import AppKit
import CuttrCompose
import Testing
@testable import CuttrUI

/// What a spinner's row in the programme list says on its first line.
///
/// The line the eye goes to first, and the one that was blank: the properties
/// panel adds a word empty and waits to be typed into, so a spinner can have
/// words and still have nothing to say. A row with an empty first line reads as
/// a broken row rather than as a spinner, which is what this is about.
@Suite @MainActor struct SpinnerRowTests {

	private typealias Row = ProgrammePanel.OverlayRow

	@Test func aSpinnerThatOnlyTurnsIsNamedByItsStyle() {
		#expect(Row.said(Spinner(style: .bars)) == "spinner (bars)")
	}

	@Test func wordsAreWhatItSays() {
		#expect(Row.said(Spinner(words: [SpinnerWord("Working"), SpinnerWord("Still working")]))
			== "Working · Still working")
	}

	@Test func aWordAddedAndNotYetTypedIntoStillLeavesAName() {
		// The panel's `+` appends `SpinnerWord("")`. `words` is not empty, so
		// the old emptiness check did not catch it and the join produced "".
		#expect(Row.said(Spinner(style: .dots, words: [SpinnerWord("")])) == "spinner (dots)")
	}

	@Test func whitespaceIsNotSomethingToSay() {
		#expect(Row.said(Spinner(style: .ring, words: [SpinnerWord("  ")])) == "spinner (ring)")
	}

	@Test func emptyingOneWordOfSeveralLeavesNoStraySeparator() {
		let spinner = Spinner(words: [SpinnerWord("Working"), SpinnerWord(""), SpinnerWord("Done")])
		#expect(Row.said(spinner) == "Working · Done")
	}
}
