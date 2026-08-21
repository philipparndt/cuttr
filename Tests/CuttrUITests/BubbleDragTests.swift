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
		 NSSize(width: 300, height: 340), NSSize(width: 620, height: 480), enlarged]
	}

	/// And the size the picture opens at when somebody asks for a bigger one to
	/// place in. In the list above because that is where the precise placing
	/// happens: a conversion that held in a pane and drifted in the big picture
	/// would be wrong in exactly the place somebody went for accuracy.
	private var enlarged: NSSize {
		Placing.size(for: NSSize(width: 1920, height: 1080),
		             in: NSRect(x: 0, y: 0, width: 1440, height: 900))
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

	// MARK: - What the picture shows after the mouse is let go

	/// **The placed position holds.** A drag that has been let go leaves the
	/// picture showing where the bubble was put, not where it came from.
	///
	/// It used to show where it came from. `end()` handed the numbers to the
	/// document and forgot them in the same breath, so from the instant the
	/// mouse came up the picture was drawn from whatever the panel had been
	/// given *before* the drag — and the bubble sat back at its old place until
	/// a reload arrived carrying the new one. Which is a flicker on a good day
	/// and, for any reload that is deferred or built from the project the panel
	/// already had, a bubble that visibly refuses to be moved.
	@Test func theBubbleStaysWhereItWasPutDown() throws {
		for size in sizes {
			let (view, result) = try preview(size, tail: CGPoint(x: 0, y: -0.2))
			let target = CGPoint(x: 0.7, y: 0.62)
			drag(view, from: place(view, paper()), to: place(view, target))
			let written = try #require(result().offset)
			let shown = try #require(view.numbersForTesting)
			#expect(shown.offset == written,
			        "at \(size) the picture went back to \(shown.offset)")
			// And the handle that was not touched is where it was.
			#expect(shown.tail == CGPoint(x: 0, y: -0.2))

			// The tip, likewise, and the paper it was dragged past stays put.
			let tip = CGPoint(x: spot.x, y: spot.y - 0.2)
			drag(view, from: place(view, tip), to: place(view, CGPoint(x: 0.22, y: 0.14)))
			let aimed = try #require(result().tail)
			let now = try #require(view.numbersForTesting)
			#expect(now.tail == aimed, "at \(size) the tip went back to \(now.tail)")
			#expect(now.offset == written, "at \(size) aiming the tail moved the paper")
		}
	}

	/// **And it holds against the reload that carries the old numbers.**
	///
	/// The panel is rebuilt after every edit and hands the picture the overlay
	/// again — sometimes the one from before the drag, because the project has
	/// to be written, resolved and passed along before the new value comes back
	/// round. Handed that, the picture must not go backwards.
	@Test func aReloadWithTheOldNumbersDoesNotPutItBack() throws {
		let (view, result) = try preview(NSSize(width: 420, height: 206))
		let (project, stale) = try bubble()
		drag(view, from: place(view, paper()), to: place(view, CGPoint(x: 0.72, y: 0.3)))
		let written = try #require(result().offset)

		// The overlay exactly as it was before the drag, arriving late.
		view.content = .bubble(stale, of: project)
		#expect(view.numbersForTesting?.offset == written,
		        "a stale reload put the bubble back at \(String(describing: view.numbersForTesting))")

		// And the one that has caught up is followed, so the picture is the
		// file's again rather than a memory of a gesture.
		let (_, caught) = try bubble(offset: written)
		view.content = .bubble(caught, of: project)
		#expect(view.numbersForTesting?.offset == written)

		// A number typed into the field beside the picture wins outright: it is
		// newer than the drag, and a picture that ignored it would be a field
		// that does nothing.
		let typed = CGPoint(x: -0.2, y: 0.05)
		let (_, edited) = try bubble(offset: typed)
		view.content = .bubble(edited, of: project)
		#expect(view.numbersForTesting?.offset == typed,
		        "the picture ignored a typed number")
	}

	/// A second drag measures from where the first one left it.
	///
	/// The picture is the only thing that knows the bubble has moved until the
	/// file comes back, so "did this drag change anything" has to be asked
	/// against what it is showing. Asked against the stale model, a drag back to
	/// the bubble's old place would write nothing and leave the picture
	/// disagreeing with the file.
	@Test func aSecondDragIsMeasuredFromWhereTheFirstLeftIt() throws {
		let (view, result) = try preview(NSSize(width: 420, height: 206))
		let start = place(view, paper())
		drag(view, from: start, to: place(view, CGPoint(x: 0.72, y: 0.3)))
		let first = try #require(result().offset)
		// Straight back to where it began, with the panel none the wiser: that
		// is a change from what the picture shows, so it is written.
		drag(view, from: place(view, CGPoint(x: 0.72, y: 0.3)), to: start)
		let second = try #require(result().offset)
		#expect(second != first, "the second drag wrote the first drag's number")
		#expect(view.numbersForTesting?.offset == second)
	}

	// MARK: - Through the panel

	/// The panel that owns the picture, wired the way the window wires it: every
	/// edit is applied, resolved and handed back, which is what makes a drag
	/// come round to the place it was made.
	private func panel() throws -> (PropertiesPanel, () -> Project) {
		_ = NSApplication.shared
		final class Box { var project = Project(); var reloads = 0 }
		let box = Box()
		box.project = try bubble().0
		let panel = PropertiesPanel()
		panel.frame = NSRect(x: 0, y: 0, width: 340, height: 900)
		let selection = ProjectSelection.overlay(.project(0))
		func push() {
			box.reloads += 1
			panel.resolved = try? Resolver.resolve(box.project,
			                                       baseURL: URL(fileURLWithPath: "/"))
			panel.reload(box.project, vocabulary: ComposeDocument.Vocabulary(),
			             selection: selection)
			panel.layoutSubtreeIfNeeded()
		}
		panel.onChange = { next in
			box.project = next
			push()
		}
		push()
		return (panel, { box.project })
	}

	/// **A drag through the panel puts the number in the project and leaves the
	/// picture showing it.**
	///
	/// The form is rebuilt on every edit, so a drag is a gesture that destroys
	/// the thing it was made in. The picture is kept across that rebuild — for
	/// the same reason the selected range and the selected key are — and the
	/// bubble is where it was put down both before the file comes back and
	/// after.
	@Test func aDragThroughThePanelLeavesTheBubbleWhereItWasPut() throws {
		let (panel, project) = try self.panel()
		let picture = try #require(panel.previewForTesting, "the panel drew no picture")
		let target = CGPoint(x: 0.68, y: 0.64)
		drag(picture, from: place(picture, paper()), to: place(picture, target))

		let written = project().overlays[0].offset
		#expect(written != Bubble.standoff, "the drag wrote nothing into the project")
		#expect(panel.previewForTesting === picture,
		        "the rebuild threw the picture away, and with it what the drag placed")
		#expect(picture.numbersForTesting?.offset == written,
		        "the picture shows \(String(describing: picture.numbersForTesting))")

		// And the reuse does not leave a constraint behind on every rebuild. The
		// form pins the picture's width to its own, and a picture that is added
		// again is a second pin unless the first one went with the removal.
		for _ in 0 ..< 3 {
			panel.reload(project(), vocabulary: ComposeDocument.Vocabulary(),
			             selection: .overlay(.project(0)))
		}
		#expect(panel.previewForTesting === picture)
		let pinned = picture.superview?.constraints.filter {
			($0.firstItem === picture || $0.secondItem === picture)
				&& $0.firstAttribute == .width && $0.secondAttribute == .width
		}
		#expect(pinned?.count == 1, "\(pinned?.count ?? 0) width pins after four rebuilds")
	}

	// MARK: - A bigger picture to place in

	/// **The bigger picture places the same numbers as the little one.**
	///
	/// Dragged to the same fraction of the frame in a picture three times the
	/// size, through a panel that is a window of its own, the number that lands
	/// in the file is the same. It is the same view class doing the arithmetic
	/// on purpose — a panel that placed by its own would be a second answer to
	/// a question the renderer has already answered.
	@Test func theBiggerPictureWritesWhatTheLittleOneWould() throws {
		let aimed = CGPoint(x: 0, y: -0.2)
		let (little, result) = try preview(NSSize(width: 240, height: 206), tail: aimed)
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
		                      styleMask: [.titled], backing: .buffered, defer: true)
		let panel = PlacingPanel()
		defer { panel.close() }
		panel.show(like: little, titled: "glitter dust", over: window,
		           output: NSSize(width: 1920, height: 1080))
		let big = panel.previewForTesting
		panel.contentView?.layoutSubtreeIfNeeded()
		#expect(big.picture.width > little.picture.width * 2,
		        "the bigger picture is \(big.picture.width) wide against \(little.picture.width)")

		// The paper, dropped at the same fraction of the frame in each.
		let target = CGPoint(x: 0.72, y: 0.62)
		drag(big, from: place(big, paper()), to: place(big, target))
		let fromBig = try #require(result().offset, "the paper was not draggable in the panel")

		let (small, smallResult) = try preview(NSSize(width: 240, height: 206), tail: aimed)
		drag(small, from: place(small, paper()), to: place(small, target))
		let fromLittle = try #require(smallResult().offset)
		// A step or two apart at most: one point of the little picture is worth
		// several of the frame, and that coarseness is the reason the big one
		// exists — but the two must be the same number, not two numbers.
		#expect(abs(fromBig.x - fromLittle.x) < 0.006, "\(fromBig) against \(fromLittle)")
		#expect(abs(fromBig.y - fromLittle.y) < 0.006, "\(fromBig) against \(fromLittle)")

		// And the tail is a handle there too: both points, or the big picture is
		// only half a place to work.
		let tip = CGPoint(x: spot.x, y: spot.y - 0.2)
		drag(big, from: place(big, tip), to: place(big, CGPoint(x: 0.2, y: 0.12)))
		let tail = try #require(result().tail, "the tip was not draggable in the panel")
		#expect(abs(tail.x - (0.2 - spot.x) * 1920 / 1080) < 0.006, "\(tail)")
		#expect(abs(tail.y - (0.12 - spot.y)) < 0.006, "\(tail)")
		// What was placed in the big picture stays placed in the big picture.
		#expect(big.numbersForTesting?.offset == fromBig)
		#expect(big.numbersForTesting?.tail == tail)
	}

	/// The bigger picture is the programme's shape, fills what it is given, and
	/// fits the window it hovers over.
	///
	/// Pure arithmetic, at three window sizes and two frame shapes, because the
	/// case that would go unnoticed is the small window: a picture sized to a
	/// fraction of a big screen and then shown over a laptop window would hang
	/// off the edge of it, and the part hanging off is the part somebody is
	/// dragging to.
	@Test func theBiggerPictureIsTheProgrammesShapeAndFitsTheWindow() {
		_ = NSApplication.shared
		let windows = [NSRect(x: 0, y: 0, width: 1440, height: 900),
		               NSRect(x: 0, y: 0, width: 700, height: 480),
		               NSRect(x: 200, y: 120, width: 2560, height: 1440)]
		for window in windows {
			for output in [NSSize(width: 1920, height: 1080), NSSize(width: 1080, height: 1920)] {
				let size = Placing.size(for: output, in: window)
				let view = FramePreview(frame: NSRect(origin: .zero, size: size))
				view.aspect = output

				// Nothing letterboxed: the panel is the shape of the picture
				// plus the strip that says what a drag writes, so the frame
				// fills it rather than sitting in the middle of it.
				#expect(abs(view.picture.width
					- (size.width - FramePreview.frameInset.width)) < 1.5,
				        "\(output) in \(window) left a margin: \(view.picture) in \(size)")
				#expect(abs(view.picture.height
					- (size.height - FramePreview.frameInset.height)) < 1.5,
				        "\(output) in \(window) left a margin: \(view.picture) in \(size)")

				// Inside the window, wherever the window is on the screen.
				let frame = Placing.place(size, inside: window)
				#expect(window.insetBy(dx: -0.5, dy: -0.5).contains(frame),
				        "\(frame) is not inside \(window)")

				// And bigger than the one in the properties panel, which is the
				// whole reason for asking.
				let panel = FramePreview(frame: NSRect(x: 0, y: 0, width: 240, height: 206))
				panel.aspect = output
				#expect(view.picture.width > panel.picture.width,
				        "\(output) in \(window): \(view.picture) is no bigger than \(panel.picture)")
				#expect(view.picture.height > panel.picture.height,
				        "\(output) in \(window): \(view.picture) is no bigger than \(panel.picture)")
			}
		}
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
