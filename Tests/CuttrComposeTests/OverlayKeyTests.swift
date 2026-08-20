import CoreImage
import CuttrKit
import Foundation
import Testing
@testable import CuttrCompose

/// An overlay's parameters, moving — the arithmetic of it.
///
/// The vocabulary is the scene's, so the first thing measured is that it means
/// the same thing: a key states what it changes and inherits the rest, before
/// the first key it is what the overlay declares, and the easing belongs to the
/// key it arrives at.
@Suite struct OverlayKeyTests {

	private func aberration(_ keys: [Overlay.Key], amount: Double = 0.2) -> Overlay {
		Overlay(kind: .aberration(Aberration(amount: amount)),
		        span: .times(from: 0, to: 3), keys: keys)
	}

	/// The example from the top of `OverlayKeys.swift`, measured.
	@Test func aParameterGoesWhereItsKeysSayItGoes() {
		let overlay = aberration([
			Overlay.Key(t: 0),
			Overlay.Key(t: 1.5, [.amount: 1.2], ease: .out),
			Overlay.Key(t: 3.0, [.amount: 0.1], ease: .in),
		])
		// The first key states nothing, so it is what the overlay declares.
		#expect(abs(overlay.value(.amount, at: 0) - 0.2) < 1e-9)
		#expect(abs(overlay.value(.amount, at: 1.5) - 1.2) < 1e-9)
		#expect(abs(overlay.value(.amount, at: 3.0) - 0.1) < 1e-9)
		// Held before the first key and after the last, as a scene's part is.
		#expect(overlay.value(.amount, at: -1) == overlay.value(.amount, at: 0))
		#expect(overlay.value(.amount, at: 99) == overlay.value(.amount, at: 3))
		// Rising all the way to the top, then falling all the way back.
		var last = overlay.value(.amount, at: 0)
		for step in stride(from: 0.05, through: 1.5, by: 0.05) {
			let now = overlay.value(.amount, at: step)
			#expect(now > last, "it stopped rising at \(step)")
			last = now
		}
		for step in stride(from: 1.55, through: 3.0, by: 0.05) {
			let now = overlay.value(.amount, at: step)
			#expect(now < last, "it stopped falling at \(step)")
			last = now
		}
	}

	/// A key that says nothing about a parameter is a key at which it is still
	/// what it was — so the ramp to the next one starts *there*, not before it.
	///
	/// Exactly `Scene.filled`'s rule, and it has to be: two spellings of the
	/// same vocabulary that disagree about this would be the worst of both.
	@Test func aKeyThatIsSilentHoldsTheValueAcrossItself() {
		let overlay = aberration([
			Overlay.Key(t: 0),
			Overlay.Key(t: 1, ease: .linear),
			Overlay.Key(t: 2, [.amount: 1], ease: .linear),
		])
		#expect(abs(overlay.value(.amount, at: 0.5) - 0.2) < 1e-9, "it ramped over a silent key")
		#expect(abs(overlay.value(.amount, at: 1) - 0.2) < 1e-9)
		#expect(abs(overlay.value(.amount, at: 1.5) - 0.6) < 1e-9)
	}

	/// A parameter no key mentions is left exactly as it was declared — the
	/// same bits, not a number that has been through the arithmetic.
	@Test func whatNothingAnimatesIsUntouched() {
		let overlay = Overlay(kind: .film(Film(strength: 0.7, grain: 0.4, vignette: 0.35)),
		                      span: .times(from: 0, to: 2),
		                      keys: [Overlay.Key(t: 0), Overlay.Key(t: 2, [.grain: 1])])
		guard case .film(let film) = overlay.kind(at: 1) else { return #expect(Bool(false)) }
		#expect(film.strength == 0.7)
		#expect(film.vignette == 0.35)
		#expect(film.ratio.written == "16:9", "the shape was rewritten by an unrelated key")
		#expect(film.grain > 0.4 && film.grain < 1)
	}

	// MARK: - The integrals

	/// The area under a parameter, in closed form, against the area worked out
	/// the slow way.
	///
	/// The closed form is what a particle effect's clock is made of, so it has
	/// to be right for every easing this format has — including `inOut`, which
	/// is two polynomials joined in the middle and the one an integral is most
	/// likely to be got wrong for.
	@Test func theAreaUnderAParameterIsWhatSummingItGives() {
		for ease in Scene.Ease.allCases {
			let track = Track([
				Overlay.Key(t: 0.5, [.speed: 1], ease: ease),
				Overlay.Key(t: 2.0, [.speed: 4], ease: ease),
				Overlay.Key(t: 3.0, [.speed: 0.5], ease: ease),
			], .speed, declared: 2)
			for moment in stride(from: 0.0, through: 4.0, by: 0.25) {
				let closed = track.integral(to: moment)
				// Ten thousand trapezia, which for a piecewise quadratic is
				// good to about a part in a million.
				let steps = 10_000
				var summed = 0.0
				for step in 0..<steps {
					let a = moment * Double(step) / Double(steps)
					let b = moment * Double(step + 1) / Double(steps)
					summed += (b - a) * (track.value(at: a) + track.value(at: b)) / 2
				}
				#expect(abs(closed - summed) < 1e-4,
				        "\(ease) at \(moment): \(closed) against \(summed)")
			}
		}
	}

