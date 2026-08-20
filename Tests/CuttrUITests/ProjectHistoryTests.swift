import AppKit
import CuttrCompose
import CuttrKit
import Foundation
import Testing
@testable import CuttrUI

/// Versions kept of a project, in real repositories in temporary directories.
///
/// **The test this file exists for is `nothingIsTouchedInTheRepository`.** A
/// program that commits behind somebody's back is only acceptable if it can be
/// shown not to touch the things they are holding: the working tree, the index,
/// and the branch they are on. Everything else here is a consequence of that
/// claim or a case where the right answer is to do nothing at all.
@Suite @MainActor struct ProjectHistoryTests {

	// MARK: - A repository to work in

	/// A work tree with a project in it, and the plumbing to interrogate it.
	struct Repo {
		let root: URL
		let project: URL
		let git: ProjectVersions.Plumbing

		init(named name: String = "programme", commitFirst: Bool = true) throws {
			let made = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
				.appendingPathComponent("cuttr-history-\(UUID().uuidString)")
			try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
			// A *directory* URL, deliberately. `URL(fileURLWithPath:relativeTo:)`
			// resolves against the base's parent when the base does not know it
			// is a folder, which quietly wrote the whole fixture one level above
			// the repository and made every assertion here pass for the wrong
			// reason.
			root = URL(fileURLWithPath: made.resolvingSymlinksInPath().path, isDirectory: true)
			project = root.appendingPathComponent(name).appendingPathExtension("cuttrproj")
			git = ProjectVersions.Plumbing(root: root)
			_ = git.run(["init", "-q", "-b", "main", "."])
			_ = git.run(["config", "user.name", "Somebody"])
			_ = git.run(["config", "user.email", "somebody@example.com"])
			if commitFirst {
				try "the readme\n".write(to: root.appendingPathComponent("README.md"),
				                        atomically: true, encoding: .utf8)
				_ = git.run(["add", "README.md"])
				_ = git.run(["commit", "-q", "-m", "first"])
			}
		}

		func remove() { try? FileManager.default.removeItem(at: root) }

		func say(_ arguments: [String]) -> String { git.run(arguments)?.out ?? "" }

		var versions: ProjectVersions { ProjectVersions(project: project, root: root) }

		/// How many versions are on the ref.
		var kept: Int {
			guard git.tip(of: ProjectVersions.ref) != nil else { return 0 }
			return Int(say(["rev-list", "--count", ProjectVersions.ref])) ?? 0
		}

		func write(_ project: Project) throws {
			try ProjectWriter.write(project).write(to: self.project, atomically: true,
			                                      encoding: .utf8)
		}

		func write(_ take: Take, at relative: String) throws {
			let url = URL(fileURLWithPath: relative, relativeTo: root)
			try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
			                                        withIntermediateDirectories: true)
			try TakeWriter.write(take).write(to: url, atomically: true, encoding: .utf8)
		}

