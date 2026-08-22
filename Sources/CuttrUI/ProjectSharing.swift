import CuttrCompose
import CuttrKit
import Foundation

/// Sending a project to the people working on it with you, and bringing back
/// what they did.
///
/// **Why this one is allowed to move HEAD.** ``ProjectVersions`` goes to real
/// trouble not to: it commits onto `refs/cuttr/saves` through plumbing so that
/// HEAD, the index and the working tree are never touched, because it runs on a
/// timer and a program that quietly commits to `main` while somebody is halfway
/// through something is worse than no safety net. None of that argument applies
/// here. A commit somebody else can fetch has to be reachable from a branch, and
/// this only ever happens because a person pressed a button. The two are
/// separated by *who asked*, and that is the whole distinction.
///
/// **What it will and will not touch.** Exactly the files
/// ``ProjectVersions/files()`` reports — the project, the takes it names, and
/// those takes' transcripts and solved anchors. The commit is built on a
/// temporary index seeded from HEAD, so anything the person has staged or left
/// dirty elsewhere is not read, not committed and not reverted.
/// `nothingElseIsCommitted` holds that down, and it is the test that matters
/// most in this file.
///
/// Nonisolated for the same reason ``ProjectVersions`` is: this is a handful of
/// subprocesses and one of them talks to a network, and the window has no
/// business waiting on the main thread for either.
public struct ProjectSharing: Sendable {

	public let project: URL
	public let root: URL

	@MainActor
	public init?(project: URL) {
		guard let root = GitRepository.root(for: project) else { return nil }
		self.project = project.resolvingSymlinksInPath().standardizedFileURL
		self.root = root.resolvingSymlinksInPath().standardizedFileURL
	}

	public init(project: URL, root: URL) {
		self.project = project.resolvingSymlinksInPath().standardizedFileURL
		self.root = root.resolvingSymlinksInPath().standardizedFileURL
	}

	private var versions: ProjectVersions { ProjectVersions(project: project, root: root) }
	private var plumbing: ProjectVersions.Plumbing { ProjectVersions.Plumbing(root: root) }

	// MARK: - What came of it

	/// What a share did, in a form the window can turn into one line.
	///
	/// Most of these are quiet rather than errors. A project on a footage volume
	/// with no repository, a branch nobody has pushed yet, and a share with
	/// nothing to send are all ordinary.
	public enum Outcome: Sendable, Equatable {
		/// Everything already agreed.
		case nothingToSend
		/// Work went out and nothing came back.
		case sent
		/// Work came in, and mine went out if there was any.
		case brought(theirs: Int, sentMine: Bool)
		/// Both sides changed the same thing and somebody has to choose.
		case mustChoose([String])
		case noRepository
		/// A work tree with no `origin`. Not an error: plenty of repositories
		/// are one person's and never leave the machine.
		case noRemote
		/// Mid-merge, mid-rebase, mid-anything.
		case busy(String)
		/// An open take window would write its stale cuts over what arrived.
		case inTheWay(String)
		case trouble(Trouble)
		case failed(String)

		/// Whether this is somebody's to do something about.
		///
		/// A refusal names a thing that has to happen first — close a take
		/// window, sign in, finish a rebase — and saying it once in a status
		/// line that is gone by the time they look is how "it refused" reads as
		/// "nothing happened". The quiet outcomes stay quiet.
		public var needsAnswering: Bool {
			switch self {
			case .nothingToSend, .sent, .brought, .mustChoose, .noRemote:
				return false
			case .noRepository, .busy, .inTheWay, .trouble, .failed:
				return true
			}
		}

