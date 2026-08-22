import AppKit
import Testing
@testable import CuttrCompose
@testable import CuttrUI

/// Taking back a change to a programme.
///
/// There was no way to. `TakeDocument` and `SceneDocument` have both had an
/// undo manager since they were written; the project window had none, so ⌘Z on
/// a programme did nothing and the way back from a wrong drag was git.
@MainActor @Suite struct ProjectUndoTests {

	private func document() throws -> ComposeDocument {
		let project = try ProjectReader.read("""
			timeline:
			  - {card: 00:10.000, fill: "#101010"}
			""")
		let document = ComposeDocument(project: project)
		document.apply(project)
		return document
	}

	private func changed(_ project: Project, to seconds: Double) -> Project {
		var next = project
		next.output.framesPerSecond = seconds
		return next
	}

	@Test func aChangeCanBeTakenBack() throws {
		let document = try document()
		let was = document.project.output.framesPerSecond

		document.apply(changed(document.project, to: 50), actionName: "Set Rate")
		#expect(document.project.output.framesPerSecond == 50)

		document.undoManager.undo()
		#expect(document.project.output.framesPerSecond == was, "undo did nothing")
	}

	@Test func andPutBackAgain() throws {
		let document = try document()
		document.apply(changed(document.project, to: 50), actionName: "Set Rate")
		document.undoManager.undo()
		document.undoManager.redo()
		#expect(document.project.output.framesPerSecond == 50, "redo did nothing")
	}

	/// The menu says what it is about to take back, which is the only way to
	/// know whether it is the thing you meant.
	@Test func theStepIsNamed() throws {
		let document = try document()
		document.apply(changed(document.project, to: 50), actionName: "Move Overlay")
		#expect(document.undoManager.undoActionName == "Move Overlay")
	}

	/// Applying the same project again is not a step. Otherwise ⌘Z would spend
	/// several presses doing nothing before it reached a real change.
	@Test func applyingTheSameThingIsNotAStep() throws {
		let document = try document()
		document.apply(document.project)
		document.apply(document.project)
		#expect(!document.undoManager.canUndo, "a no-op change went on the stack")
	}

	/// The file changed underneath, so every step on the stack is about a
	/// project that is no longer the one on disk.
	@Test func readingTheFileAgainForgetsTheStack() throws {
		let folder = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("cuttr-undo-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: folder) }
		let url = folder.appendingPathComponent("film.cuttrproj")

		let document = try document()
		try document.saveAs(url)
		document.apply(changed(document.project, to: 50), actionName: "Set Rate")
		#expect(document.undoManager.canUndo)

		document.reload()
		#expect(!document.undoManager.canUndo, "a step survived the file being re-read")
	}
}

/// The window answers ⌘Z, which is a different question from whether the
/// document remembers.
///
/// The Edit menu named `MainWindowController.undoEdit(_:)`, so only the take
/// editor ever answered — a project window with a perfectly good undo manager
/// would still have had a grey menu item.
@MainActor @Suite struct UndoReachesEveryWindowTests {

	@Test func theProjectWindowAnswersUndo() throws {
		_ = NSApplication.shared
		let project = try ProjectReader.read("timeline:\n  - {card: 00:10.000}\n")
		let document = ComposeDocument(project: project)
		document.apply(project)
		let controller = ComposeWindowController(document: document)

		#expect(controller.documentUndoManager === document.undoManager)
		#expect(controller.responds(to: #selector(DocumentEditor.undoEdit(_:))))
		#expect(controller.responds(to: #selector(DocumentEditor.redoEdit(_:))))
	}

	/// And the menu item it validates says so.
	@Test func theMenuItemSaysWhatItWillTakeBack() throws {
		_ = NSApplication.shared
		let project = try ProjectReader.read("timeline:\n  - {card: 00:10.000}\n")
		let document = ComposeDocument(project: project)
		document.apply(project)
		let controller = ComposeWindowController(document: document)

		var next = project
		next.output.framesPerSecond = 50
		document.apply(next, actionName: "Move Overlay")

		let item = NSMenuItem(title: "Undo",
		                      action: #selector(DocumentEditor.undoEdit(_:)), keyEquivalent: "z")
		#expect(controller.validateMenuItem(item))
		#expect(item.title == "Undo Move Overlay")
	}
}
