import AppKit
import Testing
@testable import CuttrUI

/// A selected row says whether its list has the keyboard.
///
/// It used not to. `isEmphasized` was pinned off, so every list in the window
/// drew its selection the same and none of them said which one the arrow keys
/// would move. The objection that put it there was to AppKit's own emphasised
/// highlight — a bar of saturated blue over the one hue carrying meaning — and
/// that is answered by drawing the selection here rather than by refusing to
/// know which list is live.
@Suite @MainActor struct SelectionFocusTests {

	/// What the row actually puts on screen, read back out of a bitmap. The
	/// only honest way to ask a `draw` what it drew.
	private func ground(emphasized: Bool) -> NSColor? {
		let row = MarkedRow(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
		row.isSelected = true
		row.isEmphasized = emphasized

		let image = NSImage(size: row.bounds.size)
		image.lockFocus()
		row.drawSelection(in: row.bounds)
		image.unlockFocus()
		guard let data = image.tiffRepresentation,
		      let bitmap = NSBitmapImageRep(data: data) else { return nil }
		// Well clear of the mark down the leading edge.
		return bitmap.colorAt(x: 100, y: 12)
	}

	@Test func aRowCanSayItHasTheKeyboard() throws {
		let lit = try #require(ground(emphasized: true))
		let dim = try #require(ground(emphasized: false))

		var litParts = (r: CGFloat(0), g: CGFloat(0), b: CGFloat(0), a: CGFloat(0))
		var dimParts = litParts
		lit.usingColorSpace(.deviceRGB)?.getRed(&litParts.r, green: &litParts.g,
		                                        blue: &litParts.b, alpha: &litParts.a)
		dim.usingColorSpace(.deviceRGB)?.getRed(&dimParts.r, green: &dimParts.g,
		                                        blue: &dimParts.b, alpha: &dimParts.a)

		#expect(litParts != dimParts, "a focused list looks the same as one without the keyboard")
	}

	/// And it is not a bar of saturated blue. The reason the old row refused to
	/// draw one is still a good reason: the hues in this program mean
	/// something, and a loud ground paints over them.
	@Test func andDoesNotShoutAboutIt() throws {
		let lit = try #require(ground(emphasized: true)?.usingColorSpace(.deviceRGB))
		var r = CGFloat(0), g = CGFloat(0), b = CGFloat(0), a = CGFloat(0)
		lit.getRed(&r, green: &g, blue: &b, alpha: &a)

		#expect(b > r, "a focused row should read cool")
		// Saturation, the cheap way: how far the widest pair of channels are
		// apart. The system's own selection blue is more than half.
		#expect(b - r < 0.3, "the focused ground is a bar of colour, not a lift in value")
		#expect(b < 0.6, "the focused ground is brighter than the text on it")
	}

	/// `isEmphasized` has to be readable at all — it was overridden to a
	/// constant, and a test that set it would have been testing nothing.
	@Test func emphasisIsNotPinnedOff() {
		let row = MarkedRow()
		row.isEmphasized = true
		#expect(row.isEmphasized, "isEmphasized is pinned off again")
	}
}

/// Clicking a list puts the keyboard in it.
///
/// The takes list never came up lit. The row selected — so the click was
/// arriving — and the keyboard stayed wherever it had been, which means the
/// arrow keys went on moving something else while the row that looked chosen
/// was not the one they moved.
@Suite @MainActor struct ListTakesTheKeyboardTests {

	private func inWindow() -> (NSWindow, KeyTable) {
		_ = NSApplication.shared
		let table = KeyTable(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
		table.addTableColumn(NSTableColumn(identifier: .init("one")))
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
		                      styleMask: [.titled], backing: .buffered, defer: false)
		let field = NSTextField(string: "somewhere else")
		let root = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
		root.addSubview(field)
		root.addSubview(table)
		window.contentView = root
		window.makeFirstResponder(field)
		return (window, table)
	}

	private func click(in table: KeyTable) -> NSEvent {
		NSEvent.mouseEvent(
			with: .leftMouseDown, location: NSPoint(x: 10, y: 10), modifierFlags: [],
			timestamp: 0, windowNumber: table.window?.windowNumber ?? 0, context: nil,
			eventNumber: 0, clickCount: 1, pressure: 1)!
	}

	@Test func aClickBringsTheKeyboardOver() {
		let (window, table) = inWindow()
		#expect(!(window.firstResponder is KeyTable), "it started with the keyboard")

		table.mouseDown(with: click(in: table))
		#expect(window.firstResponder === table, "the list did not take the keyboard")
	}

	/// And asking again when it already has it does not churn the responder,
	/// which ends editing in whatever field had it a second time over.
	@Test func askingTwiceIsQuiet() {
		let (window, table) = inWindow()
		table.mouseDown(with: click(in: table))
		table.mouseDown(with: click(in: table))
		#expect(window.firstResponder === table)
	}
}
