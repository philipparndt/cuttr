import AVFoundation
import CoreImage
import CuttrKit
import Foundation
import QuartzCore
import Testing
@testable import CuttrCompose

/// A bubble, drawn and then read back off the pixels.
///
/// Nothing about a bubble is visible in a type that compiles. A tail that
/// points at the middle of the frame whatever the anchor says is the same
/// `CGPath` as one that points at the face; a wobble taken off an unseeded
/// generator is the same `Double` as one taken off a seeded one, until two
/// renders of the same file disagree. So everything here draws and measures.
struct BubbleCanvas {

	let width: Int, height: Int
	let bytes: [UInt8]

	init(_ image: CGImage) {
		let across = image.width, down = image.height
		width = across
		height = down
		var raw = [UInt8](repeating: 0, count: across * down * 4)
		raw.withUnsafeMutableBytes { buffer in
			let context = CGContext(
				data: buffer.baseAddress, width: across, height: down,
				bitsPerComponent: 8, bytesPerRow: across * 4,
				space: CGColorSpace(name: CGColorSpace.sRGB)!,
				bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
			context.draw(image, in: CGRect(x: 0, y: 0, width: across, height: down))
		}
		bytes = raw
	}

	/// Origin bottom-left, as everywhere else in this program. The buffer
	/// arrives the other way up.
	func alpha(x: Int, y: Int) -> Double {
		guard x >= 0, y >= 0, x < width, y < height else { return 0 }
		return Double(bytes[((height - 1 - y) * width + x) * 4 + 3]) / 255
	}

	/// Every pixel the bubble actually put down.
	var drawn: [(x: Int, y: Int)] {
		var out: [(x: Int, y: Int)] = []
		for y in 0 ..< height {
			for x in 0 ..< width where alpha(x: x, y: y) > 0.5 { out.append((x, y)) }
		}
		return out
	}

	var covered: Int { drawn.count }

	/// How far the nearest drawn pixel is from a point.
	///
	/// The measurement the tail tests turn on: a tail that reaches somebody's
	/// mouth leaves ink within a pixel or two of it, and one that does not
	/// leaves the whole standoff between them.
	func nearest(to point: CGPoint) -> Double {
		var best = Double.infinity
		for pixel in drawn {
			best = min(best, hypot(Double(pixel.x) - point.x, Double(pixel.y) - point.y))
		}
		return best
	}

	/// The box every drawn pixel fits in.
	var extent: CGRect {
		let pixels = drawn
		guard let first = pixels.first else { return .zero }
		var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
		for pixel in pixels {
			minX = min(minX, pixel.x); maxX = max(maxX, pixel.x)
			minY = min(minY, pixel.y); maxY = max(maxY, pixel.y)
		}
		return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
	}
}

// MARK: - What the file says

/// The spelling, and the rule the whole format lives by: written, read, written
/// again, the same bytes.
@Suite struct BubbleFileTests {

	/// The claim this feature was asked to make good on: one line to say it,
	/// one more to say who it is about.
	@Test func aBubbleThatPointsAtSomebodyIsTwoLines() throws {
		let project = try ProjectReader.read("""
			timeline:
			  - clip: mia-close

			overlays:
			  - bubble: still thinks glitter is a colour
			    anchor: mia-eye
			    within: mia-close
			    from:   1
			    to:     4
			""")
		let overlay = try #require(project.overlays.first)
		guard case .bubble(let bubble) = overlay.kind else {
			Issue.record("it did not come back as a bubble")
			return
		}
		#expect(bubble.text == "still thinks glitter is a colour")
		#expect(bubble.shape == .speech)
		#expect(overlay.anchor == "mia-eye")
		// Nobody said where it sits, so it stands off from the face rather than
		// being drawn over it.
		#expect(overlay.offset == Bubble.standoff)
		// And it appears rather than sliding in from the left, which is what
		// every other overlay does and what no bubble should.
		#expect(overlay.arrival == .fade(over: 0.2))
	}

