import AppKit
import CuttrKit
import Testing
@testable import CuttrUI

/// The sounds that are not words, in the pane that lays out the ones that are.
///
/// The claim being checked is that a laugh is selectable *exactly like a word*:
/// the same drag, the same span arithmetic, the same menu, the same ⏎. There
/// are three kinds of thing in that text now and the whole point of the shape
/// underneath it is that none of them is a special case.
///
/// Nothing here dispatches a key event. A key a view does not claim falls
/// through to `NSResponder` and beeps on the machine of whoever is running the
/// suite.
@MainActor @Suite struct TranscriptSoundTests {

	/// A laugh in the beat between two sentences, and applause after the last
	/// word — the two places a sound turns up that a words-only layout has no
	/// room for.
	private let laugh = SoundEvent(kind: "laughter", start: 0.9, end: 1.3, confidence: 0.83)
	private let clap = SoundEvent(kind: "applause", start: 6.0, end: 7.0, confidence: 0.7)

	private func pane() -> TranscriptPane {
		_ = NSApplication.shared
		let said = Transcript(words: [
			Word(start: 0.0, end: 0.4, text: "eins"),
			Word(start: 0.4, end: 0.8, text: "zwei"),
			Word(start: 1.4, end: 1.8, text: "drei"),
			Word(start: 4.9, end: 5.3, text: "vier"),
		])
		let pane = TranscriptPane(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
		pane.show(said, words: Words(path: "w.words", recogniser: .speechAnalyzer, locale: "de-DE"),
		          sounds: [laugh, clap])
		return pane
	}

	// MARK: - Where they sit

	/// In brackets, where they happened. The label is asked for rather than
	/// spelled out, because it is in the reader's language and the suite runs
	/// on machines set to more than one.
	@Test func aSoundSitsInlineWhereItHappened() {
		let shown = pane().shownText
		#expect(shown.contains("eins zwei …\n[\(laugh.label)] drei"))
		#expect(shown.hasSuffix("vier [\(clap.label)]"))
	}

	/// A take where nobody said anything still has its laughs in it.
	@Test func soundsWithoutWordsAreStillLaidOut() {
		_ = NSApplication.shared
		let pane = TranscriptPane(frame: .zero)
		pane.show(Transcript(), words: nil, sounds: [laugh])
		#expect(pane.shownText == "[\(laugh.label)]")
		#expect(pane.wordCount == 0)
		#expect(pane.soundCount == 1)
	}

	/// And a take with neither still says what to do about it.
	@Test func nothingHeardAndNothingSaidIsTheExplanation() {
		_ = NSApplication.shared
		let pane = TranscriptPane(frame: .zero)
		pane.show(Transcript(), words: nil, sounds: [])
		#expect(pane.shownText.hasPrefix("No words yet."))
	}

	// MARK: - Selecting one

	/// Dragging across `[laughter]` gives the laugh's own span, not the
	/// sentence beside it.
	@Test func selectingASoundGivesTheSoundsSpan() {
		let pane = self.pane()
		var span: (Double, Double)?
		pane.onSelectWords = { span = ($0, $1) }
		let shown = pane.shownText as NSString
		let bracket = shown.range(of: "[\(laugh.label)]")
		pane.selectionChanged(to: bracket)
		#expect(span?.0 == 0.9)
		#expect(span?.1 == 1.3)
	}

	/// And a drag that runs from a word across a laugh to the next word covers
	/// all three, because what is highlighted is what is played.
	@Test func aSelectionAcrossASoundIncludesIt() {
		let pane = self.pane()
		var span: (Double, Double)?
		pane.onSelectWords = { span = ($0, $1) }
		let shown = pane.shownText as NSString
		let end = shown.range(of: "drei")
		pane.selectionChanged(to: NSRange(location: 0, length: NSMaxRange(end)))
		#expect(span?.0 == 0.0)
		#expect(span?.1 == 1.8)
	}

	/// The words are still counted in words. A sound between two of them is not
	/// a word and must not shift the arithmetic that turns characters into
	/// word indices — which is exactly the bug a third parallel array invites.
	@Test func aSoundInTheMiddleDoesNotMoveTheWords() {
		let pane = self.pane()
		var span: (Double, Double)?
		pane.onSelectWords = { span = ($0, $1) }
		let shown = pane.shownText as NSString
		let drei = shown.range(of: "drei")
		pane.selectionChanged(to: drei)
		#expect(span?.0 == 1.4)
		#expect(span?.1 == 1.8)

		// And the whole document is still the whole take.
		pane.selectionChanged(to: NSRange(location: 0, length: shown.length))
		#expect(span?.0 == 0.0)
		#expect(span?.1 == 7.0)
	}

	/// Clicking one takes the playhead to it, the way clicking a word does.
	@Test func clickingASoundMovesThePlayheadToIt() {
		let pane = self.pane()
		var went: Double?
		pane.onMoveTo = { went = $0 }
		let shown = pane.shownText as NSString
		pane.selectionChanged(to: NSRange(
			location: shown.range(of: "[\(laugh.label)]").location + 1, length: 0))
		#expect(went == 0.9)
	}

	/// Playing lights it, the same way it lights the word being said — because
	/// a laugh is as much a thing that is happening now as a word is.
	@Test func thePlayheadLightsTheLaughWhileItIsLaughed() {
		let pane = self.pane()
		pane.playhead = 1.0
		#expect(pane.markedSound == 0)
		#expect(pane.markedWord == nil)
		pane.playhead = 1.5
		#expect(pane.markedWord == 2)
		#expect(pane.markedSound == nil)
	}

	// MARK: - The menu on one

	/// Right-clicking `[laughter]` is pointing at the laugh, so the menu is
	/// about the laugh — and it offers the two things this pane exists for.
	@Test func theMenuOnASoundIsAboutTheSound() {
		let pane = self.pane()
		var played: (Double, Double)?
		var clipped: (Double, Double)?
		pane.onPlayWords = { played = ($0, $1) }
		pane.onClipWords = { clipped = ($0, $1) }
		let shown = pane.shownText as NSString
		let menu = pane.menuForTest(at: shown.range(of: "[\(laugh.label)]").location + 1)
		#expect(menu?.items.first?.title.contains("[\(laugh.label)]") == true)
		if let action = menu?.items.first?.action { _ = pane.perform(action) }
		#expect(played?.0 == 0.9)
		#expect(played?.1 == 1.3)

		if let action = menu?.items[1].action { _ = pane.perform(action) }
		#expect(clipped?.0 == 0.9)
		#expect(clipped?.1 == 1.3)
	}

	/// A clip made from a laugh covers the laugh. The classifier's window
	/// brackets the event rather than trimming it, and nothing here narrows it.
	@Test func aClipMadeFromALaughCoversTheLaugh() {
		let pane = self.pane()
		var clipped: (start: Double, end: Double)?
		pane.onClipWords = { clipped = ($0, $1) }
		let shown = pane.shownText as NSString
		let menu = pane.menuForTest(at: shown.range(of: "[\(clap.label)]").location)
		if let action = menu?.items[1].action { _ = pane.perform(action) }
		let made = try! #require(clipped)
		#expect(made.start <= clap.start)
		#expect(made.end >= clap.end)
	}

	/// What a selection says, which is what a clip made from it gets named
	/// after: the words in it, or the sound when there are none.
	@Test func aSelectionOfNothingButALaughIsNamedAfterIt() {
		let pane = self.pane()
		let shown = pane.shownText as NSString
		#expect(pane.said(in: shown.range(of: "[\(laugh.label)]")) == "[\(laugh.label)]")
		#expect(pane.said(in: shown.range(of: "eins zwei")) == "eins zwei")
		// Nothing but silence has no words to be named after, and says so.
		#expect(pane.said(in: shown.range(of: "…")) == nil)
	}

	// MARK: - Redrawing

	/// The pane returns early unless something has changed, so that the
	/// window's refresh on every keystroke does not drop a selection somebody
	/// is in the middle of making. A sound arriving is something changing.
	@Test func newSoundsAreShownAndNothingElseRedraws() {
		let pane = self.pane()
		let before = pane.shownText
		pane.show(Transcript(words: [Word(start: 0.0, end: 0.4, text: "eins")]),
		          words: nil, sounds: [laugh])
		#expect(pane.shownText != before)
		#expect(pane.soundCount == 1)
	}
}
