import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import QuartzCore
import Testing
import UniformTypeIdentifiers
@testable import CuttrCompose

/// A folder of pictures, played over the cut.
///
/// The reason this suite is longer than the feature is that the feature's whole
/// claim is *agreement*: the pictures are drawn somewhere else, so the only
/// thing left to get wrong is which one is on screen, where it goes, and what
/// happens to its alpha — and each of those has two answers in this program that
/// have to be the same answer. So the interesting tests here measure both paths
/// and compare them, rather than measuring one and reading the other.
@Suite struct FrameSequenceTests {

	private let context = CIContext(options: [.workingColorSpace: NSNull()])

	// MARK: - Fixtures

	/// A folder of PNGs, each one a flat colour with a stated alpha, written
	/// with whatever names are asked for.
	///
	/// Flat rather than drawn, because what these tests need from a picture is
	/// only *which* picture it is: the red channel carries the frame number, so
	/// a pixel read off a render says which frame was on at that moment.
	private func sequence(
		_ names: [String], red: [Double], alpha: Double = 1,
		pixels: CGSize = CGSize(width: 40, height: 20)
	) throws -> URL {
		let folder = FileManager.default.temporaryDirectory
			.appendingPathComponent("cuttr-frames-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		for (index, name) in names.enumerated() {
			let context = try #require(CGContext(
				data: nil, width: Int(pixels.width), height: Int(pixels.height),
				bitsPerComponent: 8, bytesPerRow: 0,
				space: CGColorSpace(name: CGColorSpace.sRGB)!,
				bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
			context.setFillColor(CGColor(srgbRed: red[index], green: 0, blue: 0, alpha: alpha))
			context.fill(CGRect(origin: .zero, size: pixels))
			let image = try #require(context.makeImage())
			let url = folder.appendingPathComponent(name)
			let destination = try #require(CGImageDestinationCreateWithURL(
				url as CFURL, UTType.png.identifier as CFString, 1, nil))
			CGImageDestinationAddImage(destination, image, nil)
			#expect(CGImageDestinationFinalize(destination))
		}
		FrameFolder.forgetEverything()
		return folder
	}

	private func resolved(_ overlay: Overlay, baseURL: URL, to end: Double) -> ResolvedProject {
		ResolvedProject(
			project: Project(overlays: [overlay]), baseURL: baseURL, clips: [],
			overlays: [ResolvedOverlay(
				overlay: overlay, origin: .project(0), appearance: 0,
				start: 0, end: end, path: nil)],
			groups: [], anchors: [])
	}

	/// One pixel of a Core Image image, composited over black — which is what a
	/// render does to it. The channels back, nought to 255.
	private func pixel(_ image: CIImage, x: Int, y: Int) -> [UInt8] {
		let black = CIImage(color: .black).cropped(to: image.extent.union(
			CGRect(x: 0, y: 0, width: Double(x) + 1, height: Double(y) + 1)))
		var bytes = [UInt8](repeating: 0, count: 4)
		context.render(image.composited(over: black), toBitmap: &bytes, rowBytes: 4,
		               bounds: CGRect(x: x, y: y, width: 1, height: 1),
		               format: .RGBA8, colorSpace: nil)
		return bytes
	}

	/// Every layer in a tree that has a picture in it.
	private func pictures(in layer: CALayer) -> [CALayer] {
		let mine = (layer.contents as CFTypeRef?).map { CFGetTypeID($0) == CGImage.typeID } ?? false
		return (mine ? [layer] : []) + (layer.sublayers ?? []).flatMap { pictures(in: $0) }
	}

	// MARK: - What is in the folder

	/// The sequence is the numbered pictures, in numeric order — whatever they
	/// are called, and whatever else is in the folder beside them.
	///
	/// Written the way three different renderers actually name their output, in
	/// the wrong order, with a sidecar and a note dropped in: `remotion render
	/// --sequence` writes `element-0000.png`, so a folder anybody produces has
	/// to work without being told a pattern.
	@Test func theSequenceIsTheNumberedPicturesInTheFolder() throws {
		let folder = try sequence(
			["element-0002.png", "element-0000.png", "element-0010.png", "element-0001.png"],
			red: [0.2, 0, 1, 0.1])
		// The things a render leaves beside the frames, none of which is a frame.
		try "{}".write(to: folder.appendingPathComponent("rendered.json"),
		               atomically: true, encoding: .utf8)
		try "hello".write(to: folder.appendingPathComponent("notes.txt"),
		                  atomically: true, encoding: .utf8)
		FrameFolder.forgetEverything()

		let listing = FrameFolder.listing(folder.path, relativeTo: URL(fileURLWithPath: "/"))
		#expect(listing.count == 4)
		#expect(listing.urls.map { $0.lastPathComponent }
			== ["element-0000.png", "element-0001.png", "element-0002.png", "element-0010.png"])
		// Ten sorts after two, which is the whole reason the number is parsed
		// rather than the name compared.
		#expect(listing.pixels == CGSize(width: 40, height: 20))
	}

	/// The *last* run of digits, so a folder called `render_v2` does not become
	/// a sequence of one frame numbered two.
	@Test func theFrameNumberIsTheLastRunOfDigits() {
		#expect(FrameFolder.number(in: "element-0042.png") == 42)
		#expect(FrameFolder.number(in: "0042.png") == 42)
		#expect(FrameFolder.number(in: "render_v2_0007.png") == 7)
		#expect(FrameFolder.number(in: "frame_0001_custom.jpeg") == 1)
		#expect(FrameFolder.number(in: "poster.png") == nil)
	}

	/// A folder that is not there is a sequence of nothing, and nothing is
	/// drawn. Said out loud by ``Frames/found(relativeTo:)``, which is what
	/// `--describe` prints.
	@Test func aFolderWithNoPicturesInItIsSaidOutLoud() throws {
		let frames = Frames(folder: "nowhere-at-all", framesPerSecond: 25)
		let found = frames.found(relativeTo: URL(fileURLWithPath: "/tmp/"))
		#expect(found.count == 0)
		#expect(found.seconds == 0)
	}

	// MARK: - Which picture is on

	/// It steps at the rate the file states, from the start of the span.
	@Test func itStepsAtTheRateTheFileStates() {
		let frames = Frames(folder: "x", framesPerSecond: 10)
		#expect(frames.frame(at: 0, of: 50) == 0)
		#expect(frames.frame(at: 0.09, of: 50) == 0)
		#expect(frames.frame(at: 0.1, of: 50) == 1)
		#expect(frames.frame(at: 1.25, of: 50) == 12)
		// Before the span — which is where a movement placed before the mark
		// draws it — it holds its first picture rather than running backwards.
		#expect(frames.frame(at: -3, of: 50) == 0)
		#expect(frames.frame(at: 0, of: 0) == nil)
	}

	/// A held sequence stops on its last picture; a looped one starts again.
	@Test func aHeldSequenceHoldsAndALoopedOneStartsAgain() {
		let held = Frames(folder: "x", framesPerSecond: 10, ends: .hold)
		let looped = Frames(folder: "x", framesPerSecond: 10, ends: .loop)
		#expect(held.frame(at: 0.9, of: 10) == 9)
		#expect(held.frame(at: 5, of: 10) == 9)
		#expect(looped.frame(at: 0.9, of: 10) == 9)
		#expect(looped.frame(at: 1.0, of: 10) == 0)
		#expect(looped.frame(at: 1.3, of: 10) == 3)
	}

	// MARK: - The file

	/// A sequence with no `fps:` is refused, with the reason in the message.
	@Test func aSequenceWithNoRateIsRefused() throws {
		let text = """
		cuttr-project: 1
		overlays:
		  - frames: overlays/chart
		    from:   "@intro"
		"""
		let thrown = try #require(throws: ProjectError.self) { try ProjectReader.read(text) }
		#expect(thrown.errorDescription?.contains("`fps:`") == true)
	}

	/// And `ends: stretch` is refused by name, because the reason it is absent
	/// is not obvious from its absence.
	@Test func stretchingASequenceIsRefusedByName() throws {
		let text = """
		cuttr-project: 1
		overlays:
		  - frames: overlays/chart
		    fps:    25
		    ends:   stretch
		    from:   "@intro"
		"""
		let thrown = try #require(throws: ProjectError.self) { try ProjectReader.read(text) }
		#expect(thrown.errorDescription?.contains("re-time") == true)
		#expect(thrown.errorDescription?.contains("hold") == true)
	}

	/// Nothing about a sequence can be animated, and the refusal says what a
	/// sequence's animation actually is.
	@Test func aSequenceCannotBeAnimated() throws {
		let text = """
		cuttr-project: 1
		overlays:
		  - frames: overlays/chart
		    fps:    25
		    from:   "@intro"
		    keys:
		      - {t: 0, size: 0.2}
		"""
		let thrown = try #require(throws: ProjectError.self) { try ProjectReader.read(text) }
		#expect(thrown.errorDescription?.contains("frames") == true)
	}

	/// Written back byte for byte, with the defaults absent and the offset kept.
	@Test func aSequenceSurvivesTheFile() throws {
		let plain = Project(overlays: [Overlay(
			kind: .frames(Frames(folder: "overlays/chart", framesPerSecond: 30)),
			span: .marks(from: .group("chart"), to: .group("chart")),
			arrival: .fade(over: 0.4), departure: .fade(over: 0.4))])
		let text = ProjectWriter.write(plain)
		#expect(text.contains("- frames: overlays/chart\n"))
		#expect(text.contains("  fps:    30\n"))
		// The two that are what a sequence is without them. Spelt with the
		// column the overlay block aligns to, because `output:` has a `size:`
		// of its own and it is not this one.
		#expect(!text.contains("  size:   "))
		#expect(!text.contains("ends:"))
		let back = try ProjectReader.read(text)
		#expect(back.overlays == plain.overlays)
		#expect(ProjectWriter.write(back) == text)

		let dressed = Project(overlays: [Overlay(
			kind: .frames(Frames(folder: "overlays/globe", framesPerSecond: 25,
			                     size: 0.4, ends: .loop)),
			span: .times(from: 1, to: 4),
			arrival: .fade(over: 0.4), departure: .fade(over: 0.4),
			offset: CGPoint(x: -0.2, y: 0.15))])
		let second = ProjectWriter.write(dressed)
		#expect(second.contains("  size:   0.4\n"))
		#expect(second.contains("  ends:   loop\n"))
		// An offset with no anchor is measured from the middle of the frame, so
		// it has to be written even though nothing is being followed.
		#expect(second.contains("  offset: [-0.2, 0.15]\n"))
		let read = try ProjectReader.read(second)
		#expect(read.overlays == dressed.overlays)
		#expect(ProjectWriter.write(read) == second)
	}

	// MARK: - Both paths

	/// **The measurement the whole design rests on.** A PNG comes back from
	/// ImageIO with straight — not premultiplied — alpha, and both Core Image
	/// and Core Animation premultiply it themselves, identically: pure white at
	/// half alpha over black is 128 in each of them.
	///
	/// That is why nothing in ``FrameFolder`` touches a pixel, and why the same
	/// `CGImage` object can be handed to both paths. Premultiplying by hand
	/// would double the operation and show as a dark fringe round every soft
	/// edge — which is the classic way a composited PNG sequence goes wrong.
	/// If a future framework stops doing this, this test says so rather than
	/// the render.
	@Test func bothPathsAgreeOnAHalfCoveredPixel() throws {
		let folder = try sequence(["0000.png"], red: [1], alpha: 0.5)
		let frames = Frames(folder: folder.path, framesPerSecond: 25)
		let overlay = Overlay(kind: .frames(frames), span: .times(from: 0, to: 2),
		                      arrival: .cut, departure: .cut)
		let size = CGSize(width: 80, height: 40)
		let tree = resolved(overlay, baseURL: URL(fileURLWithPath: "/"), to: 2)

		// The painter, through Core Image.
		let painted = try #require(OverlayPainter.image(
			for: tree.overlays[0], project: tree.project, baseURL: tree.baseURL,
			size: size, at: 1))
		let byCoreImage = pixel(painted, x: 40, y: 20)

		// The same image object, through Core Animation. The tree's own root is
		// held at `opacity = 0` by the envelope until something animates it, so
		// what is rendered here is the picture layer itself — which is the only
		// thing in the comparison anyway: the question is what the framework
		// does with the alpha, not where the layer sits.
		let built = OverlayLayers.build(tree, size: size, host: .export)
		let picture = try #require(pictures(in: built).first)
		#expect((picture.contents as CFTypeRef?).map { CFGetTypeID($0) == CGImage.typeID } == true)
		let root = CALayer()
		root.frame = CGRect(origin: .zero, size: picture.bounds.size)
		root.backgroundColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
		let copy = CALayer()
		copy.frame = root.bounds
		copy.contents = picture.contents
		copy.contentsGravity = .resize
		root.addSublayer(copy)
		let out = try #require(CGContext(
			data: nil, width: Int(root.bounds.width), height: Int(root.bounds.height),
			bitsPerComponent: 8, bytesPerRow: 0,
			space: CGColorSpace(name: CGColorSpace.sRGB)!,
			bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
		root.render(in: out)
		let byCoreAnimation = pixel(CIImage(cgImage: try #require(out.makeImage())), x: 1, y: 1)

		#expect(abs(Int(byCoreImage[0]) - 128) <= 1, "Core Image: \(byCoreImage)")
		#expect(abs(Int(byCoreAnimation[0]) - 128) <= 1, "Core Animation: \(byCoreAnimation)")
		#expect(abs(Int(byCoreImage[0]) - Int(byCoreAnimation[0])) <= 1,
		        "the two paths disagree: \(byCoreImage) against \(byCoreAnimation)")
	}

	/// The two paths show the *same picture* at the same moment.
	///
	/// The red channel is the frame number, so the painter's pixel and the
	/// layer path's keyframe can be compared directly. A frame rate that does
	/// not divide the span is on purpose: the interesting disagreement would be
	/// an off-by-one at a step boundary.
	@Test func bothPathsShowTheSamePictureAtTheSameMoment() throws {
		let reds = [0.0, 0.2, 0.4, 0.6, 0.8, 1.0]
		let folder = try sequence((0..<6).map { String(format: "element-%04d.png", $0) }, red: reds)
		let frames = Frames(folder: folder.path, framesPerSecond: 4)
		let overlay = Overlay(kind: .frames(frames), span: .times(from: 0, to: 2),
		                      arrival: .cut, departure: .cut)
		let size = CGSize(width: 80, height: 40)
		let tree = resolved(overlay, baseURL: URL(fileURLWithPath: "/"), to: 2)

		let built = OverlayLayers.build(tree, size: size, host: .export)
		let picture = try #require(pictures(in: built).first)
		let animation = try #require(
			picture.animation(forKey: "contents") as? CAKeyframeAnimation)
		let values = try #require(animation.values as? [CGImage])
		let times = try #require(animation.keyTimes).map(\.doubleValue)
		#expect(animation.calculationMode == .discrete, "the pictures cross-fade into each other")
		// Six pictures at four a second is a second and a half, and the sequence
		// holds its last for the remaining half — so six pictures, not eight.
		#expect(values.count == 6)
		#expect(animation.duration == 2)

		/// The red channel of one picture, as a fraction.
		func redOf(_ image: CGImage) -> Double {
			Double(pixel(CIImage(cgImage: image), x: 1, y: 1)[0]) / 255
		}

		for (index, at) in [0.0, 0.3, 0.6, 0.9, 1.2, 1.6, 1.99].enumerated() {
			_ = index
			let painted = try #require(OverlayPainter.image(
				for: tree.overlays[0], project: tree.project, baseURL: tree.baseURL,
				size: size, at: at))
			let painterRed = Double(pixel(painted, x: 40, y: 20)[0]) / 255
			// Which keyframe Core Animation is holding at that moment: the last
			// one whose time has come, which is what `.discrete` means. Clamped
			// to the values, because the last key time closes the final interval
			// and has no picture of its own.
			let step = min(times.lastIndex { $0 <= at / 2 + 1e-9 } ?? 0, values.count - 1)
			let layerRed = redOf(values[step])
			#expect(abs(painterRed - layerRed) < 0.01,
			        "at \(at)s the painter has \(painterRed) and the layer path \(layerRed)")
			// And it is the frame the arithmetic says, not merely the same one
			// twice.
			let expected = try #require(frames.frame(at: at, of: 6))
			#expect(abs(painterRed - reds[expected]) < 0.01,
			        "at \(at)s frame \(expected) should be on")
		}
	}

	/// And in the same place, at the same size — the box from the pictures' own
	/// shape, the position from `offset:` measured off the middle of the frame.
	@Test func bothPathsPutTheSequenceInTheSameBox() throws {
		let folder = try sequence(["0000.png"], red: [1],
		                          pixels: CGSize(width: 400, height: 100))
		// 0.5 of a 400-high frame is 200 tall, and 4:1 makes it 800 wide.
		let frames = Frames(folder: folder.path, framesPerSecond: 25, size: 0.5)
		let overlay = Overlay(kind: .frames(frames), span: .times(from: 0, to: 2),
		                      arrival: .cut, departure: .cut,
		                      offset: CGPoint(x: 0.25, y: -0.125))
		let size = CGSize(width: 1000, height: 400)
		let tree = resolved(overlay, baseURL: URL(fileURLWithPath: "/"), to: 2)

		let painted = try #require(OverlayPainter.image(
			for: tree.overlays[0], project: tree.project, baseURL: tree.baseURL,
			size: size, at: 1))
		#expect(abs(painted.extent.width - 800) < 1, "the painter's box is \(painted.extent)")
		#expect(abs(painted.extent.height - 200) < 1)
		// The middle of the frame is (500, 200); the offset is in fractions of
		// the frame *height* on both axes, so (+100, -50) puts the middle of the
		// box at (600, 150) and its corner at (200, 50).
		#expect(abs(painted.extent.midX - 600) < 1, "the painter's box is \(painted.extent)")
		#expect(abs(painted.extent.midY - 150) < 1)

		let built = OverlayLayers.build(tree, size: size, host: .export)
		let placer = try #require(built.sublayers?.first)
		#expect(abs(placer.bounds.width - 800) < 1, "the layer path's box is \(placer.bounds)")
		#expect(abs(placer.bounds.height - 200) < 1)
		#expect(abs(placer.position.x - 600) < 1, "the layer path sits at \(placer.position)")
		#expect(abs(placer.position.y - 150) < 1)
		#expect(placer.anchorPoint == CGPoint(x: 0.5, y: 0.5))
	}

	/// A looped sequence keeps stepping past its own end in both paths — and it
	/// is the same picture object each time round, not a second decode of it.
	@Test func aLoopedSequenceComesRoundInBothPaths() throws {
		let folder = try sequence((0..<3).map { "\($0).png" }, red: [0, 0.5, 1])
		let frames = Frames(folder: folder.path, framesPerSecond: 3, ends: .loop)
		let overlay = Overlay(kind: .frames(frames), span: .times(from: 0, to: 2),
		                      arrival: .cut, departure: .cut)
		let tree = resolved(overlay, baseURL: URL(fileURLWithPath: "/"), to: 2)
		let built = OverlayLayers.build(tree, size: CGSize(width: 60, height: 30), host: .export)
		let picture = try #require(pictures(in: built).first)
		let animation = try #require(
			picture.animation(forKey: "contents") as? CAKeyframeAnimation)
		let values = try #require(animation.values as? [CGImage])
		// Three pictures at three a second over two seconds: six turns, and no
		// seventh, because a picture whose turn begins exactly at the end of the
		// span is a picture nobody sees.
		#expect(values.count == 6)
		#expect(values[0] === values[3], "a loop decodes the same picture twice")
		#expect(values[1] === values[4])
	}

	/// **One more key time than values**, which is what a discrete keyframe
	/// animation means by a key time: each one opens an interval and the extra
	/// one closes the last.
	///
	/// Its own test because getting it wrong is silent. Measured on a rendered
	/// file with one time per value: Core Animation ignored the animation
	/// outright and a two-picture sequence showed its first picture for the whole
	/// of both cards it was on. Nothing in the render, the log or the preview
	/// said so.
	@Test func framesStepThroughTheirOwnKeyTimes() throws {
		let folder = try sequence((0..<4).map { "\($0).png" }, red: [0, 0.3, 0.6, 0.9])
		let frames = Frames(folder: folder.path, framesPerSecond: 2)
		let overlay = Overlay(kind: .frames(frames), span: .times(from: 0, to: 2),
		                      arrival: .cut, departure: .cut)
		let tree = resolved(overlay, baseURL: URL(fileURLWithPath: "/"), to: 2)
		let built = OverlayLayers.build(tree, size: CGSize(width: 60, height: 30), host: .export)
		let picture = try #require(pictures(in: built).first)
		let animation = try #require(
			picture.animation(forKey: "contents") as? CAKeyframeAnimation)
		let values = try #require(animation.values)
		let times = try #require(animation.keyTimes).map(\.doubleValue)
		#expect(times.count == values.count + 1,
		        "\(values.count) pictures and \(times.count) key times")
		#expect(times.first == 0, "a discrete animation has to start at nought")
		#expect(times.last == 1, "and finish at one")
		// Four pictures at two a second is exactly the two-second span.
		#expect(values.count == 4)
		#expect(times == [0, 0.25, 0.5, 0.75, 1])
	}
}
