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
	///
	/// The transcript counts, because naming who is speaking changes the
	/// sidecar and nothing else. Without it, a session spent labelling an
	/// interview would close without so much as asking.
	public var isDirty: Bool { take != savedTake || transcript != savedTranscript }
	private var savedTake: Take?
	private var savedTranscript = Transcript()

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

	// MARK: - Who is speaking

	/// A model's proposal, keyed by the first word of each line it is about.
	///
	/// **Not in the file, and not in the transcript.** A suggestion is a fact
	/// about this session — the same distinction ``manualSlugs`` draws — and
	/// the file records what somebody confirmed. Drawn as visibly a
	/// suggestion, and it becomes a fact only when ``acceptSuggestions()`` or a
	/// keystroke says so.
	public private(set) var suggestedSpeakers: [Int: String] = [:]

	/// What an automatic pass thinks, offered rather than applied.
	public func suggest(_ proposal: [Int: String]) {
		suggestedSpeakers = proposal
		onChange?()
	}

	public func clearSuggestions() {
		guard !suggestedSpeakers.isEmpty else { return }
		suggestedSpeakers = [:]
		onChange?()
	}

	/// Writes down what was proposed. The one place a guess becomes a record.
	public func acceptSuggestions() {
		guard !suggestedSpeakers.isEmpty else { return }
		var next = transcript
		for line in next.lines {
			guard let slug = suggestedSpeakers[line.lowerBound] else { continue }
			for index in line { next.words[index].speaker = slug }
		}
		// Anybody the proposal invented joins the cast, or the names would have
		// nowhere to live.
		var take = take
		for slug in next.speakers where take.speaker(slug) == nil {
			take.speakers.append(Speaker(slug: slug))
		}
		if take != self.take { apply(take, actionName: "Name the Speakers") }
		suggestedSpeakers = [:]
		applyTranscript(next, actionName: "Name the Speakers")
	}

	/// Says who is speaking on the lines these words touch. See
	/// ``CuttrKit/Transcript/assign(_:to:)``.
	@discardableResult
	public func assignSpeaker(_ slug: String?, to words: Range<Int>) -> Int {
		var next = transcript
		let changed = next.assign(slug, to: words)
		guard changed > 0 else { return 0 }
		// Answering a line by hand retires the guess it covers, so the pane
		// does not go on offering an answer to a question already settled.
		let wanted = words.isEmpty ? words.lowerBound ..< words.lowerBound + 1 : words
		for line in next.lines where line.overlaps(wanted) {
			suggestedSpeakers[line.lowerBound] = nil
		}
		applyTranscript(next, actionName: "Name the Speaker")
		return changed
	}

	/// Adds somebody to the cast under a slug nothing else has.
	@discardableResult
	public func addSpeaker(named name: String) -> Speaker? {
		let trimmed = name.trimmingCharacters(in: .whitespaces)
		guard !trimmed.isEmpty else { return nil }
		var next = take
		let added = next.add(Speaker(slug: Slug.make(from: trimmed), name: trimmed))
		apply(next, actionName: "Add a Speaker")
		return added
	}

	/// Renames somebody.
	///
	/// The prose only. The slug is what the sidecar's four hundred lines point
	/// at, and leaving it alone is exactly what makes renaming one line's work
	/// — the same rule the clips follow, for the same reason.
	public func renameSpeaker(_ slug: String, to name: String) {
		guard let index = take.speakers.firstIndex(where: { $0.slug == slug }) else { return }
		var next = take
		next.speakers[index].name = name.trimmingCharacters(in: .whitespaces)
		apply(next, actionName: "Rename Speaker")
	}

	/// Takes somebody out of the cast, and off every word that named them.
	public func removeSpeaker(_ slug: String) {
		var next = take
		next.speakers.removeAll { $0.slug == slug }
		apply(next, actionName: "Remove Speaker")
		var said = transcript
		if said.rename(slug, to: nil) > 0 {
			applyTranscript(said, actionName: "Remove Speaker")
		}
	}

	/// The one way the transcript changes once it exists.
	///
	/// Undoable like everything else, because a transcript is a value too — and
	/// a carry-forward that painted forty lines the wrong colour has to be one
	/// press of ⌘Z, or nobody will risk the keystroke that makes this fast.
	///
	/// The sidecar is not written here. It goes at save, with the take, because
	/// a key held down for a second is thirty edits and none of them is a
	/// decision to write a file.
	public func applyTranscript(_ next: Transcript, actionName: String) {
		guard next != transcript else { return }
		let previous = transcript
		undoManager.registerUndo(withTarget: self) { document in
			MainActor.assumeIsolated { document.applyTranscript(previous, actionName: actionName) }
		}
		undoManager.setActionName(actionName)
		transcript = next
		onChange?()
	}

	// MARK: - Where the lines end

	/// Ends the line before this word, or takes back the break that is there.
	///
	/// One method rather than two, because the pane has one key for it and the
	/// answer to "which of the two did you mean" is in the transcript both of
	/// them are looking at. `false` when neither can be done — see
	/// ``CuttrKit/Transcript/addBreak(before:)``.
	@discardableResult
	public func breakLine(before index: Int) -> Bool {
		var next = transcript
		let broken = next.hasBreak(before: index)
		guard broken ? next.removeBreak(before: index) : next.addBreak(before: index)
		else { return false }
		// A guess about the line being split is a guess about both halves of
		// it: it was made from the whole line's voice, and the second half is
		// part of that line. Left alone, the offer would keep the name on the
		// top half and quietly stop offering anything for the bottom one, so
		// the page would lose an offer to a keystroke that was not about
		// speakers at all.
		if !broken, let line = transcript.line(of: index),
		   let offered = suggestedSpeakers[transcript.lines[line].lowerBound] {
			suggestedSpeakers[index] = offered
		}
		applyTranscript(next, actionName: broken ? "Join the Line" : "End the Line")
		return true
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
	public private(set) var transcript = Transcript() {
		didSet { if transcript.isEmpty != oldValue.isEmpty { suggestedSpeakers = [:] } }
	}

	/// Records a transcript and writes it beside the take.
	///
	/// The take gains a `words:` key, so this is an edit and it is undoable.
	/// The sidecar is written straight away rather than at save: it is a
	/// measurement and not a decision, and the alternative is a take file
	/// pointing at a file that is not there yet.
	public func setTranscript(
		_ transcript: Transcript, recogniser: Words.Recogniser, locale: String
	) throws {
		// The words are the recogniser's; where the lines end is not. Asking
		// for a transcript again replaces every word, and the breaks somebody
		// put in are carried across and resolved against the new ones — which
		// is the whole reason they are times and not word indices. A break the
		// new pass leaves nothing to break is dropped by
		// ``CuttrKit/Transcript/init(words:breaks:)``.
		let carried = Transcript(words: transcript.words, breaks: self.transcript.breaks)
		self.transcript = carried
		self.savedTranscript = carried
		var next = take
		next.words = Words(
			path: take.words?.path ?? "words/\(Slug.make(from: displayName)).words",
			recogniser: recogniser, locale: locale)
		apply(next, actionName: "Transcribe")
		try writeWords()
	}

	/// The sounds that are not words. Straight into the take, because that is
	/// where they live — there is no sidecar to keep in step.
	public func setSounds(_ sounds: [SoundEvent]) {
		var next = take
		next.sounds = sounds
		apply(next, actionName: "Find Sounds")
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
		savedTranscript = transcript
		guard let baseURL, let words = take.words,
		      let text = try? String(
			      contentsOf: URL(fileURLWithPath: words.path, relativeTo: baseURL), encoding: .utf8)
		else { return }
		transcript = Transcript.read(text)
		savedTranscript = transcript
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

	/// How much to turn this whole recording up or down. See
	/// ``CuttrKit/Take/gain``.
	public func setTakeGain(_ gain: Double) {
		guard take.gain != gain else { return }
		var next = take
		next.gain = gain
		apply(next, actionName: "Change Level")
	}

	/// How much to turn one clip up or down. See ``CuttrKit/Clip/gain``.
	public func setGain(_ gain: Double, for id: Clip.ID) {
		var next = take
		guard let index = next.clips.firstIndex(where: { $0.id == id }),
		      next.clips[index].gain != gain else { return }
		next.clips[index].gain = gain
		apply(next, actionName: "Change Level")
	}

	/// Every clip's trim at once, from what each one measured.
	///
	/// One edit and one undo, because levelling a take is one act: correcting
	/// twelve clips and having to press ⌘Z twelve times is not a feature
	/// anybody uses twice.
	public func setGains(_ gains: [Clip.ID: Double]) {
		var next = take
		var changed = false
		for index in next.clips.indices {
			guard let gain = gains[next.clips[index].id], next.clips[index].gain != gain
			else { continue }
			next.clips[index].gain = gain
			changed = true
		}
		guard changed else { return }
		apply(next, actionName: "Match Levels")
	}

	/// The whole curve at once: a proposal somebody has accepted, or a curve
	/// cleared away. One edit and one undo, because drawing a curve over a take
	/// is one act — see ``setGains(_:)``, which is the same argument for the
	/// same reason.
	public func setLevels(_ levels: [LevelPoint], actionName: String = "Change Level") {
		guard levels != take.levels else { return }
		var next = take
		next.levels = GainCurve.tidied(levels)
		apply(next, actionName: actionName)
	}

	/// A point put on the curve, or the one already at that moment moved to a
	/// new level. Returns where it landed, since the click that makes a point is
	/// the start of the drag that places it.
	@discardableResult
	public func addLevel(at time: Double, gain: Double, within tolerance: Double = 0) -> Int {
		var next = take
		let index = next.setLevel(gain, at: time, within: tolerance)
		apply(next, actionName: "Add a Level Point")
		return index
	}

	public func removeLevel(at index: Int) {
		guard take.levels.indices.contains(index) else { return }
		var next = take
		next.removeLevel(at: index)
		apply(next, actionName: "Remove a Level Point")
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

	// MARK: - Where the talking is

	/// Worked out from the envelope, and kept until the envelope changes.
	///
	/// The separate recorder when there is one: it is the microphone nearest
	/// whoever is talking, and it is the track the words were heard from. Its
	/// edges are shifted onto the video's clock by the take's own offset, so
	/// everything that comes out of here is on the one clock like everything
	/// else in a take.
	///
	/// It lives on the document rather than on the timeline because it is now
	/// answering two questions — what ⌥ snaps to, and where a clip made out of
	/// a sentence goes. Two caches of one measurement is two chances for the
	/// mark you can see and the mark you get to disagree.
	public var speechMap: SpeechMap? {
		let wave = audioWaveform ?? videoWaveform
		guard let wave else { return nil }
		let shift = audioWaveform != nil ? (take.audio?.offset ?? 0) : 0
		let signature = SpeechSignature(buckets: wave.bucketCount, duration: wave.duration, shift: shift)
		if let cached = speechCache, cached.signature == signature { return cached.map }
		let made = SpeechMap.of(wave, shift: shift)
		speechCache = (signature, made)
		return made
	}

	private var speechCache: (signature: SpeechSignature, map: SpeechMap)?

	private struct SpeechSignature: Equatable {
		let buckets: Int
		let duration: Double
		let shift: Double
	}

	/// What a span read off the words should actually be cut as: the marks put
	/// on the sound, and air taken from the silence around them.
	///
	/// The whole ``SpeechMap/Cut`` rather than two numbers, so a caller can say
	/// what it did. With no envelope decoded yet the span comes back untouched,
	/// which is what this program did before and is better than making somebody
	/// wait for a decode to press Return.
	public func cut(from start: Double, to end: Double,
	                handle: Double = SpeechMap.handle) -> SpeechMap.Cut {
		let asked = min(start, end) ... max(start, end)
		guard let speechMap else { return .unchanged(asked) }
		let room = transcript.neighbours(of: asked)
		return speechMap.cut(from: asked.lowerBound, to: asked.upperBound,
		                     after: room.before, before: room.after, handle: handle)
	}

	/// For the tests: what a probe and a decode would have found, without a file
	/// to read.
	///
	/// The lanes of the timeline exist only where something has finished
	/// decoding, and nothing is drawn on one until the take has a length, so
	/// anything about drawing on a lane or pointing at one needs both. A test
	/// that had to write a WAV and wait for `AVAssetReader` to read it back
	/// would be a test about `AVAssetReader`.
	func setMediaForTesting(video: MediaInfo? = nil, audio: MediaInfo? = nil,
	                        videoWave: Waveform? = nil, audioWave: Waveform? = nil) {
		videoInfo = video
		audioInfo = audio
		videoWaveform = videoWave
		audioWaveform = audioWave
	}

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
		return MediaPath.relative(fileURL, toFolder: baseURL)
	}

	// MARK: - File

	/// The same take, under a new name.
	///
	/// Renaming a take from the project window renames its file, and a window
	/// with that take open has to follow — otherwise its next save writes the
	/// old name back and quietly undoes the rename, which is why renaming an
	/// open take used to be refused outright. Being told is the same amount of
	/// truth and none of the ceremony.
	///
	/// Only the last component may change. ``baseURL`` is this file's folder and
	/// everything the take points at is relative to it, so a document told it
	/// had moved to another folder would go on resolving against the old one.
	/// Moving is ``write(to:)``, which re-relativises; this is a rename.
	public func renamed(to fileURL: URL) {
		guard let url,
		      fileURL.deletingLastPathComponent().standardizedFileURL
		      	== url.deletingLastPathComponent().standardizedFileURL,
		      fileURL.standardizedFileURL != url.standardizedFileURL
		else { return }
		self.url = fileURL
		onChange?()
	}

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
		savedTranscript = transcript
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
