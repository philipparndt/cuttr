@preconcurrency import AVFoundation
import CoreGraphics
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
		var instructions: [AVMutableVideoCompositionInstruction] = []
		var cursor = CMTime.zero
		var sawVideo = false

		for clip in resolved.clips {
			let at = CMTime(seconds: clip.start, preferredTimescale: scale)
			let range = CMTimeRange(
				start: CMTime(seconds: clip.clip.start, preferredTimescale: scale),
				duration: CMTime(seconds: clip.duration, preferredTimescale: scale))

			var transform = CGAffineTransform.identity
			if let videoURL = clip.videoURL {
				let asset = AVURLAsset(url: videoURL)
				if let source = try await asset.loadTracks(withMediaType: .video).first {
					try? videoTrack.insertTimeRange(range, of: source, at: at)
					let (natural, preferred) = try await source.load(.naturalSize, .preferredTransform)
					transform = fit(natural: natural, preferred: preferred, into: size)
					sawVideo = true
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

			let instruction = AVMutableVideoCompositionInstruction()
			instruction.timeRange = CMTimeRange(start: at, duration: range.duration)
			let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
			layer.setTransform(transform, at: at)
			instruction.layerInstructions = [layer]
			instructions.append(instruction)
			cursor = at + range.duration
		}

		guard sawVideo else { throw RenderError.noVideo }

		let videoComposition = AVMutableVideoComposition()
		videoComposition.renderSize = size
		videoComposition.frameDuration = CMTime(
			value: 1, timescale: CMTimeScale(max(1, output.framesPerSecond.rounded())))
		videoComposition.instructions = instructions

		let overlays = OverlayLayers.build(resolved, size: size, host: host)
		if host == .export {
			// The tool wants two layers: the video, and a parent to draw it
			// into. They must not be in any live layer tree, which is why the
			// preview builds its own tree rather than borrowing this one.
			let videoLayer = CALayer()
			videoLayer.frame = CGRect(origin: .zero, size: size)
			let parent = CALayer()
			parent.frame = CGRect(origin: .zero, size: size)
			parent.addSublayer(videoLayer)
			parent.addSublayer(overlays)
			videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
				postProcessingAsVideoLayer: videoLayer, in: parent)
		}
		_ = cursor
		return Built(composition: composition, videoComposition: videoComposition, overlays: overlays)
	}

	/// Renders to a file.
	///
	/// `progress` is called on an unspecified thread, often, with 0…1.
	public static func export(
		_ resolved: ResolvedProject,
		to url: URL,
		progress: @escaping @Sendable (Double) -> Void = { _ in }
	) async throws {
		let built = try await build(resolved, host: .export)

		guard let session = AVAssetExportSession(
			asset: built.composition, presetName: AVAssetExportPresetHighestQuality)
		else { throw RenderError.exportFailed("no exporter for this composition") }
		session.videoComposition = built.videoComposition
		session.outputFileType = .mov
		session.outputURL = url
		session.shouldOptimizeForNetworkUse = false

		// The export refuses to start if anything is already there, rather than
		// overwriting, so the removal is ours to do — and is worth doing
		// explicitly rather than discovering as a failure ten seconds in.
		try? FileManager.default.removeItem(at: url)
		guard FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().path)
		else { throw RenderError.cannotWrite(url) }

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

	/// The transform that fits a source frame into the output frame.
	///
	/// Aspect-fit and centred, which is the only choice that never crops
	/// somebody's head off. A source already the right shape gets a scale of one
	/// and a translation of zero, so the common case costs nothing.
	static func fit(natural: CGSize, preferred: CGAffineTransform, into output: CGSize) -> CGAffineTransform {
		// What the source measures once its own rotation is applied: a portrait
		// clip from a phone declares a landscape natural size and a 90°
		// transform, and fitting the declared size would letterbox it wrongly.
		let oriented = CGRect(origin: .zero, size: natural).applying(preferred)
		let width = abs(oriented.width), height = abs(oriented.height)
		guard width > 0, height > 0 else { return preferred }
		let scale = min(output.width / width, output.height / height)
		// `preferred` may translate the frame off the origin — a 90° rotation
		// does — so the fit is measured from where the rotated frame actually
		// lands rather than from zero.
		let translated = preferred.concatenating(
			CGAffineTransform(translationX: -oriented.minX, y: -oriented.minY))
		return translated
			.concatenating(CGAffineTransform(scaleX: scale, y: scale))
			.concatenating(CGAffineTransform(
				translationX: (output.width - width * scale) / 2,
				y: (output.height - height * scale) / 2))
	}
}
