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

	/// How dark a pixel is: nought for paper, one for ink.
	///
	/// What "the words have not moved" has to be measured on. The alpha inside a
	/// bubble is one everywhere — the paper is opaque — so it would not notice a
	/// whole sentence sliding across it. Outside the bubble there is nothing, and
	/// nothing reads as dark, so only ask about pixels known to be on paper.
	func darkness(x: Int, y: Int) -> Double {
		guard x >= 0, y >= 0, x < width, y < height else { return 0 }
		let index = ((height - 1 - y) * width + x) * 4
		let luma = 0.299 * Double(bytes[index]) + 0.587 * Double(bytes[index + 1])
			+ 0.114 * Double(bytes[index + 2])
		return 1 - luma / 255
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
			width: 0.24, seed: 12, breath: 1.5, at: CGPoint(x: 0.36, y: 0.52))
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

	/// `breath: 0` is how a project asks for the still drawing, and it survives
	/// the file — a bubble somebody deliberately stopped must not start again
	/// the next time it is saved.
	@Test func theStillDrawingIsSpelledOut() throws {
		let project = try ProjectReader.read("""
			overlays:
			  - bubble: the good chair
			    shape:  box
			    breath: 0
			    at:     [0.2, 0.3]
			    from:   0
			    to:     2
			""")
		guard case .bubble(let bubble) = project.overlays.first?.kind else {
			Issue.record("not a bubble")
			return
		}
		#expect(bubble.breath == 0)
		let written = ProjectWriter.write(project)
		#expect(written.contains("breath: 0"), "it did not write the one thing it was told:\n\(written)")
		#expect(ProjectWriter.write(try ProjectReader.read(written)) == written)
		// And a bubble that says nothing about it writes nothing about it: the
		// ordinary bubble is still two lines.
		#expect(!ProjectWriter.fragment(for: Overlay(
			kind: .bubble(Bubble(text: "hello")), span: .times(from: 0, to: 1)))
			.contains("breath"))
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

// MARK: - What breathes

/// The line is alive, and only slightly.
///
/// Every claim in here is a number taken off the drawing, because *slightly* is
/// a claim about a magnitude, and a magnitude cannot be checked by reading the
/// code that produces it. Two of them are taken off the geometry rather than the
/// pixels — how far the line actually moved is a distance, and a rasteriser
/// rounds it to the pixel grid before anybody can measure it.
@Suite struct BubbleBreathTests {

	private let size = CGSize(width: 1280, height: 720)

	/// A bubble with nothing to point at: what is measured is then the outline
	/// and not the outline and a tail, and the tail is a whole question of its
	/// own.
	private func shown(_ bubble: Bubble, from: Double = 0, to: Double = 4) -> ResolvedOverlay {
		ResolvedOverlay(
			overlay: Overlay(kind: .bubble(bubble), span: .times(from: from, to: to),
			                 arrival: .cut, departure: .cut),
			origin: .project(0), appearance: 0, start: from, end: to, path: nil)
	}

