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

	init() {
		// Fast rather than accurate: the mask is a decision about which side of
		// a person a piece of paper is on, and it is behind moving confetti.
		// Accurate costs several times as much for an edge nobody can see.
		request.qualityLevel = .fast
		request.outputPixelFormat = kCVPixelFormatType_OneComponent8
	}

	/// The mask for a frame, in the frame's own coordinates, or `nil` if Vision
	/// found nobody — in which case there is nothing to go behind.
	func mask(for image: CIImage, at time: Double) -> CIImage? {
		lock.lock()
		defer { lock.unlock() }
		if time == lastTime { return lastMask }

		let extent = image.extent
		guard extent.width > 1, extent.height > 1 else { return nil }

		// Segmented at a fraction of the size: a mask is a shape, and a shape
		// survives being worked out small far better than a render survives
		// being slow.
		let scale = min(1, 640 / extent.width)
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
		let back = CGAffineTransform(
			scaleX: extent.width / maskExtent.width,
			y: extent.height / maskExtent.height)
		// Softened by a pixel or two: an edge cut exactly along the mask reads
		// as a cut-out, and hair is not a hard edge in the first place.
		let scaled = mask.transformed(by: back)
			.applyingFilter("CIGaussianBlur", parameters: ["inputRadius": 1.5])
			.cropped(to: extent)

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
