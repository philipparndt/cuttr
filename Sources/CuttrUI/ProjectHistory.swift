import CuttrCompose
import CuttrKit
import Foundation

/// A version of a project, kept in the repository it lives in, every time the
/// editing goes quiet.
///
/// **Why this exists.** A project window writes its file on every edit, which is
/// the right thing for an as-text tool and a terrible thing for anybody who
/// wants yesterday's cut back: the file only ever holds the last state, and the
/// last state is exactly the one that is wrong when something has gone wrong. So
/// a save also leaves a commit, and an hour later there is a list to go back
/// through.
///
/// **Why it uses plumbing and not `git add`.** This program's whole claim is
/// that the file is the product and that the repository is the person's, not
/// ours. A background `git commit` would put staged changes in their index and
/// commits on whichever branch they happened to be on — an editor quietly
/// committing to `main` while somebody is halfway through a rebase is worse than
/// no safety net at all. Everything here therefore goes through `hash-object`,
/// `write-tree` against a *temporary* index, `commit-tree` and `update-ref`.
/// Nothing else in the repository moves: not `HEAD`, not the index, not one file
/// on disk. `nothingIsTouchedInTheRepository` holds that claim down.
///
/// **Why the ref is outside `refs/heads`.** These are machine-made commits, tens
/// of them in an afternoon. A branch would appear in every `git branch`, in
/// Fork's sidebar, and — worst — in this program's own branch menu in the title
/// bar, where the one useful list would be buried under our own bookkeeping.
/// ``ref`` is `refs/cuttr/saves`: git keeps its objects alive exactly as it does
/// a branch's, `git log refs/cuttr/saves` reads it, and nothing that lists
/// branches lists it. The handle for it is this program's own Versions list,
/// which is a better handle than a branch name anyway because it can say what
/// changed.
///
/// Nonisolated on purpose. A commit is a handful of subprocesses and the window
/// has no business waiting for them, so ``ProjectHistory`` runs this off the
/// main thread; only ``init(project:)`` is on the main actor, because
/// ``GitRepository`` is.
public struct ProjectVersions: Sendable {

	/// Where versions are kept. Not a branch — see the type's own note.
	public static let ref = "refs/cuttr/saves"

	/// One kept version.
	public struct Version: Sendable, Equatable, Identifiable {
		public var commit: String
		public var when: Date
		/// The commit's subject: what changed, in the words the program uses.
		public var title: String
		/// The files this version differs from its predecessor in, repository
		/// relative. Everything, for the first one.
		public var files: [String]

		public var id: String { commit }
		public var short: String { String(commit.prefix(7)) }
	}

	/// What came of trying.
	///
	/// Four of these five are quiet outcomes rather than errors: a footage
	/// volume that is not a work tree, a save that changed nothing, and a
	/// repository mid-rebase are all ordinary, and none of them is worth
	/// interrupting anybody over.
	public enum Outcome: Sendable, Equatable {
		case kept(Version)
		case nothingChanged
		case noRepository
		/// A merge, rebase, cherry-pick or bisect is in progress. Said rather
		/// than done: a program has no business writing into a repository whose
		/// owner is halfway through something.
		case busy(String)
		case failed(String)
	}

	/// The `.cuttrproj`, and the work tree it sits in.
	public let project: URL
	public let root: URL

	/// `nil` when the project is not in a work tree, which is the ordinary case
	/// for a project sitting on a footage volume.
	@MainActor
	public init?(project: URL) {
		guard let root = GitRepository.root(for: project) else { return nil }
		// Physical paths on both sides, or `/tmp` and `/private/tmp` — or
		// `/var` and `/private/var`, which is where a temporary directory
		// actually is — make a file inside the work tree look outside it.
		self.project = project.resolvingSymlinksInPath().standardizedFileURL
		self.root = root.resolvingSymlinksInPath().standardizedFileURL
	}

	/// For the tests, and for a work tree already known.
	public init(project: URL, root: URL) {
		self.project = project.resolvingSymlinksInPath().standardizedFileURL
		self.root = root.resolvingSymlinksInPath().standardizedFileURL
	}

