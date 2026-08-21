import Foundation
import Testing
@testable import CuttrKit

/// A line break somebody put in themselves.
///
/// The automatic ones come off the recording — half a second of silence, a full
/// stop — and they are right about four hundred lines and wrong about the one
/// somebody is reading, where two turns of a conversation arrived as one line
/// because nobody paused and nothing was punctuated. That break is a decision,
/// so it is recorded, and everything below is about what it is recorded against.
///
/// Invented German throughout. The take this was built against is a family's
/// recording of children and this repository is public.
@Suite struct TranscriptBreakTests {

	/// One line: nothing here pauses for half a second and nothing ends in a
	/// full stop, so the recogniser hands back five words in a row. The turn
	/// changes at `kam`.
	private func said() -> Transcript {
		Transcript(words: [
			Word(start: 0.0, end: 0.4, text: "und"),
			Word(start: 0.4, end: 0.8, text: "dann"),
			Word(start: 0.8, end: 1.2, text: "kam"),
			Word(start: 1.2, end: 1.6, text: "der"),
			Word(start: 1.6, end: 2.0, text: "Werkzeugkasten"),
		])
	}

	private func write(_ said: Transcript) -> String {
		said.write(name: "t", recogniser: "speech-analyzer", locale: "de-DE")
	}

	// MARK: - What it does to the lines

	@Test func aBreakEndsALineWhereTheSilencesWouldNot() {
		var said = said()
		#expect(said.lines == [0 ..< 5])
		// A local: `#expect` calls what it is handed on a copy, and this one
		// has to be called on the transcript itself.
		let put = said.addBreak(before: 2)
		#expect(put)
		// A new line with nothing behind it to point at, which is the only
		// thing a hand can honestly say about a recording it cannot change.
		#expect(said.silence(after: 1) == .sentence)
		#expect(said.lines == [0 ..< 2, 2 ..< 5])
		#expect(said.segment(around: 3) == 2 ..< 5)
		#expect(said.line(of: 1) == 0)
		#expect(said.line(of: 2) == 1)
		// And every word is still in exactly one line.
		#expect(said.lines.flatMap { Array($0) } == Array(0 ..< 5))
	}

	@Test func takingTheBreakOutPutsTheLineBackTogether() {
		var said = said()
		said.addBreak(before: 2)
		let took = said.removeBreak(before: 2)
		#expect(took)
		#expect(said.lines == [0 ..< 5])
		#expect(said.breaks.isEmpty)
		// And a second attempt has nothing to take out.
		let again = said.removeBreak(before: 2)
		#expect(again == false)
	}

	/// A line the *recording* ends is not somebody's to end again, or to join.
	/// There is half a second of silence there; the pane draws it as a pause
	/// that can be selected, played and cut, and a hand that could join those
	/// two lines would swallow a stretch of the take nothing else can point at.
	@Test func aBreakIsRefusedWhereTheRecordingAlreadyEndsTheLine() {
		var said = Transcript(words: [
			Word(start: 0.0, end: 0.4, text: "fertig"),
			Word(start: 1.4, end: 1.8, text: "weiter"),
			Word(start: 1.8, end: 2.2, text: "Schluss."),
			Word(start: 2.2, end: 2.6, text: "nein"),
		])
		#expect(said.silence(after: 0) == .beat)
		let afterAPause = said.addBreak(before: 1)
		let afterAFullStop = said.addBreak(before: 3)
		let joined = said.removeBreak(before: 1)
		#expect(afterAPause == false)
		#expect(afterAFullStop == false)
		#expect(joined == false)
		#expect(said.breaks.isEmpty)
	}

	@Test func thereIsNoLineToEndBeforeTheFirstWordOrAfterTheLast() {
		var said = said()
		let first = said.addBreak(before: 0)
		let past = said.addBreak(before: 5)
		let nonsense = said.addBreak(before: -1)
		#expect(first == false)
		#expect(past == false)
		#expect(nonsense == false)
		#expect(said.hasBreak(before: 0) == false)
		// The same break twice is one break.
		let put = said.addBreak(before: 2)
		let twice = said.addBreak(before: 2)
		#expect(put)
		#expect(twice == false)
		#expect(said.breaks.count == 1)
	}

	// MARK: - Who is speaking, either side of it

