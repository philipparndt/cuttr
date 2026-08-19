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

	override func menu(for event: NSEvent) -> NSMenu? {
		onMenu?(event) ?? super.menu(for: event)
	}
}

/// An outline that does the same. `NSOutlineView` is an `NSTableView`, but not
/// one that can be swapped for `KeyTable`, so this is the same three lines.
@MainActor
final class MenuOutline: NSOutlineView {
	var onMenu: ((NSEvent) -> NSMenu?)?

	override func menu(for event: NSEvent) -> NSMenu? {
		onMenu?(event) ?? super.menu(for: event)
	}
}