	@Test func everyDialSurvivesTheFile() throws {
		let bubble = Bubble(
			shape: .thought, text: "maybe it is a colour", style: "caption",
			fill: RGBA(hex: "#e8f0ff")!, line: RGBA(hex: "#203040")!,
			width: 0.24, seed: 12, at: CGPoint(x: 0.36, y: 0.52))
		let project = Project(
			timeline: [TimelineEntry(clip: ClipReference("intro"))],
			overlays: [Overlay(kind: .bubble(bubble), span: .times(from: 0, to: 4),
			                   arrival: .fade(over: 0.2), departure: .cut,
			                   anchor: "mia-eye", offset: CGPoint(x: 0.2, y: 0.1))])
		let text = ProjectWriter.write(project)
		let back = try ProjectReader.read(text)
		guard case .bubble(let read) = back.overlays.first?.kind else {
			Issue.record("it did not come back as a bubble:\n\(text)")
			return
		}
		#expect(read == bubble, "written:\n\(text)")
		#expect(back.overlays.first?.offset == CGPoint(x: 0.2, y: 0.1))
		#expect(ProjectWriter.write(back) == text, "written twice:\n\(text)")
	}

	/// The ordinary one, written out, is the two lines it was read from — plus
	/// the range and the two transitions every overlay writes.
	@Test func theOrdinaryBubbleWritesTheOrdinaryThing() {
		let overlay = Overlay(
			kind: .bubble(Bubble(text: "still thinks glitter is a colour")),
			span: .times(from: 1, to: 4),
			arrival: .fade(over: 0.2), departure: .fade(over: 0.2),
			anchor: "mia-eye", offset: Bubble.standoff)
		#expect(ProjectWriter.fragment(for: overlay) == """
			overlays:
			  - bubble: still thinks glitter is a colour
			    from:   00:01.000
			    to:     00:04.000
			    anchor: mia-eye
			    offset: [0.1, 0.22]
			    in:     {fade: true, over: 0.2}
			    out:    {fade: true, over: 0.2}

			""")
	}

	/// A project with no bubbles in it writes exactly what it wrote before
	/// there were any.
	@Test func aProjectWithoutOneIsUntouched() throws {
		let before = """
			# cuttr project — the assembly. Clips are referenced by slug.
			cuttr-project: 1

			output:
			  size: 1920x1080
			  fps:  25

			timeline:
			  - clip: intro

			overlays:
			  - text:   hello
			    style:  title
			    from:   00:00.000
			    to:     00:02.000
			    in:     {fade: true, over: 0.3}
			    out:    {fade: true, over: 0.3}

			"""
		let once = ProjectWriter.write(try ProjectReader.read(before))
		#expect(!once.contains("bubble"))
		#expect(!once.contains("offset"))
		#expect(ProjectWriter.write(try ProjectReader.read(once)) == once)
	}

	/// A bubble on three times, saying something else each time — the `when:`
	/// machinery a caption already had, meaning the same thing here.
	@Test func aBubbleCanSaySomethingElseTheSecondTime() throws {
		let project = try ProjectReader.read("""
			overlays:
			  - bubble: still thinks glitter is a colour
			    anchor: mia-eye
			    when:
			      - {from: 00:01.000, to: 00:03.000}
			      - {from: 00:06.000, to: 00:08.000, text: still does}
			""")
		let overlay = try #require(project.overlays.first)
		let second = overlay.shown(at: overlay.appearances[1])
		guard case .bubble(let bubble) = second.kind else {
			Issue.record("not a bubble")
			return
		}
		#expect(bubble.text == "still does")
		#expect(ProjectWriter.write(try ProjectReader.read(ProjectWriter.write(project)))
			== ProjectWriter.write(project))
	}

	/// A shape nobody has heard of is an error with the offending word in it,
	/// which is the rule everywhere else in this format.
	@Test func anUnknownShapeIsRefusedByName() {
		#expect(throws: ProjectError.self) {
			try ProjectReader.read("""
				overlays:
				  - bubble: hello
				    shape:  banana
				    from:   0
				    to:     1
				""")
		}
	}

	/// A bubble has nothing a key could move, and says so rather than quietly
	/// ignoring one.
	@Test func aBubbleRefusesKeys() {
		do {
			_ = try ProjectReader.read("""
				overlays:
				  - bubble: hello
				    from:   0
				    to:     1
				    keys:
				      - {t: 0, amount: 1}
				""")
			Issue.record("a key on a bubble was accepted")
		} catch {
			#expect("\(error.localizedDescription)".contains("bubble"),
			        "\(error.localizedDescription)")
		}
	}
}

// MARK: - What it draws

@Suite struct BubbleDrawingTests {

	private let size = CGSize(width: 640, height: 360)

	private func shown(
		_ bubble: Bubble, path: AnchorPath? = nil, offset: CGPoint = Bubble.standoff,
		from: Double = 0, to: Double = 4
	) -> ResolvedOverlay {
		ResolvedOverlay(
			overlay: Overlay(kind: .bubble(bubble), span: .times(from: from, to: to),
			                 arrival: .cut, departure: .cut,
			                 anchor: path == nil ? nil : "mia-eye", offset: offset),
			origin: .project(0), appearance: 0, start: from, end: to, path: path)
	}

	private func painted(_ bubble: Bubble, path: AnchorPath? = nil,
	                     offset: CGPoint = Bubble.standoff, at time: Double) throws -> BubbleCanvas {
		let resolved = shown(bubble, path: path, offset: offset)
		return BubbleCanvas(try #require(OverlayPainter.bubbleImage(
			bubble, resolved: resolved, project: Project(), size: size, at: time)))
	}

	/// Something is actually drawn, and it is where it was put.
	@Test func aBubbleIsDrawnBesideTheThingItPointsAt() throws {
		let bubble = Bubble(text: "still thinks glitter is a colour",
		                    seed: 3, at: CGPoint(x: 0.3, y: 0.2))
		let canvas = try painted(bubble, at: 1)
		#expect(canvas.covered > 2000, "almost nothing was drawn: \(canvas.covered)")
		// Beside the spot, not over it: the standoff is up and to the right, so
		// the middle of the paper is above the thing it is about.
		let extent = canvas.extent
		#expect(extent.midY > 0.2 * size.height,
		        "the bubble sits on the thing it points at: \(extent)")
		#expect(extent.maxX <= size.width && extent.minX >= 0, "it ran off the side: \(extent)")
	}

	/// The tail follows the face, and the words do not.
	///
	/// Two positions for the same anchor, and the measurement is the one that
	/// matters: ink lands next to wherever the face is now, and does not land
	/// where it was going to be.
	@Test func theTailPointsAtTheAnchorWhereverItIs() throws {
		let early = CGPoint(x: 0.25, y: 0.2)
		let late = CGPoint(x: 0.78, y: 0.16)
		let path = AnchorPath(samples: [(0, early), (2, late)])
		let bubble = Bubble(text: "still thinks glitter is a colour", seed: 4)

		func frame(_ point: CGPoint) -> CGPoint {
			CGPoint(x: point.x * size.width, y: point.y * size.height)
		}
		let atStart = try painted(bubble, path: path, at: 0)
		let atEnd = try painted(bubble, path: path, at: 2)

		#expect(atStart.nearest(to: frame(early)) < 8,
		        "the tail misses the face by \(atStart.nearest(to: frame(early)))")
		#expect(atEnd.nearest(to: frame(late)) < 8,
		        "the tail did not follow: \(atEnd.nearest(to: frame(late)))")
		// And it is not pointing at both at once.
		#expect(atStart.nearest(to: frame(late)) > 60,
		        "there is ink where she has not got to yet")

		// The words stayed exactly where they were: the paper is the same
		// pixels at both moments, whatever the tail is doing.
		let box = try wordBox(bubble, path: path)
		for point in [CGPoint(x: box.midX, y: box.midY), CGPoint(x: box.midX + 20, y: box.midY)] {
			#expect(atStart.alpha(x: Int(point.x), y: Int(point.y))
				== atEnd.alpha(x: Int(point.x), y: Int(point.y)),
			        "the paper moved under the reader at \(point)")
		}
	}

	private func wordBox(_ bubble: Bubble, path: AnchorPath?) throws -> CGRect {
		let resolved = shown(bubble, path: path)
		let style = Project().style(named: bubble.style ?? "bubble")
		let words = Bubbling.words(bubble.text, style: style, frame: size, width: bubble.width)
		return Bubbling.box(
			words: words?.size ?? .zero, shape: bubble.shape, style: style,
			home: OverlayLayers.bubbleHome(bubble, resolved: resolved, style: style, size: size),
			frame: size)
	}

	/// Where the tracking stops, the tail stops. The bubble keeps its words.
	@Test func withNoTrackingThereIsNoTail() throws {
		let seen = CGPoint(x: 0.25, y: 0.2)
		// Solved over the first two seconds and no further — she left the room.
		let path = AnchorPath(samples: [(0, seen), (2, seen)], covered: [0 ... 2])
		let bubble = Bubble(text: "still thinks glitter is a colour", seed: 4)

		let while_ = try painted(bubble, path: path, at: 1)
		let after = try painted(bubble, path: path, at: 3)
		let point = CGPoint(x: seen.x * size.width, y: seen.y * size.height)
		#expect(while_.nearest(to: point) < 8)
		#expect(after.nearest(to: point) > 40, "the tail is still pointing at an empty doorway")
		// But the bubble is still there, saying what it says.
		#expect(after.covered > while_.covered / 2, "the whole bubble went with the tracking")
	}

	/// The point of a seed: the same one draws the same wobble, twice, and a
	/// different one draws a different wobble.
	@Test func theWobbleIsTheSameTwiceAndDifferentForTwoSeeds() throws {
		func drawn(seed: Int) throws -> [UInt8] {
			try painted(Bubble(text: "still thinks glitter is a colour", seed: seed,
			                   at: CGPoint(x: 0.3, y: 0.2)), at: 1).bytes
		}
		#expect(try drawn(seed: 3) == drawn(seed: 3))
		#expect(try drawn(seed: 3) != drawn(seed: 4))
	}

	/// A long line makes a taller bubble, not one that runs off the frame.
	///
	/// Drawn with nothing to point at, so that what is measured is the paper
	/// rather than the paper and a tail — a tail is the same length whatever the
	/// bubble says, and would swamp the thing being asked about.
	@Test func aLongLineGrowsDownwardsRatherThanSideways() throws {
		let short = try painted(Bubble(text: "glitter", seed: 2), at: 1).extent
		let long = try painted(
			Bubble(text: "she has been telling this story since nineteen seventy and it gets "
				+ "longer every single year", seed: 2), at: 1).extent

		#expect(long.height > short.height * 1.8,
		        "the long one is not taller: \(short) then \(long)")
		#expect(long.width > short.width, "it did not grow at all")
		// Wider than the measure by the roundness — a corner has to go
		// somewhere — but nothing like the frame, which is the point.
		#expect(long.width < 0.32 * size.width * 1.5,
		        "it grew past the measure it was given: \(long.width)")
		#expect(long.minX >= 0 && long.maxX <= size.width,
		        "it ran off the side of the frame: \(long)")
		#expect(long.minY >= 0 && long.maxY <= size.height,
		        "it ran off the top or the bottom: \(long)")
	}

	/// The three shapes are three drawings rather than three names for one.
	@Test func theThreeShapesAreDifferentDrawings() throws {
		let spot = CGPoint(x: 0.5, y: 0.14)
		func drawn(_ shape: Bubble.Shape) throws -> [UInt8] {
			try painted(Bubble(shape: shape, text: "glitter", seed: 6, at: spot), at: 1).bytes
		}
		#expect(try drawn(.speech) != drawn(.thought))
		#expect(try drawn(.speech) != drawn(.box))
		#expect(try drawn(.thought) != drawn(.box))

		// A thought bubble's trail is separate puffs, so walking from the middle
		// of the paper down to the spot crosses ink, then nothing, then ink
		// again; a speech bubble's tail is one unbroken spike.
		let thought = try painted(Bubble(shape: .thought, text: "glitter", seed: 6, at: spot), at: 1)
		let speech = try painted(Bubble(text: "glitter", seed: 6, at: spot), at: 1)
		let target = CGPoint(x: spot.x * size.width, y: spot.y * size.height)
		func runs(_ canvas: BubbleCanvas, from middle: CGPoint) -> Int {
			var count = 0, on = false
			for step in 0 ... 400 {
				let t = Double(step) / 400
				let x = Int(middle.x + (target.x - middle.x) * t)
				let y = Int(middle.y + (target.y - middle.y) * t)
				let lit = canvas.alpha(x: x, y: y) > 0.5
				if lit, !on { count += 1 }
				on = lit
			}
			return count
		}
		let middle = try CGPoint(x: wordBox(Bubble(text: "glitter", seed: 6, at: spot),
		                                    path: nil).midX,
		                         y: wordBox(Bubble(text: "glitter", seed: 6, at: spot),
		                                    path: nil).midY)
		#expect(runs(thought, from: middle) > runs(speech, from: middle),
		        "the trail is not broken into puffs")
	}
}

// MARK: - What the export gets

@Suite struct BubbleLayerTests {

	private let size = CGSize(width: 640, height: 360)

	private func shapes(in layer: CALayer) -> [CAShapeLayer] {
		((layer.sublayers ?? []).flatMap { shapes(in: $0) })
			+ ((layer as? CAShapeLayer).map { [$0] } ?? [])
	}

	private func tree(_ path: AnchorPath?) -> CALayer {
		let overlay = Overlay(
			kind: .bubble(Bubble(text: "still thinks glitter is a colour", seed: 3,
			                     at: CGPoint(x: 0.3, y: 0.2))),
			span: .times(from: 0, to: 2), arrival: .cut, departure: .cut,
			anchor: path == nil ? nil : "mia-eye", offset: Bubble.standoff)
		let resolved = ResolvedProject(
			project: Project(), baseURL: URL(fileURLWithPath: "."), clips: [],
			overlays: [ResolvedOverlay(overlay: overlay, origin: .project(0), appearance: 0,
			                           start: 0, end: 2, path: path)],
			groups: [], anchors: [])
		return OverlayLayers.build(resolved, size: size, host: .export)
	}

	/// A bubble is laid over the finished frame, like a caption.
	@Test func aBubbleIsALayer() {
		#expect(OverlayLayers.isLayered(Overlay(kind: .bubble(Bubble(text: "hi")),
		                                        span: .times(from: 0, to: 1))))
	}

	/// The tail is keyframed, at the anchor's own sample times, and every
	/// keyframe has the same number of points — which is Core Animation's one
	/// condition for interpolating a path.
	@Test func theTailIsKeyframedAlongTheAnchor() throws {
		let path = AnchorPath(samples: (0 ... 20).map {
			(Double($0) / 10, CGPoint(x: 0.2 + Double($0) * 0.03, y: 0.2))
		})
		let animated = shapes(in: tree(path)).compactMap {
			$0.animation(forKey: "path") as? CAKeyframeAnimation
		}
		#expect(animated.count == 2, "the two strokes should both move: \(animated.count)")
		let values = try #require(animated.first?.values as? [CGPath])
		#expect(values.count > 10, "the tail is redrawn \(values.count) times")
		let counts = values.map { path -> Int in
			var points = 0
			path.applyWithBlock { _ in points += 1 }
			return points
		}
		#expect(Set(counts).count == 1,
		        "the keyframes have different numbers of points: \(Set(counts))")
	}

	/// A bubble that points at a fixed spot never moves, so nothing is animated
	/// and the file pays for nothing.
	@Test func aFixedSpotIsDrawnOnce() {
		let animated = shapes(in: tree(nil)).compactMap { $0.animation(forKey: "path") }
		#expect(animated.isEmpty)
		#expect(shapes(in: tree(nil)).allSatisfy { $0.path != nil })
	}
}

// MARK: - What comes out of the encoder

/// The two claims that can only be made about a rendered file: it is on when it
/// should be, and it is the same file twice.
@Suite struct BubbleRenderTests {

	private func rendered(_ seed: Int) async throws -> URL {
		let directory = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("cuttr-bubble-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let project = try ProjectReader.read("""
			output:
			  size: 640x360
			  fps:  25
			  file: bubbles.mov

			timeline:
			  - card: 00:03.000
			    fill: "#000000"

			overlays:
			  - bubble: still thinks glitter is a colour
			    seed:   \(seed)
			    at:     [0.4, 0.2]
			    from:   00:01.000
			    to:     00:02.000
			    in:     cut
			    out:    cut
			""")
		let resolved = try Resolver.resolve(project, baseURL: directory)
		let url = directory.appendingPathComponent("bubbles.mov")
		try await Renderer.export(resolved, to: url)
		return url
	}

	private func frame(in url: URL, at seconds: Double) async throws -> [UInt8] {
		let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
		generator.requestedTimeToleranceBefore = .zero
		generator.requestedTimeToleranceAfter = .zero
		let image = try await generator.image(
			at: CMTime(seconds: seconds, preferredTimescale: 600)).image
		return BubbleCanvas(image).bytes
	}

	/// How much paper is on the frame: the bubble is nearly white and the card
	/// under it is black.
	private func paper(_ bytes: [UInt8]) -> Int {
		stride(from: 0, to: bytes.count, by: 4).count { bytes[$0] > 180 }
	}

	@Test func aBubbleIsOnOverItsSpanAndNotOutsideIt() async throws {
		let url = try await rendered(3)
		defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
		#expect(try await paper(frame(in: url, at: 0.4)) == 0)
		#expect(try await paper(frame(in: url, at: 0.96)) == 0)
		#expect(try await paper(frame(in: url, at: 1.4)) > 1000)
		#expect(try await paper(frame(in: url, at: 1.96)) > 1000)
		#expect(try await paper(frame(in: url, at: 2.4)) == 0)
	}

	/// Two renders of the same project draw the same bubble, and two seeds do
	/// not. The hand-drawn look is worth nothing if it cannot be repeated.
	///
	/// Not byte-for-byte on the decoded frame, which is what this used to ask
	/// and why it failed under a loaded machine and passed when run alone: an
	/// H.264 encoder given less time makes different rate-control decisions,
	/// and a decoded frame is a level or two away from the one it made when it
	/// was not busy. That is a fact about the encoder and this test is about
	/// the drawing, so it compares how far apart the two frames are — nothing,
	/// against a different seed, which redraws every wobble.
	@Test func twoRendersOfTheSameProjectAreTheSameFrames() async throws {
		let first = try await rendered(3)
		let second = try await rendered(3)
		let other = try await rendered(4)
		defer {
			for url in [first, second, other] {
				try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
			}
		}
		let a = try await frame(in: first, at: 1.5)
		let b = try await frame(in: second, at: 1.5)
		let c = try await frame(in: other, at: 1.5)
		let same = apart(a, b)
		let different = apart(a, c)
		// Measured on an idle machine: nothing at all against 0.44 a channel.
		// The bounds are set an order of magnitude either side of those, because
		// what is being asked is "the same drawing" against "a different one",
		// and a single byte of encoder noise moves the mean by a millionth.
		#expect(same < 0.01, "two renders of one project disagree by \(same) a channel")
		#expect(different > 0.1,
		        "two seeds drew the same bubble: \(different) against \(same)")
	}

	/// The mean absolute difference per channel between two decoded frames.
	private func apart(_ a: [UInt8], _ b: [UInt8]) -> Double {
		guard a.count == b.count, !a.isEmpty else { return .infinity }
		var total = 0
		for index in stride(from: 0, to: a.count, by: 4) {
			total += abs(Int(a[index]) - Int(b[index]))
		}
		return Double(total) / Double(a.count / 4)
	}
}
