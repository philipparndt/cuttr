import AppKit
import Foundation
import Testing
@testable import CuttrUI

/// Reading git's complaint, which is the only part of a network failure that
/// can be tested without a network.
///
/// The strings here are what git actually prints. They are quoted verbatim
/// rather than paraphrased, because the whole value of this type is that it
/// recognises the real thing — a classifier tested against invented text is a
/// classifier tested against itself.
@Suite @MainActor struct GitRemoteTests {

	private func said(_ error: String, status: Int32 = 128,
	                  timedOut: Bool = false) -> ProjectVersions.Plumbing.Said {
		ProjectVersions.Plumbing.Said(status: status, out: "", error: error,
		                              data: Data(), timedOut: timedOut)
	}

	// MARK: - Not signed in

	/// The ordinary case this whole classification exists for: an HTTPS remote
	/// on a machine that has never been signed in. `GIT_TERMINAL_PROMPT=0` is
	/// what turns a hidden prompt into this message.
	@Test func promptsDisabledIsNotSignedIn() {
		let trouble = Trouble.read(said("""
			fatal: could not read Username for 'https://github.com': terminal prompts disabled
			"""))
		#expect(trouble == .unauthenticated(host: "github.com"))
		#expect(trouble.sentence.contains("not signed in"))
		// The words that would send somebody to the wrong place.
		#expect(!trouble.sentence.lowercased().contains("network"))
		#expect(!trouble.sentence.lowercased().contains("credential helper"))
	}

	@Test func aRefusedKeyIsNotSignedInEither() {
		#expect(Trouble.read(said("git@github.com: Permission denied (publickey).\n"
			+ "fatal: Could not read from remote repository."))
			== .unauthenticated(host: "github.com"))
	}

	/// An Enterprise install is named by its host. Calling it GitHub would be a
	/// guess where the address is a fact.
	@Test func theHostIsWhateverTheAddressSays() {
		#expect(Trouble.read(said(
			"fatal: Authentication failed for 'https://git.example.com/team/film.git/'"))
			== .unauthenticated(host: "git.example.com"))
	}

	// MARK: - The others

	@Test func aHostThatIsNotThereIsUnreachable() {
		#expect(Trouble.read(said(
			"fatal: unable to access 'https://github.com/x/y.git/': "
				+ "Could not resolve host: github.com")) == .unreachable)
	}

	@Test func noWriteAccessIsForbidden() {
		#expect(Trouble.read(said("ERROR: Permission to someone/theirs.git denied to me.\n"
			+ "fatal: Could not read from remote repository.")) == .forbidden)
	}

	/// The one worth retrying, and the only one.
	@Test func aRaceIsWorthTryingAgain() {
		let trouble = Trouble.read(said("""
			 ! [rejected]        main -> main (fetch first)
			error: failed to push some refs to 'https://github.com/x/y.git'
			hint: Updates were rejected because the remote contains work that you do not
			"""))
		#expect(trouble == .raced)
		#expect(trouble.isWorthRetrying)
	}

	@Test func nothingElseIsWorthTryingAgain() {
		for trouble: Trouble in [.noGit, .unreachable, .unauthenticated(host: nil),
		                         .forbidden, .tooSlow, .said("something")] {
			#expect(!trouble.isWorthRetrying, "\(trouble) should not be retried")
		}
	}

	/// Being killed for taking too long is read before the text is, because a
	/// process that was terminated may not have printed anything at all.
	@Test func beingStoppedBeatsWhateverItManagedToPrint() {
		#expect(Trouble.read(said("Could not resolve host: github.com", timedOut: true))
			== .tooSlow)
	}

	/// Anything unrecognised comes through in git's own words, first line only.
	/// A guess would be worse than what git said.
	@Test func anythingElseIsGitsOwnWords() {
		#expect(Trouble.read(said("fatal: something nobody has classified\nhint: and a hint"))
			== .said("fatal: something nobody has classified"))
	}

	@Test func everyTroubleSaysSomething() {
		for trouble: Trouble in [.noGit, .unreachable, .unauthenticated(host: "example.com"),
		                         .unauthenticated(host: nil), .forbidden, .raced, .tooSlow] {
			#expect(!trouble.sentence.isEmpty)
			#expect(trouble.sentence.lowercased() == trouble.sentence.lowercased())
		}
	}

	// MARK: - Against a real repository

	/// A folder that is a work tree with no remote. Asked of a real one rather
	/// than a stub: the point is that it answers quietly.
	@Test func aWorkTreeWithNoOriginHasNone() throws {
		let folder = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("cuttr-remote-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: folder) }
		_ = ProjectVersions.Plumbing(root: folder).run(["init", "--quiet"])

		let remote = GitRemote(root: folder)
		#expect(!remote.hasOrigin())
		#expect(remote.upstream(of: "main") == nil)
	}
}
