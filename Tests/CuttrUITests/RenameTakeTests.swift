import Foundation
import Testing
@testable import CuttrCompose
@testable import CuttrKit
@testable import CuttrUI

/// Renaming a take that is open.
///
/// It used to be refused — "close that take before renaming it" — for a real
/// reason: the open document held the old URL, so its next save wrote the old
/// file back and undid the rename. That was a fair answer when a take was a
/// separate window somebody could go and close. Every document lives in the
/// same window now, so the answer has to be to tell the document instead.
@MainActor @Suite struct RenameTakeTests {

	private func folder() throws -> URL {
		let root = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("cuttr-rename-\(UUID().uuidString)")
		try FileManager.default.createDirectory(
			at: root.appendingPathComponent("takes"), withIntermediateDirectories: true)
		try FileManager.default.createDirectory(
			at: root.appendingPathComponent("media"), withIntermediateDirectories: true)
		try Data().write(to: root.appendingPathComponent("media/a.mov"))
		try TakeWriter.write(Take(video: "../media/a.mov", clips: [
			Clip(slug: "one", start: 0, end: 2),
		])).write(to: root.appendingPathComponent("takes/before.cuttr"),
		          atomically: true, encoding: .utf8)
		return root
	}

	private func project(in root: URL) -> ComposeDocument {
		ComposeDocument(
			project: Project(takes: ["takes/before.cuttr"], output: Output(file: "out.mov")),
			url: root.appendingPathComponent("p.cuttrproj"))
	}

	// MARK: - The file, and the project that points at it

	/// The rename says where the file went, because the caller needs to tell
	/// whoever has it open.
	@Test func renamingSaysWhereTheFileWent() throws {
		let root = try folder()
		defer { try? FileManager.default.removeItem(at: root) }
		let document = project(in: root)

		let outcome = document.renameTake("takes/before.cuttr", to: "after")
		#expect(outcome == .renamed(root.appendingPathComponent("takes/after.cuttr")
			.standardizedFileURL))
		#expect(document.project.takes == ["takes/after.cuttr"])
		#expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("takes/after.cuttr").path))
		#expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("takes/before.cuttr").path))
	}

	/// The same name is not a rename, and a name already taken is refused
	/// rather than losing the file it would have written over.
	@Test func nothingToDoAndNothingToLose() throws {
		let root = try folder()
		defer { try? FileManager.default.removeItem(at: root) }
		let document = project(in: root)
		#expect(document.renameTake("takes/before.cuttr", to: "before") == .unchanged)
		#expect(document.renameTake("takes/before.cuttr", to: "   ") == .unchanged)

		try Data("taken".utf8).write(to: root.appendingPathComponent("takes/taken.cuttr"))
		guard case .refused = document.renameTake("takes/before.cuttr", to: "taken") else {
			Issue.record("renaming over an existing take was allowed")
			return
		}
		// And the file it would have written over is still what it was.
		#expect(try String(contentsOf: root.appendingPathComponent("takes/taken.cuttr"),
		                   encoding: .utf8) == "taken")
	}

	// MARK: - The document that has it open

	/// The failure the refusal was protecting against, now that nothing
	/// refuses: an open take must save under its new name and must not bring
	/// the old file back.
	@Test func aRenamedTakeSavesUnderItsNewNameAndDoesNotBringTheOldOneBack() throws {
		let root = try folder()
		defer { try? FileManager.default.removeItem(at: root) }
		let before = root.appendingPathComponent("takes/before.cuttr")
		let after = root.appendingPathComponent("takes/after.cuttr")

		// The take, open, with an edit in it that has not been saved.
		let take = TakeDocument()
		try take.read(from: before)
		take.apply(Take(video: take.take.video, clips: [Clip(slug: "two", start: 1, end: 3)]),
		           actionName: "Edit")
		#expect(take.isDirty)

		// The project renames the file underneath it, and says so.
		let document = project(in: root)
		guard case .renamed(let to) = document.renameTake("takes/before.cuttr", to: "after") else {
			Issue.record("the rename did not happen")
			return
		}
		take.renamed(to: to)

		// Saving now writes the new file, and the old name stays gone.
		try take.write(to: take.url!)
		#expect(take.url?.standardizedFileURL == after.standardizedFileURL)
		#expect(FileManager.default.fileExists(atPath: after.path))
		#expect(!FileManager.default.fileExists(atPath: before.path))
		#expect(try TakeReader.read(String(contentsOf: after, encoding: .utf8))
			.clips.map(\.slug) == ["two"])
	}

	/// The folder does not change, so everything the take points at still
	/// points where it pointed.
	@Test func aRenameLeavesTheTakesOwnPathsAlone() throws {
		let root = try folder()
		defer { try? FileManager.default.removeItem(at: root) }
		let take = TakeDocument()
		try take.read(from: root.appendingPathComponent("takes/before.cuttr"))
		let media = take.videoURL

		take.renamed(to: root.appendingPathComponent("takes/after.cuttr"))
		#expect(take.take.video == "../media/a.mov")
		#expect(take.videoURL?.standardizedFileURL == media?.standardizedFileURL)
	}

	/// Another folder is a move, not a rename, and is declined: every relative
	/// path in the take is relative to the folder it is in, so a document told
	/// it had moved would go on resolving against the old one. `write(to:)` is
	/// the one that re-relativises.
	@Test func aRenameIsNotAMove() throws {
		let root = try folder()
		defer { try? FileManager.default.removeItem(at: root) }
		let take = TakeDocument()
		try take.read(from: root.appendingPathComponent("takes/before.cuttr"))
		let was = take.url

		take.renamed(to: root.appendingPathComponent("media/after.cuttr"))
		#expect(take.url == was)
	}
}
