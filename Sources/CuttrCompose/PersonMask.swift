import CoreImage
import Foundation
import Vision

/// The shape of whoever is in the frame, worked out on this machine.
///
/// Vision segments people locally and quickly, which is the only reason this is
/// affordable at all: a mask per frame, at a fraction of the frame's size,
/// nothing sent anywhere. What it buys is depth — the far half of a shower of
/// confetti passing *behind* somebody instead of over them, which is the
/// difference between confetti in the room and confetti stuck to the lens.
///
/// It knows people and nothing else. A table does not stop a piece of paper
/// here, and saying so plainly is better than a model that guesses at furniture
/// and is wrong in a way nobody can predict.
final class PersonMask: @unchecked Sendable {

	/// How finely the shape is worked out, which is a decision about time.
	///
	/// Measured on a 1920×1080 frame of real footage, warm, per frame:
	///
	///     fast       256 × 192 mask     8 ms
	///     balanced   512 × 384 mask    20 ms
	///     accurate  2016 × 1512 mask   52 ms
	///
	/// The quality level chooses the model's *own* output size — the size of
	/// the image handed in barely matters, because the model resamples what it
	/// is given. That is the whole story of the staircase somebody noticed: a
	/// 256-pixel mask stretched seven and a half times to reach a 1920 frame,
	/// and no amount of blurring hides a step that is eight pixels wide.
	public enum Quality: String, Sendable, CaseIterable {
		case fast, balanced, accurate

		var level: VNGeneratePersonSegmentationRequest.QualityLevel {
			switch self {
			case .fast: return .fast
			case .balanced: return .balanced
			case .accurate: return .accurate
			}
		}
	}

	private let request = VNGeneratePersonSegmentationRequest()
	/// For turning the mask into pixels of our own, straight away.
	private let context = CIContext(options: [.workingColorSpace: NSNull()])
	/// One request object, one frame at a time. Vision's handler is not two
	/// things and Core Image asks from several threads.
	private let lock = NSLock()
	/// The frame this mask was made from, so several effects over one frame ask
	/// for the segmentation once between them.
	private var lastTime = Double.nan
	private var lastMask: CIImage?

	private let quality: Quality

	init(_ quality: Quality = .accurate) {
		// Accurate by default, which it was not.
		//
		// The old reasoning was that the mask decides which side of a person a
		// piece of paper is on, behind moving confetti, and that a finer edge
		// was an edge nobody could see. Both halves stopped being true: a
		// caption goes behind somebody now, and it sits still while she moves,
		// so the edge is exactly what the eye is on. Fifty milliseconds a frame
		// is the price, and only on the frames that need a mask at all.
		self.quality = quality
		request.qualityLevel = quality.level
		request.outputPixelFormat = kCVPixelFormatType_OneComponent8
	}

	/// A mask at the model's size, brought up to the frame's.
	///
	/// Lanczos rather than the default, because this is an *enlargement* and the
	/// default one steps. It costs a filter and it is the difference between an
	/// edge and a staircase — which is what a 256-pixel mask stretched seven and
	/// a half times looked like, and what somebody noticed.
	///
	/// `inputScale` is the *vertical* factor and `inputAspectRatio` is what is
	/// applied on top of it horizontally, which is not what the names suggest:
	/// scaling by the width put a 1439-pixel square in a 1920 by 1080 frame, and
	/// everything to the right of it, being outside the image, came out as
	/// person. Hence the test that the result covers the frame.
	///
	/// Then softened in proportion to how far it was stretched. An edge cut
	/// exactly along the mask reads as a cut-out and hair is not a hard edge in
	/// the first place; a mask that arrives at frame size wants a pixel or two,
	/// and one that arrives at a seventh of it wants seven times that or the
	/// steps show through the blur.
	static func enlarge(_ mask: CIImage, to extent: CGRect) -> CIImage {
		let source = mask.extent
		guard source.width > 0, source.height > 0 else { return mask }
		let growth = extent.height / source.height
		let enlarged = mask.applyingFilter("CILanczosScaleTransform", parameters: [
			kCIInputScaleKey: growth,
			kCIInputAspectRatioKey: (extent.width / source.width) / growth,
		])
		let softness = max(1.5, 1.5 * Double(extent.width / source.width))
		return enlarged
			.applyingFilter("CIGaussianBlur", parameters: ["inputRadius": softness])
			.cropped(to: extent)
	}

	/// The mask for a frame, in the frame's own coordinates, or `nil` if Vision
	/// found nobody — in which case there is nothing to go behind.
	func mask(for image: CIImage, at time: Double) -> CIImage? {
		lock.lock()
		defer { lock.unlock() }
		if time == lastTime { return lastMask }

		let extent = image.extent
		guard extent.width > 1, extent.height > 1 else { return nil }

		// Handed in at a fraction of the size, because the model resamples what
		// it is given and a 1920-wide frame buys nothing over a 960-wide one:
		// measured, the mask came back the same size and the same shape either
		// way. What it saves is the copy, not the segmentation.
		let scale = min(1, 960 / extent.width)
		let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

		let handler = VNImageRequestHandler(ciImage: small, options: [:])
		do {
			try handler.perform([request])
		} catch {
			lastTime = time
			lastMask = nil
			return nil
		}
		guard let result = request.results?.first else {
			lastTime = time
			lastMask = nil
			return nil
		}

		let mask = CIImage(cvPixelBuffer: result.pixelBuffer)
		let maskExtent = mask.extent
		guard maskExtent.width > 0, maskExtent.height > 0 else { return nil }
		let scaled = Self.enlarge(mask, to: extent)

		// Drawn now, into pixels of our own.
		//
		// A `CIImage` is a promise, and this one is a promise about a buffer
		// Vision hands back and then reuses for the next frame — so by the time
		// the composite was evaluated the mask was whatever the *next* frame had
		// put there, or nothing at all. Everything downstream looked right and
		// nothing was occluded.
		guard let drawn = context.createCGImage(scaled, from: extent) else { return nil }
		let fitted = CIImage(cgImage: drawn)

		lastTime = time
		lastMask = fitted
		return fitted
	}
}
