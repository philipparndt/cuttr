import AppKit
import CuttrKit

/// The take being edited, its media, and everything derived from both.
///
/// One object owns the whole editing state, and every change to it goes through
/// ``apply(_:actionName:)``. That is what makes undo a single line rather than a
/// per-operation chore: a take is a value, so the undo stack is a stack of
/// values, and there is no way to add an operation that forgets to register one.
///
/// The cost is that every edit copies the clip array. A take with a thousand
/// clips is 100 kB a copy, on a keystroke — which is nothing, and is worth
/// saying out loud because "snapshot undo does not scale" is the received
/// wisdom and it is about documents four orders of magnitude bigger than this.
public extension Notification.Name {
	/// A take was written. The `object` is its URL.
	///
	/// How a project window notices that one of its takes was re-cut in another
	/// tab. It could watch the files — the project already watches its own —
	/// but a notification is exact and instant where a file watcher is neither:
	/// no debounce, no atomic-replace dance, and no chance of reacting to a
	/// half-written file, because it is posted after the write returns.
	static let cuttrTakeChanged = Notification.Name("de.rnd7.cuttr.takeChanged")
}

@MainActor
public final class TakeDocument {

	public private(set) var take: Take
	public private(set) var url: URL?

	/// Set when the take differs from what is on disk.
	///
	/// Compared against the last thing written rather than set by every edit, so
	/// that undoing back to the saved state clears the dot in the close button
	/// instead of leaving a document that claims to be modified into exactly
	/// what is on disk.
	public var isDirty: Bool { take != savedTake }
	private var savedTake: Take?

	/// Media, once probed. `nil` while loading, and after a file that has gone
	/// missing — a take whose video has moved still opens, still shows its
	/// clips, and says what it cannot find.
	public private(set) var videoInfo: MediaInfo?
	public private(set) var audioInfo: MediaInfo?
	public private(set) var videoWaveform: Waveform?
	public private(set) var audioWaveform: Waveform?
	public private(set) var mediaError: String?
	public private(set) var isLoadingMedia = false

	/// Clips whose slug the operator typed themselves.
	///
	/// Not in the file, and it should not be: it is the answer to "may I
	/// re-derive this slug when the name changes", which is a question about
	/// this editing session. Once somebody has written a slug by hand, renaming
	/// the clip must not silently change what the assembly file references.
	private var manualSlugs = Set<Clip.ID>()

	public let undoManager = UndoManager()

	/// Called after any change to ``take``.
	public var onChange: (() -> Void)?
	/// Called when media finishes loading, or fails to.
	public var onMediaChange: (() -> Void)?

	private var mediaTask: Task<Void, Never>?

	public init(take: Take = Take(), url: URL? = nil) {
		self.take = take
		self.url = url
		// A document starts as what it was given. Left nil, a brand-new empty
		// take compared unequal to nothing and reported itself as edited: the
		// title said "Untitled — edited" before anybody had touched it, and
		// closing an untouched window asked whether to save it.
		self.savedTake = take
	}

	// MARK: - Editing

	/// The one way the take changes.
	public func apply(_ newTake: Take, actionName: String) {
		guard newTake != take else { return }
		let previous = take
		undoManager.registerUndo(withTarget: self) { document in
			MainActor.assumeIsolated { document.apply(previous, actionName: actionName) }
		}
		undoManager.setActionName(actionName)
		let mediaChanged = newTake.video != take.video
			|| newTake.audio?.file != take.audio?.file
		take = newTake
		onChange?()
		if mediaChanged { loadMedia() }
	}

	/// The take, changed, with no undo step of its own.
	///
	/// For the middle of a drag. A slider moved across its range is one
	/// decision and sixty changes: the first registers an undo and the rest go
	/// through here, so what Undo puts back is where the slider started rather
	/// than where it was a frame ago. The timeline does the same thing for a
	/// clip being dragged, with its own `commit` flag.
	public func replaceWithoutUndo(_ newTake: Take) {
		guard newTake != take else { return }
		take = newTake
		onChange?()
	}

