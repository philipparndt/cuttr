import AppKit
import CuttrCompose
import CuttrKit
import Testing
@testable import CuttrUI

/// Dragging a bubble around the picture in the panel.
///
/// The arithmetic itself is measured in ``BubblePlacingTests``, against the
/// pixels a render puts down. What is left for this side is the part that only
/// the view knows: **the picture is scaled and letterboxed**, so a drag in view
/// points has to become the same fraction of frame height that a hand-typed
/// number means, whatever size the pane happens to be. Get that wrong and a
/// bubble dragged to somebody's ear lands on their shoulder in the render — and
/// it would look right in whichever window size it was developed at.
///
/// Driven through the view's own ``FramePreview/begin(at:)``,
/// ``FramePreview/drag(to:)`` and ``FramePreview/end()`` rather than by sending
/// events. An `NSEvent` needs a window to have a location in, and what is under
/// test is the arithmetic between a point in this view and a number in the file.
/// Nothing here dispatches a key event: an unhandled one reaches `NSResponder`
/// and beeps on the machine the test is running on.
@Suite @MainActor struct BubbleDragTests {

	/// The spot the bubble is about, in the frame's unit coordinates.
	private let spot = CGPoint(x: 0.4, y: 0.45)

	/// One bubble on a card, written the way a file writes it and resolved the
	/// way the window resolves it.
	private func bubble(offset: CGPoint = Bubble.standoff,
	                    tail: CGPoint = .zero) throws -> (Project, ResolvedOverlay) {
		let project = try ProjectReader.read("""
			output:
			  size: 1920x1080
			  fps:  25

			timeline:
			  - card: 00:04.000

			overlays:
			  - bubble: glitter dust
			    seed:   4
			    breath: 0
			    at:     [\(spot.x), \(spot.y)]
			    offset: [\(offset.x), \(offset.y)]
			    tail:   [\(tail.x), \(tail.y)]
			    from:   00:00.000
			    to:     00:04.000
			    in:     cut
			    out:    cut
			""")
		let out = try Resolver.resolve(project, baseURL: URL(fileURLWithPath: "/"))
		return (project, try #require(out.overlays.first))
	}

	/// The picture, at a size, with the bubble in it and somewhere for the two
	/// numbers to land.
	private func preview(
		_ size: NSSize, offset: CGPoint = Bubble.standoff, tail: CGPoint = .zero
	) throws -> (view: FramePreview, written: () -> (offset: CGPoint?, tail: CGPoint?)) {
		_ = NSApplication.shared
		let (project, resolved) = try bubble(offset: offset, tail: tail)
		let view = FramePreview(frame: NSRect(origin: .zero, size: size))
		view.aspect = project.output.size
		view.content = .bubble(resolved, of: project)
		final class Box { var offset: CGPoint?; var tail: CGPoint? }
		let box = Box()
		view.onOffset = { box.offset = $0 }
		view.onTail = { box.tail = $0 }
		return (view, { (box.offset, box.tail) })
	}

	/// Where the paper's middle is, in the frame's unit coordinates, for a bubble
	/// standing off from the spot by `offset`.
	///
	/// `x` is a fraction of the frame's **height** and a unit coordinate is a
	/// fraction of each side, so the horizontal one has to be turned round.
	private func paper(_ offset: CGPoint = Bubble.standoff) -> CGPoint {
		CGPoint(x: spot.x + offset.x * 1080 / 1920, y: spot.y + offset.y)
	}

	/// Where a point of the frame is in the view, worked out from the picture the
	/// view laid out — which is the one thing about the conversion this test is
	/// entitled to be told rather than to check.
	private func place(_ view: FramePreview, _ unit: CGPoint) -> NSPoint {
		NSPoint(x: view.picture.minX + unit.x * view.picture.width,
		        y: view.picture.minY + unit.y * view.picture.height)
	}

	/// A whole drag: take hold at one point, move to another, let go.
	private func drag(_ view: FramePreview, from: NSPoint, to: NSPoint) {
		view.begin(at: from)
		view.drag(to: to)
		view.end()
	}

	/// The sizes a pane is dragged to. The picture letterboxes inside each, so
	/// the offsets from the view's edges are different in every one — which is
	/// the part a conversion written against one window silently gets wrong.
	private var sizes: [NSSize] {
		[NSSize(width: 240, height: 206), NSSize(width: 420, height: 206),
		 NSSize(width: 300, height: 340), NSSize(width: 620, height: 480)]
	}

	// MARK: - The conversion

	/// **A point in the view becomes the number that draws there.**
	///
	/// Dropped on the same fraction of the picture at four sizes of pane, the
	/// drag writes the same number every time — and that number is the one the
	/// renderer reads to put the paper there.
	@Test func aPointInTheViewIsTheSameNumberAtAnySize() throws {
		var written: [CGPoint] = []
		for size in sizes {
			let (view, result) = try preview(size)
			// Grab the paper by its own middle so there is no offset between the
			// pointer and the thing being moved, then drop it two thirds of the
			// way across and three fifths up.
			let target = CGPoint(x: 0.66, y: 0.6)
			drag(view, from: place(view, paper()), to: place(view, target))
			let offset = try #require(result().offset, "nothing was written at \(size)")
			written.append(offset)

			// The number is the one the format means: the distance from the spot
			// it is about, in fractions of the frame **height** on both axes.
			let frame = CGSize(width: 1920, height: 1080)
			let expected = CGPoint(
				x: (target.x - spot.x) * frame.width / frame.height,
				y: (target.y - spot.y))
			// Within a step and a pixel of the picture: the pane is a couple of
			// hundred points across, so one point of it is worth several steps
			// and rounding cannot be tighter than that.
			let slack = 2 * BubblePlacing.step + 1 / view.picture.height
			#expect(abs(offset.x - expected.x) < slack,
			        "at \(size) x came out \(offset.x), wanted \(expected.x)")
			#expect(abs(offset.y - expected.y) < slack,
			        "at \(size) y came out \(offset.y), wanted \(expected.y)")
			#expect(result().tail == nil, "a drag on the paper wrote a tail")
		}
		// And the four sizes agree with each other to within a step or two,
		// which is the claim in its plainest form.
		for other in written.dropFirst() {
			#expect(abs(other.x - written[0].x) < 0.006, "\(written)")
			#expect(abs(other.y - written[0].y) < 0.006, "\(written)")
		}
	}

	/// And the number renders ink where the point was — measured on a full-size
	/// frame, which is the render the panel is standing in for.
	@Test func theNumberTheViewWritesDrawsThereInTheRender() throws {
		for size in sizes {
			let (view, result) = try preview(size)
			let target = CGPoint(x: 0.62, y: 0.66)
			drag(view, from: place(view, paper()), to: place(view, target))
			let offset = try #require(result().offset)

			let (project, resolved) = try bubble(offset: offset)
			let frame = CGSize(width: 1920, height: 1080)
			guard case .bubble(let bubble) = resolved.overlay.kind else {
				Issue.record("the overlay stopped being a bubble")
				return
			}
			let placed = BubblePlacing.placement(bubble, resolved: resolved, project: project,
			                                     size: frame, at: 0)
			let wanted = CGPoint(x: target.x * frame.width, y: target.y * frame.height)
			// A pixel or two of 1080, which is what a point of the little picture
			// is worth at this scale.
			#expect(hypot(placed.paper.x - wanted.x, placed.paper.y - wanted.y)
				< frame.height / view.picture.height + 2,
			        "at \(size) the render put the paper at \(placed.paper), wanted \(wanted)")
		}
	}

	// MARK: - Two handles

	/// **The tip is grabbable, and grabbing it leaves the paper alone.**
	@Test func theTipIsItsOwnHandle() throws {
		// Aimed well below the spot, so the diamond is a long way from the disc
		// and there is no question which one is being taken hold of.
		let (view, result) = try preview(NSSize(width: 420, height: 206),
		                                tail: CGPoint(x: 0, y: -0.2))
		let frame = CGSize(width: 1920, height: 1080)
		// `tail: [0, -0.2]` is a fifth of the frame's height below the spot,
		// which on the vertical axis is a fifth of the unit square too.
		let tip = CGPoint(x: spot.x, y: spot.y - 0.2)
		drag(view, from: place(view, tip), to: place(view, CGPoint(x: 0.2, y: 0.12)))

		let tail = try #require(result().tail, "the tip did not write anything")
		#expect(result().offset == nil, "dragging the tip moved the paper")
		#expect(abs(tail.x - (0.2 - spot.x) * frame.width / frame.height) < 0.01, "\(tail)")
		#expect(abs(tail.y - (0.12 - spot.y)) < 0.01, "\(tail)")
	}

	/// And the reverse: taking hold of the paper writes only `offset:`.
	@Test func thePaperIsItsOwnHandleToo() throws {
		let (view, result) = try preview(NSSize(width: 420, height: 206),
		                                tail: CGPoint(x: 0, y: -0.2))
		drag(view, from: place(view, paper()), to: place(view, CGPoint(x: 0.75, y: 0.7)))
		#expect(result().offset != nil)
		#expect(result().tail == nil, "dragging the paper re-aimed the tail")
	}

	/// The tip wins where the two are on top of each other.
	///
	/// A tail aimed at a mouth beside a bubble that covers the mouth is an
	/// ordinary bubble, and the tip has to stay reachable in it — the paper is
	/// the size of a sentence and the tip is a few points across, so losing the
	/// small one to the large one would leave it unreachable.
	@Test func theTipIsNotLostUnderThePaper() throws {
		// `offset: [0, 0]` puts the paper *on* the spot, and `tail: [0, 0]` puts
		// the tip there too: the one arrangement where they coincide.
		let (view, result) = try preview(NSSize(width: 420, height: 206), offset: .zero)
		drag(view, from: place(view, spot), to: place(view, CGPoint(x: 0.8, y: 0.2)))
		#expect(result().tail != nil, "the tip was not reachable under the paper")
		#expect(result().offset == nil)
	}

	// MARK: - A drag that changes nothing

	/// **Let go where you took hold and nothing is written**: no key, no diff,
	/// no version kept. The emitter's stability is a house rule and a picture
	/// somebody merely looked at is not an edit.
	@Test func aDragThatLandsWhereItStartedWritesNothing() throws {
		for size in sizes {
			// The paper, taken by its middle and let go there.
			let (paper, paperResult) = try preview(size)
			let at = place(paper, self.paper())
			drag(paper, from: at, to: at)
			#expect(paperResult().offset == nil, "at \(size) a still paper wrote an offset")

			// And a click with no movement at all, which is the same gesture
			// without the drag events.
			let (again, againResult) = try preview(size)
			again.begin(at: at)
			again.end()
			#expect(againResult().offset == nil, "at \(size) a click wrote an offset")
			#expect(againResult().tail == nil)

			// The tip, likewise.
			let (tip, tipResult) = try preview(size, tail: CGPoint(x: 0, y: -0.18))
			let point = place(tip, CGPoint(x: spot.x, y: spot.y - 0.18))
			drag(tip, from: point, to: point)
			#expect(tipResult().tail == nil, "at \(size) a still tip wrote a tail")
		}
	}

	/// A drag of one point that rounds back to where it was writes nothing
	/// either — the number is what is compared, not the mouse.
	@Test func aDragTooSmallToChangeTheNumberWritesNothing() throws {
		let (view, result) = try preview(NSSize(width: 620, height: 480))
		let at = place(view, paper())
		// A tenth of a point: below the step the number is written in, so the
		// number does not change and neither does the file.
		view.begin(at: at)
		view.drag(to: NSPoint(x: at.x + 0.1, y: at.y))
		view.end()
		#expect(result().offset == nil, "a tenth of a point was written as an edit")
	}

	// MARK: - Still a picture of the other overlays

	/// A caption is dragged the way it always was. The bubble's two handles are
	/// a second arrangement inside this view, not a replacement for the first.
	@Test func aCaptionIsUnaffectedByAnyOfThis() {
		_ = NSApplication.shared
		let view = FramePreview(frame: NSRect(x: 0, y: 0, width: 420, height: 206))
		view.aspect = CGSize(width: 1920, height: 1080)
		view.content = .caption("hello", TextStyle.lowerThird)
		var moved: CGPoint?
		view.onMove = { moved = $0 }
		let to = NSPoint(x: view.picture.minX + view.picture.width * 0.3,
		                 y: view.picture.minY + view.picture.height * 0.8)
		view.begin(at: NSPoint(x: view.picture.midX, y: view.picture.midY))
		view.drag(to: to)
		view.end()
		let spot = try? #require(moved)
		#expect(abs((spot?.x ?? 0) - 0.3) < 0.01)
		#expect(abs((spot?.y ?? 0) - 0.8) < 0.01)
	}
}
