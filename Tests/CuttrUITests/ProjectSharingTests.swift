import CuttrCompose
import CuttrKit
import Foundation
import Testing
@testable import CuttrUI

/// Committing a project onto the branch without disturbing the repository it
/// lives in.
///
/// This is the analogue of `nothingIsTouchedInTheRepository`, and it is the
/// suite that matters most for this feature. Sharing is the one thing in cuttr
/// allowed to move HEAD; the claim that goes with that permission is that it
/// moves HEAD and *nothing else*. Everything here is against a real repository,
/// because the claim is about what git thinks afterwards and nothing else can
/// answer that.
@Suite(.serialized) @MainActor struct ProjectSharingTests {

	/// A work tree with a project, a take, and one committed state.
	private struct Bench {
		let root: URL
		let project: URL
		let sharing: ProjectSharing
		let git: ProjectVersions.Plumbing

		func run(_ arguments: [String]) -> String {
			git.run(arguments)?.out ?? ""
		}

		/// Asked as `git diff` rather than as `git status --porcelain`, because
		/// porcelain says which column a change is in with a leading space and
		/// `Plumbing.run` trims the output — so the one character that carries
		/// the meaning is the one that goes missing.
		func dirty() -> [String] { names(["diff", "--name-only"]) }
		func staged() -> [String] { names(["diff", "--cached", "--name-only"]) }

		private func names(_ arguments: [String]) -> [String] {
			(git.run(arguments)?.out ?? "")
				.split(separator: "\n").map { String($0) }.filter { !$0.isEmpty }
		}
	}

	private func bench() throws -> Bench {
		let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
			.appendingPathComponent("cuttr-share-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		let git = ProjectVersions.Plumbing(root: root)
		_ = git.run(["init", "--quiet", "--initial-branch=main"])
		_ = git.run(["config", "user.email", "test@localhost"])
		_ = git.run(["config", "user.name", "Test"])

		let take = root.appendingPathComponent("one.cuttr")
		try TakeWriter.write(Take(video: "one.mov",
		                          clips: [Clip(slug: "intro", start: 0, end: 10)]))
			.write(to: take, atomically: true, encoding: .utf8)
		let project = root.appendingPathComponent("film.cuttrproj")
		try ProjectWriter.write(Project(takes: ["one.cuttr"]))
			.write(to: project, atomically: true, encoding: .utf8)

		// One commit to start from, made the ordinary way — the interesting
		// cases are all about what happens on top of an existing history.
		_ = git.run(["add", "-A"])
		_ = git.run(["commit", "-q", "-m", "first"])

		// A resolved root, because /var and /private/var make a file inside the
		// work tree look outside it.
		let real = root.resolvingSymlinksInPath().standardizedFileURL
		return Bench(root: real,
		             project: project.resolvingSymlinksInPath().standardizedFileURL,
		             sharing: ProjectSharing(project: project, root: real), git: git)
	}

	private func edit(_ url: URL, _ change: (inout Take) -> Void) throws {
		var take = try TakeReader.read(String(contentsOf: url, encoding: .utf8))
		change(&take)
		try TakeWriter.write(take).write(to: url, atomically: true, encoding: .utf8)
	}

	// MARK: - What it commits

	@Test func itCommitsTheProjectsOwnFiles() throws {
		let bench = try bench()
		defer { try? FileManager.default.removeItem(at: bench.root) }
		try edit(bench.root.appendingPathComponent("one.cuttr")) { $0.clips[0].end = 12 }

		guard case .made(let commit) = bench.sharing.commitOurs(on: "main") else {
			Issue.record("nothing was committed"); return
		}
		#expect(bench.run(["rev-parse", "refs/heads/main"]) == commit,
		        "the branch does not point at the commit")
		#expect(bench.run(["show", "--name-only", "--format=", commit]).contains("one.cuttr"))
	}

	@Test func aSecondShareWithNoEditsCommitsNothing() throws {
		let bench = try bench()
		defer { try? FileManager.default.removeItem(at: bench.root) }
		#expect(bench.sharing.commitOurs(on: "main") == .nothingChanged)
	}

