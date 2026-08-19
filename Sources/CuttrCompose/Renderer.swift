@preconcurrency import AVFoundation
import CoreGraphics
import CoreImage
import CuttrKit
import Foundation

public enum RenderError: LocalizedError {
	case noVideo
	case noTracks(URL)
	case exportFailed(String)
	case cannotWrite(URL)

	public var errorDescription: String? {
		switch self {
		case .noVideo:
			return "None of the clips on this timeline have a video track."
		case .noTracks(let url):
			return "\(url.lastPathComponent) has no tracks this can read."
		case .exportFailed(let message):
			return "The export failed: \(message)"
		case .cannotWrite(let url):
			return "Cannot write to \(url.path)."
		}
	}
}

/// Turns a resolved project into a file.
///
/// The cut is an `AVMutableComposition`; the look is an `AVVideoComposition`
/// carrying the same Core Animation tree the preview uses. Nothing here draws a
/// frame itself — that is the whole design. A renderer with its own drawing code
/// is a renderer that disagrees with the preview, and the disagreement is only
/// ever found after a twenty-minute export.
public enum Renderer {

	/// What the composition and the video composition come to, kept together so
	/// the preview can build exactly what the export will encode.
	public struct Built {
		public let composition: AVMutableComposition
		public let videoComposition: AVMutableVideoComposition
		/// What the compositor was told, if this render needs one. Handed back
		/// so whoever finishes with it can say so.
		public var session: UUID?
		public let overlays: CALayer
		public let audioMix: AVAudioMix?
	}

