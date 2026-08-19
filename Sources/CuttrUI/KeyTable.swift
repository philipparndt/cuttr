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

	override func keyDown(with event: NSEvent) {
		if onKey?(event) == true { return }
		super.keyDown(with: event)
	}
}
