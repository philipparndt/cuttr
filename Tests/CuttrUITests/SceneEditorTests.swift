import AppKit
import CuttrCompose
import CuttrKit
import Testing
@testable import CuttrUI

/// The scene editor, assembled and driven.
///
/// The window is built here rather than only looked at, because both of this
/// program's launch crashes were AppKit refusing something a view did while it
/// was being put together — and a window that never opens in a test is a window
/// that crashes on the person using it.
@Suite @MainActor struct SceneEditorTests {

	private func project() -> Project {
		Project(
			output: Output(width: 1920, height: 1080, framesPerSecond: 25),
			timeline: [TimelineEntry(clip: ClipReference("intro"))],
			overlays: [Overlay(kind: .scene("intro", with: ["title": "Folge 3"]),
			                   span: .times(from: 0, to: 4))],
			scenes: ["intro": SceneDocument.starter,
			         "outro": Scene(parts: [
			         	.init(content: .shape(fill: .white, corner: 0),
			         	      keys: [.init(t: 0, x: 0.5, y: 0.2, width: 0.4, height: 0.004)]),
			         ])])
	}

	private func document() -> SceneDocument {
		SceneDocument(project: project(), baseURL: URL(fileURLWithPath: "/tmp"), name: "intro")
	}

	// MARK: - The window

	@Test func theWindowOpensAndTakesTheSizeItIsGiven() {
		_ = NSApplication.shared
		let controller = SceneWindowController(document: document(), projectURL: nil)
		guard let window = controller.window else { return }
		window.setContentSize(NSSize(width: 1400, height: 900))
		window.layoutIfNeeded()
		#expect(window.contentView?.frame.width ?? 0 >= 1300)
		#expect(window.contentView?.frame.height ?? 0 >= 850)
		// And small again: a required size in the middle of it would pin the
		// window to one shape.
		window.setContentSize(NSSize(width: 900, height: 600))
		window.layoutIfNeeded()
		#expect(window.contentView?.frame.width ?? 0 <= 950)
		window.close()
	}

	/// Every part in turn, through the panels, the way the properties panel is
	/// checked — the form is thrown away and rebuilt each time.
	@Test func thePanelsShowEveryKindOfPart() {
		_ = NSApplication.shared
		let inspector = SceneInspector()
		let parts = ScenePartsList()
		let scene = Scene(parts: [
			.init(content: .background(Scene.Background(from: .black, to: .white, angle: 45)),
			      keys: [.init(t: 0, opacity: 1)]),
			.init(content: .text("{{title}}", style: "title", tracking: 0.1),
			      keys: [.init(t: 0, x: 0.5, y: 0.5, opacity: 0, color: .white),
			             .init(t: 1, opacity: 1, ease: .out)]),
			.init(content: .shape(fill: .white, corner: 0.01),
			      keys: [.init(t: 0, x: 0.5, y: 0.3, width: 0.3, height: 0.004)]),
			.init(content: .image("logo.png"), keys: [.init(t: 0, x: 0.2, y: 0.8)]),
			.init(content: .bar(Scene.Bar(corner: 0.006, direction: .up)),
			      keys: [.init(t: 0, x: 0.1, y: 0.5, width: 0.02, height: 0.4, progress: 0),
			             .init(t: 2, progress: 1, ease: .out)]),
			.init(content: .spinner(Spinner(style: .ring)),
			      keys: [.init(t: 0, x: 0.9, y: 0.5, opacity: 1)]),
			.init(content: .shape(fill: .white, corner: 0, kind: .star),
			      keys: [.init(t: 0, x: 0.5, y: 0.8, width: 0.1, height: 0.1),
			             .init(t: 1, shape: .hexagon)]),
		])
		for part in [nil, 0, 1, 2, 3, 4, 5, 6, 9] as [Int?] {
			inspector.reload(scene, project: project(), part: part, key: 0)
			parts.reload(scene, selected: part)
		}
		inspector.reload(scene, project: project(), part: 1, key: 1)
		inspector.layoutSubtreeIfNeeded()
		parts.layoutSubtreeIfNeeded()
	}