	/// Splitting a line says nothing about who is talking, and it does not get
	/// to. Both halves keep the name they already had — which works because a
	/// speaker is recorded per *word*: a line is a layout decision, and a fact
	/// recorded against a decision moves when the decision does.
	@Test func bothHalvesOfABrokenLineKeepWhoWasSpeaking() {
		var said = said()
		said.assign("papa", to: 0 ..< 5)
		said.addBreak(before: 2)
		#expect(said.lines.map { said.speaker(ofLine: $0) } == ["papa", "papa"])
	}

	/// Which is the point of doing it: the two halves can now be answered
	/// separately, and answering one leaves the other alone.
	@Test func namingOneHalfOfABrokenLineLeavesTheOtherAlone() {
		var said = said()
		said.assign("papa", to: 0 ..< 5)
		said.addBreak(before: 2)
		let named = said.assign("mia", to: 3 ..< 4)
		#expect(named == 1)
		#expect(said.lines.map { said.speaker(ofLine: $0) } == ["papa", "mia"])
		#expect(said.words.map(\.speaker) == ["papa", "papa", "mia", "mia", "mia"])
	}

	// MARK: - The sidecar

	@Test func aBreakSurvivesTheSidecar() {
		var said = said()
		said.addBreak(before: 2)
		let back = Transcript.read(write(said))
		#expect(back == said)
		#expect(back.lines == [0 ..< 2, 2 ..< 5])
	}

