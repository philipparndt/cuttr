import AppKit
import CuttrCompose
import CuttrKit

public extension Notification.Name {
	/// A project changed — read, reloaded, or edited. The `object` is the
	/// ``ComposeDocument`` it happened to.
	static let cuttrProjectChanged = Notification.Name("de.rnd7.cuttr.projectChanged")
}

/// The project being composed, and everything derived from it.
///
/// Deliberately thinner than ``TakeDocument``. The project file is the
/// interface — it is meant to be edited in a text editor, which is the whole
/// point of an as-text tool — so this window does not try to be a form for every
/// field. It watches the file, re-reads it when it changes, and shows what it
/// means. What it *does* own is the two things a text editor cannot do: playing
/// the result, and marking a point on somebody's face.
@MainActor
public final class ComposeDocument {

	public private(set) var project: Project
	public private(set) var url: URL?
	public private(set) var resolved: ResolvedProject?
	public private(set) var problem: String?
	public private(set) var isDirty = false

	public var onChange: (() -> Void)?

	private var watcher: DispatchSourceFileSystemObject?
	private var watchedDescriptor: CInt = -1
	private var takeObserver: NSObjectProtocol?

	public init(project: Project = Project(), url: URL? = nil) {
		self.project = project
		self.url = url
		// Re-cutting a take in another tab changes this programme: a clip moved
		// or renamed, a face newly tracked. The window should show that at
		// once rather than when somebody thinks to reload.
		takeObserver = NotificationCenter.default.addObserver(
			forName: .cuttrTakeChanged, object: nil, queue: .main
		) { [weak self] note in
			MainActor.assumeIsolated {
				guard let self, let changed = note.object as? URL else { return }
				guard self.takes.contains(where: { $0.url == changed }) else { return }
				self.resolve()
			}
		}
	}

	deinit {
		watcher?.cancel()
		if let takeObserver { NotificationCenter.default.removeObserver(takeObserver) }
	}

	public var baseURL: URL? {
		url.map { URL(fileURLWithPath: $0.deletingLastPathComponent().path, isDirectory: true) }
	}

	public var displayName: String {
		url?.deletingPathExtension().lastPathComponent ?? "Untitled"
	}

	// MARK: - Reading

	public func read(from fileURL: URL) throws {
		let text = try String(contentsOf: fileURL, encoding: .utf8)
		project = try ProjectReader.read(text)
		url = fileURL
		isDirty = false
		resolve()
		watch()
	}

	/// Re-reads the file from disk.
	///
	/// The window is a viewer as much as an editor, so somebody's editor is
	/// expected to be the thing changing the file. Reloading rather than
	/// merging: this window has nothing of its own to lose except an anchor
	/// being solved, and that is written to the file before it starts.
	public func reload() {
		guard let url else { return }
		do {
			project = try ProjectReader.read(try String(contentsOf: url, encoding: .utf8))
			problem = nil
			isDirty = false
		} catch {
			// A file that is being typed into is invalid half the time. The old
			// programme stays on screen and the error is shown beside it, rather
			// than the window emptying itself every time somebody opens a brace.
			problem = error.localizedDescription
			onChange?()
			return
		}
		resolve()
	}

	public func apply(_ newProject: Project) {
		project = newProject
		isDirty = true
		resolve()
	}

	/// Saves the project to a chosen place, and starts watching it there.
	///
	/// Every path a project carries is relative to where the project sits —
	/// that is what lets a folder be copied to another disk and still work — so
	/// writing the same text into another folder would point every take at
	/// nothing. Each path is therefore resolved against where the project *was*
	/// and written again against where it is going. An absolute path is left
	/// alone: somebody who typed one meant it.
	public func saveAs(_ fileURL: URL) throws {
		if let old = url, old.deletingLastPathComponent().standardized.path
			!= fileURL.deletingLastPathComponent().standardized.path {
			repoint(from: old, to: fileURL)
		}
		url = fileURL
		try ProjectWriter.write(project).write(to: fileURL, atomically: true, encoding: .utf8)
		isDirty = false
		resolve()
		watch()
	}

