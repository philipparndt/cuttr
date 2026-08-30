import CoreGraphics
import Foundation

public extension Scene {

	/// A line of text that arrives one character at a time.
	///
	/// **Why this is a part and not a rectangle over one.** The way to type a
	/// word before this was to draw the whole line, lay a shape the colour of
	/// the card over it, and step the shape right by one letter at a time. That
	/// asks a project file for two things it cannot be held to. The first is a
	/// colour: the scene is painted into an sRGB bitmap and composited into
	/// whatever space the picture is in, so a mask written as the same hex as
	/// the card behind it comes out a shade lighter and the "invisible"
	/// rectangle is on screen. The second is arithmetic: the file has to know
	/// how wide a letter is, and it can only know that by the author working it
	/// out — which is why every such line in a project is thirty-odd keys of
	/// hand-computed thousandths, why it is only ever done in a monospaced
	/// face, and why the edge lands halfway through a glyph the moment one of
	/// those numbers is a rounding out.
	///
	/// Here the reveal is a clip at a glyph boundary that CoreText gives us for
	/// the exact string, in the exact face, at the exact size. There is no
	/// second colour and no arithmetic to get wrong, a proportional face works
	/// as well as a monospaced one, and a line of any length is two keys.
	///
	/// **How far it has got is `progress` on a key**, the same field a bar and
	/// a determinate spinner already use, because that is the thing that moves
	/// and everything that moves in a scene is on a key. So the easing, the
	/// holding and the filling-in all come from the key and not from here.
	/// A typed part whose keys never mention `progress` has not been told how
	/// far it has got, and is drawn whole — which is what makes `typed:` safe
	/// to add to a line that is already on screen.
	struct Typing: Sendable, Equatable {
		/// How evenly the characters land, from 1 for a machine down to 0 for a
		/// hand.
		///
		/// At 1 every character takes the same share of the progress, which is
		/// a teleprinter and reads as one. Below it the shares differ: most
		/// stay near even, a few run long, and the gap at a space is wider than
		/// the gap inside a word — which is what a person typing sounds like
		/// and, it turns out, looks like.
		///
		/// **The unevenness is arithmetic on the text, not a random number.**
		/// A render has to give the same frames on every machine and on every
		/// run, so the wobble is derived from what is being typed and where in
		/// the line it is. Swift's own `Hasher` is seeded per process and would
		/// have given a different rhythm to every render of the same file.
		public var steady: Double

		/// The caret's colour, or `nil` for a line that types without one.
		///
		/// Drawn by this part rather than beside it, because a caret is the
		/// insertion point and the insertion point is the same measurement that
		/// decides the reveal. Two parts cannot be kept in step by hand: the
		/// caret written beside a mask has its own keys, and it slides between
		/// them while the letters cut, so it is caught halfway across a glyph
		/// on most of the frames it is on.
		public var caret: RGBA?

		/// Seconds for one on-and-off of the caret once the line is typed out,
		/// or 0 for a caret that stays lit.
		///
		/// It does not blink *while* typing, which is what a terminal does and
		/// for the same reason: a caret that blinks under a hand is one more
		/// thing moving in a picture where something is already moving.
		public var blink: Double

		/// How loud a click each character makes, from 0 for a line that types
		/// in silence to 1 for the usual level.
		///
		/// Synthesised rather than played from a file — see ``TypingSound`` for
		/// why — and mixed at the moments the characters actually land, which
		/// are the moments ``moments(of:keys:)`` gives the picture. So an
		/// uneven ``steady`` is heard as well as seen, and the two cannot drift
		/// apart, because there is only one list of moments.
		public var click: Double

		public init(steady: Double = 1, caret: RGBA? = nil, blink: Double = 1.06,
		            click: Double = 0) {
			self.steady = steady
			self.caret = caret
			self.blink = blink
			self.click = click
		}
	}
}

// MARK: - Which characters are showing

public extension Scene.Typing {

