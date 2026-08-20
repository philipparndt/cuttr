import CoreGraphics
import CuttrKit
import Foundation
import Testing
@testable import CuttrCompose

/// Placing a bubble by dragging it: the arithmetic, and both directions of it.
///
/// The claim a draggable preview makes is not that a number changes. It is that
/// **the number renders ink where the point was** — at any size of picture, on
/// any shape of frame, at any moment of a shot where the face is walking. So
/// nearly everything here draws the bubble and measures the pixels, exactly as
/// the rest of ``BubbleDrawingTests`` does: a conversion that compiles is no
/// evidence at all, and the failure this guards against — a bubble dragged to
/// somebody's ear that lands on their shoulder in the render — is a failure of
/// a few pixels rather than of a type.
@Suite struct BubblePlacingTests {

	// MARK: - Bubbles to measure

	/// A bubble whose only ink is its type, so the middle of the ink is the
	/// middle of the paper.
	///
	/// The outline and the tail are ink too, and the tail goes on purpose where
	/// the paper does not — counting either would be measuring something else.
	/// `breath: 0` for the same reason it is elsewhere: a still drawing is the
	/// one whose position is a number rather than a number and a wobble.
	private func said(_ text: String = "glitter dust", at: CGPoint? = nil,
	                  tail: CGPoint = .zero) -> Bubble {
		Bubble(text: text, line: RGBA(r: 0, g: 0, b: 0, a: 0), seed: 4, breath: 0,
		       tail: tail, at: at)
	}

	/// And one with its line drawn, for the measurements that are about the tail.
	private func drawn(at: CGPoint? = nil, tail: CGPoint = .zero) -> Bubble {
		Bubble(text: "glitter", seed: 4, breath: 0, tail: tail, at: at)
	}

	private func shown(_ bubble: Bubble, path: AnchorPath? = nil,
	                   offset: CGPoint = Bubble.standoff) -> ResolvedOverlay {
		ResolvedOverlay(
			overlay: Overlay(kind: .bubble(bubble), span: .times(from: 0, to: 4),
			                 arrival: .cut, departure: .cut,
			                 anchor: path == nil ? nil : "mia-eye", offset: offset),
			origin: .project(0), appearance: 0, start: 0, end: 4, path: path)
	}

