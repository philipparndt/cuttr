import Foundation
import Testing
@testable import CuttrKit

/// Where the silences are, and what they make of the text.
@MainActor @Suite struct TranscriptShapeTests {

	/// Four words, then half a second, then two, then three seconds, then one.
	private let said = Transcript(words: [
		Word(start: 0.0, end: 0.4, text: "eins"),
		Word(start: 0.4, end: 0.8, text: "zwei"),
		Word(start: 1.4, end: 1.8, text: "drei"),
		Word(start: 4.9, end: 5.3, text: "vier"),
	])

	@Test func aPauseIsAsLongAsItIs() {
		#expect(said.silence(after: 0) == .none)
		#expect(said.silence(after: 1) == .beat)
		#expect(said.silence(after: 2) == .rest)
		// Nothing follows the last word, and nothing is what it says.
		#expect(said.silence(after: 3) == .none)
		#expect(said.silence(after: 9) == .none)
	}

	/// The unit somebody means when they point at a line.
	@Test func aLineIsWhatIsBetweenTwoSilences() {
		#expect(said.segment(around: 0) == 0..<2)
		#expect(said.segment(around: 1) == 0..<2)
		#expect(said.segment(around: 2) == 2..<3)
		#expect(said.segment(around: 3) == 3..<4)
		// Out of range is answered rather than crashed: a click lands where it
		// lands.
		#expect(said.segment(around: 99) == 3..<4)
	}

	/// One long take is one paragraph, which is the thing this replaced.
	@Test func wordsWithNoSilenceInThemAreOneLine() {
		let solid = Transcript(words: (0..<20).map {
			Word(start: Double($0) * 0.3, end: Double($0) * 0.3 + 0.3, text: "w\($0)")
		})
		#expect(solid.segment(around: 10) == 0..<20)
		#expect((0..<19).allSatisfy { solid.silence(after: $0) == .none })
	}
}

/// A full stop is a line break, because two people taking turns do not pause.
@MainActor @Suite struct TranscriptSentenceTests {

	/// The shape that made this necessary: a question and its answer, 40 ms
	/// apart, arriving from the recogniser as one line and plainly two
	/// speakers.
	///
	/// Invented German. It was measured on a real take — a child's family
	/// interview — and this repository is public; the timings are what the
	/// measurement was about and they are kept exactly.
	private let interview = Transcript(words: [
		Word(start: 147.907, end: 148.2, text: "Und"),
		Word(start: 148.2, end: 148.5, text: "was"),
		Word(start: 148.5, end: 148.8, text: "kommt"),
		Word(start: 148.8, end: 149.2, text: "als"),
		Word(start: 149.2, end: 149.5, text: "allerletztes"),
		Word(start: 149.5, end: 149.827, text: "dran?"),
		Word(start: 149.827, end: 150.2, text: "Ganz"),
		Word(start: 150.2, end: 150.6, text: "zuletzt"),
		Word(start: 150.6, end: 151.0, text: "kommt"),
		Word(start: 151.0, end: 151.3, text: "der"),
		Word(start: 151.3, end: 153.967, text: "Werkzeugkasten."),
	])

	@Test func aQuestionAndItsAnswerAreTwoLines() {
		// A break with no silence behind it, which is the whole point: there
		// are forty milliseconds between the question and the answer, so no
		// threshold on the gap could have separated them.
		#expect(interview.silence(after: 5) == .sentence)
		#expect(interview.silence(after: 4) == .none)
		#expect(interview.lines.count == 2)
		#expect(interview.segment(around: 2) == 0..<6)
		#expect(interview.segment(around: 8) == 6..<11)
	}

	/// The clock is asked first. A long silence after a full stop is still a
	/// paragraph, and half a second after one is still a beat with a pause in
	/// it that somebody can select — otherwise a take's shape would collapse
	/// into one flat run of lines with nothing in them to point at.
	@Test func aRestStillOutranksAFullStop() {
		let said = Transcript(words: [
			Word(start: 0, end: 0.4, text: "Fertig."),
			Word(start: 4.0, end: 4.4, text: "Weiter."),
			Word(start: 4.9, end: 5.3, text: "Ja"),
		])
		#expect(said.silence(after: 0) == .rest)
		#expect(said.silence(after: 1) == .beat)
	}

	/// What is not a sentence end. An initial, an ordinal — `4. Mai` is a date
	/// — and a bare number are all full stops that break nothing.
	@Test func notEveryFullStopEndsASentence() {
		#expect(Transcript.endsASentence("Werkzeugkasten.") == true)
		#expect(Transcript.endsASentence("dran?") == true)
		#expect(Transcript.endsASentence("Nein!") == true)
		#expect(Transcript.endsASentence("gesagt.\u{201C}") == true)
		#expect(Transcript.endsASentence("J.") == false)
		#expect(Transcript.endsASentence("4.") == false)
		#expect(Transcript.endsASentence("1999.") == false)
		#expect(Transcript.endsASentence("Werkzeugkasten") == false)
		#expect(Transcript.endsASentence("") == false)
		#expect(Transcript.endsASentence(".") == false)
	}

	/// Every word is in exactly one line, and the lines cover the take.
	@Test func theLinesTileTheTake() {
		let covered = interview.lines.flatMap { Array($0) }
		#expect(covered == Array(0 ..< interview.count))
		#expect(interview.line(of: 7) == 1)
		#expect(interview.line(of: 99) == nil)
	}
}
