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
		// A fiftieth of the frame is a lot of confetti: the pieces are small,
		// and the ones at the back of the cloud are smaller still.
		#expect(full.covered > 0.01, "it never fills: \(full.covered)")
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

/// Depth: what is further back is smaller, darker and slower.
///
/// A cloud of confetti all one size at all one speed reads as a sheet of
/// stickers moving down the screen; the depth is what makes it a shower.
@Suite struct EffectDepthTests {

	@Test func theBackOfTheCloudIsSmallerAndSlower() throws {
		let renderer = try #require(EffectRenderer(
			Effect(style: .confetti, density: 1, seed: 2), size: CGSize(width: 320, height: 180)))
		let sizes = renderer.depths
		#expect(sizes.count > 20)

		// Sorted by how far back they are: the near half is bigger than the far
		// half, and falls further in the same time.
		let sorted = sizes.sorted { $0.depth < $1.depth }
		let near = sorted.prefix(sorted.count / 2)
		let far = sorted.suffix(sorted.count / 2)
		#expect(near.map(\.size).reduce(0, +) / Double(near.count)
			> far.map(\.size).reduce(0, +) / Double(far.count))
		#expect(near.map(\.fall).reduce(0, +) / Double(near.count)
			> far.map(\.fall).reduce(0, +) / Double(far.count))
	}
}

/// The keys an effect is written with come back as the same effect.
@Suite struct EffectFileTests {

	@Test func everyDialSurvivesTheFile() throws {
		let effect = Effect(style: .confetti, finish: .metallic, behind: .people,
		                    density: 1.4, speed: 1.2, size: 1.6,
		                    palette: [RGBA(hex: "#ff0000")!], seed: 9)
		let project = Project(
			timeline: [TimelineEntry(clip: ClipReference("intro"))],
			overlays: [Overlay(kind: .effect(effect),
			                   span: .times(from: 0, to: 4),
			                   arrival: .cut, departure: .fall(over: 1.5))])
		let text = ProjectWriter.write(project)
		let back = try ProjectReader.read(text)
		guard case .effect(let read) = back.overlays.first?.kind else {
			Issue.record("it did not come back as an effect")
			return
		}
		#expect(read == effect, "written:\n\(text)")
		#expect(back.overlays.first?.departure == .fall(over: 1.5))
		#expect(ProjectWriter.write(back) == text)
	}
}

/// The two halves of the cloud are two halves: they add up to it, and neither
/// is the whole thing.
///
/// Which is the test the occlusion needed. Hiding a node is an animatable
/// change, and a scene with no view has no clock to run the animation on — so
/// the flags were set and nothing was hidden. Both halves held the whole cloud,
/// the composite came out pixel-identical to no occlusion at all, and every
/// intermediate step looked right.
@Suite struct EffectHalvesTests {

	@Test func theHalvesPartitionTheCloud() throws {
		let renderer = try #require(EffectRenderer(
			Effect(style: .confetti, behind: .people, density: 1, seed: 6),
			size: CGSize(width: 320, height: 180)))

		_ = renderer.image(at: 6, only: .all)
		let all = renderer.showing
		_ = renderer.image(at: 6, only: .back)
		let back = renderer.showing
		_ = renderer.image(at: 6, only: .front)
		let front = renderer.showing

		#expect(all > 0)
		#expect(back > 0, "nothing goes behind")
		#expect(front > 0, "nothing stays in front")
		#expect(back + front == all, "\(back) + \(front) is not \(all)")
		#expect(back < all)
	}
}