	@Test func theStageAndTheScrubberDrawWhateverTheyAreGiven() {
		_ = NSApplication.shared
		let stage = SceneStage(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
		stage.project = project()
		stage.scene = SceneDocument.starter
		stage.parameters = ["title": "Folge 3"]
		stage.outputSize = CGSize(width: 1920, height: 1080)
		for time in [0.0, 0.5, 1.0, 4.0] {
			stage.time = time
			stage.selected = 1
			stage.display()
		}
		// An empty scene is a state, not a fault.
		stage.scene = Scene()
		stage.selected = nil
		stage.display()

		let scrubber = SceneScrubber(frame: NSRect(x: 0, y: 0, width: 640, height: 120))
		scrubber.scene = SceneDocument.starter
		scrubber.length = 4
		scrubber.selectedPart = 1
		scrubber.selectedKey = 0
		scrubber.display()
	}

	/// The stage's picture is the frame's shape, wherever it is on the view —
	/// which is what makes a part dragged to the middle of the stage land in
	/// the middle of the file.
	@Test func theStageFitsTheFrameIntoWhateverRoomItHas() {
		_ = NSApplication.shared
		let stage = SceneStage(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
		stage.outputSize = CGSize(width: 1920, height: 1080)
		let picture = stage.picture
		#expect(abs(picture.width / picture.height - 16.0 / 9) < 0.01)
		#expect(picture.width <= 800)
		#expect(picture.height <= 300)
	}

	/// A part is dragged on the stage, and the drag arrives as a position in
	/// fractions of the frame — live all the way, once more on the way up.
	///
	/// Driven with real events through a real window, because the arithmetic
	/// that turns a point on screen into a place in the file is the part that
	/// goes wrong, and it involves the picture's rectangle inside the view.
	@Test func draggingAPartOnTheStageMovesIt() throws {
		_ = NSApplication.shared
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
		                      styleMask: [.titled], backing: .buffered, defer: false)
		// A window made here and closed here is released by closing, and then
		// released again by the local going out of scope. That is a crash in a
		// test rather than a bug in the program, and it costs one line.
		window.isReleasedWhenClosed = false
		let stage = SceneStage()
		window.contentView = stage
		stage.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
		stage.project = project()
		stage.outputSize = CGSize(width: 1920, height: 1080)
		stage.scene = Scene(parts: [
			.init(content: .shape(fill: .white, corner: 0),
			      keys: [.init(t: 0, x: 0.5, y: 0.5, opacity: 1, width: 0.3, height: 0.3)]),
		])
		stage.selected = 0
		stage.display()

		var moves: [(Double, Double, Bool)] = []
		stage.onMove = { _, x, y, commit in moves.append((x, y, commit)) }

		func event(_ type: NSEvent.EventType, _ at: NSPoint) throws -> NSEvent {
			try #require(NSEvent.mouseEvent(
				with: type, location: at, modifierFlags: [], timestamp: 0,
				windowNumber: window.windowNumber, context: nil,
				eventNumber: 0, clickCount: 1, pressure: 1))
		}

		let picture = stage.picture
		let middle = NSPoint(x: picture.midX, y: picture.midY)
		stage.mouseDown(with: try event(.leftMouseDown, middle))
		// A quarter of the picture's width to the right — well past the snap to
		// the two-thirds line, which is what a small nudge would land on.
		let moved = NSPoint(x: picture.midX + picture.width * 0.3, y: picture.midY)
		stage.mouseDragged(with: try event(.leftMouseDragged, moved))
		stage.mouseUp(with: try event(.leftMouseUp, moved))

