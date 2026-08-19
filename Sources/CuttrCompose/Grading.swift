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

	/// The look's own arithmetic, which lives with the look.
	///
	/// It was written out again here once, and two copies of "what warmer
	/// means" is one copy too many: the renderer's picture and the cutting
	/// window's would drift apart at the first change and nobody would know
	/// which was right.
	static func apply(_ look: Look, to image: CIImage) -> CIImage {
		look.applied(to: image)
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