	/// Written as a comment above the word the line starts at, which is the
	/// whole trick: a reader that has never heard of breaks throws the line
	/// away and lays the words out by their silences, exactly as it did before.
	@Test func theBreakIsACommentAboveTheWordTheLineStartsAt() {
		var said = said()
		said.addBreak(before: 2)
		let lines = write(said).components(separatedBy: "\n")
		let marker = lines.firstIndex(of: "# line: break")
		#expect(marker != nil)
		if let marker { #expect(lines[marker + 1].hasSuffix("kam")) }
		#expect(write(said).contains("# `# line: break` ends a line where the recording does not"))

		// The old reader, which is three fields and no comments at all.
		var old: [String] = []
		for line in lines {
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
			let fields = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
			guard fields.count == 3, Double(fields[0]) != nil else { continue }
			old.append(String(fields[2]).trimmingCharacters(in: .whitespaces))
		}
		#expect(old == said.words.map(\.text))
	}

	/// The rule the sidecar lives by, and the reason a break carries no time of
	/// its own: where the comment sits already says which two words it is
	/// between, and re-writing what was read back has to produce the same bytes
	/// or opening a take and saving it rewrites the transcript.
	@Test func writingIsStableAcrossABreak() {
		var said = said()
		said.addBreak(before: 2)
		said.addBreak(before: 4)
		let once = write(said)
		#expect(write(said) == once)
		#expect(write(Transcript.read(once)) == once)
		#expect(Transcript.read(once).breaks.count == 2)
	}

	/// And a transcript nobody has broken is byte for byte the file this
	/// program has always written, down to the header.
	@Test func aTranscriptNobodyHasBrokenWritesTheFileItAlwaysDid() {
		#expect(write(said()) == """
		# cuttr transcript — t
		# speech-analyzer, de-DE, times on the video's clock
		# start      end        word
		0.000      0.400      und
		0.400      0.800      dann
		0.800      1.200      kam
		1.200      1.600      der
		1.600      2.000      Werkzeugkasten

		""")
	}

	/// A break and a name at the same word: the break ends the line above, the
	/// name heads the line it starts, and they are written in that order so the
	/// file reads as what it is.
	@Test func aBreakAndANameAtTheSameWordAreWrittenInThatOrder() {
		var said = said()
		said.addBreak(before: 2)
		said.assign("papa", to: 0 ..< 1)
		said.assign("mia", to: 2 ..< 3)
		let markers = write(said).components(separatedBy: "\n")
			.filter { $0.hasPrefix("# speaker:") || $0.hasPrefix("# line:") }
		#expect(markers == ["# speaker: papa", "# line: break", "# speaker: mia"])
		#expect(Transcript.read(write(said)) == said)
	}

	/// A key this version does not know belongs to a version that has not been
	/// written yet, and the honest thing to do with it is nothing.
	@Test func aLineKeyThisVersionDoesNotKnowIsLeftAlone() {
		let said = Transcript.read("""
		# cuttr transcript — t
		0.000      0.400      und
		# line: join
		0.400      0.800      dann
		""")
		#expect(said.count == 2)
		#expect(said.breaks.isEmpty)
	}

	// MARK: - When the words change underneath it

	/// The reason a break is a time and not a word index.
	///
	/// A second pass over the same audio hears an `äh` nobody transcribed the
	/// first time, so every index after it is off by one. The break is before
	/// `kam` both times, because 0.8 s into the take is 0.8 s into the take.
	@Test func aBreakStaysBetweenTheSameWordsWhenAnotherIsHeard() {
		var said = said()
		said.addBreak(before: 2)
		let again = Transcript(words: [
			Word(start: 0.0, end: 0.2, text: "äh"),
			Word(start: 0.2, end: 0.4, text: "und"),
			Word(start: 0.4, end: 0.8, text: "dann"),
			Word(start: 0.8, end: 1.2, text: "kam"),
			Word(start: 1.2, end: 1.6, text: "der"),
			Word(start: 1.6, end: 2.0, text: "Werkzeugkasten"),
		], breaks: said.breaks)
		#expect(again.hasBreak(before: 3))
		#expect(again.lines == [0 ..< 3, 3 ..< 6])
		// An index would have put it here, one word early, and said nothing
		// about having done so.
		#expect(again.hasBreak(before: 2) == false)
	}

	/// The times move a little as well, and a break moves with the words rather
	/// than being lost to two milliseconds.
	@Test func aBreakFollowsItsWordsWhenTheyShift() {
		var said = said()
		said.addBreak(before: 2)
		let again = Transcript(
			words: said.words.map {
				Word(start: $0.start + 0.002, end: $0.end + 0.002, text: $0.text)
			}, breaks: said.breaks)
		#expect(again.hasBreak(before: 2))
		#expect(again.lines == [0 ..< 2, 2 ..< 5])
	}

	/// Where a new pass hears one word across the moment the break was at, the
	/// boundary it was about is gone and the nearest one takes it — the one
	/// after, on a tie, so the words that were on the first line stay on it.
	@Test func aBreakGoesToTheNearestBoundaryWhenAWordSwallowsTheOldOne() {
		var said = said()
		said.addBreak(before: 2)
		// `dann kam` came back as one word, so there is no longer a boundary
		// at 0.8 s at all. `und dannkam` keeps what the first line had.
		let again = Transcript(words: [
			Word(start: 0.0, end: 0.4, text: "und"),
			Word(start: 0.4, end: 1.2, text: "dannkam"),
			Word(start: 1.2, end: 1.6, text: "der"),
			Word(start: 1.6, end: 2.0, text: "Werkzeugkasten"),
		], breaks: said.breaks)
		#expect(again.lines == [0 ..< 2, 2 ..< 4])
	}

	/// And where there is nothing left to break, it goes. Nudging it to the
	/// nearest boundary would be this program guessing where somebody wanted
	/// their line to end, which is the one thing it must not do: losing a break
	/// costs the keystroke that put it in, and a break that moves by itself
	/// costs somebody's belief in all the others.
	@Test func aBreakGoesWhenThereIsNothingLeftToBreak() {
		var said = said()
		said.addBreak(before: 2)
		let asOneWord = Transcript(
			words: [Word(start: 0.0, end: 2.0, text: "unddannkamderwerkzeugkasten")],
			breaks: said.breaks)
		#expect(asOneWord.breaks.isEmpty)
		#expect(asOneWord.lines == [0 ..< 1])
		// Nor does a break survive words that are no longer there at all.
		let elsewhere = Transcript(
			words: [Word(start: 60.0, end: 60.4, text: "spaeter"),
			        Word(start: 60.4, end: 60.8, text: "vielleicht")],
			breaks: said.breaks)
		#expect(elsewhere.breaks.isEmpty)
	}

	/// Kept canonical, so two breaks that end up before the same word are one
	/// break and the file cannot churn between saves.
	@Test func breaksAreKeptCanonical() {
		let said = Transcript(words: said().words, breaks: [0.79, 0.8, 0.82])
		#expect(said.breaks == [0.8])
		#expect(said.hasBreak(before: 2))
	}
}