	/// The wind's area, which is the area under two curves multiplied.
	///
	/// Three-point Gauss–Legendre is exact for a quartic and the product of two
	/// eased ramps is one, so this is a closed form and not an approximation —
	/// which is what the tolerance here is claiming.
	@Test func theAreaUnderTheWindTimesTheSpeedIsExact() {
		let keys = [
			Overlay.Key(t: 0, [.wind: 0, .speed: 1], ease: .linear),
			Overlay.Key(t: 1.5, [.wind: 3], ease: .inOut),
			Overlay.Key(t: 2.5, [.speed: 4], ease: .out),
			Overlay.Key(t: 4, [.wind: -2, .speed: 0.5], ease: .in),
		]
		let wind = Track(keys, .wind, declared: 0)
		let speed = Track(keys, .speed, declared: 1)
		for moment in stride(from: 0.0, through: 5.0, by: 0.5) {
			let closed = Track.integral(of: wind, times: speed, to: moment)
			let steps = 20_000
			var summed = 0.0
			for step in 0..<steps {
				let a = moment * Double(step) / Double(steps)
				let b = moment * Double(step + 1) / Double(steps)
				summed += (b - a) * (wind.value(at: a) * speed.value(at: a)
					+ wind.value(at: b) * speed.value(at: b)) / 2
			}
			#expect(abs(closed - summed) < 1e-4, "at \(moment): \(closed) against \(summed)")
		}
	}

	/// The clock read backwards: the moment at which the area was this much.
	///
	/// Asked once per piece per frame, to find out when a piece was let go, so
	/// getting it wrong shows up as a shower that dries out at the wrong time.
	@Test func theClockRunsBothWays() {
		let motion = EffectMotion(Effect(style: .rain, speed: 1), keys: [
			Overlay.Key(t: 0),
			Overlay.Key(t: 2, [.speed: 5], ease: .linear),
			Overlay.Key(t: 4, [.speed: 0.2], ease: .inOut),
		])
		for moment in stride(from: 0.0, through: 8.0, by: 0.13) {
			// The clock is handed to the scene graph as a `Float`, so the round
			// trip is only as exact as that — which is what the tolerance says.
			let there = Double(motion.clock(at: moment))
			#expect(abs(motion.time(atClock: there) - moment) < 1e-5,
			        "\(moment) came back as \(motion.time(atClock: there))")
		}
	}

	/// With nothing animated the clock is the multiplication it always was, to
	/// the bit.
	///
	/// Not a nicety. Several hundred lit slips of card overlap in a depth
	/// buffer, and the last bit of a position decides which of two of them wins
	/// a pixel: doing this multiplication in `Double` and converting once,
	/// rather than converting each and multiplying, moved the rendered file of
	/// `examples/effects/looks` by three levels in the mean across the frame.
	/// A project with no keys in it must render what it always rendered, and
	/// this is the equality that says so.
	@Test func anEffectWithNoKeysKeepsTheClockItHad() {
		let motion = EffectMotion(Effect(style: .confetti, speed: 2.5), keys: [])
		for moment in stride(from: 0.0, through: 6.0, by: 0.25) {
			#expect(motion.clock(at: moment) == Float(moment) * Float(2.5))
		}
		#expect(motion.showing(at: 3) == 1)
		#expect(motion.windy == false)
		// And the wind is worked out per piece the way it always was, because a
		// lean that never changes comes straight out of the integral.
		#expect(motion.windMoves == false)
		#expect(EffectMotion(Effect(style: .rain, wind: 2), keys: []).windMoves == false)
		#expect(EffectMotion(Effect(style: .rain), keys: [
			Overlay.Key(t: 0), Overlay.Key(t: 1, [.wind: 2]),
		]).windMoves)
	}

	/// A density that moves is a fraction of the cloud allowed to fall, against
	/// the most it is ever asked for — because pieces cannot be made mid-render.
	@Test func densityIsAFractionOfTheFullestCloud() {
		let effect = Effect(style: .rain, density: 1)
		let motion = EffectMotion(effect, keys: [
			Overlay.Key(t: 0),
			Overlay.Key(t: 4, [.density: 0.25], ease: .linear),
		])
		#expect(motion.peakDensity == 1)
		#expect(abs(motion.showing(at: 0) - 1) < 1e-9)
		#expect(abs(motion.showing(at: 4) - 0.25) < 1e-9)
		// Rising as well as falling: the cloud is built for the peak, so a
		// density that ends higher than it starts still has pieces to let go.
		let rising = EffectMotion(effect, keys: [
			Overlay.Key(t: 0), Overlay.Key(t: 4, [.density: 3], ease: .linear),
		])
		#expect(rising.peakDensity == 3)
		#expect(abs(rising.showing(at: 0) - 1.0 / 3) < 1e-9)
		#expect(abs(rising.showing(at: 4) - 1) < 1e-9)
		#expect(effect.count(for: 3) > effect.count)
	}
}

