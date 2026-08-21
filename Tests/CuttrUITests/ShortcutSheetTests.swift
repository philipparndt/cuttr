import AppKit
import Foundation
import Testing
@testable import CuttrUI

/// The list of keys, and the window that holds it.
///
/// It was an alert with the list in `informativeText`: proportional font over
/// text that is aligned with spaces, no scrolling, and modal. Every column was
/// torn apart and two thirds of it was off the bottom of the screen.
@MainActor @Suite struct ShortcutSheetTests {

	/// The keys stay monospaced — that is what makes the columns line up — and
	/// only the headings differ, so nothing moves sideways.
	@Test func theKeysAreFixedWidthAndTheHeadingsAreNot() {
		let laid = ShortcutsPanel.laidOut("Playing\n  space        play / pause\n")
		let text = laid.string
		guard let headingAt = text.range(of: "Playing"),
		      let keyAt = text.range(of: "space") else {
			Issue.record("the lines did not come through")
			return
		}
		let heading = laid.attribute(
			.font, at: text.distance(from: text.startIndex, to: headingAt.lowerBound),
			effectiveRange: nil) as? NSFont
		let key = laid.attribute(
			.font, at: text.distance(from: text.startIndex, to: keyAt.lowerBound),
			effectiveRange: nil) as? NSFont
		#expect(key == Theme.mono)
		#expect(heading != Theme.mono)
	}

	/// A heading is a line that starts at the margin and every key is indented,
	/// so the list's own shape says which is which — the sheet needs no markup
	/// and stays something somebody can read in the source.
	@Test func indentationIsWhatMarksAKey() {
		let laid = ShortcutsPanel.laidOut("Cutting\n  S  or  ⌘B    split here\nnot indented\n")
		let text = laid.string
		func font(before word: String) -> NSFont? {
			guard let at = text.range(of: word) else { return nil }
			return laid.attribute(.font, at: text.distance(from: text.startIndex,
			                                               to: at.lowerBound),
			                      effectiveRange: nil) as? NSFont
		}
		#expect(font(before: "Cutting") != Theme.mono)
		#expect(font(before: "S  or") == Theme.mono)
		#expect(font(before: "not indented") != Theme.mono)
	}

	/// Every line survives, in order. A reference that quietly drops a row is
	/// worse than one that is ugly.
	@Test func nothingIsLost() {
		let sheet = MainMenu.shortcutSheet
		let laid = ShortcutsPanel.laidOut(sheet)
		#expect(laid.string.components(separatedBy: "\n").count
			== sheet.components(separatedBy: "\n").count + 1)
		#expect(laid.string.contains("play / pause"))
		#expect(laid.string.contains("zoom out / in"))
	}

	/// It scrolls, it resizes, and it is not modal — the point of looking up a
	/// key is to use it.
	@Test func theWindowCanHoldTheList() {
		_ = NSApplication.shared
		ShortcutsPanel.present(MainMenu.shortcutSheet)
		guard let panel = NSApp.windows.compactMap({ $0 as? ShortcutsPanel }).first else {
			Issue.record("no panel")
			return
		}
		defer { panel.close() }
		#expect(panel.styleMask.contains(.resizable))
		#expect(panel.styleMask.contains(.closable))
		let scrolls = panel.contentView?.subviews.contains {
			($0 as? NSScrollView)?.hasVerticalScroller == true
		}
		#expect(scrolls == true)

		// Asked twice, it is the same window rather than a second one.
		ShortcutsPanel.present(MainMenu.shortcutSheet)
		#expect(NSApp.windows.compactMap { $0 as? ShortcutsPanel }.count == 1)
	}
}
