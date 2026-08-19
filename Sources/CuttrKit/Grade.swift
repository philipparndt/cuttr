@preconcurrency import AVFoundation
import CoreGraphics
import CoreImage
import Foundation

/// What a recording turned out to be, once something has looked at it.
///
/// Facts about the footage, so they live in the take beside the audio offset and
/// the anchors — measured once and reused by every programme that draws on it.
/// A project says what it is *aiming* at; this says where the material starts
/// from.
public struct Measured: Sendable, Equatable {
	/// Integrated loudness, LUFS. `nil` for silence, which has none.
	public var loudness: Double?
	/// Sample peak, dBFS.
	public var peak: Double?
	/// Mean linear RGB over the recording, 0…1.
	///
	/// Linear, not sRGB. Averaging gamma-encoded values answers a question
	/// nobody asked — the mean of two sRGB numbers is not the colour of the
	/// mean light — and the whole point of this number is to divide one by
	/// another and get a sensible gain.
	public var cast: [Double]?

	public init(loudness: Double? = nil, peak: Double? = nil, cast: [Double]? = nil) {
		self.loudness = loudness
		self.peak = peak
		self.cast = cast
	}

	public var isEmpty: Bool { loudness == nil && peak == nil && cast == nil }
}

/// How a clip should be graded.
///
/// Two halves that compose: `gain` is what the automatic match worked out, and
/// the rest is what a person decided. The match handles "this camera is cooler
/// than that one"; the hand controls handle "and I want the whole thing warmer".
/// Neither has to know about the other.
public struct Look: Sendable, Equatable {
	/// A named look from the project's `profiles:`, applied underneath.
	public var profile: String?
	/// Stops.
	public var exposure: Double
	/// Warmer positive, cooler negative — roughly Kelvin, applied as a red/blue
	/// tilt rather than a real chromatic adaptation, which would need to know
	/// the source white point and does not.
	public var temperature: Double
	/// Green negative, magenta positive.
	public var tint: Double
	/// 1 is unchanged.
	public var saturation: Double
	/// 1 is unchanged.
	public var contrast: Double
	/// Per-channel linear multiplier, from matching against the reference.
	public var gain: [Double]?

	public init(
		profile: String? = nil, exposure: Double = 0, temperature: Double = 0,
		tint: Double = 0, saturation: Double = 1, contrast: Double = 1, gain: [Double]? = nil
	) {
		self.profile = profile
		self.exposure = exposure
		self.temperature = temperature
		self.tint = tint
		self.saturation = saturation
		self.contrast = contrast
		self.gain = gain
	}

	public static let none = Look()

	public var isEmpty: Bool { self == Look.none }

	/// This look laid over `base` — a profile, usually.
	///
	/// The additive controls add and the multiplicative ones multiply, which is
	/// what makes "this camera's look, and then a bit warmer" mean what it
	/// reads like.
	public func over(_ base: Look) -> Look {
		Look(
			profile: profile ?? base.profile,
			exposure: base.exposure + exposure,
			temperature: base.temperature + temperature,
			tint: base.tint + tint,
			saturation: base.saturation * saturation,
			contrast: base.contrast * contrast,
			gain: gain ?? base.gain)
	}

	/// This look, applied to a frame.
	///
	/// Here rather than in the renderer because a look is a thing that can be
	/// *applied*, and two places now want to: the renderer, which grades every
	/// frame of a programme, and the cutting window, which shows somebody what
	/// they are doing while they drag a slider. Two implementations of the same
	/// arithmetic would be two pictures, and the second one would be wrong in a
	/// way nobody could see until the render came back.
	public func applied(to image: CIImage) -> CIImage {
		var image = image
		if let gain, gain.count == 3 {
			image = image.applyingFilter("CIColorMatrix", parameters: [
				"inputRVector": CIVector(x: gain[0], y: 0, z: 0, w: 0),
				"inputGVector": CIVector(x: 0, y: gain[1], z: 0, w: 0),
				"inputBVector": CIVector(x: 0, y: 0, z: gain[2], w: 0),
			])
		}
		if exposure != 0 {
			image = image.applyingFilter("CIExposureAdjust", parameters: ["inputEV": exposure])
		}
		if temperature != 0 || tint != 0 {
			// The *source* neutral moves, not the target.
			//
			// It was the other way round, with a comment explaining why that
			// meant warmer — and measured on a flat grey, `temperature: 1500`
			// came out blue. The filter's question is "what is this picture's
			// neutral, and what should it be": saying the picture's neutral is
			// 8000 K and should be 6500 tells it the picture is too cool, and
			// it warms it. Saying the reverse cools it, which is what was
			// happening. The file's meaning is unchanged — positive is warmer,
			// as it always said — and the pixels now agree with it.
			image = image.applyingFilter("CITemperatureAndTint", parameters: [
				"inputNeutral": CIVector(x: 6500 + temperature, y: tint),
				"inputTargetNeutral": CIVector(x: 6500, y: 0),
			])
		}
		if saturation != 1 || contrast != 1 {
			image = image.applyingFilter("CIColorControls", parameters: [
				kCIInputSaturationKey: saturation,
				kCIInputContrastKey: contrast,
			])
		}
		return image
	}

