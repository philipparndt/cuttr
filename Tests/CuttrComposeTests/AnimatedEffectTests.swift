import CoreImage
import CuttrKit
import Foundation
import Testing
@testable import CuttrCompose

/// The frame filters with their knobs moving, measured on the pixels.
///
/// The claim each one is making is that the *picture* changes over the span,
/// not merely that a number does — so every test here reads the frame back and
/// counts something in it. Written in the style of `FilmTests`, which is where
/// this suite's grey frame and pixel reader come from.
@Suite struct AnimatedFrameTests {

	private let size = CGSize(width: 320, height: 180)
	private let context = CIContext(options: [.workingColorSpace: NSNull()])

	private func pixel(_ image: CIImage, x: Int, y: Int) -> (r: Double, g: Double, b: Double) {
		var bytes = [UInt8](repeating: 0, count: 4)
		context.render(image, toBitmap: &bytes, rowBytes: 4,
		               bounds: CGRect(x: x, y: y, width: 1, height: 1),
		               format: .RGBA8, colorSpace: nil)
		return (Double(bytes[0]) / 255, Double(bytes[1]) / 255, Double(bytes[2]) / 255)
	}

	/// A flat mid-grey, for the things that show as a tilt.
	private var grey: CIImage {
		CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
			.cropped(to: CGRect(origin: .zero, size: size))
	}

