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
		/// looks like.
		var segments: [(range: CMTimeRange, track: CMPersistentTrackID,
		                look: Look, transition: Double, blend: Transition)] = []
		/// What size each clip's picture arrives at, and when — for the pass
		/// that fits without filtering.
		var pictures: [(at: CMTime, size: CGSize)] = []

		var lane = 0
		for clip in resolved.clips {
			// The lane only changes where a dissolve needs it to. A programme of
			// straight cuts stays on one track, which is what keeps the simple
			// case simple — and exact.
			if clip.transition > 0 { lane = (lane + 1) % videoTracks.count }
			let videoTrack = videoTracks[lane]
			let audioTrack = audioTracks.indices.contains(lane) ? audioTracks[lane] : nil
			let at = CMTime(seconds: clip.start, preferredTimescale: scale)
			let range = CMTimeRange(
				start: CMTime(seconds: clip.clip.start, preferredTimescale: scale),
				duration: CMTime(seconds: clip.duration, preferredTimescale: scale))

			grades.append((clip.start, clip.end, clip.look))
			segments.append((
				CMTimeRange(start: at, duration: CMTime(seconds: clip.duration, preferredTimescale: scale)),
				videoTrack.trackID, clip.look, clip.transition, clip.blend))
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

		guard sawVideo else { throw RenderError.noVideo }

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
		if !graded, effects.isEmpty, !painted, !dissolves, !filmed {
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
			             audioMix: audioMix(audioTracks, levels: levels, clips: resolved.clips))
		}

		// A dissolve needs two frames at once, and only the compositor can hold
		// two. Everything else goes through Core Image, which is where it has
		// always gone — and, measured against the footage, comes out with the
		// numbers it went in with. The compositor's own frames arrive about
		// three per cent lifted, which is worth it for a dissolve and is not
		// worth it for a programme of straight cuts.
		guard dissolves else {
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
			             audioMix: audioMix(audioTracks, levels: levels, clips: resolved.clips))
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
					incomingLook: segment.look, session: session))
			}
		}
		videoComposition.instructions = instructions

		return Built(composition: composition, videoComposition: videoComposition,
		             session: session, overlays: overlays,
		             audioMix: audioMix(audioTracks, levels: levels, clips: resolved.clips))
	}

	/// The mix: one parameter set per audio track, stepping the volume at each
	/// cut and ramping it across a dissolve.
	///
	/// A step at a cut because the cut is already a discontinuity — a crossfade
	/// of levels across it would be audible as a swell on the wrong side of the
	/// edit. A ramp across a dissolve because there the picture is mixing too,
	/// and a hard audio cut in the middle of one is the thing everybody hears.
	private static func audioMix(
		_ tracks: [AVMutableCompositionTrack],
		levels: [(track: Int, at: CMTime, volume: Float)],
		clips: [ResolvedClip]
	) -> AVAudioMix? {
		guard !tracks.isEmpty else { return nil }
		let scale: CMTimeScale = 600
		var parameters: [AVMutableAudioMixInputParameters] = []
		var wanted = false

		for (lane, track) in tracks.enumerated() {
			let mine = levels.filter { $0.track == lane }
			guard !mine.isEmpty else { continue }
			let input = AVMutableAudioMixInputParameters(track: track)
			// Silent to begin with: a track only carries the clips laid on it,
			// and what is between them must not be heard.
			input.setVolume(0, at: .zero)
			for level in mine {
				input.setVolume(level.volume, at: level.at)
				if level.volume != 1 { wanted = true }
			}
			parameters.append(input)
		}

		// The dissolves: the outgoing lane down, the incoming lane up, over
		// exactly the overlap.
		for (index, clip) in clips.enumerated() where clip.transition > 0 && index > 0 {
			wanted = true
			let range = CMTimeRange(
				start: CMTime(seconds: clip.start, preferredTimescale: scale),
				duration: CMTime(seconds: clip.transition, preferredTimescale: scale))
			let outgoing = clips[index - 1]
			let up = Float(pow(10, clip.gain / 20)), down = Float(pow(10, outgoing.gain / 20))
			for (lane, input) in parameters.enumerated() {
				// Lanes alternate at a dissolve, so one of the two is going out
				// and the other is coming in; which is which follows from where
				// the clip was laid.
				if lane == index % 2 {
					input.setVolumeRamp(fromStartVolume: 0, toEndVolume: up, timeRange: range)
				} else {
					input.setVolumeRamp(fromStartVolume: down, toEndVolume: 0, timeRange: range)
				}
			}
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
