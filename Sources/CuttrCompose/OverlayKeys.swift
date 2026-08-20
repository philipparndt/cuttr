import CoreGraphics
import Foundation

// An overlay's parameters, moving.
//
// The same keyframe vocabulary a scene is built on, and deliberately not a
// second spelling of it: `t` in seconds from the start of the overlay's own
// appearance, every field optional, a gap inherited from the key before, and an
// `ease` per key saying how it got there. Somebody who has written a scene can
// write one of these without being told anything new.
//
// ```yaml
//   - aberration: radial
//     amount:  0.2
//     keys:
//       - {t: 0}
//       - {t: 1.5, amount: 1.2, ease: out}
//       - {t: 3.0, amount: 0.1, ease: in}
// ```
//
// What a key inherits before the first key that states anything is the value
// written on the overlay itself — `amount: 0.2` above — so adding `keys:` to an
// overlay never silently changes what it was.
//
// **This is not the `in:`/`out:` envelope.** That scales the whole effect on
// its way in and out and knows nothing about which knob is which; these move
// the knobs. The two compose: an aberration whose `amount` grows from a fifth
// to one still fades up over its first half second if that is what `in:` says.

public extension Overlay {

	/// What the overlay's parameters are at one moment.
	///
	/// A dictionary rather than fifteen optionals, because the fifteen belong to
	/// four different kinds and no key can ever state more than one kind's
	/// worth. Which names a kind will answer to is ``Kind/animatable``, and the
	/// reader refuses anything else by name rather than dropping it.
	struct Key: Sendable, Equatable {
		/// Seconds from the start of this appearance, as a scene's is from the
		/// start of the scene. An overlay that is on three times runs its keys
		/// three times, from nought each time.
		public var t: Double
		/// Only what this key changes.
		public var values: [Parameter: Double]
		/// How it gets here from the key before.
		public var ease: Scene.Ease

		public init(t: Double, _ values: [Parameter: Double] = [:], ease: Scene.Ease = .inOut) {
			self.t = t
			self.values = values
			self.ease = ease
		}

		public subscript(_ parameter: Parameter) -> Double? {
			get { values[parameter] }
			set { values[parameter] = newValue }
		}
	}

	/// A knob a key can turn.
	///
	/// The order here is the order they are written in a key and listed in the
	/// panel, so a file that comes out of this program twice comes out the same
	/// both times.
	enum Parameter: String, Sendable, CaseIterable {
		// Film mode.
		case ratio, strength, grain, vignette
		// The aberration.
		case amount, angle
		// The tape.
		case jitter, band, chroma, scanlines, dropouts
		// The particle effects.
		case density, speed, size, wind
	}
}

public extension Overlay.Kind {

	/// The parameters of this kind that a key may state, and nothing else.
	///
	/// **What is missing from each list, and why.** This is the judgement the
	/// whole feature turns on, so it is written where somebody meets it.
	///
	/// - The stock (`film:`), the aberration's kind, the tape's condition, an
	///   effect's style, finish and palette are *names*, not numbers. There is
	///   no half way between `warm` and `noir`, and a format that pretended
	///   otherwise would be lying about what it renders. Change them with a
	///   second overlay and a dissolve, which is what a dissolve is for.
	/// - `seed`, on the tape and on an effect, is what the thing is made of. The
	///   same number gives the same wobble and the same cloud on every machine,
	///   every render; a seed that changed half way through would not be one
	///   cloud moving but two clouds cut together. Refused by name.
	/// - `size`, on an effect, **is** here, and it is worth saying why it is not
	///   in the paragraph above. A piece's geometry is built once, but its
	///   scale is set on the node every single frame from `effect.size` — so a
	///   cloud whose pieces grow is a cloud whose pieces grow, with nothing
	///   invented and nothing jumping.
	/// - `density` is here too, and it does not mean what it means on the
	///   overlay: see ``EffectMotion/showing(at:)``.
	var animatable: [Overlay.Parameter] {
		switch self {
		case .film: return [.ratio, .strength, .grain, .vignette]
		case .aberration: return [.amount, .angle]
		case .tape: return [.jitter, .band, .chroma, .scanlines, .dropouts]
		case .effect: return [.density, .speed, .size, .wind]
		// A caption, a spinner and a scene are layers rather than pixels, and
		// two of the three carry their own timing already — a spinner's words
		// have durations, and a scene's parts have keys. There is nothing here
		// for a key to move that is not already said better somewhere else.
		case .text, .spinner, .scene: return []
		}
	}

