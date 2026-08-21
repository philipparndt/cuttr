import AppKit
import CoreGraphics
import CoreImage
import Foundation
import QuartzCore
import Testing
@testable import CuttrCompose

/// A folder of frames, put on the picture.
///
/// The part with no drawing in it, which is exactly why it is worth testing hard:
/// everything that can go wrong is arithmetic — which file, at which moment, in
/// which box — and all of it has to come out the same in both render paths.
@Suite struct FrameSequenceTests {

	private let size = CGSize(width: 400, height: 200)
	private let context = CIContext(options: [.workingColorSpace: NSNull()])

	// MARK: - Which file

	@Test func thePatternTakesTheFrameNumber() {
		#expect(FrameSequence.expand("charts/walks/%04d.png", 0) == "charts/walks/0000.png")
		#expect(FrameSequence.expand("charts/walks/%04d.png", 137) == "charts/walks/0137.png")
		#expect(FrameSequence.expand("f/%d.png", 7) == "f/7.png")
		#expect(FrameSequence.expand("f/%05d.png", 12_345) == "f/12345.png")
		// Wider than the padding, which is a sequence longer than whoever named
		// it expected. It keeps counting rather than wrapping.
		#expect(FrameSequence.expand("f/%02d.png", 1234) == "f/1234.png")
	}

	/// A pattern with no `%d` in it, and one with something that is not a frame
	/// number, are left exactly as they are — so a typo is a file that is not
	/// there rather than a surprise.
	@Test func aPatternWithNothingToFillInIsLeftAlone() {
		#expect(FrameSequence.expand("one.png", 5) == "one.png")
		#expect(FrameSequence.expand("%s.png", 5) == "%s.png")
		#expect(FrameSequence.expand("100%.png", 5) == "100%.png")
	}

	@Test func theFrameShowingIsTheOneTheRateSays() {
		let sequence = FrameSequence(pattern: "f/%03d.png", fps: 25)
		#expect(sequence.index(at: 0) == 0)
		// Frame nought is on for the whole of the first fortieth of a second,
		// not for half of it.
		#expect(sequence.index(at: 0.039) == 0)
		#expect(sequence.index(at: 0.04) == 1)
		#expect(sequence.index(at: 1) == 25)
		// Before the start there is no frame minus one.
		#expect(sequence.index(at: -3) == 0)
	}

	/// A sequence baked at 25 on a 50 fps programme holds each frame for two,
	/// which is what a sequence baked at 25 *is*.
	@Test func theSequencesOwnRateDecidesAndNotTheOutputs() {
		let slow = FrameSequence(pattern: "f/%03d.png", fps: 12.5)
		#expect(slow.index(at: 0.079) == 0)
		#expect(slow.index(at: 0.08) == 1)
		#expect(slow.index(at: 1) == 12)
	}

	// MARK: - The file

	private func read(_ text: String) throws -> Project {
		try ProjectReader.read(text)
	}

	private let file = """
		cuttr-project: 1

		output:
		  size: 1920x1080
		  fps:  25

		scenes:
		  s:
		    parts:
		      - frames: charts/walks/%04d.png
		        fps:    25
		        keys:
		          - {t: 0, x: 0.5, y: 0.5, width: 0.7, height: 0.5}
		"""

	@Test func aSequencePartReads() throws {
		let project = try read(file)
		let part = try #require(project.scenes["s"]?.parts.first)
		guard case .frames(let sequence) = part.content else {
			Issue.record("that is not a frames part")
			return
		}
		#expect(sequence.pattern == "charts/walks/%04d.png")
		#expect(sequence.fps == 25)
	}

