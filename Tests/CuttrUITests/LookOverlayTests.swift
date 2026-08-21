@preconcurrency import AVFoundation
import AppKit
import Testing
@testable import CuttrCompose
@testable import CuttrUI

/// What is drawn over a look, measured in pixels rather than believed from the
/// code.
///
/// A look played the programme bare: the cut, the grade and the effects arrived
/// because they are in the composition, and every caption, spinner, scene and
/// bubble was missing because those are a `CALayer` tree over the *window's*
/// player and the look has a player of its own. Believing a fix to that from the
/// code is how it shipped broken the first time, so this suite takes the tree the
/// panel is actually holding, draws it into a file, and looks at what came out.
@MainActor @Suite struct LookOverlayTests {

	/// A programme of one black card, with a spinner on for the middle of it.
	///
	/// A spinner rather than a caption because it is the case that cannot be
	/// faked: it is on for a stretch, it turns while it is on, and a still of it
	/// is only white where the dots are.
	private func programme(withSpinner: Bool) throws -> (Project, ResolvedProject) {
		let project = try ProjectReader.read("""
			output:
			  size: 640x360
			  fps:  25
			  file: look.mov

			timeline:
			  - card: 00:02.000
			    fill: "#000000"
			\(withSpinner ? """

			overlays:
			  - spinner: dots
			    size:    0.5
			    from:    00:00.500
			    to:      00:01.500
			""" : "")
			""")
		let resolved = try Resolver.resolve(
			project, baseURL: URL(fileURLWithPath: NSTemporaryDirectory()))
		return (project, resolved)
	}

