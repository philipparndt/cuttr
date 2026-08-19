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
		let effect = Effect(style: .confetti, finish: .metallic,
		                    density: 1.4, speed: 1.2, size: 1.6,
		                    palette: [RGBA(hex: "#ff0000")!], seed: 9)
		let project = Project(
			timeline: [TimelineEntry(clip: ClipReference("intro"))],
			overlays: [Overlay(kind: .effect(effect),
			                   span: .times(from: 0, to: 4),
			                   arrival: .cut, departure: .fall(over: 1.5),
			                   behind: .people)])
		let text = ProjectWriter.write(project)
		let back = try ProjectReader.read(text)
		guard case .effect(let read) = back.overlays.first?.kind else {
			Issue.record("it did not come back as an effect")
			return
		}
		#expect(read == effect, "written:\n\(text)")
		#expect(back.overlays.first?.departure == .fall(over: 1.5))
		#expect(back.overlays.first?.behind == .people)
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
			Effect(style: .confetti, density: 1, seed: 6),
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

/// A caption that goes behind somebody is painted into the frame instead of
/// laid over it, because the shape of the person is only known in the pass that
/// has the pixels.
@Suite struct BehindTests {

	private func caption(behind: Overlay.Occlusion) -> ResolvedOverlay {
		ResolvedOverlay(
			overlay: Overlay(kind: .text("behind her", style: nil),
			                 span: .times(from: 0, to: 4),
			                 arrival: .fade(over: 1), departure: .fade(over: 1),
			                 behind: behind),
			source: 0, appearance: 0, start: 0, end: 4, path: nil)
	}

	@Test func onlyWhatStaysInFrontIsALayer() {
		#expect(OverlayLayers.isLayered(caption(behind: .nothing).overlay))
		#expect(!OverlayLayers.isLayered(caption(behind: .people).overlay))
	}

	@Test func thePainterFadesTheSameWayTheLayerWould() {
		let shown = caption(behind: .people)
		let size = CGSize(width: 640, height: 360)
		let project = Project()

		// Nothing at the very start of a one-second fade, something in the
		// middle of the span, nothing at the very end.
		#expect(OverlayPainter.image(for: shown, project: project, baseURL: URL(fileURLWithPath: "."), size: size, at: 0) == nil)
		#expect(OverlayPainter.image(for: shown, project: project, baseURL: URL(fileURLWithPath: "."), size: size, at: 2) != nil)
		#expect(OverlayPainter.image(for: shown, project: project, baseURL: URL(fileURLWithPath: "."), size: size, at: 4) == nil)
	}

	/// It lands where the style says, in the frame's own coordinates.
	@Test func itIsWhereTheStyleSays() throws {
		let shown = caption(behind: .people)
		let size = CGSize(width: 640, height: 360)
		let image = try #require(OverlayPainter.image(
			for: shown, project: Project(), baseURL: URL(fileURLWithPath: "."),
			size: size, at: 2))
		let style = TextStyle.lowerThird
		// Left-aligned, so the left edge of the plate sits on the position.
		#expect(abs(image.extent.minX - style.position.x * size.width) < 2)
		#expect(image.extent.midY < size.height / 2)
	}
}

/// A spinner and a scene can go behind somebody too, which means they are
/// painted rather than laid over — and what is painted has to be there.
@Suite struct PaintedOverlayTests {

	private func shown(_ kind: Overlay.Kind) -> ResolvedOverlay {
		ResolvedOverlay(
			overlay: Overlay(kind: kind, span: .times(from: 0, to: 4),
			                 arrival: .cut, departure: .cut, behind: .people),
			source: 0, appearance: 0, start: 0, end: 4, path: nil)
	}

	@Test func aSpinnerIsPainted() throws {
		let image = try #require(OverlayPainter.image(
			for: shown(.spinner(Spinner(style: .bars, words: [SpinnerWord("working")]))),
			project: Project(), baseURL: URL(fileURLWithPath: "."),
			size: CGSize(width: 640, height: 360), at: 1))
		#expect(image.extent.width > 10)
		#expect(image.extent.height > 10)
	}

	@Test func aSceneIsPaintedTheSizeOfTheFrame() throws {
		let scene = Scene(parts: [
			.init(content: .text("{{title}}", style: nil),
			      keys: [.init(t: 0, x: 0.5, y: 0.5, opacity: 1)]),
		])
		let project = Project(scenes: ["intro": scene])
		let image = try #require(OverlayPainter.image(
			for: shown(.scene("intro", with: ["title": "Folge 3"])),
			project: project, baseURL: URL(fileURLWithPath: "."),
			size: CGSize(width: 640, height: 360), at: 1))
		#expect(image.extent.size == CGSize(width: 640, height: 360))
	}

	/// Nothing is laid over the frame when it is meant to be under somebody.
	@Test func noneOfThemIsALayer() {
		for kind in [Overlay.Kind.text("a", style: nil),
		             .spinner(Spinner()),
		             .scene("intro", with: [:])] {
			#expect(!OverlayLayers.isLayered(shown(kind).overlay))
		}
	}
}

/// How long an effect takes to appear.
///
/// The renderer's own comment says a piece starts above the frame "so the first
/// of them arrive within a moment and the rest follow". That was measured and
/// it was true only of the fast styles: head-room and spread were fixed
/// *distances*, so snow — which falls at a fifth of confetti's speed — had
/// nothing on screen until four seconds and did not fill until eight. On a
/// three-second card it rendered nothing at all.
@Suite(.serialized) struct EffectArrivalTests {

	private let context = CIContext(options: [.workingColorSpace: NSNull()])

	/// How much of the plate is covered at a moment, in pixels.
	private func ink(_ effect: Effect, at time: Double) -> Int {
		let size = CGSize(width: 480, height: 270)
		guard let renderer = EffectRenderer(effect, size: size),
		      let image = renderer.image(at: time, spawningUntil: .infinity, only: .all)
		else { return -1 }
		var bytes = [UInt8](repeating: 0, count: 480 * 270 * 4)
		context.render(image, toBitmap: &bytes, rowBytes: 480 * 4,
		               bounds: CGRect(origin: .zero, size: size),
		               format: .RGBA8, colorSpace: nil)
		return stride(from: 3, to: bytes.count, by: 4).filter { bytes[$0] > 8 }.count
	}

    @Test func everyStyleIsOnScreenWithinHalfASecond() {
		for style in Effect.Style.allCases {
			// A sparkle is thrown up from below and is a burst rather than a
			// fall, but it too has to be visible early.
			let effect = Effect(style: style)
			#expect(ink(effect, at: 0.5) > 0, "\(style) has nothing on screen at half a second")
		}
	}

	/// And a slow style fills as promptly as a fast one, which is the fault
	/// this pins: three seconds of snow must look like snow.
	@Test func aSlowStyleFillsInTheSameTimeAsAFastOne() {
		let snow = ink(Effect(style: .snow), at: 2)
		let confetti = ink(Effect(style: .confetti), at: 2)
		#expect(snow > 0 && confetti > 0)
		// Not the same number of pixels — the pieces are different sizes — but
		// the same order of thing, rather than one of them being empty.
		#expect(Double(snow) > Double(confetti) / 8, "snow \(snow) against confetti \(confetti)")
	}
}
