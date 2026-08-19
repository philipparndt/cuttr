import CoreImage
import CuttrKit
import Foundation

/// Taking a frame to film, and back again.
///
/// Everything here is scaled by one number — how far into the mode the
/// programme is at this moment — so that the same code draws the middle of a
/// transition and the middle of the sequence. At nought it must hand the frame
/// back untouched, and it is written so that it does: no grade, no grain, no
/// bars, no trip through a filter that would cost colour for nothing.
enum Filming {

	/// The frame, `intensity` of the way into film mode.
	///
	/// `time` moves the grain. Grain that does not move is dirt on the lens,
	/// and the eye finds a fixed pattern in about two seconds.
	static func applied(
		_ film: Film, to picture: CIImage, intensity: Double, size: CGSize, time: Double
	) -> CIImage {
		let amount = min(1, max(0, intensity))
		guard amount > 0.001 else { return picture }
		var image = picture

		// --- The colour -------------------------------------------------------
		let strength = max(0, min(1, film.strength)) * amount
		if strength > 0.001, film.tint != .none {
			let graded = film.tint.look.applied(to: image)
			image = image.applyingFilter("CIDissolveTransition", parameters: [
				kCIInputTargetImageKey: graded,
				kCIInputTimeKey: strength,
			])
		}

		// --- The grain --------------------------------------------------------
		//
		// Core Image's noise, desaturated and moved every frame, laid over the
		// picture in soft light so it darkens as much as it lightens. Soft light
		// rather than plain addition because grain that only adds turns the
		// blacks grey, which is the one thing film grain does not do.
		let grain = max(0, min(1, film.grain)) * amount
		if grain > 0.001 {
			// A whole number of pixels, so the pattern moves rather than
			// resampling itself into mush.
			let step = (time * 137).rounded()
			let noise = CIFilter(name: "CIRandomGenerator")?.outputImage?
				.transformed(by: CGAffineTransform(translationX: step.truncatingRemainder(dividingBy: 512),
				                                   y: (step * 7).truncatingRemainder(dividingBy: 512)))
				.applyingFilter("CIColorControls", parameters: [
					kCIInputSaturationKey: 0,
					// Centred on grey and gentle: the strength is in the blend.
					kCIInputContrastKey: 0.35 + 0.65 * grain,
					kCIInputBrightnessKey: 0,
				])
				.cropped(to: CGRect(origin: .zero, size: size))
			if let noise {
				let over = noise.applyingFilter("CISoftLightBlendMode", parameters: [
					kCIInputBackgroundImageKey: image,
				])
				image = image.applyingFilter("CIDissolveTransition", parameters: [
					kCIInputTargetImageKey: over,
					kCIInputTimeKey: min(1, grain),
				])
			}
		}

		// --- The corners ------------------------------------------------------
		let vignette = max(0, min(1, film.vignette)) * amount
		if vignette > 0.001 {
			image = image.applyingFilter("CIVignetteEffect", parameters: [
				kCIInputCenterKey: CIVector(x: size.width / 2, y: size.height / 2),
				kCIInputRadiusKey: max(size.width, size.height) * 0.62,
				kCIInputIntensityKey: vignette * 1.4,
			])
		}

		// --- The bars ---------------------------------------------------------
		//
		// Last, and over everything: they are the edge of the frame, and grain
		// on a black bar is grain on the projector.
		let bars = film.bars(in: size)
		if bars.vertical > 0.0001 || bars.horizontal > 0.0001 {
			let black = CIImage(color: .black)
			let vertical = CGFloat(bars.vertical * amount) * size.height
			let horizontal = CGFloat(bars.horizontal * amount) * size.width
			if vertical > 0.5 {
				image = black.cropped(to: CGRect(x: 0, y: 0, width: size.width, height: vertical))
					.composited(over: image)
				image = black.cropped(to: CGRect(x: 0, y: size.height - vertical,
				                                 width: size.width, height: vertical))
					.composited(over: image)
			}
			if horizontal > 0.5 {
				image = black.cropped(to: CGRect(x: 0, y: 0, width: horizontal, height: size.height))
					.composited(over: image)
				image = black.cropped(to: CGRect(x: size.width - horizontal, y: 0,
				                                 width: horizontal, height: size.height))
					.composited(over: image)
			}
		}

		return image.cropped(to: CGRect(origin: .zero, size: size))
	}
}