	/// Renames a clip, and re-derives its slug unless somebody has claimed it.
	public func setName(_ name: String, for id: Clip.ID, actionName: String = "Rename Clip") {
		guard let index = take.clips.firstIndex(where: { $0.id == id }) else { return }
		var next = take
		next.clips[index].name = name
		if !manualSlugs.contains(id) {
			var taken = next.slugs
			taken.remove(next.clips[index].slug)
			next.clips[index].slug = Slug.unique(Slug.make(from: name), taken: taken)
		}
		apply(next, actionName: actionName)
	}

	/// Sets a slug by hand, and stops deriving it from the name from now on.
	public func setSlug(_ slug: String, for id: Clip.ID) {
		var next = take
		guard next.setSlug(slug, for: id) != nil else { return }
		manualSlugs.insert(id)
		apply(next, actionName: "Change Slug")
	}

	public func setNote(_ note: String, for id: Clip.ID) {
		guard let index = take.clips.firstIndex(where: { $0.id == id }) else { return }
		var next = take
		next.clips[index].note = note.isEmpty ? nil : note
		apply(next, actionName: "Edit Note")
	}

	// MARK: - Anchors

	/// The solved paths, keyed by anchor name, on the take's own clock.
	public private(set) var anchorPaths: [String: AnchorPath] = [:]

	/// Marks a point in the picture at a time.
	///
	/// Nothing to do with the clips. The range comes back from the solver — it
	/// is however far the face could be followed — so an anchor can be marked
	/// before a single cut has been made, and every subclip that later overlaps
	/// the shot gets to use it.
	public func addAnchor(name: String, at time: Double, point: CGPoint) -> Anchor {
		var next = take
		let slug = Slug.unique(Slug.make(from: name), taken: Set(take.anchors.map(\.name)))
		let anchor = next.add(Anchor(
			name: slug, from: time, to: time, markedAt: time, point: point,
			method: .faceLandmark, path: "anchors/\(slug).path"))
		apply(next, actionName: "Track a Point")
		return anchor
	}

	/// Records what the solver actually managed to follow.
	public func setRange(_ range: ClosedRange<Double>, for name: String) {
		guard let index = take.anchors.firstIndex(where: { $0.name == name }) else { return }
		var next = take
		next.anchors[index].from = range.lowerBound
		next.anchors[index].to = range.upperBound
		apply(next, actionName: "Track a Point")
	}

	/// Renames an anchor, and takes its sidecar with it.
	///
	/// The name is what a project references, so this is a rename that reaches
	/// outside the file: any project saying `anchor: old-name` stops resolving.
	/// Returns the name actually used so the caller can say so — and say what it
	/// means — rather than the rename happening quietly.
	@discardableResult
	public func renameAnchor(_ old: String, to requested: String) -> String? {
		guard let index = take.anchors.firstIndex(where: { $0.name == old }) else { return nil }
		var taken = Set(take.anchors.map(\.name))
		taken.remove(old)
		let cleaned = Slug.make(from: requested)
		guard !cleaned.isEmpty else { return nil }
		let name = Slug.unique(cleaned, taken: taken)
		guard name != old else { return old }

		var next = take
		next.anchors[index].name = name
		// The sidecar is named after the anchor, so it moves too — otherwise the
		// files accumulate under old names and nobody can tell which is live.
		if let baseURL, let oldPath = take.anchors[index].path {
			let newPath = "anchors/\(name).path"
			next.anchors[index].path = newPath
			try? FileManager.default.moveItem(
				at: URL(fileURLWithPath: oldPath, relativeTo: baseURL),
				to: URL(fileURLWithPath: newPath, relativeTo: baseURL))
		}
		anchorPaths[name] = anchorPaths[old]
		anchorPaths[old] = nil
		apply(next, actionName: "Rename Anchor")
		return name
	}

	public func removeAnchor(named name: String) {
		var next = take
		next.anchors.removeAll { $0.name == name }
		apply(next, actionName: "Remove Anchor")
		anchorPaths[name] = nil
	}

