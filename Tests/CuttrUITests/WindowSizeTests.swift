import AppKit
import CuttrCompose
import CuttrKit
import Testing
@testable import CuttrUI

/// The window has to be resizable.
///
/// A required constraint that pins content to every edge *and* states an exact
/// size gives the window a minimum equal to its maximum, and then nothing about
/// it can be dragged. That is a thing to find here rather than by trying to
/// drag the corner.
@Suite @MainActor struct WindowSizeTests {

	private func fits(_ content: NSView, _ size: NSSize) -> Bool {
		let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
		                      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
		_ = NSApplication.shared
		window.contentView = content
		window.setContentSize(size)
		window.layoutIfNeeded()
		let got = window.contentView?.frame.size ?? .zero
		return abs(got.width - size.width) < 1 && abs(got.height - size.height) < 1
	}

	@Test func theProjectEditorTakesTheSizeItIsGiven() {
		let inspector = ProjectInspector()
		inspector.reload(Project(), vocabulary: ComposeDocument.Vocabulary())
		#expect(fits(inspector, NSSize(width: 1400, height: 900)))
		#expect(fits(inspector, NSSize(width: 1000, height: 700)))
	}

	@Test func thePropertiesPanelTakesTheSizeItIsGiven() {
		let panel = PropertiesPanel()
		panel.reload(Project(), vocabulary: ComposeDocument.Vocabulary(), selection: .output)
		#expect(fits(panel, NSSize(width: 900, height: 800)))
		#expect(fits(panel, NSSize(width: 320, height: 400)))
	}

	@Test func theProgrammePanelTakesTheSizeItIsGiven() {
		let panel = ProgrammePanel()
		panel.reload(Project(), vocabulary: ComposeDocument.Vocabulary())
		#expect(fits(panel, NSSize(width: 1100, height: 900)))
		#expect(fits(panel, NSSize(width: 400, height: 400)))
	}

	/// The window the application actually opens.
	@Test func theComposeWindowResizes() {
		_ = NSApplication.shared
		let controller = ComposeWindowController(document: ComposeDocument())
		guard let window = controller.window else { return }
		window.setContentSize(NSSize(width: 1500, height: 950))
		window.layoutIfNeeded()
		#expect(window.contentView?.frame.width ?? 0 >= 1400)
		#expect(window.contentView?.frame.height ?? 0 >= 900)
	}

	@Test func theLibraryTakesTheSizeItIsGiven() {
		let library = LibraryView()
		library.reload(ComposeDocument.Vocabulary())
		#expect(fits(library, NSSize(width: 500, height: 700)))
	}
}