	/// The per-channel gain that takes `cast` to `reference`.
	///
	/// Grey-world against a chosen shot rather than against an assumption:
	/// dividing one recording's average by another's corrects the exposure and
	/// the white balance in one number each, which is most of what "these two
	/// cameras do not match" means in practice.
	///
	/// Bounded, because a shot that is genuinely a different scene — a sunset
	/// against an office — would otherwise be "corrected" into a stain. When the
	/// bound binds, the result is a partial match rather than a wrong one.
	public static func match(cast: [Double], to reference: [Double], limit: Double = 1.8) -> [Double]? {
		guard cast.count == 3, reference.count == 3 else { return nil }
		var gain: [Double] = []
		for (source, target) in zip(cast, reference) {
			guard source > 1e-6 else { return nil }
			gain.append(min(max(target / source, 1 / limit), limit))
		}
		return gain
	}
}

/// What colour a recording is, on average.
public enum ColourAnalysis {

	/// Samples frames across a range and averages them.
	///
	/// Twelve frames, not one: a single frame catches whatever was in shot at
	/// that instant, and somebody walking past in a red coat should not
	/// re-grade the take. Not every frame either — the average of a recording
	/// converges long before you have decoded all of it, and decoding all of it
	/// is minutes.
	public static func measure(
		videoURL: URL, from: Double, to: Double, samples: Int = 12
	) async throws -> [Double] {
		let asset = AVURLAsset(url: videoURL)
		guard try await asset.loadTracks(withMediaType: .video).first != nil else {
			throw AnchorError.noVideoTrack(videoURL)
		}
		let generator = AVAssetImageGenerator(asset: asset)
		generator.appliesPreferredTrackTransform = true
		generator.requestedTimeToleranceBefore = .zero
		generator.requestedTimeToleranceAfter = .zero
		// Tiny: the mean of an image does not need the image. Core Graphics
		// does the averaging in the downsample, which is both the fastest and
		// the most accurate way to ask for it.
		generator.maximumSize = CGSize(width: 320, height: 320)

		var totals = [0.0, 0.0, 0.0]
		var counted = 0
		let span = max(to - from, 0)
		for index in 0 ..< max(samples, 1) {
			let t = samples <= 1 ? from : from + span * Double(index) / Double(samples - 1)
			guard let image = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)).image,
			      let mean = average(image)
			else { continue }
			for channel in 0 ..< 3 { totals[channel] += mean[channel] }
			counted += 1
		}
		guard counted > 0 else { throw AnchorError.noVideoTrack(videoURL) }
		return totals.map { $0 / Double(counted) }
	}

	/// The mean linear RGB of one frame.
	static func average(_ image: CGImage) -> [Double]? {
		// Drawn into a 4×4 and averaged, rather than a 1×1: the same answer for
		// an ordinary frame, and it survives an image with one blown highlight
		// in a corner rather better.
		let side = 4
		var pixels = [UInt8](repeating: 0, count: side * side * 4)
		guard let space = CGColorSpace(name: CGColorSpace.sRGB),
		      let context = CGContext(
			      data: &pixels, width: side, height: side, bitsPerComponent: 8,
			      bytesPerRow: side * 4, space: space,
			      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
		else { return nil }
		context.interpolationQuality = .high
		context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))

		var totals = [0.0, 0.0, 0.0]
		for pixel in 0 ..< (side * side) {
			for channel in 0 ..< 3 {
				totals[channel] += linear(Double(pixels[pixel * 4 + channel]) / 255)
			}
		}
		return totals.map { $0 / Double(side * side) }
	}

	/// sRGB's transfer function, undone.
	static func linear(_ value: Double) -> Double {
		value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
	}
}
