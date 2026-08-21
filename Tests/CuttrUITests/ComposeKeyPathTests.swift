import AppKit
import Foundation
import Testing
@testable import CuttrCompose
@testable import CuttrUI

/// The keys of the project window, through the path the keyboard takes.
///
/// The zoom and the in/out keys on the Play page were reported not working
/// three times. Each time the code that answers them was right and the key
/// never reached it — a view answering its own `keyDown` while the window's
/// monitor ate the press first, then a modifier guard that no German keyboard
/// could satisfy. Every one of those was invisible to a test that called the
/// answering function directly, so these go through `ComposeWindowController`.
@MainActor @Suite struct ComposeKeyPathTests {

	private func window() throws -> ComposeWindowController {
		_ = NSApplication.shared
		let project = try ProjectReader.read("""
			timeline:
			  - {card: 00:10.000, fill: "#101010"}
			overlays:
			  - text: over it
			    from: 00:02.000
			    to:   00:06.000
			""")
		let document = ComposeDocument(project: project)
		// Applying is what resolves, and the strip needs a programme to zoom.
		document.apply(project)
		let controller = ComposeWindowController(document: document)
		let window = controller.windowForTesting
		window.setContentSize(NSSize(width: 1400, height: 900))
		window.layoutIfNeeded()
		return controller
	}

	private func key(_ character: String, flags: NSEvent.ModifierFlags = [],
	                 code: UInt16 = 0) -> NSEvent {
		NSEvent.keyEvent(
			with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
			windowNumber: 0, context: nil, characters: character,
			charactersIgnoringModifiers: character, isARepeat: false, keyCode: code)!
	}

	/// The one that has been broken three times: pressing a zoom key with the
	/// window in front has to zoom the strip.
	@Test func aZoomKeyReachesTheTimeline() throws {
		let controller = try window()
		defer { controller.window?.close() }
		let strip = controller.stripForTesting
		strip.drawForTesting()
		let whole = strip.shownForTesting.end - strip.shownForTesting.start
		#expect(whole > 0)

		#expect(controller.handle(key("+", code: 24)))
		let after = strip.shownForTesting.end - strip.shownForTesting.start
		#expect(after < whole)

		// And out again.
		#expect(controller.handle(key("-", code: 27)))
		#expect(strip.shownForTesting.end - strip.shownForTesting.start > after)
	}

	/// German: `=` is Shift+0, which the first version of this guard threw away.
	@Test func aGermanZoomKeyReachesItToo() throws {
		let controller = try window()
		defer { controller.window?.close() }
		let strip = controller.stripForTesting
		strip.drawForTesting()
		let whole = strip.shownForTesting.end - strip.shownForTesting.start
		#expect(controller.handle(key("0", flags: .shift, code: 24)))
		#expect(strip.shownForTesting.end - strip.shownForTesting.start < whole)
	}

	/// `o` sets the selected overlay's out from the playhead, through the same
	/// path.
	@Test func oReachesTheTimeline() throws {
		let controller = try window()
		defer { controller.window?.close() }
		let strip = controller.stripForTesting
		strip.drawForTesting()
		strip.selectFirstBarForTesting()
		strip.playhead = 4
		var written: (Origin, Int, Double, Double)?
		strip.onMoveOverlay = { written = ($0, $1, $2, $3) }
		#expect(controller.handle(key("o")))
		#expect(written?.3 == 4)
	}

	/// The View menu's zooms work in this window too. They always existed —
	/// ⌘+, ⌘− and ⌘0 — and only the cutting window answered them, so here the
	/// items were greyed out and the keys that zoom a take did nothing to a
	/// programme.
	@Test func theViewMenusZoomsReachTheTimeline() throws {
		let controller = try window()
		defer { controller.window?.close() }
		let strip = controller.stripForTesting
		strip.drawForTesting()
		let whole = strip.shownForTesting.end - strip.shownForTesting.start

		controller.zoomIn(nil)
		let inned = strip.shownForTesting.end - strip.shownForTesting.start
		#expect(inned < whole)
		controller.zoomOut(nil)
		#expect(strip.shownForTesting.end - strip.shownForTesting.start > inned)
		controller.zoomIn(nil)
		controller.zoomFit(nil)
		#expect(abs(strip.shownForTesting.end - strip.shownForTesting.start - whole) < 1e-9)
	}

	/// Space is still the tape, and ⌘ still belongs to the menu.
	@Test func theWindowKeepsItsOwnKeys() throws {
		let controller = try window()
		defer { controller.window?.close() }
		#expect(controller.handle(key(" ", code: 49)))
		#expect(controller.handle(key("-", flags: .command, code: 27)) == false)
		#expect(controller.handle(key("q")) == false)
	}
}