	/// The look, taken from the tree, with the programme the window has built.
	private func look(_ project: Project, _ resolved: ResolvedProject,
	                  playing built: Renderer.Built) -> ProgrammePanel {
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 820),
		                      styleMask: [.titled], backing: .buffered, defer: true)
		let panel = ProgrammePanel(frame: NSRect(x: 0, y: 0, width: 440, height: 820))
		window.contentView?.addSubview(panel)
		panel.resolved = resolved
		panel.reload(project, vocabulary: ComposeDocument.Vocabulary())
		panel.playable = { (built.composition, built.videoComposition, built.audioMix,
		                    resolved.duration) }
		panel.selectRow(0)
		panel.showLook()
		return panel
	}

	/// How much of a frame is bright enough to be a white dot on black.
	private func ink(in url: URL, at seconds: Double) async throws -> Int {
		let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
		generator.requestedTimeToleranceBefore = .zero
		generator.requestedTimeToleranceAfter = .zero
		let image = try await generator.image(
			at: CMTime(seconds: seconds, preferredTimescale: 600)).image
		let width = image.width, height = image.height
		var pixels = [UInt8](repeating: 0, count: width * height * 4)
		let context = CGContext(data: &pixels, width: width, height: height,
		                        bitsPerComponent: 8, bytesPerRow: width * 4,
		                        space: CGColorSpaceCreateDeviceRGB(),
		                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
		context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
		return stride(from: 0, to: pixels.count, by: 4).count { pixels[$0] > 140 }
	}

	/// Draws one layer tree over a finished film, the way an export's second
	/// pass does.
	///
	/// The tree is the *panel's own*, taken off the panel and handed to
	/// `AVVideoCompositionCoreAnimationTool` — which is the only way to get a
	/// layer tree into a file and therefore the only way to photograph one. What
	/// this measures is consequently the exact object the look is holding over
	/// its picture, at the exact moments the animations in it are meant to be
	/// doing something.
	private func draw(_ tree: CALayer, over source: URL, to url: URL,
	                  size: CGSize, duration: Double) async throws {
		let asset = AVURLAsset(url: source)
		let videoComposition = try await AVMutableVideoComposition
			.videoComposition(withPropertiesOf: asset)
		videoComposition.renderSize = size
		videoComposition.frameDuration = CMTime(value: 1, timescale: 25)
		let track = try await asset.loadTracks(withMediaType: .video).first
		let trackID = (track?.trackID ?? 1) &+ 1
		tree.frame = CGRect(origin: .zero, size: size)
		videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
			additionalLayer: tree, asTrackID: trackID)
		if let source = track {
			let instruction = AVMutableVideoCompositionInstruction()
			instruction.timeRange = CMTimeRange(
				start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 600))
			let over = AVMutableVideoCompositionLayerInstruction()
			over.trackID = trackID
			instruction.layerInstructions = [
				over, AVMutableVideoCompositionLayerInstruction(assetTrack: source),
			]
			instruction.enablePostProcessing = true
			videoComposition.instructions = [instruction]
		}
		let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality)!
		session.videoComposition = videoComposition
		try await session.export(to: url, as: .mov)
	}

	/// **The one that matters.** A spinner that is on at that moment is in the
	/// look.
	///
	/// Taken the whole way: the tree resolves, the panel takes a look at the
	/// card, the tree the panel is holding over its picture is drawn into a file,
	/// and the file is decoded and counted. White where the dots are while the
	/// spinner is on, and nothing at all half a second before it arrives —
	/// which is the second half of the claim, because a tree that painted
	/// something over every frame would pass the first half.
	@Test func aSpinnerThatIsOnAppearsInTheLook() async throws {
		let folder = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("cuttr-look-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: folder) }

		// The picture on its own, which is what the look plays: a card is a
		// frame with no footage in it, and the spinner is not in the file.
		let (_, bareResolved) = try programme(withSpinner: false)
		let card = folder.appendingPathComponent("card.mov")
		try await Renderer.export(bareResolved, to: card)

		let (project, resolved) = try programme(withSpinner: true)
		let built = try await Renderer.build(resolved, host: .preview)
		let panel = look(project, resolved, playing: built)
		let tree = try #require(panel.lookOverlayTreeForTesting,
		                        "the look is holding nothing over its picture")
		panel.closeLook()
		tree.removeFromSuperlayer()

		let drawn = folder.appendingPathComponent("drawn.mov")
		try await draw(tree, over: card, to: drawn,
		               size: CGSize(width: 640, height: 360), duration: resolved.duration)

		#expect(try await ink(in: card, at: 1) == 0, "the card itself is black")
		#expect(try await ink(in: drawn, at: 1) > 40, "no spinner in the look")
		#expect(try await ink(in: drawn, at: 0.2) == 0, "a spinner up before its span")
		#expect(try await ink(in: drawn, at: 1.9) == 0, "a spinner still up after its span")
	}

	/// And it is on the player's own clock, which is what makes it turn with the
	/// picture rather than beside it.
	///
	/// `AVSynchronizedLayer` is the mechanism: the tree the look holds is
	/// synchronised to the very item the look is playing. The alternative the
	/// composing window uses — a tree held still and stepped from playback ticks
	/// — is right for a preview somebody is scrubbing and wrong for four seconds
	/// of playback, which is two clocks and a spinner that stutters.
	@Test func theOverlaysRunOnTheItemTheLookIsPlaying() async throws {
		let (project, resolved) = try programme(withSpinner: true)
		let built = try await Renderer.build(resolved, host: .preview)
		let panel = look(project, resolved, playing: built)
		defer { panel.closeLook() }
		#expect(panel.lookOverlayTreeForTesting != nil)
		let item = try #require(panel.lookOverlayItemForTesting)
		#expect(item.asset === built.composition,
		        "synchronised to something other than what is playing")
	}

	/// One builder, three callers. The look's tree and the export's are built by
	/// the same function from the same resolved programme, so they hold the same
	/// overlays — which is the whole reason the look is worth taking.
	@Test func theLookAndTheExportDrawTheSameOverlays() throws {
		let (_, resolved) = try programme(withSpinner: true)
		func leaves(_ layer: CALayer) -> Int {
			(layer.sublayers ?? []).reduce(1) { $0 + leaves($1) }
		}
		let look = QuickLook.overlays(for: resolved)
		let export = OverlayLayers.build(resolved, size: resolved.project.output.size,
		                                 host: .export)
		#expect(leaves(look) == leaves(export))
		#expect(leaves(look) > 1, "an empty tree would agree with anything")
	}

	/// Nothing over a programme is an empty tree rather than no tree: the panel
	/// is handed one either way, and the difference between "nothing to draw"
	/// and "nothing was built" is not something to leave to a `nil`.
	@Test func aProgrammeWithNothingOverItGetsAnEmptyTree() throws {
		let (_, resolved) = try programme(withSpinner: false)
		let tree = QuickLook.overlays(for: resolved)
		#expect(tree.sublayers?.isEmpty != false)
	}

	/// The tree is scaled onto the picture and not onto the view.
	///
	/// A 16:9 programme in a panel that is not quite 16:9 is letterboxed by the
	/// player, and overlays laid over the view instead of over the picture would
	/// put a lower third somewhere the file will not have it.
	@Test func theOverlaysSitExactlyOverThePicture() {
		let output = NSSize(width: 1920, height: 1080)
		let square = QuickLook.picture(of: output, in: NSRect(x: 0, y: 0, width: 400, height: 400))
		#expect(square.width == 400)
		#expect(abs(square.height - 225) < 0.001)
		#expect(abs(square.midY - 200) < 0.001, "not centred in the letterbox")

		let exact = QuickLook.picture(of: output, in: NSRect(x: 0, y: 0, width: 640, height: 360))
		#expect(exact == NSRect(x: 0, y: 0, width: 640, height: 360))
	}
}