	/// Lays a freshly solved stretch into an anchor that already has one.
	///
	/// Widens the anchor's range to cover both, so a project asking for the
	/// anchor gets everything that was followed.
	public func extendPath(_ addition: AnchorPath, for name: String) throws {
		guard let index = take.anchors.firstIndex(where: { $0.name == name }) else { return }
		let merged = (anchorPaths[name] ?? AnchorPath()).merging(addition)
		var next = take
		if let range = merged.timeRange {
			next.anchors[index].from = range.lowerBound
			next.anchors[index].to = range.upperBound
		}
		apply(next, actionName: "Continue Tracking")
		try writePath(merged, for: next.anchors[index])
	}

	/// Writes a solved path beside the take, and keeps it for drawing.
	public func writePath(_ path: AnchorPath, for anchor: Anchor) throws {
		anchorPaths[anchor.name] = path
		guard let baseURL, let relative = anchor.path else { onChange?(); return }
		let url = URL(fileURLWithPath: relative, relativeTo: baseURL)
		try FileManager.default.createDirectory(
			at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
		try path.write(name: anchor.name,
		               over: "\(Timecode.string(anchor.from))–\(Timecode.string(anchor.to))",
		               framesPerSecond: grid.framesPerSecond)
			.write(to: url, atomically: true, encoding: .utf8)
		onChange?()
		// Tracking is something a project draws with, so a solved path is a
		// change a project window wants to hear about too.
		if let url = self.url {
			NotificationCenter.default.post(name: .cuttrTakeChanged, object: url.standardizedFileURL)
		}
	}

	/// Reads whatever sidecars the take names. Called after opening one.
	public func loadAnchorPaths() {
		anchorPaths = [:]
		guard let baseURL else { return }
		for anchor in take.anchors {
			guard let relative = anchor.path,
			      let text = try? String(
				      contentsOf: URL(fileURLWithPath: relative, relativeTo: baseURL), encoding: .utf8)
			else { continue }
			anchorPaths[anchor.name] = AnchorPath.read(text)
		}
	}

	// MARK: - Words

	/// What was said, once it has been worked out or read back.
	///
	/// Empty until one or the other happens, and it is asked for *once*: the
	/// sidecar is read when the take is opened and the recogniser is run only
	/// when somebody asks for it. Transcribing on every open would be a minute
	/// of somebody's machine, every time, for an answer that has not changed.
	public private(set) var transcript = Transcript()

	/// Records a transcript and writes it beside the take.
	///
	/// The take gains a `words:` key, so this is an edit and it is undoable.
	/// The sidecar is written straight away rather than at save: it is a
	/// measurement and not a decision, and the alternative is a take file
	/// pointing at a file that is not there yet.
	public func setTranscript(
		_ transcript: Transcript, recogniser: Words.Recogniser, locale: String
	) throws {
		self.transcript = transcript
		var next = take
		next.words = Words(
			path: take.words?.path ?? "words/\(Slug.make(from: displayName)).words",
			recogniser: recogniser, locale: locale)
		apply(next, actionName: "Transcribe")
		try writeWords()
	}

	private func writeWords() throws {
		guard let baseURL, let words = take.words else { onChange?(); return }
		let url = URL(fileURLWithPath: words.path, relativeTo: baseURL)
		try FileManager.default.createDirectory(
			at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
		try transcript
			.write(name: displayName, recogniser: words.recogniser.rawValue, locale: words.locale)
			.write(to: url, atomically: true, encoding: .utf8)
		onChange?()
	}

	/// Reads the sidecar the take names. Called after opening one.
	public func loadWords() {
		transcript = Transcript()
		guard let baseURL, let words = take.words,
		      let text = try? String(
			      contentsOf: URL(fileURLWithPath: words.path, relativeTo: baseURL), encoding: .utf8)
		else { return }
		transcript = Transcript.read(text)
	}

	/// Trimming from the table or the context menu.
	///
	/// Snapped to the frame grid, the same as a drag on the timeline is. A time
	/// typed into the table is a request rather than a fact — the renderer hands
	/// whole frames to an encoder either way, and rounding here is the one place
	/// somebody can see it happen.
	public func setTimes(start: Double, end: Double, for id: Clip.ID, actionName: String = "Trim Clip") {
		var next = take
		guard next.setTimes(start: grid.snap(start), end: grid.snap(end), for: id) else { return }
		apply(next, actionName: actionName)
	}

	public func setTags(_ tags: [String], for id: Clip.ID) {
		var next = take
		next.setTags(tags, for: id)
		apply(next, actionName: "Edit Tags")
	}

	public func setOrder(_ order: Int, for id: Clip.ID) {
		var next = take
		next.setOrder(order, for: id)
		apply(next, actionName: "Change Order")
	}

	public func setOffset(_ offset: Double) {
		guard var audio = take.audio else { return }
		audio.offset = offset
		var next = take
		next.audio = audio
		apply(next, actionName: "Adjust Alignment")
	}

	// MARK: - Media

	/// The directory relative paths in the take are resolved against.
	///
	/// The take file's own directory, or — before it has been saved — the
	/// directory the media came from. An untitled take holds absolute paths and
	/// they are made relative at save time, which is the only moment the answer
	/// is known.
	public var baseURL: URL? {
		url?.deletingLastPathComponent() ?? untitledBase
	}
	private var untitledBase: URL?

	public var videoURL: URL? { resolve(take.video) }
	public var audioURL: URL? { resolve(take.audio?.file) }

	public func resolve(_ path: String?) -> URL? {
		guard let path, !path.isEmpty else { return nil }
		if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
		guard let baseURL else { return nil }
		return URL(fileURLWithPath: path, relativeTo: baseURL).standardizedFileURL
	}

	/// The take's own clock: the video's duration, or the audio's when there is
	/// no video. Nothing can be cut past it.
	public var duration: Double {
		if let videoInfo { return videoInfo.duration }
		if let audioInfo, take.video == nil { return audioInfo.duration }
		return 0
	}

	/// The frames a cut mark may land on.
	public var grid: FrameGrid { videoInfo?.grid ?? .none }

	/// Probes both files and decodes their waveforms.
	///
	/// Cancels whatever was in flight first. Dropping a second video on the
	/// window while the first is still decoding is ordinary, and the old decode
	/// is minutes of CPU spent on a file nobody is looking at any more.
	public func loadMedia() {
		mediaTask?.cancel()
		videoInfo = nil; audioInfo = nil
		videoWaveform = nil; audioWaveform = nil
		mediaError = nil
		isLoadingMedia = videoURL != nil || audioURL != nil
		onMediaChange?()
		guard isLoadingMedia else { return }

		let video = videoURL
		let audio = audioURL
		mediaTask = Task { [weak self] in
			var failures: [String] = []

			if let video {
				do {
					let info = try await MediaProbe.probe(video)
					guard !Task.isCancelled else { return }
					self?.videoInfo = info
					self?.onMediaChange?()
					if info.hasAudio {
						// Decoded even when a separate recorder is in use: it
						// is the reference the aligner correlates against, and
						// it is the lane somebody looks at to check the answer.
						let wave = try await WaveformExtractor.extract(url: video)
						guard !Task.isCancelled else { return }
						self?.videoWaveform = wave
						self?.onMediaChange?()
					}
				} catch is CancellationError {
					return
				} catch {
					failures.append("\(video.lastPathComponent): \(error.localizedDescription)")
				}
			}

			if let audio {
				do {
					let info = try await MediaProbe.probe(audio)
					guard !Task.isCancelled else { return }
					self?.audioInfo = info
					self?.onMediaChange?()
					let wave = try await WaveformExtractor.extract(url: audio)
					guard !Task.isCancelled else { return }
					self?.audioWaveform = wave
					self?.onMediaChange?()
				} catch is CancellationError {
					return
				} catch {
					failures.append("\(audio.lastPathComponent): \(error.localizedDescription)")
				}
			}

			guard !Task.isCancelled else { return }
			self?.isLoadingMedia = false
			self?.mediaError = failures.isEmpty ? nil : failures.joined(separator: "\n")
			self?.onMediaChange?()
		}
	}

	/// Points the take at a media file, choosing the slot by what is in it.
	public func setMedia(video: URL?, audio: URL?) {
		if untitledBase == nil, url == nil {
			untitledBase = (video ?? audio)?.deletingLastPathComponent()
		}
		var next = take
		if let video { next.video = pathString(for: video) }
		if let audio {
			// A new audio file keeps whatever offset was already found. Swapping
			// in a re-export of the same recording is the common case, and
			// throwing away an alignment somebody spent a minute on would be the
			// wrong default; it is one keystroke to re-align.
			next.audio = AudioTrack(file: pathString(for: audio), offset: take.audio?.offset ?? 0)
		}
		apply(next, actionName: video != nil ? "Set Video" : "Set Audio")
	}

	/// Relative to the take file where that is possible, absolute otherwise.
	///
	/// Relative is the point: a take, its video and its audio are one folder
	/// that gets copied to another disk, and a cut list full of
	/// `/Users/somebody/...` survives none of that.
	private func pathString(for fileURL: URL) -> String {
		guard let baseURL else { return fileURL.path }
		let base = baseURL.standardizedFileURL.pathComponents
		let target = fileURL.standardizedFileURL.pathComponents
		var shared = 0
		while shared < base.count, shared < target.count, base[shared] == target[shared] { shared += 1 }
		// Anything more than a couple of `..` is not a folder somebody will
		// copy around, and an absolute path at least says where the file is.
		let ups = base.count - shared
		guard ups <= 2 else { return fileURL.path }
		return (Array(repeating: "..", count: ups) + target[shared...]).joined(separator: "/")
	}

	// MARK: - File

	public func read(from fileURL: URL) throws {
		let text = try String(contentsOf: fileURL, encoding: .utf8)
		take = try TakeReader.read(text)
		savedTake = take
		url = fileURL
		untitledBase = nil
		manualSlugs = Set(take.clips.map(\.id))   // every slug in a file is somebody's
		undoManager.removeAllActions()
		loadAnchorPaths()
		loadWords()
		onChange?()
		loadMedia()
	}

	public func write(to fileURL: URL) throws {
		// Re-relativise before writing: an untitled take holds absolute paths,
		// and this is the moment the folder they should be relative to is known.
		var next = take
		let previousBase = baseURL
		untitledBase = nil
		url = fileURL
		if let video = take.video, video.hasPrefix("/") || previousBase != baseURL {
			next.video = pathString(for: resolveAgainst(video, base: previousBase))
		}
		if let audio = take.audio, audio.file.hasPrefix("/") || previousBase != baseURL {
			next.audio?.file = pathString(for: resolveAgainst(audio.file, base: previousBase))
		}
		take = next
		try TakeWriter.write(take).write(to: fileURL, atomically: true, encoding: .utf8)
		// A take transcribed before it was ever saved has its words in memory
		// and nowhere else. This is the first moment there is a folder to put
		// them beside, so they go now rather than at the next transcription.
		if !transcript.isEmpty { try? writeWords() }
		savedTake = take
		onChange?()
		NotificationCenter.default.post(name: .cuttrTakeChanged, object: fileURL.standardizedFileURL)
	}

	private func resolveAgainst(_ path: String, base: URL?) -> URL {
		if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
		guard let base else { return URL(fileURLWithPath: path) }
		return URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL
	}

	/// Where ⌘S should put an untitled take: beside its video, named after it.
	public var suggestedURL: URL? {
		guard let media = videoURL ?? audioURL else { return nil }
		return media.deletingPathExtension().appendingPathExtension("cuttr")
	}

	public var displayName: String {
		url?.deletingPathExtension().lastPathComponent
			?? videoURL?.deletingPathExtension().lastPathComponent
			?? "Untitled"
	}
}
