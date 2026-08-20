import Foundation
import Testing
@testable import CuttrKit

@Suite struct TranscriptTests {

	private func sample() -> Transcript {
		Transcript(words: [
			Word(start: 1.000, end: 1.180, text: "So"),
			Word(start: 1.180, end: 1.320, text: "the"),
			Word(start: 1.320, end: 1.740, text: "driver"),
			Word(start: 1.740, end: 2.310, text: "installs"),
			Word(start: 3.000, end: 3.400, text: "itself."),
			Word(start: 8.000, end: 8.500, text: "Größe"),
		])
	}

	// MARK: - The sidecar

	@Test func roundTripsThroughTheSidecar() {
		let text = sample().write(name: "take-01", recogniser: "speech-analyzer", locale: "de-DE")
		let back = Transcript.read(text)
		#expect(back == sample())
	}

	@Test func writingIsStableForTheSameTranscript() {
		// The same rule the take file lives by. A sidecar that churns on every
		// save is a sidecar nobody can keep in version control beside the take
		// it belongs to.
		let once = sample().write(name: "take-01", recogniser: "speech-analyzer", locale: "de-DE")
		let twice = sample().write(name: "take-01", recogniser: "speech-analyzer", locale: "de-DE")
		#expect(once == twice)
		// And re-writing what was read back has to produce the same bytes, or
		// opening a take and saving it rewrites the transcript.
		#expect(Transcript.read(once)
			.write(name: "take-01", recogniser: "speech-analyzer", locale: "de-DE") == once)
	}

	@Test func theSidecarIsThreeColumnsSomebodyCanFix() {
		let text = sample().write(name: "take-01", recogniser: "speech-analyzer", locale: "de-DE")
		let lines = text.components(separatedBy: "\n").filter { !$0.hasPrefix("#") && !$0.isEmpty }
		#expect(lines.count == 6)
		#expect(lines[0].hasPrefix("1.000"))
		#expect(lines[0].hasSuffix("So"))
		// The provenance is in the header, so a file found on its own still
		// says what made it.
		#expect(text.contains("speech-analyzer, de-DE"))
	}

	@Test func aCorrectedLineIsReadBack() {
		// The reason it is text: somebody opens it and fixes a misheard name.
		let corrected = """
		# cuttr transcript — take-01
		# start      end        word
		1.000      1.180      So
		1.180      1.320      the
		9.500      9.900      Doris Walter
		"""
		let back = Transcript.read(corrected)
		#expect(back.count == 3)
		#expect(back.words[2].text == "Doris Walter")
		#expect(back.words[2].start == 9.5)
	}

	// MARK: - Words into clips

	@Test func aRunOfWordsIsAClipFromTheFirstToTheLast() {
		let span = sample().span(1 ..< 4)
		#expect(span?.start == 1.180)
		#expect(span?.end == 2.310)
	}

	@Test func aSpanBeyondTheEndIsClampedRatherThanCrashing() {
		#expect(sample().span(4 ..< 99)?.end == 8.5)
		#expect(sample().span(9 ..< 9) == nil)
		#expect(Transcript().span(0 ..< 1) == nil)
	}

	@Test func aClipIsNamedAfterItsFirstWords() {
		let phrase = sample().phrase(covering: 1.05 ... 2.2)
		#expect(phrase == "So the driver installs")
		// Which is the point: this is what turns `clip-7` into a reference
		// somebody can read in the assembly file.
		#expect(Slug.make(from: phrase) == "so-the-driver-installs")
	}

	@Test func namingStopsAtTheWordLimitAndDropsTheFullStop() {
		#expect(sample().phrase(0 ..< 5) == "So the driver installs itself")
		#expect(sample().phrase(0 ..< 6, limit: 4) == "So the driver installs")
		#expect(sample().phrase(4 ..< 5) == "itself")
		// And an umlaut becomes something an assembly file can reference.
		#expect(Slug.make(from: sample().phrase(5 ..< 6)) == "groesse")
	}

	@Test func theWordsUnderASpanAreTheOnesThatOverlapIt() {
		#expect(sample().indices(in: 1.2 ... 1.5) == 1 ..< 3)
		// A span in a pause contains nothing, which is different from
		// containing the word either side of it.
		#expect(sample().indices(in: 4.0 ... 5.0).isEmpty)
	}

	// MARK: - Following the playhead

	@Test func thePlayheadPicksOutTheWordBeingSaid() {
		#expect(sample().index(at: 1.4) == 2)
		#expect(sample().index(at: 1.0) == 0)
		// Silence is silence: nothing is being said at 5 seconds, and lighting
		// up the last word would claim otherwise.
		#expect(sample().index(at: 5) == nil)
		#expect(sample().index(at: -1) == nil)
	}

	@Test func theNearestWordIsFoundEvenInAPause() {
		#expect(sample().nearestIndex(to: 5) == 4)
		#expect(sample().nearestIndex(to: 1000) == 5)
		#expect(Transcript().nearestIndex(to: 0) == nil)
	}

	// MARK: - Find

	@Test func aPhraseIsFoundAcrossWordBoundaries() {
		#expect(sample().find("the driver") == 1 ..< 3)
		#expect(sample().find("driver installs") == 2 ..< 4)
		#expect(sample().find("nothing here") == nil)
	}

	@Test func findIgnoresCaseAccentsAndPunctuation() {
		#expect(sample().find("SO THE") == 0 ..< 2)
		#expect(sample().find("itself") == 4 ..< 5)   // the file says `itself.`
		// The file says `Größe`; both of these fold to `groesse`, which is the
		// same rule a slug is made by.
		#expect(sample().find("größe") == 5 ..< 6)
		#expect(sample().find("GRÖSSE") == 5 ..< 6)
	}

	@Test func findCarriesOnFromWhereYouAreAndThenWrapsRound() {
		let long = Transcript(words: [
			Word(start: 0, end: 1, text: "again"),
			Word(start: 1, end: 2, text: "and"),
			Word(start: 2, end: 3, text: "again"),
		])
		#expect(long.find("again", from: 0) == 0 ..< 1)
		#expect(long.find("again", from: 1) == 2 ..< 3)
		#expect(long.find("again", from: 3) == 0 ..< 1)
	}

	@Test func typingPartOfAWordFindsIt() {
		#expect(sample().find("driv") == 2 ..< 3)
	}
}
