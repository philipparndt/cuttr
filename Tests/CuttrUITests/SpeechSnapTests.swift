import AppKit
import Foundation
import Testing
@testable import CuttrKit
@testable import CuttrUI

/// Trimming against the speech rather than against the grid.
@MainActor @Suite struct SpeechSnapTests {

	private func timeline() -> (TimelineView, TakeDocument) {
		let view = TimelineView(frame: NSRect(x: 0, y: 0, width: 800, height: 200))
		let document = TakeDocument()
		try! document.setTranscript(Transcript(words: [
			Word(start: 1.0, end: 1.4, text: "eins"),
			Word(start: 1.4, end: 1.8, text: "zwei"),
			Word(start: 4.0, end: 4.4, text: "drei"),
		]), recogniser: .hand, locale: "de-DE")
		view.document = document
		view.setZoom(0.01)   // a hundredth of a second per point
		// The view holds its document weakly, so the test has to hold it.
		return (view, document)
	}

	/// Within a dozen points of a mark, that is what was meant.
	@Test func aMarkNearTheEndOfASentenceGoesToIt() {
		let (view, document) = timeline()
		_ = document
		#expect(view.speechEdge(near: 1.85) == 1.8)
		#expect(view.speechEdge(near: 3.95) == 4.0)
	}

	/// Further away than that, nobody pointed at it.
	@Test func aMarkNowhereNearOneIsLeftAlone() {
		let (view, document) = timeline()
		_ = document
		#expect(view.speechEdge(near: 2.6) == nil)
	}

	/// A take with no words has nothing to aim at, and the trim behaves as it
	/// always did.
	@Test func withNoWordsThereIsNothingToSnapTo() {
		let view = TimelineView(frame: NSRect(x: 0, y: 0, width: 800, height: 200))
		view.document = TakeDocument()
		#expect(view.speechEdge(near: 1.85) == nil)
	}
}