	/// White on the left, black on the right, with the edge well off centre.
	///
	/// An aberration on a flat colour is invisible and has to be: it moves the
	/// three channels apart, and a picture that is the same everywhere is the
	/// same everywhere when it is moved. The fringe only exists at an edge, and
	/// a radial one only away from the middle of the frame.
	private var edge: CIImage {
		let frame = CGRect(origin: .zero, size: size)
		return CIImage(color: CIColor(red: 1, green: 1, blue: 1))
			.cropped(to: CGRect(x: 0, y: 0, width: 260, height: size.height))
			.composited(over: CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: frame))
	}

	/// How many columns across the middle of the frame have red and blue at
	/// different levels — which is the fringe, and nothing else is.
	private func fringe(_ image: CIImage) -> Int {
		(0..<Int(size.width)).filter { x in
			let colour = pixel(image, x: x, y: 90)
			return abs(colour.r - colour.b) > 0.1
		}.count
	}

	/// An aberration whose `amount` grows, measured at three moments.
	///
	/// The number this is really checking is the *fringe*, in columns of actual
	/// pixels, because that is the thing somebody sees. The amounts are far
	/// larger than anybody would use — a tenth of one is what reads as glass —
	/// so that a 320-wide frame has enough columns to count.
	@Test func theAberrationGrowsBetweenThreeMoments() {
		let overlay = Overlay(
			kind: .aberration(Aberration(kind: .radial, amount: 0.2)),
			span: .times(from: 0, to: 3),
			keys: [
				Overlay.Key(t: 0),
				Overlay.Key(t: 1.5, [.amount: 4], ease: .linear),
				Overlay.Key(t: 3.0, [.amount: 12], ease: .linear),
			])

		func fringeWidth(at time: Double) -> Int {
			guard case .aberration(let now) = overlay.kind(at: time) else { return -1 }
			return fringe(Aberrating.applied(now, to: edge, intensity: 1, size: size))
		}
		let start = fringeWidth(at: 0)
		let middle = fringeWidth(at: 1.5)
		let end = fringeWidth(at: 3)
		#expect(start >= 0 && start <= 2, "it is already wide open at the start: \(start)")
		#expect(middle > start, "it did not grow: \(start) then \(middle)")
		#expect(end > middle, "it stopped growing: \(middle) then \(end)")
		// And roughly where the arithmetic says: the radial kind scales by one
		// per cent of the frame at amount one, so twelve at 120 pixels out from
		// the middle is about fourteen pixels of separation.
		#expect(end > 8, "the fringe never really opened: \(end)")
	}

	/// A knob that is off at one key and on at the next.
	///
	/// The tape's scanlines, because they are the one of the five that is
	/// exactly measurable on a flat frame: every other row goes into shadow, so
	/// the difference between neighbouring rows goes from nothing to something.
	@Test func aTapeKnobIsOffAtOneKeyAndOnAtTheNext() {
		var tape = Tape(.clean)
		tape.jitter = 0; tape.band = 0; tape.chroma = 0; tape.dropouts = 0
		tape.scanlines = 0
		let overlay = Overlay(kind: .tape(tape), span: .times(from: 0, to: 2),
		                      keys: [
		                      	Overlay.Key(t: 0, [.scanlines: 0]),
		                      	Overlay.Key(t: 2, [.scanlines: 1], ease: .linear),
		                      ])

		/// The biggest step between one row and the next, down a column.
		func banding(at time: Double) -> Double {
			guard case .tape(let now) = overlay.kind(at: time) else { return -1 }
			let image = Taping.applied(now, to: grey, intensity: 1, size: size, time: time)
			let column = (60..<120).map { pixel(image, x: 160, y: $0).g }
			return zip(column, column.dropFirst()).map { abs($0 - $1) }.max() ?? 0
		}
		let off = banding(at: 0)
		let half = banding(at: 1)
		let on = banding(at: 2)
		#expect(off < 0.01, "the lines were already there at the first key: \(off)")
		#expect(on > 0.15, "the lines never arrived: \(on)")
		#expect(half > off && half < on, "it jumped rather than arriving: \(off), \(half), \(on)")
	}

	/// The bars closing in, because the shape is closing in.
	///
	/// The one parameter here that had to be *checked* rather than reasoned
	/// about. A bar's edge lands on a whole pixel, so a shape that closes slowly
	/// enough holds the same bar for two frames and the movement reads as a
	/// staircase. Measured at 720, where a project actually renders: the bar
	/// grows by between one and three rows every frame of a 25 fps pass and
	/// never once repeats itself, so there is nothing to see.
	///
	/// At a preview size it does step — a 180-row frame has 23 rows of bar to
	/// grow through and 50 frames to do it in — and that is the preview's
	/// resolution rather than the shape's, which is why this is measured where
	/// the answer matters.
	@Test func theBarsCloseAsTheShapeDoes() {
		let big = CGSize(width: 1280, height: 720)
		let picture = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
			.cropped(to: CGRect(origin: .zero, size: big))
		let overlay = Overlay(
			kind: .film(Film(ratio: Film.Ratio(16, 9), tint: .none,
			                 strength: 0, grain: 0, vignette: 0)),
			span: .times(from: 0, to: 2),
			keys: [Overlay.Key(t: 0), Overlay.Key(t: 2, [.ratio: 2.39], ease: .linear)])

		/// How many rows up from the bottom are black. Found by halving rather
		/// than by scanning: the bar is one band, so eight reads answer what two
		/// hundred would.
		func bar(at time: Double) -> Int {
			guard case .film(let now) = overlay.kind(at: time) else { return -1 }
			let image = Filming.applied(now, to: picture, intensity: 1, size: big, time: 0)
			func black(_ y: Int) -> Bool {
				var bytes = [UInt8](repeating: 0, count: 4)
				context.render(image, toBitmap: &bytes, rowBytes: 4,
				               bounds: CGRect(x: 640, y: y, width: 1, height: 1),
				               format: .RGBA8, colorSpace: nil)
				return Double(bytes[0]) / 255 < 0.05
			}
			guard black(0) else { return 0 }
			var low = 0, high = 300
			while high - low > 1 {
				let middle = (low + high) / 2
				if black(middle) { low = middle } else { high = middle }
			}
			return high
		}
		let heights = stride(from: 0.0, through: 2.0, by: 1.0 / 25).map(bar)
		#expect(heights.first == 0, "16:9 over a 16:9 frame has bars: \(heights.first ?? -1)")
		#expect(heights.last ?? 0 > 80, "the bars never closed: \(heights.last ?? -1)")
		// Every frame moves, none of them backwards, and none by a leap: the
		// definition of closing rather than stepping.
		for (before, after) in zip(heights.dropFirst(), heights.dropFirst(2)) {
			#expect(after > before, "the bars held still or opened: \(heights)")
			#expect(after - before <= 4, "the bars jumped: \(heights)")
		}
	}

	/// The keys move the knobs; `in:` and `out:` still scale the lot. Two
	/// mechanisms, and they compose rather than one replacing the other.
	@Test func theEnvelopeStillScalesWhatTheKeysSay() {
		let overlay = Overlay(
			kind: .aberration(Aberration(kind: .radial, amount: 12)),
			span: .times(from: 0, to: 3), keys: [Overlay.Key(t: 0), Overlay.Key(t: 3, [.amount: 12])])
		guard case .aberration(let now) = overlay.kind(at: 1.5) else { return #expect(Bool(false)) }
		let full = fringe(Aberrating.applied(now, to: edge, intensity: 1, size: size))
		let quarterWayIn = fringe(Aberrating.applied(now, to: edge, intensity: 0.25, size: size))
		#expect(quarterWayIn < full, "the fade did nothing: \(quarterWayIn) against \(full)")
		#expect(quarterWayIn > 0)
	}
}

// MARK: - The clouds