		func write(_ text: String, at relative: String) throws {
			let url = URL(fileURLWithPath: relative, relativeTo: root)
			try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
			                                        withIntermediateDirectories: true)
			try text.write(to: url, atomically: true, encoding: .utf8)
		}

		func read(_ relative: String) -> String? {
			try? String(contentsOf: URL(fileURLWithPath: relative, relativeTo: root),
			            encoding: .utf8)
		}
	}

	/// A take with a clip, a transcript sidecar and a tracked anchor — one of
	/// each of the three kinds of file a version has to carry.
	private func take(clip slug: String) -> Take {
		Take(video: "../media/one.mov",
		     clips: [Clip(slug: slug, name: "Intro", start: 1, end: 4)],
		     anchors: [Anchor(name: "mia-eye", from: 1, to: 4, markedAt: 2,
		                      point: CGPoint(x: 0.5, y: 0.6), path: "anchors/mia-eye.path")],
		     words: Words(path: "words/one.words", locale: "en-GB"))
	}

	/// A repository with a project, a take and both sidecars on disk.
	private func furnished(_ repo: Repo, clip: String = "intro") throws {
		try repo.write(Project(takes: ["takes/one.cuttr"],
		                       timeline: [TimelineEntry(clip: ClipReference(clip))]))
		try repo.write(take(clip: clip), at: "takes/one.cuttr")
		try repo.write("# words\n", at: "takes/words/one.words")
		try repo.write("# path\n", at: "takes/anchors/mia-eye.path")
	}

	// MARK: - The claim

	/// **Nothing else in the repository moves.**
	///
	/// The whole design rests on this. A dirty working tree, a staged change and
	/// a branch checked out — everything somebody might be holding — and after a
	/// version is kept, `git status`, the index and `HEAD` say exactly what they
	/// said before. If this goes red the feature is not safe and should be off.
	@Test func nothingIsTouchedInTheRepository() throws {
		let repo = try Repo()
		defer { repo.remove() }

		// A dirty file and a staged one.
		try repo.write("edited, not committed\n", at: "README.md")
		try repo.write("staged\n", at: "staged.txt")
		_ = repo.say(["add", "staged.txt"])
		try furnished(repo)

		let statusWas = repo.say(["status", "--porcelain"])
		let headWas = repo.say(["rev-parse", "HEAD"])
		let branchWas = repo.say(["symbolic-ref", "HEAD"])
		let indexWas = repo.say(["ls-files", "--stage"])
		let readmeWas = repo.read("README.md")

		let outcome = repo.versions.keep()
		guard case .kept = outcome else {
			Issue.record("no version was kept: \(outcome)")
			return
		}

		#expect(repo.say(["status", "--porcelain"]) == statusWas, "the working tree changed")
		#expect(repo.say(["rev-parse", "HEAD"]) == headWas, "HEAD moved")
		#expect(repo.say(["symbolic-ref", "HEAD"]) == branchWas, "the branch changed")
		#expect(repo.say(["ls-files", "--stage"]) == indexWas, "the index changed")
		#expect(repo.read("README.md") == readmeWas, "a file on disk was rewritten")
		// And the branch somebody is on has no new commit on it.
		#expect(repo.say(["rev-list", "--count", "main"]) == "1")
	}

	/// The ref is not a branch, so nothing that lists branches lists it — not
	/// `git branch`, not Fork, and not this program's own branch menu in the
	/// title bar, which is the one that would have hurt.
	@Test func theRefIsNotABranch() throws {
		let repo = try Repo()
		defer { repo.remove() }
		try furnished(repo)
		_ = repo.versions.keep()

		let branches = GitRepository.branches(in: repo.root)
		#expect(branches == ["main"], "the saves ref turned up in the branch list: \(branches)")
		#expect(repo.say(["for-each-ref", "--format=%(refname)", "refs/cuttr/"])
			== ProjectVersions.ref)
		// And it is a real commit that `git log` can read, which is the point of
		// putting it in a ref at all.
		#expect(repo.kept == 1)
	}

	/// Never push. Not even with a remote configured and a push that would
	/// succeed.
	@Test func nothingIsPushed() throws {
		let repo = try Repo()
		defer { repo.remove() }
		let elsewhere = repo.root.appendingPathComponent("remote.git")
		_ = repo.say(["init", "-q", "--bare", elsewhere.path])
		_ = repo.say(["remote", "add", "origin", elsewhere.path])
		_ = repo.say(["push", "-q", "origin", "main"])

		let remote = ProjectVersions.Plumbing(root: elsewhere)
		let refsWere = remote.run(["for-each-ref", "--format=%(refname) %(objectname)"])?.out

		try furnished(repo)
		_ = repo.versions.keep()
		try repo.write("changed\n", at: "takes/words/one.words")
		_ = repo.versions.keep()

		#expect(remote.run(["for-each-ref", "--format=%(refname) %(objectname)"])?.out == refsWere,
		        "something reached the remote")
	}

	// MARK: - What goes in

	/// The project, every take it names, and the sidecars those takes name.
	/// Going back has to restore a coherent state rather than half of one.
	@Test func theProjectAndEverythingTextualItIsMadeOf() throws {
		let repo = try Repo()
		defer { repo.remove() }
		try furnished(repo)
		// Footage, which is not ours to keep.
		try repo.write("not really a movie\n", at: "media/one.mov")

		guard case .kept = repo.versions.keep() else {
			Issue.record("no version was kept")
			return
		}
		let held = repo.say(["ls-tree", "-r", "--name-only", ProjectVersions.ref])
			.split(separator: "\n").map(String.init).sorted()
		#expect(held == ["programme.cuttrproj", "takes/anchors/mia-eye.path",
		                 "takes/one.cuttr", "takes/words/one.words"],
		        "the version holds \(held)")
	}

	/// A take on a footage volume is dropped rather than being an error: half a
	/// version — the part that carries the cut — beats none.
	@Test func aTakeOutsideTheWorkTreeIsLeftOut() throws {
		let repo = try Repo()
		defer { repo.remove() }
		let outside = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
			.appendingPathComponent("cuttr-elsewhere-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: outside) }
		let away = outside.appendingPathComponent("far.cuttr")
		try TakeWriter.write(take(clip: "far")).write(to: away, atomically: true, encoding: .utf8)

		try repo.write(Project(takes: ["takes/one.cuttr", away.path]))
		try repo.write(take(clip: "intro"), at: "takes/one.cuttr")
		try repo.write("# words\n", at: "takes/words/one.words")
		try repo.write("# path\n", at: "takes/anchors/mia-eye.path")

		guard case .kept = repo.versions.keep() else {
			Issue.record("no version was kept")
			return
		}
		let held = repo.say(["ls-tree", "-r", "--name-only", ProjectVersions.ref])
		#expect(!held.contains("far.cuttr"))
		#expect(held.contains("programme.cuttrproj"))
	}

	/// A project the person has never committed is still worth keeping. The ref
	/// does not care whether they track it; it records what was on disk.
	@Test func aProjectNobodyHasEverCommittedIsStillKept() throws {
		let repo = try Repo(commitFirst: false)
		defer { repo.remove() }
		try furnished(repo)
		#expect(repo.say(["rev-parse", "--verify", "--quiet", "HEAD"]).isEmpty,
		        "this repository was supposed to have no commits")

		guard case .kept = repo.versions.keep() else {
			Issue.record("an untracked project was not kept")
			return
		}
		#expect(repo.kept == 1)
		// Still nothing on the branch, and still nothing staged.
		#expect(repo.say(["rev-parse", "--verify", "--quiet", "HEAD"]).isEmpty)
		#expect(repo.say(["ls-files"]).isEmpty)
	}

	// MARK: - When to say nothing

	/// No commit when nothing tracked-by-us changed. Footage moved, a render
	/// written, a save that rewrote the same bytes: none of them is a version.
	@Test func nothingIsKeptWhenNothingChanged() throws {
		let repo = try Repo()
		defer { repo.remove() }
		try furnished(repo)

		guard case .kept = repo.versions.keep() else {
			Issue.record("the first version was not kept")
			return
		}
		#expect(repo.versions.keep() == .nothingChanged)
		// A file we do not keep changing is still nothing.
		try repo.write("bigger\n", at: "media/one.mov")
		#expect(repo.versions.keep() == .nothingChanged)
		#expect(repo.kept == 1)

		// And a real edit is something again.
		try repo.write(take(clip: "outro"), at: "takes/one.cuttr")
		guard case .kept = repo.versions.keep() else {
			Issue.record("a re-cut take was not kept")
			return
		}
		#expect(repo.kept == 2)
	}

	/// A footage volume is not a work tree. `/Volumes/500G` is the ordinary
	/// case, and the right answer is silence.
	@Test func aProjectOutsideAnyRepositoryIsQuiet() throws {
		let plain = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
			.appendingPathComponent("cuttr-no-repo-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: plain) }
		let project = plain.appendingPathComponent("programme.cuttrproj")
		try ProjectWriter.write(Project()).write(to: project, atomically: true, encoding: .utf8)

		#expect(ProjectVersions(project: project) == nil,
		        "a plain folder was taken for a work tree")

		// And through the coalescer, which is where it actually happens.
		let history = ProjectHistory()
		var said: [ProjectVersions.Outcome] = []
		history.onOutcome = { said.append($0) }
		history.quiet = 3600
		history.saved(project)
		#expect(history.flushAndWait() == .noRepository)
		#expect(said == [.noRepository])
		#expect(!history.isPending)
	}

	/// A repository halfway through a merge or a rebase is a state a program has
	/// no business writing into.
	@Test func nothingIsKeptMidMergeOrRebase() throws {
		let repo = try Repo()
		defer { repo.remove() }
		try furnished(repo)
		let dot = repo.root.appendingPathComponent(".git")

		for (file, expected) in [("MERGE_HEAD", "a merge"),
		                         ("CHERRY_PICK_HEAD", "a cherry-pick"),
		                         ("REVERT_HEAD", "a revert"),
		                         ("BISECT_LOG", "a bisect")] {
			let head = repo.say(["rev-parse", "HEAD"])
			try head.write(to: dot.appendingPathComponent(file), atomically: true, encoding: .utf8)
			#expect(repo.versions.keep() == .busy(expected))
			try FileManager.default.removeItem(at: dot.appendingPathComponent(file))
		}

		// A rebase is a directory rather than a file.
		let rebase = dot.appendingPathComponent("rebase-merge", isDirectory: true)
		try FileManager.default.createDirectory(at: rebase, withIntermediateDirectories: true)
		#expect(repo.versions.keep() == .busy("a rebase"))
		#expect(repo.kept == 0, "a version was kept during a rebase")
		try FileManager.default.removeItem(at: rebase)

		// And once it is over, the version that was owed goes in.
		guard case .kept = repo.versions.keep() else {
			Issue.record("nothing was kept after the rebase finished")
			return
		}
	}

	// MARK: - Coalescing

	/// A version per thought, not per keystroke.
	///
	/// The compose window writes the project on every edit — dragging an overlay
	/// is dozens of writes in a second — so the clock restarts on each save and
	/// only the pause produces a commit. Driven without the timer here, so the
	/// assertion is about the coalescing and not about a sleep being long
	/// enough; `theClockActuallyFires` covers the timer itself.
	@Test func manySavesBecomeOneVersion() throws {
		let repo = try Repo()
		defer { repo.remove() }
		try furnished(repo)

		let history = ProjectHistory()
		history.quiet = 3600
		var said: [ProjectVersions.Outcome] = []
		history.onOutcome = { said.append($0) }

		for slug in ["alpha", "bravo", "charlie", "delta"] {
			try repo.write(take(clip: slug), at: "takes/one.cuttr")
			history.saved(repo.project)
		}
		#expect(repo.kept == 0, "a version was kept while the editing was still going")
		#expect(history.isPending)

		guard case .kept = history.flushAndWait() else {
			Issue.record("the pause kept nothing")
			return
		}
		#expect(repo.kept == 1, "four saves left \(repo.kept) versions")
		#expect(!history.isPending)
		// The version holds the last state, not the first.
		#expect(repo.say(["show", "\(ProjectVersions.ref):takes/one.cuttr"]).contains("delta"))

		// Flushing again with nothing owed says nothing and keeps nothing.
		#expect(history.flushAndWait() == .nothingChanged)
		#expect(repo.kept == 1)
		#expect(said.count == 1)
	}

	/// And the clock does fire on its own, without anybody flushing it.
	@Test func theClockActuallyFires() async throws {
		let repo = try Repo()
		defer { repo.remove() }
		try furnished(repo)

		let history = ProjectHistory()
		history.quiet = 0.15
		history.saved(repo.project)
		history.saved(repo.project)

		// Polled rather than slept at: a fixed sleep is either flaky or slow.
		var waited = 0
		while repo.kept == 0, waited < 100 {
			try await Task.sleep(nanoseconds: 50_000_000)
			waited += 1
		}
		#expect(repo.kept == 1, "the clock kept \(repo.kept) versions")
	}

	/// A repository that cannot be written to says so once, not every five
	/// seconds for an hour.
	@Test func aFailureIsSaidOnce() throws {
		let history = ProjectHistory()
		var said: [ProjectVersions.Outcome] = []
		history.onOutcome = { said.append($0) }
		history.report(.failed("git fell over"))
		history.report(.failed("git fell over"))
		history.report(.failed("git fell over"))
		#expect(said == [.failed("git fell over")])

		// Something else happening in between makes the next one worth saying.
		history.report(.nothingChanged)
		history.report(.failed("git fell over"))
		#expect(said.count == 3)

		// And the same for a rebase somebody is halfway through all afternoon.
		history.report(.busy("a rebase"))
		history.report(.busy("a rebase"))
		#expect(said.count == 4, "a rebase was announced \(said.count - 3) times")
	}

	// MARK: - Going back

	/// A version comes back onto the disk — and the state being left goes in
	/// first, so going back is not a way to lose the thing you were doing.
	@Test func aVersionComesBack() throws {
		let repo = try Repo()
		defer { repo.remove() }
		try furnished(repo, clip: "intro")
		guard case .kept(let first) = repo.versions.keep() else {
			Issue.record("nothing to go back to")
			return
		}

		// A second version.
		try repo.write(Project(takes: ["takes/one.cuttr"],
		                       timeline: [TimelineEntry(clip: ClipReference("outro"))]))
		try repo.write(take(clip: "outro"), at: "takes/one.cuttr")
		try repo.write("# other words\n", at: "takes/words/one.words")
		guard case .kept = repo.versions.keep() else {
			Issue.record("the second version was not kept")
			return
		}

		// And an edit nobody has kept yet — the thing that must not be lost.
		try repo.write("# words nobody kept\n", at: "takes/words/one.words")

		let headWas = repo.say(["rev-parse", "HEAD"])
		let branchWas = repo.say(["symbolic-ref", "HEAD"])
		let indexWas = repo.say(["ls-files", "--stage"])

		guard case .kept = repo.versions.restore(first.commit) else {
			Issue.record("the restore failed")
			return
		}

		// The files are back.
		#expect(repo.read("takes/words/one.words") == "# words\n")
		#expect(repo.read("takes/one.cuttr")?.contains("intro") == true)
		#expect(repo.read("programme.cuttrproj")?.contains("intro") == true)

		// Nobody's branch moved to do it.
		#expect(repo.say(["rev-parse", "HEAD"]) == headWas, "restoring moved HEAD")
		#expect(repo.say(["symbolic-ref", "HEAD"]) == branchWas)
		#expect(repo.say(["ls-files", "--stage"]) == indexWas, "restoring touched the index")

		// And the un-kept state is on the ref, one commit newer than the two.
		#expect(repo.kept == 3, "the state being left was not kept: \(repo.kept) versions")
		let newest = repo.say(["rev-parse", ProjectVersions.ref])
		#expect(repo.say(["show", "\(newest):takes/words/one.words"])
			.contains("nobody kept"), "the un-kept edit is not recoverable")

		// The list reads newest first and can see all three.
		let list = repo.versions.list()
		#expect(list.count == 3)
		#expect(list.first?.commit == newest)
		#expect(list.last?.commit == first.commit)
		#expect(list.map(\.when).sorted(by: >) == list.map(\.when))
		// And each row says which files it differs in, so somebody scrolling for
		// "before I broke it" can see it without opening anything.
		#expect(list.first?.files == ["takes/words/one.words"])
		#expect(list.last?.files.sorted()
			== ["programme.cuttrproj", "takes/anchors/mia-eye.path",
			    "takes/one.cuttr", "takes/words/one.words"],
		        "the first version lists \(list.last?.files ?? [])")
	}

	/// Restoring is refused mid-rebase for the same reason keeping is.
	@Test func aRestoreIsRefusedMidRebase() throws {
		let repo = try Repo()
		defer { repo.remove() }
		try furnished(repo)
		guard case .kept(let first) = repo.versions.keep() else {
			Issue.record("nothing to go back to")
			return
		}
		let rebase = repo.root.appendingPathComponent(".git/rebase-apply", isDirectory: true)
		try FileManager.default.createDirectory(at: rebase, withIntermediateDirectories: true)
		#expect(repo.versions.restore(first.commit) == .busy("a rebase"))
	}

	/// A restore waits for an open take window, exactly as a checkout does.
	///
	/// A `TakeDocument` holds its cuts in memory and never watches its file, so
	/// writing a version out under one leaves it unaware and its next save puts
	/// the stale take back. Keeping a version is safe over anything — it only
	/// reads — so this guards the way back and not the way in.
	@Test func aRestoreWaitsForAnOpenTake() throws {
		let repo = try Repo()
		defer { repo.remove() }
		let was = BranchMenu.documentsInTheWay
		defer { BranchMenu.documentsInTheWay = was }

		BranchMenu.documentsInTheWay = { _ in [] }
		#expect(ProjectVersions.inTheWay(of: repo.root) == nil)

		BranchMenu.documentsInTheWay = { _ in ["mia-take-1", "mia-take-2"] }
		let waiting = try #require(ProjectVersions.inTheWay(of: repo.root))
		#expect(waiting.contains("mia-take-1"))
		#expect(waiting.contains("mia-take-2"))
	}

	/// A commit that is not there is said rather than guessed at.
	@Test func restoringSomethingThatIsNotThere() throws {
		let repo = try Repo()
		defer { repo.remove() }
		try furnished(repo)
		_ = repo.versions.keep()
		guard case .failed = repo.versions.restore("0000000000000000000000000000000000000000") else {
			Issue.record("a commit that does not exist was restored")
			return
		}
	}

	// MARK: - What the commit says

	/// The message says what changed in the terms the program uses, so a log
	/// read an hour later is a list of edits rather than a list of timestamps.
	@Test func theMessageSaysWhatChanged() {
		let was = Project(takes: ["takes/one.cuttr"],
		                  timeline: [TimelineEntry(clip: ClipReference("intro"))])

		var added = was
		added.timeline.append(TimelineEntry(clip: ClipReference("outro")))
		#expect(ProjectVersions.changes(from: was, to: added, files: []) == ["a clip added"])

		var takes = was
		takes.takes += ["takes/two.cuttr", "takes/three.cuttr"]
		#expect(ProjectVersions.changes(from: was, to: takes, files: []) == ["2 takes added"])

		var named = was
		named.timeline[0].label = "the opening"
		#expect(ProjectVersions.changes(from: was, to: named, files: []) == ["a section named"])
		var renamed = named
		renamed.timeline[0].label = "the intro"
		#expect(ProjectVersions.changes(from: named, to: renamed, files: []) == ["a section renamed"])

		var over = was
		over.overlays = [Overlay(kind: .text("hello", style: nil), span: .times(from: 0, to: 1))]
		#expect(ProjectVersions.changes(from: was, to: over, files: []) == ["an overlay added"])
		var moved = over
		moved.overlays[0].appearances[0].span = .times(from: 2, to: 3)
		#expect(ProjectVersions.changes(from: over, to: moved, files: []) == ["an overlay moved"])

		var wider = was
		wider.output.width = 3840
		#expect(ProjectVersions.changes(from: was, to: wider, files: []) == ["the output changed"])

		// Reordering is not the same as changing, and worth saying so.
		var shuffled = added
		shuffled.timeline.reverse()
		#expect(ProjectVersions.changes(from: added, to: shuffled, files: [])
			== ["the programme re-ordered"])

		// And what the files say, for the edits that do not live in the project.
		#expect(ProjectVersions.changes(from: was, to: was,
		                                files: ["programme.cuttrproj", "takes/mia-1.cuttr",
		                                        "takes/words/mia-1.words",
		                                        "takes/anchors/mia-eye.path"])
			== ["mia-1 re-cut", "mia-1 transcribed", "mia-eye tracked"])
	}

	/// A subject is one line somebody can read in a log, and the fallback says
	/// the project's name and the time, plainly.
	@Test func theSubjectIsOneReadableLine() {
		let when = Date(timeIntervalSince1970: 1_700_000_000)
		let plain = ProjectVersions.message(name: "programme", changes: [], files: ["a"], at: when)
		let subject = plain.split(separator: "\n", omittingEmptySubsequences: false)[0]
		#expect(subject.hasPrefix("programme at "), "the fallback subject is \(subject)")
		#expect(subject.count <= 72)
		#expect(plain.contains("refs/cuttr/saves"), "the body does not say where this went")

		let said = ProjectVersions.message(
			name: "programme", changes: ["a clip added", "an overlay moved"],
			files: ["programme.cuttrproj"], at: when)
		#expect(said.split(separator: "\n", omittingEmptySubsequences: false)[0]
			== "programme: a clip added, an overlay moved")

		// Forty things at once is still one line.
		let many = ProjectVersions.message(
			name: "a project with a rather long name",
			changes: Array(repeating: "an overlay moved", count: 40), files: [], at: when)
		let head = many.split(separator: "\n", omittingEmptySubsequences: false)[0]
		#expect(head.count <= 72, "a subject \(head.count) characters long: \(head)")

		// And a real commit's subject comes out of this, not out of nowhere.
		#expect(!said.isEmpty)
	}

	/// The commit actually carries it, and carries the person's own identity
	/// where they have one.
	@Test func theCommitCarriesTheMessageAndTheAuthor() throws {
		let repo = try Repo()
		defer { repo.remove() }
		try furnished(repo)
		guard case .kept(let version) = repo.versions.keep() else {
			Issue.record("no version was kept")
			return
		}
		#expect(repo.say(["log", "-1", "--format=%s", version.commit]) == version.title)
		#expect(repo.say(["log", "-1", "--format=%an", version.commit]) == "Somebody")
		#expect(repo.say(["log", "-1", "--format=%b", version.commit]).contains("Saved by cuttr"))
		#expect(!version.files.isEmpty)
	}

	// MARK: - Through the document

	/// The window's door: a project written through ``ComposeDocument`` leaves a
	/// version, and nothing in the repository moves to do it.
	@Test func savingThroughTheDocumentKeepsAVersion() throws {
		let repo = try Repo()
		defer { repo.remove() }
		try furnished(repo)

		let document = ComposeDocument()
		document.history.quiet = 3600
		try document.read(from: repo.project)

		let statusWas = repo.say(["status", "--porcelain"])
		let headWas = repo.say(["rev-parse", "HEAD"])

		// The first version arrived all at once, so it is named after the
		// project and the time rather than pretending to describe an edit.
		guard case .kept(let opening) = repo.versions.keep() else {
			Issue.record("the opening state was not kept")
			return
		}
		#expect(opening.title.hasPrefix("programme at "), "the first version says \(opening.title)")

		var project = document.project
		project.timeline.append(TimelineEntry(clip: ClipReference("outro")))
		document.apply(project)
		try document.write()
		#expect(repo.kept == 1, "a version went in before the editing stopped")

		guard case .kept = document.keepAVersion() else {
			Issue.record("closing the window kept nothing")
			return
		}
		#expect(repo.kept == 2)
		#expect(document.versions().count == 2)
		#expect(document.versions().first?.title.contains("a clip added") == true,
		        "the version says \(document.versions().first?.title ?? "nothing")")
		#expect(repo.say(["status", "--porcelain"]) == statusWas)
		#expect(repo.say(["rev-parse", "HEAD"]) == headWas)
	}

	/// And a document going back through the same door reads what it wrote.
	@Test func restoringThroughTheDocument() throws {
		let repo = try Repo()
		defer { repo.remove() }
		try furnished(repo, clip: "intro")

		let document = ComposeDocument()
		document.history.quiet = 3600
		try document.read(from: repo.project)
		document.keepAVersion()
		// Nothing was owed — reading is not saving — so keep the first version
		// off the plumbing directly.
		if repo.kept == 0 { _ = repo.versions.keep() }
		let first = try #require(document.versions().first)

		var project = document.project
		project.timeline = [TimelineEntry(clip: ClipReference("outro"))]
		document.apply(project)
		try document.write()
		document.keepAVersion()
		#expect(document.project.timeline.count == 1)

		guard case .kept = document.restore(first.commit) else {
			Issue.record("the document could not go back")
			return
		}
		#expect(document.project.timeline.first?.clip?.slug == "intro",
		        "the document is still showing what it had before the restore")
	}
}

