import Foundation

/// One recognised word, and when it was said.
///
/// **On the video's clock**, like every other time in a take. The recogniser is
/// usually pointed at the separate recorder's file, which has a clock of its
/// own; the conversion happens once, in ``Transcriber``, before a word ever
/// becomes one of these. Nothing downstream has to remember to add an offset,
/// which is the only way that stays true.
public struct Word: Sendable, Equatable {
	public var start: Double
	public var end: Double
	/// As the recogniser wrote it, capitals, punctuation and all. Not slugged:
	/// this is what was said, and turning it into an identifier is a separate
	/// decision made at the moment a clip is named.
	public var text: String

	public init(start: Double, end: Double, text: String) {
		self.start = Swift.min(start, end)
		self.end = Swift.max(start, end)
		self.text = text
	}

	public var duration: Double { end - start }

	public func contains(_ time: Double) -> Bool { time >= start && time < end }
}

/// Everything that was said in a take, in the order it was said.
///
/// The sidecar's contents — the counterpart of ``AnchorPath``. A minute of
/// speech is around 150 of these and a long take is several thousand, which is
/// far too many for the take file: it would bury the clips, which are the part
/// somebody wrote. So the take names a file and this is what is in it.
public struct Transcript: Sendable, Equatable {
	public var words: [Word]

	public init(words: [Word] = []) {
		self.words = words.sorted { $0.start < $1.start }
	}

	public var isEmpty: Bool { words.isEmpty }
	public var count: Int { words.count }

	/// Everything said, as one line of prose. For a search that spans words.
	public var text: String { words.map(\.text).joined(separator: " ") }

	// MARK: - Where the silences are

	/// What sits between two words when nobody was speaking.
	///
	/// Speech is not a stream of words, it is sentences with air between them,
	/// and a transcript laid out as one paragraph makes somebody read the whole
	/// take to find the sentence they meant. The silences are already in the
	/// file — this is only the decision about how long a silence has to be
	/// before it is worth seeing.
	public enum Silence: Sendable, Equatable {
		/// The same breath. A space.
		case none
		/// A beat: the end of a sentence, or somebody thinking. A new line.
		case beat
		/// Long enough that something else happened — a question asked, a
		/// camera moved, nobody speaking at all. A new paragraph.
		case rest
	}

	/// Half a second. Measured rather than chosen: on a five-minute take of
	/// four people talking, the word times come back in two clumps with nothing
	/// between them — nine gaps in ten are exactly zero, and the next one up is
	/// a fifth of a second. Anything from a tenth to a second draws the same
	/// twenty-nine lines, so the number is not delicate and there is no point
	/// pretending it is.
	public static let beat = 0.5
	/// Two and a half seconds. The same take gives thirteen of these, which is
	/// thirteen paragraphs in five minutes: about what somebody would write.
	public static let rest = 2.5

	/// What follows the word at `index`.
	public func silence(after index: Int) -> Silence {
		guard index >= 0, index + 1 < words.count else { return .none }
		let gap = words[index + 1].start - words[index].end
		if gap >= Self.rest { return .rest }
		if gap >= Self.beat { return .beat }
		return .none
	}

	/// The run of words around `index` with no break in it — the line somebody
	/// sees, which is the unit they mean when they point at one and say "play
	/// that".
	public func segment(around index: Int) -> Range<Int> {
		guard !words.isEmpty else { return 0..<0 }
		let index = min(max(index, 0), words.count - 1)
		var first = index
		while first > 0, silence(after: first - 1) == .none { first -= 1 }
		var last = index
		while last + 1 < words.count, silence(after: last) == .none { last += 1 }
		return first..<(last + 1)
	}

	/// The word being said at `time`, or `nil` in the gaps.
	///
	/// `nil` in a pause rather than the nearest word, because the marker in the
	/// pane is a claim about what is being said *now*: leaving the last word lit
	/// through four seconds of silence says she is still saying it.
	public func index(at time: Double) -> Int? {
		guard !words.isEmpty else { return nil }
		// Binary search: this is asked on every tick of the player.
		var low = 0, high = words.count - 1
		while low < high {
			let mid = (low + high + 1) / 2
			if words[mid].start <= time { low = mid } else { high = mid - 1 }
		}
		return words[low].contains(time) ? low : nil
	}

	/// The word nearest `time`, whether or not it is being said.
	///
	/// What a playhead parked in a pause should scroll to, and what "name this
	/// clip from its first words" starts from when the clip opens on a breath.
	public func nearestIndex(to time: Double) -> Int? {
		guard !words.isEmpty else { return nil }
		if let exact = index(at: time) { return exact }
		var best = 0
		var distance = Double.infinity
		for (index, word) in words.enumerated() {
			let gap = word.start > time ? word.start - time : time - word.end
			if gap < distance { distance = gap; best = index }
			if word.start > time { break }
		}
		return best
	}

	/// The words that fall inside a span, whole or in part.
	public func indices(in span: ClosedRange<Double>) -> Range<Int> {
		let first = words.firstIndex { $0.end > span.lowerBound }
		guard let first else { return words.count ..< words.count }
		var last = first
		while last < words.count, words[last].start < span.upperBound { last += 1 }
		return first ..< last
	}

	// MARK: - Making a clip out of words

	/// Where a run of words starts and ends.
	///
	/// The arithmetic behind "select a sentence, press Return": the head of the
	/// first word to the tail of the last, and nothing added at either end. A
	/// handle of padding would be kinder to the ear and is not this function's
	/// decision to make — the times in a take are what somebody can see on the
	/// timeline, and a clip that quietly begins 200 ms before the word it was
	/// made from is a clip whose numbers do not match its name.
	public func span(_ range: Range<Int>) -> (start: Double, end: Double)? {
		let clamped = range.clamped(to: 0 ..< words.count)
		guard !clamped.isEmpty else { return nil }
		return (words[clamped.lowerBound].start, words[clamped.upperBound - 1].end)
	}

