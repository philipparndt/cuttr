import CoreImage
import CuttrKit
import Foundation
import Testing
@testable import CuttrCompose

/// Going to film, and coming back.
@Suite struct FilmTests {

	private let size = CGSize(width: 320, height: 180)
	private let context = CIContext(options: [.workingColorSpace: NSNull()])

	/// A flat mid-grey, so a tint shows as a tilt and grain as a wobble.
	private var frame: CIImage {
		CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
			.cropped(to: CGRect(origin: .zero, size: size))
	}

	private func pixel(_ image: CIImage, x: Int, y: Int) -> (Double, Double, Double) {
		var bytes = [UInt8](repeating: 0, count: 4)
		context.render(image, toBitmap: &bytes, rowBytes: 4,
		               bounds: CGRect(x: x, y: y, width: 1, height: 1),
		               format: .RGBA8, colorSpace: nil)
		return (Double(bytes[0]) / 255, Double(bytes[1]) / 255, Double(bytes[2]) / 255)
	}

	private func made(_ film: Film, _ intensity: Double, at time: Double = 0) -> CIImage {
		Filming.applied(film, to: frame, intensity: intensity, size: size, time: time)
	}

	/// At nought it is the frame that went in, untouched — no grade, no grain,
	/// no bars. Anything else and every programme with a film overlay anywhere
	/// in it pays for it everywhere.
	@Test func nothingHappensAtTheStart() {
		let before = pixel(made(Film(), 0), x: 160, y: 90)
		#expect(abs(before.0 - 0.5) < 0.005)
		#expect(abs(before.1 - 0.5) < 0.005)
		#expect(abs(before.2 - 0.5) < 0.005)
		// And the corners are the picture, not bars.
		#expect(pixel(made(Film(), 0), x: 160, y: 2).0 > 0.4)
	}

	/// The bars close as it goes in and open again on the way out — which is
	/// the whole difference between going to film and switching to it.
	@Test func theBarsCloseWithTheTransition() {
		// A 2.39 shape over a 16:9 frame: bars top and bottom.
		let film = Film(ratio: Film.Ratio(2.39, 1), tint: .none, strength: 0, grain: 0, vignette: 0)
		let full = film.bars(in: size).vertical
		#expect(full > 0.1 && full < 0.3, "2.39 over 16:9 is about a sixth: \(full)")

		func barAt(_ intensity: Double) -> Double {
			// How far up the frame is still black.
			var height = 0.0
			for y in 0 ..< 40 where pixel(made(film, intensity), x: 160, y: y).0 < 0.05 {
				height = Double(y + 1)
			}
			return height
		}
		#expect(barAt(0) == 0)
		let half = barAt(0.5), whole = barAt(1)
		#expect(whole > half && half > 0, "half way in: \(half), all the way: \(whole)")
		#expect(abs(whole / Double(size.height) - full) < 0.02)
	}

	/// Which way the bars go follows from the two shapes, and both ways happen.
	@Test func theBarsGoWhicheverWayTheyHaveTo() {
		// A programme cut for a phone, going to 16:9: a wide picture with a
		// great deal of black above and below it.
		let phone = CGSize(width: 1080, height: 1920)
		let widescreen = Film(ratio: Film.Ratio(16, 9)).bars(in: phone)
		#expect(widescreen.horizontal == 0)
		#expect(widescreen.vertical > 0.3)

		// A shape narrower than the programme pillarboxes instead.
		let square = Film(ratio: Film.Ratio(1, 1)).bars(in: size)
		#expect(square.vertical == 0)
		#expect(square.horizontal > 0.2)

		// And a shape the frame already is costs nothing at all.
		#expect(Film(ratio: Film.Ratio(16, 9)).bars(in: size).vertical < 0.001)
		#expect(Film(ratio: Film.Ratio(16, 9)).bars(in: size).horizontal < 0.001)
	}

	@Test func theStockDecidesTheColour() {
		func middle(_ tint: Film.Tint) -> (Double, Double, Double) {
			pixel(made(Film(ratio: Film.Ratio(16, 9), tint: tint, strength: 1,
			                grain: 0, vignette: 0), 1), x: 160, y: 90)
		}
		let warm = middle(.warm)
		#expect(warm.0 > warm.2, "warm should be redder than it is bluer")
		let cool = middle(.cool)
		#expect(cool.2 > cool.0)
		let noir = middle(.noir)
		#expect(abs(noir.0 - noir.2) < 0.02, "noir should have no colour left")
		let plain = middle(.none)
		#expect(abs(plain.0 - 0.5) < 0.01, "`none` should leave the colour alone")
	}

	/// Half the strength is half the way there, so the control is a mix rather
	/// than a switch.
	@Test func strengthMixesTheGradeIn() {
		func warmth(_ strength: Double) -> Double {
			let out = pixel(made(Film(ratio: Film.Ratio(16, 9), tint: .warm, strength: strength,
			                          grain: 0, vignette: 0), 1), x: 160, y: 90)
			return out.0 - out.2
		}
		let full = warmth(1), half = warmth(0.5)
		#expect(full > half && half > 0)
		#expect(abs(half - full / 2) < 0.06, "half strength: \(half) against \(full)")
	}

	/// Grain has to be there, and it has to move — a fixed pattern is dirt on
	/// the lens and the eye finds it in about two seconds.
	@Test func theGrainMovesFromFrameToFrame() {
		let film = Film(ratio: Film.Ratio(16, 9), tint: .none, strength: 0, grain: 1, vignette: 0)
		var seen: Set<Int> = []
		var spread = 0.0
		for time in [0.0, 0.04, 0.08] {
			let image = made(film, 1, at: time)
			let sample = (0 ..< 12).map { pixel(image, x: 40 + $0 * 5, y: 90).0 }
			seen.insert(Int(sample[0] * 1000))
			spread = max(spread, (sample.max() ?? 0) - (sample.min() ?? 0))
		}
		#expect(spread > 0.02, "the grain is flat: \(spread)")
		#expect(seen.count > 1, "the same pattern every frame is dirt on the lens")
	}
}
