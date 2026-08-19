import AppKit
import CuttrCompose
import CuttrKit
import Testing
@testable import CuttrUI

/// Dragging the overlay on the picture, and its ranges on the programme.
///
/// The bug both of these are about: a field being typed into stops the panel
/// reloading, because otherwise the file would come back mid-word and take the
/// cursor with it. A drag on a picture does not move the focus by itself, so it
/// wrote a new value into a form that had been told not to look, and the
/// numbers beside the picture never changed.
@Suite @MainActor struct DragTests {

	private func project() -> Project {
		Project(
			timeline: [TimelineEntry(clip: ClipReference("intro"))],
			overlays: [Overlay(kind: .spinner(Spinner()),
			                   spans: [.times(from: 1, to: 4)],
			                   anchor: nil, offset: CGPoint(x: 0, y: 0))])
	}

	private func panel(_ project: Project) -> (PropertiesPanel, NSWindow) {
		_ = NSApplication.shared
		let panel = PropertiesPanel()
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 800),
		                      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
		window.contentView = panel
		panel.reload(project, vocabulary: ComposeDocument.Vocabulary(), selection: .overlay(0))
		panel.layoutSubtreeIfNeeded()
		return (panel, window)
	}

	private func find<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
		view.subviews.flatMap { subview -> [T] in
			((subview as? T).map { [$0] } ?? []) + find(type, in: subview)
		}
	}

	/// Every number the panel is showing.
	private func numbers(_ panel: NSView) -> [String] {
		find(NSTextField.self, in: panel).filter { $0.isEditable }.map(\.stringValue)
	}

	@Test func draggingTheOverlayChangesTheOffsetShown() {
		var project = self.project()
		let (panel, window) = self.panel(project)
		panel.onChange = { project = $0 }

		// Somebody clicked into a field first, which is the state the bug needed.
		if let field = find(NSTextField.self, in: panel).first(where: { $0.isEditable }) {
			window.makeFirstResponder(field)
		}

		let preview = find(FramePreview.self, in: panel).first
		#expect(preview != nil)
		preview?.onMove?(CGPoint(x: 0.75, y: 0.25))

		#expect(project.overlays[0].offset.x == 0.25)
		#expect(project.overlays[0].offset.y == -0.25)

		panel.reload(project, vocabulary: ComposeDocument.Vocabulary(), selection: .overlay(0))
		panel.layoutSubtreeIfNeeded()
		#expect(numbers(panel).contains("0.25"), "the offset shown is \(numbers(panel))")
	}

	@Test func draggingARangeChangesTheTimesShown() {
		var project = self.project()
		let (panel, window) = self.panel(project)
		panel.onChange = { project = $0 }
		if let field = find(NSTextField.self, in: panel).first(where: { $0.isEditable }) {
			window.makeFirstResponder(field)
		}

		let strip = find(SpanStrip.self, in: panel).first
		#expect(strip != nil)
		strip?.onDrag?(0, 6, 9)

		#expect(project.overlays[0].spans == [.times(from: 6, to: 9)])

		panel.reload(project, vocabulary: ComposeDocument.Vocabulary(), selection: .overlay(0))
		panel.layoutSubtreeIfNeeded()
		#expect(numbers(panel).contains(Timecode.string(6)), "the times shown are \(numbers(panel))")
	}
}
