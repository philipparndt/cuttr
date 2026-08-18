import AppKit
import CuttrCompose
import CuttrKit

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

	public init(project: Project = Project(), url: URL? = nil) {
		self.project = project
		self.url = url
	}

	deinit {
		watcher?.cancel()
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

	public func write() throws {
		guard let url else { return }
		// The watcher would see this write and reload what was just written.
		stopWatching()
		defer { watch() }
		try ProjectWriter.write(project).write(to: url, atomically: true, encoding: .utf8)
		isDirty = false
	}

	private func resolve() {
		guard let baseURL else { resolved = nil; onChange?(); return }
		do {
			resolved = try Resolver.resolve(project, baseURL: baseURL)
			problem = nil
		} catch {
			resolved = nil
			problem = error.localizedDescription
		}
		onChange?()
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

	// Anchors are marked in the cutting window now, on the take. This window
	// only shows them: a project draws its overlays against a face that was
	// tracked once, wherever else that clip is also used.
}
