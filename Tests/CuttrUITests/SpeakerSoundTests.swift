import AppKit
import CuttrKit
import Testing
@testable import CuttrUI

/// Speakers and sounds in the same pane.
///
/// The two features arrived separately and both restructured this text. What is
/// checked here is that they compose: a name is a fourth kind of piece
/// alongside a word, a pause and a sound, and none of the four is a special
/// case in the selection arithmetic.
///
/// Nothing here dispatches a key event. A key a view does not claim falls
/// through to `NSResponder` and beeps on the machine of whoever is running the
/// suite.
@MainActor @Suite struct SpeakerSoundTests {

	private let laugh = SoundEvent(kind: "laughter", start: 0.85, end: 1.15, confidence: 0.8)
	private let cast = [Speaker(slug: "papa", name: "Papa"), Speaker(slug: "mia", name: "Mia")]

	/// A question, a laugh in the beat after it, then the answer — which is
	/// what an interview with a child in it actually sounds like.
	private func said() -> Transcript {
		var said = Transcript(words: [
			Word(start: 0.0, end: 0.4, text: "Wie"),
			Word(start: 0.4, end: 0.8, text: "geht's?"),
			Word(start: 1.4, end: 1.8, text: "Gut."),
			Word(start: 1.8, end: 2.2, text: "Und"),
			Word(start: 2.2, end: 2.6, text: "sonst?"),
		])
		said.assign("papa", to: 0 ..< 2)
		said.assign("mia", to: 2 ..< 3)
		said.assign("papa", to: 3 ..< 6)
		return said
	}

	private func pane(_ transcript: Transcript? = nil, sounds: [SoundEvent]? = nil,
	                  cast: [Speaker]? = nil) -> TranscriptPane {
		_ = NSApplication.shared
		let pane = TranscriptPane(frame: NSRect(x: 0, y: 0, width: 460, height: 300))
		pane.show(transcript ?? said(),
		          words: Words(path: "w.words", recogniser: .speechAnalyzer, locale: "de-DE"),
		          sounds: sounds ?? [laugh], cast: cast ?? self.cast)
		return pane
	}

	// MARK: - Where things sit

	/// The name heads the line and the laugh sits on it, after the name rather
	/// than before it — otherwise the sound would start at the margin and the
	/// column of names would stop lining up two lines in.
	@Test func aSoundSitsUnderTheNameOfTheLineItIsOn() {
		let shown = pane().shownText
		#expect(shown == "Papa Wie geht's? …\nMia  [\(laugh.label)] Gut.\nPapa Und sonst?")
	}

	/// The name says who was *speaking*. Nobody has claimed the laugh, so it
	/// keeps its own colour under somebody else's name.
	@Test func aSoundKeepsItsOwnColourUnderSomebodysName() {
		let pane = pane()
		let colours = Speaker.colors(for: ["papa", "mia"])
		#expect(pane.colourOfWord(2) == Theme.speakerText(colours["mia"]!))
		#expect(pane.colourOfSound(0) == Theme.heardNotSaid)
	}

	/// A sound is still selectable exactly like a word when there is a column
	/// of names beside it.
	@Test func aSoundIsStillAboutItselfWithNamesInTheText() {
		let pane = pane()
		let at = pane.shownText.distance(
			from: pane.shownText.startIndex,
			to: pane.shownText.range(of: "[\(laugh.label)]")!.lowerBound)
		var played: (Double, Double)?
		pane.onPlayWords = { played = ($0, $1) }
		let menu = pane.menuForTest(at: at + 1)
		#expect(menu?.items.first?.title.contains("[\(laugh.label)]") == true)
		if let action = menu?.items.first?.action { _ = pane.perform(action) }
		#expect(played?.0 == laugh.start)
		#expect(played?.1 == laugh.end)
	}

	// MARK: - A name is the line

	/// Clicking a name points at the line it heads, not at the end of the line
	/// above it — which is the word that happens to sit before it in the text.
	@Test func clickingANamePointsAtItsOwnLine() {
		let pane = pane()
		var moved: Double?
		pane.onMoveTo = { moved = $0 }
		// The `M` of `Mia`, at the head of the second line.
		let at = pane.shownText.distance(
			from: pane.shownText.startIndex,
			to: pane.shownText.range(of: "Mia")!.lowerBound)
		pane.selectionChanged(to: NSRange(location: at, length: 0))
		#expect(moved == 1.4)
	}

	/// And so does a keystroke, which is the reason it matters: the number keys
	/// name the line under the caret, and naming the line above the one
	/// somebody is looking at would be worse than doing nothing.
	@Test func aKeystrokeInANameNamesThatLine() {
		let pane = pane()
		let at = pane.shownText.distance(
			from: pane.shownText.startIndex,
			to: pane.shownText.range(of: "Mia")!.lowerBound)
		pane.selectForTest(NSRange(location: at + 1, length: 0))
		#expect(pane.caretWord == 2)

		var asked: (Range<Int>, String?)?
		pane.onAssign = { asked = ($0, $1) }
		pane.assignFromKey(1)
		#expect(asked?.0 == 2 ..< 3)
		#expect(asked?.1 == "papa")
	}

	/// Selecting a name selects its line, so the menu and the in/out marks are
	/// about the words rather than about a label.
	@Test func selectingANameSelectsItsLine() {
		let pane = pane()
		let at = pane.shownText.distance(
			from: pane.shownText.startIndex,
			to: pane.shownText.range(of: "Papa Und")!.lowerBound)
		let touched = pane.touched(by: NSRange(location: at, length: 4))
		#expect(touched?.words == 3 ..< 5)
		#expect(touched?.start == 1.8)
		#expect(touched?.end == 2.6)
	}

	// MARK: - A sentence break is not a pause

	/// Two lines split by a full stop have no silence between them, so there is
	/// nothing there to select — while a real gap still leaves an ellipsis that
	/// is a stretch of the take.
	@Test func onlyARealSilenceLeavesSomethingToPointAt() {
		let pane = pane(said(), sounds: [])
		let shown = pane.shownText
		// One ellipsis, after the question, where the 600 ms gap is.
		#expect(shown.filter { $0 == "…" }.count == 1)
		// And none between `Gut.` and `Und`, which are touching.
		#expect(shown.contains("Gut.\nPapa Und"))
	}

	/// The whole line, when a line wraps, hangs under the words and not under
	/// the name. Checked as the attribute rather than by measuring glyphs.
	@Test func aWrappedLineHangsUnderTheWords() {
		#expect((pane().paragraphStyleAtStart?.headIndent ?? 0) > 0)
		// And a take nobody has named has no indent to hang under.
		let plain = pane(Transcript(words: said().words.map {
			Word(start: $0.start, end: $0.end, text: $0.text)
		}), sounds: [], cast: [])
		#expect((plain.paragraphStyleAtStart?.headIndent ?? 0) == 0)
	}
}