	private func painted(_ bubble: Bubble, at time: Double,
	                     from: Double = 0, to: Double = 4) throws -> BubbleCanvas {
		BubbleCanvas(try #require(OverlayPainter.bubbleImage(
			bubble, resolved: shown(bubble, from: from, to: to),
			project: Project(), size: size, at: time)))
	}

	private func box(_ bubble: Bubble) -> CGRect {
		let style = Project().style(named: bubble.style ?? "bubble")
		let words = Bubbling.words(bubble.text, style: style, frame: size, width: bubble.width)
		return Bubbling.box(
			words: words?.size ?? .zero, shape: bubble.shape, style: style,
			home: OverlayLayers.bubbleHome(bubble, resolved: shown(bubble),
			                               style: style, size: size),
			frame: size)
	}

	private func points(_ path: CGPath) -> [CGPoint] {
		var out: [CGPoint] = []
		path.applyWithBlock { element in
			if element.pointee.type != .closeSubpath { out.append(element.pointee.points[0]) }
		}
		return out
	}

	/// How far the outline moved between two moments, point for point: the
	/// average and the worst of it, in pixels.
	private func moved(_ bubble: Bubble, from: Double, to: Double) throws -> (mean: Double, most: Double) {
		let shape = box(bubble)
		func outline(_ time: Double) -> [CGPoint] {
			points(Bubbling.paths(bubble, box: shape, pointingAt: nil,
			                      frame: size, pass: 0, at: time).body)
		}
		let before = outline(from), after = outline(to)
		try #require(before.count == after.count)
		let steps = zip(before, after).map { hypot($1.x - $0.x, $1.y - $0.y) }
		return (steps.reduce(0, +) / Double(steps.count), steps.max() ?? 0)
	}

	/// **How much.** A pixel and a bit at 720p, and never as much as the line is
	/// wide — which is the number it was chosen against: under that, the line has
	/// been *redrawn*, and over it the bubble is changing shape.
	@Test func theLineMovesByAboutAPixel() throws {
		let bubble = Bubble(text: "still thinks glitter is a colour", seed: 3)
		let step = try moved(bubble, from: 1, to: 1.125)
		let weight = Bubbling.lineWidth(for: size)
		// Measured at 1280×720: 0.92 px on average and 2.42 px at the worst
		// point, against a line 3.24 px wide.
		#expect(step.mean > 0.3, "the line barely moved: \(step.mean) px")
		#expect(step.mean < weight,
		        "the line moved \(step.mean) px, and it is only \(weight) px wide")
		#expect(step.most < 2 * weight, "the worst point moved \(step.most) px")

		// And it stays in that range over a run of drawings rather than wandering
		// off: this is a hand redrawing one line, not a shape being animated.
		var worst = 0.0
		for beat in 0 ..< 24 {
			let at = 1 + Double(beat) / Bubbling.drawingsPerSecond
			worst = max(worst, try moved(bubble, from: 1, to: at).most)
		}
		#expect(worst < 3 * weight,
		        "the outline drifted \(worst) px away from where it started")
	}

	/// **Stepped, not continuous.** Two moments inside one drawing are the same
	/// drawing; two moments either side of a beat are not.
	@Test func aDrawingIsHeldAndThenReplaced() throws {
		let bubble = Bubble(text: "still thinks glitter is a colour", seed: 3)
		let beat = 1 / Bubbling.drawingsPerSecond
		#expect(try painted(bubble, at: 1).bytes == painted(bubble, at: 1 + beat * 0.9).bytes,
		        "the drawing changed inside its own turn on the screen")
		#expect(try painted(bubble, at: 1).bytes != painted(bubble, at: 1 + beat).bytes,
		        "the drawing did not change on the beat")
		// Eight a second, so a second of programme is eight drawings and not
		// twenty-five. Counted rather than asserted about, because the whole
		// argument for holding is the count.
		var frames: [[UInt8]] = []
		for frame in 0 ..< 25 { frames.append(try painted(bubble, at: 1 + Double(frame) / 25).bytes) }
		var drawings = 1
		for (before, after) in zip(frames, frames.dropFirst()) where before != after { drawings += 1 }
		#expect(drawings == 8, "a second of programme was \(drawings) drawings")
	}

	/// **How much a frame changes**, in pixels touched: a percent of the frame,
	/// which is a fringe on a line and not a bubble in motion.
	@Test func consecutiveDrawingsDifferAndBySmallAmounts() throws {
		let bubble = Bubble(text: "still thinks glitter is a colour", seed: 3)
		let a = try painted(bubble, at: 1), b = try painted(bubble, at: 1.125)
		var touched = 0
		for y in 0 ..< a.height {
			for x in 0 ..< a.width where a.alpha(x: x, y: y) != b.alpha(x: x, y: y) {
				touched += 1
			}
		}
		let paper = a.covered
		// Measured at 1280×720: 1,339 pixels changed, of 32,242 the bubble
		// covers and 921,600 in the frame. Four percent of the bubble and a
		// seventh of a percent of the picture.
		#expect(touched > 100, "nothing moved at all: \(touched) pixels")
		#expect(Double(touched) < Double(paper) * 0.25,
		        "\(touched) pixels moved out of \(paper) drawn — that is not a redrawn line")
	}

	/// **The words do not move.** Sampled over a run of frames, exactly: the
	/// paper is the same paper and the type is the same type, whatever the
	/// outline round it is doing.
	@Test func theWordsDoNotMoveAcrossARunOfFrames() throws {
		let bubble = Bubble(text: "still thinks glitter is a colour", seed: 3)
		let shape = box(bubble)
		// Exactly the rectangle the type is drawn in — not the paper's, whose
		// corners are outside the outline by construction, so that what is being
		// asked about is the words and not the line round them.
		let style = Project().style(named: "bubble")
		let measured = try #require(
			Bubbling.words(bubble.text, style: style, frame: size, width: bubble.width)).size
		let inside = CGRect(x: shape.midX - measured.width / 2, y: shape.midY - measured.height / 2,
		                    width: measured.width, height: measured.height)
		func ink(_ canvas: BubbleCanvas) -> [Double] {
			var out: [Double] = []
			for y in stride(from: Int(inside.minY), to: Int(inside.maxY), by: 1) {
				for x in stride(from: Int(inside.minX), to: Int(inside.maxX), by: 1) {
					out.append(canvas.darkness(x: x, y: y))
				}
			}
			return out
		}
		let first = ink(try painted(bubble, at: 1))
		let lettering = first.count { $0 > 0.5 }
		#expect(lettering > 200, "there is no lettering to measure: \(lettering) pixels")
		#expect(lettering < first.count / 2, "that is not lettering, that is a block")
		for frame in 1 ... 25 {
			let at = 1 + Double(frame) / 25
			#expect(ink(try painted(bubble, at: at)) == first,
			        "the words moved by frame \(frame), at \(at)s")
		}
	}

	/// **The still one is still**, and it is the drawing this program drew before
	/// any of this existed — which is what `breath: 0` is for.
	@Test func withNoBreathNothingMoves() throws {
		let still = Bubble(text: "still thinks glitter is a colour", seed: 3, breath: 0)
		let reference = try painted(still, at: 1).bytes
		for at in [1.04, 1.125, 1.5, 2.0, 3.99] {
			#expect(try painted(still, at: at).bytes == reference, "it moved at \(at)s")
		}
		// And it is not the same as the breathing one, or `breath:` does nothing.
		let alive = Bubble(text: "still thinks glitter is a colour", seed: 3)
		#expect(try painted(alive, at: 1).bytes != reference)
	}

	/// **Reproducible.** The drawing is a function of the seed and the time, and
	/// of nothing else — not of which span the bubble happens to be on, and not
	/// of how the moment was arrived at.
	@Test func theSameSeedAndTimeIsTheSameDrawing() throws {
		func drawn(seed: Int, at time: Double, from: Double, to: Double) throws -> [UInt8] {
			try painted(Bubble(text: "still thinks glitter is a colour", seed: seed),
			            at: time, from: from, to: to).bytes
		}
		#expect(try drawn(seed: 3, at: 1.3, from: 0, to: 4)
			== drawn(seed: 3, at: 1.3, from: 0, to: 4))
		#expect(try drawn(seed: 3, at: 1.3, from: 0, to: 4)
			!= drawn(seed: 4, at: 1.3, from: 0, to: 4))
		// The beat is the programme's, not the bubble's: the same instant of the
		// programme is the same drawing however long the bubble has been up.
		// Which is why a nudged `from:` does not redraw every frame of it.
		#expect(try drawn(seed: 3, at: 1.3, from: 0, to: 4)
			== drawn(seed: 3, at: 1.3, from: 0.7, to: 4))
	}

	/// The other two shapes breathe as well — a thought bubble's cloud and a
	/// box's rectangle are drawn lines too, and a still box beside a breathing
	/// speech bubble is a box that was printed rather than drawn.
	@Test func allThreeShapesBreathe() throws {
		for shape in Bubble.Shape.allCases {
			let bubble = Bubble(shape: shape, text: "glitter", seed: 6,
			                    at: CGPoint(x: 0.5, y: 0.14))
			let resolved = shown(bubble)
			func drawn(_ time: Double) throws -> [UInt8] {
				BubbleCanvas(try #require(OverlayPainter.bubbleImage(
					bubble, resolved: resolved, project: Project(),
					size: size, at: time))).bytes
			}
			#expect(try drawn(1) != drawn(1.125), "a \(shape.rawValue) bubble is still")
			#expect(try drawn(1) == drawn(1.1), "a \(shape.rawValue) bubble boils")
		}
	}
}