	// MARK: - What is kept

	/// Every textual file this project is made of, as it stands on disk.
	///
	/// The project, every take it names, and the sidecars those takes name: the
	/// `words:` transcript and each anchor's solved path. Not footage, not
	/// renders — going back has to restore a coherent state rather than half of
	/// one, and a project whose takes have since been re-cut is a project
	/// pointing at clips that have moved.
	///
	/// Read from disk rather than from what a window holds in memory: the ref
	/// records what was on the disk, which is the thing somebody wants back.
	public func files() -> [URL] {
		var found: [URL] = [project]
		let base = project.deletingLastPathComponent()
		guard let text = try? String(contentsOf: project, encoding: .utf8),
		      let read = try? ProjectReader.read(text) else { return found }
		for path in read.takes {
			let take = URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL
			found.append(take)
			let beside = take.deletingLastPathComponent()
			guard let takeText = try? String(contentsOf: take, encoding: .utf8),
			      let parsed = try? TakeReader.read(takeText) else { continue }
			if let words = parsed.words {
				found.append(URL(fileURLWithPath: words.path, relativeTo: beside)
					.standardizedFileURL)
			}
			for anchor in parsed.anchors {
				guard let path = anchor.path else { continue }
				found.append(URL(fileURLWithPath: path, relativeTo: beside).standardizedFileURL)
			}
		}
		// A path a project names twice — two takes sharing a transcript, say —
		// is one file, and `update-index` refuses a tree with a name in it
		// twice.
		var seen = Set<String>()
		return found.filter { seen.insert($0.resolvingSymlinksInPath().path).inserted }
	}

	/// The files, as paths inside the work tree, in the order git wants them.
	///
	/// Anything outside the work tree is dropped rather than being an error: a
	/// project under version control may perfectly well name a take on a
	/// footage volume, and half a version is better than none — the project
	/// file itself is the part that carries the cut.
	func trackable() -> [(path: String, url: URL)] {
		let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
		return files().compactMap { url -> (String, URL)? in
			let real = url.resolvingSymlinksInPath().standardizedFileURL
			guard real.path.hasPrefix(prefix),
			      FileManager.default.fileExists(atPath: real.path) else { return nil }
			let path = String(real.path.dropFirst(prefix.count))
			// `update-index --index-info` reads one line per file with a tab
			// before the path. A name holding either character would build a
			// tree with the wrong paths in it, and a wrong tree restores over
			// the wrong files — so such a file is left out rather than guessed
			// at. Nothing in this program makes one.
			guard !path.contains("\t"), !path.contains("\n") else { return nil }
			return (path, real)
		}
		.sorted { $0.0 < $1.0 }
	}

	// MARK: - Keeping one

