import AppKit
import Testing
@testable import CuttrUI

/// Page Up, Page Down, Home and End move the selection.
///
/// AppKit's answer is to scroll and leave the selection where it was, which is
/// right for a document and wrong for a list somebody is choosing from: the
/// chosen row ends up off screen, the arrow keys carry on from there, and the
/// page you are looking at has nothing to do with what is selected.
@Suite @MainActor struct PagingSelectionTests {

	/// A list of forty rows with about ten on screen.
	private final class Rows: NSObject, NSTableViewDataSource {
		func numberOfRows(in tableView: NSTableView) -> Int { 40 }
	}

	private var held: Rows?

	/// In a scroll view, which is the only configuration where "a page" means
	/// anything: a table outside one sizes itself to its *content*, so asking
	/// its own height how much is on screen gives the whole list.
	private func table() -> KeyTable {
		_ = NSApplication.shared
		let table = KeyTable()
		table.addTableColumn(NSTableColumn(identifier: .init("one")))
		table.rowHeight = 20
		table.intercellSpacing = NSSize(width: 0, height: 0)
		let rows = Rows()
		table.dataSource = rows
		objc_setAssociatedObject(table, "rows", rows, .OBJC_ASSOCIATION_RETAIN)

		let scroll = TableScroll.fitting(table)
		scroll.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
		scroll.layoutSubtreeIfNeeded()
		table.reloadData()
		return table
	}

	@Test func homeGoesToTheTopAndSelectsIt() {
		let table = table()
		table.selectRowIndexes([20], byExtendingSelection: false)
		table.scrollToBeginningOfDocument(nil)
		#expect(table.selectedRow == 0, "Home scrolled without choosing anything")
	}

	@Test func endGoesToTheBottomAndSelectsIt() {
		let table = table()
		table.selectRowIndexes([0], byExtendingSelection: false)
		table.scrollToEndOfDocument(nil)
		#expect(table.selectedRow == 39, "End scrolled without choosing anything")
	}

	@Test func pageDownMovesTheSelectionDown() {
		let table = table()
		table.selectRowIndexes([0], byExtendingSelection: false)
		table.scrollPageDown(nil)
		#expect(table.selectedRow > 0, "Page Down scrolled without choosing anything")
		#expect(table.selectedRow < 39, "Page Down went to the end rather than a page")
	}

	@Test func pageUpMovesTheSelectionUp() {
		let table = table()
		table.selectRowIndexes([30], byExtendingSelection: false)
		table.scrollPageUp(nil)
		#expect(table.selectedRow < 30)
		#expect(table.selectedRow > 0, "Page Up went to the top rather than a page")
	}

	/// Clamped rather than crashing off the end.
	@Test func pagingPastEitherEndStopsThere() {
		let table = table()
		table.selectRowIndexes([1], byExtendingSelection: false)
		table.scrollPageUp(nil)
		#expect(table.selectedRow == 0)

		table.selectRowIndexes([38], byExtendingSelection: false)
		table.scrollPageDown(nil)
		#expect(table.selectedRow == 39)
	}

	/// A page keeps a row of context, so the row that was at the bottom is at
	/// the top afterwards.
	@Test func aPageIsAlmostAScreenful() {
		let table = table()
		// Ten rows of twenty points fit in two hundred.
		#expect(table.rowsAPage == 9, "a page is \\(table.rowsAPage) rows of the ten on screen")
	}

	/// An empty list has nothing to select, and `selectRowIndexes` on one is a
	/// crash waiting for the first person with no takes.
	@Test func anEmptyListIsLeftAlone() {
		_ = NSApplication.shared
		let table = KeyTable()
		table.addTableColumn(NSTableColumn(identifier: .init("one")))
		let scroll = TableScroll.fitting(table)
		scroll.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
		scroll.layoutSubtreeIfNeeded()
		table.scrollToEndOfDocument(nil)
		table.scrollPageDown(nil)
		#expect(table.selectedRow == -1)
	}
}
