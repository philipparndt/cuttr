import CoreGraphics
import Foundation

/// Something thrown over the whole frame: confetti, snow, a shower of sparks.
///
/// Not a caption and not a spinner. Those two are *placed* — they sit
/// somewhere, they follow a face, they say something. An effect has no
/// position: it is the whole frame for as long as it lasts, and what it is for
/// is the moment rather than the information.
///
/// Rendered as real geometry with real light on it — slips of card that tumble
/// and catch the key light as they turn, rather than flat shapes drifting down.
/// That is the whole difference between an effect somebody enjoys and one that
/// looks like a screensaver from 1998, and it costs a scene graph.
public struct Effect: Sendable, Equatable {

	public enum Style: String, Sendable, CaseIterable {
		/// Slips of card, tumbling and drifting. The party one.
		case confetti
		/// Flakes, slower, smaller, going almost straight down.
		case snow
		/// Bright shards thrown upwards and falling back — a burst rather than
		/// a fall, for the moment something lands.
		case sparkle
		/// Rain: long thin streaks, nearly vertical, going fast.
		///
		/// Geometry rather than a filter, and in here with the rest for that
		/// reason: a streak is a thing at a distance, so the far ones are
		/// smaller, dimmer and slower, and the near ones pass in front of them.
		/// A rain filter over the whole frame has no depth in it and looks like
		/// a scratched print.
		case rain
	}

	public var style: Style
	/// What the pieces are made of, which is most of how expensive they look.
	public var finish: Finish

	public enum Finish: String, Sendable, CaseIterable {
		/// Printed card: the colour it is, lit and shaded, no shine.
		case matte
		/// Foil: a mirror with a colour, so a piece flares white as it turns
		/// through the light and goes dark as it turns away.
		case metallic
		/// Foil cut small, with every piece polished differently, so the
		/// catches are scattered and quick rather than broad — glitter.
		case glitter
	}
	/// How much of it, against the style's own idea of enough. Two is twice as
	/// much card in the air, not bigger pieces.
	public var density: Double
	/// How fast it falls or flies.
	public var speed: Double
	/// How big each piece is, against the style's own idea of the right size.
	public var size: Double
	/// What the pieces are made of. Empty takes the style's own colours.
	public var palette: [RGBA]
	/// How hard it is blowing, and which way: positive to the right.
	///
	/// Only the styles that drift have any use for it — rain leans into it and
	/// travels sideways as it falls, snow is simply carried. Nought is straight
	/// down, and one is a good wind rather than a gale.
	public var wind: Double
	/// The same number gives the same cloud, every render, on every machine.
	///
	/// An effect nobody can reproduce is one nobody can approve: a director who
	/// liked the third take of a shower of confetti has to be able to get that
	/// one back, and "it is random" is not an answer.
	public var seed: Int

	public init(
		style: Style = .confetti,
		finish: Finish = .matte,
		density: Double = 1,
		speed: Double = 1,
		size: Double = 1,
		palette: [RGBA] = [],
		wind: Double = 0,
		seed: Int = 1
	) {
		self.style = style
		self.finish = finish
		self.density = density
		self.speed = speed
		self.size = size
		self.palette = palette
		self.wind = wind
		self.seed = seed
	}

	/// The colours a style falls back to when the file names none.
	public var colours: [RGBA] {
		guard palette.isEmpty else { return palette }
		switch style {
		case .confetti:
			return [RGBA(hex: "#ff375f")!, RGBA(hex: "#ffd60a")!, RGBA(hex: "#30d158")!,
			        RGBA(hex: "#0a84ff")!, RGBA(hex: "#bf5af2")!, RGBA(hex: "#ff9f0a")!]
		case .snow:
			return [RGBA(hex: "#ffffff")!, RGBA(hex: "#eaf4ff")!]
		case .sparkle:
			return [RGBA(hex: "#ffe680")!, RGBA(hex: "#ffffff")!, RGBA(hex: "#ffc74d")!]
		case .rain:
			// Rain is not blue. It is whatever is behind it, slightly brighter
			// along the streak — so the pieces are pale and nearly white, with
			// a hint of the sky in them.
			return [RGBA(hex: "#dfe9f2")!, RGBA(hex: "#c9d8e6")!, RGBA(hex: "#eef4fa")!]
		}
	}

	/// How many pieces are in the air at once.
	public var count: Int { count(for: density) }

	/// The same, for a density other than the declared one.
	///
	/// Wanted because keys can move the density and the cloud cannot be rebuilt
	/// half way through a render: it is built for the most it is ever asked for
	/// and thinned by hiding, which is what ``EffectMotion`` explains at length.
	/// A cloud built for a bigger number keeps the first of its pieces exactly
	/// where they were, because they come off the same seeded sequence in the
	/// same order.
	public func count(for density: Double) -> Int {
		let base: Int
		switch style {
		case .confetti: base = finish == .glitter ? 320 : 160
		case .snow: base = 220
		case .sparkle: base = 120
		// More of them than anything else, and they are the thinnest things
		// here: a dozen streaks is a leak in the roof.
		case .rain: base = 420
		}
		return max(4, min(1200, Int(Double(base) * max(0.05, density))))
	}
}

/// The same numbers every time, from a number somebody chose.
///
/// `SystemRandomNumberGenerator` would make a render that cannot be repeated,
/// and this file is the sort of thing a project is diffed and re-rendered from.
/// Splitmix64: eight lines, and identical on every machine.
struct Seeded: RandomNumberGenerator {
	private var state: UInt64

	init(_ seed: Int) {
		state = UInt64(bitPattern: Int64(seed)) &+ 0x9e37_79b9_7f4a_7c15
	}

	mutating func next() -> UInt64 {
		state &+= 0x9e37_79b9_7f4a_7c15
		var z = state
		z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
		z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
		return z ^ (z >> 31)
	}

	/// A number in a range, which is all any of this needs.
	mutating func value(_ range: ClosedRange<Double>) -> Double {
		let unit = Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
		return range.lowerBound + unit * (range.upperBound - range.lowerBound)
	}
}
