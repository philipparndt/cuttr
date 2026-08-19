import CoreImage
import Foundation

/// Playing the frame off a worn tape.
///
/// Five things in a fixed order, each of them off when its knob is nought and
/// all of them scaled by how far into the overlay the programme is. At nought
/// the frame is handed back as it came — the same rule film mode follows, and
/// the reason a programme with a tape effect in one place stays exact
/// everywhere else.
///
/// Nothing here steps from the frame before: every number comes from the seed
/// and the time, so any moment can be asked for in any order — which is what a
/// scrubbing preview does — and the same second comes out the same on every
/// machine.
enum Taping {

	/// How many strips the frame is cut into for the tracking wobble.
	///
	/// Measured at 1080, thirty frames each: the frame alone 0.5 ms, eight
	/// strips 2.3, twenty-four 2.8, sixty-four 5.9, a hundred and twenty 10.4.
	/// Twenty-four is where it stops looking better — the wobble on a tape is a
	/// slow thing several dozen lines tall, not a per-scanline one — so paying
	/// four times as much for it buys nothing anybody can see.
	private static let strips = 24

	/// Thirty a second, whatever the render is.
	///
	/// Tied to the frame rate instead, a dropout would last one frame of a 60
	/// fps render and half as long as on the 30 fps version of the same
	/// programme. A field is a length of time, not a number of frames.
	private static let fieldsPerSecond = 30.0

