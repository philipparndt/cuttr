import AppKit
import CuttrCompose
import CuttrKit
import Testing
@testable import CuttrUI

/// Saying where a project stands, without doing anything about it.
///
/// Everything a share did, it said once in a status line that was gone by the
/// time anybody looked — so there was no telling "I have three changes nobody
/// else has" from "the button did nothing", which is how the button came to be
/// reported as doing nothing.
@Suite(.serialized) @MainActor struct StandingTests {

	private struct Bench {
		let home: URL
		let work: URL
		let sharing: ProjectSharing
		let git: ProjectVersions.Plumbing
	}

	private func bench() throws -> Bench {
		let home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
			.appendingPathComponent("cuttr-standing-\(UUID().uuidString)", isDirectory: true)
			.resolvingSymlinksInPath().standardizedFileURL
		try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
		let outer = ProjectVersions.Plumbing(root: home)
		let origin = home.appendingPathComponent("origin.git")
		_ = outer.run(["init", "--bare", "--quiet", "--initial-branch=main", origin.path])

		let work = home.appendingPathComponent("work")
		_ = outer.run(["clone", "--quiet", origin.path, work.path])
		let git = ProjectVersions.Plumbing(root: work)
		_ = git.run(["config", "user.email", "test@localhost"])
		_ = git.run(["config", "user.name", "Test"])

		let file = work.appendingPathComponent("film.cuttrproj")
		try ProjectWriter.write(Project(timeline: [TimelineEntry(card: Card(duration: 3))]))
			.write(to: file, atomically: true, encoding: .utf8)
		_ = git.run(["add", "-A"])
		_ = git.run(["commit", "-q", "-m", "first"])
		_ = git.run(["push", "--quiet", "--set-upstream", "origin", "main"])

		return Bench(home: home, work: work,
		             sharing: ProjectSharing(project: file, root: work), git: git)
	}

	private func touch(_ bench: Bench) throws {
		var project = Project(timeline: [TimelineEntry(card: Card(duration: 9))])
		project.takes = []
		try ProjectWriter.write(project).write(
			to: bench.work.appendingPathComponent("film.cuttrproj"),
			atomically: true, encoding: .utf8)
	}

	@Test func aSettledProjectHasNothingToSay() throws {
		let bench = try bench()
		defer { try? FileManager.default.removeItem(at: bench.home) }
		let standing = bench.sharing.standing()
		#expect(standing.isSettled, "\(standing)")
		#expect(standing.hasRemote)
	}

	/// The case that was invisible: a file changed and not yet committed.
	@Test func anEditedProjectHasSomethingToUpload() throws {
		let bench = try bench()
		defer { try? FileManager.default.removeItem(at: bench.home) }
		try touch(bench)

		let standing = bench.sharing.standing()
		#expect(standing.uncommitted == 1, "\(standing)")
		#expect(!standing.isSettled)
	}

	@Test func aCommitNobodyElseHasIsSomethingToUpload() throws {
		let bench = try bench()
		defer { try? FileManager.default.removeItem(at: bench.home) }
		try touch(bench)
		_ = bench.git.run(["add", "-A"])
		_ = bench.git.run(["commit", "-q", "-m", "mine"])

		let standing = bench.sharing.standing()
		#expect(standing.toUpload == 1, "\(standing)")
		#expect(standing.uncommitted == 0)
	}

	/// And after a share there is nothing left to say, which is the button
	/// going away.
	@Test func sharingSettlesIt() throws {
		let bench = try bench()
		defer { try? FileManager.default.removeItem(at: bench.home) }
		try touch(bench)

		#expect(bench.sharing.share().outcome == .sent)
		#expect(bench.sharing.standing().isSettled, "\(bench.sharing.standing())")
	}

	/// A repository nobody can send to has no button, rather than a button
	/// that cannot work.
	@Test func aProjectWithNoRemoteSaysSo() throws {
		let home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
			.appendingPathComponent("cuttr-lonely-\(UUID().uuidString)", isDirectory: true)
			.resolvingSymlinksInPath().standardizedFileURL
		try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: home) }
		let git = ProjectVersions.Plumbing(root: home)
		_ = git.run(["init", "--quiet", "--initial-branch=main"])
		let file = home.appendingPathComponent("film.cuttrproj")
		try ProjectWriter.write(Project()).write(to: file, atomically: true, encoding: .utf8)

		let standing = ProjectSharing(project: file, root: home).standing()
		#expect(!standing.hasRemote)
	}

	// MARK: - Which outcomes have to be answered

	/// A refusal names something that has to happen first. Saying it once in a
	/// status line is how "it refused" reads as "nothing happened".
	@Test func refusalsHaveToBeAnsweredAndSuccessDoesNot() {
		#expect(ProjectSharing.Outcome.inTheWay("close it").needsAnswering)
		#expect(ProjectSharing.Outcome.busy("a rebase").needsAnswering)
		#expect(ProjectSharing.Outcome.trouble(.unauthenticated(host: "x")).needsAnswering)
		#expect(ProjectSharing.Outcome.noRepository.needsAnswering)
		#expect(ProjectSharing.Outcome.failed("no").needsAnswering)

		#expect(!ProjectSharing.Outcome.sent.needsAnswering)
		#expect(!ProjectSharing.Outcome.nothingToSend.needsAnswering)
		#expect(!ProjectSharing.Outcome.brought(theirs: 2, sentMine: true).needsAnswering)
		// The sheet is the answering.
		#expect(!ProjectSharing.Outcome.mustChoose(["intro"]).needsAnswering)
	}
}