	/// The knob somebody most likely means when they first ask for something to
	/// move. What a new key list states, so that the panel opens with one number
	/// to type rather than a list of empty rows.
	var principal: Overlay.Parameter? {
		switch self {
		case .film: return .strength
		case .aberration: return .amount
		case .tape: return .jitter
		case .effect: return .density
		case .text, .spinner, .scene: return nil
		}
	}

	/// What to call one in an error message.
	///
	/// ``Overlay/described`` is this with the caption's own words in it; a
	/// refusal at read time has no appearance in hand and only needs the kind.
	var named: String {
		switch self {
		case .text: return "a caption"
		case .spinner: return "a spinner"
		case .scene: return "a scene"
		case .effect(let effect): return "the \(effect.style.rawValue)"
		case .film: return "film mode"
		case .aberration: return "the aberration"
		case .tape: return "the tape"
		}
	}

	/// What a parameter is at the moment nobody has said otherwise.
	func declared(_ parameter: Overlay.Parameter) -> Double {
		switch self {
		case .film(let film):
			switch parameter {
			case .ratio: return film.ratio.value
			case .strength: return film.strength
			case .grain: return film.grain
			case .vignette: return film.vignette
			default: return 0
			}
		case .aberration(let aberration):
			switch parameter {
			case .amount: return aberration.amount
			case .angle: return aberration.angle
			default: return 0
			}
		case .tape(let tape):
			switch parameter {
			case .jitter: return tape.jitter
			case .band: return tape.band
			case .chroma: return tape.chroma
			case .scanlines: return tape.scanlines
			case .dropouts: return tape.dropouts
			default: return 0
			}
		case .effect(let effect):
			switch parameter {
			case .density: return effect.density
			case .speed: return effect.speed
			case .size: return effect.size
			case .wind: return effect.wind
			default: return 0
			}
		case .text, .spinner, .scene: return 0
		}
	}
}

public extension Overlay {

	/// Whether any key states this parameter. A parameter nothing states is
	/// left exactly as the overlay declares it — not recomputed, not rounded.
	func animates(_ parameter: Parameter) -> Bool {
		keys.contains { $0.values[parameter] != nil }
	}

	/// Whether anything at all moves.
	var isAnimated: Bool { !keys.isEmpty }

	/// One parameter's value `t` seconds into an appearance.
	func value(_ parameter: Parameter, at t: Double) -> Double {
		track(parameter).value(at: t)
	}

	/// The largest a parameter ever gets, for the things that have to be built
	/// before the render starts and cannot be rebuilt half way through.
	func peak(_ parameter: Parameter) -> Double { track(parameter).peak }

	/// What each key's value for a parameter actually is once the gaps are
	/// filled in from the key before — one number per key, in the order the
	/// keys are held.
	///
	/// For the panel, which shows an inherited number dim and in brackets
	/// rather than as something somebody typed. The scene inspector shows the
	/// same distinction the same way, and it is the whole reason a key list is
	/// readable: at a glance, what this key *says* against what it merely is.
	func inherited(_ parameter: Parameter) -> [Double] {
		var last = kind.declared(parameter)
		return keys.map { key in
			last = key[parameter] ?? last
			return last
		}
	}

	internal func track(_ parameter: Parameter, clampedTo range: ClosedRange<Double>? = nil) -> Track {
		Track(keys, parameter, declared: kind.declared(parameter), clampedTo: range)
	}

