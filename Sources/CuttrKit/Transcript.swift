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

	/// Who said it, as a ``Speaker/slug``, or `nil` when nobody has said.
	///
	/// Per word rather than per line, because a line is a layout decision that
	/// this program may change — it changed once already, when a full stop
	/// became a line break — and a fact recorded against a decision moves when
	/// the decision does. The sidecar writes runs rather than four hundred
	/// repetitions of `mia`; see ``Transcript/write(name:recogniser:locale:)``.
	///
	/// Only ever what somebody confirmed. A model's guess is a fact about this
	/// session and is not written here, for the same reason a derived slug is
	/// not marked as derived in the file: the file records decisions.
	public var speaker: String?

	public init(start: Double, end: Double, text: String, speaker: String? = nil) {
		self.start = Swift.min(start, end)
		self.end = Swift.max(start, end)
		self.text = text
		self.speaker = speaker
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

	/// Where somebody ended a line themselves, on the video's clock.
	///
	/// The breaks in ``lines`` are derived from the recording: half a second of
	/// silence ends a line, two and a half seconds ends a paragraph, a full
	/// stop ends a sentence. Derived is the right answer for four hundred lines
	/// and the wrong one for the line somebody is looking at, where two turns
	/// of a conversation came back as one because nobody paused and the
	/// recogniser heard no full stop. That break is a *decision*, and this
	/// program keeps decisions in files — the same split `TakeDocument`'s
	/// `manualSlugs` draws between a slug that was derived and one that was
	/// typed, and the same one between a speaker a model offered and a speaker
	/// somebody confirmed.
	///
	/// **A time, not a word index.** Every other time in a take is on the
	/// video's clock and this is no exception, and the reason is what happens
	/// when the words change underneath it: asking for the transcript again
	/// replaces every ``Word``, so an index is off by however many words the
	/// new pass heard differently — silently, and further out the further down
	/// the take you read. A time is a fact about the recording, and the same
	/// instant is the same instant to whatever pass hears it next.
	///
	/// Each of these is the start of the word the break comes *before*, and
	/// ``word(breakingAt:)`` is what turns it back into a word. What that
	/// answers, when the words have changed underneath it: the same words in
	/// the same places put the break back exactly; a word heard that was not
	/// heard before, or one dropped, leaves it between the same two words,
	/// which is the whole of what an index could not do; times nudged by a few
	/// milliseconds carry it along. Beyond a ``beat`` from any boundary it goes
	/// — a take re-timed by more than that has been re-aligned, and moving
	/// somebody's line break half a second down the conversation without
	/// saying so is the one outcome worth refusing.
	///
	/// Kept canonical by ``init(words:breaks:)``, which is what makes writing,
	/// reading and writing again produce the same bytes: every time in here is
	/// some word's own `start`, and no two of them are before the same word.
	public private(set) var breaks: [Double]

	public init(words: [Word] = [], breaks: [Double] = []) {
		self.words = words.sorted { $0.start < $1.start }
		self.breaks = []
		var before = Set<Int>()
		for time in breaks {
			if let index = word(breakingAt: time) { before.insert(index) }
		}
		self.breaks = before.sorted().map { self.words[$0].start }
	}

	public var isEmpty: Bool { words.isEmpty }
	public var count: Int { words.count }

	/// Everything said, as one line of prose. For a search that spans words.
	public var text: String { words.map(\.text).joined(separator: " ") }

	// MARK: - Where the silences are

	/// What sits between two words.
	///
	/// Speech is not a stream of words, it is sentences with air between them,
	/// and a transcript laid out as one paragraph makes somebody read the whole
	/// take to find the sentence they meant. The silences are already in the
	/// file — most of this is only the decision about how long a silence has to
	/// be before it is worth seeing.
	///
	/// The exception is ``sentence``, which is a break with no silence behind
	/// it, and it is here rather than in an enum of its own because "what
	/// separates these two words" is one question. Two enums with the same
	/// three shapes would be two names for it, and the pane would have to ask
	/// both and hope they agreed.
	public enum Silence: Sendable, Equatable {
		/// The same breath. A space.
		case none
		/// A full stop, and nobody paused.
		///
		/// A new line, but *not* a pause anybody can point at: there is no
		/// silence here to select, play or cut. Two people taking turns do not
		/// pause — measured on a real interview, a question and its answer are
		/// forty milliseconds apart — so without this a transcript cut on the
		/// clock alone could not be labelled a line at a time at all.
		///
		/// Also what a break somebody put in themselves comes back as, and for
		/// the same reason: see ``Transcript/breaks``.
		case sentence
		/// A beat: somebody thinking, or the end of a sentence with air after
		/// it. A new line, and a pause that is part of the take.
		case beat
		/// Long enough that something else happened — a question asked, a
		/// camera moved, nobody speaking at all. A new paragraph.
		case rest
	}

	/// Whether the word at `index` ends a sentence.
	///
	/// The recogniser punctuates, and a full stop is a stronger claim about
	/// where one thought ended than a fifth of a second of silence is.
	///
	/// Guarded twice, because a full stop is not always a sentence:
	///
	/// - a stem of one character is an initial or an ordinal — `J.`, and in
	///   German `4. Mai` is a date, not two sentences;
	/// - a stem that is all digits is a number, for the same reason.
	///
	/// Closing quotes and brackets are stepped over first, so a sentence that
	/// ends inside quotation marks still ends where it plainly does.
	public static func endsASentence(_ text: String) -> Bool {
		var stem = Substring(text)
		while let last = stem.last, closers.contains(last) { stem = stem.dropLast() }
		guard let last = stem.last, terminators.contains(last) else { return false }
		while let last = stem.last, terminators.contains(last) { stem = stem.dropLast() }
		guard stem.count >= 2 else { return false }
		return !stem.allSatisfy(\.isNumber)
	}

	private static let terminators: Set<Character> = [".", "?", "!", "\u{2026}"]
	private static let closers: Set<Character> = ["\"", "'", ")", "]", "\u{00BB}", "\u{201C}", "\u{2019}"]

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
	///
	/// The clock is asked first and the punctuation last, so a long silence
	/// after a full stop is still a paragraph rather than merely a line: the
	/// shape of a take is what the recording did, and the sentence ends are
	/// what the recogniser noticed on top of it.
	///
	/// A break somebody put in themselves sits between the two, and it can only
	/// ever be a ``Silence/sentence`` — a new line with nothing behind it to
	/// point at. ``beat`` and ``rest`` are *measurements*: the pane draws each
	/// of them as an ellipsis somebody can select, play and cut, because there
	/// is that much silence there. A hand can say where a line ends; it cannot
	/// put a second and a half of air into a recording that has none. So a
	/// break only ever turns a ``Silence/none`` into a ``Silence/sentence``,
	/// and it takes nothing away from the page: a `none` had no pause to point
	/// at either.
	public func silence(after index: Int) -> Silence {
		guard index >= 0, index + 1 < words.count else { return .none }
		let gap = words[index + 1].start - words[index].end
		if gap >= Self.rest { return .rest }
		if gap >= Self.beat { return .beat }
		if hasBreak(before: index + 1) { return .sentence }
		return Self.endsASentence(words[index].text) ? .sentence : .none
	}

	/// The run of words around `index` with no break in it — the line somebody
	/// sees, which is the unit they mean when they point at one and say "play
	/// that", and the unit a speaker is assigned to.
	public func segment(around index: Int) -> Range<Int> {
		guard !words.isEmpty else { return 0..<0 }
		let index = min(max(index, 0), words.count - 1)
		var first = index
		while first > 0, silence(after: first - 1) == .none { first -= 1 }
		var last = index
		while last + 1 < words.count, silence(after: last) == .none { last += 1 }
		return first..<(last + 1)
	}

	/// Every line in the take, in order. What a speaker is assigned to, and
	/// what an automatic pass has to answer for one at a time.
	public var lines: [Range<Int>] {
		guard !words.isEmpty else { return [] }
		var out: [Range<Int>] = []
		var first = 0
		for index in 0 ..< words.count where silence(after: index) != .none || index == words.count - 1 {
			out.append(first ..< (index + 1))
			first = index + 1
		}
		return out
	}

	/// Which line a word is in.
	public func line(of index: Int) -> Int? {
		lines.firstIndex { $0.contains(index) }
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

	// MARK: - Ending a line by hand

	/// Which word a break at `time` comes before.
	///
	/// The word whose start is nearest it, and `nil` when that is further off
	/// than a ``beat`` — or when there is no word a line could start at, the
	/// first one being no line's second.
	///
	/// Nearest rather than "the gap it falls in", because a break sits *on* a
	/// boundary and two words that touch make that boundary one instant: a
	/// second pass that moves it by two milliseconds would otherwise put the
	/// break inside the word before it and lose it. `beat` is the bound
	/// because it is already this program's answer to how much silence is
	/// worth seeing, so a boundary further away than that is somewhere else in
	/// the conversation rather than the same place re-timed.
	public func word(breakingAt time: Double) -> Int? {
		guard words.count > 1 else { return nil }
		var best = 1
		// `<=`, so where two starts are equally far off the later one wins: a
		// line somebody ended after a word should keep that word rather than
		// hand it to the line below.
		for index in 2 ..< words.count
		where abs(words[index].start - time) <= abs(words[best].start - time) { best = index }
		return abs(words[best].start - time) <= Self.beat ? best : nil
	}

	/// Whether somebody put a break in before this word.
	public func hasBreak(before index: Int) -> Bool {
		guard index > 0, index < words.count else { return false }
		// The list first, which is a handful of comparisons and is why this is
		// cheap enough to ask once per word in ``lines``. The resolution only
		// for a time that is actually in it, so that two words sharing a start
		// cannot both claim the same break.
		return breaks.contains(words[index].start)
			&& word(breakingAt: words[index].start) == index
	}

	/// Ends the line before this word.
	///
	/// `false` when there is nothing to record — the recording already ends the
	/// line there, or the word is not one a line could start at. A fact that
	/// changes nothing does not belong in the file.
	@discardableResult
	public mutating func addBreak(before index: Int) -> Bool {
		guard index > 0, index < words.count else { return false }
		guard silence(after: index - 1) == .none else { return false }
		let time = words[index].start
		// Refuses to write down a break it could not read back, which is only
		// possible where two words share a start time.
		guard word(breakingAt: time) == index, !breaks.contains(time) else { return false }
		breaks.append(time)
		breaks.sort()
		return true
	}

	/// Takes a break back out.
	///
	/// Only one somebody put in. A break the *recording* made is not somebody's
	/// to take out: there is half a second of silence there, the pane draws it
	/// as a pause that can be selected and played, and joining the two lines
	/// would swallow a stretch of the take nothing else can point at. See the
	/// note on ``Silence``.
	@discardableResult
	public mutating func removeBreak(before index: Int) -> Bool {
		guard hasBreak(before: index) else { return false }
		let time = words[index].start
		breaks.removeAll { $0 == time }
		return true
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

	/// Where the words on either side of a span are — what a mark may not cross.
	///
	/// The head of a span may be put on the sound rather than on the word time
	/// (see ``SpeechMap/cut(from:to:after:before:handle:reach:)``), and this is
	/// what stops that from quietly taking in the word before it. `nil` at
	/// either end of the take, where there is nothing to run into.
	///
	/// Word times rather than speech edges, deliberately: this is a claim about
	/// what was *selected*, and the selection is a run of words. Two words with
	/// no silence between them return each other's times, refinement is pinned
	/// and does nothing, which is the right answer — there is no moment the
	/// sound started in the middle of a word.
	public func neighbours(of span: ClosedRange<Double>) -> (before: Double?, after: Double?) {
		(words.last { $0.end <= span.lowerBound }?.end,
		 words.first { $0.start >= span.upperBound }?.start)
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

	/// Everything said inside a span, as one line of prose.
	///
	/// What a model is handed when it is asked to name a clip — the *whole*
	/// passage rather than the first few words, because the difference between
	/// naming a clip and abbreviating it is having read to the end of it. It is
	/// capped all the same: a two-minute clip is three hundred words, and a
	/// model given three hundred words to make a label out of will make a label
	/// out of the last of them.
	public func text(covering span: ClosedRange<Double>, limit: Int = 60) -> String {
		let clamped = indices(in: span).clamped(to: 0 ..< words.count)
		guard !clamped.isEmpty else { return "" }
		return words[clamped].prefix(limit).map(\.text).joined(separator: " ")
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
	/// Who is speaking is a *comment*, and that is the whole trick.
	///
	/// A sidecar has to survive being opened by an older build of this program
	/// — the file outlives the version that wrote it, the same as the take file
	/// does. There is no fourth column an older reader would ignore: it takes
	/// the rest of the line as the word, so anything added after the text
	/// becomes part of the text, and anything added before it shifts the two
	/// columns it is counting on.
	///
	/// A comment line is the one thing every version of this reader has always
	/// thrown away. So a speaker is written as `# speaker: mia` above the run
	/// they say, and a build that has never heard of speakers reads exactly the
	/// words it read before. It also happens to be the nicest way to read one:
	/// a transcript laid out under headings is what a transcript looks like.
	///
	/// Runs, not repetitions. Assigning is a line at a time and people talk in
	/// paragraphs, so a marker appears where the speaker *changes* — a couple
	/// of dozen lines in a five-minute interview rather than four hundred.
	/// `# speaker:` with nothing after it says nobody knows.
	///
	/// A line somebody ended themselves is a comment for the same reason and by
	/// the same trick: `# line: break`, above the word the line starts at. An
	/// older reader throws it away and lays the words out by their silences,
	/// which is exactly what it did before anybody could end a line by hand.
	/// The marker carries no time, because where it sits in the file already
	/// says which two words it is between — one fact, written once. The time in
	/// ``breaks`` is what that position means, and it is read back off the word
	/// underneath.
	public func write(name: String, recogniser: String, locale: String) -> String {
		var out = "# cuttr transcript — \(name)\n"
		out += "# \(recogniser), \(locale), times on the video's clock\n"
		// The explaining lines only when there is something to explain, so a
		// take nobody has labelled writes byte for byte what it always did.
		if words.contains(where: { $0.speaker != nil }) {
			out += "# `# speaker:` names who says what follows, until the next one\n"
		}
		if !breaks.isEmpty {
			out += "# `# line: break` ends a line where the recording does not\n"
		}
		out += "# start      end        word\n"
		// Starts as nobody, so a take with no speakers in it writes no markers
		// at all rather than one saying so.
		var current: String? = nil
		for (index, word) in words.enumerated() {
			// The break first: it ends the line above, and the name that
			// follows heads the line it starts.
			if hasBreak(before: index) { out += "# line: break\n" }
			if current != word.speaker {
				current = word.speaker
				out += "# speaker: \(word.speaker ?? "")\n"
			}
			out += String(format: "%-10.3f %-10.3f %@\n", word.start, word.end, word.text)
		}
		return out
	}

	public static func read(_ text: String) -> Transcript {
		var words: [Word] = []
		var speaker: String?
		var breaks: [Double] = []
		var breaking = false
		for line in text.components(separatedBy: .newlines) {
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			guard !trimmed.isEmpty else { continue }
			if trimmed.hasPrefix("#") {
				let comment = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
				if comment.lowercased().hasPrefix("line:") {
					// Only `break` is understood. Anything else under this key
					// belongs to a version that has not been written yet, and
					// the honest thing for this one to do with it is nothing.
					if Slug.make(from: String(comment.dropFirst("line:".count))) == "break" {
						breaking = true
					}
					continue
				}
				guard comment.lowercased().hasPrefix("speaker:") else { continue }
				let named = Slug.make(from: String(comment.dropFirst("speaker:".count)))
				speaker = named.isEmpty ? nil : named
				continue
			}
			let fields = trimmed.split(
				separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
			guard fields.count == 3,
			      let start = Double(fields[0]), let end = Double(fields[1])
			else { continue }
			// The rest of the line, so a hyphenated or apostrophed token that
			// somebody has re-typed with a space in it still reads back.
			words.append(Word(start: start, end: end,
			                  text: String(fields[2]).trimmingCharacters(in: .whitespaces),
			                  speaker: speaker))
			// Off the word rather than off the numbers on the line, so a
			// hand-edit that has written them the wrong way round still puts
			// the break where the word ended up.
			if breaking, let word = words.last { breaks.append(word.start) }
			breaking = false
		}
		return Transcript(words: words, breaks: breaks)
	}

	// MARK: - Who is speaking

	/// The slugs the words name, in the order they are first heard.
	///
	/// The take's `speakers:` block is the cast; this is who the sidecar
	/// actually names, which may include somebody a hand-edit invented. The
	/// pane shows both, because a colour for a speaker the take has not heard
	/// of is better than a silent omission.
	public var speakers: [String] {
		var seen = Set<String>()
		return words.compactMap(\.speaker).filter { seen.insert($0).inserted }
	}

	/// Who says a line, taken from its first word.
	public func speaker(ofLine range: Range<Int>) -> String? {
		guard range.lowerBound >= 0, range.lowerBound < words.count else { return nil }
		return words[range.lowerBound].speaker
	}

	/// Says who is speaking on every line the given words touch.
	///
	/// **It does not carry forward.** It used to: pressing a key on a line
	/// meant "from here on, it is her", and painted every following line that
	/// still agreed with this one. That is one keystroke for a whole page,
	/// which is quick — and it is also one keystroke for a mistake whose
	/// extent nobody can see. One press could repaint forty lines, and beside
	/// a standing guess the page stopped being readable at all.
	///
	/// So a line is answered when somebody answers it, and a *run* of lines is
	/// answered by selecting them and saying who — which is the case the
	/// carry-forward was really for, and which says exactly which lines it is
	/// about. Whole lines either way: a speaker belongs to a line and not to
	/// the three words somebody happened to drag across.
	///
	/// Returns how many lines it set, so the pane can say so.
	@discardableResult
	public mutating func assign(_ speaker: String?, to range: Range<Int>) -> Int {
		// A caret is a range of no length, and it means the line it is in.
		let wanted = range.isEmpty ? range.lowerBound ..< range.lowerBound + 1 : range
		var changed = 0
		for line in lines where line.overlaps(wanted) {
			for index in line { words[index].speaker = speaker }
			changed += 1
		}
		return changed
	}

	/// Renames a speaker everywhere the words name them, or takes them off
	/// altogether when `new` is nothing.
	///
	/// Only for when the slug itself changes, which is rare: the ordinary
	/// rename changes ``Speaker/name``, which is prose in the take file, and
	/// does not touch a single word.
	@discardableResult
	public mutating func rename(_ old: String, to new: String?) -> Int {
		var changed = 0
		for index in words.indices where words[index].speaker == old {
			words[index].speaker = new
			changed += 1
		}
		return changed
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