	private func painted(_ bubble: Bubble, offset: CGPoint, size: CGSize,
	                     path: AnchorPath? = nil, at time: Double = 0) throws -> BubbleCanvas {
		BubbleCanvas(try #require(OverlayPainter.bubbleImage(
			bubble, resolved: shown(bubble, path: path, offset: offset),
			project: Project(), size: size, at: time)))
	}

	/// A face walking across the shot, sampled ten a second as the solver
	/// samples, with a good deal of jitter on every sample.
	///
	/// More jitter than a real tracker has, and deliberately: the paper is
	/// placed against the *smoothed* path and the tail against the raw one, and
	/// the only thing that tells the two apart in a measurement is how far apart
	/// they are. A pixel of jitter would let a preview that inverted against the
	/// wrong one of them pass.
	private func walking(jitter: Double = 0.012) -> AnchorPath {
		AnchorPath(samples: (0 ... 40).map { step in
			let t = Double(step) / 10
			// Not random: a test that is a different test every run is not a
			// test. A fast wobble at the sample rate, which is what a fresh
			// measurement per sample looks like.
			let shake = sin(Double(step) * 2.7) * jitter
			return (t, CGPoint(x: 0.28 + t * 0.09 + shake, y: 0.46 + shake))
		})
	}

	/// The frames to check every conversion against.
	///
	/// Four sizes, three shapes, a factor of two between the smallest and the
	/// largest. The shapes are the ones that matter: `x` is a fraction of the
	/// frame's **height** like everything else in the format, so a conversion
	/// that reached for the width instead is exactly right on a square frame,
	/// out by a ninth on 4:3, and out by nearly half on 16:9.
	///
	/// The smallest is 360 tall rather than 180 because the measurements below
	/// weigh the type's own ink, and at 180 a two-word bubble is set in six
	/// pixels — too little ink to have a middle. The conversion has nothing in it
	/// that could care: every number in a bubble is a fraction of the frame.
	private var frames: [CGSize] {
		[CGSize(width: 640, height: 360), CGSize(width: 1280, height: 720),
		 CGSize(width: 800, height: 600), CGSize(width: 1080, height: 1080)]
	}

	// MARK: - A point becomes a number, and the number draws there

	/// **The round trip.** A point in the picture becomes an `offset:`, and that
	/// `offset:` puts ink where the point was — at every size and shape of frame.
	@Test func aPointBecomesTheNumberThatDrawsThere() throws {
		for size in frames {
			let bubble = said(at: CGPoint(x: 0.3, y: 0.35))
			let origins = BubblePlacing.origins(bubble, resolved: shown(bubble),
			                                    size: size, at: 0)

			// Two places to drop the paper, well apart and both well inside the
			// frame, so the edge has nothing to say about either.
			let a = CGPoint(x: 0.40 * size.width, y: 0.64 * size.height)
			let b = CGPoint(x: 0.68 * size.width, y: 0.38 * size.height)
			let toA = try #require(BubblePlacing.offset(forPaper: a, origins: origins, size: size))
			let toB = try #require(BubblePlacing.offset(forPaper: b, origins: origins, size: size))

			let inkA = try #require(try painted(bubble, offset: toA, size: size).ink)
			let inkB = try #require(try painted(bubble, offset: toB, size: size).ink)

			// Where the ink went, against where the point was. The tolerance is
			// the type's own weight inside its line — a sentence's ink is not
			// exactly centred on the box that holds it, because ascenders and
			// descenders are not symmetrical — and it scales with the frame
			// because everything about a bubble does.
			#expect(hypot(inkA.x - a.x, inkA.y - a.y) < 0.03 * size.height,
			        "at \(size) the paper landed \(inkA) for a drag to \(a)")
			#expect(hypot(inkB.x - b.x, inkB.y - b.y) < 0.03 * size.height,
			        "at \(size) the paper landed \(inkB) for a drag to \(b)")

			// And the sharp measurement: the ink moved by exactly what the
			// pointer moved by. Whatever bias the type's own shape has is the
			// same in both, so it subtracts out and what is left is the
			// conversion — to within a pixel, which is the step the number is
			// written in.
			#expect(abs((inkB.x - inkA.x) - (b.x - a.x)) < 1.5,
			        "at \(size) x drifted by \((inkB.x - inkA.x) - (b.x - a.x))")
			#expect(abs((inkB.y - inkA.y) - (b.y - a.y)) < 1.5,
			        "at \(size) y drifted by \((inkB.y - inkA.y) - (b.y - a.y))")
		}
	}

	/// The same for the tip: dropped on a spot, the tail reaches it.
	@Test func theTipLandsWhereItWasDropped() throws {
		for size in frames {
			let spot = CGPoint(x: 0.5, y: 0.6)
			let bubble = drawn(at: spot)
			let origins = BubblePlacing.origins(bubble, resolved: shown(bubble),
			                                    size: size, at: 0)
			// Down and to the left of the thing it is about: a hand, say, where
			// the spot being tracked is an eye.
			let target = CGPoint(x: 0.32 * size.width, y: 0.22 * size.height)
			var aimed = bubble
			aimed.tail = try #require(
				BubblePlacing.tail(forTip: target, origins: origins, size: size))

			let canvas = try painted(aimed, offset: Bubble.standoff, size: size)
			// The tail stops a little short of what it points at on purpose —
			// a tail that reached past its target would be a dent — so "it lands
			// there" is a few hundredths of the frame's height, as it is in
			// ``BubbleTailTests``. "It does not" is the whole standoff away.
			#expect(canvas.nearest(to: target) < 0.04 * size.height,
			        "at \(size) the tip missed by \(canvas.nearest(to: target))")
			let unaimed = try painted(bubble, offset: Bubble.standoff, size: size)
			#expect(unaimed.nearest(to: target) > 0.12 * size.height,
			        "at \(size) the unaimed tail was already there")
		}
	}

	// MARK: - Two handles, two numbers

	/// **Neither handle answers for the other.** What a drag on the paper writes
	/// does not depend on where the tail is aimed, and the reverse — they are
	/// measured from one place and they move different things.
	@Test func theTwoHandlesDoNotAnswerForEachOther() throws {
		let size = CGSize(width: 1280, height: 720)
		let spot = CGPoint(x: 0.45, y: 0.5)
		// The frame point both handles are being dropped on, and the number that
		// point is, worked out by hand: a quarter and a bit of the frame's
		// height to the right of the spot, a fifth of it below.
		let place = CGPoint(x: 0.7 * size.width, y: 0.3 * size.height)
		let expected = CGPoint(x: 0.444, y: -0.2)

		for tail in [CGPoint.zero, CGPoint(x: -0.3, y: 0.2)] {
			for offset in [CGPoint.zero, Bubble.standoff, CGPoint(x: 0.4, y: -0.3)] {
				let bubble = said(at: spot, tail: tail)
				let origins = BubblePlacing.origins(
					bubble, resolved: shown(bubble, offset: offset), size: size, at: 0)
				#expect(BubblePlacing.offset(forPaper: place, origins: origins, size: size)
					== expected, "offset moved with tail \(tail) or offset \(offset)")
				#expect(BubblePlacing.tail(forTip: place, origins: origins, size: size)
					== expected, "tail moved with tail \(tail) or offset \(offset)")
			}
		}

		// And on the picture. Moving the paper a long way leaves the tip on the
		// mouth it was aimed at, because the tip is measured from the face.
		let mouth = CGPoint(x: spot.x * size.width, y: (spot.y - 0.14) * size.height)
		let aimed = drawn(at: spot, tail: CGPoint(x: 0, y: -0.14))
		for offset in [Bubble.standoff, CGPoint(x: -0.34, y: 0.3)] {
			let canvas = try painted(aimed, offset: offset, size: size)
			let missed = canvas.nearest(to: mouth)
			#expect(missed < 0.04 * size.height,
			        "with the paper at \(offset) the tip left the mouth by \(missed)")
		}
	}

	// MARK: - A face that walks

	/// **The same place on the face is the same number at any moment.**
	///
	/// The origin travels, so a handle's position on screen is a function of the
	/// frame being looked at and the number it writes is relative to that frame.
	/// Two drags of the same gesture, three seconds apart on a walking face,
	/// have to write the same thing — and they only do if the arithmetic undoes
	/// exactly what the drawing did on the way, which for the paper means
	/// undoing the smoothing.
	@Test func theSameGestureIsTheSameNumberAtAnyMoment() throws {
		let size = CGSize(width: 1280, height: 720)
		let path = walking()
		let bubble = said()
		let offset = CGPoint(x: 0.12, y: 0.24)
		let resolved = shown(bubble, path: path, offset: offset)
		// A tenth of the frame's height to the right of wherever the paper is
		// at that moment: one gesture, two moments.
		var written: [CGPoint] = []
		for moment in [0.8, 3.2] {
			let placed = BubblePlacing.placement(bubble, resolved: resolved,
			                                     project: Project(), size: size, at: moment)
			let nudged = CGPoint(x: placed.home.x + 0.1 * size.height, y: placed.home.y)
			written.append(try #require(BubblePlacing.offset(
				forPaper: nudged, origins: placed.origins, size: size)))
		}
		#expect(written[0] == written[1],
		        "the same drag wrote \(written[0]) at 0.8s and \(written[1]) at 3.2s")
		#expect(abs(written[0].x - (offset.x + 0.1)) <= BubblePlacing.step)
		#expect(abs(written[0].y - offset.y) <= BubblePlacing.step)
	}

	/// The tip, likewise — and it is the raw anchor it is relative to, which on
	/// a jittering path is a visibly different point from the smoothed one.
	@Test func theTipsGestureIsAlsoTheSameNumberAtAnyMoment() throws {
		let size = CGSize(width: 1280, height: 720)
		let path = walking()
		let tail = CGPoint(x: 0.02, y: -0.16)
		let bubble = drawn(tail: tail)
		let resolved = shown(bubble, path: path)
		var written: [CGPoint] = []
		for moment in [0.8, 3.2] {
			let placed = BubblePlacing.placement(bubble, resolved: resolved,
			                                     project: Project(), size: size, at: moment)
			let tip = try #require(placed.tip)
			let nudged = CGPoint(x: tip.x - 0.05 * size.height, y: tip.y)
			written.append(try #require(BubblePlacing.tail(
				forTip: nudged, origins: placed.origins, size: size)))
		}
		#expect(written[0] == written[1],
		        "the same drag wrote \(written[0]) at 0.8s and \(written[1]) at 3.2s")
		#expect(abs(written[0].x - (tail.x - 0.05)) <= BubblePlacing.step)
		#expect(abs(written[0].y - tail.y) <= BubblePlacing.step)

		// The two origins really are different points on a path like this —
		// otherwise the test above would pass with the smoothing left in.
		let placed = BubblePlacing.placement(bubble, resolved: resolved, project: Project(),
		                                     size: size, at: 0.8)
		let paper = try #require(placed.origins.paper)
		let tip = try #require(placed.origins.tip)
		#expect(hypot(paper.x - tip.x, paper.y - tip.y) > 2 * BubblePlacing.step * size.height,
		        "the smoothed and the raw anchor are the same point: nothing is being tested")
	}

	// MARK: - Where there is nothing to be relative to

	/// **Outside the stretch that was solved there is no tip to place.**
	///
	/// The tail refuses to point at where a face last was — a tail frozen on a
	/// doorway somebody left through looks exactly like a tracker that has
	/// failed — so at such a moment nothing is drawn to grab, and a `tail:`
	/// written against the last sample would land somewhere else in the render.
	/// The paper is a different question: it *is* placed against the last
	/// sample, by the renderer as well as by this, so it stays draggable.
	@Test func outsideTheSolvedRangeThereIsNoTipToPlace() throws {
		let size = CGSize(width: 640, height: 360)
		let seen = CGPoint(x: 0.3, y: 0.45)
		// Solved over the first two seconds and no further — she left the room.
		let path = AnchorPath(samples: [(0, seen), (2, seen)], covered: [0 ... 2])
		let bubble = drawn()
		let resolved = shown(bubble, path: path)

		let inside = BubblePlacing.origins(bubble, resolved: resolved, size: size, at: 1)
		#expect(inside.paper != nil)
		#expect(inside.tip != nil)

		let after = BubblePlacing.origins(bubble, resolved: resolved, size: size, at: 3)
		#expect(after.tip == nil, "a tip was offered where no tail is drawn")
		#expect(BubblePlacing.tail(forTip: CGPoint(x: 100, y: 100),
		                          origins: after, size: size) == nil)
		#expect(after.paper != nil, "the paper is placed against the last sample and is not")
		#expect(BubblePlacing.offset(forPaper: CGPoint(x: 100, y: 100),
		                             origins: after, size: size) != nil)
		// And the picture agrees with both: no tail there, and a bubble still.
		let canvas = try painted(bubble, offset: Bubble.standoff, size: size,
		                         path: path, at: 3)
		let spot = CGPoint(x: seen.x * size.width, y: seen.y * size.height)
		#expect(canvas.nearest(to: spot) > 0.1 * size.height, "there is still a tail drawn")
		#expect(canvas.covered > 500, "the whole bubble went with the tracking")
	}

	/// **A bubble about nothing has no handle to drag**, and that is the honest
	/// answer rather than a limitation: with no `anchor:` and no `at:` the paper
	/// sits where its style says and the renderer does not read `offset:` at
	/// all, so there is no number a drag could write that would move it.
	@Test func aBubbleAboutNothingHasNoHandleToDrag() throws {
		let size = CGSize(width: 640, height: 360)
		let bubble = said()
		let origins = BubblePlacing.origins(bubble, resolved: shown(bubble), size: size, at: 0)
		#expect(origins.paper == nil)
		#expect(origins.tip == nil)
		#expect(BubblePlacing.offset(forPaper: CGPoint(x: 10, y: 10),
		                             origins: origins, size: size) == nil)
		#expect(BubblePlacing.tail(forTip: CGPoint(x: 10, y: 10),
		                           origins: origins, size: size) == nil)

		// Which is what the drawing does: two very different offsets, one
		// position, because neither is read.
		let style = Project().style(named: "bubble")
		for offset in [CGPoint.zero, CGPoint(x: 0.4, y: -0.3)] {
			let placed = BubblePlacing.placement(bubble, resolved: shown(bubble, offset: offset),
			                                     project: Project(), size: size, at: 0)
			#expect(abs(placed.home.x - style.position.x * size.width) < 0.001)
			#expect(abs(placed.home.y - style.position.y * size.height) < 0.001)
		}
	}

	// MARK: - What gets written

	/// **A drag that lands where it started is the number it started from.**
	///
	/// Which is what makes a no-op drag write nothing: the panel compares what
	/// came out with what went in, and this is the claim that the comparison is
	/// worth making. It holds because the number is rounded to a step — without
	/// that, a value put through the drawing and read back would come out with
	/// its last bit changed and every look at a bubble would be an edit.
	@Test func aDragThatLandsWhereItStartedIsTheNumberItStartedFrom() throws {
		let size = CGSize(width: 1280, height: 720)
		let offset = CGPoint(x: 0.123, y: -0.045)
		let tail = CGPoint(x: -0.08, y: 0.016)
		for path in [nil, walking()] as [AnchorPath?] {
			let bubble = drawn(at: path == nil ? CGPoint(x: 0.42, y: 0.44) : nil, tail: tail)
			let resolved = shown(bubble, path: path, offset: offset)
			for moment in [0.8, 3.2] {
				let placed = BubblePlacing.placement(bubble, resolved: resolved,
				                                     project: Project(), size: size, at: moment)
				#expect(BubblePlacing.offset(forPaper: placed.home, origins: placed.origins,
				                             size: size) == offset,
				        "the paper came back as something else at \(moment)s")
				#expect(BubblePlacing.tail(forTip: try #require(placed.tip),
				                           origins: placed.origins, size: size) == tail,
				        "the tip came back as something else at \(moment)s")
			}
		}
	}

	/// And the number is one somebody could have typed: a whole number of steps,
	/// not seven digits of mouse.
	@Test func theNumberIsOneSomebodyCouldHaveTyped() throws {
		let size = CGSize(width: 1080, height: 1080)
		let bubble = said(at: CGPoint(x: 0.5, y: 0.5))
		let origins = BubblePlacing.origins(bubble, resolved: shown(bubble), size: size, at: 0)
		for x in stride(from: 0.0, through: 1000.0, by: 137.0) {
			let written = try #require(BubblePlacing.offset(
				forPaper: CGPoint(x: x, y: x / 3), origins: origins, size: size))
			for value in [written.x, written.y] {
				let steps = value / BubblePlacing.step
				#expect(abs(steps - steps.rounded()) < 1e-6, "\(value) is not a whole step")
			}
		}
	}

	/// The painter and the panel are one drawing.
	///
	/// ``OverlayPainter/bubbleImage(_:resolved:project:size:at:)`` is what the
	/// frame path paints a bubble with and what the panel's picture draws, and it
	/// is the same call — so this is a short test with a long reason: if these
	/// two ever came apart, somebody would place a bubble against one drawing
	/// and export the other.
	@Test func thePainterAndThePreviewAreTheSameDrawing() throws {
		let size = CGSize(width: 640, height: 360)
		let bubble = drawn(at: CGPoint(x: 0.4, y: 0.4), tail: CGPoint(x: 0, y: -0.1))
		let resolved = shown(bubble, offset: Bubble.standoff)
		let one = try #require(OverlayPainter.bubbleImage(
			bubble, resolved: resolved, project: Project(), size: size, at: 1))
		let two = try #require(BubblePlacing.drawing(
			bubble, resolved: resolved, project: Project(), size: size, at: 1).image)
		#expect(BubbleCanvas(one).bytes == BubbleCanvas(two).bytes)
	}
}
