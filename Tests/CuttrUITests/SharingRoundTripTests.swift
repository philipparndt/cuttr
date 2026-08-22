import CuttrCompose
import CuttrKit
import Foundation
import Testing
@testable import CuttrUI

/// Two people, one programme, and a remote between them.
///
/// A bare repository on the disk stands in for the host. Nothing here reaches a
/// network — the point is the *sequence*, and a `file://` remote exercises
/// fetch, merge and push exactly as a real one does while running in
/// milliseconds and working on a train.
///
/// Serialized: each test drives real git in three work trees, and the suite is
/// about what git thinks afterwards.
@Suite(.serialized) @MainActor struct SharingRoundTripTests {

	/// A remote, and two people with a clone each.
	private struct World {
		let home: URL
		let anna: Person
		let ben: Person

		func tidy() { try? FileManager.default.removeItem(at: home) }
	}

	private struct Person {
		let root: URL
		let sharing: ProjectSharing
		let git: ProjectVersions.Plumbing

		var take: URL { root.appendingPathComponent("one.cuttr") }

		func read() throws -> Take {
			try TakeReader.read(String(contentsOf: take, encoding: .utf8))
		}

		func edit(_ change: (inout Take) -> Void) throws {
			var take = try read()
			change(&take)
			try TakeWriter.write(take).write(to: self.take, atomically: true, encoding: .utf8)
		}
	}

	private func world() throws -> World {
		let home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
			.appendingPathComponent("cuttr-two-\(UUID().uuidString)", isDirectory: true)
			.resolvingSymlinksInPath().standardizedFileURL
		try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

		let origin = home.appendingPathComponent("origin.git")
		_ = ProjectVersions.Plumbing(root: home).run(["init", "--bare", "--quiet",
		                                              "--initial-branch=main", origin.path])

		// Anna sets the project up and pushes it.
		let anna = try clone(origin, into: home.appendingPathComponent("anna"))
		try TakeWriter.write(Take(video: "one.mov", clips: [
			Clip(slug: "intro", name: "Intro", start: 0, end: 10),
			Clip(slug: "middle", name: "Middle", start: 10, end: 20),
			Clip(slug: "outro", name: "Outro", start: 20, end: 30),
		])).write(to: anna.take, atomically: true, encoding: .utf8)
		try ProjectWriter.write(Project(takes: ["one.cuttr"]))
			.write(to: anna.root.appendingPathComponent("film.cuttrproj"),
			       atomically: true, encoding: .utf8)
		_ = anna.git.run(["add", "-A"])
		_ = anna.git.run(["commit", "-q", "-m", "the film"])
		_ = anna.git.run(["push", "--quiet", "--set-upstream", "origin", "main"])

		let ben = try clone(origin, into: home.appendingPathComponent("ben"))
		return World(home: home, anna: anna, ben: ben)
	}

	private func clone(_ origin: URL, into folder: URL) throws -> Person {
		_ = ProjectVersions.Plumbing(root: origin.deletingLastPathComponent())
			.run(["clone", "--quiet", origin.path, folder.path])
		let root = folder.resolvingSymlinksInPath().standardizedFileURL
		let git = ProjectVersions.Plumbing(root: root)
		_ = git.run(["config", "user.email", "test@localhost"])
		_ = git.run(["config", "user.name", "Test"])
		let project = root.appendingPathComponent("film.cuttrproj")
		return Person(root: root, sharing: ProjectSharing(project: project, root: root), git: git)
	}

	// MARK: - The ordinary day

	@Test func nothingToSendWhenNothingChanged() throws {
		let world = try world()
		defer { world.tidy() }
		#expect(world.ben.sharing.share().outcome == .nothingToSend)
	}

	@Test func oneChangeGoesOut() throws {
		let world = try world()
		defer { world.tidy() }
		try world.anna.edit { $0.clips[0].end = 12 }

		#expect(world.anna.sharing.share().outcome == .sent)

		// And Ben can see it.
		#expect(world.ben.sharing.share().outcome == .brought(theirs: 1, sentMine: false))
		#expect(try world.ben.read().clips[0].end == 12)
	}

	/// The case the whole feature is for: two people cutting two different
	/// shots, and neither of them asked anything.
	@Test func twoPeopleCutTwoDifferentShots() throws {
		let world = try world()
		defer { world.tidy() }

		try world.anna.edit { $0.clips[0].end = 12 }
		#expect(world.anna.sharing.share().outcome == .sent)

		try world.ben.edit { $0.clips[2].start = 22 }
		let (outcome, choose) = world.ben.sharing.share()
		#expect(choose == nil, "somebody was asked about two different shots")
		#expect(outcome == .brought(theirs: 1, sentMine: true))

		// Ben has both edits.
		let bens = try world.ben.read()
		#expect(bens.clips[0].end == 12, "Anna's trim did not arrive")
		#expect(bens.clips[2].start == 22, "Ben's own trim was lost")

		// And so does Anna, next time she asks.
		#expect(world.anna.sharing.share().outcome == .brought(theirs: 1, sentMine: false))
		let annas = try world.anna.read()
		#expect(annas.clips[0].end == 12)
		#expect(annas.clips[2].start == 22)
	}

