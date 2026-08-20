import CoreGraphics
import CoreImage
import Foundation
import QuartzCore
import Testing
@testable import CuttrCompose

/// A background animated in the thing it actually is.
///
/// Before this, a key could state a flat `color` and nothing else, so a
/// background moved in opacity and position and *not* in its gradient — the one
/// thing it is made of. A key now states the far stop and the direction beside
/// the near one, and all of it is measured here on the pixels, because the
/// pixels are what somebody sees.
@Suite struct SceneGradientTests {

	private let size = CGSize(width: 320, height: 180)
	private let context = CIContext(options: [.workingColorSpace: NSNull()])

	/// The frame at a moment, with the origin bottom-left — the same way round
	/// as everything in a scene, so `y: 4` is near the bottom of the picture and
	/// a gradient at 90° has its `from` there.
	private func grey(_ scene: Scene, at time: Double, x: Int, y: Int) throws -> Double {
		let image = try #require(OverlayPainter.sceneImage(
			scene, with: [:], project: Project(), baseURL: URL(fileURLWithPath: "."),
			size: size, at: time))
		var bytes = [UInt8](repeating: 0, count: 4)
		context.render(CIImage(cgImage: image), toBitmap: &bytes, rowBytes: 4,
		               bounds: CGRect(x: x, y: y, width: 1, height: 1),
		               format: .RGBA8, colorSpace: nil)
		return Double(bytes[0]) / 255
	}

	private func background(_ background: Scene.Background, _ keys: [Scene.Key]) -> Scene {
		Scene(parts: [.init(content: .background(background), keys: keys)])
	}

	// MARK: - Two stops, both moving

	/// A background that ramps from one gradient to another, sampled near the
	/// top and near the bottom of the frame at the start, the middle and the
	/// end.
	///
	/// The two stops are made to move *opposite ways* — the near one up from
	/// black, the far one down from a quarter grey — so a renderer that animated
	/// only the near stop and dragged the far one along with it could not pass.
	@Test func bothStopsOfTheRampMove() throws {
		let scene = background(
			Scene.Background(from: .black, to: RGBA(r: 0.25, g: 0.25, b: 0.25), angle: 90),
			[.init(t: 0, opacity: 1, ease: .linear),
			 .init(t: 1, color: .white, to: RGBA(r: 0.75, g: 0.75, b: 0.75), ease: .linear)])

		// Near the bottom is the near stop, near the top the far one.
		let bottom = try [0.0, 0.5, 1.0].map { try grey(scene, at: $0, x: 160, y: 4) }
		let top = try [0.0, 0.5, 1.0].map { try grey(scene, at: $0, x: 160, y: 176) }

		#expect(abs(bottom[0] - 0.0) < 0.05, "the near stop does not start black: \(bottom)")
		#expect(abs(bottom[1] - 0.5) < 0.05, "the near stop is not half way: \(bottom)")
		#expect(abs(bottom[2] - 1.0) < 0.05, "the near stop does not end white: \(bottom)")

		#expect(abs(top[0] - 0.25) < 0.05, "the far stop does not start dark: \(top)")
		#expect(abs(top[1] - 0.5) < 0.05, "the far stop is not half way: \(top)")
		#expect(abs(top[2] - 0.75) < 0.05, "the far stop does not end light: \(top)")

		// And they arrived from opposite directions, which is the point.
		#expect(bottom[0] < bottom[2] && top[0] < top[2])
		#expect(top[0] > bottom[0] && top[2] < bottom[2],
		        "the far stop followed the near one instead of moving on its own")
	}

	/// A flat background ramping into a gradient, which is the case that has no
	/// rule of its own: a flat fill is a gradient whose stops are the same
	/// colour, so there is a second stop at both ends and the arithmetic is
	/// ordinary.
	@Test func aFlatColourRampsIntoAGradient() throws {
		let scene = background(
			Scene.Background(from: .black, angle: 90),
			[.init(t: 0, opacity: 1, ease: .linear),
			 .init(t: 1, to: .white, ease: .linear)])

		// Flat at the start: the top of the frame is the same as the bottom.
		#expect(try abs(grey(scene, at: 0, x: 160, y: 176)
			- grey(scene, at: 0, x: 160, y: 4)) < 0.02)
		// A ramp at the end, and half of one in between.
		#expect(try grey(scene, at: 1, x: 160, y: 176) > 0.95)
		#expect(try grey(scene, at: 1, x: 160, y: 4) < 0.05)
		let half = try grey(scene, at: 0.5, x: 160, y: 176)
		#expect(abs(half - 0.5) < 0.05, "half a ramp is \(half)")
		#expect(try grey(scene, at: 0.5, x: 160, y: 4) < 0.05, "the near stop moved")
	}

	// MARK: - The angle

	/// The ramp turns: measured as which way the picture gets lighter, at two
	/// moments of the same scene.
	@Test func theRampTurns() throws {
		let scene = background(
			Scene.Background(from: .black, to: .white, angle: 0),
			[.init(t: 0, opacity: 1, ease: .linear),
			 .init(t: 1, angle: 90, ease: .linear)])

		// At nought it runs across the frame: dark on the left, light on the
		// right, and the same all the way up a column.
		#expect(try grey(scene, at: 0, x: 4, y: 90) < 0.05)
		#expect(try grey(scene, at: 0, x: 316, y: 90) > 0.95)
		#expect(try abs(grey(scene, at: 0, x: 160, y: 4)
			- grey(scene, at: 0, x: 160, y: 176)) < 0.02)

		// At ninety it runs up it: dark at the bottom, light at the top, and the
		// same all the way along a row.
		#expect(try grey(scene, at: 1, x: 160, y: 4) < 0.05)
		#expect(try grey(scene, at: 1, x: 160, y: 176) > 0.95)
		#expect(try abs(grey(scene, at: 1, x: 4, y: 90)
			- grey(scene, at: 1, x: 316, y: 90)) < 0.02)

		// And half way it is a diagonal: light in one corner, dark in the other.
		#expect(try grey(scene, at: 0.5, x: 4, y: 4) < 0.1)
		#expect(try grey(scene, at: 0.5, x: 316, y: 176) > 0.9)
	}

	/// Three hundred and fifty degrees to ten is twenty degrees of turn, not
	/// three hundred and forty.
	///
	/// Measured where it shows: the long way round passes through 180, where the
	/// ramp is reversed and the light end is on the *left*. So the test is that
	/// the light end never crosses the frame.
	@Test func theRampTurnsTheShortWayRound() throws {
		let scene = background(
			Scene.Background(from: .black, to: .white, angle: 350),
			[.init(t: 0, opacity: 1, ease: .linear),
			 .init(t: 1, angle: 10, ease: .linear)])

		for moment in [0.0, 0.25, 0.5, 0.75, 1.0] {
			let left = try grey(scene, at: moment, x: 4, y: 90)
			let right = try grey(scene, at: moment, x: 316, y: 90)
			#expect(right > left + 0.8,
			        "at \(moment) the ramp has turned the long way: \(left) → \(right)")
		}

		// And the arithmetic underneath it, which is what the pixels are of: the
		// angle goes up through 360 rather than down through 180.
		let keys = Scene.filled(scene.parts[0].keys)
		let declared = Scene.Background(from: .black, to: .white, angle: 350)
		let angles = [0.0, 0.25, 0.5, 0.75].map { declared.at($0, keys: keys).angle }
		#expect(angles == [350, 355, 360, 365])
		// At the key itself it is the number somebody wrote, which is the same
		// direction as 370 and reads better in a file.
		#expect(declared.at(1, keys: keys).angle == 10)
	}

	/// A whole turn cannot be written as nought and three hundred and sixty,
	/// because those are the same direction. It is written as the keys it turns
	/// through — which is worth a test, because it is the price of the rule
	/// above and somebody will want to do it.
	@Test func aWholeTurnIsWrittenAsTheKeysItTurnsThrough() {
		let keys = Scene.filled([
			Scene.Key(t: 0, angle: 0, ease: .linear),
			Scene.Key(t: 1, angle: 120, ease: .linear),
			Scene.Key(t: 2, angle: 240, ease: .linear),
			Scene.Key(t: 3, angle: 360, ease: .linear),
		])
		#expect(Scene.state(of: keys, at: 0.5)?.angle == 60)
		#expect(Scene.state(of: keys, at: 1.5)?.angle == 180)
		#expect(Scene.state(of: keys, at: 2.5)?.angle == 300)
		#expect(Scene.state(of: keys, at: 3)?.angle == 360)
	}

	// MARK: - Nothing else changes

	/// Every byte of every frame of a background that states no gradient on any
	/// key, against what this program drew before there were gradient keys.
	///
	/// The numbers are the FNV-1a hash of the whole 320×180 frame, captured from
	/// the commit before this change by rendering these three scenes and hashing
	/// the bitmap. This is the test that matters most: a flat background, a
	/// declared ramp, and a ramp whose `color` moves are what every scene in
	/// `examples/` and in anybody's project is made of, and not one of their
	/// pixels is allowed to move.
	@Test func aSceneWithNoGradientKeysDrawsTheSameBytes() throws {
		let ramp = background(
			Scene.Background(from: RGBA(hex: "#0b1220")!, to: RGBA(hex: "#1d3557")!, angle: 90),
			[.init(t: 0, opacity: 0), .init(t: 0.4, opacity: 1, ease: .out)])
		let tinted = background(
			Scene.Background(from: RGBA(hex: "#0b1220")!, to: RGBA(hex: "#1d3557")!, angle: 30),
			[.init(t: 0, opacity: 1, color: RGBA(hex: "#802010")!),
			 .init(t: 1, color: RGBA(hex: "#20a080")!, ease: .out)])
		let flat = background(Scene.Background(from: RGBA(hex: "#101418")!),
		                      [.init(t: 0, opacity: 1)])

		let expected: [String: [Double: UInt64]] = [
			"ramp": [0: 10_899_314_016_002_978_691,
			         0.2: 14_422_866_609_275_137_855,
			         0.4: 5_503_496_522_185_580_339,
			         1: 5_503_496_522_185_580_339],
			"tinted": [0: 8_747_651_273_579_717_428,
			           0.2: 8_277_275_567_427_755_966,
			           0.4: 1_666_893_970_066_219_504,
			           1: 10_685_311_302_588_272_777],
			"flat": [0: 1_643_999_880_852_151_171,
			         0.2: 1_643_999_880_852_151_171,
			         0.4: 1_643_999_880_852_151_171,
			         1: 1_643_999_880_852_151_171],
		]
		for (name, scene) in [("ramp", ramp), ("tinted", tinted), ("flat", flat)] {
			// None of them states the gradient anywhere, so none of them takes
			// the new path at all.
			#expect(!Scene.movesTheGradient(Scene.filled(scene.parts[0].keys)))
			for time in [0.0, 0.2, 0.4, 1.0] {
				#expect(try hash(of: scene, at: time) == expected[name]?[time],
				        "\(name) at \(time) is not the frame it was")
			}
		}
	}

	/// The whole frame, as one number.
	private func hash(of scene: Scene, at time: Double) throws -> UInt64 {
		let image = try #require(OverlayPainter.sceneImage(
			scene, with: [:], project: Project(), baseURL: URL(fileURLWithPath: "."),
			size: size, at: time))
		let width = Int(size.width), height = Int(size.height)
		var bytes = [UInt8](repeating: 0, count: width * height * 4)
		let drawing = try #require(bytes.withUnsafeMutableBytes { raw in
			CGContext(data: raw.baseAddress, width: width, height: height,
			          bitsPerComponent: 8, bytesPerRow: width * 4,
			          space: CGColorSpace(name: CGColorSpace.sRGB)!,
			          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
		})
		drawing.draw(image, in: CGRect(origin: .zero, size: size))
		guard let made = drawing.makeImage(),
		      let data = made.dataProvider?.data as Data? else { return 0 }
		var digest: UInt64 = 1_469_598_103_934_665_603
		for byte in data { digest = (digest ^ UInt64(byte)) &* 1_099_511_628_211 }
		return digest
	}

	/// A part whose keys state the gradient, in and out of the file, twice.
	@Test func aGradientOnAKeySurvivesTheFile() throws {
		let project = Project(scenes: ["dusk": background(
			Scene.Background(from: RGBA(hex: "#0b1220")!, to: RGBA(hex: "#1d3557")!, angle: 90),
			[.init(t: 0, opacity: 1),
			 .init(t: 2, color: RGBA(hex: "#402015")!, to: RGBA(hex: "#f4a261")!,
			       angle: 350, ease: .out)])])
		let text = ProjectWriter.write(project)
		#expect(text.contains(
			"- {t: 2, color: \"#402015\", to: \"#f4a261\", angle: 350, ease: out}"))
		let back = try ProjectReader.read(text)
		#expect(back.scenes == project.scenes)
		#expect(ProjectWriter.write(back) == text)
	}

	/// …and a key that states no gradient writes exactly what it always wrote:
	/// `color`, and nothing beside it.
	@Test func aKeyWithNoGradientWritesWhatItAlwaysWrote() throws {
		let project = Project(scenes: ["plate": background(
			Scene.Background(from: RGBA(hex: "#0b1220")!, to: RGBA(hex: "#1d3557")!, angle: 90),
			[.init(t: 0, opacity: 1, color: RGBA(hex: "#802010")!)])])
		let text = ProjectWriter.write(project)
		// The key line and the whole of it: the part's own `to` and `angle` are
		// on the line above, and a key that says nothing about them says nothing.
		let line = try #require(text.split(separator: "\n")
			.first { $0.contains("- {t: 0") }).trimmingCharacters(in: .whitespaces)
		#expect(line == "- {t: 0, opacity: 1, color: \"#802010\"}")
		#expect(try ProjectReader.read(text).scenes == project.scenes)
	}

	// MARK: - What the resolver answers

	/// A background with no gradient keys resolves to exactly the arithmetic
	/// this had before: the declared ramp, with `color` at the near stop.
	///
	/// Written down because it is *why* the frames above cannot move — the
	/// painter and the layer path both take a `Background` and nothing else, so
	/// the same `Background` is the same pixels.
	@Test func withoutGradientKeysTheAnswerIsTheDeclaredRamp() {
		let declared = Scene.Background(from: RGBA(hex: "#0b1220")!,
		                                to: RGBA(hex: "#1d3557")!, angle: 30)
		let keys = Scene.filled([.init(t: 0, opacity: 1, color: RGBA(hex: "#802010")!),
		                         .init(t: 1, color: RGBA(hex: "#20a080")!, ease: .linear)])
		let now = declared.at(0.5, keys: keys)
		#expect(now.to == declared.to)
		#expect(now.angle == declared.angle)
		#expect(now.from == RGBA.between(RGBA(hex: "#802010")!, RGBA(hex: "#20a080")!, 0.5))

		// And a flat one stays flat, which is what keeps it a single fill rather
		// than a ramp between two of the same colour.
		let plate = Scene.Background(from: RGBA(hex: "#101418")!)
		#expect(plate.at(3, keys: Scene.filled([.init(t: 0, opacity: 1)])).to == nil)
	}

	// MARK: - The export

	/// The layer path — which is what an export runs — turns the gradient too,
	/// and only when a key asks it to.
	///
	/// Core Animation interpolates a gradient's ends as points, so a turn built
	/// from two keyframes would cut across the arc and the ramp would tighten
	/// half way round. The samples are what keeps the export the picture the
	/// preview draws, so this asserts there are a great many of them and that
	/// the first and last are the directions the keys asked for.
	@Test func theExportTurnsTheGradientOnASampledTrack() throws {
		func ramp(_ keys: [Scene.Key]) throws -> CAGradientLayer {
			let scene = background(Scene.Background(from: .black, to: .white, angle: 0), keys)
			let overlay = Overlay(kind: .scene("dusk", with: [:]), span: .times(from: 0, to: 2))
			let resolved = ResolvedProject(
				project: Project(overlays: [overlay], scenes: ["dusk": scene]), clips: [],
				overlays: [ResolvedOverlay(overlay: overlay, origin: .project(0), appearance: 0,
				                           start: 0, end: 2, path: nil)],
				groups: [], anchors: [])
			return try #require(gradient(
				in: OverlayLayers.build(resolved, size: size, host: .export)))
		}

		/// The one gradient layer anywhere in the tree, whatever the tree's shape
		/// is — which is not this test's business.
		func gradient(in layer: CALayer) -> CAGradientLayer? {
			if let ramp = layer as? CAGradientLayer { return ramp }
			for child in layer.sublayers ?? [] {
				if let found = gradient(in: child) { return found }
			}
			return nil
		}

		let turning = try ramp([.init(t: 0, opacity: 1, ease: .linear),
		                        .init(t: 2, angle: 90, ease: .linear)])
		let track = try #require(turning.animation(forKey: "startPoint") as? CAKeyframeAnimation)
		#expect((track.values?.count ?? 0) > 30, "too coarse to be an arc")
		#expect(turning.animation(forKey: "endPoint") != nil)
		#expect(turning.animation(forKey: "colors") != nil)
		let first = try #require(track.values?.first as? NSValue).pointValue
		let last = try #require(track.values?.last as? NSValue).pointValue
		// Nought runs across the frame and ninety runs up it, so the start of
		// the ramp moves from the left edge to the bottom one.
		#expect(abs(first.x) < 0.001 && abs(first.y - 0.5) < 0.001, "starts at \(first)")
		#expect(abs(last.x - 0.5) < 0.001 && abs(last.y) < 0.001, "ends at \(last)")

		// A background whose keys say nothing about the gradient keeps the
		// animation it always had: the colours, at the keys, and no more.
		let still = try ramp([.init(t: 0, opacity: 1, color: .black),
		                      .init(t: 2, color: RGBA(r: 0.5, g: 0.5, b: 0.5), ease: .linear)])
		#expect(still.animation(forKey: "startPoint") == nil)
		#expect(still.animation(forKey: "endPoint") == nil)
		#expect((still.animation(forKey: "colors") as? CAKeyframeAnimation)?.values?.count == 2)
	}

	/// A key stating either the far stop or the angle is what turns a background
	/// into a ramp, and both count.
	@Test func statingEitherOneIsWhatMakesItARamp() {
		#expect(!Scene.movesTheGradient([.init(t: 0, opacity: 1, color: .white)]))
		#expect(Scene.movesTheGradient([.init(t: 0, opacity: 1), .init(t: 1, to: .white)]))
		#expect(Scene.movesTheGradient([.init(t: 0, opacity: 1), .init(t: 1, angle: 45)]))
		// A flat part whose keys move the gradient has a second stop from then
		// on, and it is the near one, so nothing looks different until a key
		// says it should.
		let plate = Scene.Background(from: .black)
		let keys = Scene.filled([.init(t: 0, opacity: 1), .init(t: 1, angle: 45)])
		#expect(plate.at(0, keys: keys).to == RGBA.black)
	}
}