		/// One line, in the program's own words. No `ahead`, no `behind`, no
		/// `fast-forward`, and no commit hash — somebody who knew those words
		/// would be using a git client.
		public var sentence: String {
			switch self {
			case .nothingToSend: return "nothing to send — everybody has the same cut"
			case .sent: return "sent your changes"
			case .brought(let theirs, let sentMine):
				let came = theirs == 1 ? "1 change" : "\(theirs) changes"
				return sentMine ? "brought in \(came) and sent yours" : "brought in \(came)"
			case .mustChoose(let what):
				let list = what.prefix(3).joined(separator: ", ")
				let more = what.count > 3 ? " and \(what.count - 3) more" : ""
				return "somebody else changed \(list)\(more) too — choose which to keep"
			case .noRepository: return "this project is not in a git repository"
			case .noRemote: return "this repository has nowhere to send to"
			case .busy(let what): return "\(what) is in progress — finish it first"
			case .inTheWay(let why): return why
			case .trouble(let trouble): return trouble.sentence
			case .failed(let why): return why
			}
		}
	}

	// MARK: - Committing what is ours

	/// What a commit attempt came to.
	enum Committed: Equatable {
		/// A new commit, and the branch now points at it.
		case made(String)
		/// The project's files are already exactly what HEAD has.
		case nothingChanged
		case failed(String)
	}

	/// Puts the project's own files on the current branch, and nothing else.
	///
	/// The order, and every step of it deliberate:
	///
	/// 1. seed a *temporary* index from HEAD, so the tree starts as the branch
	///    has it rather than as the person's index has it;
	/// 2. `update-index --add` only our paths into that index;
	/// 3. `write-tree`, and stop if it is the tree HEAD already has;
	/// 4. `commit-tree -p HEAD`;
	/// 5. `update-ref` the branch, with the old value named so that a second
	///    window committing at the same moment loses rather than overwrites;
	/// 6. refresh the *real* index for our paths only, so `git status` does not
	///    afterwards report as modified the files we have just committed.
	///
	/// Step 6 is the only time this touches the person's own index, it touches
	/// exactly the paths in step 2, and it leaves them saying what HEAD now
	/// says — which is the state they would be in if the person had committed
	/// by hand.
	func commitOurs(on branch: String) -> Committed {
		let git = plumbing
		let entries = versions.trackable()
		guard !entries.isEmpty else { return .nothingChanged }

		let index = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
			.appendingPathComponent("cuttr-share-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: index) }

		let head = git.tip(of: "HEAD")
		// An unborn branch — a repository somebody has just made — has no HEAD
		// to read, and an empty index is the right place to start from.
		if head != nil {
			guard let seeded = git.run(["read-tree", "HEAD"], index: index),
			      seeded.status == 0 else { return .failed("git could not read the branch") }
		}
		let added = git.run(["update-index", "--add", "--"] + entries.map(\.path), index: index)
		guard let added, added.status == 0 else {
			let why = added?.error ?? ""
			return .failed(why.isEmpty ? "git could not stage the project" : why)
		}
		guard let tree = git.run(["write-tree"], index: index), tree.status == 0,
		      !tree.out.isEmpty else { return .failed("git could not write the tree") }

		if let head, git.tree(of: head) == tree.out { return .nothingChanged }

		let name = project.deletingPathExtension().lastPathComponent
		let was = head.flatMap { git.project(in: $0) }
		let now = (try? String(contentsOf: project, encoding: .utf8))
			.flatMap { try? ProjectReader.read($0) }
		let touched = head.map { git.changedFiles(from: $0, to: tree.out) }
			?? entries.map(\.path)
		let said = head == nil ? [] : ProjectVersions.changes(from: was, to: now, files: touched)
		let message = ProjectVersions.message(name: name, changes: said,
		                                      files: touched, at: Date())

		var arguments = ["commit-tree", tree.out]
		if let head { arguments += ["-p", head] }
		let made = git.run(arguments, input: Data(message.utf8))
		guard let made, made.status == 0, !made.out.isEmpty else {
			let why = made?.error ?? ""
			return .failed(why.isEmpty ? "git could not make the commit" : why)
		}
		guard let moved = git.run(["update-ref", "refs/heads/\(branch)", made.out, head ?? ""]),
		      moved.status == 0 else {
			return .failed("the branch moved while this was being written")
		}
		refreshIndex(for: entries.map(\.path))
		return .made(made.out)
	}

	/// Brings the person's own index into line for the paths just committed,
	/// and for no others.
	///
	/// Without this the files would read as modified for ever after: the index
	/// would still hold the blob HEAD had before the commit, while the working
	/// tree holds what was just committed. Named paths and `--` so that nothing
	/// can be read as an option, and a failure is not fatal — a stale index
	/// entry is untidy where a refusal to share would be a broken feature.
	private func refreshIndex(for paths: [String]) {
		guard !paths.isEmpty else { return }
		_ = plumbing.run(["update-index", "--add", "--"] + paths)
	}

	// MARK: - Where it stands

	/// The branch this work tree is on, or nothing when it is not on one.
	func branch() -> String? {
		guard let said = plumbing.run(["symbolic-ref", "--short", "--quiet", "HEAD"]),
		      said.status == 0, !said.out.isEmpty else { return nil }
		return said.out
	}

	/// Why a share has to wait, or `nil` when it does not.
	///
	/// The same two refusals a checkout and a restore already make, for the
	/// same reason: a `TakeDocument` holds its cuts in memory and never
	/// re-reads, so anything that rewrites a take file under an open window
	/// leaves that window unaware — and its next save puts the stale take back
	/// over what just arrived.
	@MainActor
	func mustWait() -> Outcome? {
		if let busy = plumbing.midSomething() { return .busy(busy) }
		if let waiting = ProjectVersions.inTheWay(of: root) { return .inTheWay(waiting) }
		return nil
	}
}

// MARK: - The whole of sharing

public extension ProjectSharing {