	// MARK: - Disagreeing

	@Test func twoPeopleCuttingOneShotHaveToChoose() throws {
		let world = try world()
		defer { world.tidy() }

		try world.anna.edit { $0.clips[0].end = 12 }
		#expect(world.anna.sharing.share().outcome == .sent)

		try world.ben.edit { $0.clips[0].end = 14 }
		let (outcome, choose) = world.ben.sharing.share()

		guard case .mustChoose(let titles) = outcome else {
			Issue.record("expected to be asked, got \(outcome)"); return
		}
		#expect(titles == ["Intro"])
		#expect(choose?.takes.count == 1)

		// Nothing was written, and the tree is exactly as it was: Ben's own cut
		// is still on the disk and nothing is half-merged.
		#expect(try world.ben.read().clips[0].end == 14)
		#expect(world.ben.git.midSomething() == nil, "a merge was left in progress")
	}

	@Test func choosingTheirsFinishesTheShare() throws {
		let world = try world()
		defer { world.tidy() }

		try world.anna.edit { $0.clips[0].end = 12 }
		_ = world.anna.sharing.share()
		try world.ben.edit { $0.clips[0].end = 14 }
		_ = world.ben.sharing.share()

		#expect(world.ben.sharing.finish(choosing: ["clip:intro": .theirs]) == .sent)
		#expect(try world.ben.read().clips[0].end == 12, "Anna's cut was not taken")
		#expect(world.ben.git.midSomething() == nil)

		// Anna gets the resolution back.
		_ = world.anna.sharing.share()
		#expect(try world.anna.read().clips[0].end == 12)
	}

	@Test func choosingMineFinishesTheShare() throws {
		let world = try world()
		defer { world.tidy() }

		try world.anna.edit { $0.clips[0].end = 12 }
		_ = world.anna.sharing.share()
		try world.ben.edit { $0.clips[0].end = 14 }
		_ = world.ben.sharing.share()

		#expect(world.ben.sharing.finish(choosing: ["clip:intro": .mine]) == .sent)
		#expect(try world.ben.read().clips[0].end == 14, "Ben's own cut was not kept")
	}

	/// No conflict marker may ever reach a take file, because the reader would
	/// fail on it and the person would be looking at a broken project.
	@Test func noConflictMarkerEverReachesATake() throws {
		let world = try world()
		defer { world.tidy() }

		try world.anna.edit { $0.clips[0].end = 12 }
		_ = world.anna.sharing.share()
		try world.ben.edit { $0.clips[0].end = 14 }
		_ = world.ben.sharing.share()

		let onDisk = try String(contentsOf: world.ben.take, encoding: .utf8)
		#expect(!onDisk.contains("<<<<<<<"))
		#expect(!onDisk.contains(">>>>>>>"))
		// And it still parses, which is the thing a marker would break.
		#expect(throws: Never.self) { try TakeReader.read(onDisk) }

		_ = world.ben.sharing.finish(choosing: ["clip:intro": .theirs])
		let after = try String(contentsOf: world.ben.take, encoding: .utf8)
		#expect(!after.contains("<<<<<<<"))
		#expect(throws: Never.self) { try TakeReader.read(after) }
	}

	// MARK: - Refusing

	/// `git merge --abort` can take uncommitted work with it, so a merge is not
	/// started while there is any. The repository is the person's.
	@Test func unrelatedUncommittedWorkStopsAMerge() throws {
		let world = try world()
		defer { world.tidy() }

		try world.anna.edit { $0.clips[0].end = 12 }
		_ = world.anna.sharing.share()

		let theirs = world.ben.root.appendingPathComponent("notes.txt")
		try "mine".write(to: theirs, atomically: true, encoding: .utf8)
		_ = world.ben.git.run(["add", "notes.txt"])
		_ = world.ben.git.run(["commit", "-q", "-m", "notes"])
		try "changed, and not committed".write(to: theirs, atomically: true, encoding: .utf8)
		try world.ben.edit { $0.clips[2].start = 22 }

		guard case .failed(let why) = world.ben.sharing.share().outcome else {
			Issue.record("a merge was started over uncommitted work"); return
		}
		#expect(why.contains("uncommitted"))
		// Their file is untouched.
		#expect(try String(contentsOf: theirs, encoding: .utf8) == "changed, and not committed")
	}

	// MARK: - Footage

	@Test func footageThisMachineHasNotGotIsNamed() throws {
		let world = try world()
		defer { world.tidy() }
		// `one.mov` was never on anybody's disk — the takes are text and the
		// recordings are not in the repository.
		#expect(world.ben.sharing.missingFootage() == ["one.mov"])
	}

	@Test func footageThatIsThereIsNotComplainedAbout() throws {
		let world = try world()
		defer { world.tidy() }
		try Data().write(to: world.ben.root.appendingPathComponent("one.mov"))
		#expect(world.ben.sharing.missingFootage().isEmpty)
	}
}
