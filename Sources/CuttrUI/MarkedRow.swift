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
/// `isEmphasized` is pinned off because AppKit's emphasised highlight is the
/// saturated one, and whether a table happens to be the first responder is not
/// something anybody wants the loudest thing on screen to depend on.
@MainActor
final class MarkedRow: NSTableRowView {

	override func drawSelection(in dirtyRect: NSRect) {
		guard selectionHighlightStyle != .none else { return }
		Theme.selected.setFill()
		bounds.fill()
		Theme.accent.setFill()
		NSRect(x: 0, y: 2, width: 2, height: max(0, bounds.height - 4)).fill()
	}

	override var isEmphasized: Bool {
		get { false }
		set { _ = newValue }
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