// MARK: - What the export gets

@Suite struct BubbleLayerTests {

	private let size = CGSize(width: 640, height: 360)

	private func shapes(in layer: CALayer) -> [CAShapeLayer] {
		((layer.sublayers ?? []).flatMap { shapes(in: $0) })
			+ ((layer as? CAShapeLayer).map { [$0] } ?? [])
	}

	private func tree(_ path: AnchorPath?, breath: Double = 1) -> CALayer {
		let overlay = Overlay(
			kind: .bubble(Bubble(text: "still thinks glitter is a colour", seed: 3,
			                     breath: breath, at: CGPoint(x: 0.3, y: 0.2))),
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

	/// A still bubble pointing at a fixed spot never moves, so nothing is
	/// animated and the file pays for nothing.
	@Test func aStillBubbleOnAFixedSpotIsDrawnOnce() {
		let animated = shapes(in: tree(nil, breath: 0)).compactMap { $0.animation(forKey: "path") }
		#expect(animated.isEmpty)
		#expect(shapes(in: tree(nil, breath: 0)).allSatisfy { $0.path != nil })
	}

	/// A breathing one on a fixed spot is keyframed even though nothing it points
	/// at has moved — the *hand* moved — and the keyframes are held rather than
	/// interpolated, which is the difference between a second drawing and a
	/// rubber line.
	@Test func aBreathingBubbleIsSteppedThroughItsDrawings() throws {
		let animated = shapes(in: tree(nil)).compactMap {
			$0.animation(forKey: "path") as? CAKeyframeAnimation
		}
		#expect(animated.count == 2, "both strokes should be redrawn: \(animated.count)")
		let animation = try #require(animated.first)
		#expect(animation.calculationMode == .discrete,
		        "the drawings are being interpolated: \(animation.calculationMode)")
		// Two seconds at eight a second, and one key time more than there are
		// values: the last one closes the final drawing rather than opening
		// another.
		let values = try #require(animation.values as? [CGPath])
		#expect(values.count == 16, "two seconds came out as \(values.count) drawings")
		#expect(animation.keyTimes?.count == values.count + 1,
		        "discrete keyframes want one key time more than they have values")
		#expect(animation.keyTimes?.last == 1)
		// Every drawing is a different drawing, and all of them the same length,
		// which is Core Animation's one condition on a path.
		let counts = values.map { path -> Int in
			var points = 0
			path.applyWithBlock { _ in points += 1 }
			return points
		}
		#expect(Set(counts).count == 1, "the drawings have different point counts")
		func corners(_ path: CGPath) -> [CGPoint] {
			var out: [CGPoint] = []
			path.applyWithBlock { element in
				if element.pointee.type != .closeSubpath { out.append(element.pointee.points[0]) }
			}
			return out
		}
		#expect(corners(values[0]) != corners(values[1]),
		        "two consecutive drawings are the same drawing")
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
		// Inside a drawing's turn rather than on the beat it changes on: a
		// presentation time landing exactly on a boundary is a question about
		// rounding and not one about the drawing.
		let a = try await frame(in: first, at: 1.44)
		let b = try await frame(in: second, at: 1.44)
		let c = try await frame(in: other, at: 1.44)
		let same = redrawn(a, b)
		let different = redrawn(a, c)
		// Measured: not one pixel, against 0.29% of the frame for a second seed.
		// The bounds are an order of magnitude either side of those, because what
		// is being asked is "the same drawing" against "a different one".
		#expect(same < 0.0002, "two renders of one project disagree over \(same) of the frame")
		#expect(different > 0.001,
		        "two seeds drew the same bubble: \(different) against \(same)")
	}

	/// The drawings survive the encoder, and they are held while they are up.
	///
	/// The only place the two implementations of the drawing clock can be checked
	/// against each other end to end: the layer path steps through `.discrete`
	/// keyframes and the frame path quantises the time it is handed, and if they
	/// disagreed about where the beat falls this is where it would show. Frames
	/// chosen inside a drawing's turn rather than on its edge, because a
	/// presentation time landing exactly on a beat is a coin toss and not a
	/// claim worth making.
	@Test func theEncodedFramesHoldEachDrawing() async throws {
		let url = try await rendered(3)
		defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
		let early = try await frame(in: url, at: 1.04)
		let held = try await frame(in: url, at: 1.08)
		let next = try await frame(in: url, at: 1.20)
		let inside = redrawn(early, held)
		let across = redrawn(early, next)
		// Measured: not one pixel within a drawing, against 0.08% of the frame
		// across a beat — which at 640×360 is the seven hundred pixels a line
		// two hundred and forty points long leaves when it moves by most of one.
		#expect(inside < 0.0002, "the drawing changed inside its own turn: \(inside)")
		#expect(across > 0.0004,
		        "the drawing did not change across a beat: \(across) against \(inside)")
	}

	/// How many pixels of two decoded frames are *properly* different, as a
	/// fraction of the frame.
	///
	/// The mean below is the right measure for "the same drawing or a different
	/// one", where the whole outline has moved. It is the wrong one for "the same
	/// drawing at two moments", because the two frames are two lossy encodings of
	/// one picture and the encoder's noise is spread thinly over all of it —
	/// enough of it, under load, to swamp a line that moved by a pixel. A moved
	/// line is the other shape: a few hundred pixels that changed by a lot. So
	/// this counts those and ignores the haze.
	private func redrawn(_ a: [UInt8], _ b: [UInt8]) -> Double {
		guard a.count == b.count, !a.isEmpty else { return .infinity }
		var count = 0
		for index in stride(from: 0, to: a.count, by: 4)
			where abs(Int(a[index]) - Int(b[index])) > 48 { count += 1 }
		return Double(count) / Double(a.count / 4)
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