	/// What a share needs somebody to answer, and enough to ask them with.
	///
	/// Held rather than applied. The spec's rule is that dismissing the chooser
	/// leaves the work tree exactly as it was, so the merge is worked out,
	/// *abandoned*, and worked out again when the answers come back — which is
	/// deterministic, because nothing on either side has moved in between.
	struct MustChoose: @unchecked Sendable {
		public var takes: [(path: String, merged: TakeMerge.Merged)]
		public var projects: [(path: String, merged: ProjectMerge.Merged)]

		public init(takes: [(path: String, merged: TakeMerge.Merged)],
		            projects: [(path: String, merged: ProjectMerge.Merged)]) {
			self.takes = takes
			self.projects = projects
		}

		/// Every conflict across every file, for the sheet to walk through.
		public var titles: [String] {
			takes.flatMap { $0.merged.conflicts.map(\.title) }
				+ projects.flatMap { $0.merged.conflicts.map(\.title) }
		}

		public var isEmpty: Bool { takes.isEmpty && projects.isEmpty }
	}

	/// Send what is here and bring back what is not, in that order.
	///
	/// The caller keeps a version first — ``ComposeDocument/keepAVersion()`` —
	/// so that whatever this does, the state before it is recoverable from
	/// `refs/cuttr/saves`. This does not do it itself, because the document is
	/// the thing that knows whether anything is owed.
	/// Not on the main actor: this fetches and pushes, and a window that waited
	/// on the main thread for a remote would beachball for as long as the remote
	/// took. The caller checks ``mustWait()`` first, on the main actor, because
	/// asking which take windows are open is a question only the main actor can
	/// answer.
	func share() -> (outcome: Outcome, choose: MustChoose?) {
		if let busy = plumbing.midSomething() { return (.busy(busy), nil) }
		guard let branch = branch() else {
			return (.failed("this repository is not on a branch"), nil)
		}
		let remote = GitRemote(root: root)
		guard remote.hasOrigin() else { return (.noRemote, nil) }

		let committed = commitOurs(on: branch)
		if case .failed(let why) = committed { return (.failed(why), nil) }
		let hadOwnWork = committed != .nothingChanged

		// Three goes at the whole cycle, because the only thing worth trying
		// again is somebody else pushing between our fetch and our push — and
		// that can happen twice.
		var lastTrouble: Trouble?
		for _ in 0 ..< 3 {
			if let trouble = remote.fetch() { return (.trouble(trouble), nil) }

			guard let upstream = remote.upstream(of: branch) else {
				// Never pushed. There is nothing to bring in and nowhere for a
				// merge to go wrong.
				if let trouble = remote.push(branch, setUpstream: true) {
					return (.trouble(trouble), nil)
				}
				return (hadOwnWork ? .sent : .nothingToSend, nil)
			}
			guard let counted = remote.counts(branch, against: upstream) else {
				return (.failed("git could not say how far apart the two are"), nil)
			}
			if counted.ahead == 0, counted.behind == 0 {
				return (hadOwnWork ? .sent : .nothingToSend, nil)
			}

			var brought = 0
			if counted.behind > 0 {
				switch integrate(upstream, on: branch) {
				case .done: brought = counted.behind
				case .mustChoose(let choose):
					return (.mustChoose(choose.titles), choose)
				case .failed(let why): return (.failed(why), nil)
				}
			}
			if counted.ahead == 0, brought == 0 { return (.nothingToSend, nil) }

			if let trouble = remote.push(branch) {
				guard trouble.isWorthRetrying else { return (.trouble(trouble), nil) }
				lastTrouble = trouble
				continue
			}
			if brought > 0 {
				return (.brought(theirs: brought, sentMine: counted.ahead > 0 || hadOwnWork), nil)
			}
			return (.sent, nil)
		}
		return (.trouble(lastTrouble ?? .raced), nil)
	}

