import AppKit
import Foundation
import Testing
@testable import CuttrKit
@testable import CuttrUI

/// The transcript as a document: laid out by its silences, with a menu that
/// does the two things this pane is for.
@MainActor @Suite struct TranscriptPaneShapeTests {

	private func pane() -> (TranscriptPane, Transcript) {
		let said = Transcript(words: [
			Word(start: 0.0, end: 0.4, text: "eins"),
			Word(start: 0.4, end: 0.8, text: "zwei"),
			Word(start: 1.4, end: 1.8, text: "drei"),
			Word(start: 4.9, end: 5.3, text: "vier"),
		])
		let pane = TranscriptPane(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
		pane.show(said, words: Words(path: "w.words", recogniser: .speechAnalyzer, locale: "de-DE"))
		return (pane, said)
	}

	@Test func aBeatIsALineAndARestIsAParagraph() {
		let (pane, _) = pane()
		let shown = pane.shownText
		#expect(shown.contains("eins zwei …\ndrei …\n\nvier"))
	}

	/// The ellipses are not words, and everything else in the pane counts in
	/// words — so the arithmetic that turns characters into a span has to skip
	/// them.
	@Test func theMarksBetweenLinesAreNotWords() {
		let (pane, said) = pane()
		var span: (start: Double, end: Double)?
		pane.onSelectWords = { span = ($0, $1) }
		let shown = pane.shownText as NSString
		pane.selectionChanged(to: NSRange(location: 0, length: shown.length))
		#expect(span?.start == said.words.first?.start)
		#expect(span?.end == said.words.last?.end)
	}

	/// Right-clicking a word with nothing selected is about the line it is in.
	@Test func theMenuIsAboutTheLineUnderThePointer() {
		let (pane, _) = pane()
		var played: (Double, Double)?
		pane.onPlayWords = { played = ($0, $1) }
		let menu = pane.menuForTest(at: 0)
		#expect(menu != nil)
		#expect(menu?.items.first?.title.contains("2 words") == true)
		if let action = menu?.items.first?.action { _ = pane.perform(action) }
		#expect(played?.0 == 0.0)
		#expect(played?.1 == 0.8)
	}

	/// And a clip of exactly those words.
	@Test func theMenuMakesAClipOfWhatItIsAbout() {
		let (pane, _) = pane()
		var clipped: (Double, Double)?
		pane.onClipWords = { clipped = ($0, $1) }
		let menu = pane.menuForTest(at: 20)
		if let action = menu?.items[1].action { _ = pane.perform(action) }
		#expect(clipped?.0 == 4.9)
		#expect(clipped?.1 == 5.3)
	}

	/// A transcript with no words has nothing to offer, and offers nothing
	/// rather than an empty menu.
	@Test func nothingSaidIsNoMenu() {
		let pane = TranscriptPane(frame: .zero)
		pane.show(Transcript(), words: nil)
		#expect(pane.menuForTest(at: 0) == nil)
	}
}