	/// Assembles everything except the encode.
	///
	/// Separate from ``export`` because the preview needs precisely this and
	/// none of the rest: same cuts, same transforms, same overlays, played
	/// rather than written.
	public static func build(_ resolved: ResolvedProject, host: OverlayLayers.Host) async throws -> Built {
		let output = resolved.project.output
		let size = output.size
		let composition = AVMutableComposition()
		// Two picture tracks, used in turn.
		//
		// A cut needs one; a dissolve needs the outgoing shot and the incoming
		// one at the same moment, which means they cannot be on the same track.
		// Alternating always — rather than only where a dissolve asks — keeps
		// the arithmetic that decides which track a clip is on to one line.
		// The second lane exists only where a dissolve needs it. An empty extra
		// video track is not free: a Core Image filter composition over an asset
		// with two video tracks fails to export at all, which is a programme of
		// straight cuts refusing to render because of a track nothing is on.
		let lanes = resolved.clips.contains { $0.transition > 0 } ? 2 : 1
		guard let videoTracks = try? (0..<lanes).map({ _ -> AVMutableCompositionTrack in
			guard let track = composition.addMutableTrack(
				withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
			else { throw RenderError.noVideo }
			return track
		}) else { throw RenderError.noVideo }
		let audioTracks = (0..<lanes).compactMap { _ in
			composition.addMutableTrack(
				withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
		}

		let scale: Int32 = 600
		var cursor = CMTime.zero
		var sawVideo = false
		/// What to do to each clip, looked up by time while rendering.
		var grades: [(start: Double, end: Double, look: Look)] = []
		/// Volume steps for the audio mix, one per clip and track.
		var levels: [(track: Int, at: CMTime, volume: Float)] = []
		/// One stretch of programme: which track it plays from, and what it
		/// looks like. A card plays from no track at all, and says what colour
		/// to paint instead.
		var segments: [(range: CMTimeRange, track: CMPersistentTrackID?,
		                look: Look, transition: Double, blend: Transition,
		                fill: Card.Fill?)] = []
		/// What size each clip's picture arrives at, and when — for the pass
		/// that fits without filtering.
		var pictures: [(at: CMTime, size: CGSize)] = []
		/// Which lane each clip landed on, in the order the clips are in. The
		/// mix needs it: which lane is going out and which is coming in at a
		/// dissolve is decided here, and guessing it from the clip's position
		/// was wrong for any programme that mixes cuts and dissolves.
		var clipLanes: [Int] = []

		var lane = 0
		for placement in resolved.programme {
			// A card occupies time and no track. Its instruction is written
			// with the rest of them below; there is nothing to insert.
			guard case .clip(let clip) = placement else { continue }
			// The lane only changes where a dissolve needs it to. A programme of
			// straight cuts stays on one track, which is what keeps the simple
			// case simple — and exact.
			if clip.transition > 0 { lane = (lane + 1) % videoTracks.count }
			clipLanes.append(lane)
			let videoTrack = videoTracks[lane]
			let audioTrack = audioTracks.indices.contains(lane) ? audioTracks[lane] : nil
			let at = CMTime(seconds: clip.start, preferredTimescale: scale)
			let range = CMTimeRange(
				start: CMTime(seconds: clip.clip.start, preferredTimescale: scale),
				duration: CMTime(seconds: clip.duration, preferredTimescale: scale))

			grades.append((clip.start, clip.end, clip.look))
			// Linear amplitude, because that is what a mix takes. Decibels are
			// what a person reads and what the file says.
			levels.append((lane, at, Float(pow(10, clip.gain / 20))))

			if let videoURL = clip.videoURL {
				let asset = AVURLAsset(url: videoURL)
				if let source = try await asset.loadTracks(withMediaType: .video).first {
					try? videoTrack.insertTimeRange(range, of: source, at: at)
					sawVideo = true
					let natural = try await source.load(.naturalSize)
					let transform = try await source.load(.preferredTransform)
					let turned = natural.applying(transform)
					pictures.append((at, CGSize(width: abs(turned.width), height: abs(turned.height))))
				}
				// The camera's own audio, but only when the take has no separate
				// recorder. A take that has one has it because the camera's is
				// not the one anybody wants to hear.
				if clip.audioURL == nil, let audioTrack,
				   let source = try await asset.loadTracks(withMediaType: .audio).first {
					try? audioTrack.insertTimeRange(range, of: source, at: at)
				}
			}

			if let audioURL = clip.audioURL, let audioTrack {
				let asset = AVURLAsset(url: audioURL)
				if let source = try await asset.loadTracks(withMediaType: .audio).first {
					// The clip's times are on the video's clock; the audio file
					// has a clock of its own, and the take's offset is what
					// relates them. Subtracting it here is the whole reason the
					// alignment lives in the take rather than in the media.
					let audioStart = clip.clip.start - clip.audioOffset
					let lead = max(0, -audioStart)   // the audio starts after this clip does
					let available = max(0, clip.duration - lead)
					if available > 0 {
						let sourceRange = CMTimeRange(
							start: CMTime(seconds: max(0, audioStart), preferredTimescale: scale),
							duration: CMTime(seconds: available, preferredTimescale: scale))
						try? audioTrack.insertTimeRange(
							sourceRange, of: source,
							at: at + CMTime(seconds: lead, preferredTimescale: scale))
					}
				}
			}

			cursor = at + range.duration
		}

		// The stretches, in the order they play — a shot from a track, or a
		// card from a colour. Built from the merged programme rather than from
		// the clips, because a card between two shots is a stretch of time like
		// any other and the instruction list is a list of stretches of time.
		var placed = 0
		for placement in resolved.programme {
			let range = CMTimeRange(
				start: CMTime(seconds: placement.start, preferredTimescale: scale),
				duration: CMTime(seconds: placement.duration, preferredTimescale: scale))
			switch placement {
			case .clip(let clip):
				// In step with the loop above: both walk the programme in the
				// same order, and every placement starts at a different moment,
				// so the sort that made the list is settled rather than merely
				// consistent.
				let track = videoTracks[clipLanes.indices.contains(placed) ? clipLanes[placed] : 0]
				placed += 1
				segments.append((range, track.trackID, clip.look,
				                 clip.transition, clip.blend, nil))
			case .card(let card):
				segments.append((range, nil, .none, card.transition, card.blend, card.card.fill))
			}
		}

		// A card is time with nothing behind it, and a composition has no way to
		// say that. `insertEmptyTimeRange` looked like the way and is not:
		// measured, an empty range appended past the end of a track is ignored
		// outright, so a programme ending on a card came out exactly the card
		// short — and one made of nothing but cards refused to export at all,
		// as "Operation Stopped".
		//
		// So a card gets a carrier: one black frame, stretched to its length,
		// on a track of its own, never looked at. The compositor paints the
		// fill over the top and nothing else in the render knows it is there.
		// A track of its own because the lanes belong to the shots, and a card
		// that dissolves into one would otherwise be laid across it.
		var stretches: [(start: Double, end: Double)] = []
		for card in resolved.cards {
			// Merged, because two cards with a dissolve between them overlap,
			// and one carrier serves both: what is under a card is never seen,
			// so where one ends and the next begins is nothing.
			if let last = stretches.last, card.start <= last.end + 1e-6 {
				stretches[stretches.count - 1].end = max(last.end, card.end)
			} else {
				stretches.append((card.start, card.end))
			}
		}
		if let longest = stretches.map({ $0.end - $0.start }).max(),
		   let carrier = try? await carrier(size: size, seconds: longest,
		                                    framesPerSecond: output.framesPerSecond),
		   let track = composition.addMutableTrack(
			   withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
			// Asked for rather than read off the track: an asset loaded
			// asynchronously has not measured itself yet, and the synchronous
			// property answers zero — which inserts nothing, which is a card
			// that is not there at all.
			let held = (try? await carrier.track.load(.timeRange).duration) ?? .zero
			for stretch in stretches {
				let wanted = min(held, CMTime(seconds: stretch.end - stretch.start,
				                              preferredTimescale: scale))
				try? track.insertTimeRange(
					CMTimeRange(start: .zero, duration: wanted), of: carrier.track,
					at: CMTime(seconds: stretch.start, preferredTimescale: scale))
			}
		}
		// The sounds, each on a lane of its own only where it has to be.
		//
		// One lane holds any number of sounds that do not overlap, which is
		// nearly always: music, then an atmosphere, then a sting. A second lane
		// appears when two of them are on at once, because a track can only
		// play one thing at a time.
		var soundLanes: [(track: AVMutableCompositionTrack, sounds: [ResolvedSound])] = []
		for sound in resolved.sounds {
			let asset = AVURLAsset(url: sound.url)
			guard let source = (try? await asset.loadTracks(withMediaType: .audio))?.first
			else { continue }
			let free = soundLanes.firstIndex { $0.sounds.last.map { $0.end <= sound.start + 1e-6 } ?? true }
			let lane: Int
			if let free {
				lane = free
			} else {
				guard let track = composition.addMutableTrack(
					withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
				else { continue }
				soundLanes.append((track, []))
				lane = soundLanes.count - 1
			}
			// As much of the file as the span asks for, or as much as there is.
			// A sound shorter than its span simply stops; looping it would be a
			// decision the file did not make.
			let available = (try? await source.load(.timeRange).duration) ?? .zero
			let wanted = CMTime(seconds: sound.duration, preferredTimescale: scale)
			try? soundLanes[lane].track.insertTimeRange(
				CMTimeRange(start: .zero, duration: min(available, wanted)), of: source,
				at: CMTime(seconds: sound.start, preferredTimescale: scale))
			soundLanes[lane].sounds.append(sound)
		}

		// A track nothing was laid on is dropped before the export sees it.
		//
		// An export of a composition carrying a track with no media in it stops
		// dead, as "Operation Stopped", which says nothing at all about the
		// empty track that caused it. It is the same reasoning the second video
		// lane already gets a few lines up, and it has bitten twice from the
		// other end: a take whose video has no audio track — silent b-roll, a
		// downloaded clip — leaves the audio lane empty and the whole render
		// refuses. A programme of nothing but cards leaves both empty.
		//
		// The video side only drops a lane no instruction names. A lane a clip
		// was assigned to but whose media would not load is still where the
		// compositor will look, and taking it out of the composition turns a
		// black stretch into a failed render.
		let named = Set(segments.compactMap(\.track))
		for track in composition.tracks(withMediaType: .audio) where track.segments.isEmpty {
			composition.removeTrack(track)
		}
		for track in composition.tracks(withMediaType: .video)
		where track.segments.isEmpty && !named.contains(track.trackID) {
			composition.removeTrack(track)
		}
		// What is left, with the lane each one is — the mix is about lanes, and
		// after a removal the positions in this array are not them.
		let liveAudio = audioTracks.enumerated()
			.filter { !$0.element.segments.isEmpty }
			.map { (lane: $0.offset, track: $0.element) }
		let liveSounds = soundLanes.filter { !$0.track.segments.isEmpty }
		// Whether any lane has a hole in it — under a card, or where a silent
		// shot sits between two that are not. A hole has to be *heard* as
		// silence, and that wants a mix even when every level in it is one:
		// without one the export passes the audio through and says where the
		// holes are in an edit list, which some players honour and some quietly
		// play straight over. Measured twice: a tone that should have stopped
		// under a card ran on through it, and a programme that opened on a
		// silent shot came back with the second shot's sound at the top.
		let gaps = liveAudio.contains { $0.track.segments.contains(where: \.isEmpty) }
		cursor = max(cursor, CMTime(seconds: resolved.duration, preferredTimescale: scale))

		// A card is a picture with no footage in it, so a programme made only of
		// cards is a programme.
		guard sawVideo || !resolved.cards.isEmpty else { throw RenderError.noVideo }

		let overlays = OverlayLayers.build(resolved, size: size, host: host)

		// The effects are drawn into the frame here, in the same pass as the
		// grade — they are pixels, not layers, and a layer tree cannot hold
		// three hundred lit slips of card tumbling in depth.
		let effects: [(overlay: ResolvedOverlay, effect: Effect, renderer: EffectRenderer)] =
			resolved.overlays.compactMap { shown in
				guard case .effect(let effect) = shown.overlay.kind,
				      let renderer = EffectRenderer(effect, size: size) else { return nil }
				return (shown, effect, renderer)
			}
		// Asked for only when something wants to go behind somebody.
		let people = resolved.overlays.contains { $0.overlay.behind == .people } ? PersonMask() : nil

		// Nothing to filter? Then do not filter.
		//
		// Core Image's pass costs colour: measured against the same frame of the
		// same footage, the picture came back seven or eight levels lifted right
		// across, which is what "washed out" was. A programme with no grade and
		// no effects, at the size it was shot, has nothing for that pass to do —
		// so it goes through AVFoundation's own path instead and comes out
		// identical to what went in. A fit, when one is needed, is a transform
		// on a layer instruction, which is exact.
		let graded = grades.contains { $0.look != .none }
		let dissolves = resolved.clips.contains { $0.transition > 0 }
		let unmanaged = CIContext(options: [.workingColorSpace: NSNull()])
		// Anything that goes behind somebody is painted into the frame, which
		// is the filter pass's job — so there *is* something for it to do.
		let painted = resolved.overlays.contains { $0.overlay.behind == .people }
		// Film mode is the picture, changed. Without this the programme would
		// take the exact path — which is the one that does nothing at all.
		let filmed = resolved.overlays.contains {
			if case .film = $0.overlay.kind { return true } else { return false }
		}
		// A card has no source frame, so there is nothing for either of the
		// two cheap paths to hand back or to filter: only the compositor can
		// make a frame out of nothing. A project with no cards pays nothing for
		// this — it is one array being empty.
		let cards = !resolved.cards.isEmpty
		if !graded, effects.isEmpty, !painted, !dissolves, !filmed, !cards {
			let plainComposition = AVMutableVideoComposition(propertiesOf: composition)
			plainComposition.renderSize = size
			plainComposition.frameDuration = CMTime(
				value: 1, timescale: CMTimeScale(max(1, output.framesPerSecond.rounded())))

			// The fit, per clip, as a step at the moment that clip starts.
			let instruction = AVMutableVideoCompositionInstruction()
			instruction.timeRange = CMTimeRange(start: .zero, duration: cursor)
			let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTracks[0])
			for picture in pictures {
				let fit = Grading.fit(CGRect(origin: .zero, size: picture.size), into: size)
				layer.setTransform(fit, at: picture.at)
			}
			instruction.layerInstructions = [layer]
			plainComposition.instructions = [instruction]

			return Built(composition: composition, videoComposition: plainComposition,
			             overlays: overlays,
			             audioMix: audioMix(liveAudio, levels: levels, clips: resolved.clips,
			                              lanes: clipLanes, duration: resolved.duration,
			                              silences: gaps,
			                              sounds: liveSounds))
		}

		// A dissolve needs two frames at once, and only the compositor can hold
		// two. Everything else goes through Core Image, which is where it has
		// always gone — and, measured against the footage, comes out with the
		// numbers it went in with. The compositor's own frames arrive about
		// three per cent lifted, which is worth it for a dissolve and is not
		// worth it for a programme of straight cuts.
		guard dissolves || cards else {
			let filtered = AVMutableVideoComposition(asset: composition) { request in
				let time = request.compositionTime.seconds
				let look = grades.last { time >= $0.start - 1e-6 && time < $0.end + 1e-6 }?.look ?? .none
				var image = Grading.apply(look, to: request.sourceImage)
				image = image.transformed(by: Grading.fit(image.extent, into: size))
				image = Frame.overlays(over: image, at: time, size: size,
				                       work: ProgrammeCompositor.Work(
					                       size: size, project: resolved.project,
					                       baseURL: resolved.baseURL, overlays: resolved.overlays,
					                       effects: effects.map { ($0.overlay, $0.renderer) },
					                       people: people))
				// Colour management off: converting Rec. 709 video into Core
				// Image's linear space and back does not come home, and the
				// picture arrives seven or eight levels lifted.
				request.finish(with: image, context: unmanaged)
			}
			filtered.renderSize = size
			filtered.frameDuration = CMTime(
				value: 1, timescale: CMTimeScale(max(1, output.framesPerSecond.rounded())))
			return Built(composition: composition, videoComposition: filtered,
			             overlays: overlays,
			             audioMix: audioMix(liveAudio, levels: levels, clips: resolved.clips,
			                              lanes: clipLanes, duration: resolved.duration,
			                              silences: gaps,
			                              sounds: liveSounds))
		}

		let session = ProgrammeCompositor.register(ProgrammeCompositor.Work(
			size: size, project: resolved.project, baseURL: resolved.baseURL,
			overlays: resolved.overlays,
			effects: effects.map { ($0.overlay, $0.renderer) }, people: people))

		let videoComposition = AVMutableVideoComposition()
		videoComposition.customVideoCompositorClass = ProgrammeCompositor.self
		// Named for the compositor's own frames, which this program made and
		// should say the colour of. Without it they come back forty levels
		// dark; with it, about eight light. Neither is nothing, and the second
		// is the one to have.
		videoComposition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
		videoComposition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
		videoComposition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
		videoComposition.renderSize = size
		videoComposition.frameDuration = CMTime(
			value: 1, timescale: CMTimeScale(max(1, output.framesPerSecond.rounded())))

		// One instruction per stretch: a dissolve while two shots overlap, the
		// shot on its own for the rest.
		var instructions: [AVVideoCompositionInstructionProtocol] = []
		for (index, segment) in segments.enumerated() {
			let previous = index > 0 ? segments[index - 1] : nil
			let start = segment.range.start
			if segment.transition > 0, let previous {
				let over = CMTime(seconds: segment.transition, preferredTimescale: scale)
				instructions.append(ProgrammeInstruction(
					timeRange: CMTimeRange(start: start, duration: over),
					outgoing: previous.track, incoming: segment.track,
					outgoingLook: previous.look, incomingLook: segment.look,
					outgoingFill: previous.fill, incomingFill: segment.fill,
					blend: segment.blend, session: session))
			}
			// Alone from the end of its dissolve until the next one begins.
			let soloStart = start + CMTime(seconds: segment.transition, preferredTimescale: scale)
			let soloEnd = index + 1 < segments.count
				? segments[index + 1].range.start
				: segment.range.end
			if soloEnd > soloStart {
				instructions.append(ProgrammeInstruction(
					timeRange: CMTimeRange(start: soloStart, end: soloEnd),
					outgoing: nil, incoming: segment.track,
					incomingLook: segment.look, incomingFill: segment.fill,
					session: session))
			}
		}
		videoComposition.instructions = instructions

		return Built(composition: composition, videoComposition: videoComposition,
		             session: session, overlays: overlays,
		             audioMix: audioMix(liveAudio, levels: levels, clips: resolved.clips,
			                              lanes: clipLanes, duration: resolved.duration,
			                              silences: gaps,
			                              sounds: liveSounds))
	}

	/// One black frame in a file, for a card to hold its place with.
	///
	/// Written once per size into the temporary folder and reused: it is a
	/// single frame, it is the same frame every time, and a render that writes
	/// it again on every build is a render that writes a file to throw it away.
	/// Nothing ever looks at the pixels — the compositor paints the card's own
	/// fill over them — so the only thing that matters about this file is that
	/// it exists and has a frame in it.
	private static func carrier(
		size: CGSize, seconds: Double, framesPerSecond: Double
	) async throws -> (asset: AVURLAsset, track: AVAssetTrack)? {
		let rate = max(1, framesPerSecond.rounded())
		let frames = max(1, Int((seconds * rate).rounded(.up)))
		let url = FileManager.default.temporaryDirectory.appendingPathComponent(
			"cuttr-card-\(Int(size.width))x\(Int(size.height))-\(frames)@\(Int(rate)).mov")
		if !FileManager.default.fileExists(atPath: url.path) {
			let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
			let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
				AVVideoCodecKey: AVVideoCodecType.h264,
				AVVideoWidthKey: Int(size.width),
				AVVideoHeightKey: Int(size.height),
			])
			input.expectsMediaDataInRealTime = false
			let adaptor = AVAssetWriterInputPixelBufferAdaptor(
				assetWriterInput: input,
				sourcePixelBufferAttributes: [
					kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
				])
			guard writer.canAdd(input) else { return nil }
			writer.add(input)
			guard writer.startWriting() else { return nil }
			writer.startSession(atSourceTime: .zero)
			var buffer: CVPixelBuffer?
			CVPixelBufferCreate(nil, Int(size.width), Int(size.height),
			                    kCVPixelFormatType_32BGRA, nil, &buffer)
			if let buffer {
				CVPixelBufferLockBaseAddress(buffer, [])
				if let base = CVPixelBufferGetBaseAddress(buffer) {
					memset(base, 0, CVPixelBufferGetBytesPerRow(buffer) * Int(size.height))
				}
				CVPixelBufferUnlockBaseAddress(buffer, [])
				// A frame for every frame of the card, rather than one frame
				// held. Held was tried twice — as a long sample, and as a short
				// one stretched with `scaleTimeRange` — and both made a
				// composition of exactly the right length that then exported
				// one frame past the last shot: the encoder stops where the
				// source samples stop, whatever the edits say. Black frames
				// compress to nothing, so this costs a few kilobytes.
				for frame in 0..<frames {
					while !input.isReadyForMoreMediaData {
						try? await Task.sleep(nanoseconds: 1_000_000)
					}
					adaptor.append(buffer, withPresentationTime: CMTime(
						value: CMTimeValue(frame), timescale: CMTimeScale(rate)))
				}
			}
			input.markAsFinished()
			writer.endSession(atSourceTime: CMTime(
				value: CMTimeValue(frames), timescale: CMTimeScale(rate)))
			await writer.finishWriting()
		}
		// The asset comes back with the track, because a track holds its asset
		// *weakly*: handing back the track alone let the asset go the moment
		// this returned, and every insert then failed with a bare -12780.
		let asset = AVURLAsset(url: url)
		guard let track = try await asset.loadTracks(withMediaType: .video).first else { return nil }
		return (asset, track)
	}

