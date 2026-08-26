import AppKit
import Testing
@testable import CuttrCompose
@testable import CuttrRecord
@testable import CuttrUI

/// The page where a recording is made.
///
/// It was a sheet on a menu item, and the first thing that happened was somebody
/// looking for it under *New Take* and not finding it. A page is where the other
/// things this window does live, and it keeps the settings on screen while the
/// browser is open beside them.
@MainActor @Suite struct RecordPageTests {

	private func page() -> RecordPage {
		_ = NSApplication.shared
		let made = RecordPage(frame: NSRect(x: 0, y: 0, width: 640, height: 420))
		made.layoutSubtreeIfNeeded()
		return made
	}

	/// **A project that is nowhere has nowhere to put a recording** — the media
	/// lands beside the project file and the browser's profile lives in its
	/// folder. Said, rather than a button that is grey for no stated reason.
	@Test func anUnsavedProjectIsToldWhyNot() {
		let page = self.page()
		page.project = nil
		#expect(page.panelForTesting.saysForTesting.contains("Save the project first"))
		#expect(!page.panelForTesting.canRecordForTesting)
	}

	/// What the project already states is offered, so a recording that was
	/// written down is made again rather than typed again.
	@Test func theProjectsOwnRecordingsAreOffered() {
		let page = self.page()
		page.stated = [Recording(name: "install-demo", url: "https://example.com")]
		#expect(page.panelForTesting.statedNamesForTesting.contains("install-demo"))
		#expect(page.panelForTesting.recording.name == "install-demo")
	}

	/// And a project that states none is not offered a menu with one item in it.
	@Test func aProjectWithNoneIsNotOfferedAList() {
		#expect(page().panelForTesting.statedNamesForTesting.isEmpty)
	}

	/// Leaving the page is safe with nothing running — the window calls it on
	/// every page change, and a page that threw on the way out would take the
	/// window with it.
	@Test func leavingWithNothingRunningIsFine() {
		let page = self.page()
		page.left()
		page.left()
	}
}