	/// The overlay's kind with every animated parameter moved to where it is
	/// `t` seconds in.
	///
	/// The one call the frame pass makes, so that ``Filming``, ``Aberrating``
	/// and ``Taping`` need to know nothing about keys at all: they are handed a
	/// `Film`, an `Aberration` or a `Tape` as it stands at this moment and go on
	/// doing exactly what they did. Every one of those three works its numbers
	/// out per frame already, which is the whole reason they are the easy case.
	///
	/// The particle effects are not here. A cloud is built once and cannot be
	/// re-made per frame, so what moves it is ``EffectMotion`` inside the
	/// renderer, where the integrating has to happen.
	func kind(at t: Double) -> Kind {
		guard !keys.isEmpty else { return kind }
		func now(_ parameter: Parameter) -> Double? {
			animates(parameter) ? value(parameter, at: t) : nil
		}
		switch kind {
		case .film(var film):
			// Written as `n:1` because that is the number a key states — the
			// shape as one quantity, which is the thing that can move. The pair
			// somebody wrote on the overlay itself is left alone.
			if let ratio = now(.ratio) { film.ratio = Film.Ratio(max(0.01, ratio), 1) }
			if let strength = now(.strength) { film.strength = strength }
			if let grain = now(.grain) { film.grain = grain }
			if let vignette = now(.vignette) { film.vignette = vignette }
			return .film(film)
		case .aberration(var aberration):
			if let amount = now(.amount) { aberration.amount = amount }
			if let angle = now(.angle) { aberration.angle = angle }
			return .aberration(aberration)
		case .tape(var tape):
			if let jitter = now(.jitter) { tape.jitter = jitter }
			if let band = now(.band) { tape.band = band }
			if let chroma = now(.chroma) { tape.chroma = chroma }
			if let scanlines = now(.scanlines) { tape.scanlines = scanlines }
			if let dropouts = now(.dropouts) { tape.dropouts = dropouts }
			return .tape(tape)
		case .effect, .text, .spinner, .scene:
			return kind
		}
	}
}

// MARK: - One parameter over time

/// One parameter's value at every moment, and the area under it.
///
/// Built from the keys once and asked many times, because the effect renderer
/// asks for the same two integrals for every piece of a cloud on every frame.
struct Track: Sendable, Equatable {

	struct Point: Sendable, Equatable {
		var t: Double
		var v: Double
		var ease: Scene.Ease
	}

	/// Empty when nothing states this parameter, which is the common case and
	/// the fast path: the value is ``declared`` and the area under it is a
	/// rectangle.
	private(set) var points: [Point] = []
	private(set) var declared: Double

	/// Every key contributes a point, whether or not it states this parameter,
	/// and one that does not gets the value from the key before it — exactly
	/// what ``Scene/filled(_:)`` does and for the same reason. It matters: a key
	/// that says nothing about `amount` is a key at which `amount` is still what
	/// it was, so the ramp to the *next* key starts there rather than reaching
	/// back over it.
	init(_ keys: [Overlay.Key], _ parameter: Overlay.Parameter,
	     declared: Double, clampedTo range: ClosedRange<Double>? = nil) {
		func clamp(_ value: Double) -> Double {
			guard let range else { return value }
			return min(max(value, range.lowerBound), range.upperBound)
		}
		self.declared = clamp(declared)
		guard keys.contains(where: { $0.values[parameter] != nil }) else { return }
		var last = self.declared
		for key in keys.sorted(by: { $0.t < $1.t }) {
			// Clamped here rather than at every evaluation. Both easings this
			// format has stay between nought and one, so a ramp between two
			// clamped values is itself within the range — which is what makes
			// the integral below exact rather than an integral of a curve that
			// has been bent somewhere else.
			last = key.values[parameter].map(clamp) ?? last
			points.append(Point(t: key.t, v: last, ease: key.ease))
		}
	}

	var isFlat: Bool { points.isEmpty }