	/// The mix: what each lane is set to, moment by moment.
	///
	/// A level is *held* rather than set once and left. Measured, and it cost
	/// an afternoon: two volume settings a few seconds apart are read as the
	/// ends of a ramp, not as a step and a step, so a sound set to its gain at
	/// three seconds and to nothing at six faded steadily away across the whole
	/// of itself. So everything here is written as a ramp — a flat one where the
	/// level holds — and the flat stretches are worked out from where the next
	/// change is.
	///
	/// A step at a cut because the cut is already a discontinuity: a crossfade
	/// of levels across it would be audible as a swell on the wrong side of the
	/// edit. A ramp across a dissolve because there the picture is mixing too,
	/// and a hard audio cut in the middle of one is the thing everybody hears.
	private static func audioMix(
		_ tracks: [(lane: Int, track: AVMutableCompositionTrack)],
		levels: [(track: Int, at: CMTime, volume: Float)],
		clips: [ResolvedClip],
		lanes: [Int],
		duration: Double,
		silences: Bool = false,
		sounds: [(track: AVMutableCompositionTrack, sounds: [ResolvedSound])] = []
	) -> AVAudioMix? {
		guard !tracks.isEmpty || !sounds.isEmpty else { return nil }
		let scale: CMTimeScale = 600
		var parameters: [AVMutableAudioMixInputParameters] = []
		// Stretches that have to be *heard* as silence want a mix even when
		// every level in it is one. Without one the export passes the audio
		// through and says where the gaps are in an edit list, which some
		// players honour and some quietly play straight over — measured: a tone
		// that should have stopped under a card ran on through it.
		var wanted = silences || !sounds.isEmpty
		let end = max(duration, 0) + 1

		func time(_ seconds: Double) -> CMTime {
			CMTime(seconds: max(0, seconds), preferredTimescale: scale)
		}

		/// One lane's instructions: levels that hold, and moves between them.
		struct Lane {
			var steps: [(at: Double, volume: Float)] = []
			var moves: [(start: Double, end: Double, from: Float, to: Float)] = []
		}

		/// Writes a lane out, turning every held level into a flat ramp that
		/// runs as far as the next thing that happens on that lane.
		func write(_ lane: Lane, to input: AVMutableAudioMixInputParameters) {
			var moves = lane.moves
			let changes = (lane.moves.map(\.start) + lane.steps.map(\.at)).sorted()
			for step in lane.steps {
				let next = changes.first { $0 > step.at + 1e-6 } ?? end
				moves.append((step.at, next, step.volume, step.volume))
			}
			// Silent until the first thing happens: a lane carries only what was
			// laid on it, and what is between must not be heard.
			if let first = changes.first, first > 0 {
				moves.append((0, first, 0, 0))
			}
			for move in moves.sorted(by: { $0.start < $1.start }) where move.end > move.start {
				input.setVolumeRamp(
					fromStartVolume: move.from, toEndVolume: move.to,
					timeRange: CMTimeRange(start: time(move.start),
					                       duration: time(move.end - move.start)))
			}
		}

		/// What a lane is set to at a moment, before anything ducks it.
		func level(_ lane: Int, at when: Double) -> Float {
			levels.last { $0.track == lane && $0.at.seconds <= when + 1e-6 }?.volume ?? 0
		}

		/// Everything pulling the programme under at a moment, multiplied
		/// together. Two sounds ducking at once duck twice, which is what the
		/// numbers say.
		let ducking = sounds.flatMap(\.sounds).filter { $0.sound.ducks != 0 }
		func duck(at when: Double) -> Float {
			var factor: Float = 1
			for sound in ducking where when > sound.start - 1e-6 && when < sound.end + 1e-6 {
				factor *= Float(pow(10, -sound.sound.ducks / 20))
			}
			return factor
		}

		for (lane, track) in tracks {
			let mine = levels.filter { $0.track == lane }
			guard !mine.isEmpty else { continue }
			var built = Lane()

			for step in mine {
				if step.volume != 1 { wanted = true }
				built.steps.append((step.at.seconds, step.volume * duck(at: step.at.seconds)))
			}

			// The dissolves: the outgoing lane down, the incoming lane up, over
			// exactly the overlap.
			for (index, clip) in clips.enumerated() where clip.transition > 0 && index > 0 {
				wanted = true
				let under = duck(at: clip.start)
				let up = Float(pow(10, clip.gain / 20)) * under
				let down = Float(pow(10, clips[index - 1].gain / 20)) * under
				// The lanes the two clips were actually laid on, rather than the
				// parity of their position. A lane only changes where a dissolve
				// asks for it, so in a programme that mixes cuts and dissolves
				// the two are not the same number — and the ramps went to the
				// wrong lanes, taking the incoming shot's sound up from nothing
				// on a track that had nothing on it.
				let coming = index < lanes.count ? lanes[index] : index % 2
				let going = index - 1 < lanes.count ? lanes[index - 1] : (index - 1) % 2
				if lane == coming {
					built.moves.append((clip.start, clip.start + clip.transition, 0, up))
				} else if lane == going {
					built.moves.append((clip.start, clip.start + clip.transition, down, 0))
				}
			}

			// The ducking, at its two edges. In the middle the levels above
			// already carry it, so what is left is getting there and back: down
			// as the sound comes up, and up again as it goes. It follows the
			// sound's own fades, because a duck that snaps under a fading-in bed
			// is heard as a drop rather than as room being made.
			for sound in ducking {
				let factor = Float(pow(10, -sound.sound.ducks / 20))
				let inOver = max(0.25, min(sound.sound.fadeIn, sound.duration / 2))
				let outOver = max(0.25, min(sound.sound.fadeOut, sound.duration / 2))
				let before = level(lane, at: sound.start - 1e-3)
				if before > 0 {
					built.moves.append((max(0, sound.start - inOver), sound.start,
					                    before, before * factor))
				}
				let after = level(lane, at: sound.end)
				if after > 0 {
					built.moves.append((max(0, sound.end - outOver), sound.end,
					                    after * factor, after))
				}
			}

			let input = AVMutableAudioMixInputParameters(track: track)
			write(built, to: input)
			parameters.append(input)
		}

		// The sounds themselves: a level, and a fade at each end when the file
		// asks for one.
		for lane in sounds {
			var built = Lane()
			for sound in lane.sounds {
				let gain = Float(pow(10, sound.sound.gain / 20))
				let inOver = min(sound.sound.fadeIn, sound.duration / 2)
				let outOver = min(sound.sound.fadeOut, sound.duration / 2)
				if inOver > 0 {
					built.moves.append((sound.start, sound.start + inOver, 0, gain))
				}
				built.steps.append((sound.start + inOver, gain))
				if outOver > 0 {
					built.moves.append((sound.end - outOver, sound.end, gain, 0))
				}
				// Off at the end, whether it faded or stopped: the lane may
				// carry another sound later, and what is between them must not
				// be heard.
				built.steps.append((sound.end, 0))
			}
			let input = AVMutableAudioMixInputParameters(track: lane.track)
			write(built, to: input)
			parameters.append(input)
		}

		guard wanted, !parameters.isEmpty else { return nil }
		let mix = AVMutableAudioMix()
		mix.inputParameters = parameters
		return mix
	}