		#expect(moves.count == 2)
		#expect(moves.first?.2 == false)
		#expect(moves.last?.2 == true)
		#expect(abs((moves.last?.0 ?? 0) - 0.8) < 0.01, "moved to \(moves.last?.0 ?? -1)")
		#expect(abs((moves.last?.1 ?? 0) - 0.5) < 0.01)
		window.close()
	}

	// MARK: - The document

	/// A drag writes into the key at the playhead, or makes one there.
	@Test func draggingWritesAKeyAtThePlayhead() {
		let document = self.document()
		document.playhead = 0.6
		document.move(1, x: 0.4, y: 0.7, commit: true)

		let keys = document.scene.parts[1].keys
		#expect(keys.contains { abs($0.t - 0.6) < 1e-6 })
		let made = keys.first { abs($0.t - 0.6) < 1e-6 }
		#expect(made?.x == 0.4)
		#expect(made?.y == 0.7)
	}

	/// A whole drag is one step in the Edit menu, and undoing it puts the part
	/// back where the drag started rather than where it was a frame ago.
	@Test func aDragIsOneUndoStep() {
		let document = self.document()
		document.playhead = 0
		let before = document.scene
		for x in stride(from: 0.5, through: 0.2, by: -0.05) {
			document.move(1, x: x, y: 0.46, commit: x <= 0.2)
		}
		#expect(document.scene != before)
		document.undoManager.undo()
		#expect(document.scene == before)
	}

	/// The editing length is a fact about the session. It never reaches the
	/// file, because a scene plays for as long as the overlay using it.
	@Test func theEditingLengthIsNeverWritten() {
		let document = self.document()
		document.length = 9.5
		var written: Project?
		document.onWrite = { written = $0 }
		document.playhead = 1
		document.move(1, x: 0.5, y: 0.5, commit: true)
		let text = ProjectWriter.write(try! #require(written))
		#expect(text.contains("scenes:"))
		#expect(!text.contains("9.5"))
		#expect(!text.contains("length"))
	}

	/// The window hands the project back whole, so the project document can
	/// write the file — the scene window never touches it.
	@Test func editsComeBackAsAWholeProject() {
		let document = self.document()
		var written: [Project] = []
		document.onWrite = { written.append($0) }
		document.addPart(.shape(fill: .white, corner: 0))
		#expect(written.count == 1)
		#expect(written.last?.scenes["intro"]?.parts.count == 3)
		// …and the rest of the project is untouched by it.
		#expect(written.last?.timeline == project().timeline)
		#expect(written.last?.scenes["outro"] == project().scenes["outro"])
	}

	/// A background goes to the back whatever order it was added in, because a
	/// ground drawn last is a blank frame.
	@Test func aBackgroundGoesUnderneath() {
		let document = SceneDocument(
			project: Project(scenes: ["plate": Scene(parts: [
				.init(content: .text("hello", style: nil), keys: [.init(t: 0, x: 0.5, y: 0.5)]),
			])]),
			baseURL: nil, name: "plate")
		document.addPart(.background(Scene.Background(from: .black)))
		if case .background = document.scene.parts[0].content {} else {
			Issue.record("the background is not the first part")
		}
	}

	/// Switching scenes in the picker takes the selection and the playhead with
	/// it: a key of the old part selected against the new one is a form
	/// pointing at something that is not there.
	@Test func switchingScenesForgetsWhatWasSelected() {
		let document = self.document()
		document.selectedPart = 1
		document.selectedKey = 1
		document.playhead = 2
		document.show("outro")
		#expect(document.name == "outro")
		#expect(document.selectedPart == nil)
		#expect(document.selectedKey == nil)
		#expect(document.playhead == 0)
	}

	/// Naming a shape at the playhead is how a morph is made, and it lands on
	/// the key there — or makes one.
	@Test func namingAShapeWritesAKeyAtThePlayhead() {
		let document = SceneDocument(
			project: Project(scenes: ["badge": Scene(parts: [
				.init(content: .shape(fill: .white, corner: 0, kind: .rectangle),
				      keys: [.init(t: 0, x: 0.5, y: 0.5, width: 0.3, height: 0.3)]),
			])]),
			baseURL: nil, name: "badge")
		document.playhead = 1.5
		document.setShape(.star, on: 0)

		let keys = document.scene.parts[0].keys
		#expect(keys.count == 2)
		#expect(keys[1].shape == .star)
		#expect(keys[0].shape == nil, "the first key was given a kind it did not need")
		// And the part is morphing, which is the whole point of writing it.
		let morph = Scene.morph(of: Scene.filled(keys), at: 0.75, default: .rectangle)
		#expect(morph.from == .rectangle)
		#expect(morph.to == .star)
	}

	/// A project with no takes at all is a real programme now — a card with a
	/// scene on it and nothing else — so the scene editor has to open on one.
	@Test func aProjectWithNoTakesStillEdits() {
		_ = NSApplication.shared
		let project = Project(output: Output(width: 1920, height: 1080),
		                      scenes: ["intro": SceneDocument.starter])
		let document = SceneDocument(project: project, baseURL: nil, name: "intro")
		#expect(document.length > 0)
		let controller = SceneWindowController(document: document, projectURL: nil)
		controller.window?.layoutIfNeeded()
		document.addPart(.bar(Scene.Bar()))
		controller.window?.layoutIfNeeded()
		#expect(document.scene.parts.count == 3)
		controller.window?.close()
	}

	/// The stage shows the scene with the words the project puts in it, not
	/// with `{{title}}` — a title card cannot be judged by the width of its
	/// placeholder.
	@Test func theStageShowsTheWordsTheProgrammeUses() {
		#expect(document().parameters == ["title": "Folge 3"])
	}
}
