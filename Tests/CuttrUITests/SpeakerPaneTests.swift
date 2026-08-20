import AppKit
import Foundation
import Testing
@testable import CuttrKit
@testable import CuttrUI

/// Who is speaking, in the pane: a name at the head of every line, a number
/// that assigns it, and a guess that looks like a guess.
@MainActor @Suite struct SpeakerPaneTests {

	/// Four lines, split on the full stops — a question, an answer, a question,
	/// an answer, which is what an interview is.
	private func said() -> Transcript {
		Transcript(words: [
			Word(start: 0.0, end: 0.4, text: "Wie"),
			Word(start: 0.4, end: 0.8, text: "geht's?"),
			Word(start: 0.8, end: 1.2, text: "Gut."),
			Word(start: 1.2, end: 1.6, text: "Und"),
			Word(start: 1.6, end: 2.0, text: "sonst?"),
			Word(start: 2.0, end: 2.4, text: "Auch."),
		])
	}

	private let cast = [Speaker(slug: "papa", name: "Papa"), Speaker(slug: "mia", name: "Mia")]

	private func pane(_ transcript: Transcript? = nil,
	                  cast: [Speaker]? = nil,
	                  suggestions: [Int: String] = [:]) -> TranscriptPane {
		let pane = TranscriptPane(frame: NSRect(x: 0, y: 0, width: 420, height: 300))
		pane.show(transcript ?? said(),
		          words: Words(path: "w.words", recogniser: .speechAnalyzer, locale: "de-DE"),
		          cast: cast ?? self.cast, suggestions: suggestions)
		return pane
	}

	// MARK: - What is drawn

	/// A take nobody has labelled looks exactly as it did: no column of names,
	/// no indent, nothing to explain.
	///
	/// And no ellipses either, because these four lines are divided by full
	/// stops rather than by silence — there is no pause between them to draw,
	/// and drawing one would offer somebody a stretch of the take to select
	/// that does not exist.
	@Test func nobodyNamedIsTheOldLayout() {
		#expect(pane().shownText == "Wie geht's?\nGut.\nUnd sonst?\nAuch.")
	}

	/// A silence between two lines is still an ellipsis, and still something
	/// the pointer can be about.
	@Test func aRealSilenceIsStillDrawnAndStillSelectable() {
		let said = Transcript(words: [
			Word(start: 0.0, end: 0.4, text: "Ja"),
			Word(start: 2.0, end: 2.4, text: "gut"),
		])
		let pane = pane(said, cast: [])
		#expect(pane.shownText == "Ja …\ngut")
		var played: (Double, Double)?
		pane.onPlayWords = { played = ($0, $1) }
		// The ellipsis, not the word beside it.
		let menu = pane.menuForTest(at: 3)
		#expect(menu?.items.first?.title.contains("this pause") == true)
		if let action = menu?.items.first?.action { _ = pane.perform(action) }
		#expect(played?.0 == 0.4)
		#expect(played?.1 == 2.0)
	}

	/// Once anybody is named, every line says who — including the ones nobody
	/// has answered yet, which is how you see what is left to do.
	@Test func everyLineSaysWhoIsSpeaking() {
		var said = said()
		said.assign("papa", from: 0)
		said.assign("mia", from: 2)
		let shown = pane(said).shownText
		#expect(shown.hasPrefix("Papa Wie geht's?\nMia  Gut.\n"))
		// The column is as wide as the longest name and no wider.
		#expect(shown.contains("\nMia  Und sonst?"))
	}

	/// Hue is not the only thing marking a speaker — the name is there in text
	/// — but the hue has to be there too, and it has to be the speaker's.
	@Test func theWordsAreDrawnInTheirSpeakersColour() {
		var said = said()
		said.assign("papa", from: 0)
		said.assign("mia", from: 2)
		let pane = pane(said)
		let colours = Speaker.colors(for: ["papa", "mia"])
		#expect(pane.colourOfWord(0) == Theme.speakerText(colours["papa"]!))
		#expect(pane.colourOfWord(2) == Theme.speakerText(colours["mia"]!))
		#expect(colours["papa"] != colours["mia"])
	}

	/// A guess is bracketed, dim, and does not get to paint the words. That is
	/// the whole difference between an offer and a record.
	@Test func aGuessLooksLikeAGuess() {
		let pane = pane(suggestions: [0: "papa", 2: "mia"])
		let shown = pane.shownText
		#expect(shown.hasPrefix("(Papa) Wie geht's?\n(Mia)  Gut."))
		// The words themselves are the ordinary text colour: nothing has been
		// decided about them.
		#expect(pane.colourOfWord(0) == Theme.text)
		#expect(pane.colourOfWord(2) == Theme.text)
	}

	/// A speaker the take has never heard of — a hand-edited sidecar — still
	/// gets a colour and a name rather than being quietly left blank.
	@Test func aSpeakerTheCastDoesNotKnowIsStillDrawn() {
		var said = said()
		said.assign("onkel", from: 0)
		let pane = pane(said, cast: [])
		#expect(pane.shownText.hasPrefix("onkel Wie geht's?"))
		#expect(pane.colourOfWord(0) != Theme.text)
	}

