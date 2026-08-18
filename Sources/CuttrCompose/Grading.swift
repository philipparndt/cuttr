import CoreImage
import CuttrKit
import Foundation

/// Turning a ``Look`` into pixels.
///
/// Core Image filters rather than a shader, for the same reason the overlays are
/// Core Animation: they run identically in the preview and the export, and this
/// program's one rule is that those two cannot be allowed to disagree.
///
/// The order is not arbitrary. The match `gain` goes first, in linear-ish terms,
/// because it is a correction *of the recording* — it is putting two cameras on
/// the same footing, and everything after it is a decision made about the
/// footage once it is comparable. Exposure then white balance then the trims,
/// which is the order a person would work in.
enum Grading {

	static func apply(_ look: Look, to image: CIImage) -> CIImage {
		var image = image
		if let gain = look.gain, gain.count == 3 {
			image = image.applyingFilter("CIColorMatrix", parameters: [
				"inputRVector": CIVector(x: gain[0], y: 0, z: 0, w: 0),
				"inputGVector": CIVector(x: 0, y: gain[1], z: 0, w: 0),
				"inputBVector": CIVector(x: 0, y: 0, z: gain[2], w: 0),
			])
		}
		if look.exposure != 0 {
			image = image.applyingFilter("CIExposureAdjust", parameters: ["inputEV": look.exposure])
		}
		if look.temperature != 0 || look.tint != 0 {
			// Neutral in, shifted out: the filter's job is "this was shot at
			// 6500 K, make it look like it was shot at 6500 + n". Warmer is a
			// higher target, which is why positive reads as warmer here and in
			// the file.
			image = image.applyingFilter("CITemperatureAndTint", parameters: [
				"inputNeutral": CIVector(x: 6500, y: 0),
				"inputTargetNeutral": CIVector(x: 6500 + look.temperature, y: look.tint),
			])
		}
		if look.saturation != 1 || look.contrast != 1 {
			image = image.applyingFilter("CIColorControls", parameters: [
				"inputSaturation": look.saturation,
				"inputContrast": look.contrast,
				"inputBrightness": 0,
			])
		}
		return image
	}

	/// Aspect-fits a frame into the output, centred.
	///
	/// The same rule the instruction-based path used, expressed as a Core Image
	/// transform so there is one place that decides where a frame lands rather
	/// than two that have to agree.
	static func fit(_ extent: CGRect, into output: CGSize) -> CGAffineTransform {
		guard extent.width > 0, extent.height > 0 else { return .identity }
		let scale = min(output.width / extent.width, output.height / extent.height)
		return CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
			.concatenating(CGAffineTransform(scaleX: scale, y: scale))
			.concatenating(CGAffineTransform(
				translationX: (output.width - extent.width * scale) / 2,
				y: (output.height - extent.height * scale) / 2))
	}
}