	/// Hashes what is on disk, builds a tree, and commits it onto ``ref``.
	///
	/// In this order, and every step of it read-only as far as the repository's
	/// working state goes:
	///
	/// 1. refuse if a merge or a rebase is in progress;
	/// 2. `hash-object -w` every file — this writes blobs into `.git/objects`
	///    and nothing else;
	/// 3. `update-index --index-info` into a *temporary* index file, then
	///    `write-tree` from it;
	/// 4. stop if that tree is the tree the last version already has;
	/// 5. `commit-tree` with the current tip as the parent;
	/// 6. `update-ref` with the old tip as the expected value, so two windows
	///    saving at once cannot lose one another's version.
	public func keep() -> Outcome {
		guard FileManager.default.isExecutableFile(atPath: Plumbing.tool.path) else {
			return .noRepository
		}
		let git = Plumbing(root: root)
		if let busy = git.midSomething() { return .busy(busy) }

		let entries = trackable()
		guard !entries.isEmpty else { return .nothingChanged }

		guard let hashed = git.run(["hash-object", "-w", "--"] + entries.map(\.url.path)),
		      hashed.status == 0 else { return .failed("git could not hash the project") }
		let hashes = hashed.out.split(separator: "\n").map(String.init)
		guard hashes.count == entries.count else {
			return .failed("git hashed \(hashes.count) of \(entries.count) files")
		}

		let index = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
			.appendingPathComponent("cuttr-index-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: index) }
		let info = zip(hashes, entries)
			.map { "100644 \($0.0)\t\($0.1.path)\n" }.joined()
		guard let written = git.run(["update-index", "--index-info"],
		                           input: Data(info.utf8), index: index), written.status == 0
		else { return .failed("git could not build the tree") }
		guard let tree = git.run(["write-tree"], index: index), tree.status == 0,
		      !tree.out.isEmpty else { return .failed("git could not write the tree") }

		let parent = git.tip(of: Self.ref)
		if let parent, git.tree(of: parent) == tree.out { return .nothingChanged }

		let was = parent.flatMap { git.project(in: $0) }
		let now = (try? String(contentsOf: project, encoding: .utf8))
			.flatMap { try? ProjectReader.read($0) }
		let touched = parent.map { git.changedFiles(from: $0, to: tree.out) }
			?? entries.map(\.path)
		// Nothing changed in the first version — everything arrived at once —
		// and calling that "a take re-cut" would be a lie in the one place
		// somebody is most likely to read. It gets the name and the time.
		let said = parent == nil ? [] : Self.changes(from: was, to: now, files: touched)
		let name = project.deletingPathExtension().lastPathComponent
		let message = Self.message(name: name, changes: said, files: touched, at: Date())

		var arguments = ["commit-tree", tree.out]
		if let parent { arguments += ["-p", parent] }
		let made = git.run(arguments, input: Data(message.utf8))
		guard let made, made.status == 0, !made.out.isEmpty else {
			let why = made?.error ?? ""
			return .failed(why.isEmpty ? "git could not make the commit" : why)
		}
		// The expected old value, so a second window committing between the
		// read and the write loses rather than overwrites.
		guard let moved = git.run(["update-ref", Self.ref, made.out, parent ?? ""]),
		      moved.status == 0 else {
			return .failed("another version was kept at the same moment")
		}
		return .kept(Version(commit: made.out, when: Date(),
		                     title: message.split(separator: "\n").first.map(String.init) ?? name,
		                     files: touched))
	}

	// MARK: - Going back

	/// The versions kept of this project, newest first.
	///
	/// One `git log`, not one per commit. A record separator in the format and
	/// `--name-only` after it means the files come back in the same output as
	/// the subjects — the first cut of this ran `git show` per version and spent
	/// two hundred subprocesses opening a list.
	public func list(limit: Int = 200) -> [Version] {
		let git = Plumbing(root: root)
		guard git.tip(of: Self.ref) != nil else { return [] }
		guard let log = git.run(["log", "--max-count=\(limit)", "--name-only",
		                         "--format=%x1e%H%x1f%ct%x1f%s", Self.ref]), log.status == 0
		else { return [] }
		return log.out.split(separator: "\u{1e}").compactMap { record in
			var lines = record.split(separator: "\n", omittingEmptySubsequences: true)
				.map(String.init)
			guard !lines.isEmpty else { return nil }
			let header = lines.removeFirst()
				.split(separator: "\u{1f}", omittingEmptySubsequences: false)
			guard header.count >= 3, let seconds = Double(header[1]) else { return nil }
			return Version(commit: String(header[0]),
			               when: Date(timeIntervalSince1970: seconds),
			               title: String(header[2]), files: lines)
		}
	}

	/// Writes a version's files back over the ones on disk.
	///
	/// Two things this deliberately does not do. It does not move anybody's
	/// branch or touch their index — the files are written out of a temporary
	/// index with `checkout-index`, which is the same operation a checkout
	/// performs and none of the bookkeeping. And it does not throw away what is
	/// there now: the current state is kept as a version *first*, so going back
	/// is not a way to lose the thing you were doing.
	///
	/// Nor does it delete. A take added since the version stays on disk; the
	/// restored project simply does not name it, which is a stray file rather
	/// than a lost one.
	public func restore(_ commit: String) -> Outcome {
		guard FileManager.default.isExecutableFile(atPath: Plumbing.tool.path) else {
			return .noRepository
		}
		let git = Plumbing(root: root)
		if let busy = git.midSomething() { return .busy(busy) }
		guard let target = git.run(["rev-parse", "--verify", "--quiet", commit + "^{commit}"]),
		      target.status == 0, !target.out.isEmpty else {
			return .failed("there is no version \(commit)")
		}
		// What is on disk now, before anything is written over it.
		switch keep() {
		case .failed(let why): return .failed(why)
		case .busy(let what): return .busy(what)
		default: break
		}

		let index = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
			.appendingPathComponent("cuttr-restore-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: index) }
		guard let read = git.run(["read-tree", target.out], index: index), read.status == 0
		else { return .failed("git could not read that version") }
		let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
		guard let out = git.run(["checkout-index", "-a", "-f", "--prefix=\(prefix)"],
		                        index: index), out.status == 0
		else { return .failed("git could not write that version out") }

		return .kept(Version(commit: target.out, when: git.when(target.out) ?? Date(),
		                     title: git.subject(of: target.out) ?? "a version",
		                     files: git.files(in: target.out)))
	}

	// MARK: - What to call it

	/// What changed, said the way the program says it.
	///
	/// Cheap on purpose: two `Project` values already parsed, compared field by
	/// field. Nothing here re-reads a take or resolves a programme — this runs
	/// after every quiet moment and a commit message is not worth a render.
	///
	/// Empty when nothing recognisable changed, and then ``message(name:changes:files:at:)``
	/// falls back to the project's name and the time, plainly.
	static func changes(from was: Project?, to now: Project?, files: [String]) -> [String] {
		var said: [String] = []
		if let was, let now {
			said += structural(from: was, to: now)
		}
		// What the files themselves say, for the changes that live outside the
		// project file: a take re-cut in another tab, a transcript run, a face
		// tracked. A version has to hold those too, so it should name them.
		for path in files {
			let url = URL(fileURLWithPath: path)
			let name = url.deletingPathExtension().lastPathComponent
			switch url.pathExtension {
			case "cuttr": said.append("\(name) re-cut")
			case "words": said.append("\(name) transcribed")
			case "path": said.append("\(name) tracked")
			default: break
			}
		}
		return said
	}

	private static func structural(from was: Project, to now: Project) -> [String] {
		var said: [String] = []
		func phrase(_ count: Int, _ one: String, _ many: String, _ verb: String) -> String {
			// "an overlay", not "a overlay". A commit message somebody reads a
			// hundred times a week is worth one line of grammar.
			let article = "aeiou".contains(one.lowercased().first ?? " ") ? "an" : "a"
			return count == 1 ? "\(article) \(one) \(verb)" : "\(count) \(many) \(verb)"
		}
		func flat(_ entries: [TimelineEntry]) -> [TimelineEntry] {
			entries.flatMap { entry -> [TimelineEntry] in
				guard case .group(_, let inner) = entry.source else { return [entry] }
				return [entry] + flat(inner)
			}
		}

		let takesWas = Set(was.takes), takesNow = Set(now.takes)
		let takesIn = takesNow.subtracting(takesWas), takesOut = takesWas.subtracting(takesNow)
		if !takesIn.isEmpty { said.append(phrase(takesIn.count, "take", "takes", "added")) }
		if !takesOut.isEmpty { said.append(phrase(takesOut.count, "take", "takes", "removed")) }

		let before = flat(was.timeline), after = flat(now.timeline)
		if after.count > before.count {
			said.append(phrase(after.count - before.count, "clip", "clips", "added"))
		} else if after.count < before.count {
			said.append(phrase(before.count - after.count, "clip", "clips", "removed"))
		} else {
			let sourcesWas = before.map { $0.source.description }
			let sourcesNow = after.map { $0.source.description }
			if sourcesWas != sourcesNow {
				said.append(sourcesWas.sorted() == sourcesNow.sorted()
					? "the programme re-ordered" : "a clip changed")
			}
			if zip(before, after).contains(where: { $0.trim != $1.trim }) {
				said.append("a clip trimmed")
			}
			if zip(before, after).contains(where: { $0.transition != $1.transition }) {
				said.append("a transition changed")
			}
		}

		let labelsWas = Set(before.compactMap(\.label)), labelsNow = Set(after.compactMap(\.label))
		if labelsWas != labelsNow {
			if labelsWas.count == labelsNow.count {
				said.append("a section renamed")
			} else if labelsNow.count > labelsWas.count {
				said.append(phrase(labelsNow.count - labelsWas.count, "section", "sections", "named"))
			} else {
				said.append("a section unnamed")
			}
		}

		let overlaysWas = was.overlays + before.flatMap(\.overlays)
		let overlaysNow = now.overlays + after.flatMap(\.overlays)
		if overlaysNow.count > overlaysWas.count {
			said.append(phrase(overlaysNow.count - overlaysWas.count, "overlay", "overlays", "added"))
		} else if overlaysNow.count < overlaysWas.count {
			said.append(phrase(overlaysWas.count - overlaysNow.count, "overlay", "overlays", "removed"))
		} else if overlaysWas != overlaysNow {
			// Moved rather than changed, when it is the spans that differ:
			// dragging a lower third along the programme is the commonest edit
			// there is and "an overlay changed" would not help anybody find it.
			said.append(zip(overlaysWas, overlaysNow).contains { $0.spans != $1.spans }
				? "an overlay moved" : "an overlay changed")
		}

		let soundsWas = was.sounds + before.flatMap(\.sounds)
		let soundsNow = now.sounds + after.flatMap(\.sounds)
		if soundsNow.count != soundsWas.count {
			said.append(soundsNow.count > soundsWas.count
				? phrase(soundsNow.count - soundsWas.count, "sound", "sounds", "added")
				: phrase(soundsWas.count - soundsNow.count, "sound", "sounds", "removed"))
		} else if soundsWas != soundsNow {
			said.append("a sound changed")
		}

		let scenesWas = Set(was.scenes.keys), scenesNow = Set(now.scenes.keys)
		if scenesWas != scenesNow {
			if scenesWas.count == scenesNow.count {
				said.append("a scene renamed")
			} else {
				said.append(scenesNow.count > scenesWas.count
					? phrase(scenesNow.count - scenesWas.count, "scene", "scenes", "added")
					: phrase(scenesWas.count - scenesNow.count, "scene", "scenes", "removed"))
			}
		} else if was.scenes != now.scenes {
			said.append("a scene changed")
		}

		if was.styles != now.styles { said.append("a text style changed") }
		if was.profiles != now.profiles { said.append("a look changed") }
		if was.output != now.output { said.append("the output changed") }
		return said
	}

	/// The commit message.
	///
	/// A subject somebody scrolling a log for "before I broke it" can read at a
	/// glance, and a body with the rest of it. The last paragraph is there for
	/// whoever finds one of these in `git log` and wonders what put it there and
	/// whether it moved anything of theirs.
	static func message(name: String, changes: [String], files: [String],
	                    at when: Date) -> String {
		let clock = DateFormatter()
		clock.locale = Locale(identifier: "en_US_POSIX")
		clock.dateFormat = "HH:mm"
		let stamp = DateFormatter()
		stamp.locale = Locale(identifier: "en_US_POSIX")
		stamp.dateFormat = "yyyy-MM-dd HH:mm:ss"

		let head = changes.prefix(3).joined(separator: ", ")
		var subject = head.isEmpty
			? "\(name) at \(clock.string(from: when))"
			: "\(name): \(head)"
		if changes.count > 3 { subject += ", and more" }
		// A subject is a line. A project with forty overlays touched at once
		// would otherwise write one nobody can read in a log.
		if subject.count > 72 { subject = String(subject.prefix(71)) + "…" }

		var body = "\n\nSaved by cuttr at \(stamp.string(from: when)).\n"
		if changes.count > 1 {
			body += "\n" + changes.map { "- \($0)\n" }.joined()
		}
		if !files.isEmpty {
			body += "\nFiles:\n" + files.map { "  \($0)\n" }.joined()
		}
		body += """

			Written with git plumbing onto \(Self.ref), which is not a branch: the
			working tree, the index and HEAD were not touched to make this commit,
			and nothing was pushed.

			"""
		return subject + body
	}

	// MARK: - Talking to git

	/// The subprocess calls, and nothing else.
	///
	/// Its own runner rather than ``GitRepository``'s, for three reasons that
	/// runner cannot serve: plumbing needs data on stdin, it needs the exit
	/// status and stderr rather than `nil`, and it needs the *inherited*
	/// environment — `commit-tree` finds `user.name` in `~/.gitconfig`, and a
	/// process with no `HOME` finds nobody.
	struct Plumbing: Sendable {
		let root: URL
		static let tool = URL(fileURLWithPath: "/usr/bin/git")

		struct Said: Sendable {
			var status: Int32
			var out: String
			var error: String
			var data: Data
		}

		/// Runs one git command in the work tree.
		///
		/// `index` puts a temporary index file in `GIT_INDEX_FILE`, which is the
		/// whole trick: `update-index` and `read-tree` then build a tree without
		/// the repository's own index ever being opened.
		func run(_ arguments: [String], input: Data? = nil, index: URL? = nil) -> Said? {
			guard FileManager.default.isExecutableFile(atPath: Self.tool.path) else { return nil }
			let process = Process()
			process.executableURL = Self.tool
			process.arguments = identity() + arguments
			process.currentDirectoryURL = root
			var environment = ProcessInfo.processInfo.environment
			// A repository on a network volume can otherwise ask for
			// credentials on stdin and never come back.
			environment["GIT_TERMINAL_PROMPT"] = "0"
			environment["GIT_OPTIONAL_LOCKS"] = "0"
			if let index { environment["GIT_INDEX_FILE"] = index.path }
			process.environment = environment

			let out = Pipe(), error = Pipe(), stdin = Pipe()
			process.standardOutput = out
			process.standardError = error
			process.standardInput = stdin
			do { try process.run() } catch { return nil }
			// Written on another queue, and stderr read on a third: a pipe
			// holds 64K and a project with hundreds of takes writes more index
			// lines than that. Everything in one thread deadlocks the day
			// somebody's project gets big.
			DispatchQueue.global().async {
				if let input { stdin.fileHandleForWriting.write(input) }
				try? stdin.fileHandleForWriting.close()
			}
			var complaint = Data()
			let waited = DispatchSemaphore(value: 0)
			DispatchQueue.global().async {
				complaint = error.fileHandleForReading.readDataToEndOfFile()
				waited.signal()
			}
			let said = out.fileHandleForReading.readDataToEndOfFile()
			waited.wait()
			process.waitUntilExit()
			func trimmed(_ data: Data) -> String {
				String(data: data, encoding: .utf8)?
					.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
			}
			return Said(status: process.terminationStatus, out: trimmed(said),
			            error: trimmed(complaint), data: said)
		}

		/// `-c user.name=…`, but only when the person has not said who they are.
		///
		/// Their own identity where they have one — a version is theirs, and a
		/// log full of a program's name says less than a log full of a person's.
		/// The fallback exists because `commit-tree` refuses outright without
		/// one, and a fresh repository on a fresh machine has none.
		private func identity() -> [String] {
			let plain = Process()
			plain.executableURL = Self.tool
			plain.arguments = ["config", "--get", "user.email"]
			plain.currentDirectoryURL = root
			let out = Pipe()
			plain.standardOutput = out
			plain.standardError = Pipe()
			do { try plain.run() } catch { return [] }
			let said = out.fileHandleForReading.readDataToEndOfFile()
			plain.waitUntilExit()
			let email = String(data: said, encoding: .utf8)?
				.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
			guard email.isEmpty else { return [] }
			return ["-c", "user.name=cuttr", "-c", "user.email=cuttr@localhost"]
		}

		/// The commit a ref points at, or nothing when the ref does not exist —
		/// which is what the first version of every project finds.
		func tip(of ref: String) -> String? {
			guard let said = run(["rev-parse", "--verify", "--quiet", ref]), said.status == 0,
			      !said.out.isEmpty else { return nil }
			return said.out
		}

		func tree(of commit: String) -> String? {
			guard let said = run(["rev-parse", commit + "^{tree}"]), said.status == 0,
			      !said.out.isEmpty else { return nil }
			return said.out
		}

		/// Whether the repository is halfway through something.
		///
		/// A merge, a rebase, a cherry-pick, a revert or a bisect. Answering the
		/// question by looking in the git directory rather than by asking git,
		/// because there is no one command that answers it and the files are
		/// the state.
		func midSomething() -> String? {
			guard let dir = run(["rev-parse", "--absolute-git-dir"]), dir.status == 0,
			      !dir.out.isEmpty else { return nil }
			let git = URL(fileURLWithPath: dir.out, isDirectory: true)
			let signs: [(String, String)] = [
				("rebase-merge", "a rebase"),
				("rebase-apply", "a rebase"),
				("MERGE_HEAD", "a merge"),
				("CHERRY_PICK_HEAD", "a cherry-pick"),
				("REVERT_HEAD", "a revert"),
				("BISECT_LOG", "a bisect"),
			]
			for (file, what) in signs
			where FileManager.default.fileExists(atPath: git.appendingPathComponent(file).path) {
				return what
			}
			return nil
		}

		/// The project file as a version of it had it, parsed.
		func project(in commit: String) -> Project? {
			// Whatever the project is called, it is the only `.cuttrproj` in the
			// tree we wrote.
			guard let listed = run(["ls-tree", "-r", "--name-only", commit]),
			      listed.status == 0 else { return nil }
			guard let path = listed.out.split(separator: "\n")
				.first(where: { $0.hasSuffix(".cuttrproj") }) else { return nil }
			guard let blob = run(["show", "\(commit):\(path)"]), blob.status == 0 else { return nil }
			return try? ProjectReader.read(String(decoding: blob.data, as: UTF8.self))
		}

		/// Which paths differ between a commit and a tree.
		func changedFiles(from commit: String, to tree: String) -> [String] {
			guard let said = run(["diff-tree", "-r", "--name-only", "--no-commit-id",
			                      commit, tree]), said.status == 0 else { return [] }
			return said.out.split(separator: "\n").map(String.init)
		}

		/// A commit's subject.
		func subject(of commit: String) -> String? {
			guard let said = run(["log", "-1", "--format=%s", commit]), said.status == 0
			else { return nil }
			return said.out
		}

		/// When a commit was made.
		func when(_ commit: String) -> Date? {
			guard let said = run(["log", "-1", "--format=%ct", commit]), said.status == 0,
			      let seconds = Double(said.out) else { return nil }
			return Date(timeIntervalSince1970: seconds)
		}

		/// Every path in a commit's tree.
		func files(in commit: String) -> [String] {
			guard let said = run(["ls-tree", "-r", "--name-only", commit]), said.status == 0
			else { return [] }
			return said.out.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
		}
	}
}

public extension ProjectVersions {

	/// Why a restore has to wait, or `nil` when it does not.
	///
	/// The same hazard the branch menu refuses a checkout over, and for the same
	/// reason: a ``TakeDocument`` holds its cuts in memory and never watches its
	/// file, so a version written under an open take window leaves that window
	/// unaware — and its next save puts the stale take back over the one just
	/// restored. Keeping a version is safe over anything, because it only ever
	/// reads; writing one out is not.
	@MainActor
	static func inTheWay(of root: URL) -> String? {
		let open = BranchMenu.documentsInTheWay?(root) ?? []
		guard !open.isEmpty else { return nil }
		return "close \(open.joined(separator: ", ")) first — a take window holds "
			+ "its cuts in memory and would write them back over the version"
	}
}

/// When a version gets kept: after a few seconds of quiet, and once more when
/// the window closes.
///
/// **Why not on every write.** The compose window writes the project on every
/// edit — dragging an overlay along the programme is dozens of writes in a
/// second — so a commit per write would be hundreds in an afternoon and a log
/// nobody could read. What somebody wants back is a version per *thought*, so
/// the timer restarts on every save and only a pause in the typing produces a
/// commit. Closing the window flushes, because the pause after the last edit of
/// the day is the one that matters most.
///
/// Owned by ``ComposeDocument``, which knows when the project has been written.
@MainActor
public final class ProjectHistory {

	/// How long the editing has to stop for. Five seconds is about a thought.
	public var quiet: TimeInterval = 5

	/// Said once per outcome, for the status line. Never a sheet and never a
	/// refusal: the save has already happened by the time any of this runs, and
	/// a program that interrupts an edit to talk about its own bookkeeping is
	/// worse than one that keeps no versions at all.
	public var onOutcome: ((ProjectVersions.Outcome) -> Void)?

	/// Which project, and whether it is in a work tree. Re-asked on every save,
	/// because Save As moves a project between folders and one of them may not
	/// be under version control.
	/// The clock. A work item on the main queue rather than a `Timer`, because
	/// the main queue is drained in every run loop mode — a timer in the default
	/// mode alone stops while a menu is down or a divider is being dragged,
	/// which is exactly when somebody has stopped editing.
	private var clock: DispatchWorkItem?
	private var pending: URL?
	/// Whether a keep is already running off the main thread, so two do not
	/// race for the ref.
	private var running = false
	/// The last thing that went wrong, so a repository that cannot be written
	/// to says so once rather than every five seconds.
	private var complained: String?

	public init() {}

	deinit { clock?.cancel() }

	/// A save happened. Start — or restart — the clock.
	public func saved(_ url: URL?) {
		guard let url else { return }
		pending = url
		clock?.cancel()
		let after = quiet
		guard after > 0 else { flush(); return }
		let armed = DispatchWorkItem { [weak self] in
			MainActor.assumeIsolated { self?.flush() }
		}
		clock = armed
		DispatchQueue.main.asyncAfter(deadline: .now() + after, execute: armed)
	}

	/// Keep a version now, if one is owed, without waiting for the clock.
	///
	/// Off the main thread: the window is not made to wait for a subprocess.
	/// Use ``flushAndWait()`` where the answer is needed before carrying on —
	/// closing a window, or a test.
	public func flush() {
		clock?.cancel()
		clock = nil
		guard let url = pending else { return }
		// One at a time, so two keeps do not race for the ref. Re-armed rather
		// than dropped: returning here left the version that the one in flight
		// did not include owed for ever, waiting on a save that might not come.
		if running {
			let again = DispatchWorkItem { [weak self] in
				MainActor.assumeIsolated { self?.flush() }
			}
			clock = again
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: again)
			return
		}
		pending = nil
		running = true
		guard let versions = ProjectVersions(project: url) else {
			running = false
			// Not a work tree. A footage volume is the ordinary case and the
			// silence is the right answer.
			report(.noRepository)
			return
		}
		Task.detached {
			let outcome = versions.keep()
			await MainActor.run { [weak self] in
				self?.running = false
				self?.report(outcome)
			}
		}
	}

	/// The same, on this thread, for when the window is going away and there
	/// will be no later moment to finish in.
	@discardableResult
	public func flushAndWait() -> ProjectVersions.Outcome {
		clock?.cancel()
		clock = nil
		guard let url = pending else { return .nothingChanged }
		pending = nil
		guard let versions = ProjectVersions(project: url) else {
			report(.noRepository)
			return .noRepository
		}
		let outcome = versions.keep()
		report(outcome)
		return outcome
	}

	/// Whether a version is owed — for the tests, and for a menu item that
	/// should not offer to keep one twice.
	public var isPending: Bool { pending != nil }

	/// Internal rather than private so `aFailureIsSaidOnce` can drive it: the
	/// once-only rule is the part that keeps a broken repository from filling
	/// somebody's status line all afternoon, and it is worth a test of its own.
	func report(_ outcome: ProjectVersions.Outcome) {
		switch outcome {
		// Once. A repository that refuses every commit, or one somebody is
		// rebasing all afternoon, would otherwise put the same line in the
		// status bar every five seconds for an hour.
		case .failed(let why), .busy(let why):
			guard complained != why else { return }
			complained = why
		case .kept, .nothingChanged, .noRepository:
			complained = nil
		}
		onOutcome?(outcome)
	}
}