/// The handle on the ref: what the list shows, and what pressing Restore does.
///
/// Nothing here dispatches a key event into a view. An unhandled one walks up to
/// `NSResponder` and beeps on the machine running the tests.
@Suite @MainActor struct VersionsSheetTests {

	private func versions() -> [ProjectVersions.Version] {
		[ProjectVersions.Version(commit: String(repeating: "a", count: 40),
		                         when: Date(timeIntervalSince1970: 1_700_000_000),
		                         title: "programme: a clip added",
		                         files: ["programme.cuttrproj", "takes/one.cuttr"]),
		 ProjectVersions.Version(commit: String(repeating: "b", count: 40),
		                         when: Date(timeIntervalSince1970: 1_699_990_000),
		                         title: "programme at 09:12",
		                         files: ["programme.cuttrproj"])]
	}

	/// A row per version, and the files of whichever one is chosen.
	@Test func itListsWhatIsThereAndWhatEachOneHolds() {
		var asked: [String] = []
		let sheet = VersionsSheet(versions: versions()) { commit in
			asked.append(commit)
			return .kept(ProjectVersions.Version(commit: commit, when: Date(),
			                                     title: "back", files: []))
		}
		_ = sheet.view
		#expect(sheet.rows == 2)
		// Nothing chosen, nothing to press: Restore on no selection would have
		// to guess which version, and guessing here overwrites somebody's work.
		#expect(!sheet.canRestore)

		sheet.select(0)
		#expect(sheet.canRestore)
		#expect(sheet.filesShown == "programme.cuttrproj\ntakes/one.cuttr")
		sheet.select(1)
		#expect(sheet.filesShown == "programme.cuttrproj")

		sheet.restoreForTesting()
		#expect(asked == [String(repeating: "b", count: 40)],
		        "the wrong version was restored, or none")
	}

	/// What went wrong stays in the sheet. A restore that failed must not close
	/// the sheet as though it had worked.
	@Test func aRefusalIsSaidWithoutClosing() {
		let sheet = VersionsSheet(versions: versions()) { _ in .busy("a rebase") }
		_ = sheet.view
		sheet.select(0)
		sheet.restoreForTesting()
		#expect(sheet.noteForTesting.contains("a rebase"),
		        "the sheet says \(sheet.noteForTesting)")

		let broken = VersionsSheet(versions: versions()) { _ in .failed("git fell over") }
		_ = broken.view
		broken.select(0)
		broken.restoreForTesting()
		#expect(broken.noteForTesting == "git fell over")
	}

	/// The sheet says why pressing it is safe, because that is the only reason
	/// anybody would.
	@Test func itSaysWhatRestoringDoesAndDoesNotDo() {
		#expect(VersionsSheet.explanation.contains("HEAD stays where it is"))
		#expect(VersionsSheet.explanation.contains("kept as a version first"))
	}

	/// Today's versions show a time; older ones show a date as well, or a list
	/// of an afternoon's work reads as one moment repeated.
	@Test func whenAVersionWasKept() {
		let now = Date()
		#expect(!VersionsSheet.when(now).isEmpty)
		let long = VersionsSheet.when(now.addingTimeInterval(-60 * 60 * 24 * 8))
		#expect(long.count > VersionsSheet.when(now).count,
		        "an old version reads the same as today's: \(long)")
	}
}