	/// The largest it ever is, counting the value it holds before the first key
	/// and after the last.
	var peak: Double { max(declared, points.map(\.v).max() ?? declared) }

	func value(at time: Double) -> Double {
		guard let first = points.first, let last = points.last else { return declared }
		if time <= first.t { return first.v }
		if time >= last.t { return last.v }
		guard let next = points.firstIndex(where: { $0.t > time }), next > 0 else { return last.v }
		let before = points[next - 1], after = points[next]
		let span = max(after.t - before.t, 0.0001)
		let fraction = Scene.eased(after.ease, (time - before.t) / span)
		return before.v + (after.v - before.v) * fraction
	}

	/// The area under the curve from nought to `time`.
	///
	/// Closed form, not a sum of samples. Over one interval the value is
	/// `a + (b - a)·ease(u)`, so the area is `(t₁ - t₀)·(a·v + (b - a)·E(v))`
	/// where `E` is the area under the easing itself — and every easing this
	/// format has is a polynomial of degree at most three, so `E` is written
	/// out below rather than approximated.
	///
	/// This is the thing a particle effect needs and the reason `speed` cannot
	/// simply be multiplied in: a piece's height is the integral of its speed,
	/// and `speed(t)·t` is not that integral for any speed that changes. It
	/// teleports every piece in the cloud the moment the speed does.
	func integral(to time: Double) -> Double {
		guard time > 0 else { return 0 }
		guard let first = points.first, let last = points.last else { return declared * time }
		if time <= first.t { return first.v * time }
		var area = first.v * first.t
		for index in 1..<points.count {
			let before = points[index - 1], after = points[index]
			let span = after.t - before.t
			guard span > 0 else { continue }
			if time >= after.t {
				area += span * (before.v + (after.v - before.v) * Self.easedArea(after.ease, 1))
			} else {
				let fraction = (time - before.t) / span
				return area + span * (before.v * fraction
					+ (after.v - before.v) * Self.easedArea(after.ease, fraction))
			}
		}
		return area + last.v * (time - last.t)
	}

	/// When the area under the curve first reaches `area` — the clock read
	/// backwards.
	///
	/// Only asked of a track that is everywhere positive (the speed one, which
	/// is clamped away from nought), so the area is strictly increasing and
	/// there is exactly one answer. The straight stretches at either end are
	/// solved outright; inside an interval it is bisected, which is a dozen
	/// lines less than inverting a cubic and cannot pick the wrong root.
	func time(reaching area: Double) -> Double {
		guard area > 0 else { return 0 }
		guard let first = points.first, let last = points.last else {
			return declared > 0 ? area / declared : 0
		}
		let head = first.v * first.t
		if area <= head { return first.v > 0 ? area / first.v : first.t }
		let whole = integral(to: last.t)
		if area >= whole { return last.v > 0 ? last.t + (area - whole) / last.v : last.t }
		var low = first.t, high = last.t
		for _ in 0..<48 {
			let middle = (low + high) / 2
			if integral(to: middle) < area { low = middle } else { high = middle }
		}
		return (low + high) / 2
	}

	/// The area under an easing curve from nought to `v`.
	///
	/// `linear` is `u`, `in` is `u²`, `out` is `1 - (1 - u)²`, and `inOut` is
	/// those two halves joined at the middle — so these four are the integrals
	/// of exactly what ``Scene/eased(_:_:)`` computes, and nothing else may be
	/// added to that enum without adding its area here.
	static func easedArea(_ ease: Scene.Ease, _ v: Double) -> Double {
		let v = min(max(v, 0), 1)
		switch ease {
		case .linear: return v * v / 2
		case .in: return v * v * v / 3
		case .out: return v - (1 - pow(1 - v, 3)) / 3
		case .inOut:
			if v < 0.5 { return 2 * v * v * v / 3 }
			return (v - 0.5) + 2 * pow(1 - v, 3) / 3
		}
	}