	/// Rewrites every path in the project so it finds the same file from the
	/// project's new home.
	private func repoint(from old: URL, to new: URL) {
		let from = old.deletingLastPathComponent()
		func moved(_ path: String) -> String {
			guard !path.hasPrefix("/"), !path.hasPrefix("~") else { return path }
			return MemeDownload.relativePath(
				from: new, to: URL(fileURLWithPath: path, relativeTo: from))
		}
		func moved(_ entries: [TimelineEntry]) -> [TimelineEntry] {
			entries.map { entry in
				var entry = entry
				for index in entry.sounds.indices { entry.sounds[index].file = moved(entry.sounds[index].file) }
				if case .group(let name, let inside) = entry.source {
					entry.source = .group(name, moved(inside))
				}
				return entry
			}
		}
		project.takes = project.takes.map(moved)
		for index in project.sounds.indices { project.sounds[index].file = moved(project.sounds[index].file) }
		project.timeline = moved(project.timeline)
		isDirty = true
	}

	public func write() throws {
		guard let url else { return }
		// The watcher would see this write and reload what was just written.
		stopWatching()
		defer { watch() }
		try ProjectWriter.write(project).write(to: url, atomically: true, encoding: .utf8)
		isDirty = false
	}

	private func resolve() {
		// An untitled project can still be a programme.
		//
		// Everything a project points at is relative to where the project sits,
		// so until it is saved there is nowhere to point *from* — which is why
		// this used to give up. But a project that points at nothing needs no
		// somewhere: a card with a scene on it is a whole intro screen, made of
		// nothing but the file it is written in. Refusing to resolve one left
		// the window empty with the render button greyed and not a word about
		// why, which is the worst of both.
		//
		// So: resolve anyway when there is nothing to find on disk, and when
		// there is, say what to do about it rather than going quiet.
		guard let base = baseURL ?? (project.takes.isEmpty
			? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true) : nil)
		else {
			resolved = nil
			problem = "Save the project before adding takes — a take is found "
				+ "relative to where the project sits."
			onChange?()
			return
		}
		do {
			resolved = try Resolver.resolve(project, baseURL: base)
			problem = nil
		} catch {
			resolved = nil
			problem = error.localizedDescription
		}
		onChange?()
		// Anything else showing this project — a scene window, say — hears
		// about it here. A notification rather than a second `onChange`,
		// because there can be several listeners and only one of that.
		NotificationCenter.default.post(name: .cuttrProjectChanged, object: self)
	}

	// MARK: - Watching

	/// Reloads when the file changes underneath.
	///
	/// Watching the file rather than polling, and re-arming after every event:
	/// an editor that writes atomically — which is most of them, and which this
	/// program does itself — replaces the file rather than changing it, so the
	/// descriptor being watched is deleted and the watch has to be re-made
	/// against the new one. Watching without this works exactly once.
	private func watch() {
		stopWatching()
		guard let url else { return }
		watchedDescriptor = open(url.path, O_EVTONLY)
		guard watchedDescriptor >= 0 else { return }
		let source = DispatchSource.makeFileSystemObjectSource(
			fileDescriptor: watchedDescriptor, eventMask: [.write, .delete, .rename, .extend],
			queue: .main)
		source.setEventHandler { [weak self] in
			guard let self else { return }
			let events = source.data
			if events.contains(.delete) || events.contains(.rename) {
				// Atomically replaced: re-arm on the new file, after a moment
				// so the replacement has landed.
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
					self.watch()
					self.reload()
				}
			} else {
				self.reload()
			}
		}
		source.setCancelHandler { [descriptor = watchedDescriptor] in
			if descriptor >= 0 { close(descriptor) }
		}
		watcher = source
		source.resume()
	}

	private func stopWatching() {
		watcher?.cancel()
		watcher = nil
		watchedDescriptor = -1
	}

	// MARK: - What there is to refer to

	/// The names a project can actually use, gathered from its takes.
	///
	/// So the editor offers what exists rather than a blank field. Every one of
	/// these is something a project refers to *by name* — a slug, a tag, an
	/// anchor, a section — which means every one of them is somewhere a typo
	/// turns into "no clip called intro" at render time.
	public struct Vocabulary: Sendable {
		public var clips: [String] = []
		public var tags: [String] = []
		public var anchors: [String] = []
		public var groups: [String] = []
		/// The scenes this project defines. Not drawn from the takes like the
		/// rest of the vocabulary — a scene is the project's own — but listed
		/// with them because it is one more name the file refers to by name.
		public var scenes: [String] = []
		/// The placements somebody named with `as:`. A section of one clip as
		/// far as everything downstream is concerned — but kept apart here,
		/// because in a list of things to hang an overlay on it matters whether
		/// a name means a stretch of programme or one shot in it.
		public var labels: [String] = []
		/// Every clip with what it is, take by take. The flat lists above are
		/// what a combo box offers; this is what a library shows.
		public var items: [Item] = []
		/// The takes, in the order the project lists them.
		public var takeNames: [String] = []
		/// Which anchors came from which take, so the library can say where a
		/// tracked face lives.
		public var anchorTakes: [String: String] = [:]
		/// Takes that were downloaded rather than recorded, by name.
		///
		/// Read from each take's own `source:` block — see ``TakeSource`` — and
		/// not from the folder its file sits in. A guess from the path is right
		/// until somebody moves the file somewhere tidier, and then the meme
		/// quietly stops being a meme.
		public var memeTakes: Set<String> = []

		public struct Item: Sendable {
			public var take: String
			public var slug: String
			public var name: String
			public var tags: [String]
			/// Where it begins on the take's clock, so somebody can be taken
			/// there without the take being read a second time.
			public var start: Double = 0
			public var length: Double
			/// What a project would write to mean this clip: bare when the slug
			/// is unique across the takes, `take/slug` when it is not.
			public var reference: String
		}
	}

	public var vocabulary: Vocabulary {
		var found = Vocabulary()
		var clips = Set<String>(), tags = Set<String>(), anchors = Set<String>()
		// Read from the takes rather than from what resolved, so the lists are
		// there to fix a project with, not only to admire a working one.
		for entry in takes {
			guard let text = try? String(contentsOf: entry.url, encoding: .utf8),
			      let take = try? TakeReader.read(text) else { continue }
			for clip in take.clips {
				clips.insert(clip.slug)
				tags.formUnion(clip.tags)
			}
			anchors.formUnion(take.anchors.map(\.name))
		}
		func names(_ entries: [TimelineEntry]) -> [String] {
			entries.flatMap { entry -> [String] in
				guard case .group(let name, let inner) = entry.source else { return [] }
				return [name] + names(inner)
			}
		}
		func labels(_ entries: [TimelineEntry]) -> [String] {
			entries.flatMap { entry -> [String] in
				var found = entry.label.map { [$0] } ?? []
				if case .group(_, let inner) = entry.source { found += labels(inner) }
				return found
			}
		}
		var items: [Vocabulary.Item] = []
		var takeNames: [String] = []
		var anchorTakes: [String: String] = [:]
		var slugCounts: [String: Int] = [:]
		for entry in takes {
			guard let text = try? String(contentsOf: entry.url, encoding: .utf8),
			      let take = try? TakeReader.read(text) else { continue }
			takeNames.append(entry.name)
			for clip in take.clips { slugCounts[clip.slug, default: 0] += 1 }
			for anchor in take.anchors { anchorTakes[anchor.name] = entry.name }
			if take.source?.isMeme == true { found.memeTakes.insert(entry.name) }
		}
		for entry in takes {
			guard let text = try? String(contentsOf: entry.url, encoding: .utf8),
			      let take = try? TakeReader.read(text) else { continue }
			for clip in take.clips {
				items.append(Vocabulary.Item(
					take: entry.name, slug: clip.slug, name: clip.name, tags: clip.tags,
					start: clip.start, length: clip.end - clip.start,
					reference: (slugCounts[clip.slug] ?? 0) > 1
						? "\(entry.name)/\(clip.slug)" : clip.slug))
			}
		}
		found.items = items
		found.takeNames = takeNames
		found.anchorTakes = anchorTakes
		found.clips = clips.sorted()
		found.tags = tags.sorted()
		found.anchors = anchors.sorted()
		found.scenes = project.scenes.keys.sorted()
		found.groups = Array(Set(names(project.timeline))).sorted()
		found.labels = Array(Set(labels(project.timeline))).sorted()
		return found
	}

	// MARK: - Takes

	/// The take files this project draws on, resolved and reported on.
	///
	/// Reported rather than assumed: a project is a list of paths, and a path
	/// that has moved is the commonest thing to go wrong with one. The window
	/// shows what each entry actually is, so "no clip called intro" is not the
	/// first anybody hears of it.
	public struct TakeEntry: Sendable {
		public let path: String
		public let url: URL
		public let name: String
		public let clips: Int
		public let problem: String?
	}

	public var takes: [TakeEntry] {
		guard let baseURL else { return [] }
		return project.takes.map { path in
			let url = URL(fileURLWithPath: path, relativeTo: baseURL).standardizedFileURL
			let name = url.deletingPathExtension().lastPathComponent
			do {
				let take = try TakeReader.read(try String(contentsOf: url, encoding: .utf8))
				return TakeEntry(path: path, url: url, name: name, clips: take.clips.count, problem: nil)
			} catch {
				return TakeEntry(path: path, url: url, name: name, clips: 0,
				                 problem: error.localizedDescription)
			}
		}
	}

	/// Adds a take, as a path relative to the project.
	///
	/// Relative is the point: a project, its takes and its media are one folder
	/// that gets copied to another disk, and a list full of `/Users/somebody/…`
	/// survives none of that.
	@discardableResult
	public func addTake(_ url: URL) -> Bool {
		guard let baseURL else { return false }
		let path = relativePath(url, from: baseURL)
		guard !project.takes.contains(path) else { return false }
		var next = project
		next.takes.append(path)
		apply(next)
		try? write()
		return true
	}

	/// Renames a take's file, and updates the project to match.
	///
	/// The file, not a label: a take's name *is* its file name, which is what a
	/// project's `takes:` list holds and what shows in the list. Sidecar paths
	/// inside the take are relative to the take and do not mention its name, so
	/// they keep resolving.
	///
	/// Returns what went wrong, or `nil` when it worked.
	public func renameTake(_ path: String, to requested: String) -> String? {
		guard let baseURL else { return "Save the project first." }
		let name = requested.trimmingCharacters(in: .whitespacesAndNewlines)
			// A file name, so the characters a path cannot hold come out.
			.replacingOccurrences(of: "/", with: "-")
			.replacingOccurrences(of: ":", with: "-")
		guard !name.isEmpty else { return nil }

		let from = URL(fileURLWithPath: path, relativeTo: baseURL).standardizedFileURL
		guard from.deletingPathExtension().lastPathComponent != name else { return nil }
		let to = from.deletingLastPathComponent()
			.appendingPathComponent(name).appendingPathExtension("cuttr")
		guard !FileManager.default.fileExists(atPath: to.path) else {
			return "There is already a take called \(name) in that folder."
		}
		do { try FileManager.default.moveItem(at: from, to: to) } catch {
			return error.localizedDescription
		}

		var next = project
		let replacement = relativePath(to, from: baseURL)
		next.takes = next.takes.map { $0 == path ? replacement : $0 }
		apply(next)
		try? write()
		return nil
	}

	public func removeTake(_ path: String) {
		var next = project
		next.takes.removeAll { $0 == path }
		apply(next)
		try? write()
	}

	private func relativePath(_ url: URL, from base: URL) -> String {
		let baseParts = base.standardizedFileURL.pathComponents
		let target = url.standardizedFileURL.pathComponents
		var shared = 0
		while shared < baseParts.count, shared < target.count, baseParts[shared] == target[shared] { shared += 1 }
		let ups = baseParts.count - shared
		// More than a couple of `..` is not a folder anybody will copy around,
		// and an absolute path at least says where the file is.
		guard ups <= 2 else { return url.path }
		return (Array(repeating: "..", count: ups) + target[shared...]).joined(separator: "/")
	}

	/// Where a new take should be written: a `takes/` folder beside the project.
	public func placeForNewTake(named name: String) -> URL? {
		guard let baseURL else { return nil }
		let folder = baseURL.appendingPathComponent("takes", isDirectory: true)
		try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		return folder.appendingPathComponent(name).appendingPathExtension("cuttr")
	}

	// Anchors are marked in the cutting window now, on the take. This window
	// only shows them: a project draws its overlays against a face that was
	// tracked once, wherever else that clip is also used.
}