// MARK: - The file

/// What the file says, and that it keeps saying it.
@Suite struct OverlayKeyFileTests {

	private func project(_ overlays: String) throws -> Project {
		try ProjectReader.read("""
		cuttr-project: 1

		timeline:
		  - clip: intro

		overlays:
		\(overlays)
		""")
	}

	@Test func theKeysComeBackAsTheyWereWritten() throws {
		let read = try project("""
		  - aberration: radial
		    amount:  0.2
		    keys:
		      - {t: 0}
		      - {t: 1.5, amount: 1.2, ease: out}
		      - {t: 3, amount: 0.1, ease: in}
		    from:   intro
		    to:     intro
		""")
		let overlay = try #require(read.overlays.first)
		#expect(overlay.keys.count == 3)
		#expect(overlay.keys[1][.amount] == 1.2)
		#expect(overlay.keys[1].ease == .out)
		#expect(overlay.keys[0].values.isEmpty)
	}

	/// Written back where a reader's eye is already looking — under the knobs
	/// the keys move — and byte for byte the same the second time.
	@Test func writingIsStableForTheSameProject() throws {
		let read = try project("""
		  - tape:    worn
		    keys:
		      - {t: 0, dropouts: 0}
		      - {t: 2, dropouts: 0.9, chroma: 1, ease: linear}
		    from:   intro
		    to:     intro
		""")
		let once = ProjectWriter.write(read)
		let twice = ProjectWriter.write(try ProjectReader.read(once))
		#expect(once == twice, "\(once)")
		#expect(once.contains("      - {t: 0, dropouts: 0}"), "\(once)")
		#expect(once.contains("      - {t: 2, chroma: 1, dropouts: 0.9, ease: linear}"), "\(once)")
		// Under the knobs, above the range.
		let keysAt = try #require(once.range(of: "    keys:"))
		let fromAt = try #require(once.range(of: "    from:"))
		#expect(keysAt.lowerBound < fromAt.lowerBound)
	}

	/// An overlay with no keys writes exactly what it wrote before there were
	/// any. This is the whole of the promise to every project already on disk.
	@Test func anOverlayWithNoKeysWritesWhatItAlwaysWrote() throws {
		let read = try project("""
		  - effect:  confetti
		    density: 1.4
		    from:   intro
		    to:     intro
		""")
		let written = ProjectWriter.write(read)
		#expect(!written.contains("keys:"), "\(written)")
		#expect(written.contains("  - effect:  confetti\n    density: 1.4\n"), "\(written)")
	}

	// MARK: - What it refuses

	private func refuses(_ overlays: String, saying fragment: String) {
		do {
			_ = try project(overlays)
			Issue.record("read keys it should have refused: \(overlays)")
		} catch let error as ProjectError {
			let said = error.errorDescription ?? ""
			#expect(said.contains(fragment), "said \(said)")
		} catch {
			Issue.record("wrong error: \(error)")
		}
	}

