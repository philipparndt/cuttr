import CoreImage
import Foundation

/// Pulling red and blue off green, and putting the frame back together.
///
/// Three plates and two composites, which is the cheap way of the two that
/// were tried. The other was `CIDisplacementDistortion` with a map built per
/// frame: a shade quicker on paper, and it displaces along the map's *gradient*
/// rather than by the value in it, so saying "move red two pixels out from the
/// centre here" means building a map whose slope says that — arithmetic nobody
/// reading this file afterwards would be able to check. Measured at 1080: the
/// three plates cost about a millisecond and a half a frame over the frame
/// alone, which is not the reason to prefer either.
///
/// Unmanaged, like everything else in the frame pass: no colour space named,
/// none asked for, for the reason the renderer records at length.
enum Aberrating {

	/// The frame with the channels `intensity` of the way apart.
	///
	/// The fade scales the separation rather than mixing the picture back in.
	/// Dissolving between a clean frame and an aberrated one at half way is two
	/// pictures at half strength — a ghost — where what is wanted is the
	/// fringes arriving, which is a smaller separation.
	static func applied(
		_ aberration: Aberration, to picture: CIImage, intensity: Double, size: CGSize
	) -> CIImage {
		let amount = min(1, max(0, intensity)) * max(0, aberration.amount)
		guard amount > 0.0005, size.width > 1, size.height > 1 else { return picture }

		let red: CIImage, blue: CIImage
		switch aberration.kind {
		case .radial:
			// Scaling one channel about the middle *is* radial displacement:
			// how far a point moves is how far it already was from the centre,
			// which is the thing that makes it read as a lens. One per cent of
			// scale at amount one, so red and blue end up about one per cent of
			// the half-diagonal apart at the corners and nothing apart in the
			// middle.
			let scale = amount * 0.01
			red = scaled(picture, by: 1 + scale, in: size)
			blue = scaled(picture, by: 1 - scale, in: size)
		case .linear:
			// Half the separation each way, so `amount` means the same thing
			// here as it does for the radial kind: the distance between the red
			// copy and the blue one.
			let radians = aberration.angle * .pi / 180
			let travel = amount * 0.005 * Double(size.height)
			let step = CGPoint(x: cos(radians) * travel, y: sin(radians) * travel)
			red = shifted(picture, by: step, in: size)
			blue = shifted(picture, by: CGPoint(x: -step.x, y: -step.y), in: size)
		}
		return combined(red: red, green: picture, blue: blue, size: size)
	}

	/// One picture's red, another's green, a third's blue.
	///
	/// Shared with the tape, whose chroma bleed is the same trick with both
	/// copies pulled the same way.
	static func combined(red: CIImage, green: CIImage, blue: CIImage, size: CGSize) -> CIImage {
		// Put back together with a *maximum* rather than an addition. The three
		// plates have two of their three channels at nought, so the maximum is
		// the sum — and unlike addition it leaves the alpha at one instead of
		// summing three opaque frames to three, which the encoder then has an
		// opinion about.
		channel(red, 0)
			.applyingFilter("CIMaximumCompositing", parameters: [
				kCIInputBackgroundImageKey: channel(green, 1),
			])
			.applyingFilter("CIMaximumCompositing", parameters: [
				kCIInputBackgroundImageKey: channel(blue, 2),
			])
			.cropped(to: CGRect(origin: .zero, size: size))
	}

	/// One channel of a picture, with the other two zeroed and the alpha left
	/// alone. 0 is red, 1 green, 2 blue.
	private static func channel(_ image: CIImage, _ keep: Int) -> CIImage {
		let nothing = CIVector(x: 0, y: 0, z: 0, w: 0)
		return image.applyingFilter("CIColorMatrix", parameters: [
			"inputRVector": keep == 0 ? CIVector(x: 1, y: 0, z: 0, w: 0) : nothing,
			"inputGVector": keep == 1 ? CIVector(x: 0, y: 1, z: 0, w: 0) : nothing,
			"inputBVector": keep == 2 ? CIVector(x: 0, y: 0, z: 1, w: 0) : nothing,
			"inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
		])
	}

	/// Bigger or smaller about the middle of the frame.
	///
	/// Clamped before the transform and cropped after it: a scale down leaves a
	/// border of nothing at the edge, and nothing in Core Image is transparent
	/// black — so without the clamp a frame with any aberration on it has a dark
	/// rim, which is exactly the artefact this is supposed to be too subtle to
	/// cause.
	static func scaled(_ image: CIImage, by scale: Double, in size: CGSize) -> CIImage {
		let centre = CGPoint(x: size.width / 2, y: size.height / 2)
		let transform = CGAffineTransform(translationX: centre.x, y: centre.y)
			.scaledBy(x: scale, y: scale)
			.translatedBy(x: -centre.x, y: -centre.y)
		return image.clampedToExtent().transformed(by: transform)
			.cropped(to: CGRect(origin: .zero, size: size))
	}

	static func shifted(_ image: CIImage, by offset: CGPoint, in size: CGSize) -> CIImage {
		image.clampedToExtent()
			.transformed(by: CGAffineTransform(translationX: offset.x, y: offset.y))
			.cropped(to: CGRect(origin: .zero, size: size))
	}
}