	/// The rate is not optional. A sequence made at 25 and dropped into a 50 fps
	/// project would otherwise play at double speed and read as a mistake in the
	/// animation, which is a bad half hour.
	@Test func aSequenceWithNoRateIsRefused() {
		#expect(throws: (any Error).self) {
			try read(self.file.replacingOccurrences(of: "        fps:    25\n", with: ""))
		}
	}

	@Test func aSequencePartIsWrittenBackAsItWasWritten() throws {
		let project = try read(file)
		let out = ProjectWriter.write(project)
		#expect(out.contains("      - frames: charts/walks/%04d.png\n"))
		#expect(out.contains("        fps:    25\n"))
		// And again, unchanged: the emitter's whole job.
		#expect(ProjectWriter.write(try read(out)) == out)
	}

	// MARK: - Drawing it, in both paths

	/// A folder of frames: a red left half and a green right half, so which
	/// frame is on screen can be read off one pixel.
	private func reel(_ count: Int) throws -> (URL, FrameSequence) {
		// A directory URL, with the trailing slash, because that is what the
		// resolver hands the render paths — `URL(fileURLWithPath:relativeTo:)`
		// against a URL that does not know it is a directory throws the last
		// component away, and a fixture that got that wrong would be testing
		// nothing.
		let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
			.appendingPathComponent("cuttr-frames-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: directory.appendingPathComponent("f"),
		                                        withIntermediateDirectories: true)
		for index in 0 ..< count {
			// Frame n is a 100×100 square whose red channel is n, so a pixel
			// says which frame this is.
			let context = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8,
			                        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
			                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
			context.setFillColor(CGColor(srgbRed: Double(index) / 255, green: 0, blue: 0, alpha: 1))
			context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
			let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
			try rep.representation(using: .png, properties: [:])!.write(
				to: directory.appendingPathComponent(String(format: "f/%03d.png", index)))
		}
		Reel.shared.empty()
		return (directory, FrameSequence(pattern: "f/%03d.png", fps: 25))
	}

	private func scene(_ sequence: FrameSequence) -> Scene {
		Scene(parts: [.init(content: .frames(sequence),
		                    keys: [.init(t: 0, x: 0.5, y: 0.5, opacity: 1,
		                                 width: 1, height: 1)])])
	}

	/// Which frame this is, read off the red channel at `at`.
	private func red(_ image: CGImage, at point: CGPoint = CGPoint(x: 200, y: 100)) -> Int {
		var bytes = [UInt8](repeating: 0, count: 4)
		context.render(CIImage(cgImage: image), toBitmap: &bytes, rowBytes: 4,
		               bounds: CGRect(x: point.x, y: point.y, width: 1, height: 1),
		               format: .RGBA8, colorSpace: nil)
		return Int(bytes[0])
	}

	/// The painter draws the frame the time asks for, and the last one for ever
	/// after that — the rule keyframes already follow.
	@Test func thePainterDrawsTheFrameTheTimeAsksFor() throws {
		let (directory, sequence) = try reel(5)
		func drawn(at time: Double) throws -> Int {
			red(try #require(OverlayPainter.sceneImage(
				scene(sequence), with: [:], project: Project(), baseURL: directory,
				size: size, at: time)))
		}
		#expect(try drawn(at: 0) == 0)
		#expect(try drawn(at: 0.08) == 2)
		#expect(try drawn(at: 0.16) == 4)
		// Past the end it holds the last frame rather than vanishing, which
		// would read as a bug in the cut.
		#expect(try drawn(at: 9) == 4)
		try? FileManager.default.removeItem(at: directory)
	}

	private func resolved(_ project: Project, baseURL: URL) -> ResolvedProject {
		ResolvedProject(
			project: project, baseURL: baseURL, clips: [],
			overlays: [ResolvedOverlay(
				overlay: Overlay(kind: .scene("s", with: [:]), span: .times(from: 0, to: 3),
				                 arrival: .cut, departure: .cut),
				origin: .project(0), appearance: 0, start: 0, end: 3, path: nil)],
			groups: [], anchors: [])
	}

	private func layers(in layer: CALayer) -> [CALayer] {
		[layer] + (layer.sublayers ?? []).flatMap { layers(in: $0) }
	}

	/// There is one implementation, and the layer path is not it.
	///
	/// A scene holding a sequence goes through the painter in *both* passes, so
	/// the preview and the export are the same pixels by construction rather than
	/// by being checked against each other. `OverlayLayers` builds nothing for
	/// one, which is the assertion here: a layer tree with a picture in it would
	/// be a second answer to "what is on screen at 12.4 seconds", and would take
	/// four gigabytes of bitmap to give it.
	@Test func aSceneWithASequenceInItIsPaintedRatherThanLayered() throws {
		let (directory, sequence) = try reel(5)
		var project = Project(scenes: ["s": scene(sequence)])
		project.output = Output(width: 400, height: 200, framesPerSecond: 25)

		#expect(project.scenes["s"]?.hasFrames == true)
		let overlay = Overlay(kind: .scene("s", with: [:]), span: .times(from: 0, to: 3),
		                      arrival: .cut, departure: .cut)
		#expect(!OverlayLayers.isLayered(overlay, in: project))

		let tree = OverlayLayers.build(resolved(project, baseURL: directory),
		                               size: size, host: .export)
		#expect(layers(in: tree).allSatisfy { $0.contents == nil },
		        "the layer path built a picture for a sequence")
		#expect(tree.sublayers?.isEmpty ?? true)

		// And a scene of anything else still is layered, so this has not turned
		// the second pass off for everybody.
		let plain = Project(scenes: ["s": Scene(parts: [
			.init(content: .shape(fill: .white, corner: 0),
			      keys: [.init(t: 0, x: 0.5, y: 0.5, opacity: 1, width: 0.2, height: 0.2)]),
		])])
		#expect(plain.scenes["s"]?.hasFrames == false)
		#expect(OverlayLayers.isLayered(overlay, in: plain))
		try? FileManager.default.removeItem(at: directory)
	}

	/// The pass the export actually goes through, on the pixels.
	///
	/// This is the end-to-end one and it is the important one: the layer path no
	/// longer carries a sequence, so if the frame pass ever stopped picking one
	/// up, a component would render as nothing at all and every other test here
	/// would still pass. It goes through ``Frame/overlays(over:at:size:work:)``,
	/// which is the function the compositor calls for every frame of a render.
	@Test func theFramePassPutsTheSequenceOnThePicture() throws {
		let (directory, sequence) = try reel(5)
		var project = Project(scenes: ["s": scene(sequence)])
		project.output = Output(width: 400, height: 200, framesPerSecond: 25)
		let work = ProgrammeCompositor.Work(
			size: size, project: project, baseURL: directory,
			overlays: resolved(project, baseURL: directory).overlays, effects: [], people: nil)

		// A green card underneath, so anything that arrived can be told from
		// what was already there.
		let card = CIImage(color: CIColor(red: 0, green: 1, blue: 0)).cropped(
			to: CGRect(origin: .zero, size: size))

		func over(_ time: Double) -> (r: Int, g: Int) {
			let out = Frame.overlays(over: card, at: time, size: size, work: work)
			var bytes = [UInt8](repeating: 0, count: 4)
			context.render(out, toBitmap: &bytes, rowBytes: 4,
			               bounds: CGRect(x: 200, y: 100, width: 1, height: 1),
			               format: .RGBA8, colorSpace: nil)
			return (Int(bytes[0]), Int(bytes[1]))
		}

		// The frames are opaque, so the green is gone and the red channel says
		// which frame arrived — the same numbers the painter gave above.
		#expect(over(0) == (0, 0))
		#expect(over(0.08) == (2, 0))
		#expect(over(0.16) == (4, 0))
		// And past the end it is still the last frame rather than the card.
		#expect(over(2.5) == (4, 0))
		try? FileManager.default.removeItem(at: directory)
	}

	/// A sequence with a hole in it is a sequence that ends at the hole. Said
	/// out loud here because the alternative — skipping the gap — silently
	/// shortens the animation, and nobody would find out until the render.
	@Test func aSequenceEndsAtItsFirstMissingFrame() throws {
		let (directory, sequence) = try reel(5)
		try FileManager.default.removeItem(at: directory.appendingPathComponent("f/003.png"))
		Reel.shared.empty()
		#expect(sequence.count(relativeTo: directory) == 3)
		try? FileManager.default.removeItem(at: directory)
	}
}
