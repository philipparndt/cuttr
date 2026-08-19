import CoreGraphics
import CoreImage
import Foundation
import Testing
@testable import CuttrKit

@Suite struct GradeTests {

	@Test func aLookLaysOverAProfile() {
		let profile = Look(exposure: 0.2, temperature: 300, saturation: 1.1)
		let own = Look(exposure: 0.1, saturation: 1.05, contrast: 0.95)
		let combined = own.over(profile)
		// Additive controls add, multiplicative ones multiply — which is what
		// makes "this camera's look, and then a bit brighter" mean what it reads
		// like rather than replacing the profile.
		#expect(abs(combined.exposure - 0.3) < 1e-9)
		#expect(combined.temperature == 300)
		#expect(abs(combined.saturation - 1.155) < 1e-9)
		#expect(abs(combined.contrast - 0.95) < 1e-9)
	}

	@Test func matchingDividesOneAverageByTheOther() {
		let gain = try! #require(Look.match(cast: [0.20, 0.25, 0.30], to: [0.25, 0.25, 0.25]))
		#expect(abs(gain[0] - 1.25) < 1e-9)
		#expect(abs(gain[1] - 1.0) < 1e-9)
		#expect(abs(gain[2] - (0.25 / 0.30)) < 1e-9)
	}

	@Test func matchingIsBoundedSoADifferentSceneIsNotStained() {
		// A sunset against an office is not a camera mismatch, and "correcting"
		// it would ruin both. The bound makes it a partial match instead.
		let gain = try! #require(Look.match(cast: [0.02, 0.25, 0.25], to: [0.25, 0.25, 0.25], limit: 1.8))
		#expect(gain[0] == 1.8)
	}

	@Test func matchingDeclinesOnBlack() {
		// Dividing by nothing gives nonsense, and nonsense applied to every
		// frame is worse than leaving it alone.
		#expect(Look.match(cast: [0, 0, 0], to: [0.25, 0.25, 0.25]) == nil)
		#expect(Look.match(cast: [0.25, 0.25], to: [0.25, 0.25, 0.25]) == nil)
	}

	@Test func measurementsAndLooksRoundTrip() throws {
		let take = Take(
			video: "a.mov",
			clips: [Clip(slug: "a", start: 0, end: 1)],
			measured: Measured(loudness: -21.4, peak: -3.1, cast: [0.412, 0.398, 0.431]),
			look: Look(profile: "camera-b", exposure: 0.08, saturation: 1.04, gain: [1.02, 1.0, 0.97]))
		let back = try TakeReader.read(TakeWriter.write(take))
		#expect(back.measured.loudness == -21.4)
		#expect(back.measured.cast?.count == 3)
		#expect(back.look.profile == "camera-b")
		#expect(abs(back.look.saturation - 1.04) < 1e-9)
		#expect(back.look.gain?[0] == 1.02)
		#expect(back == take)
	}

	@Test func anUnmeasuredTakeCarriesNoBlocks() {
		// A take nobody has analysed should not be full of defaults that look
		// like decisions somebody made.
		let text = TakeWriter.write(Take(video: "a.mov", clips: [Clip(slug: "a", start: 0, end: 1)]))
		#expect(!text.contains("measured:"))
		#expect(!text.contains("look:"))
	}

	@Test func sRGBIsUndoneBeforeAveraging() {
		// The mean of two gamma-encoded numbers is not the colour of the mean
		// light, and the whole point of the cast is to divide one by another.
		#expect(abs(ColourAnalysis.linear(0) - 0) < 1e-9)
		#expect(abs(ColourAnalysis.linear(1) - 1) < 1e-9)
		#expect(ColourAnalysis.linear(0.5) < 0.25)
	}
}

/// The grade, on actual pixels.
///
/// It lives with the look because two things apply it now — the renderer and
/// the cutting window's preview — and two copies of "what warmer means" would
/// drift apart at the first change.
@Suite struct LookAppliedTests {

	private let context = CIContext(options: [.workingColorSpace: NSNull()])

	private func pixel(_ look: Look, _ colour: CIColor) -> (Double, Double, Double) {
		let frame = CIImage(color: colour).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
		var bytes = [UInt8](repeating: 0, count: 4)
		context.render(look.applied(to: frame), toBitmap: &bytes, rowBytes: 4,
		               bounds: CGRect(x: 1, y: 1, width: 1, height: 1),
		               format: .RGBA8, colorSpace: nil)
		return (Double(bytes[0]) / 255, Double(bytes[1]) / 255, Double(bytes[2]) / 255)
	}

	private var grey: CIColor { CIColor(red: 0.5, green: 0.5, blue: 0.5) }

	@Test func anEmptyLookLeavesTheFrameAlone() {
		let before = pixel(.none, grey)
		#expect(abs(before.0 - 0.5) < 0.01)
		#expect(abs(before.1 - 0.5) < 0.01)
	}

	@Test func exposureIsInStops() {
		let up = pixel(Look(exposure: 1), grey)
		#expect(up.0 > 0.85, "a stop up should be about twice the light: \(up.0)")
		let down = pixel(Look(exposure: -1), grey)
		#expect(down.0 < 0.3)
	}

	/// Positive is warmer, which is the direction the file and the slider say.
	@Test func warmerIsPositive() {
		let warm = pixel(Look(temperature: 1500), grey)
		#expect(warm.0 > warm.2, "warmer should come out redder than it is bluer")
		let cool = pixel(Look(temperature: -1500), grey)
		#expect(cool.2 > cool.0)

		// And tint: green negative, magenta positive, as the file says.
		let magenta = pixel(Look(tint: 40), grey)
		#expect(magenta.0 > magenta.1 && magenta.2 > magenta.1)
		let green = pixel(Look(tint: -40), grey)
		#expect(green.1 > green.0 && green.1 > green.2)
	}

	@Test func saturationEmptiesTheColourOut() {
		let red = CIColor(red: 0.8, green: 0.2, blue: 0.2)
		let flat = pixel(Look(saturation: 0), red)
		#expect(abs(flat.0 - flat.1) < 0.02)
		#expect(abs(flat.1 - flat.2) < 0.02)
		let more = pixel(Look(saturation: 1.8), red)
		#expect(more.0 > 0.8)
	}

	/// The matched gain is a per-channel multiplier, and it is applied first —
	/// a match under a hand grade rather than over it.
	@Test func theMatchedGainMultipliesEachChannel() {
		let matched = pixel(Look(gain: [1.4, 1, 0.6]), grey)
		#expect(matched.0 > 0.6)
		#expect(matched.2 < 0.4)
	}
}
