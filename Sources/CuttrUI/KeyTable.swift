import AppKit

/// A table that hands its key presses somewhere before answering them itself.
///
/// `NSTableView` deals with the arrows by moving the selection, which is right
/// for a list and wrong for a list of sections: left and right should fold and
/// unfold. Subclassing to ask first is the smallest way to get both — the
/// answer is "did somebody else deal with it", and anything unclaimed behaves
/// exactly as a table always has.
@MainActor
final class KeyTable: NSTableView {
	var onKey: ((NSEvent) -> Bool)?
	/// And the same for a right-click, for the same reason: the list knows
	/// where the pointer is, and what is under it belongs to whoever filled the
	/// list in.
	var onMenu: ((NSEvent) -> NSMenu?)?

	override func keyDown(with event: NSEvent) {
		if onKey?(event) == true { return }
		super.keyDown(with: event)
	}

	/// Clicking a row puts the keyboard in this list.
	///
	/// Said out loud rather than left to AppKit, which is what every other view
	/// in this program that answers a click already does — the timeline, the
	/// span strip, the scene stage, the big picture. The takes list never came
	/// up lit: the row selected, so the click was arriving, and the keyboard
	/// stayed wherever it had been — so the arrow keys went on moving something
	/// else while the row that looked chosen was not the one they moved.
	///
	/// Before `super`, so the selection this click is about to make is drawn
	/// emphasised the first time it is drawn rather than a moment later.
	override func mouseDown(with event: NSEvent) {
		if window?.firstResponder !== self { window?.makeFirstResponder(self) }
		super.mouseDown(with: event)
	}


	// Page Up, Page Down, Home and End move the selection. See the extension at
	// the foot of this file for why.
	override func scrollPageUp(_ sender: Any?) { selectAndShow(rowAPageAway(-1)) }
	override func scrollPageDown(_ sender: Any?) { selectAndShow(rowAPageAway(1)) }
	override func scrollToBeginningOfDocument(_ sender: Any?) { selectAndShow(0) }
	override func scrollToEndOfDocument(_ sender: Any?) { selectAndShow(numberOfRows - 1) }

	override func menu(for event: NSEvent) -> NSMenu? {
		onMenu?(event) ?? super.menu(for: event)
	}

	/// One column, as wide as the list.
	///
	/// `NSTableColumn` starts at a hundred points and `uniformColumnAutoresizing`
	/// only redistributes width when the table is *resized* — a table given its
	/// size by Auto Layout, as every list here is, may never be. So a cell drawn
	/// against `bounds.maxX` had a hundred points to work with in a pane three
	/// times that: in the document switcher there was no room left for a path
	/// after the name, so most rows showed none and a couple showed four
	/// characters of one.
	override func layout() {
		super.layout()
		guard tableColumns.count == 1 else { return }
		// The *visible* width, from the scroll view rather than from this
		// table's own bounds: the table's width follows its columns, so sizing
		// a column to it is a circle that ends up wider than the pane and
		// clipped. `contentSize` is what the clip view will show, scrollers
		// taken off.
		let want = max(40, enclosingScrollView?.contentSize.width ?? bounds.width)
		if abs(tableColumns[0].width - want) > 0.5 { tableColumns[0].width = want }
	}
}

/// An outline that does the same. `NSOutlineView` is an `NSTableView`, but not
/// one that can be swapped for `KeyTable`, so this is the same three lines.
@MainActor
final class MenuOutline: NSOutlineView {
	var onMenu: ((NSEvent) -> NSMenu?)?
	var onKey: ((NSEvent) -> Bool)?

	// Page Up, Page Down, Home and End move the selection. See the extension at
	// the foot of this file for why.
	override func scrollPageUp(_ sender: Any?) { selectAndShow(rowAPageAway(-1)) }
	override func scrollPageDown(_ sender: Any?) { selectAndShow(rowAPageAway(1)) }
	override func scrollToBeginningOfDocument(_ sender: Any?) { selectAndShow(0) }
	override func scrollToEndOfDocument(_ sender: Any?) { selectAndShow(numberOfRows - 1) }

	override func menu(for event: NSEvent) -> NSMenu? {
		onMenu?(event) ?? super.menu(for: event)
	}

	override func keyDown(with event: NSEvent) {
		if onKey?(event) == true { return }
		super.keyDown(with: event)
	}
}

/// Whether a key press is one of the two deletes.
///
/// Both, because a full keyboard has a forward delete and somebody who reaches
/// for it means the same thing. `NSEvent`'s character constants rather than key
/// codes: a key code is a position on a keyboard, and these two are not in the
/// same position on every one.
@MainActor
func isDelete(_ event: NSEvent) -> Bool {
	guard let key = event.charactersIgnoringModifiers?.unicodeScalars.first else { return false }
	return key == Unicode.Scalar(NSDeleteCharacter)
		|| key == Unicode.Scalar(NSBackspaceCharacter)
		|| key == Unicode.Scalar(NSDeleteFunctionKey)!
}

// MARK: - Paging moves the selection

/// What Page Up, Page Down, Home and End do in a list.
///
/// AppKit's answer is to scroll and leave the selection where it was, which is
/// right for a document and wrong for a list of things you are choosing between:
/// the row that is chosen ends up off screen, the arrow keys carry on from
/// there, and the page you are looking at has nothing to do with what is
/// selected. Every list in this program is a list somebody is picking from.
///
/// So the keys move the selection and bring it into view, which is what the
/// arrows already do — these are the same gesture at a coarser grain.
extension NSTableView {

	/// How many whole rows are on screen at once.
	var rowsAPage: Int {
		let step = rowHeight + intercellSpacing.height
		guard step > 0 else { return 1 }
		// The scroll view's, not this table's: a table sizes itself to its
		// *content*, so its own height is the length of the whole list and a
		// page worked out from it is "everything".
		let visible = enclosingScrollView?.contentView.bounds.height ?? visibleRect.height
		// One less than fits, so a page keeps a row of context — the row that
		// was at the bottom is at the top afterwards, which is how somebody
		// keeps their place. Never less than one, or the keys would do nothing.
		return max(1, Int(visible / step) - 1)
	}

	/// Where a paging key should land, counted from the selection rather than
	/// from what is scrolled into view: the selection is the thing being moved.
	func rowAPageAway(_ direction: Int) -> Int {
		let from = selectedRow >= 0 ? selectedRow : (direction > 0 ? -1 : numberOfRows)
		return from + direction * rowsAPage
	}

	/// Selects a row, clamped to the list, and shows it. Nothing at all for an
	/// empty list — `selectRowIndexes` on one is a crash waiting for the first
	/// person with no takes.
	func selectAndShow(_ wanted: Int) {
		guard numberOfRows > 0 else { return }
		let row = max(0, min(wanted, numberOfRows - 1))
		selectRowIndexes([row], byExtendingSelection: false)
		scrollRowToVisible(row)
	}
}