	/// Applies the answers and finishes the share the chooser interrupted.
	func finish(choosing choices: [String: TakeMerge.Side]) -> Outcome {
		if let busy = plumbing.midSomething() { return .busy(busy) }
		guard let branch = branch() else { return .failed("this repository is not on a branch") }
		let remote = GitRemote(root: root)
		guard let upstream = remote.upstream(of: branch) else { return .noRemote }

		switch integrate(upstream, on: branch, choosing: choices) {
		case .mustChoose:
			return .failed("something changed while you were choosing — try sharing again")
		case .failed(let why): return .failed(why)
		case .done: break
		}
		if let trouble = remote.push(branch) { return .trouble(trouble) }
		return .sent
	}
}

// MARK: - Bringing theirs in

extension ProjectSharing {

	enum Integrated {
		case done
		case mustChoose(MustChoose)
		case failed(String)
	}

	/// Brings the upstream's commits in.
	///
	/// A fast-forward where one is possible, which is the common case and moves
	/// no files nobody has touched. Otherwise a real merge, with the cuttr files
	/// resolved by ``TakeMerge`` and ``ProjectMerge`` rather than by git's line
	/// merge — the whole reason those exist.
	func integrate(_ upstream: String, on branch: String,
	               choosing choices: [String: TakeMerge.Side] = [:]) -> Integrated {
		let git = plumbing

		// A merge that has to be abandoned is abandoned with `--abort`, and
		// `--abort` can take unrelated uncommitted work with it. So it is not
		// started while there is any: the repository is the person's, and a
		// tidy-up of ours that loses a file of theirs would be unforgivable.
		if let dirty = git.run(["diff", "--name-only", "HEAD"]), dirty.status == 0,
		   !dirty.out.isEmpty {
			return .failed("there are uncommitted changes in this folder — "
				+ "commit or put them aside first, then share")
		}

		if let fast = git.run(["merge", "--ff-only", upstream]), fast.status == 0 {
			return .done
		}
		guard let started = git.run(["merge", "--no-commit", "--no-ff", upstream]) else {
			return .failed("git could not start the merge")
		}
		if started.status == 0 {
			return commitMerge(upstream, message: "Merge \(upstream)")
		}

		let stuck = (git.run(["diff", "--name-only", "--diff-filter=U"])?.out ?? "")
			.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
		guard !stuck.isEmpty else {
			_ = git.run(["merge", "--abort"])
			return .failed(started.error.isEmpty
				? "git could not merge" : started.error)
		}

		var choose = MustChoose(takes: [], projects: [])
		var resolved: [String] = []
		for path in stuck {
			switch path.hasSuffix(".cuttr") ? resolveTake(path, choosing: choices)
				: path.hasSuffix(".cuttrproj") ? resolveProject(path, choosing: choices)
				: Resolution.cannot {
			case .wrote:
				resolved.append(path)
			case .ask(let take, let project):
				if let take { choose.takes.append((path, take)) }
				if let project { choose.projects.append((path, project)) }
			case .cannot:
				// Not ours to merge, and pretending otherwise is how somebody's
				// README gets mangled. Handed back whole.
				_ = git.run(["merge", "--abort"])
				return .failed("\(path) was changed on both sides and cuttr cannot merge it — "
					+ "open the folder in a git client to sort it out")
			}
		}
		guard choose.isEmpty else {
			// Nothing is written until every one is answered.
			_ = git.run(["merge", "--abort"])
			return .mustChoose(choose)
		}
		guard !resolved.isEmpty else {
			_ = git.run(["merge", "--abort"])
			return .failed("git could not merge")
		}
		guard let added = git.run(["add", "--"] + resolved), added.status == 0 else {
			_ = git.run(["merge", "--abort"])
			return .failed("git would not take the merged files")
		}
		return commitMerge(upstream, message: "Merge \(upstream)")
	}

