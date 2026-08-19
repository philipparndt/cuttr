import CoreImage
import CuttrKit
import Foundation
import Testing
@testable import CuttrCompose

/// Reading pixels back off the things that are the frame rather than something
/// over it.
///
/// Flat colours and hard edges go in and the numbers that come out are checked
/// against the claim each effect makes about itself. None of it is visible in a
/// type that compiles: an aberration that pulls the channels the same distance
/// everywhere looks exactly like one that grows towards the edges until
/// somebody measures the fringe in two places.
struct FramePixels {

	let size: CGSize
	/// No colour management, for the reason the renderer records at length.
	let context = CIContext(options: [.workingColorSpace: NSNull()])

	init(_ size: CGSize = CGSize(width: 320, height: 180)) { self.size = size }

	var frame: CGRect { CGRect(origin: .zero, size: size) }

	func flat(_ white: Double) -> CIImage {
		CIImage(color: CIColor(red: white, green: white, blue: white)).cropped(to: frame)
	}

	/// A white column on black — an edge to find fringes and wobbles against.
	func column(at x: Int, wide: Int = 20) -> CIImage {
		CIImage(color: CIColor(red: 1, green: 1, blue: 1))
			.cropped(to: CGRect(x: CGFloat(x), y: 0, width: CGFloat(wide), height: size.height))
			.composited(over: flat(0))
			.cropped(to: frame)
	}

	func pixel(_ image: CIImage, x: Int, y: Int) -> (r: Double, g: Double, b: Double) {
		var bytes = [UInt8](repeating: 0, count: 4)
		context.render(image, toBitmap: &bytes, rowBytes: 4,
		               bounds: CGRect(x: x, y: y, width: 1, height: 1),
		               format: .RGBA8, colorSpace: nil)
		return (Double(bytes[0]) / 255, Double(bytes[1]) / 255, Double(bytes[2]) / 255)
	}

	/// The whole frame, for the tests that ask whether two of them are the same.
	func bytes(_ image: CIImage) -> [UInt8] {
		let width = Int(size.width), height = Int(size.height)
		var pixels = [UInt8](repeating: 0, count: width * height * 4)
		pixels.withUnsafeMutableBytes { raw in
			context.render(image, toBitmap: raw.baseAddress!, rowBytes: width * 4,
			               bounds: frame, format: .RGBA8, colorSpace: nil)
		}
		return pixels
	}

	/// The whole frame, drawn once and then read many times.
	///
	/// A pixel at a time through `render(toBitmap:)` is a whole render of the
	/// graph per pixel, which for the tests that scan forty frames is minutes
	/// rather than seconds.
	struct Bitmap {
		let width: Int, height: Int
		let bytes: [UInt8]

		/// In the frame's own coordinates: `y` nought is the bottom, as it is
		/// everywhere else in this program. The buffer arrives the other way up.
		subscript(x: Int, y: Int) -> (r: Double, g: Double, b: Double) {
			let index = ((height - 1 - y) * width + x) * 4
			return (Double(bytes[index]) / 255, Double(bytes[index + 1]) / 255,
			        Double(bytes[index + 2]) / 255)
		}
	}

	func map(_ image: CIImage) -> Bitmap {
		Bitmap(width: Int(size.width), height: Int(size.height), bytes: bytes(image))
	}

	/// The first column, going right from `from`, where this channel is lit.
	func edge(_ map: Bitmap, row: Int, from: Int, channel: Int = 1) -> Int? {
		for x in from..<Int(size.width) {
			let out = map[x, row]
			let value = channel == 0 ? out.r : channel == 1 ? out.g : out.b
			if value > 0.5 { return x }
		}
		return nil
	}
}

// MARK: - The lens

@Suite struct AberrationTests {

	private let pixels = FramePixels()

	private func made(_ aberration: Aberration, _ intensity: Double,
	                  over picture: CIImage) -> CIImage {
		Aberrating.applied(aberration, to: picture, intensity: intensity, size: pixels.size)
	}

