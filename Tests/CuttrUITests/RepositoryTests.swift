import AppKit
import CuttrKit
import Testing
@testable import CuttrUI

/// What git says about the folder a document sits in — and, more importantly,
/// what happens when it says nothing.
///
/// **A repository is a fact about a folder, not about cuttr.** Footage lives on
/// a volume that is not under version control: `/Volumes/500G` is the ordinary
/// case, not an edge one. Every question here has to answer "nothing" quietly,
/// and the capsule has to look right without a right half.
@Suite @MainActor struct RepositoryTests {

	/// A folder that is a work tree, and one that is not.
	@Test func itFindsAWorkTreeAndIsQuietWhenThereIsNone() throws {
		// This test is running inside a checkout, so there is one to find.
		let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
		if let root = GitRepository.root(for: here) {
			#expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path)
				|| GitRepository.branch(in: root) != nil,
			        "found a root that git does not recognise: \\(root.path)")
		}

		// A folder that is certainly not one. Under the temporary directory,
		// which is not inside any checkout on this machine.
		let outside = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("cuttr-not-a-repo-\\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: outside) }
		#expect(GitRepository.root(for: outside) == nil,
		        "a plain folder was taken for a work tree")
		#expect(GitRepository.branches(in: outside).isEmpty)
		#expect(GitRepository.branch(in: outside) == nil)
		#expect(GitRepository.forge(in: outside) == nil)
	}

	/// A folder that does not exist at all is not an error either — a project
	/// whose file has been moved out from under it asks the same question.
	@Test func aFolderThatIsNotThereSaysNothing() {
		let gone = URL(fileURLWithPath: "/Volumes/nothing-here-\(UUID().uuidString)/take.cuttr")
		#expect(GitRepository.root(for: gone) == nil)
	}

	/// The remote, written either way round, becomes an address.
	///
	/// Named after the host rather than after a vendor: an Enterprise install is
	/// `git.example.com`, and calling that GitHub would be a guess where the
	/// address is a fact.
	@Test func itReadsARemoteWrittenEitherWay() {
		let ssh = GitRepository.Forge(host: "github.com", owner: "rnd7", name: "cuttr")
		#expect(ssh.displayName == "GitHub")
		#expect(ssh.home?.absoluteString == "https://github.com/rnd7/cuttr")
		#expect(ssh.branch("ui")?.absoluteString == "https://github.com/rnd7/cuttr/tree/ui")
		#expect(ssh.commits(on: "ui")?.absoluteString
			== "https://github.com/rnd7/cuttr/commits/ui")
		#expect(ssh.pullRequests?.absoluteString == "https://github.com/rnd7/cuttr/pulls")

		let enterprise = GitRepository.Forge(host: "git.example.com", owner: "team", name: "film")
		#expect(enterprise.displayName == "git.example.com",
		        "an Enterprise host was called GitHub")

		// A branch with a slash in it is a path component, not four.
		let slashed = ssh.branch("feature/one")
		#expect(slashed?.absoluteString.contains("feature/one") == true)
	}

	/// Nothing is offered that cannot work: no Fork row without Fork, no Abydos
	/// row without Abydos. A menu item that cannot work is worse than an absent
	/// one.
	@Test func handoffsAreOnlyOfferedWhenTheyAreInstalled() {
		for handoff in [BranchMenu.Handoff.fork, .abydos] {
			if handoff.isInstalled {
				#expect(handoff.applicationURL() != nil)
				#expect(handoff.icon() != nil, "\\(handoff.bundleIdentifier) has no icon")
			} else {
				#expect(handoff.applicationURL() == nil)
				#expect(handoff.icon() == nil)
			}
		}
		// One that is certainly not installed.
		let absent = BranchMenu.Handoff(bundleIdentifier: "com.example.nothing",
		                                conventionalPath: "/Applications/Nothing.app")
		#expect(!absent.isInstalled)
		#expect(absent.icon() == nil)
	}

	/// The branch you are on is ticked and cannot be chosen: checking out the
	/// branch you are already on is nothing.
	@Test func theCurrentBranchIsTickedAndNotOfferable() throws {
		let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
		guard let root = GitRepository.root(for: here),
		      let branch = GitRepository.branch(in: root),
		      let menu = BranchMenu.menu(for: root, branch: branch)
		else { return }

		let named = menu.items.filter { $0.title == branch }
		#expect(named.count == 1, "the current branch is listed \\(named.count) times")
		let current = try #require(named.first)
		#expect(current.state == .on, "the current branch is not ticked")
		#expect(!current.isEnabled, "the branch you are on is offered as somewhere to go")
	}

	/// And a checkout is refused while a take from that repository is open.
	///
	/// A `TakeDocument` holds its cuts in memory and never watches its file, so
	/// a work tree moving under it leaves the window unaware — the next save
	/// writes the stale take over the branch's own.
	@Test func aCheckoutIsNotOfferedOverAnOpenTake() throws {
		let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
		guard let root = GitRepository.root(for: here),
		      let branch = GitRepository.branch(in: root)
		else { return }

		let was = BranchMenu.documentsInTheWay
		defer { BranchMenu.documentsInTheWay = was }

		BranchMenu.documentsInTheWay = { _ in [] }
		let free = try #require(BranchMenu.menu(for: root, branch: branch))
		let others = free.items.filter { $0.title != branch && !$0.isSeparatorItem
			&& $0.submenu == nil && $0.image == nil }
		// Nothing to say if this checkout has only one branch.
		if let offered = others.first {
			#expect(offered.isEnabled, "a checkout was refused with nothing in the way")
		}

		BranchMenu.documentsInTheWay = { _ in ["mia-take-1"] }
		let blocked = try #require(BranchMenu.menu(for: root, branch: branch))
		let stopped = blocked.items.filter { $0.title != branch && !$0.isSeparatorItem
			&& $0.submenu == nil && $0.image == nil }
		for item in stopped {
			#expect(!item.isEnabled, "\\(item.title) was offered over an open take")
			#expect(item.toolTip?.contains("mia-take-1") == true,
			        "the row does not say what is in the way")
		}
	}
}