	// MARK: - What it leaves alone

	/// The claim the permission to move HEAD is granted on.
	@Test func nothingElseIsCommitted() throws {
		let bench = try bench()
		defer { try? FileManager.default.removeItem(at: bench.root) }

		// Somebody's own work, sitting in the tree beside the project.
		let theirs = bench.root.appendingPathComponent("notes.txt")
		try "half a thought".write(to: theirs, atomically: true, encoding: .utf8)
		_ = bench.git.run(["add", "notes.txt"])
		_ = bench.git.run(["commit", "-q", "-m", "notes"])
		try "half a thought, changed".write(to: theirs, atomically: true, encoding: .utf8)

		try edit(bench.root.appendingPathComponent("one.cuttr")) { $0.clips[0].end = 12 }
		guard case .made(let commit) = bench.sharing.commitOurs(on: "main") else {
			Issue.record("nothing was committed"); return
		}

		#expect(!bench.run(["show", "--name-only", "--format=", commit]).contains("notes.txt"),
		        "somebody else's file was swept into the commit")
		// And it is still dirty and still unstaged, exactly as they left it.
		#expect(bench.dirty().contains("notes.txt"),
		        "their modified file did not stay modified: \(bench.dirty())")
		#expect(!bench.staged().contains("notes.txt"),
		        "their file was staged by a share: \(bench.staged())")
	}

	/// A person mid-thought with something staged. Sharing must not commit it
	/// and must not un-stage it.
	@Test func aStagedChangeStaysStagedAndUncommitted() throws {
		let bench = try bench()
		defer { try? FileManager.default.removeItem(at: bench.root) }

		let theirs = bench.root.appendingPathComponent("staged.txt")
		try "staged on purpose".write(to: theirs, atomically: true, encoding: .utf8)
		_ = bench.git.run(["add", "staged.txt"])

		try edit(bench.root.appendingPathComponent("one.cuttr")) { $0.clips[0].end = 12 }
		guard case .made(let commit) = bench.sharing.commitOurs(on: "main") else {
			Issue.record("nothing was committed"); return
		}

		#expect(!bench.run(["show", "--name-only", "--format=", commit]).contains("staged.txt"),
		        "a staged file was committed by a share")
		#expect(bench.staged().contains("staged.txt"),
		        "the staged change did not survive: \(bench.staged())")
	}

	/// Without refreshing the person's index for the paths just committed, the
	/// project would read as modified for ever after: the index would hold the
	/// blob HEAD had *before* the commit.
	@Test func whatWasCommittedReadsAsClean() throws {
		let bench = try bench()
		defer { try? FileManager.default.removeItem(at: bench.root) }
		try edit(bench.root.appendingPathComponent("one.cuttr")) { $0.clips[0].end = 12 }

		guard case .made = bench.sharing.commitOurs(on: "main") else {
			Issue.record("nothing was committed"); return
		}
		#expect(!bench.dirty().contains("one.cuttr") && !bench.staged().contains("one.cuttr"),
		        "the committed take still reads as changed: \(bench.dirty()) \(bench.staged())")
	}

	// MARK: - Refusing

	@Test func aRepositoryMidSomethingIsNotWrittenTo() throws {
		let bench = try bench()
		defer { try? FileManager.default.removeItem(at: bench.root) }
		// The files are the state — the same way `midSomething` reads it.
		let gitDir = bench.root.appendingPathComponent(".git")
		try "ref".write(to: gitDir.appendingPathComponent("MERGE_HEAD"),
		                atomically: true, encoding: .utf8)

		#expect(bench.sharing.mustWait() == .busy("a merge"))
	}

	@Test func aFolderThatIsNotAWorkTreeHasNoSharing() {
		let outside = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("cuttr-nowhere-\(UUID().uuidString)")
		#expect(ProjectSharing(project: outside.appendingPathComponent("x.cuttrproj")) == nil)
	}
}
