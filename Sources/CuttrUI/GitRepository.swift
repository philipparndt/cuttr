import AppKit

/// What git can tell us about the folder a document sits in.
///
/// **A repository is a fact about a folder, not about cuttr.** Footage lives on
/// a volume that may or may not be under version control — `/Volumes/500G` is
/// the ordinary case and it is not a work tree — so every question here answers
/// `nil` rather than complaining, and nothing in the window appears when the
/// answer is nothing.
///
/// Shelled out to `git` rather than linked against libgit2. What is asked is
/// three questions a script could ask, the answers are needed a few times a
/// session, and a dependency that has to be built and signed for one line of
/// output would be the more expensive of the two by a wide margin.
@MainActor
public enum GitRepository {

	/// Where git lives, or nothing. Xcode's git is the one that is always
	/// present; a Homebrew one earlier on the path is found by `xcrun`, which is
	/// not worth a subprocess here.
	private static let tool = URL(fileURLWithPath: "/usr/bin/git")

	/// Runs one git command in a folder and hands back what it said.
	///
	/// Everything is `nil` on failure, including git not being there at all: a
	/// machine without the command line tools is a machine with no branches to
	/// show, which is the same outcome as a folder that is not a repository.
	@discardableResult
	static func run(_ arguments: [String], in folder: URL) -> String? {
		guard FileManager.default.isExecutableFile(atPath: tool.path) else { return nil }
		let process = Process()
		process.executableURL = tool
		process.arguments = arguments
		process.currentDirectoryURL = folder
		let out = Pipe()
		let error = Pipe()
		process.standardOutput = out
		process.standardError = error
		// A repository on a network volume can otherwise ask for credentials on
		// stdin and never come back.
		process.environment = ["GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0"]
		do { try process.run() } catch { return nil }
		let data = out.fileHandleForReading.readDataToEndOfFile()
		_ = error.fileHandleForReading.readDataToEndOfFile()
		process.waitUntilExit()
		guard process.terminationStatus == 0 else { return nil }
		return String(data: data, encoding: .utf8)?
			.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	/// The work tree a file belongs to, if it belongs to one.
	public static func root(for url: URL) -> URL? {
		let folder = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
		guard FileManager.default.fileExists(atPath: folder.path) else { return nil }
		guard let path = run(["rev-parse", "--show-toplevel"], in: folder), !path.isEmpty else {
			return nil
		}
		return URL(fileURLWithPath: path)
	}

	/// Which branch the work tree is on.
	///
	/// `HEAD` when it is detached, which is a real answer and worth showing:
	/// somebody who has checked out a commit should see that rather than the
	/// name of a branch they are not on.
	public static func branch(in root: URL) -> String? {
		guard let name = run(["rev-parse", "--abbrev-ref", "HEAD"], in: root) else { return nil }
		return name.isEmpty ? nil : name
	}

	/// The local branches, most recently committed to first — which puts the
	/// ones somebody actually moves between at the top.
	public static func branches(in root: URL) -> [String] {
		guard let out = run(["branch", "--sort=-committerdate", "--format=%(refname:short)"],
		                    in: root) else { return [] }
		return out.split(separator: "\n")
			.map { $0.trimmingCharacters(in: .whitespaces) }
			.filter { !$0.isEmpty }
	}

	/// Whether anything is uncommitted. Not used to refuse a checkout — git
	/// refuses that itself, and better — but to say so before trying.
	public static func isClean(in root: URL) -> Bool {
		run(["status", "--porcelain"], in: root)?.isEmpty ?? false
	}

	/// Moves the work tree onto another branch, or says why not.
	///
	/// Git's own message on failure: a dirty work tree is the usual reason and
	/// nothing this program could write would explain it better.
	public static func checkout(_ branch: String, in root: URL) -> String? {
		guard FileManager.default.isExecutableFile(atPath: tool.path) else {
			return "git is not installed"
		}
		let process = Process()
		process.executableURL = tool
		process.arguments = ["checkout", branch]
		process.currentDirectoryURL = root
		let error = Pipe()
		process.standardOutput = Pipe()
		process.standardError = error
		process.environment = ["GIT_TERMINAL_PROMPT": "0"]
		do { try process.run() } catch { return error.localizedDescription }
		let said = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
		process.waitUntilExit()
		guard process.terminationStatus != 0 else { return nil }
		let message = (said ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
		return message.isEmpty ? "git exited with \(process.terminationStatus)" : message
	}

	// MARK: - Where else it lives

	/// The remote's web address, when the remote is a place with a website.
	///
	/// Named after the host rather than after a vendor: an Enterprise install is
	/// `git.example.com`, and calling that GitHub would be a guess where the
	/// address is a fact.
	public struct Forge {
		public var host: String
		public var owner: String
		public var name: String

		public var displayName: String {
			host == "github.com" ? "GitHub" : host
		}

		public var home: URL? { URL(string: "https://\(host)/\(owner)/\(name)") }

		public func branch(_ branch: String) -> URL? {
			URL(string: "https://\(host)/\(owner)/\(name)/tree/\(escaped(branch))")
		}

		public func commits(on branch: String) -> URL? {
			URL(string: "https://\(host)/\(owner)/\(name)/commits/\(escaped(branch))")
		}

		public var pullRequests: URL? {
			URL(string: "https://\(host)/\(owner)/\(name)/pulls")
		}

		private func escaped(_ text: String) -> String {
			text.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? text
		}
	}

	/// Reads `origin` and turns it into an address, whether it is written as
	/// `ssh` or as `https`. A remote that is a path on this disk has no website
	/// and gets nothing.
	public static func forge(in root: URL) -> Forge? {
		guard let remote = run(["remote", "get-url", "origin"], in: root), !remote.isEmpty else {
			return nil
		}
		var text = remote
		if text.hasSuffix(".git") { text.removeLast(4) }

		// `git@host:owner/name`
		if let at = text.firstIndex(of: "@"), let colon = text.firstIndex(of: ":"),
		   at < colon, !text.hasPrefix("http") {
			let host = String(text[text.index(after: at)..<colon])
			let path = String(text[text.index(after: colon)...])
			return split(host: host, path: path)
		}
		// `https://host/owner/name` and `ssh://git@host/owner/name`
		guard let url = URL(string: text), let host = url.host else { return nil }
		return split(host: host, path: url.path)
	}

	private static func split(host: String, path: String) -> Forge? {
		let parts = path.split(separator: "/").map(String.init)
		guard parts.count >= 2 else { return nil }
		return Forge(host: host, owner: parts[parts.count - 2], name: parts[parts.count - 1])
	}
}
