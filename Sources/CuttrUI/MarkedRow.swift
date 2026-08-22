import AppKit

/// A selected row: a mark, and a ground a shade lighter.
///
/// It was the system's own highlight — a full-width bar of saturated blue, which
/// was the loudest thing on the screen for the least information in it. Every
/// list in this program is a list of *named things*, and the names carry hue:
/// green is a clip, amber a tag, teal a list, violet a section, rose a spinner.
/// A blue bar under all of them takes the one signal that means something and
/// paints over it.
///
/// So selection is said the way selection is said in this program everywhere
/// now: in value rather than in hue. The row lifts, and a two-point mark down
/// its leading edge is the part that reads from across the desk.
///
/// **Focus is said too, and used not to be.** `isEmphasized` was pinned off, so
/// a row looked the same whether or not its list had the keyboard — and a
/// window full of lists where none of them says which one the arrow keys will
/// move is a window somebody has to guess at. The objection that put it there
/// was to AppKit's *emphasised* highlight, a bar of saturated blue that paints
/// over the one hue carrying meaning. That objection is answered by drawing the
/// selection here rather than by refusing to know: lit is the same steel as the
/// mark, a shade up in value, and every hue still reads through it.
@MainActor
final class MarkedRow: NSTableRowView {

	override func drawSelection(in dirtyRect: NSRect) {
		guard selectionHighlightStyle != .none else { return }
		let lit = isEmphasized
		(lit ? Theme.selectedFocused : Theme.selected).setFill()
		bounds.fill()
		// The mark is the part that reads from across the desk, so it carries
		// the difference as well: full strength for the list with the keyboard,
		// held back for the ones without.
		Theme.accent.withAlphaComponent(lit ? 1 : 0.55).setFill()
		NSRect(x: 0, y: 2, width: lit ? 3 : 2, height: max(0, bounds.height - 4)).fill()
	}

	/// The one every list makes, so there is one place this is decided.
	static func make(in table: NSTableView) -> NSTableRowView {
		if let found = table.makeView(withIdentifier: identifier, owner: nil) as? MarkedRow {
			return found
		}
		let made = MarkedRow()
		made.identifier = identifier
		return made
	}

	private static let identifier = NSUserInterfaceItemIdentifier("marked-row")
}
