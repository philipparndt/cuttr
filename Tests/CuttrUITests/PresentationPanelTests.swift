import AppKit
import CuttrKit
import Testing
@testable import CuttrCompose
@testable import CuttrUI

/// Editing a treatment in the properties panel.
///
/// Nothing here dispatches a key event: the fields are found and their actions
/// fired the way the panel's own wiring fires them, because an unhandled key
/// event walks up to `NSResponder` and beeps on the machine running the tests.
@MainActor @Suite struct PresentationPanelTests {

	private func panel(_ project: Project) -> (PropertiesPanel, Project) {
		_ = NSApplication.shared
		let panel = PropertiesPanel()
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 1400),
		                      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
		window.contentView = panel
		panel.reload(project, vocabulary: ComposeDocument.Vocabulary(),
		             selection: .entry([0]))
		panel.layoutSubtreeIfNeeded()
		return (panel, project)
	}

	private func find<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
		view.subviews.flatMap { subview -> [T] in
			((subview as? T).map { [$0] } ?? []) + find(type, in: subview)
		}
	}

	private func button(_ title: String, in panel: NSView) -> NSButton? {
		find(NSButton.self, in: panel).first { $0.title == title }
	}

	private func press(_ button: NSButton?) {
		guard let button, let target = button.target, let action = button.action else { return }
		_ = target.perform(action, with: button)
	}

	private func withOne() -> Project {
		var entry = TimelineEntry(clip: ClipReference("install"))
		entry.presentations = [Presentation(
			at: 12, into: Presentation.Rectangle(x: 0.04, y: 0.2, width: 0.44, height: 0.6),
			hold: 6, scene: "bullets", parameters: ["one": "Download it"])]
		return Project(timeline: [entry])
	}

	/// The button that is there when there is nothing yet, and what it makes: a
	/// treatment somebody can see the effect of before they have typed a word.
	@Test func addingOneMakesATreatmentWorthLookingAt() {
		var project = Project(timeline: [TimelineEntry(clip: ClipReference("install"))])
		let (panel, _) = self.panel(project)
		panel.onChange = { project = $0 }

		press(button("add a presentation", in: panel))
		let made = try? #require(project.timeline.first?.presentations.first)
		#expect(made?.hold == 4)
		#expect(made?.scene == "bullets")
		#expect(made?.into.isWhole == false)
	}

	@Test func theTreatmentIsShownAndEdited() {
		var project = withOne()
		let (panel, _) = self.panel(project)
		panel.onChange = { project = $0 }

		let fields = find(NSTextField.self, in: panel).filter(\.isEditable)
		// The moment, as a timecode, and the line it says.
		#expect(fields.contains { $0.stringValue == "00:12.000" })
		#expect(fields.contains { $0.stringValue == "Download it" })

		guard let moment = fields.first(where: { $0.stringValue == "00:12.000" }) else { return }
		moment.stringValue = "00:20.000"
		if let target = moment.target, let action = moment.action {
			_ = target.perform(action, with: moment)
		}
		#expect(project.timeline[0].presentations[0].at == 20)
	}

	/// The two sides anybody wants, as buttons, because four fractions is not
	/// how somebody decides which half of the frame a screen recording goes in.
	@Test func theSideButtonsMoveThePicture() {
		var project = withOne()
		let (panel, _) = self.panel(project)
		panel.onChange = { project = $0 }

		press(button("right", in: panel))
		#expect(project.timeline[0].presentations[0].into.x > 0.5)
		#expect(project.timeline[0].presentations[0].into.free.x == 0)
	}

	@Test func removingOneTakesItAway() {
		var project = withOne()
		let (panel, _) = self.panel(project)
		panel.onChange = { project = $0 }

		press(button("remove", in: panel))
		#expect(project.timeline[0].presentations.isEmpty)
	}

	/// The bug this would otherwise have: every form in the panel builds a
	/// whole entry rather than editing one, so an edit to the trim would throw
	/// the treatments away with the overlays and the sounds.
	@Test func editingTheEntryKeepsWhatIsWrittenInsideIt() {
		var project = withOne()
		project.timeline[0].sounds = [Sound(file: "sting.wav", span: nil)]
		let (panel, _) = self.panel(project)
		panel.onChange = { project = $0 }

		// The `as` field, which replaces the entry wholesale.
		guard let name = find(NSTextField.self, in: panel)
			.filter(\.isEditable)
			.first(where: { $0.placeholderString == "a name for this use" })
		else {
			Issue.record("the `as` field is not on the form")
			return
		}
		name.stringValue = "the-install"
		if let target = name.target, let action = name.action {
			_ = target.perform(action, with: name)
		}
		#expect(project.timeline[0].label == "the-install")
		#expect(project.timeline[0].presentations.count == 1)
		#expect(project.timeline[0].sounds.count == 1)
	}

	/// A card has no picture to move aside, so the form does not offer to move
	/// one.
	@Test func aCardIsNotOfferedATreatment() {
		let project = Project(timeline: [TimelineEntry(card: Card(duration: 4))])
		let (panel, _) = self.panel(project)
		#expect(button("add a presentation", in: panel) == nil)
	}
}
