import CoreImage
import Foundation

/// What is on screen while two shots overlap.
///
/// One function per kind, and nothing else in the program has to know which
/// kind it was. That is the point of the arrangement: the resolver works out
/// the overlap, the renderer lays the two shots on two lanes, and the only
/// thing that varies is what happens to the pixels in between.
///
/// Everything here is unmanaged — no colour space named, none asked for. The
/// values that came out of the footage are the values that go back, for the
/// reason the renderer records at length: a trip through Core Image's linear
/// space and back lifts the picture eight levels, and a transition would be the
/// only place in the programme where that happened.
enum Transitions {

	/// `progress` runs 0 at the first frame of the overlap to 1 at the last.
	static func blend(
		_ how: Transition, going: CIImage, coming: CIImage,
		progress: Double, size: CGSize
	) -> CIImage {
		let t = min(1, max(0, progress))
		switch how.kind {
		case .cut:
			return t < 0.5 ? going : coming

		case .dissolve:
			return dissolve(going, coming, t)

		case .dipToBlack:
			return dip(going, coming, t, through: flat(.black, size))

		case .dipToWhite:
			return dip(going, coming, t, through: flat(.white, size))

		case .wipe:
			// A hard edge with a couple of per cent of softness on it, so it
			// does not crawl up the frame's own pixel grid.
			return blend(going, coming, mask: edgeMask(how.edge, t, size: size, soft: 0.02))

		case .push:
			// Both move together, the frame's width apart, which is what makes
			// it read as one move rather than two.
			let travel = shift(how.edge, size)
			let out = going.transformed(by: CGAffineTransform(
				translationX: -travel.x * CGFloat(t), y: -travel.y * CGFloat(t)))
			let into = coming.transformed(by: CGAffineTransform(
				translationX: travel.x * CGFloat(1 - t), y: travel.y * CGFloat(1 - t)))
			return into.composited(over: out).cropped(to: frame(size))

		case .slide:
			let travel = shift(how.edge, size)
			let into = coming.transformed(by: CGAffineTransform(
				translationX: travel.x * CGFloat(1 - t), y: travel.y * CGFloat(1 - t)))
			return into.composited(over: going).cropped(to: frame(size))

		case .blur:
			// Softest in the middle, sharp at both ends, so it arrives and
			// leaves as itself.
			let radius = sin(Double.pi * t) * Double(size.height) * 0.03
			return dissolve(soften(going, radius, size), soften(coming, radius, size), t)

		case .flash:
			let white = flat(.white, size)
			let mixed = dissolve(going, coming, t)
			return dissolve(mixed, white, sin(Double.pi * t) * 0.9)

		case .iris:
			return blend(going, coming, mask: circleMask(t, size: size))
		}
	}

	// MARK: - The pieces

	private static func frame(_ size: CGSize) -> CGRect {
		CGRect(origin: .zero, size: size)
	}

	private static func dissolve(_ going: CIImage, _ coming: CIImage, _ t: Double) -> CIImage {
		going.applyingFilter("CIDissolveTransition", parameters: [
			kCIInputTargetImageKey: coming,
			kCIInputTimeKey: t,
		])
	}

	/// Out through something and back: the first half belongs to the shot going
	/// out, the second to the one coming in, and neither is on screen at the
	/// middle of it.
	private static func dip(
		_ going: CIImage, _ coming: CIImage, _ t: Double, through veil: CIImage
	) -> CIImage {
		t < 0.5
			? dissolve(going, veil, t * 2)
			: dissolve(veil, coming, (t - 0.5) * 2)
	}

	private static func flat(_ colour: CIColor, _ size: CGSize) -> CIImage {
		CIImage(color: colour).cropped(to: frame(size))
	}

	/// Blurred and cropped back: a blur reads the pixels outside the frame as
	/// transparent, so without the clamp the edges go dark exactly when the
	/// blur is deepest.
	private static func soften(_ image: CIImage, _ radius: Double, _ size: CGSize) -> CIImage {
		guard radius > 0.5 else { return image }
		return image.clampedToExtent()
			.applyingFilter("CIGaussianBlur", parameters: ["inputRadius": radius])
			.cropped(to: frame(size))
	}

	private static func blend(_ going: CIImage, _ coming: CIImage, mask: CIImage) -> CIImage {
		coming.applyingFilter("CIBlendWithMask", parameters: [
			kCIInputBackgroundImageKey: going,
			kCIInputMaskImageKey: mask,
		])
	}

	/// Where the incoming shot starts, which is the side it comes in from.
	///
	/// The edge names that side — `left` means the new shot arrives from the
	/// left, so it begins a frame's width to the left of where it will end up,
	/// and the old one is pushed the same way.
	private static func shift(_ edge: Transition.Edge, _ size: CGSize) -> CGPoint {
		switch edge {
		case .left: return CGPoint(x: -size.width, y: 0)
		case .right: return CGPoint(x: size.width, y: 0)
		case .down: return CGPoint(x: 0, y: -size.height)
		case .up: return CGPoint(x: 0, y: size.height)
		}
	}

	/// White where the incoming shot shows, black where the outgoing one does,
	/// with the boundary travelling across the frame.
	private static func edgeMask(
		_ edge: Transition.Edge, _ t: Double, size: CGSize, soft: Double
	) -> CIImage {
		let along = edge == .left || edge == .right ? size.width : size.height
		let softness = max(1, Double(along) * soft)
		// The line, and which way the white side lies.
		let at = Double(along) * t
		let from: CGPoint, to: CGPoint
		switch edge {
		case .left:
			from = CGPoint(x: at, y: 0); to = CGPoint(x: at - softness, y: 0)
		case .right:
			from = CGPoint(x: Double(size.width) - at, y: 0)
			to = CGPoint(x: Double(size.width) - at + softness, y: 0)
		case .down:
			from = CGPoint(x: 0, y: at); to = CGPoint(x: 0, y: at - softness)
		case .up:
			from = CGPoint(x: 0, y: Double(size.height) - at)
			to = CGPoint(x: 0, y: Double(size.height) - at + softness)
		}
		// Black at the boundary and white a hair beyond it, on the side the new
		// shot is coming from — and the gradient holds its end colours past
		// both points, which is what makes two points describe a whole frame.
		let gradient = CIFilter(name: "CILinearGradient", parameters: [
			"inputPoint0": CIVector(cgPoint: from),
			"inputPoint1": CIVector(cgPoint: to),
			"inputColor0": CIColor.black,
			"inputColor1": CIColor.white,
		])?.outputImage
		return (gradient ?? flat(.black, size)).cropped(to: frame(size))
	}

	/// A circle opening from the middle, big enough at the end to have taken in
	/// the corners.
	private static func circleMask(_ t: Double, size: CGSize) -> CIImage {
		let centre = CGPoint(x: size.width / 2, y: size.height / 2)
		let corner = sqrt(Double(size.width * size.width + size.height * size.height)) / 2
		let radius = corner * t
		let gradient = CIFilter(name: "CIRadialGradient", parameters: [
			"inputCenter": CIVector(cgPoint: centre),
			"inputRadius0": max(0, radius - max(1, corner * 0.01)),
			"inputRadius1": radius,
			"inputColor0": CIColor.white,
			"inputColor1": CIColor.black,
		])?.outputImage
		return (gradient ?? flat(.black, size)).cropped(to: frame(size))
	}
}