	static func applied(
		_ tape: Tape, to picture: CIImage, intensity: Double, size: CGSize, time: Double
	) -> CIImage {
		let amount = min(1, max(0, intensity))
		guard amount > 0.001, size.width > 2, size.height > 2 else { return picture }
		let frame = CGRect(origin: .zero, size: size)
		let field = Int((max(0, time) * fieldsPerSecond).rounded(.down))
		var image = picture

		// --- The colour, running sideways -------------------------------------
		//
		// Both colour channels late and the brightness on time, which is what
		// the format actually did: the chroma was carried under the luma and
		// arrived after it. So a white edge on black gets magenta on one side
		// and green on the other, and a green edge — where there is no red or
		// blue to be late — does not move at all.
		let chroma = max(0, min(1, tape.chroma)) * amount
		if chroma > 0.001 {
			let late = chroma * 0.008 * Double(size.width)
			image = Aberrating.combined(
				red: Aberrating.shifted(image, by: CGPoint(x: late, y: 0), in: size),
				green: image,
				blue: Aberrating.shifted(image, by: CGPoint(x: late * 0.7, y: 0), in: size),
				size: size)
		}

		// --- The tracking -----------------------------------------------------
		//
		// Each strip on its own slow wave, so the picture leans rather than
		// vibrating. The strip is cropped, moved, and cropped back to where it
		// was, which leaves the picture underneath showing in the gap — a smear
		// rather than a black margin, which is what a tape does.
		let jitter = max(0, min(1, tape.jitter)) * amount
		if jitter > 0.001 {
			var random = Seeded(tape.seed)
			let height = size.height / CGFloat(strips)
			let reach = jitter * 0.05 * Double(size.width)
			var wobbled = image
			for index in 0..<strips {
				let rate = random.value(0.3...2.4)
				let phase = random.value(0...(2 * .pi))
				let weight = random.value(0.15...1)
				let step = CGFloat(sin(rate * time * 6 + phase) * weight * reach)
				guard abs(step) >= 0.5 else { continue }
				let band = CGRect(x: 0, y: CGFloat(index) * height,
				                  width: size.width, height: height)
				wobbled = image.cropped(to: band)
					.transformed(by: CGAffineTransform(translationX: step, y: 0))
					.cropped(to: band)
					.composited(over: wobbled)
			}
			image = wobbled.cropped(to: frame)
		}

		// --- The band ---------------------------------------------------------
		//
		// One band of brighter, noisier, more displaced picture crawling up the
		// frame. Up rather than down because that is the way a tracking error
		// travels on a helical scan, and everybody who has watched a tape knows
		// which way it goes even if they could not say so.
		let band = max(0, min(1, tape.band)) * amount
		if band > 0.001 {
			let thickness = size.height * CGFloat(0.05 + 0.08 * band)
			let travelled = (time * 0.22).truncatingRemainder(dividingBy: 1)
			let bottom = CGFloat(travelled) * (size.height + thickness) - thickness
			let rect = CGRect(x: 0, y: bottom, width: size.width, height: thickness)
				.intersection(frame)
			if rect.height > 1 {
				var strip = image.cropped(to: rect)
					.transformed(by: CGAffineTransform(
						translationX: CGFloat(band * 0.02 * Double(size.width)), y: 0))
					.cropped(to: rect)
					.applyingFilter("CIColorControls", parameters: [
						kCIInputBrightnessKey: 0.06 * band,
						kCIInputContrastKey: 1 + 0.2 * band,
						kCIInputSaturationKey: max(0, 1 - 0.5 * band),
					])
				// The noise moves with the field rather than with the clock, so
				// it is a new pattern every field and the same one twice if the
				// same field is asked for twice.
				if let noise = CIFilter(name: "CIRandomGenerator")?.outputImage?
					.transformed(by: CGAffineTransform(
						translationX: CGFloat(field * 71 % 512), y: CGFloat(field * 37 % 512)))
					.applyingFilter("CIColorControls", parameters: [
						kCIInputSaturationKey: 0,
						kCIInputContrastKey: 0.5 + 0.5 * band,
					])
					.cropped(to: rect) as CIImage? {
					let lit = noise.applyingFilter("CISoftLightBlendMode", parameters: [
						kCIInputBackgroundImageKey: strip,
					])
					strip = strip.applyingFilter("CIDissolveTransition", parameters: [
						kCIInputTargetImageKey: lit,
						kCIInputTimeKey: min(1, band),
					])
				}
				image = strip.cropped(to: rect).composited(over: image)
			}
		}

		// --- The dropouts -----------------------------------------------------
		//
		// Short bright streaks where the tape has lost its coating. A field at a
		// time and only some fields, because a dropout on every frame is a
		// pattern and a pattern is not a fault.
		let dropouts = max(0, min(1, tape.dropouts)) * amount
		if dropouts > 0.001 {
			var random = Seeded(tape.seed &+ field &* 9781)
			for _ in 0..<3 where random.value(0...1) < dropouts * 0.6 {
				let thickness = CGFloat(random.value(1...3)) * max(1, size.height / 240)
				let rect = CGRect(
					x: CGFloat(random.value(0...0.75) * Double(size.width)),
					y: CGFloat(random.value(0...1) * Double(size.height)),
					width: CGFloat(random.value(0.06...0.4) * Double(size.width)),
					height: thickness).intersection(frame)
				guard rect.height >= 1, rect.width >= 1 else { continue }
				image = CIImage(color: CIColor(red: 0.92, green: 0.92, blue: 0.9,
				                               alpha: 0.5 + 0.45 * dropouts))
					.cropped(to: rect)
					.composited(over: image)
			}
		}

		// --- The lines --------------------------------------------------------
		//
		// Last, and over everything, because they are the display rather than
		// the tape: a dropout is on the tape and wobbles with it, a scanline is
		// where the beam was not.
		let scanlines = max(0, min(1, tape.scanlines)) * amount
		if scanlines > 0.001 {
			// A fixed number of lines whatever the render is — two hundred and
			// forty pairs, near enough what the format showed — with a floor of
			// one pixel so a small preview gets lines it can actually draw.
			let width = max(1, Double(size.height) / 480)
			if let stripes = CIFilter(name: "CIStripesGenerator", parameters: [
				kCIInputCenterKey: CIVector(x: 0, y: 0),
				"inputColor0": CIColor(red: 1, green: 1, blue: 1),
				"inputColor1": CIColor(red: 1 - 0.5 * scanlines, green: 1 - 0.5 * scanlines,
				                       blue: 1 - 0.5 * scanlines),
				kCIInputWidthKey: width,
				kCIInputSharpnessKey: 1,
			])?.outputImage?
				.transformed(by: CGAffineTransform(rotationAngle: .pi / 2))
				.cropped(to: frame) {
				image = stripes.applyingFilter("CIMultiplyBlendMode", parameters: [
					kCIInputBackgroundImageKey: image,
				]).cropped(to: frame)
			}
		}

		return image
	}
}
