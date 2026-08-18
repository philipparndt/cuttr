import CoreGraphics
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
