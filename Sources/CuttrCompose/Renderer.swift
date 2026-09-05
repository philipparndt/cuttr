@preconcurrency import AVFoundation
import CoreGraphics
import CoreImage
import CuttrKit
import Foundation

public enum RenderError: LocalizedError {
	case noVideo
	case noTracks(URL)
	/// A recording a clip names that this machine cannot read — gone, or on a
	/// card nobody has plugged in. The whole path, because the point of saying
	/// it is that somebody goes and finds the file.
	case missingRecording(URL)
	case exportFailed(String)
	case cannotWrite(URL)

	public var errorDescription: String? {
		switch self {
		case .noVideo:
			return "None of the clips on this timeline have a video track."
		case .noTracks(let url):
			return "\(url.lastPathComponent) has no tracks this can read."
		case .missingRecording(let url):
			return "\(url.path) cannot be read, so the clips that play it have no "
				+ "picture. A render of a programme with a hole in it is not what "
				+ "anybody meant to ask for, so this stops here."
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
		// Two sound lanes always, taken in turn — one per clip, whether or
		// not anything dissolves. Not for overlap: the audio renderer cannot
		// *step* a volume. Measured on an export: a level written to change
		// at a cut is smoothed across roughly the next render buffer, some
		// hundred and ninety milliseconds, so a shot levelled at +20 dB
		// followed by one at −12 dB played the first fraction of the quiet
		// shot eight times too loud — a burst at every such cut, and a dip
		// drawn just after one drowned in it. With the two shots on two lanes
		// the change is written where a lane is carrying nothing, and there is
		// no step left for the renderer to smooth. See ``settling``. An empty
		// audio track costs nothing here: one nothing landed on is dropped
		// below, the way the video lane is.
		let audioTracks = (0..<2).compactMap { _ in
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
		/// And where a clip's level *moves*, for the clips whose take carries a
		/// gain curve. A step and a ramp are two different instructions to the
		/// mix, so they are two lists rather than one with a flag: a clip with
		/// no curve writes exactly the step it always wrote.
		var ramps: [(track: Int, start: Double, end: Double, from: Float, to: Float)] = []
		/// One stretch of programme: which track it plays from, and what it
		/// looks like. A card plays from no track at all, and says what colour
		/// to paint instead.
		var segments: [(range: CMTimeRange, track: CMPersistentTrackID?,
		                look: Look, transition: Double, blend: Transition,
		                fill: Card.Fill?)] = []
		/// What size each clip's picture arrives at, and when — for the pass
		/// that fits without filtering.
		var pictures: [(at: CMTime, size: CGSize)] = []
		/// Which sound lane each clip landed on, in the order the clips are in.
		/// The mix needs it: which lane is going out and which is coming in at a
		/// dissolve is decided here, and guessing it from the clip's position
		/// was wrong for any programme that mixes cuts and dissolves.
		var clipLanes: [Int] = []
		/// And which picture lane, which is a different question: the picture
		/// changes lane only where a dissolve needs two at once.
		var videoLanes: [Int] = []
		/// The stretches whose recording would not load, and the file each of
		/// them names.
		///
		/// A preview plays these as a pink card saying so; an export refuses by
		/// name. The two hosts want opposite things from the same fact: the
		/// window is where somebody is *finding out* that a file is missing,
		/// and a file with a hole in it is not something to discover afterwards.
		var missing: [(range: CMTimeRange, url: URL)] = []
		/// The frame a hold stands on, already fitted to the output, and the
		/// stretch of programme it is shown for.
		///
		/// A picture rather than a stretch of track, because a composition has
		/// no way to say "this frame, for six seconds" that survives being
		/// exported — see the hold below.
		var stills: [(range: CMTimeRange, image: CIImage)] = []

		var videoLane = 0
		var lane = audioTracks.count - 1
		for placement in resolved.programme {
			// A card occupies time and no track. Its instruction is written
			// with the rest of them below; there is nothing to insert.
			guard case .clip(let clip) = placement else { continue }
			// The picture lane only changes where a dissolve needs it to. A
			// programme of straight cuts stays on one track, which is what
			// keeps the simple case simple — and exact. The sound lane changes
			// at every clip, for the reason given where the tracks are made.
			if clip.transition > 0 { videoLane = (videoLane + 1) % videoTracks.count }
			lane = (lane + 1) % max(audioTracks.count, 1)
			clipLanes.append(lane)
			videoLanes.append(videoLane)
			let videoTrack = videoTracks[videoLane]
			let audioTrack = audioTracks.indices.contains(lane) ? audioTracks[lane] : nil
			let at = CMTime(seconds: clip.start, preferredTimescale: scale)
			grades.append((clip.start, clip.end, clip.look))
			// Linear amplitude, because that is what a mix takes. Decibels are
			// what a person reads and what the file says.
			//
			// A curve is the same arithmetic once per interval instead of once
			// per clip, and it covers the clip end to end: the mix is told to
			// move rather than to hold, so there is no step left over to argue
			// with the ramps.
			if clip.levels.isEmpty {
				levels.append((lane, at, Float(Levelling.amplitude(clip.gain))))
			} else {
				for move in GainCurve.ramps(clip.levels, from: clip.start, to: clip.end) {
					ramps.append((lane, move.start, move.end,
					              Float(Levelling.amplitude(clip.gain + move.from)),
					              Float(Levelling.amplitude(clip.gain + move.to))))
				}
			}

			// One stretch when nothing is held, and a split with a frozen
			// frame between for each hold. The clip asks for the split; here
			// it is only laid down.
			let stretches = clip.playing

			if let videoURL = clip.videoURL {
				let asset = AVURLAsset(url: videoURL)
				// `try?`, and the resolver is what says so.
				//
				// A recording that is not on this machine — a project cloned
				// without its media, a card reader unplugged — threw out of
				// here and took the build with it, and what somebody saw was
				// "The operation could not be completed" and no preview at all,
				// for a programme of a hundred and twenty clips of which one
				// was missing. The file is named beside the picture when the
				// project resolves; here it costs its own clip and nothing
				// else.
				let tracks = try? await asset.loadTracks(withMediaType: .video)
				if tracks?.isEmpty ?? true {
					guard host == .preview else {
						// A file that is there and will not decode is a
						// different thing to look into than one that is not
						// there at all, and the difference is worth the two
						// lines it costs to say.
						throw FileManager.default.fileExists(atPath: videoURL.path)
							? RenderError.noTracks(videoURL)
							: RenderError.missingRecording(videoURL)
					}
					let range = CMTimeRange(
						start: at, duration: CMTime(seconds: clip.duration,
						                            preferredTimescale: scale))
					missing.append((range, videoURL))
					stills.append((range, missingPicture(videoURL, size: size)))
					// Over the whole frame rather than inside the last shot's
					// rectangle: what is being said is about the programme, not
					// about a picture that is not there to be fitted.
					pictures.append((at, size))
				}
				if let source = tracks?.first {
					// How much recording there is, for the filler a hold needs
					// — and *only* then.
					//
					// This was asked for every clip, and asked with a bare `try`:
					// one recording whose track would not answer took the whole
					// build down, and what somebody saw was a preview that did
					// nothing, a play button that did nothing and a look that
					// did nothing, with an AVFoundation code in the corner. A
					// programme with no holds in it does not need this at all,
					// and a programme with one should lose the hold rather than
					// the film.
					var sourceSpan = CMTimeRange(start: .zero, duration: .zero)
					if stretches.contains(where: \.isHeld) {
						sourceSpan = (try? await source.load(.timeRange))
							?? CMTimeRange(start: .zero,
							               duration: CMTime(seconds: clip.clip.end,
							                                preferredTimescale: scale))
					}
					for stretch in stretches {
						let lands = CMTime(seconds: stretch.at, preferredTimescale: scale)
						if stretch.isHeld {
							// The picture is held by *drawing* one frame for
							// the length of the hold, not by putting one in the
							// track — see `stills` below. What goes in the
							// track here is filler: the right number of
							// seconds of something, so that the composition has
							// an unbroken timeline and every downstream pass
							// has an instruction to work from. None of it is
							// ever seen.
							//
							// Two shorter ways were tried and both are wrong.
							// One frame `scaleTimeRange`d to the hold renders
							// correctly and then breaks the pass *after* it:
							// the file comes out with the right duration and
							// only the frames that were in the footage, spread
							// out, and `AVVideoCompositionCoreAnimationTool`
							// over an asset timed like that draws nothing —
							// a programme with its hold and none of its
							// captions. Laying the same frame down once per
							// frame of the hold builds a correct composition of
							// several hundred one-frame segments, and the
							// export then loses two frames in three of them.
							let mark = CMTime(seconds: stretch.from, preferredTimescale: scale)
							let whole = CMTime(seconds: stretch.length, preferredTimescale: scale)
							var filled = CMTime.zero
							// A recording of no length has nothing to fill
							// with, and the loop below would never end asking
							// for some.
							let hasFooting = sourceSpan.duration > .zero
							while hasFooting && filled < whole {
								let want = whole - filled
								// As near the hold's own mark as the recording
								// allows, and round again when the hold is
								// longer than the whole recording. Which
								// seconds these are is not a question anybody
								// can see the answer to.
								let from = max(sourceSpan.start, min(mark, sourceSpan.end - want))
								let take = min(want, sourceSpan.end - from)
								guard take > .zero else { break }
								try? videoTrack.insertTimeRange(
									CMTimeRange(start: from, duration: take),
									of: source, at: lands + filled)
								filled = filled + take
							}
							if let held = try? await still(
								of: asset, at: stretch.from, size: size) {
								stills.append((CMTimeRange(
									start: lands,
									duration: CMTime(seconds: stretch.length,
									                 preferredTimescale: scale)), held))
							}
						} else {
							try? videoTrack.insertTimeRange(CMTimeRange(
								start: CMTime(seconds: stretch.from, preferredTimescale: scale),
								duration: CMTime(seconds: stretch.take, preferredTimescale: scale)),
								of: source, at: lands)
						}
					}
					sawVideo = true
					let natural = try await source.load(.naturalSize)
					let transform = try await source.load(.preferredTransform)
					let turned = natural.applying(transform)
					pictures.append((at, CGSize(width: abs(turned.width), height: abs(turned.height))))
				}
				// The camera's own audio, but only when the take has no separate
				// recorder. A take that has one has it because the camera's is
				// not the one anybody wants to hear.
				//
				// A held stretch gets none of it: a frozen picture with the
				// sound running on is the one thing that reads as a fault
				// rather than as a deliberate stop.
				if clip.audioURL == nil, let audioTrack,
				   let source = (try? await asset.loadTracks(withMediaType: .audio))?.first {
					for stretch in stretches where !stretch.isHeld {
						try? audioTrack.insertTimeRange(CMTimeRange(
							start: CMTime(seconds: stretch.from, preferredTimescale: scale),
							duration: CMTime(seconds: stretch.take, preferredTimescale: scale)),
							of: source, at: CMTime(seconds: stretch.at, preferredTimescale: scale))
					}
				}
			}

			if let audioURL = clip.audioURL, let audioTrack {
				let asset = AVURLAsset(url: audioURL)
				if let source = (try? await asset.loadTracks(withMediaType: .audio))?.first {
					for stretch in stretches where !stretch.isHeld {
						// The clip's times are on the video's clock; the audio
						// file has a clock of its own, and the take's offset is
						// what relates them. Subtracting it here is the whole
						// reason the alignment lives in the take rather than in
						// the media.
						let audioStart = stretch.from - clip.audioOffset
						let lead = max(0, -audioStart)   // the audio starts after this stretch does
						let available = max(0, stretch.take - lead)
						guard available > 0 else { continue }
						let sourceRange = CMTimeRange(
							start: CMTime(seconds: max(0, audioStart), preferredTimescale: scale),
							duration: CMTime(seconds: available, preferredTimescale: scale))
						try? audioTrack.insertTimeRange(
							sourceRange, of: source,
							at: CMTime(seconds: stretch.at + lead, preferredTimescale: scale))
					}
				}
			}

			cursor = CMTime(seconds: clip.end, preferredTimescale: scale)
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
				let track = videoTracks[videoLanes.indices.contains(placed) ? videoLanes[placed] : 0]
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
		//
		// A shot whose recording is missing wants exactly the same thing, for
		// exactly the same reason: its lane is empty there, and a stretch of
		// composition with nothing in any track is a stretch the compositor is
		// never asked about — so the card saying the file is missing would
		// never be drawn.
		var stretches: [(start: Double, end: Double)] = []
		let carried = (resolved.cards.map { (start: $0.start, end: $0.end) }
			+ missing.map { (start: $0.range.start.seconds, end: $0.range.end.seconds) })
			.sorted { $0.start < $1.start }
		for span in carried {
			// Merged, because two cards with a dissolve between them overlap,
			// and one carrier serves both: what is under a card is never seen,
			// so where one ends and the next begins is nothing.
			if let last = stretches.last, span.start <= last.end + 1e-6 {
				stretches[stretches.count - 1].end = max(last.end, span.end)
			} else {
				stretches.append(span)
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
		// A typed line's clicks come in here as an ordinary sound, so they get
		// the lane allocation and the mix every other sound gets rather than a
		// second arrangement of their own. Sorted in with the rest, because the
		// lane allocator above looks at what it laid last.
		let withClicks = (resolved.sounds + typingClicks(resolved)).sorted { $0.start < $1.start }
		for sound in withClicks {
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
		guard sawVideo || !resolved.cards.isEmpty || !missing.isEmpty else {
			throw RenderError.noVideo
		}

		let overlays = OverlayLayers.build(resolved, size: size, host: host)

		// The effects are drawn into the frame here, in the same pass as the
		// grade — they are pixels, not layers, and a layer tree cannot hold
		// three hundred lit slips of card tumbling in depth.
		let effects: [(overlay: ResolvedOverlay, effect: Effect, renderer: EffectRenderer)] =
			resolved.overlays.compactMap { shown in
				guard case .effect(let effect) = shown.overlay.kind,
				      let renderer = EffectRenderer(effect, keys: shown.overlay.keys, size: size)
				else { return nil }
				return (shown, effect, renderer)
			}
		// Asked for only when something wants to go behind somebody.
		let people = resolved.overlays.contains { $0.overlay.behind == .people } ? PersonMask() : nil

		// Nothing to filter? Then do not filter.
		//
		// Core Image's pass costs a decode and an encode per frame, and used to
		// be thought to cost colour — the seven or eight levels that "washed
		// out" meant. Re-measured against the source frame, the pass as it
		// stands is not the eight levels: a fifth of a level on the mean at
		// worst, which is the HEVC re-encode rather than the pass. What is left
		// is time. Still not worth paying: a programme with no grade and no
		// effects, at the size it was shot, has nothing for that pass to *do*,
		// and AVFoundation's own path hands the frames that were shot straight
		// to the encoder. A fit, when one is needed, is a transform on a layer
		// instruction, which is exact.
		let graded = grades.contains { $0.look != .none }
		let dissolves = resolved.clips.contains { $0.transition > 0 }
		let unmanaged = context()
		// Anything that goes behind somebody is painted into the frame, which
		// is the filter pass's job — so there *is* something for it to do.
		let painted = resolved.overlays.contains { $0.overlay.behind == .people }
		// Film mode, the aberration and the tape are the picture, changed.
		// Without this the programme would take the exact path — which is the
		// one that does nothing at all.
		let filmed = resolved.overlays.contains { $0.overlay.kind.changesTheFrame }
		// A card has no source frame, so there is nothing for either of the
		// two cheap paths to hand back or to filter: only the compositor can
		// make a frame out of nothing. A project with no cards pays nothing for
		// this — it is one array being empty.
		let cards = !resolved.cards.isEmpty
		// A shot whose recording is missing is a card in the only way that
		// matters here: there is no source frame, and what plays instead has to
		// be made rather than filtered. The cheap paths hand back what the
		// track has, which where a recording is missing is nothing at all —
		// so the card saying which file it was would never be drawn, and what
		// somebody would see is the black stretch this was meant to replace.
		let holes = !missing.isEmpty
		// A treatment moves the picture into a rectangle, which is a frame that
		// is not the frame that was shot — so neither of the cheap paths can
		// serve it. One array being empty, as above.
		let treated = resolved.clips.filter { !$0.presentations.isEmpty }
		if !graded, effects.isEmpty, !painted, !dissolves, !filmed, !cards, !holes,
		   treated.isEmpty {
			let plainComposition = AVMutableVideoComposition(propertiesOf: composition)
			declareColour(on: plainComposition)
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
			             audioMix: audioMix(liveAudio, levels: levels, ramps: ramps, clips: resolved.clips,
			                              lanes: clipLanes, duration: resolved.duration,
			                              silences: gaps,
			                              sounds: liveSounds))
		}

		// A dissolve needs two frames at once, and only the compositor can hold
		// two. Everything else goes through Core Image, which is where it has
		// always gone — and, measured against the footage, comes out with the
		// numbers it went in with. The compositor's own frames come out about
		// three quarters of a level *darker* on the mean, not the three per cent
		// lifted this used to claim: an extra generation of chroma, and worth it
		// for a dissolve rather than for a programme of straight cuts.
		guard dissolves || cards || holes else {
			// Made once and captured, rather than rebuilt per frame: it is the
			// same work for every frame, and the treated clips are now looked
			// up in it.
			let work = ProgrammeCompositor.Work(
				size: size, project: resolved.project, baseURL: resolved.baseURL,
				overlays: resolved.overlays,
				effects: effects.map { ($0.overlay, $0.renderer) },
				people: people, treated: treated, stills: stills)
			let filtered = AVMutableVideoComposition(asset: composition) { request in
				let time = request.compositionTime.seconds
				let look = grades.last { time >= $0.start - 1e-6 && time < $0.end + 1e-6 }?.look ?? .none
				// A held frame stands in for the filler in the track. Graded
				// the same way, because a hold is part of the shot it stopped.
				var image: CIImage
				if let held = work.still(at: time) {
					image = Grading.apply(look, to: held)
				} else {
					image = Grading.apply(look, to: request.sourceImage)
					image = image.transformed(by: Grading.fit(image.extent, into: size))
				}
				image = Frame.picture(image, into: work.picture(at: time), size: size)
				image = Frame.overlays(over: image, at: time, size: size, work: work)
				// Unmanaged, and ``context()`` says why — which is not the reason
				// this comment used to give. AVFoundation owns the buffer here,
				// so the day management goes on it is the context's
				// `outputColorSpace` that has to name the destination: there is
				// nowhere to pass one.
				request.finish(with: image, context: unmanaged)
			}
			declareColour(on: filtered)
			filtered.renderSize = size
			filtered.frameDuration = CMTime(
				value: 1, timescale: CMTimeScale(max(1, output.framesPerSecond.rounded())))
			return Built(composition: composition, videoComposition: filtered,
			             overlays: overlays,
			             audioMix: audioMix(liveAudio, levels: levels, ramps: ramps, clips: resolved.clips,
			                              lanes: clipLanes, duration: resolved.duration,
			                              silences: gaps,
			                              sounds: liveSounds))
		}

		let session = ProgrammeCompositor.register(ProgrammeCompositor.Work(
			size: size, project: resolved.project, baseURL: resolved.baseURL,
			overlays: resolved.overlays,
			effects: effects.map { ($0.overlay, $0.renderer) }, people: people,
			treated: treated, stills: stills))

		let videoComposition = AVMutableVideoComposition()
		videoComposition.customVideoCompositorClass = ProgrammeCompositor.self
		declareColour(on: videoComposition)
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
		             audioMix: audioMix(liveAudio, levels: levels, ramps: ramps, clips: resolved.clips,
			                              lanes: clipLanes, duration: resolved.duration,
			                              silences: gaps,
			                              sounds: liveSounds))
	}

	/// What colour the film is — said once, and said the same on every path.
	///
	/// Left unsaid, AVFoundation infers it from the footage, and the answer it
	/// infers is the widest thing it can find. One iPhone clip in a project of
	/// twenty exported the whole film as HLG BT.2020: every player that is not
	/// HDR-aware showed all of it washed out, and the Rec. 709 clips in it were
	/// flattened into HLG's range on the way in — measured at a hundred and
	/// eighty where the footage said two hundred and forty-seven. Adding a
	/// single card to that same project moved it onto the compositor, which
	/// *does* say 709, and the same footage came out a different colour again.
	///
	/// Three paths cannot hold three opinions about what colour the film is,
	/// and the one that decides must not be "which features does this project
	/// happen to use". Rec. 709 is the answer here: this program writes an SDR
	/// film that every player shows the same way, so a wider source is
	/// converted into it rather than reinterpreted — which is a conversion
	/// AVFoundation does correctly once it has been told where to land.
	private static func declareColour(on composition: AVMutableVideoComposition) {
		composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
		composition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
		composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
	}

	/// The one Core Image context every pass that makes a frame uses, and the
	/// reason colour management is off in it.
	///
	/// There were three of these, in three files, each with its own half of the
	/// same story written above it. One place now, because the story is one
	/// story and it has been measured twice.
	///
	/// **What was believed.** That management could not be turned on: measured
	/// against the same frame of the same footage, a managed pass came back
	/// seven or eight levels lifted right across, which is what "washed out"
	/// was. So `workingColorSpace` was set to null everywhere, which switches
	/// off every conversion Core Image would do — and made the arithmetic
	/// correct only because *everything* in the pipe then happens to be raw
	/// Rec. 709 code values.
	///
	/// **What is true.** Management was never the problem; the destination was.
	/// A frame arriving from AVFoundation is tagged 709 and its space is the
	/// profile Core Video builds from those tags, which is called HDTV — and
	/// `CGColorSpace(name: .itur_709)`, the constant anybody reaches for, is a
	/// *different* profile with a different curve. Measured on a 0…255 ramp
	/// through one pass, worst error in levels:
	///
	///     working             destination                    worst
	///     linear sRGB         sRGB                              11
	///     linear sRGB         itur_709                          19
	///     linear sRGB         the space the frame arrived in     0
	///     that space          that space                        0
	///
	/// So the round trip comes home exactly, and always could have. The eight
	/// levels were a pass landing in the wrong 709. Turned on that way and
	/// measured end to end — a 709 shot and an HLG shot, through the filtering
	/// path and through the compositor — every rendered frame came out *byte
	/// identical* to the unmanaged render it replaced. ``ColourPassTests`` holds
	/// those numbers so that the next person to try this starts from the
	/// answer rather than from the eight levels.
	///
	/// **Why it is still off.** Because of the colour this program *paints*. A
	/// managed pass converts a `CIColor` out of sRGB and into the film, and the
	/// Core Animation pass that draws a caption or a scene does not: measured on
	/// one rendered file, `#808080` came out at 116 as a card's fill and at 127
	/// as a scene's shape. One hex, two colours in one film — which is the same
	/// class of fault as three render paths holding three opinions about what
	/// colour the film is, and no better for being the correct half of it that
	/// moved. Off, everything painted agrees at 127, by accident.
	///
	/// So this waits on the painted colour being declared too — ``RGBA/ciColor``
	/// naming the space it is in, and the layer pass agreeing — and then it is
	/// two lines and a table of zeroes. It is also the first thing an HDR mode
	/// needs: raw-code-value arithmetic works only while everything in the pipe
	/// is one space, and a wider film is a second one.
	static func context() -> CIContext {
		CIContext(options: [.workingColorSpace: NSNull()])
	}

	/// One black frame in a file, for a card to hold its place with.
	///
	/// Written once per size into the temporary folder and reused: it is a
	/// single frame, it is the same frame every time, and a render that writes
	/// it again on every build is a render that writes a file to throw it away.
	/// Nothing ever looks at the pixels — the compositor paints the card's own
	/// fill over them — so the only thing that matters about this file is that
	/// it exists and has a frame in it.
	/// One folder per launch for the black movies cards are carried on.
	///
	/// **Per launch, and that is the point.** These were kept under fixed names
	/// in the temporary directory and reused by every later run, which made a
	/// bad one permanent: a render of a card-only programme failed with `Cannot
	/// Decode` every time, for ever, because of a file written by a process
	/// that no longer existed. It cost an afternoon to find, and the thing that
	/// made it so expensive is that nothing in the failure mentions a cached
	/// file, or a card, or a name anybody could have deleted.
	///
	/// The one on this machine read as a perfectly good two-second h.264 movie
	/// to every tool that looked at it — same codec, profile, level, pixel
	/// format, frame count and duration as a fresh one, and `AVAssetReader`
	/// read samples out of it happily. Only the exporter refused it. So a check
	/// before use cannot be trusted to tell a good one from a bad one, and the
	/// answer is to stop keeping them: within a run the cache still saves the
	/// work, and no run inherits another's.
	private static let carrierFolder: URL = {
		let folder = FileManager.default.temporaryDirectory
			.appendingPathComponent("cuttr-cards-\(UUID().uuidString)", isDirectory: true)
		try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		return folder
	}()

	/// Where the carrier for this shape and length is kept, for this run.
	///
	/// Internal so the tests can put a bad one there, which is the whole of
	/// what went wrong: see ``carrier(size:seconds:framesPerSecond:)``.
	static func carrierURL(size: CGSize, frames: Int, rate: Double) -> URL {
		carrierFolder.appendingPathComponent(
			"\(Int(size.width))x\(Int(size.height))-\(frames)@\(Int(rate)).mov")
	}

	static func carrier(
		size: CGSize, seconds: Double, framesPerSecond: Double
	) async throws -> (asset: AVURLAsset, track: AVAssetTrack)? {
		let rate = max(1, framesPerSecond.rounded())
		let frames = max(1, Int((seconds * rate).rounded(.up)))
		let url = carrierURL(size: size, frames: frames, rate: rate)
		// Kept for the run, because writing it again for every card of the same
		// shape is a second of black nobody sees, and a preview rebuilds on
		// every edit.
		//
		// Existence is enough *because* the folder is this launch's: the only
		// process that has ever written there is this one, and it does so by
		// moving a whole file into place.
		//
		// There was a check here that opened the file and read a sample out of
		// it, to catch a carrier that was there and would not play. It had to
		// go: a synchronous `AVAssetReader` on the way into every build stalled
		// the window for about a second on every edit — a worse bug than the one
		// it was guarding, and one somebody feels rather than reads about. The
		// per-launch folder is what makes the check unnecessary; keeping both
		// was paying for the same guarantee twice.
		if !FileManager.default.fileExists(atPath: url.path) {
			// Written under a name nobody looks for and moved into place when
			// it is whole, so a process that dies mid-write leaves a stray
			// temporary file rather than a poisoned one.
			let building = url.deletingLastPathComponent().appendingPathComponent(
				".\(url.lastPathComponent).\(UUID().uuidString)")
			defer { try? FileManager.default.removeItem(at: building) }
			let writer = try AVAssetWriter(outputURL: building, fileType: .mov)
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
			guard writer.status == .completed else { return nil }
			// Into place in one step. Two processes doing this at once both end
			// up with a whole file, which is the other half of why it is done
			// this way round.
			try? FileManager.default.removeItem(at: url)
			try FileManager.default.moveItem(at: building, to: url)
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
	/// The clicks every typed line in the programme makes.
	///
	/// Worked out here rather than in the resolver because it writes files, and
	/// resolving is meant to be arithmetic on what the project says. What comes
	/// back is an ordinary ``ResolvedSound`` per line, which is what lets the
	/// lane allocation and the mix below treat it as one more sound.
	///
	/// The moments are the scene's own — `resolved.start` is where the scene's
	/// clock begins, which is the same offset ``Frame`` subtracts before asking
	/// a scene what it looks like — so a click lands on the frame its character
	/// does.
	static func typingClicks(_ resolved: ResolvedProject) -> [ResolvedSound] {
		var out: [ResolvedSound] = []
		for shown in resolved.overlays {
			guard case .scene(let name, let parameters) = shown.overlay.kind,
			      let scene = resolved.project.scene(named: name, with: parameters)
			else { continue }
			for part in scene.parts {
				guard case .text(let text, _, _, let typed) = part.content,
				      let typed, typed.click > 0
				else { continue }
				let words = Scene.fill(text, with: parameters)
				// One per character that lands, and not the moment the part
				// starts — which `moments` reports as the count it opens on,
				// and which is nothing being typed.
				let landings = typed.moments(of: words, keys: part.keys)
					.filter { $0.shown > 0 }
					.map(\.t)
				guard !landings.isEmpty,
				      let url = TypingSound.file(
						clicking: landings, level: min(1, typed.click),
						into: TypingSound.folder)
				else { continue }
				let last = (landings.last ?? 0) + 0.25
				out.append(ResolvedSound(
					sound: Sound(file: url.path, span: nil, gain: 0,
					             arrival: .cut, departure: .cut, ducks: 0),
					origin: shown.origin, url: url,
					start: shown.start, end: min(shown.end, shown.start + last)))
			}
		}
		return out
	}

	/// How long before a clip begins its level is put on its lane.
	///
	/// The audio renderer — export and player both — does not step a volume:
	/// a change written at one moment is smoothed across roughly the next
	/// render buffer, which was measured at about a hundred and ninety
	/// milliseconds. A change written this far ahead of the cut, on a lane
	/// carrying nothing at the time, has settled before anything is heard
	/// through it. Three hundred was the shortest lead that came out clean;
	/// a hundred still let a quarter of the old level through.
	public static let settling = 0.3

	private static func audioMix(
		_ tracks: [(lane: Int, track: AVMutableCompositionTrack)],
		levels: [(track: Int, at: CMTime, volume: Float)],
		ramps: [(track: Int, start: Double, end: Double, from: Float, to: Float)] = [],
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

		/// Where a move stands at a moment of itself.
		func along(_ move: (start: Double, end: Double, from: Float, to: Float),
		           at when: Double) -> Float {
			let span = move.end - move.start
			guard span > 0 else { return move.to }
			let part = Float(min(max((when - move.start) / span, 0), 1))
			return move.from + (move.to - move.from) * part
		}

		/// Writes a lane out, turning every held level into a flat ramp that
		/// runs as far as the next thing that happens on that lane — and
		/// deciding, where two instructions land on the same stretch, which of
		/// them is heard there.
		///
		/// The deciding is not tidiness. `setVolumeRamp` raises an
		/// Objective-C exception the moment two ramps overlap, and an
		/// Objective-C exception out of a build takes the whole window with it:
		/// a duck fading back up across a dissolve was a crash, not a mix
		/// anybody could argue with. Ramps that merely *begin* together are
		/// accepted — silently, one replacing the other — which is worse than
		/// the crash, because which of the two survived was down to the order a
		/// sort happened to leave them in.
		///
		/// So the lane is swept rather than written straight out. At every
		/// moment the instruction that started last is the one heard, for as
		/// long as it runs; what it interrupted is heard again after it, from
		/// where it had got to by then. A dissolve laid over a hold therefore
		/// does the dissolve and then holds, which is what both of them were
		/// asking for.
		func write(_ lane: Lane, to input: AVMutableAudioMixInputParameters) {
			// The holds first and the moves after them, because the sweep reads
			// the order as the tie: a dissolve and the level it dissolves from
			// both begin at the cut, and the dissolve is the one that was asked
			// for there.
			var instructions: [(start: Double, end: Double, from: Float, to: Float)] = []
			let changes = (lane.moves.map(\.start) + lane.steps.map(\.at)).sorted()
			for step in lane.steps {
				let next = changes.first { $0 > step.at + 1e-6 } ?? end
				instructions.append((step.at, next, step.volume, step.volume))
			}
			// Silent until the first thing happens: a lane carries only what was
			// laid on it, and what is between must not be heard.
			if let first = changes.first, first > 0 {
				instructions.append((0, first, 0, 0))
			}
			instructions.append(contentsOf: lane.moves)

			// In the order they win: later beats earlier, and at the same
			// moment the one written later here beats the one written before.
			let ordered = instructions.enumerated()
				.filter { $0.element.end > $0.element.start }
				.sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }
			guard !ordered.isEmpty else { return }

			// Every moment anything starts or stops. Two of them a whisker
			// apart are one: the times are seconds of somebody's timeline, and
			// a stretch too short to have a frame in it is not a stretch.
			var edges: [Double] = []
			for edge in ordered.flatMap({ [$0.element.start, $0.element.end] }).sorted()
			where edges.last.map({ edge - $0 > 1e-6 }) ?? true {
				edges.append(edge)
			}

			/// What is heard across a stretch nothing else interrupts: of
			/// everything covering it, whichever started last.
			func heard(from: Double, to: Double) -> (start: Double, end: Double,
			                                         from: Float, to: Float)? {
				ordered.last {
					$0.element.start <= from + 1e-6 && $0.element.end >= to - 1e-6
				}?.element
			}

			// Written as one ramp per run of the same instruction rather than
			// one per stretch: a move cut in two by something inside it is the
			// same straight line either side, and a mix that says so is a mix
			// somebody can read.
			var pending: (move: (start: Double, end: Double, from: Float, to: Float),
			              start: Double, end: Double)?
			func flush() {
				guard let done = pending else { return }
				pending = nil
				let range = CMTimeRange(start: time(done.start),
				                        duration: time(done.end - done.start))
				guard range.duration > .zero else { return }
				input.setVolumeRamp(
					fromStartVolume: along(done.move, at: done.start),
					toEndVolume: along(done.move, at: done.end),
					timeRange: range)
			}
			for (index, from) in edges.dropLast().enumerated() {
				let to = edges[index + 1]
				guard let move = heard(from: from, to: to) else { flush(); continue }
				if var carrying = pending, carrying.move == move {
					carrying.end = to
					pending = carrying
				} else {
					flush()
					pending = (move, from, to)
				}
			}
			flush()
		}

		/// What a lane is set to at a moment, before anything ducks it.
		///
		/// A curved clip has no step to read, so its ramps answer instead — at
		/// the point along the ramp the question is about, since the whole of
		/// what a curve says is that the answer is different a second later.
		func level(_ lane: Int, at when: Double) -> Float {
			if let move = ramps.last(where: {
				$0.track == lane && $0.start <= when + 1e-6 && $0.end >= when - 1e-6
			}) {
				let span = move.end - move.start
				guard span > 0 else { return move.to }
				return move.from + (move.to - move.from) * Float((when - move.start) / span)
			}
			return levels.last { $0.track == lane && $0.at.seconds <= when + 1e-6 }?.volume ?? 0
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
			let curved = ramps.filter { $0.track == lane }
			guard !mine.isEmpty || !curved.isEmpty else { continue }
			var built = Lane()

			for step in mine {
				if step.volume != 1 { wanted = true }
				built.steps.append((step.at.seconds, step.volume * duck(at: step.at.seconds)))
			}

			// Each clip's opening level, put on the lane *before* the clip
			// begins — while the lane is carrying nothing, so nobody hears the
			// change happen. The renderer smooths every change of volume over
			// about a fifth of a second (see where the tracks are made), which
			// at a cut means the outgoing shot's level bleeding over the top of
			// the incoming one. Set in the gap, there is nothing to bleed.
			//
			// A shot dissolving in is put at nought instead, since that is
			// where its fade begins. Where the gap is shorter than the settling
			// — a shot between them shorter than that — the change is a ramp
			// across what gap there is, which is the best that can be done.
			var previous: ResolvedClip?
			for (index, clip) in clips.enumerated()
			where (index < lanes.count ? lanes[index] : index % 2) == lane {
				defer { previous = clip }
				let since = max(previous?.end ?? 0, clip.start - settling)
				guard since < clip.start - 1e-6 else { continue }
				let opening: Float = clip.transition > 0 ? 0
					: Float(Levelling.amplitude(clip.level(at: clip.start))) * duck(at: clip.start)
				if let previous, previous.end > clip.start - settling + 1e-6 {
					let closing = Float(Levelling.amplitude(previous.level(at: previous.end)))
						* duck(at: previous.end)
					if closing != opening { wanted = true }
					built.moves.append((since, clip.start, closing, opening))
				} else {
					if opening != 1 { wanted = true }
					built.steps.append((since, opening))
				}
			}

			// The gain curves, which arrive as moves already: a clip whose take
			// carries one asked for a level that changes, and this is the only
			// place in the programme where a level changes *within* a shot.
			for move in curved {
				wanted = true
				built.moves.append((move.start, move.end,
				                    move.from * duck(at: move.start),
				                    move.to * duck(at: move.end)))
			}

			// The dissolves: the outgoing lane down, the incoming lane up, over
			// exactly the overlap.
			for (index, clip) in clips.enumerated() where clip.transition > 0 && index > 0 {
				wanted = true
				let under = duck(at: clip.start)
				// Each clip's level *at the dissolve*, not its flat figure: a
				// take with a curve on it is a different level a second later,
				// and the two ends of a crossfade are the two levels there.
				let up = Float(Levelling.amplitude(clip.level(at: clip.start))) * under
				let down = Float(Levelling.amplitude(
					clips[index - 1].level(at: clip.start))) * under
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

	/// What a stretch with no recording behind it plays instead: pink, and the
	/// name of the file that is not there.
	///
	/// Pink because nothing in a programme is this colour by accident. Black
	/// would be a shot of a dark room, a dropped frame, or a fade — three
	/// things somebody would look for a fault in before thinking of the card
	/// reader they never plugged in. And it says *which* file, because the
	/// question a hole in a programme asks is always "which one".
	static func missingPicture(_ url: URL, size: CGSize) -> CIImage {
		let frame = CGRect(origin: .zero, size: size)
		var image = CIImage(color: CIColor(red: 0.93, green: 0.16, blue: 0.53))
			.cropped(to: frame)
		let lines = [(text: "missing media", size: 0.07, at: 0.56),
		             (text: url.lastPathComponent, size: 0.032, at: 0.44)]
		for line in lines {
			let style = TextStyle(
				font: "Helvetica Neue Bold", size: line.size, color: .white,
				background: RGBA(r: 0, g: 0, b: 0, a: 0), padding: 0, cornerRadius: 0,
				position: CGPoint(x: 0.5, y: line.at), alignment: .centre)
			let (layer, plate) = OverlayLayers.textLayer(line.text, style: style, size: size)
			guard let contents = layer.contents,
			      CFGetTypeID(contents as CFTypeRef) == CGImage.typeID
			else { continue }
			// swiftlint:disable:next force_cast
			let drawn = CIImage(cgImage: contents as! CGImage)
			guard drawn.extent.width > 0, drawn.extent.height > 0 else { continue }
			image = drawn
				.transformed(by: CGAffineTransform(scaleX: plate.width / drawn.extent.width,
				                                   y: plate.height / drawn.extent.height))
				.transformed(by: CGAffineTransform(
					translationX: (size.width - plate.width) / 2,
					y: size.height * line.at - plate.height / 2))
				.composited(over: image)
		}
		return image
	}

	/// One frame of a recording, fitted to the output, for a hold to stand on.
	///
	/// `.zero` tolerance at both ends: the frame this returns is the frame the
	/// programme was on when it stopped, and a generator left to its own
	/// devices answers with the nearest keyframe — which on a long-GOP screen
	/// recording can be a second and a half away.
	private static func still(of asset: AVAsset, at seconds: Double,
	                          size: CGSize) async throws -> CIImage? {
		// The guard a card-only project needed: a generator over an asset with
		// no video track raises an Objective-C exception rather than throwing.
		guard try await !asset.loadTracks(withMediaType: .video).isEmpty else { return nil }
		let generator = AVAssetImageGenerator(asset: asset)
		generator.appliesPreferredTrackTransform = true
		generator.requestedTimeToleranceBefore = .zero
		generator.requestedTimeToleranceAfter = .zero
		let (frame, _) = try await generator.image(
			at: CMTime(seconds: seconds, preferredTimescale: 600))
		let image = CIImage(cgImage: frame)
		return image.transformed(by: Grading.fit(image.extent, into: size))
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
		let drawsOver = resolved.overlays.contains {
			OverlayLayers.isLayered($0.overlay, in: resolved.project)
		}

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
