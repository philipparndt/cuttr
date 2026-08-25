import CoreGraphics
import CuttrKit
import Foundation
import Testing
@testable import CuttrCompose

/// Where the picture is, moment by moment.
///
/// Arithmetic rather than pixels: the rectangle is decided in one place and
/// everything that draws goes through it, so what has to be right is the
/// rectangle. Rendering it as well would test Core Image.
@Suite struct PresentationFrameTests {

	private let aside = Presentation.Rectangle(x: 0.04, y: 0.22, width: 0.4, height: 0.4)

	private func shown(hold: Double = 6, ramp: Double = 0.6) -> Presentation {
		Presentation(at: 3, into: aside, hold: hold, ramp: ramp, scene: "bullets")
	}

	@Test func outsideTheGestureThePictureIsTheWholeFrame() {
		let one = shown()
		#expect(one.frame(at: -1) == .whole)
		#expect(one.frame(at: 0) == .whole)
		#expect(one.frame(at: one.span) == .whole)
		#expect(one.frame(at: one.span + 1) == .whole)
	}

	@Test func throughTheHoldItIsWhereItWasPut() {
		let one = shown()
		#expect(one.frame(at: 0.6) == aside)
		#expect(one.frame(at: 3) == aside)
		#expect(one.frame(at: 6.6) == aside)
	}

	/// Half way through the ramp it is half way there — by area travelled, not
	/// by time: the easing is what makes the stop look deliberate, and at the
	/// midpoint a smoothstep is exactly half.
	@Test func halfWayThroughTheRampItIsHalfWayThere() {
		let one = shown()
		let middle = one.frame(at: 0.3)
		#expect(abs(middle.x - (0 + 0.04) / 2) < 1e-9)
		#expect(abs(middle.width - (1 + 0.4) / 2) < 1e-9)
	}

	/// And it is eased rather than linear, which is the whole reason the ramp
	/// exists. A quarter of the way in, a smoothstep has moved less than a
	/// quarter of the distance.
	@Test func theRampIsEasedAndNotLinear() {
		let one = shown()
		let quarter = one.frame(at: 0.15)
		let linear = Presentation.Rectangle.between(.whole, aside, 0.25)
		#expect(quarter.width > linear.width, "the travel is linear")
		#expect(Presentation.eased(0.25) < 0.25)
		#expect(Presentation.eased(0.75) > 0.75)
		#expect(Presentation.eased(0.5) == 0.5)
	}

	/// The way back is the way out, reversed.
	@Test func itComesBackTheWayItWent() {
		let one = shown()
		let out = one.frame(at: 0.3)
		let back = one.frame(at: one.span - 0.3)
		#expect(abs(out.x - back.x) < 1e-9)
		#expect(abs(out.width - back.width) < 1e-9)
	}

	/// No ramp at all is a cut to the rectangle and a cut back. Legal, and the
	/// arithmetic must not divide by nought to get there.
	@Test func noRampIsACut() {
		let one = shown(ramp: 0)
		#expect(one.span == 6)
		#expect(one.frame(at: 0) == aside)
		#expect(one.frame(at: 3) == aside)
		#expect(one.frame(at: 6) == aside)
		#expect(one.frame(at: 6.1) == .whole)
	}

	/// A square box on a 16:9 picture letterboxes rather than squashing it: the
	/// fitted box is the same height and narrower, centred where the box was.
	@Test func aSquareBoxOnAWideFrameFitsRatherThanFills() {
		let square = Presentation.Rectangle(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
		// The picture fills the frame, so what it has to hold inside the box is
		// the box's own shape — one, in fractions of the frame.
		let fitted = square.fitting(aspect: 1)
		#expect(fitted == square, "a box already of that shape was changed")

		let tall = Presentation.Rectangle(x: 0.1, y: 0, width: 0.3, height: 1)
		let inside = tall.fitting(aspect: 1)
		#expect(inside.width == 0.3)
		#expect(inside.height == 0.3)
		// Centred in what it was given, so a tall box letterboxes above and
		// below rather than pinning the picture to one edge.
		#expect(abs(inside.y - 0.35) < 1e-9)
	}

	/// The compositor's question, asked of a clip rather than of a treatment:
	/// the gesture is placed on the programme's clock, ramp and all, and the
	/// hold that follows it does not move it.
	@Test func theClipPlacesTheGestureOnTheProgrammesClock() {
		let clip = ResolvedClip(
			reference: ClipReference(take: "take-01", slug: "demo"),
			takeName: "take-01", clip: Clip(slug: "demo", start: 0, end: 20),
			videoURL: nil, audioURL: nil, audioOffset: 0, start: 10,
			presentations: [shown()])
		// The picture starts moving a ramp *before* the hold: it has to be
		// aside by the time the recording stops.
		#expect(clip.picture(atProgramme: 12.4) == .whole)   // the first frame of the ramp
		#expect(clip.picture(atProgramme: 12.5) != .whole)
		#expect(clip.picture(atProgramme: 13) == aside)
		#expect(clip.picture(atProgramme: 19) == aside)
		#expect(clip.picture(atProgramme: 19.6) == .whole)
		// And afterwards, for the rest of a clip that is now six seconds
		// longer, it is the whole frame again.
		#expect(clip.picture(atProgramme: 25) == .whole)
		#expect(clip.end == 36)
	}
}