	/// The area under the product of two tracks.
	///
	/// Wanted for exactly one thing: how far the wind has carried a piece.
	/// Sideways speed is the fall rate times the lean times the clock rate, so
	/// the distance is the integral of `lean × speed` — not `lean(t) × ∫speed`,
	/// which jumps sideways the instant the lean changes.
	///
	/// Each track is a polynomial of degree at most two in its own interval —
	/// `inOut` in two halves, so the halves are boundaries here as well — which
	/// makes the product a quartic. Three-point Gauss–Legendre integrates a
	/// quartic exactly, so what follows is a closed form evaluated in three
	/// places and not a quadrature that has an error to argue about.
	static func integral(of first: Track, times second: Track, to time: Double) -> Double {
		guard time > 0 else { return 0 }
		if first.isFlat, second.isFlat { return first.declared * second.declared * time }
		var edges: Set<Double> = [0, time]
		for track in [first, second] {
			for (index, point) in track.points.enumerated() {
				if point.t > 0, point.t < time { edges.insert(point.t) }
				// The middle of an interval is a boundary too, and separately:
				// `inOut` is two polynomials joined there, and the interval a
				// moment falls *inside* is the one whose far key is past it.
				// Only splitting the intervals that end before `time` was a
				// hundred and fifty parts per million out on the first thing
				// measured against it.
				guard index > 0 else { continue }
				let middle = (track.points[index - 1].t + point.t) / 2
				if middle > 0, middle < time { edges.insert(middle) }
			}
		}
		let bounds = edges.sorted()
		// √(3/5), and the weights that go with it.
		let node = (0.6 as Double).squareRoot()
		var area = 0.0
		for index in 1..<bounds.count {
			let low = bounds[index - 1], high = bounds[index]
			let half = (high - low) / 2, middle = (high + low) / 2
			func product(_ at: Double) -> Double {
				first.value(at: at) * second.value(at: at)
			}
			area += half * (5.0 / 9 * product(middle - half * node)
				+ 8.0 / 9 * product(middle)
				+ 5.0 / 9 * product(middle + half * node))
		}
		return area
	}
}

// MARK: - A cloud, moving

/// How a particle effect's four animated knobs reach the cloud.
///
/// The interesting case, and the reason this is not simply "interpolate, then
/// apply". A cloud is built once, with a fixed number of pieces, and every
/// piece's position at a moment is worked out from the elapsed time and its own
/// fall rate. So:
///
/// - **`speed` and `wind` are integrated.** A piece's height is the area under
///   its speed, not the speed at this instant multiplied by the time so far.
///   Multiplying is what a first attempt does and it teleports the whole cloud
///   the moment the number changes — measured: rain going from 1 to 3 over two
///   seconds jumped about a third of the frame at the first key. ``clock(at:)``
///   is that area and stands in for the scaled time the renderer used to use;
///   ``drift(at:)`` is the same for the wind, which has to be integrated
///   *against* the speed because a piece falling twice as fast covers twice the
///   ground sideways while it does it.
/// - **`density` cannot change the number of pieces.** Making a new piece
///   mid-render would mean a new node, a new material and a different cloud from
///   the one the seed describes. What the renderer can already do is *hide* one
///   — that is how `out: fall` empties the frame — so an animated density is
///   read as a fraction of the cloud allowed to fall. The cloud is built for the
///   most it is ever asked for, and a piece is let go, or not, at the moment it
///   would have come over the top of the frame: nothing ever pops out of
///   existence in shot.
/// - **`size` is a scale on the node, set every frame.** No integrating, no
///   rebuilding. It simply moves.
/// - **`seed` is refused** by the reader, and this is where that decision comes
///   from: it is not a quantity the cloud has, it is the cloud.
struct EffectMotion: Sendable {

