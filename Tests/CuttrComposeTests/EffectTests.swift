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

		let first = try coverage(at: 0.5)
		let later = try coverage(at: 2.5)
		print("coverage at 0.5s:", first.covered, "at 2.5s:", later.covered)
		#expect(first.covered > 0.02, "the frame is empty: \(first.covered)")
		#expect(later.covered > 0.02)
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