	/// The progress at which each character has landed: `count + 1` numbers
	/// from 0 to 1, rising.
	///
	/// Built from a *weight* per character rather than by moving each moment
	/// off an even grid, because weights cannot produce the two things that
	/// would be bugs. They cannot put a character before the one in front of it
	/// — a sum of positive numbers only rises — and they cannot drift off the
	/// ends, since dividing by the total lands the last boundary on exactly 1
	/// whatever the weights were. An even line is the case where every weight
	/// is 1, and it falls out of the same arithmetic rather than being a branch
	/// beside it.
	func boundaries(of text: String) -> [Double] {
		let characters = Array(text)
		guard !characters.isEmpty else { return [0] }

		var running = 0.0
		var sums: [Double] = [0]
		sums.reserveCapacity(characters.count + 1)
		for (index, character) in characters.enumerated() {
			running += weight(of: character, at: index)
			sums.append(running)
		}
		guard running > 0 else {
			// Cannot happen with the clamp in `weight`, and if it ever did the
			// answer is an even line rather than a division by nothing.
			return (0...characters.count).map { Double($0) / Double(characters.count) }
		}
		return sums.map { $0 / running }
	}

	/// How many characters are showing at this progress.
	///
	/// `nil` — no key ever said — is the whole line. See ``Typing``.
	func shown(of text: String, at progress: Double?) -> Int {
		let characters = text.count
		guard let progress else { return characters }
		guard characters > 0 else { return 0 }
		if progress >= 1 { return characters }
		if progress <= 0 { return 0 }

		let marks = boundaries(of: text)
		var showing = 0
		// A boundary the progress has exactly reached counts as reached. The
		// slack is what makes the two render paths agree: the layer path works
		// out the moment a character lands by inverting the easing and asks
		// this for the count *at* that moment, and an exact comparison there
		// answers one character short as often as the arithmetic rounds down.
		for index in 1...characters where marks[index] <= progress + 1e-9 {
			showing = index
		}
		return showing
	}

	/// The share of the line one character takes.
	///
	/// Cubed on purpose. A straight unit number spreads the characters evenly
	/// either side of nominal and reads as a wow-and-flutter, like a tape
	/// dragging; cubing it leaves most characters near their proper share and
	/// sends a few a long way out, which is the shape of a person typing —
	/// mostly a rhythm, occasionally a stumble.
	private func weight(of character: Character, at index: Int) -> Double {
		let hand = max(0, min(1, 1 - steady))
		guard hand > 0 else { return 1 }

		let unit = Self.wobble(index, character)
		var weight = 1 + 2 * hand * (unit * unit * unit)
		// A space is where somebody stops to think, so it is the one place the
		// rhythm is allowed to break in a direction rather than at random.
		if character.isWhitespace { weight += 0.8 * hand }
		// Never nought and never backwards: a character that took no time at
		// all would land with the one before it, which is two letters at once.
		return max(0.12, weight)
	}

	/// A number in −1..<1 from a position in the line and the character at it.
	///
	/// FNV-1a, written out, because the answer has to be the same on every
	/// machine and in every process. See ``steady``.
	private static func wobble(_ index: Int, _ character: Character) -> Double {
		var hash: UInt64 = 0xcbf2_9ce4_8422_2325
		func mix(_ value: UInt64) {
			var value = value
			for _ in 0..<8 {
				hash = (hash ^ (value & 0xff)) &* 0x0000_0100_0000_01b3
				value >>= 8
			}
		}
		mix(UInt64(UInt32(truncatingIfNeeded: index)))
		mix(UInt64(character.unicodeScalars.first?.value ?? 0))
		// The top 53 bits, which is every bit a Double can hold, so the spread
		// does not come out in steps.
		return Double(hash >> 11) / Double(UInt64(1) << 53) * 2 - 1
	}
}

// MARK: - When each character lands

public extension Scene.Typing {

