import AppKit
import Foundation

/// The questions that need a network, and what to say when the answer is a
/// failure.
///
/// **Why not on ``GitRepository``.** That type answers questions about a folder
/// and answers `nil` to every one it cannot — which is right for "is this a work
/// tree" and useless here. A push that fails has a *reason*, the reason is the
/// only useful thing to tell somebody, and `GitRepository.run` reads stderr into
/// a variable and throws it away. So these go through
/// ``ProjectVersions/Plumbing``, which already keeps it, already avoids the
/// deadlock a big `update-index` finds, and already runs with
/// `GIT_TERMINAL_PROMPT=0`.
///
/// Everything that reaches a remote passes a timeout. Without one, a repository
/// on a host that accepts the connection and then says nothing leaves Share
/// spinning with no way out, and the person cannot tell that from slow.
struct GitRemote: Sendable {

	let plumbing: ProjectVersions.Plumbing

	/// Long enough for a big fetch on a slow line, short enough that somebody
	/// does not think the program has died.
	static let patience: TimeInterval = 45

	init(root: URL) { plumbing = ProjectVersions.Plumbing(root: root) }

	// MARK: - What the remote is

	/// The upstream of a branch — `origin/main` — or nothing when it has none.
	///
	/// A branch with no upstream is the ordinary state of one somebody just
	/// made, and it is not an error: it means the first push has to say where
	/// it is going.
	func upstream(of branch: String) -> String? {
		guard let said = plumbing.run(
			["rev-parse", "--abbrev-ref", "--symbolic-full-name", "\(branch)@{upstream}"]),
			said.status == 0, !said.out.isEmpty else { return nil }
		return said.out
	}

	/// Whether there is a remote called `origin` at all.
	func hasOrigin() -> Bool {
		guard let said = plumbing.run(["remote", "get-url", "origin"]) else { return false }
		return said.status == 0 && !said.out.isEmpty
	}

	// MARK: - Traffic

	/// Brings the remote's refs up to date. Nothing in the work tree moves.
	func fetch() -> Trouble? {
		guard let said = plumbing.run(["fetch", "--prune", "origin"],
		                              timeout: Self.patience) else {
			return .noGit
		}
		return said.status == 0 ? nil : Trouble.read(said)
	}

	/// How far apart a branch and its upstream have got: what we have that they
	/// have not, and what they have that we have not.
	func counts(_ branch: String, against upstream: String) -> (ahead: Int, behind: Int)? {
		guard let said = plumbing.run(
			["rev-list", "--left-right", "--count", "\(upstream)...\(branch)"]),
			said.status == 0 else { return nil }
		let parts = said.out.split(whereSeparator: { $0 == "\t" || $0 == " " })
			.compactMap { Int($0) }
		guard parts.count == 2 else { return nil }
		// `--left-right` counts the left side first, and the left side is the
		// upstream: what they have that we have not is *behind*.
		return (ahead: parts[1], behind: parts[0])
	}

	/// Sends a branch. `setUpstream` for one that has never been pushed.
	///
	/// There is no force here and there is no argument that constructs one. A
	/// program that force-pushes on somebody's behalf is a program that can
	/// destroy work nobody can get back, and no outcome this feature has is
	/// worth that.
	func push(_ branch: String, setUpstream: Bool = false) -> Trouble? {
		var arguments = ["push"]
		if setUpstream { arguments.append("--set-upstream") }
		arguments += ["origin", "refs/heads/\(branch):refs/heads/\(branch)"]
		guard let said = plumbing.run(arguments, timeout: Self.patience) else { return .noGit }
		return said.status == 0 ? nil : Trouble.read(said)
	}
}

/// Why a thing that reaches the network did not work, in a form the window can
/// turn into one line.
///
/// **Why classify at all.** `GIT_TERMINAL_PROMPT=0` is what stops git hanging on
/// a credential prompt nobody can see, and the price is that an HTTPS remote
/// with no credential helper fails with `could not read Username`, which means
/// nothing to the person this feature is for. Every case here exists because it
/// needs a *different next step*, and the wording says what that step is without
/// using the words "credential helper".
public enum Trouble: Equatable, Sendable {
	/// git is not on this machine.
	case noGit
	/// The host could not be reached at all.
	case unreachable
	/// The host was reached and would not say who we are.
	case unauthenticated(host: String?)
	/// We are known and are not allowed to push here.
	case forbidden
	/// Somebody else pushed between our fetch and our push.
	case raced
	/// It took too long and was stopped.
	case tooSlow
	/// Anything else, in git's own words — which are better than a guess.
	case said(String)

	/// One line, in the program's voice.
	public var sentence: String {
		switch self {
		case .noGit:
			return "git is not installed"
		case .unreachable:
			return "the remote could not be reached — check the network"
		case .unauthenticated(let host):
			let where_ = host.map { " to \($0)" } ?? ""
			return "not signed in\(where_) — open the folder in a git client once and "
				+ "sign in there, and this will work afterwards"
		case .forbidden:
			return "no permission to push to this repository"
		case .raced:
			return "somebody else pushed at the same moment"
		case .tooSlow:
			return "the remote did not answer"
		case .said(let what):
			return what
		}
	}

	/// Whether trying the whole cycle again could reasonably work. Only the
	/// race: everything else needs somebody to do something first.
	public var isWorthRetrying: Bool { self == .raced }

	/// Reads git's own complaint.
	///
	/// Matched on substrings rather than on exit status, because git says all
	/// of these with the same status. Order matters: a rejection for
	/// permissions and a rejection for a race both say "rejected", and the
	/// permission one says so as well as something else.
	static func read(_ said: ProjectVersions.Plumbing.Said) -> Trouble {
		if said.timedOut { return .tooSlow }
		let text = said.error.isEmpty ? said.out : said.error
		let lower = text.lowercased()

		if lower.contains("could not resolve host")
			|| lower.contains("could not resolve proxy")
			|| lower.contains("connection refused")
			|| lower.contains("network is unreachable")
			|| lower.contains("operation timed out")
			|| lower.contains("failed to connect") {
			return .unreachable
		}
		// `terminal prompts disabled` is the shape this takes with
		// `GIT_TERMINAL_PROMPT=0`, which is the ordinary case for an HTTPS
		// remote on a machine that has never been signed in.
		if lower.contains("could not read username")
			|| lower.contains("could not read password")
			|| lower.contains("terminal prompts disabled")
			|| lower.contains("authentication failed")
			|| lower.contains("invalid username or password")
			|| lower.contains("permission denied (publickey)") {
			return .unauthenticated(host: host(in: text))
		}
		if lower.contains("permission to")
			|| lower.contains("does not appear to be a git repository")
			|| lower.contains("write access")
			|| lower.contains("403") {
			return .forbidden
		}
		if lower.contains("non-fast-forward")
			|| lower.contains("fetch first")
			|| lower.contains("behind its remote counterpart")
			|| (lower.contains("rejected") && lower.contains("push")) {
			return .raced
		}
		return .said(text.split(separator: "\n").first.map(String.init) ?? "git said nothing")
	}

	/// The host out of whatever git printed, when there is one to find. Named
	/// after what it is rather than guessed at: an Enterprise install is
	/// `git.example.com` and calling that GitHub would be wrong.
	private static func host(in text: String) -> String? {
		guard let range = text.range(of: "https://") ?? text.range(of: "git@") else { return nil }
		let rest = text[range.upperBound...]
		let host = rest.prefix { !":/'\" \n\t".contains($0) }
		return host.isEmpty ? nil : String(host)
	}
}