	/// The words as spoken, for naming a clip after them.
	///
	/// Cut off at `limit` words, and the cut is not apologised for with an
	/// ellipsis: this becomes a name and then a slug, and `so-the-driver-`
	/// helps nobody read a reference.
	public func phrase(_ range: Range<Int>, limit: Int = 6) -> String {
		let clamped = range.clamped(to: 0 ..< words.count)
		guard !clamped.isEmpty else { return "" }
		let taken = words[clamped].prefix(limit).map(\.text)
		// Punctuation belongs to the sentence, not to the name: a clip called
		// `Right, so the driver.` reads as a mistake, and its slug would be the
		// same with or without.
		return taken.joined(separator: " ")
			.trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:!?—–-"))
	}

	/// What a clip covering `span` should be called: its first few words.
	public func phrase(covering span: ClosedRange<Double>, limit: Int = 6) -> String {
		phrase(indices(in: span), limit: limit)
	}

	// MARK: - Finding a phrase

	/// The run of words matching `phrase`, at or after `from`, wrapping once.
	///
	/// Matched over the *joined* text rather than word by word, so a phrase that
	/// crosses a word boundary is found — which is most of them.
	///
	/// Both sides go through ``Slug/make(from:)``, which is the program's one
	/// answer to "what do two pieces of text have to have in common to be the
	/// same words": case, accents and punctuation folded away, `Größe` and
	/// `grosse` the same thing. Somebody searching a transcript has not
	/// undertaken to type the comma the recogniser put in, and a second
	/// implementation of German folding is a second place for it to be wrong.
	public func find(_ phrase: String, from: Int = 0) -> Range<Int>? {
		let needle = Slug.make(from: phrase)
		guard !needle.isEmpty, !words.isEmpty else { return nil }
		let folded = words.map { Slug.make(from: $0.text) }

		// Every starting word, from `from` onwards and then round the front.
		let order = Array(from ..< words.count) + Array(0 ..< Swift.min(from, words.count))
		for start in order where !folded[start].isEmpty {
			var joined = ""
			var end = start
			while end < words.count {
				// A word that is nothing but punctuation joins nothing but
				// still passes by, so `right — so` matches `right so`.
				if !folded[end].isEmpty {
					joined += joined.isEmpty ? folded[end] : "-" + folded[end]
				}
				end += 1
				if joined == needle { return start ..< end }
				if joined.count >= needle.count || !needle.hasPrefix(joined) { break }
			}
			// A single word that merely contains what was typed still counts:
			// four letters into a word is how somebody searches.
			if needle.count < folded[start].count, folded[start].contains(needle) {
				return start ..< (start + 1)
			}
		}
		return nil
	}

	// MARK: - The sidecar

	/// Three columns of text, for the same reason the anchor path is.
	///
	/// A recogniser mishears a name once per take and always the same way. In
	/// this format that is one line to correct in an editor, and the correction
	/// survives everything except asking for the transcript again.
	public func write(name: String, recogniser: String, locale: String) -> String {
		var out = "# cuttr transcript — \(name)\n"
		out += "# \(recogniser), \(locale), times on the video's clock\n"
		out += "# start      end        word\n"
		for word in words {
			out += String(format: "%-10.3f %-10.3f %@\n", word.start, word.end, word.text)
		}
		return out
	}

	public static func read(_ text: String) -> Transcript {
		var words: [Word] = []
		for line in text.components(separatedBy: .newlines) {
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
			let fields = trimmed.split(
				separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
			guard fields.count == 3,
			      let start = Double(fields[0]), let end = Double(fields[1])
			else { continue }
			// The rest of the line, so a hyphenated or apostrophed token that
			// somebody has re-typed with a space in it still reads back.
			words.append(Word(start: start, end: end,
			                  text: String(fields[2]).trimmingCharacters(in: .whitespaces)))
		}
		return Transcript(words: words)
	}
}

/// Where a take's words are kept, and what produced them.
///
/// The block written under `words:` in the take file — the counterpart of an
/// ``Anchor``'s `path:`. The words themselves are a ``Transcript`` in the file
/// this names.
///
/// The recogniser and the locale are recorded because a transcript is a
/// *claim*, and a claim whose provenance is lost is one nobody can weigh. Next
/// year, when a word is in the wrong place, "which model said this, and in
/// which language" is the first question and the file should answer it without
/// anybody having to remember.
public struct Words: Sendable, Equatable {
	/// The sidecar, relative to the take file.
	public var path: String
	public var recogniser: Recogniser
	/// The language it was asked for, as a BCP-47 identifier: `de-DE`.
	public var locale: String

	public enum Recogniser: String, Sendable, CaseIterable {
		/// `SpeechAnalyzer` with a `SpeechTranscriber` module — the one with
		/// word-level times, and the one this program prefers.
		case speechAnalyzer = "speech-analyzer"
		/// `SFSpeechRecognizer`, pinned to on-device. The fallback on a system
		/// too old for the above.
		case speechRecognizer = "speech-recognizer"
		/// Somebody wrote or corrected the file themselves. Never written by
		/// this program, and read back so that saying so in the file survives.
		case hand
	}

	public init(path: String, recogniser: Recogniser = .speechAnalyzer, locale: String) {
		self.path = path
		self.recogniser = recogniser
		self.locale = locale
	}
}