	/// Draws the overlays over a file that has already been graded and fitted.
	///
	/// A second pass, because the first one cannot do it: a video composition
	/// built with `applyingCIFiltersWithHandler` — which is how the grade and
	/// the fit are done — silently ignores `AVVideoCompositionCoreAnimationTool`.
	public static func overlays(
		of resolved: ResolvedProject, onto source: URL, to url: URL,
		progress: @escaping @Sendable (Double) -> Void = { _ in }
	) async throws {
		let asset = AVURLAsset(url: source)
		let size = resolved.project.output.size
		let videoComposition = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: asset)
		videoComposition.renderSize = size
		videoComposition.frameDuration = CMTime(
			value: 1, timescale: CMTimeScale(max(1, resolved.project.output.framesPerSecond.rounded())))

		let overlays = OverlayLayers.build(resolved, size: size, host: .export)
		// As an *additional* layer rather than by drawing the video into one.
		//
		// `postProcessingAsVideoLayer:` puts the picture inside a Core Animation
		// tree, and Core Animation composites in its own colour: the frame came
		// back twenty levels lifted, milky, with the sky gone. This variant
		// leaves the video where it is and lays the overlays over it.
		let track = try await asset.loadTracks(withMediaType: .video).first
		let trackID = (track?.trackID ?? 1) &+ 1
		overlays.frame = CGRect(origin: .zero, size: size)
		videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
			additionalLayer: overlays, asTrackID: trackID)
		// The overlay track has to be named in the instruction, or the tool has
		// nowhere to put it.
		if let source = track {
			let instruction = AVMutableVideoCompositionInstruction()
			instruction.timeRange = CMTimeRange(
				start: .zero, duration: try await asset.load(.duration))
			// Both tracks named: the picture, and the layer that is laid over
			// it. `requiredSourceTrackIDs` is worked out from these, and the
			// tool draws nothing for a track nobody asked for.
			let overlayInstruction = AVMutableVideoCompositionLayerInstruction()
			overlayInstruction.trackID = trackID
			instruction.layerInstructions = [
				overlayInstruction,
				AVMutableVideoCompositionLayerInstruction(assetTrack: source),
			]
			instruction.enablePostProcessing = true
			videoComposition.instructions = [instruction]
		}

		try await write(asset, videoComposition: videoComposition, audioMix: nil,
		                to: url, progress: progress)
	}

	/// How far in or out an overlay is at a moment: one at the middle, nothing
	/// at either edge if it fades.
	///
	/// The same in and out an overlay's layers use, in arithmetic rather than
	/// keyframes, because an effect is composited by hand and there is nothing
	/// for Core Animation to interpolate.
	private static func fade(_ shown: ResolvedOverlay, at time: Double) -> Double {
		let span = max(shown.duration, 0.0001)
		let arrive = min(shown.overlay.arrival.duration, span / 2)
		let depart = min(shown.overlay.departure.duration, span / 2)
		var opacity = 1.0
		// Only a fade fades. An effect cannot slide — it is the whole frame —
		// so anything else simply starts, which for confetti means the first
		// pieces arriving over the top edge.
		if case .fade = shown.overlay.arrival, arrive > 0, time < shown.start + arrive {
			opacity = min(opacity, (time - shown.start) / arrive)
		}
		if case .fade = shown.overlay.departure, depart > 0, time > shown.end - depart {
			opacity = min(opacity, (shown.end - time) / depart)
		}
		return max(0, min(1, opacity))
	}

	/// Done with a build: the compositor can forget what it was told.
	public static func forget(_ session: UUID?) {
		guard let session else { return }
		ProgrammeCompositor.forget(session)
	}

	/// Renders to a file.
	///
	/// In two passes when there is anything drawn over the cut, because one pass
	/// cannot do both: the grade and the aspect fit are a Core Image video
	/// composition, and such a composition silently ignores the Core Animation
	/// tool that draws the overlays. That combination is why a render came out
	/// correct in every respect except that it had no captions and no spinners
	/// on it. A project with no overlays is still one pass, and encoded once.
	///
	/// `progress` is called on an unspecified thread, often, with 0…1.
	public static func export(
		_ resolved: ResolvedProject,
		to url: URL,
		progress: @escaping @Sendable (Double) -> Void = { _ in }
	) async throws {
		let built = try await build(resolved, host: .export)
		// Only *layers* need the second pass. An effect is drawn into the frame
		// in the first one, so a programme with nothing but effects over it is
		// encoded once.
		let drawsOver = resolved.overlays.contains { OverlayLayers.isLayered($0.overlay) }

		guard FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().path)
		else { throw RenderError.cannotWrite(url) }

		// The graded pass goes beside the output rather than into a temporary
		// folder: it is the size of the finished film, and somebody who runs out
		// of room should run out of room where they can see it.
		let graded = drawsOver
			? url.deletingPathExtension().appendingPathExtension("grading.mov")
			: url

		try await write(built.composition, videoComposition: built.videoComposition,
		                audioMix: built.audioMix, to: graded) { done in
			progress(drawsOver ? done * 0.6 : done)
		}

		guard drawsOver else { return }
		defer { try? FileManager.default.removeItem(at: graded) }
		try await overlays(of: resolved, onto: graded, to: url) { done in
			progress(0.6 + done * 0.4)
		}
		progress(1)
	}

	/// One export session, run to completion.
	private static func write(
		_ asset: AVAsset,
		videoComposition: AVVideoComposition?,
		audioMix: AVAudioMix?,
		to url: URL,
		progress: @escaping @Sendable (Double) -> Void
	) async throws {
		// HEVC, when the machine will do it.
		//
		// Measured, not assumed: the same frame of the same footage through
		// `AVAssetExportPresetHighestQuality` — which is H.264 — came out eight
		// levels lifted across the whole picture, and through the HEVC preset
		// came out identical to the source. Whatever H.264's transcode is doing
		// to the range, a video tool cannot ship a render that is a different
		// colour from its own preview.
		let presets = AVAssetExportSession.exportPresets(compatibleWith: asset)
		let preset = presets.contains(AVAssetExportPresetHEVCHighestQuality)
			? AVAssetExportPresetHEVCHighestQuality
			: AVAssetExportPresetHighestQuality
		guard let session = AVAssetExportSession(asset: asset, presetName: preset)
		else { throw RenderError.exportFailed("no exporter for this composition") }
		session.videoComposition = videoComposition
		session.audioMix = audioMix
		session.timeRange = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
		session.outputFileType = .mov
		session.outputURL = url
		session.shouldOptimizeForNetworkUse = false

		// The export refuses to start if anything is already there, rather than
		// overwriting, so the removal is ours to do — and is worth doing
		// explicitly rather than discovering as a failure ten seconds in.
		try? FileManager.default.removeItem(at: url)

		let ticker = Task {
			while !Task.isCancelled {
				progress(Double(session.progress))
				try? await Task.sleep(nanoseconds: 200_000_000)
			}
		}
		defer { ticker.cancel() }

		await session.export()
		switch session.status {
		case .completed:
			progress(1)
		case .cancelled:
			throw CancellationError()
		default:
			throw RenderError.exportFailed(session.error?.localizedDescription ?? "unknown")
		}
	}

}
