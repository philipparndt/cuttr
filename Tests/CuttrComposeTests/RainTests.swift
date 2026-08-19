import CoreImage
import Foundation
import Testing
@testable import CuttrCompose

/// Rain, as pixels and as geometry.
///
/// It is in the effect renderer rather than in a filter because it is a thing
/// at a distance: the far streaks are smaller, dimmer and slower, and the near
/// ones pass in front of them. A rain filter over the whole frame has none of
/// that, and looks like a scratched print. So what is measured here is the
/// depth as much as the wet.
///
/// Serialized, and it has to be. Building an `EffectRenderer` waits on work
/// SceneKit schedules for itself, so it needs a free thread; six of these
/// running as six concurrent tasks take every thread the pool has and all of
/// them stop for good inside SceneKit's warm-up. Sampled, not guessed — the
/// whole run sat there for ten minutes with nine threads in
/// `C3DWarmupSceneVRAMResourcesForEngineContext`.
@Suite(.serialized) struct RainTests {

	private let size = CGSize(width: 320, height: 180)
	private let context = CIContext(options: [.workingColorSpace: NSNull()])

	/// Every lit pixel of a plate, as a grid of flags.
	private func lit(_ image: CIImage) -> [[Bool]] {
		let width = Int(size.width), height = Int(size.height)
		var bytes = [UInt8](repeating: 0, count: width * height * 4)
		bytes.withUnsafeMutableBytes { raw in
			context.render(image, toBitmap: raw.baseAddress!, rowBytes: width * 4,
			               bounds: CGRect(origin: .zero, size: size),
			               format: .RGBA8, colorSpace: nil)
		}
		return (0..<height).map { row in
			(0..<width).map { bytes[(row * width + $0) * 4 + 3] > 40 }
		}
	}

	/// It falls in rather than being there already, and there is a great deal
	/// of it once it is going.
	@Test func itArrivesAndThenItIsRaining() throws {
		let renderer = try #require(EffectRenderer(
			Effect(style: .rain, density: 1, seed: 9), size: size))
		func covered(at time: Double) throws -> Double {
			let grid = lit(try #require(renderer.image(at: time)))
			let count = grid.reduce(0) { $0 + $1.filter { $0 }.count }
			return Double(count) / (size.width * size.height)
		}
		let atStart = try covered(at: 0)
		let soon = try covered(at: 1.5)
		#expect(atStart < 0.004, "the frame is already full at zero: \(atStart)")
		#expect(soon > atStart)
		#expect(soon > 0.008, "it never really rains: \(soon)")
	}

	/// Streaks, not drops. A drop photographs as a line because the shutter is
	/// open while it falls, and the length is what makes rain read as rain.
	@Test func theDropsAreLongAndThin() throws {
		let renderer = try #require(EffectRenderer(
			Effect(style: .rain, density: 0.6, seed: 4), size: size))
		let grid = lit(try #require(renderer.image(at: 2)))

		/// The longest unbroken run of lit pixels through a lit one, each way.
		func runs() -> (down: Int, across: Int) {
			var down = 0, across = 0
			for row in grid.indices {
				var here = 0
				for column in grid[row].indices {
					here = grid[row][column] ? here + 1 : 0
					across = max(across, here)
				}
			}
			for column in grid[0].indices {
				var here = 0
				for row in grid.indices {
					here = grid[row][column] ? here + 1 : 0
					down = max(down, here)
				}
			}
			return (down, across)
		}
		let (down, across) = runs()
		#expect(down > 10, "the streaks are not long: \(down) pixels")
		#expect(down > across * 3, "\(down) down against \(across) across is not a streak")
	}

	/// The back of the shower is further away: smaller, slower, and dimmer.
	@Test func theBackOfTheShowerIsFurtherAway() throws {
		let renderer = try #require(EffectRenderer(
			Effect(style: .rain, density: 0.3, seed: 2), size: size))
		let near = renderer.depths.filter { $0.depth < 0.25 }
		let far = renderer.depths.filter { $0.depth > 0.75 }
		#expect(!near.isEmpty && !far.isEmpty)
		let nearSize = near.map(\.size).reduce(0, +) / Double(near.count)
		let farSize = far.map(\.size).reduce(0, +) / Double(far.count)
		let nearFall = near.map(\.fall).reduce(0, +) / Double(near.count)
		let farFall = far.map(\.fall).reduce(0, +) / Double(far.count)
		#expect(farSize < nearSize * 0.85, "\(farSize) against \(nearSize)")
		#expect(farFall < nearFall * 0.85, "\(farFall) against \(nearFall)")
	}

	/// The wind carries it sideways, and every streak on the same slant —
	/// because a drop going twice as fast covers twice the ground while it
	/// falls, which is the one thing that makes a wind read as weather rather
	/// than as a mistake.
	@Test func theWindCarriesItAndLeansIt() throws {
		func travel(wind: Double) throws -> Double {
			let renderer = try #require(EffectRenderer(
				Effect(style: .rain, density: 0.2, wind: wind, seed: 6), size: size))
			_ = renderer.image(at: 0.05)
			let before = stride(from: 0, to: renderer.positions.count, by: 3)
				.map { renderer.positions[$0] }
			_ = renderer.image(at: 0.15)
			let after = stride(from: 0, to: renderer.positions.count, by: 3)
				.map { renderer.positions[$0] }
			// The middle of the moves rather than the average of them: a piece
			// that has just gone off one side of the cloud and come back on the
			// other has moved the width of the frame, and one of those in forty
			// is enough to decide an average.
			let moves = zip(before, after).map { $1 - $0 }.sorted()
			return moves[moves.count / 2]
		}
		#expect(abs(try travel(wind: 0)) < 0.01, "it drifts with no wind on it")
		let blown = try travel(wind: 2)
		#expect(blown > 0.1, "the wind moved nothing: \(blown)")
		#expect(try travel(wind: -2) < -0.1, "and it blows the other way too")
	}

	/// Same seed, same rain — the rule every effect in this program follows.
	@Test func theSameSeedIsTheSameRain() throws {
		func rain(seed: Int) -> [Double] {
			guard let renderer = EffectRenderer(
				Effect(style: .rain, density: 0.1, seed: seed),
				size: CGSize(width: 64, height: 36)) else { return [] }
			_ = renderer.image(at: 1.5)
			return renderer.positions
		}
		#expect(rain(seed: 8) == rain(seed: 8))
		#expect(rain(seed: 8) != rain(seed: 9))
	}

	/// Through the file and back, with the wind written only when it is
	/// blowing.
	@Test func rainSurvivesTheFile() throws {
		let overlay = Overlay(
			kind: .effect(Effect(style: .rain, density: 1.5, wind: 1.2, seed: 4)),
			span: .clips(from: ClipReference("intro"), to: ClipReference("intro")))
		let project = Project(timeline: [TimelineEntry(clip: ClipReference("intro"))],
		                      overlays: [overlay])
		let text = ProjectWriter.write(project)
		#expect(text.contains("  - effect:  rain\n"))
		#expect(text.contains("wind:    1.2"))
		let back = try ProjectReader.read(text)
		#expect(back.overlays == project.overlays)
		#expect(ProjectWriter.write(back) == text)

		// Still down rather than sideways is not written at all.
		let calm = Project(
			timeline: [TimelineEntry(clip: ClipReference("intro"))],
			overlays: [Overlay(kind: .effect(Effect(style: .rain)),
			                   span: .clips(from: ClipReference("intro"),
			                                to: ClipReference("intro")))])
		#expect(!ProjectWriter.write(calm).contains("wind:"))
	}
}