	/// Clamped exactly where the renderer used to clamp them, but at the key
	/// rather than at the instant — see ``Track/init(_:_:declared:clampedTo:)``.
	private let speed: Track
	private let wind: Track
	private let density: Track
	private let scale: Track
	/// Whether the wind ever blows at all — the question the sideways wrap
	/// asks, because a cloud with no wind on it must not wrap and never did.
	///
	/// Its neighbour ``windMoves`` is a different question: whether the wind
	/// *changes*, which is what decides whether it has to be integrated.
	let windBlows: Bool

	/// How much of the cloud is in the air at the fullest. The number of pieces
	/// is built from this, so that density can rise as well as fall.
	var peakDensity: Double { density.peak }

	init(_ effect: Effect, keys: [Overlay.Key]) {
		let kind = Overlay.Kind.effect(effect)
		func track(_ parameter: Overlay.Parameter,
		           _ range: ClosedRange<Double>? = nil) -> Track {
			Track(keys, parameter, declared: kind.declared(parameter), clampedTo: range)
		}
		speed = track(.speed, 0.05...1000)
		wind = track(.wind, -4...4)
		density = track(.density, 0.05...1000)
		scale = track(.size, 0.05...1000)
		windBlows = wind.declared != 0 || wind.points.contains { $0.v != 0 }
	}

	/// The effect's own clock: how far the cloud has fallen, in the units the
	/// renderer thinks in.
	///
	/// A speed that never changes has a closed form for its own integral —
	/// `time × speed` — and this hands back exactly that, in the two `Float`
	/// conversions the renderer has always made, rather than the same quantity
	/// rounded in `Double` first.
	///
	/// That is not fussiness. Several hundred lit slips of card overlap in a
	/// depth buffer, and the last bit of a position decides which of two of
	/// them wins a pixel. Measured on the rendered file, against the same build
	/// of everything else: doing the multiplication in `Double` and converting
	/// once moved `examples/effects/looks` by three levels in the mean across
	/// the frame, with a tenth of the pixels more than eight levels out. A
	/// project with no keys in it must render what it always rendered, and this
	/// is the whole of what that costs.
	func clock(at time: Double) -> Float {
		guard !speed.isFlat else { return Float(max(0, time)) * Float(speed.declared) }
		return Float(speed.integral(to: max(0, time)))
	}

	/// The moment the clock read this. Used to ask when a piece was let go,
	/// which is a question about the programme rather than about the cloud.
	func time(atClock clock: Double) -> Double { speed.time(reaching: clock) }

	/// Whether the wind has to be integrated at all — as against ``windBlows``,
	/// which is whether there is any wind to feel.
	///
	/// It does not when the wind never changes: a constant lean comes straight
	/// out of the integral, so the lean times the clock *is* the distance, and
	/// the renderer works it out per piece the way it always did. That holds
	/// even when the speed is animated, because the clock is already the
	/// integral of the speed. Only a wind that itself moves needs ``drift``.
	var windMoves: Bool { !wind.isFlat }

	/// How far sideways the wind has carried a piece that falls at one unit of
	/// the clock a second — multiplied by the piece's own fall rate at the call
	/// site, which is where it was before.
	///
	/// A quarter of the wind, because that is what one unit of `wind:` means:
	/// a good breeze, not a gale.
	func drift(at time: Double) -> Float {
		Float(Track.integral(of: wind, times: speed, to: max(0, time)) * 0.25)
	}

	/// The slant of the path right now, which is what a rain streak is turned
	/// to. The instantaneous lean, not the integrated one: a streak points along
	/// where it is going, not along where it has been.
	func lean(at time: Double) -> Double { wind.value(at: max(0, time)) * 0.25 }

	func size(at time: Double) -> Double { scale.value(at: max(0, time)) }

	/// How much of the cloud may be in the air at a moment, as a fraction of
	/// the most there ever is.
	///
	/// One when nothing animates the density, so a piece is hidden only by the
	/// fall-out it always was.
	func showing(at time: Double) -> Double {
		guard !density.isFlat, peakDensity > 0 else { return 1 }
		return min(1, max(0, density.value(at: max(0, time)) / peakDensity))
	}
}
