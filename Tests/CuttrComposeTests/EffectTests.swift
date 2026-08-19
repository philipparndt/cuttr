import CoreImage
import Foundation
import SceneKit
import Testing
@testable import CuttrCompose

/// The effects, as pixels.
@Suite struct EffectTests {

	/// Something is actually in the frame, and it moves.
	@Test func confettiFillsTheFrame() throws {
		let renderer = try #require(EffectRenderer(
			Effect(style: .confetti, density: 1.4, seed: 7), size: CGSize(width: 640, height: 360)))
		let context = CIContext()

		func coverage(at time: Double) throws -> (covered: Double, dump: String) {
			let image = try #require(renderer.image(at: time))
			let width = 640, height = 360
			var pixels = [UInt8](repeating: 0, count: width * height * 4)
			pixels.withUnsafeMutableBytes { bytes in
				context.render(image, toBitmap: bytes.baseAddress!, rowBytes: width * 4,
				               bounds: CGRect(x: 0, y: 0, width: width, height: height),
				               format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
			}
			var lit = 0
			for index in stride(from: 3, to: pixels.count, by: 4) where pixels[index] > 20 { lit += 1 }
			return (Double(lit) / Double(width * height), "")
		}

		// It falls in: nothing at the first frame, filling within a couple of
		// seconds. Starting full and fading up is what it must *not* do.
		let atStart = try coverage(at: 0)
		let soon = try coverage(at: 1.5)
		let full = try coverage(at: 4)
		print("coverage at 0s:", atStart.covered, "1.5s:", soon.covered, "4s:", full.covered)
		#expect(atStart.covered < 0.005, "the frame is already full at zero: \(atStart.covered)")
		#expect(soon.covered > atStart.covered)
		#expect(full.covered > 0.02, "it never fills: \(full.covered)")
	}
}

/// The same seed is the same cloud, and a different seed is a different one.
///
/// A render nobody can repeat is one nobody can approve: a director who liked
/// the third take of a shower of confetti has to be able to get that one back.
@Suite struct EffectSeedTests {

	private func cloud(seed: Int, at time: Double) -> [Double] {
		guard let renderer = EffectRenderer(
			Effect(style: .confetti, density: 0.1, seed: seed), size: CGSize(width: 64, height: 36))
		else { return [] }
		_ = renderer.image(at: time)
		return renderer.positions
	}

	@Test func theSameSeedGivesTheSameCloud() {
		#expect(cloud(seed: 4, at: 1.5) == cloud(seed: 4, at: 1.5))
		#expect(cloud(seed: 4, at: 1.5) != cloud(seed: 5, at: 1.5))
		#expect(cloud(seed: 4, at: 1.5) != cloud(seed: 4, at: 2.5))
	}
}

/// A shower that runs out rather than one somebody switched off.
@Suite struct FallOutTests {

	@Test func afterTheCutOffTheCloudEmpties() throws {
		let renderer = try #require(EffectRenderer(
			Effect(style: .confetti, density: 1, seed: 3), size: CGSize(width: 320, height: 180)))

		func showing(at time: Double, spawningUntil: Double) -> Int {
			_ = renderer.image(at: time, spawningUntil: spawningUntil)
			return renderer.showing
		}

		// Left alone it keeps going; cut off at three seconds it thins out.
		let keptGoing = showing(at: 8, spawningUntil: .infinity)
		let ranOut = showing(at: 8, spawningUntil: 3)
		#expect(keptGoing > ranOut, "the cloud did not empty: \(keptGoing) then \(ranOut)")
		#expect(showing(at: 2, spawningUntil: 3) == showing(at: 2, spawningUntil: .infinity),
		        "it emptied before the cut-off")
	}
}