	/// The moments a character lands, and how many are showing from each.
	///
	/// For the layer path, which cannot ask a question per frame: it wants a
	/// list of times and values to hand Core Animation, held from one to the
	/// next. The times are worked out by *inverting* the easing between the two
	/// keys a boundary falls between, so a character lands at the instant the
	/// progress curve actually crosses it rather than at the nearest frame the
	/// list happened to be sampled at. That is what keeps this path and the
	/// painter agreeing to the frame at any frame rate, without this one
	/// needing to know what the frame rate is.
	func moments(of text: String, keys: [Scene.Key]) -> [(t: Double, shown: Int)] {
		let filled = Scene.filled(keys)
		guard let first = filled.first else { return [] }
		let marks = boundaries(of: text)
		let characters = text.count

		var out: [(t: Double, shown: Int)] = [
			(first.t, shown(of: text, at: first.progress)),
		]
		guard characters > 0 else { return out }

		for (before, after) in zip(filled, filled.dropFirst()) {
			guard let from = before.progress, let to = after.progress, from != to else { continue }
			let span = after.t - before.t
			guard span > 0 else { continue }
			let low = min(from, to), high = max(from, to)
			for index in 1...characters {
				let mark = marks[index]
				guard mark > low, mark <= high else { continue }
				let fraction = Scene.uneased(after.ease, (mark - from) / (to - from))
				let moment = before.t + fraction * span
				out.append((moment, shown(of: text, at: mark)))
			}
		}

		out.sort { $0.t < $1.t }
		// One entry per moment: two characters landing on the same instant is
		// one step to two, not two steps.
		var deduped: [(t: Double, shown: Int)] = []
		for entry in out {
			if let last = deduped.last, abs(last.t - entry.t) < 1e-9 {
				deduped[deduped.count - 1].shown = max(last.shown, entry.shown)
			} else {
				deduped.append(entry)
			}
		}
		return deduped
	}
}

// MARK: - The caret

public extension Scene.Typing {

	/// When the line starts being typed and when it finishes, on the scene's
	/// own clock, or `nil` for either if it never gets there.
	func span(of text: String, keys: [Scene.Key]) -> (began: Double?, ended: Double?) {
		let moments = moments(of: text, keys: keys)
		let characters = text.count
		guard characters > 0 else { return (nil, nil) }
		return (moments.first { $0.shown >= 1 }?.t,
		        moments.first { $0.shown >= characters }?.t)
	}

	/// Whether the caret is showing at this moment.
	///
	/// Lit and still while characters are landing, blinking either side of
	/// that. A caret that blinked under a hand would be a second thing moving
	/// in the one place the eye is already looking, and no terminal does it.
	///
	/// The blink is measured from the moment typing stopped rather than from
	/// the top of the scene, so the caret is always lit on the frame the last
	/// character lands and goes out a half-cycle later — which reads as the
	/// line having been finished, instead of the caret being caught wherever
	/// a clock that started earlier happens to have got to.
	func lit(at time: Double, of text: String, keys: [Scene.Key]) -> Bool {
		guard caret != nil else { return false }
		guard blink > 0 else { return true }
		let (began, ended) = span(of: text, keys: keys)

		let from: Double
		if let ended, time >= ended {
			from = ended
		} else if let began, time >= began {
			return true
		} else {
			// Waiting to be typed into. The blink runs from the first key,
			// which is where the part's clock starts.
			from = Scene.filled(keys).first?.t ?? 0
		}
		let phase = ((time - from) / blink).truncatingRemainder(dividingBy: 1)
		return (phase < 0 ? phase + 1 : phase) < 0.5
	}
}

// MARK: - Undoing an ease

public extension Scene {

	/// Where in an interval a value was reached: the inverse of ``eased(_:_:)``.
	///
	/// Closed form for each of the four, rather than a search. They are a line
	/// and three quadratics, so there is an answer to write down, and a
	/// bisection here would be a second description of the easing that has to
	/// be kept in step with the first.
	static func uneased(_ ease: Ease, _ value: Double) -> Double {
		let value = max(0, min(1, value))
		switch ease {
		case .linear: return value
		case .in: return sqrt(value)
		case .out: return 1 - sqrt(1 - value)
		case .inOut:
			return value < 0.5 ? sqrt(value / 2) : 1 - sqrt((1 - value) / 2)
		}
	}
}