	/// A name longer than the column is cut rather than allowed to push the
	/// words off a narrow pane.
	@Test func aVeryLongNameIsCutToTheColumn() {
		var said = said()
		said.assign("die-grosse-schwester", from: 0)
		let pane = pane(said, cast: [Speaker(slug: "die-grosse-schwester",
		                                     name: "Die grosse Schwester")])
		#expect(pane.shownText.hasPrefix("Die grosse…  Wie"))
	}

	// MARK: - The keystroke

	/// The number on the chip is the key, and it names the line under the
	/// caret and everything after it.
	@Test func aNumberNamesTheLineUnderTheCaret() {
		let pane = pane()
		var asked: (Int, String?)?
		pane.onAssign = { asked = ($0, $1) }
		pane.selectForTest(word: 2)
		pane.assignFromKey(2)
		#expect(asked?.0 == 2)
		#expect(asked?.1 == "mia")
	}

	/// Zero is nobody, which is how a wrong answer is taken back.
	@Test func zeroIsNobody() {
		let pane = pane()
		var asked: (Int, String?)?
		pane.onAssign = { asked = ($0, $1) }
		pane.selectForTest(word: 0)
		pane.assignFromKey(0)
		#expect(asked?.0 == 0)
		#expect(asked?.1 == nil)
	}

	/// A digit with nobody behind it says so instead of quietly doing nothing
	/// — and never falls through to the clip lane it would pick elsewhere.
	@Test func aDigitWithNoSpeakerBehindItSaysSo() {
		let pane = pane()
		var asked = false
		var note = ""
		pane.onAssign = { _, _ in asked = true }
		pane.onStatus = { note = $0 }
		pane.selectForTest(word: 0)
		pane.assignFromKey(5)
		#expect(asked == false)
		#expect(note.contains("no speaker 5"))
	}

	/// The caret walks to the next line by itself, so labelling an interview
	/// is a run of keystrokes and not a run of clicks.
	@Test func theCaretWalksToTheNextLine() {
		var said = said()
		let pane = pane()
		pane.onAssign = { word, slug in
			said.assign(slug, from: word)
		}
		pane.selectForTest(word: 0)
		pane.assignFromKey(1)
		// The window would do this: the document changed, so the pane redraws.
		pane.show(said, words: Words(path: "w.words", locale: "de-DE"), cast: cast)
		#expect(pane.caretWord == 2)

		pane.assignFromKey(2)
		pane.show(said, words: Words(path: "w.words", locale: "de-DE"), cast: cast)
		#expect(said.lines.map { said.speaker(ofLine: $0) } == ["papa", "mia", "mia", "mia"])
		#expect(pane.caretWord == 3)
	}

	/// The pane only claims a key when the caret is in the words. Everywhere
	/// else `1` still picks a clip lane, which is what it has always done.
	@Test func aKeyIsDeclinedWhenTheWordsAreNotFocused() {
		let pane = pane()
		let event = NSEvent.keyEvent(
			with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
			windowNumber: 0, context: nil, characters: "1",
			charactersIgnoringModifiers: "1", isARepeat: false, keyCode: 18)!
		// No window, so nothing has the focus — and nothing is dispatched
		// anywhere either way: this asks the pane a question, it does not send
		// it a key.
		#expect(pane.handleKey(event) == false)
		#expect(pane.hasWordFocus == false)
	}

	// MARK: - The chips

	/// One chip per speaker, numbered with the key that assigns it — and, once
	/// there are two people to tell apart, the offer to work it out.
	@Test func thereIsOneChipPerSpeakerAndOneToAddAnother() {
		#expect(pane().chipTitles == ["1 Papa", "2 Mia", "Guess", "+"])
		// One speaker is nobody to tell them apart from, so there is nothing to
		// guess and nothing offered.
		#expect(pane(cast: [Speaker(slug: "mia", name: "Mia")]).chipTitles == ["1 Mia", "+"])
	}

	/// An empty cast says what to press rather than showing a bare plus.
	@Test func anEmptyCastSaysHowToStart() {
		#expect(pane(cast: []).chipTitles == ["N  Add a speaker"])
	}

	/// The offer to write the guesses down is beside the cast, and only while
	/// there are guesses.
	@Test func theGuessesCanBeKept() {
		#expect(pane(cast: [], suggestions: [0: "papa"]).chipTitles.last == "Keep 1 guess")
		#expect(pane().chipTitles.contains { $0.hasPrefix("Keep") } == false)
	}

	/// Nothing said is no chips at all: an empty pane offers to transcribe, not
	/// to name people who have not been heard.
	@Test func nothingSaidIsNoChips() {
		let pane = TranscriptPane(frame: .zero)
		pane.show(Transcript(), words: nil, cast: cast)
		#expect(pane.chipTitles.isEmpty)
	}
}
