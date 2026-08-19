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
		guard let videoTrack = composition.addMutableTrack(
			withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
		else { throw RenderError.noVideo }
		let audioTrack = composition.addMutableTrack(
			withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)

		let scale: Int32 = 600
		var cursor = CMTime.zero
		var sawVideo = false
		/// What to do to each clip, looked up by time while rendering.
		var grades: [(start: Double, end: Double, look: Look)] = []
		/// Volume steps for the audio mix, one per clip.
		var levels: [(at: CMTime, volume: Float)] = []
		/// What size each clip's picture arrives at, and when — for the pass
		/// that fits without filtering.
		var pictures: [(at: CMTime, size: CGSize)] = []

		for clip in resolved.clips {
			let at = CMTime(seconds: clip.start, preferredTimescale: scale)
			let range = CMTimeRange(
				start: CMTime(seconds: clip.clip.start, preferredTimescale: scale),
				duration: CMTime(seconds: clip.duration, preferredTimescale: scale))

			grades.append((clip.start, clip.end, clip.look))
			// Linear amplitude, because that is what a mix takes. Decibels are
			// what a person reads and what the file says.
			levels.append((at, Float(pow(10, clip.gain / 20))))

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
		let effects: [(overlay: ResolvedOverlay, renderer: EffectRenderer)] =
			resolved.overlays.compactMap { shown in
				guard case .effect(let effect) = shown.overlay.kind,
				      let renderer = EffectRenderer(effect, size: size) else { return nil }
				return (shown, renderer)
			}

		// Colour management off.
		//
		// Core Image's own working space is linear with sRGB primaries, and
		// converting Rec. 709 video into it and back does not come home: the
		// picture came out six or seven levels lifted across the whole frame,
		// which reads as washed out beside the same footage in the player. With
		// management off the values pass through untouched, and the grade — a
		// gain, an exposure, a saturation — works on them as it finds them.
		let plain = CIContext(options: [.workingColorSpace: NSNull()])

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
		if !graded, effects.isEmpty {
			let plainComposition = AVMutableVideoComposition(propertiesOf: composition)
			plainComposition.renderSize = size
			plainComposition.frameDuration = CMTime(
				value: 1, timescale: CMTimeScale(max(1, output.framesPerSecond.rounded())))

			// The fit, per clip, as a step at the moment that clip starts.
			let instruction = AVMutableVideoCompositionInstruction()
			instruction.timeRange = CMTimeRange(start: .zero, duration: cursor)
			let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
			for picture in pictures {
				let fit = Grading.fit(CGRect(origin: .zero, size: picture.size), into: size)
				layer.setTransform(fit, at: picture.at)
			}
			instruction.layerInstructions = [layer]
			plainComposition.instructions = [instruction]

			return Built(composition: composition, videoComposition: plainComposition,
			             overlays: overlays, audioMix: audioMix(audioTrack, levels: levels))
		}

		let videoComposition = AVMutableVideoComposition(asset: composition) { request in
			let time = request.compositionTime.seconds
			let look = grades.last { time >= $0.start - 1e-6 && time < $0.end + 1e-6 }?.look ?? .none
			var image = Grading.apply(look, to: request.sourceImage)
			image = image.transformed(by: Grading.fit(image.extent, into: size))

			for (shown, renderer) in effects where time >= shown.start && time <= shown.end {
				// A fall-out stops letting pieces go before the end, so what is
				// already in the air has time to leave the frame.
				var spawningUntil = Double.infinity
				if case .fall(let over) = shown.overlay.departure {
					spawningUntil = max(0, shown.duration - over)
				}
				guard let plate = renderer.image(at: time - shown.start,
				                                 spawningUntil: spawningUntil) else { continue }
				let opacity = fade(shown, at: time)
				guard opacity > 0.001 else { continue }
				let faded = opacity >= 0.999 ? plate : plate.applyingFilter("CIColorMatrix", parameters: [
					"inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity),
				])
				image = faded.composited(over: image)
			}
			request.finish(with: image, context: plain)
		}
		videoComposition.renderSize = size
		videoComposition.frameDuration = CMTime(
			value: 1, timescale: CMTimeScale(max(1, output.framesPerSecond.rounded())))
		// Said out loud: the programme is Rec. 709.
		//
		// A phone shoots HLG, and a file whose pixels are HLG but whose tags say
		// nothing is shown as sRGB — flat, milky, the blacks lifted and the sky
		// gone. Naming the colour makes AVFoundation convert into it instead of
		// hoping.

		return Built(composition: composition, videoComposition: videoComposition,
		             overlays: overlays, audioMix: audioMix(audioTrack, levels: levels))
	}

	/// The mix: one parameter set over the single audio track, stepping the
	/// volume at each cut.
	///
	/// A step rather than a ramp because the cut is already a discontinuity — a
	/// crossfade of levels across it would be audible as a swell on the wrong
	/// side of the edit.
	private static func audioMix(
		_ track: AVMutableCompositionTrack?, levels: [(at: CMTime, volume: Float)]
	) -> AVAudioMix? {
		guard let track, levels.contains(where: { $0.volume != 1 }) else { return nil }
		let parameters = AVMutableAudioMixInputParameters(track: track)
		for level in levels { parameters.setVolume(level.volume, at: level.at) }
		let mix = AVMutableAudioMix()
		mix.inputParameters = [parameters]
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
		let drawsOver = !resolved.overlays.isEmpty

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