	/// At nought it is the frame that went in, and no filter has run over it.
	/// Anything else and every programme with an aberration anywhere in it pays
	/// for it everywhere.
	@Test func nothingHappensAtTheStart() {
		let picture = pixels.column(at: 200)
		let out = made(Aberration(amount: 1), 0, over: picture)
		#expect(pixels.bytes(out) == pixels.bytes(picture))
		// And an aberration of nought is nothing however far into it we are.
		#expect(pixels.bytes(made(Aberration(amount: 0), 1, over: picture))
			== pixels.bytes(picture))
	}

	/// How wide the red fringe is off the right-hand side of an edge that many
	/// pixels from the middle of the frame.
	private func fringe(_ aberration: Aberration, at x: Int) -> Int {
		let picture = pixels.column(at: x, wide: 12)
		let out = made(aberration, 1, over: picture)
		var width = 0
		for step in 0..<40 {
			let sample = pixels.pixel(out, x: x + 12 + step, y: 90)
			guard sample.r > 0.4, sample.g < 0.4 else { break }
			width += 1
		}
		return width
	}

	/// The whole difference between a lens and a printing mistake: the
	/// separation is nothing in the middle and grows towards the edges.
	@Test func aRadialAberrationGrowsTowardsTheEdges() {
		let aberration = Aberration(kind: .radial, amount: 5)
		let near = fringe(aberration, at: 168)   // eight pixels off the middle
		let far = fringe(aberration, at: 280)    // a hundred and twenty
		#expect(near <= 1, "the middle of the frame should be nearly untouched: \(near)")
		#expect(far > 4, "the edge of the frame should be pulled well apart: \(far)")
		// Five per cent of the distance from the centre, near enough.
		#expect(abs(Double(far) - 0.05 * 126) < 2, "\(far) pixels at a hundred and twenty-six")
	}

	/// And the flat one is flat: the same offset wherever it is measured.
	@Test func aLinearAberrationIsTheSameEverywhere() {
		let aberration = Aberration(kind: .linear, amount: 5)
		let near = fringe(aberration, at: 168)
		let far = fringe(aberration, at: 280)
		#expect(near > 2 && abs(near - far) <= 1, "\(near) against \(far)")
		// Half a per cent of the frame's height each way at amount one.
		#expect(abs(Double(far) - 5 * 0.005 * 180) < 1.5, "\(far) pixels")
	}

	/// Which way `angle` points. Nought is to the right, and red is the one
	/// that goes that way.
	@Test func theAngleDecidesWhichWayItPulls() {
		let picture = pixels.column(at: 200, wide: 12)
		let right = made(Aberration(kind: .linear, amount: 5, angle: 0), 1, over: picture)
		let left = made(Aberration(kind: .linear, amount: 5, angle: 180), 1, over: picture)
		// Just off the right-hand edge of the column.
		#expect(pixels.pixel(right, x: 214, y: 90).r > 0.4)
		#expect(pixels.pixel(right, x: 214, y: 90).b < 0.4)
		#expect(pixels.pixel(left, x: 214, y: 90).b > 0.4)
		#expect(pixels.pixel(left, x: 214, y: 90).r < 0.4)
	}

	/// The fade spreads the channels rather than mixing a clean frame back in.
	/// Half way in is half the separation — a ghost of the picture at half
	/// strength is what it must not be.
	@Test func theFadeSpreadsRatherThanGhosts() {
		let aberration = Aberration(kind: .linear, amount: 8)
		let picture = pixels.column(at: 200, wide: 12)
		func width(_ intensity: Double) -> Int {
			let out = made(aberration, intensity, over: picture)
			var found = 0
			for step in 0..<40 {
				let sample = pixels.pixel(out, x: 212 + step, y: 90)
				guard sample.r > 0.4, sample.g < 0.4 else { break }
				found += 1
			}
			return found
		}
		let full = width(1), half = width(0.5)
		#expect(full > half && half > 0, "half way: \(half), all the way: \(full)")
		#expect(abs(Double(half) - Double(full) / 2) <= 1)
		// And what is left of the picture is the picture, not a double
		// exposure: the middle of the column is still white.
		let middle = pixels.pixel(made(aberration, 0.5, over: picture), x: 206, y: 90)
		#expect(middle.r > 0.9 && middle.g > 0.9 && middle.b > 0.9)
	}
}

// MARK: - The tape

@Suite struct TapeTests {

	private let pixels = FramePixels()

	private func made(_ tape: Tape, _ intensity: Double = 1, at time: Double = 1,
	                  over picture: CIImage) -> CIImage {
		Taping.applied(tape, to: picture, intensity: intensity, size: pixels.size, time: time)
	}

	/// One knob at a time, so a test about the wobble is not also a test about
	/// the lines.
	private func only(_ edit: (inout Tape) -> Void) -> Tape {
		var tape = Tape(.clean)
		tape.jitter = 0; tape.band = 0; tape.chroma = 0; tape.scanlines = 0; tape.dropouts = 0
		edit(&tape)
		return tape
	}

	@Test func nothingHappensAtTheStart() {
		let picture = pixels.column(at: 150)
		#expect(pixels.bytes(made(Tape(.chewed), 0, over: picture)) == pixels.bytes(picture))
		// And a tape with every knob at nought is a tape that does nothing.
		#expect(pixels.bytes(made(only { _ in }, 1, over: picture)) == pixels.bytes(picture))
	}