	private func commitMerge(_ upstream: String, message: String) -> Integrated {
		guard let made = plumbing.run(["commit", "--no-edit", "-m", message]),
		      made.status == 0 else {
			// A merge that changed nothing is not a failure.
			if plumbing.midSomething() == nil { return .done }
			_ = plumbing.run(["merge", "--abort"])
			return .failed("git could not finish the merge")
		}
		return .done
	}

	enum Resolution {
		case wrote
		case ask(TakeMerge.Merged?, ProjectMerge.Merged?)
		/// A file this program has no business merging.
		case cannot
	}

	/// The three sides of a conflicted file, as git holds them during a merge:
	/// stage 1 is the base, 2 is ours, 3 is theirs.
	private func stages(_ path: String) -> (base: String?, mine: String?, theirs: String?) {
		func stage(_ n: Int) -> String? {
			guard let said = plumbing.run(["show", ":\(n):\(path)"]), said.status == 0
			else { return nil }
			return String(decoding: said.data, as: UTF8.self)
		}
		return (stage(1), stage(2), stage(3))
	}

	private func resolveTake(_ path: String,
	                         choosing choices: [String: TakeMerge.Side]) -> Resolution {
		let text = stages(path)
		guard let mineText = text.mine, let theirsText = text.theirs,
		      let mine = try? TakeReader.read(mineText),
		      let theirs = try? TakeReader.read(theirsText) else { return .cannot }
		let base = text.base.flatMap { try? TakeReader.read($0) }
		let merged = TakeMerge.merge(base: base, mine: mine, theirs: theirs)

		let unanswered = merged.conflicts.filter { choices[$0.id] == nil }
		guard unanswered.isEmpty else { return .ask(merged, nil) }
		let take = TakeMerge.resolve(merged, choosing: choices)
		guard write(TakeWriter.write(take), to: path) else { return .cannot }
		return .wrote
	}

