import CoreImage
import Foundation
import Testing
@testable import CuttrCompose

/// What is actually on screen while two shots overlap.
///
/// Measured, not admired: two flat colours go in and the pixels that come out
/// are read back. Every one of these was wrong at least once — a wipe whose
/// edge came in from the wrong side, a push that moved both shots the same way
/// but the wrong way — and none of it is visible in a type that compiles.
@Suite struct CutTransitionTests {

	private let size = CGSize(width: 64, height: 32)
	/// No colour management, for the reason the renderer records at length.
	private let context = CIContext(options: [.workingColorSpace: NSNull()])

	private var going: CIImage {
		CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(origin: .zero, size: size))
	}

	private var coming: CIImage {
		CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(origin: .zero, size: size))
	}

	/// One pixel, as red, green, blue.
	private func pixel(_ image: CIImage, x: Int, y: Int) -> (Double, Double, Double) {
		var bytes = [UInt8](repeating: 0, count: 4)
		context.render(image, toBitmap: &bytes, rowBytes: 4,
		               bounds: CGRect(x: x, y: y, width: 1, height: 1),
		               format: .RGBA8, colorSpace: nil)
		return (Double(bytes[0]) / 255, Double(bytes[1]) / 255, Double(bytes[2]) / 255)
	}

	private func made(_ how: Transition, at t: Double) -> CIImage {
		Transitions.blend(how, going: going, coming: coming, progress: t, size: size)
	}

	/// Whatever the kind, the first frame of the overlap is the shot going out
	/// and the last is the one coming in. Anything else is a jump at one end.
	@Test func everyKindStartsWithOneShotAndEndsWithTheOther() {
		for kind in Transition.Kind.allCases where kind != .cut {
			let how = Transition(kind, seconds: 1)
			let first = pixel(made(how, at: 0), x: 32, y: 16)
			let last = pixel(made(how, at: 1), x: 32, y: 16)
			#expect(first.0 > 0.9 && first.2 < 0.1, "\(kind) does not begin on the shot going out")
			#expect(last.2 > 0.9 && last.0 < 0.1, "\(kind) does not end on the shot coming in")
		}
	}

	@Test func aDissolveIsHalfWayHalfWayThrough() {
		let middle = pixel(made(Transition(.dissolve, seconds: 1), at: 0.5), x: 32, y: 16)
		#expect(abs(middle.0 - 0.5) < 0.06)
		#expect(abs(middle.2 - 0.5) < 0.06)
	}

	/// A dip is *through* something: at the middle neither shot is on screen.
	@Test func aDipPassesThroughItsColour() {
		let black = pixel(made(Transition(.dipToBlack, seconds: 1), at: 0.5), x: 32, y: 16)
		#expect(black.0 < 0.05 && black.1 < 0.05 && black.2 < 0.05)
		let white = pixel(made(Transition(.dipToWhite, seconds: 1), at: 0.5), x: 32, y: 16)
		#expect(white.0 > 0.95 && white.1 > 0.95 && white.2 > 0.95)
		// And a quarter of the way in it is still mostly the shot going out.
		let quarter = pixel(made(Transition(.dipToBlack, seconds: 1), at: 0.25), x: 32, y: 16)
		#expect(quarter.0 > 0.4 && quarter.2 < 0.05)
	}

	/// The edge names the side the new shot comes in from, and it had better be
	/// that side.
	@Test func aWipeComesInFromTheSideItSays() {
		func halfWay(_ edge: Transition.Edge) -> (left: Double, right: Double,
		                                          bottom: Double, top: Double) {
			let image = made(Transition(.wipe, seconds: 1, edge: edge), at: 0.5)
			return (pixel(image, x: 4, y: 16).2, pixel(image, x: 59, y: 16).2,
			        pixel(image, x: 32, y: 3).2, pixel(image, x: 32, y: 28).2)
		}
		let fromLeft = halfWay(.left)
		#expect(fromLeft.left > 0.9, "a wipe from the left is not blue on the left")
		#expect(fromLeft.right < 0.1)
		let fromRight = halfWay(.right)
		#expect(fromRight.right > 0.9)
		#expect(fromRight.left < 0.1)
		// Core Image's origin is bottom-left: "down" means it arrives from the
		// bottom of the frame.
		let fromBelow = halfWay(.down)
		#expect(fromBelow.bottom > 0.9)
		#expect(fromBelow.top < 0.1)
		let fromAbove = halfWay(.up)
		#expect(fromAbove.top > 0.9)
		#expect(fromAbove.bottom < 0.1)
	}

	/// A push moves both shots the same way; a slide moves only the new one.
	/// Either way the new shot occupies the side it came from.
	@Test func pushAndSlideArriveFromTheirSide() {
		for kind in [Transition.Kind.push, .slide] {
			let image = made(Transition(kind, seconds: 1, edge: .left), at: 0.5)
			#expect(pixel(image, x: 4, y: 16).2 > 0.9, "\(kind) from the left is not on the left")
			#expect(pixel(image, x: 59, y: 16).0 > 0.9, "\(kind) has lost the shot going out")
		}
	}

	/// An iris opens from the middle: the centre changes over before the corner
	/// does.
	@Test func anIrisOpensFromTheMiddle() {
		let image = made(Transition(.iris, seconds: 1), at: 0.4)
		#expect(pixel(image, x: 32, y: 16).2 > 0.9)
		#expect(pixel(image, x: 1, y: 1).0 > 0.9)
	}

	/// A flash blows the frame out at the middle and is nothing but a dissolve
	/// at the ends.
	@Test func aFlashPeaksInTheMiddle() {
		let middle = pixel(made(Transition(.flash, seconds: 0.25), at: 0.5), x: 32, y: 16)
		#expect(middle.0 > 0.85 && middle.1 > 0.85 && middle.2 > 0.85)
	}

	/// A cut is a kind here, and a kind with no length — so changing a dissolve
	/// to a cut in the panel cannot leave an overlap behind.
	@Test func aCutHasNoLengthHoweverItIsWritten() {
		#expect(Transition(.cut, seconds: 2).duration == 0)
		#expect(Transition(.wipe, seconds: 0.6).duration == 0.6)
		// A bare number is a dissolve, in the file and in the type.
		let fromNumber: Transition = 0.4
		#expect(fromNumber == .dissolve(over: 0.4))
		let none: Transition = 0
		#expect(none == .cut)
	}
}