	/// The tracking: rows pushed sideways by different amounts, and the picture
	/// underneath showing in the gap rather than a black margin.
	@Test func theTrackingPushesRowsSideways() {
		let picture = pixels.column(at: 150)
		func edges(_ tape: Tape, at time: Double = 1) -> [Int] {
			let out = pixels.map(made(tape, at: time, over: picture))
			return stride(from: 2, to: 178, by: 4).compactMap { pixels.edge(out, row: $0, from: 100) }
		}
		let still = edges(only { $0.jitter = 0 })
		#expect(Set(still).count == 1, "nothing should move with the jitter off: \(Set(still))")

		let moved = edges(only { $0.jitter = 1 })
		let spread = (moved.max() ?? 0) - (moved.min() ?? 0)
		#expect(Set(moved).count > 4, "the rows are all in the same place: \(Set(moved))")
		#expect(spread > 4, "the wobble is too small to see: \(spread)")
		// Sideways, not upwards: every row still has an edge to find.
		#expect(moved.count == 44)
	}

	/// It wobbles as it plays. A tracking error that holds still is a crooked
	/// picture.
	@Test func theTrackingMovesWithTime() {
		let picture = pixels.column(at: 150)
		func edges(at time: Double) -> [Int] {
			let out = pixels.map(made(only { $0.jitter = 1 }, at: time, over: picture))
			return stride(from: 2, to: 178, by: 4).compactMap { pixels.edge(out, row: $0, from: 100) }
		}
		// The whole column rather than one row of it: a single strip can be at
		// the same place at two moments — a wave passes through where it
		// started — and that is not the picture holding still.
		#expect(edges(at: 0.2) != edges(at: 1.4))
	}

	/// The colour arrives after the brightness, so an edge carries colour off
	/// one side of it.
	@Test func theColourRunsSideways() {
		let picture = pixels.column(at: 150, wide: 20)
		let out = made(only { $0.chroma = 1 }, over: picture)
		// Just past the right-hand edge of the column: red and blue are late,
		// so they are still there where the brightness has stopped.
		let past = pixels.pixel(out, x: 171, y: 90)
		#expect(past.r > 0.5, "no colour ran off the edge: \(past)")
		#expect(past.g < 0.5, "the brightness ran too, which is not what this is")
		// And the other edge is the other way about: green first.
		let before = pixels.pixel(out, x: 151, y: 90)
		#expect(before.g > 0.5 && before.r < 0.5, "\(before)")
	}

	@Test func theLinesDarkenEveryOtherOne() {
		let out = made(only { $0.scanlines = 1 }, over: pixels.flat(0.8))
		let rows = (0..<8).map { pixels.pixel(out, x: 160, y: $0).g }
		let light = rows.max() ?? 0, dark = rows.min() ?? 0
		#expect(light > 0.7, "the lit lines should be the picture: \(light)")
		#expect(dark < 0.5, "the dark lines are not dark: \(dark)")
		// Alternating, not a gradient across the frame.
		#expect(Set(rows.map { $0 > 0.6 }).count == 2)
	}

	/// A dropout is a fault, and a fault that happens on every frame is a
	/// pattern. Some fields have one, some do not, and which is which comes
	/// from the seed.
	@Test func theDropoutsComeAndGo() {
		let picture = pixels.flat(0)
		var hit = 0
		for field in 0..<40 {
			let out = pixels.map(made(only { $0.dropouts = 1 },
			                          at: Double(field) / 30 + 0.001, over: picture))
			// The colour channels only: the alpha is one everywhere.
			let lit = out.bytes.enumerated().contains { $0.offset % 4 != 3 && $0.element > 76 }
			if lit { hit += 1 }
		}
		#expect(hit > 8, "no dropouts at all in forty fields: \(hit)")
		#expect(hit < 40, "a dropout on every field is not a fault: \(hit)")
	}

	/// The whole point of a seed: the same one is the same picture, on any
	/// machine and in any render, and a different one is a different picture.
	@Test func theSeedDecidesEverything() {
		let picture = pixels.column(at: 150)
		func frame(seed: Int, at time: Double = 1.234) -> [UInt8] {
			var tape = Tape(.chewed)
			tape.seed = seed
			return pixels.bytes(made(tape, at: time, over: picture))
		}
		#expect(frame(seed: 3) == frame(seed: 3))
		#expect(frame(seed: 3) != frame(seed: 4))
		#expect(frame(seed: 3) != frame(seed: 3, at: 2.5))
	}

	/// The condition is the five knobs, so choosing one is choosing all five.
	@Test func theConditionSetsTheKnobs() {
		#expect(Tape(.clean).dropouts == 0)
		#expect(Tape(.chewed).jitter > Tape(.worn).jitter)
		#expect(Tape(.worn).jitter > Tape(.clean).jitter)
		for condition in Tape.Condition.allCases {
			let settings = Tape.settings(condition)
			let tape = Tape(condition)
			#expect((tape.jitter, tape.band, tape.chroma, tape.scanlines, tape.dropouts)
				== (settings.jitter, settings.band, settings.chroma,
				    settings.scanlines, settings.dropouts))
		}
	}
}