	/// The seed is what the cloud is *made of*. A seed that changed half way
	/// through would be two clouds cut together, so it is refused by name
	/// rather than quietly ignored.
	@Test func aSeedCannotBeAnimated() {
		refuses("""
		  - effect:  confetti
		    keys:
		      - {t: 0, seed: 1}
		      - {t: 2, seed: 8}
		    from:   intro
		    to:     intro
		""", saying: "`seed` cannot be animated")
	}

	/// A stock, a condition and a finish are names. There is nothing half way
	/// between `warm` and `noir`.
	@Test func aNameCannotBeAnimated() {
		refuses("""
		  - film:    warm
		    keys:
		      - {t: 0, tint: 0}
		      - {t: 2, tint: 1}
		    from:   intro
		    to:     intro
		""", saying: "it is a name rather than a number")
	}

	/// A knob that belongs to another kind is named, along with what this one
	/// does have — because the commonest way to get this wrong is to reach for
	/// the right idea under the wrong overlay.
	@Test func aKnobFromAnotherKindIsRefusedByName() {
		refuses("""
		  - tape:    worn
		    keys:
		      - {t: 0, amount: 0.2}
		    from:   intro
		    to:     intro
		""", saying: "the tape has no such parameter. What can move here is "
			+ "jitter, band, chroma, scanlines, dropouts")
	}

	/// A caption has nothing to animate that `in:` and `out:` do not already
	/// say, and a scene's parts carry keys of their own.
	@Test func aCaptionAndASceneHaveNoKeysOfThisKind() {
		refuses("""
		  - text:   "Hello"
		    keys:
		      - {t: 0, opacity: 0}
		    from:   intro
		    to:     intro
		""", saying: "a caption has nothing that moves")
		refuses("""
		  - scene:  opening
		    keys:
		      - {t: 0, opacity: 0}
		    from:   intro
		    to:     intro
		""", saying: "a scene has nothing that moves")
	}

	@Test func anEasingItCannotReadIsRefused() {
		refuses("""
		  - aberration: radial
		    keys:
		      - {t: 0, amount: 0.2, ease: springy}
		    from:   intro
		    to:     intro
		""", saying: "`ease: springy`")
	}

	/// The shape a film overlay closes to is the one parameter that is not
	/// written as a number on the overlay itself. A key states the quantity
	/// that moves, and `w:h` is still read.
	@Test func theShapeIsReadBothWaysAndWrittenAsTheNumber() throws {
		let read = try project("""
		  - film:    warm
		    ratio:   "4:3"
		    keys:
		      - {t: 0}
		      - {t: 2, ratio: 2.39:1}
		    from:   intro
		    to:     intro
		""")
		let overlay = try #require(read.overlays.first)
		#expect(abs((overlay.keys[1][.ratio] ?? 0) - 2.39) < 1e-9)
		let written = ProjectWriter.write(read)
		#expect(written.contains("      - {t: 2, ratio: 2.39}"), "\(written)")
		// And the overlay's own `ratio:` keeps the pair somebody wrote.
		#expect(written.contains("    ratio:   \"4:3\""), "\(written)")
		#expect(ProjectWriter.write(try ProjectReader.read(written)) == written)
	}

	/// A shape survives being written down and read back.
	///
	/// It did not, and finding out was an accident of animating it: YAML 1.1
	/// reads digits separated by colons as a base-60 number, so `4:3` is four
	/// minutes and three seconds — 243 — and came back as `243:1`. Three of the
	/// six shapes this program offers went out through the file and returned as
	/// something else entirely. The fix is in ``TakeWriter/scalar(_:)``, which
	/// is where every other word that YAML would read as a number is quoted.
	@Test func everyShapeSurvivesTheFile() throws {
		for shape in Film.Ratio.offered {
			let out = ProjectWriter.write(Project(
				timeline: [TimelineEntry(clip: ClipReference("intro"))],
				overlays: [Overlay(kind: .film(Film(ratio: shape)),
				                   span: .times(from: 0, to: 4))]))
			let back = try ProjectReader.read(out)
			guard case .film(let film) = try #require(back.overlays.first).kind else {
				Issue.record("not a film overlay")
				continue
			}
			#expect(film.ratio == shape, "\(shape.written) came back as \(film.ratio.written)")
		}
	}
}