	private func resolveProject(_ path: String,
	                            choosing choices: [String: TakeMerge.Side]) -> Resolution {
		let text = stages(path)
		guard let mineText = text.mine, let theirsText = text.theirs,
		      let mine = try? ProjectReader.read(mineText),
		      let theirs = try? ProjectReader.read(theirsText) else { return .cannot }
		let base = text.base.flatMap { try? ProjectReader.read($0) }
		let merged = ProjectMerge.merge(base: base, mine: mine, theirs: theirs)

		let unanswered = merged.conflicts.filter { choices[$0.id] == nil }
		guard unanswered.isEmpty else { return .ask(nil, merged) }
		let project = ProjectMerge.resolve(merged, choosing: choices)
		guard write(ProjectWriter.write(project), to: path) else { return .cannot }
		return .wrote
	}

	private func write(_ text: String, to path: String) -> Bool {
		let url = root.appendingPathComponent(path)
		do { try text.write(to: url, atomically: true, encoding: .utf8) } catch { return false }
		return true
	}

	// MARK: - Footage

	/// Media an incoming take names that this machine has not got.
	///
	/// Sharing moves text. The takes are kilobytes and the recordings are
	/// gigabytes and are not in the repository, so two people sharing a project
	/// still need the footage on a shared volume at the same relative paths.
	/// Saying which file is missing is the difference between that and a
	/// project that opens to black.
	public func missingFootage() -> [String] {
		var missing: [String] = []
		for url in versions.files() where url.pathExtension == "cuttr" {
			guard let text = try? String(contentsOf: url, encoding: .utf8),
			      let take = try? TakeReader.read(text) else { continue }
			let beside = url.deletingLastPathComponent()
			for named in [take.video, take.audio?.file].compactMap({ $0 }) {
				let media = URL(fileURLWithPath: named, relativeTo: beside).standardizedFileURL
				if !FileManager.default.fileExists(atPath: media.path) {
					missing.append(media.lastPathComponent)
				}
			}
		}
		return missing
	}
}

// MARK: - Where this project stands

public extension ProjectSharing {

	/// What there is to do, without doing any of it.
	///
	/// **Why this exists.** Everything a share does, it says in one line of the
	/// status bar, and that line is easy to miss and gone by the time anybody
	/// looks. So there was no way to tell "I have three changes nobody else
	/// has" from "the button did nothing" — which is how the button came to be
	/// reported as doing nothing.
	///
	/// Read-only and cheap: `status --porcelain` over the project's own files
	/// and one `rev-list` against the upstream already fetched. **No fetch.**
	/// Asking a network how things stand is not something a window may do on a
	/// timer — that is a password prompt, or a stall, every thirty seconds for
	/// as long as the program is open.
	struct Standing: Sendable, Equatable {
		/// Changes to the project's own files that are not committed yet.
		public var uncommitted: Int
		/// Commits this machine has that the remote has not.
		public var toUpload: Int
		/// Commits the remote had, last time anybody fetched, that this
		/// machine has not.
		public var toMerge: Int
		/// Nothing to send and nothing to bring in.
		public var isSettled: Bool { uncommitted == 0 && toUpload == 0 && toMerge == 0 }
		/// Whether there is anywhere to send at all.
		public var hasRemote: Bool
	}

	func standing() -> Standing {
		let git = plumbing
		guard GitRemote(root: root).hasOrigin() else {
			return Standing(uncommitted: 0, toUpload: 0, toMerge: 0, hasRemote: false)
		}
		// Only the project's own files. Somebody's unrelated dirty README is
		// not something this button has an opinion about.
		let ours = Set(versions.trackable().map(\.path))
		var uncommitted = 0
		if let said = git.run(["status", "--porcelain", "--"] + ours.sorted()),
		   said.status == 0 {
			uncommitted = said.out.split(separator: "\n").filter { !$0.isEmpty }.count
		}

		var up = 0, down = 0
		if let branch = branch(), let upstream = GitRemote(root: root).upstream(of: branch),
		   let counted = GitRemote(root: root).counts(branch, against: upstream) {
			up = counted.ahead
			down = counted.behind
		}
		return Standing(uncommitted: uncommitted, toUpload: up, toMerge: down,
		                hasRemote: true)
	}
}
