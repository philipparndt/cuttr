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
