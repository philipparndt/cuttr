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

	/// The cutting window, with four panes down its right-hand side.
	///
	/// Each of them states a required minimum height, and a fourth one was
	/// added when the transcript arrived. Four required minimums that together
	/// exceed the column would be constraints autolayout cannot satisfy, which
	/// it announces by breaking one at random and logging about it — at the
	/// smallest size the window will go to, which is where this asks.
	@Test func theCuttingWindowFitsItsPanesAtTheSmallestSizeItAllows() {
		_ = NSApplication.shared
		let controller = MainWindowController(document: TakeDocument())
		guard let window = controller.window else { return }
		window.setContentSize(window.minSize)
		window.layoutIfNeeded()
		#expect(window.contentView?.frame.height ?? 0 > 0)
		window.setContentSize(NSSize(width: 1600, height: 1000))
		window.layoutIfNeeded()
		#expect(window.contentView?.frame.width ?? 0 >= 1500)
		window.close()
	}

	@Test func theLibraryTakesTheSizeItIsGiven() {
		let library = LibraryView()
		library.reload(ComposeDocument.Vocabulary())
		#expect(fits(library, NSSize(width: 500, height: 700)))
	}
}

/// Dragging a divider, and the pane staying where it was put.
///
/// A split view moves the frames when a divider is dragged, and autolayout puts
/// them back on the next pass: the preferred-width constraint is the only thing
/// that says how wide the tree is, so however low its priority it wins and the
/// pane springs back. Following the drag is what makes the divider work at all.
@Suite @MainActor struct SplitResizeTests {

	@Test func theTreeKeepsTheWidthItIsDraggedTo() {
		_ = NSApplication.shared
		let inspector = ProjectInspector()
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 800),
		                      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
		window.contentView = inspector
		inspector.reload(Project(timeline: [TimelineEntry(clip: ClipReference("intro"))]),
		                 vocabulary: ComposeDocument.Vocabulary())
		inspector.layoutSubtreeIfNeeded()

		func split(in view: NSView) -> NSSplitView? {
			for subview in view.subviews {
				if let found = subview as? NSSplitView { return found }
				if let found = split(in: subview) { return found }
			}
			return nil
		}
		guard let split = split(in: inspector), split.arrangedSubviews.count == 2 else {
			Issue.record("no split view")
			return
		}
		// It opens where it always has.
		#expect(abs(split.arrangedSubviews[0].frame.width - 440) < 2,
		        "opens at \(split.arrangedSubviews[0].frame.width)")

		// A drag, as AppKit reports one: the position under the pointer.
		_ = (split.delegate)?.splitView?(split, constrainSplitPosition: 600, ofSubviewAt: 0)
		split.setPosition(600, ofDividerAt: 0)
		inspector.layoutSubtreeIfNeeded()
		#expect(abs(split.arrangedSubviews[0].frame.width - 600) < 2,
		        "the tree sprang back to \(split.arrangedSubviews[0].frame.width)")

		// And it stays there through the next layout, which is where it used to
		// go back.
		inspector.frame = NSRect(x: 0, y: 0, width: 1380, height: 800)
		inspector.layoutSubtreeIfNeeded()
		#expect(abs(split.arrangedSubviews[0].frame.width - 600) < 4,
		        "and again after a relayout: \(split.arrangedSubviews[0].frame.width)")
	}
}