/// A particle effect with its knobs moving.
///
/// Serialized, and it has to be, for the reason `RainTests` records: building an
/// `EffectRenderer` waits on work SceneKit schedules for itself, and several of
/// them at once take every thread the pool has and stop inside the warm-up.
@Suite(.serialized) struct AnimatedEffectTests {

	private let size = CGSize(width: 320, height: 180)

	/// Where every piece is, in the frame, at a moment.
	private func heights(_ renderer: EffectRenderer, at time: Double) -> [Double] {
		_ = renderer.image(at: time)
		return stride(from: 1, to: renderer.positions.count, by: 3).map { renderer.positions[$0] }
	}

	/// Rain whose speed changes, with the pieces moving continuously through
	/// the key.
	///
	/// This is the measurement the whole integrating exists for. Speed goes from
	/// 1 to 4 over the second after `t = 2`, and what is checked is the distance
	/// each piece covers between one frame and the next: it must be the same
	/// either side of the key, and grow to four times as much by the end of the
	/// ramp.
	///
	/// The wrong arithmetic — the speed at this instant multiplied by the time
	/// so far — is continuous in the *value* and still fails this, which is the
	/// trap. Differentiate it and the distance per frame is
	/// `fall × (speed + time × speed′)`: with `speed′` at three a second and two
	/// seconds already on the clock, the frame after the key moves seven times
	/// as far as the frame before it. That is the surge this test exists to
	/// catch, and no amount of interpolating the speed itself prevents it.
	@Test func rainKeepsItsFootingThroughASpeedKey() throws {
		let renderer = try #require(EffectRenderer(
			Effect(style: .rain, density: 0.3, speed: 1, seed: 11),
			keys: [Overlay.Key(t: 2, [.speed: 1], ease: .linear),
			       Overlay.Key(t: 3, [.speed: 4], ease: .linear)],
			size: size))

		let frame = 1.0 / 50
		/// How far the middle piece falls between two moments a frame apart.
		/// The median, because a piece that has reached the bottom wraps back to
		/// the top and that is a step of the whole frame in the other direction.
		func step(from time: Double) -> Double {
			let before = heights(renderer, at: time)
			let after = heights(renderer, at: time + frame)
			let fallen = zip(before, after).map { $0 - $1 }.filter { $0 > 0 && $0 < 4 }.sorted()
			return fallen[fallen.count / 2]
		}

		let justBefore = step(from: 2 - frame)
		let justAfter = step(from: 2)
		#expect(abs(justAfter - justBefore) / justBefore < 0.06,
		        "it lurched at the key: \(justBefore) then \(justAfter)")

		// And by the end of the ramp it really is going four times as fast.
		let atTheEnd = step(from: 3 - frame)
		#expect(abs(atTheEnd / justBefore - 4) < 0.35,
		        "it did not reach four times: \(justBefore) then \(atTheEnd)")

		// All the way through, no single frame moves much more than the one
		// before it: an acceleration, not a cut.
		var last = justBefore
		for moment in stride(from: 2.0, through: 3.0, by: frame) {
			let now = step(from: moment)
			#expect(now >= last * 0.98, "it slowed down mid-ramp: \(last) then \(now)")
			#expect(now < last * 1.25, "it jumped at \(moment): \(last) then \(now)")
			last = now
		}
	}

	/// A density that comes on: more of the cloud in the air later than earlier,
	/// with nothing appearing in shot.
	@Test func theDensityThinsAndFillsTheCloud() throws {
		let renderer = try #require(EffectRenderer(
			Effect(style: .rain, density: 0.2, speed: 1.5, seed: 5),
			keys: [Overlay.Key(t: 0), Overlay.Key(t: 6, [.density: 1], ease: .linear)],
			size: size))

		func showing(at time: Double) -> Int {
			_ = renderer.image(at: time)
			return renderer.showing
		}
		// Built for the fullest it ever is, so there are pieces to let go.
		#expect(renderer.depths.count == Effect(style: .rain).count(for: 1))
		let early = showing(at: 1)
		let late = showing(at: 6)
		#expect(late > early * 2, "the shower never came on: \(early) then \(late)")

		// And nothing winks out where anybody can see it. Whether a piece is let
		// go is decided once per lap, at the moment it would have come over the
		// top of the frame — so a piece whose answer changes between one frame
		// and the next is a piece that is above the top edge or below the
		// bottom one at both of them. A piece that changed anywhere in between
		// would be one that vanished mid-air, which is the thing an animated
		// density must not do and the reason it is decided at release rather
		// than at the moment.
		let top = 5.0   // half the world height, which is the edge of the frame
		let frame = 1.0 / 50
		for moment in stride(from: 0.5, through: 6.0, by: frame * 12) {
			let before = heights(renderer, at: moment), wasHidden = renderer.hiddenFlags
			let after = heights(renderer, at: moment + frame), nowHidden = renderer.hiddenFlags
			for index in wasHidden.indices where wasHidden[index] != nowHidden[index] {
				#expect(abs(before[index]) > top && abs(after[index]) > top,
				        "a piece changed in shot at \(moment): \(before[index]) then \(after[index])")
			}
		}
	}

	/// Pieces that grow. `size` is a scale set on the node every frame, which is
	/// why it is one of the four that can move.
	@Test func thePiecesGrow() throws {
		let renderer = try #require(EffectRenderer(
			Effect(style: .confetti, density: 1, size: 0.5, seed: 6),
			keys: [Overlay.Key(t: 0), Overlay.Key(t: 4, [.size: 3], ease: .linear)],
			size: size))
		let context = CIContext(options: [.workingColorSpace: NSNull()])
		func covered(at time: Double) throws -> Double {
			let image = try #require(renderer.image(at: time))
			let width = Int(size.width), height = Int(size.height)
			var bytes = [UInt8](repeating: 0, count: width * height * 4)
			bytes.withUnsafeMutableBytes { raw in
				context.render(image, toBitmap: raw.baseAddress!, rowBytes: width * 4,
				               bounds: CGRect(origin: .zero, size: size),
				               format: .RGBA8, colorSpace: nil)
			}
			var lit = 0
			for index in stride(from: 3, to: bytes.count, by: 4) where bytes[index] > 20 { lit += 1 }
			return Double(lit) / Double(width * height)
		}
		let small = try covered(at: 2)
		let large = try covered(at: 4)
		#expect(large > small * 2, "the pieces did not grow: \(small) then \(large)")
	}

	/// The same project makes the same frames, keys and all. An effect nobody
	/// can repeat is one nobody can approve.
	@Test func ananimatedCloudIsStillDeterministic() throws {
		func cloud() -> [Double] {
			guard let renderer = EffectRenderer(
				Effect(style: .snow, density: 0.1, seed: 3),
				keys: [Overlay.Key(t: 0, [.wind: 0]),
				       Overlay.Key(t: 2, [.wind: 2, .speed: 3], ease: .inOut)],
				size: CGSize(width: 64, height: 36))
			else { return [] }
			_ = renderer.image(at: 2.7)
			return renderer.positions
		}
		let once = cloud()
		#expect(!once.isEmpty)
		#expect(once == cloud())
	}

	/// The wind is integrated against the speed, so a piece's path is
	/// continuous when the wind turns on.
	///
	/// The lean multiplied by the clock — which is what the arithmetic was
	/// before, and correct only while the lean never changes — slides every
	/// piece sideways the instant the wind rises.
	@Test func theWindArrivesWithoutSlidingTheCloudSideways() throws {
		// Rain rather than snow, because a flake wanders on its own — the sway
		// is a wobble of its own and would be in every measurement here. A drop
		// has too little air under it to wander, so every sideways inch of it is
		// the wind.
		let renderer = try #require(EffectRenderer(
			Effect(style: .rain, density: 0.3, speed: 1, seed: 8),
			keys: [Overlay.Key(t: 1, [.wind: 0]),
			       Overlay.Key(t: 3, [.wind: 3], ease: .linear)],
			size: size))
		func across(at time: Double) -> [Double] {
			_ = renderer.image(at: time)
			return stride(from: 0, to: renderer.positions.count, by: 3).map { renderer.positions[$0] }
		}
		let frame = 1.0 / 50
		func sideways(from time: Double) -> Double {
			let before = across(at: time), after = across(at: time + frame)
			let moved = zip(before, after).map { $1 - $0 }.filter { abs($0) < 4 }.sorted()
			return moved[moved.count / 2]
		}
		// Nothing before the key, and nothing suddenly at it.
		#expect(abs(sideways(from: 1 - frame)) < 1e-4)
		#expect(abs(sideways(from: 1)) < 0.01, "the wind arrived as a jump: \(sideways(from: 1))")
		// Then it builds, and never in one leap.
		var last = abs(sideways(from: 1))
		for moment in stride(from: 1.0, through: 3.0, by: frame) {
			let now = abs(sideways(from: moment))
			#expect(now < last + 0.02, "the wind jumped at \(moment): \(last) then \(now)")
			last = now
		}
		#expect(last > 0.05, "the wind never blew: \(last)")
		// Which is about what the arithmetic says: a drop falling six to eleven
		// units a second, leaning by three quarters of a unit sideways for every
		// unit down, covers a tenth of a unit or so in a fiftieth of a second.
		#expect(last < 0.3, "the wind blew far too hard: \(last)")
	}
}
