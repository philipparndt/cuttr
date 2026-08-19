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

/// Controls hold the position they were built with, and what they point at can
/// be gone by the time they are clicked — two taps on the same minus before the
/// form has come back is enough. Nothing here may go out of bounds.
@Suite @MainActor struct StaleControlTests {

	private func find<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
		view.subviews.flatMap { subview -> [T] in
			((subview as? T).map { [$0] } ?? []) + find(type, in: subview)
		}
	}

	@Test func pressingMinusTwiceWithoutAReloadIsHarmless() {
		_ = NSApplication.shared
		let panel = PropertiesPanel()
		var project = Project(
			timeline: [TimelineEntry(clip: ClipReference("intro"))],
			overlays: [Overlay(kind: .spinner(Spinner(words: [SpinnerWord("one")])),
			                   spans: [.times(from: 0, to: 4), .times(from: 5, to: 9)])])
		panel.onChange = { project = $0 }
		panel.reload(project, vocabulary: ComposeDocument.Vocabulary(), selection: .overlay(0))
		panel.layoutSubtreeIfNeeded()

		// Every minus in the form, twice, with no reload in between.
		for button in find(NSButton.self, in: panel).filter({ $0.title == "−" }) {
			button.performClick(nil)
			button.performClick(nil)
		}
		#expect(project.overlays[0].spans.count >= 1)
	}
}

/// Which range is being worked on survives the form being rebuilt.
///
/// The form is rebuilt whenever the project comes back, which is after every
/// edit. A rebuilt strip that selects its first range again is what "click the
/// second one and it jumps back to the first" is, from the inside.
@Suite @MainActor struct SpanSelectionTests {

	private func find<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
		view.subviews.flatMap { subview -> [T] in
			((subview as? T).map { [$0] } ?? []) + find(type, in: subview)
		}
	}

	@Test func theSelectedRangeStaysSelected() {
		_ = NSApplication.shared
		let panel = PropertiesPanel()
		let project = Project(
			timeline: [TimelineEntry(clip: ClipReference("intro"))],
			overlays: [Overlay(kind: .spinner(Spinner()),
			                   spans: [.times(from: 0, to: 4), .times(from: 5, to: 9)])])
		panel.reload(project, vocabulary: ComposeDocument.Vocabulary(), selection: .overlay(0))

		find(SpanStrip.self, in: panel).first?.onSelect?(1)
		panel.reload(project, vocabulary: ComposeDocument.Vocabulary(), selection: .overlay(0))
		#expect(find(SpanStrip.self, in: panel).first?.selected == 1)

		// A different overlay starts again at its own first range.
		panel.reload(project, vocabulary: ComposeDocument.Vocabulary(), selection: .output)
		panel.reload(project, vocabulary: ComposeDocument.Vocabulary(), selection: .overlay(0))
		#expect(find(SpanStrip.self, in: panel).first?.selected == 0)
	}
}

/// Dragging a scene onto the programme.
///
/// A clip dropped there is a clip; a scene has nowhere to be until something
/// holds it, so the drop makes the something.
@Suite @MainActor struct SceneDropTests {

	private func project() -> Project {
		var project = Project(timeline: [TimelineEntry(clip: ClipReference("intro"))])
		project.scenes["opening"] = Scene(parts: [
			Scene.Part(content: .text("{{title}}", style: nil),
			           keys: [Scene.Key(t: 0, opacity: 0), Scene.Key(t: 2.5, opacity: 1)]),
		])
		project.scenes["plain"] = Scene(parts: [
			Scene.Part(content: .shape(fill: RGBA(hex: "#ffffff")!, corner: 0),
			           keys: [Scene.Key(t: 0)]),
		])
		return project
	}

	private func panel() -> ProgrammePanel {
		_ = NSApplication.shared
		let panel = ProgrammePanel(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
		panel.reload(project(), vocabulary: ComposeDocument.Vocabulary())
		return panel
	}

	@Test func aDroppedSceneBringsACardWithIt() {
		let panel = self.panel()
		var written: Project?
		panel.onChange = { written = $0 }
		#expect(panel.dropScene("opening", into: [], at: 0))

		// The card, at the length the scene actually runs for.
		guard case .card(let card)? = written?.timeline.first?.source else {
			Issue.record("no card was inserted")
			return
		}
		#expect(abs(card.duration - 2.5) < 0.001)
		#expect(written?.timeline.first?.label == "opening")
		#expect(written?.timeline.count == 2)

		// And the scene, hung on the card by the name the card was given.
		#expect(written?.overlays.count == 1)
		#expect(written?.overlays.first?.kind == .scene("opening", with: [:]))
		#expect(written?.overlays.first?.span == .marks(from: .group("opening"),
		                                                to: .group("opening")))
	}

	/// A scene that never moves gets a title card's length rather than nothing.
	@Test func aSceneWithNothingHappeningStillTakesTime() {
		let panel = self.panel()
		var written: Project?
		panel.onChange = { written = $0 }
		_ = panel.dropScene("plain", into: [], at: 0)
		guard case .card(let card)? = written?.timeline.first?.source else { return }
		#expect(card.duration == 4)
	}

	/// Two of the same scene are two places, and each overlay must hang on its
	/// own — otherwise both play over the first card.
	@Test func theSecondOneGetsItsOwnName() {
		let panel = self.panel()
		var written = project()
		panel.onChange = { written = $0 }
		_ = panel.dropScene("opening", into: [], at: 0)
		panel.reload(written, vocabulary: ComposeDocument.Vocabulary())
		_ = panel.dropScene("opening", into: [], at: 0)

		let labels = written.timeline.compactMap(\.label)
		#expect(labels == ["opening-2", "opening"] || labels == ["opening", "opening-2"])
		#expect(written.overlays.count == 2)
		#expect(written.overlays[0].span != written.overlays[1].span,
		        "both scenes hang on the same card")
	}

	@Test func anUnknownSceneIsNotDropped() {
		let panel = self.panel()
		var written: Project?
		panel.onChange = { written = $0 }
		#expect(panel.dropScene("nothing-like-this", into: [], at: 0) == false)
		#expect(written == nil)
	}
}
