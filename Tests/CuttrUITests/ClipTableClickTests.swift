import AppKit
import Testing
@testable import CuttrUI

/// Clicking a clip in the take editor's list picks it, and does not put a
/// caret in it.
///
/// A view-based table puts an editable `NSTextField` in every cell, and
/// AppKit's own rule is that clicking one on a row that is already selected
/// starts editing. Choosing a clip and typing into a clip are different
/// intentions, and the second arrived every time you tried the first.
@Suite @MainActor struct ClipTableClickTests {

	/// A row view that says whether the click reached it.
	private final class Spy: NSView {
		var clicked = false
		override func mouseDown(with event: NSEvent) { clicked = true }
	}

	private func click() -> NSEvent {
		NSEvent.mouseEvent(
			with: .leftMouseDown, location: NSPoint(x: 5, y: 5), modifierFlags: [],
			timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1,
			pressure: 1)!
	}

	@Test func aClickGoesThroughToTheRow() {
		let row = Spy(frame: NSRect(x: 0, y: 0, width: 200, height: 20))
		let field = RowField(frame: NSRect(x: 0, y: 0, width: 200, height: 20))
		row.addSubview(field)

		field.mouseDown(with: click())
		#expect(row.clicked, "the click was taken by the field instead of selecting the row")
	}

	/// The field stays editable — `editColumn` is how the deliberate routes
	/// work, and it does not ask `mouseDown` anything. Making the field
	/// non-editable would have fixed the click and broken renaming.
	@Test func theFieldIsStillEditable() {
		let field = RowField()
		field.isEditable = true
		#expect(field.isEditable)
	}

	/// With nowhere to send it, it behaves like any other field rather than
	/// swallowing the click.
	@Test func aFieldWithNoRowKeepsTheClick() {
		let field = RowField(frame: NSRect(x: 0, y: 0, width: 200, height: 20))
		field.mouseDown(with: click())
	}
}
