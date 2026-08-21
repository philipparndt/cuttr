import Foundation

/// One recording session and the subclips cut out of it.
///
/// **Which clock the times are on.** Every time in a take — every clip start
/// and end — is on the *video's* clock, counted from the first frame of the
/// video file. A separately recorded audio file has a clock of its own, and
/// ``AudioTrack/offset`` is the one number that relates the two. Keeping one
/// clock for the clips is what makes the offset adjustable after the fact: a
/// nudge in the alignment pane moves the audio, and not a single cut mark.
///
/// For an audio-only take there is no video and the clips are on the audio's
/// own clock, with the offset unused.
public struct Take: Sendable, Equatable {

	/// The video file, relative to the take file, or `nil` for audio only.
	public var video: String?

	/// The separately recorded audio, if there is one.
	public var audio: AudioTrack?

	/// Where the recording came from, when it was not recorded. See
	/// ``TakeSource``: a downloaded meme is a take like any other, and this
	/// block is the only thing about it that is not.
	public var source: TakeSource?

	/// What was measured about this recording: how loud it is, what colour it
	/// is. Written by an analysis pass, not by hand — though correcting a number
	/// by hand is exactly the sort of thing a text file should allow.
	public var measured: Measured

	/// How this recording should be graded. A named profile, hand controls, and
	/// the per-channel gain an automatic match worked out.
	public var look: Look

	/// Points followed through the picture — an eye, usually — for overlays that
	/// have to sit on somebody. See ``Anchor`` for why they belong to the take
	/// rather than to a programme that uses it.
	public var anchors: [Anchor]

	/// What was said in this recording, worked out on this machine.
	///
	/// A reference to a sidecar and the provenance of it — see ``Words``. Like
	/// an anchor's path, the thousands of numbers live beside the take rather
	/// than in it; unlike an anchor, there is only ever one of these, because a
	/// take is one recording and one recording has one transcript.
	public var words: Words?

	/// Who talks in this recording.
	///
	/// A slug and a name each — see ``Speaker``. The words themselves carry the
	/// slug, out in the sidecar, so this is the one place a person's name is
	/// written and renaming them is one line changed.
	///
	/// Empty for every take nobody has labelled, and left out of the file
	/// entirely when it is: a recording of one person talking to camera has no
	/// cast and should not carry a block saying so.
	public var speakers: [Speaker]

	/// What was heard in this recording that nobody said: a laugh, applause, a
	/// cough. See ``SoundEvent``.
	///
	/// In the take file itself rather than in a sidecar, unlike the words, and
	/// the difference is arithmetic: a five-minute take has four hundred words
	/// and six laughs. Six blocks do not bury the clips, they read as part of
	/// the cut list — and they are exactly the sort of thing somebody wants to
	/// correct by hand, because a classifier that has heard a cough in a laugh
	/// should be one block to delete in an editor rather than a reason to run
	/// the whole pass again.
	public var sounds: [SoundEvent]

	/// The subclips, in the order they appear in the file.
	///
	/// The file's order is kept rather than sorted by time. Two clips may
	/// legitimately cover the same seconds — two attempts at one sentence, both
	/// worth keeping until somebody decides — and re-ordering a file somebody
	/// arranged is the sort of thing that makes an as-text tool untrustworthy.
	/// The UI sorts its *view*; the file keeps what it was given.
	public var clips: [Clip]

	/// Free-form lines the file carried that this version does not understand.
	///
	/// A take file outlives the program that wrote it. When a later version
	/// adds a key — a transcript, a chapter, a rating — an older build must not
	/// silently delete it on the next save, which is exactly what a strict
	/// decode-and-re-encode does. Unknown top-level keys are carried here and
	/// written back out.
	public var unknownKeys: [String: Any] {
		get { unknown.storage }
		set { unknown = UnknownKeys(storage: newValue) }
	}
	var unknown: UnknownKeys

	public init(
		video: String? = nil, audio: AudioTrack? = nil, clips: [Clip] = [],
		anchors: [Anchor] = [], words: Words? = nil, speakers: [Speaker] = [],
		sounds: [SoundEvent] = [],
		measured: Measured = Measured(), look: Look = .none,
		source: TakeSource? = nil, unknownKeys: [String: Any] = [:]
	) {
		self.video = video
		self.audio = audio
		self.source = source
		self.clips = clips
		self.anchors = anchors
		self.words = words
		self.speakers = speakers
		self.sounds = sounds
		self.measured = measured
		self.look = look
		self.unknown = UnknownKeys(storage: unknownKeys)
	}

	public static func == (a: Take, b: Take) -> Bool {
		a.video == b.video && a.audio == b.audio && a.clips == b.clips
			&& a.anchors == b.anchors && a.words == b.words
			&& a.speakers == b.speakers && a.sounds == b.sounds
			&& a.measured == b.measured && a.look == b.look
			&& a.source == b.source
	}

	// MARK: - The cast

	public func speaker(_ slug: String) -> Speaker? {
		speakers.first { $0.slug == slug }
	}

	/// What to call somebody. The cast's name for them, and otherwise the slug
	/// itself — a sidecar that names a speaker the take has never heard of is
	/// still worth colouring, and `mia` reads perfectly well.
	public func speakerTitle(_ slug: String) -> String {
		speaker(slug)?.title ?? slug
	}

	/// Adds a speaker under a slug nothing else in this take has.
	@discardableResult
	public mutating func add(_ speaker: Speaker) -> Speaker {
		var unique = speaker
		unique.slug = Slug.unique(
			Slug.make(from: speaker.slug.isEmpty ? speaker.name : speaker.slug),
			taken: Set(speakers.map(\.slug)))
		if unique.slug.isEmpty {
			unique.slug = Slug.numbered("speaker", taken: Set(speakers.map(\.slug)))
		}
		speakers.append(unique)
		return unique
	}

	/// Adds an anchor, with a name nothing else in this take has.
	@discardableResult
	public mutating func add(_ anchor: Anchor) -> Anchor {
		var unique = anchor
		unique.name = Slug.unique(
			Slug.make(from: anchor.name.isEmpty ? "anchor" : anchor.name),
			taken: Set(anchors.map(\.name)))
		anchors.append(unique)
		return unique
	}

	/// The slugs in use, for uniquing a new one.
	public var slugs: Set<String> { Set(clips.map(\.slug)) }

	/// Adds a clip, giving it a slug nothing else has.
	@discardableResult
	public mutating func add(_ clip: Clip) -> Clip {
		var c = clip
		c.slug = Slug.unique(c.slug.isEmpty ? Slug.make(from: c.name) : c.slug, taken: slugs)
		clips.append(c)
		return c
	}

	/// What one press of the mark key does at `time`, **on one colour's lane**.
	///
	/// The colour is not decoration here, it is which line of clips is being
	/// cut. Marking looks only at clips of the same colour: it splits one of
	/// those if the playhead is inside it, and otherwise closes off everything
	/// since the last clip *of that colour* ended. Clips of other colours are
	/// invisible to it.
	///
	/// That is what makes overlapping clips possible at all, and it is why the
	/// swatch is in the toolbar rather than buried in a menu. A pass in green
	/// gives the programme's sections; a pass in rose over the same minutes
	/// gives the alternate takes; neither pass has to work around the other, and
	/// the timeline draws each colour on its own bar. Before this, a second mark
	/// anywhere inside an existing clip could only ever split it, so two clips
	/// covering the same seconds could not be made at all.
	@discardableResult
	public mutating func mark(at time: Double, color: ClipColor = .default, minimumLength: Double = 0.01) -> Clip? {
		if let index = clips.lastIndex(where: { $0.color == color && $0.contains(time) }) {
			let existing = clips[index]
			guard time - existing.start > minimumLength,
			      existing.end - time > minimumLength else { return nil }
			clips[index].end = time
			// The tail keeps the name and the colour: splitting one clip in two
			// makes two of the same thing, and both halves being `intro` and
			// `intro-2` is what somebody would have typed anyway.
			let tail = Clip(
				slug: Slug.unique(existing.slug, taken: slugs),
				name: existing.name, start: time, end: existing.end,
				note: existing.note, color: existing.color)
			clips.insert(tail, at: index + 1)
			return tail
		}

		// The last boundary on this lane. A lane nobody has cut yet starts at
		// the beginning of the take, which is what makes picking a new colour
		// and pressing the key do the obvious thing.
		let start = clips.filter { $0.color == color }.map(\.end).filter { $0 <= time + 1e-6 }.max() ?? 0
		guard time - start > minimumLength else { return nil }
		let clip = Clip(slug: Slug.numbered(taken: slugs), start: start, end: time, color: color)
		clips.append(clip)
		return clip
	}

	/// Every tag in this take, in use order, for offering as a completion.
	public var tags: [String] {
		var seen = Set<String>()
		return clips.flatMap(\.tags).filter { seen.insert($0).inserted }.sorted()
	}

	public func clips(taggedWith tag: String) -> [Clip] {
		let wanted = Slug.make(from: tag)
		return clips.filter { $0.tags.contains(wanted) }
	}

	public mutating func setTags(_ tags: [String], for id: Clip.ID) {
		guard let index = clips.firstIndex(where: { $0.id == id }) else { return }
		var seen = Set<String>()
		clips[index].tags = tags.map { Slug.make(from: $0) }
			.filter { !$0.isEmpty && seen.insert($0).inserted }
	}

	public mutating func setOrder(_ order: Int, for id: Clip.ID) {
		guard let index = clips.firstIndex(where: { $0.id == id }) else { return }
		clips[index].order = order
	}

	/// The colours in use, in palette order — one bar each on the timeline.
	public var lanes: [ClipColor] {
		let used = Set(clips.map(\.color))
		return ClipColor.allCases.filter { used.contains($0) }
	}

	public mutating func setColor(_ color: ClipColor, for id: Clip.ID) {
		guard let index = clips.firstIndex(where: { $0.id == id }) else { return }
		clips[index].color = color
	}

	/// Moves a clip's edges. Ordered, and never inverted.
	@discardableResult
	public mutating func setTimes(start: Double, end: Double, for id: Clip.ID) -> Bool {
		guard let index = clips.firstIndex(where: { $0.id == id }) else { return false }
		clips[index].start = Swift.max(0, Swift.min(start, end))
		clips[index].end = Swift.max(start, end)
		return true
	}

	/// Renames a clip's slug, keeping it unique and valid.
	///
	/// Returns the slug that was actually used, which may differ from the one
	/// asked for. The caller shows that rather than pretending the rename took:
	/// a reference in the assembly file points at the slug that is in the file.
	@discardableResult
	public mutating func setSlug(_ requested: String, for id: Clip.ID) -> String? {
		guard let index = clips.firstIndex(where: { $0.id == id }) else { return nil }
		let cleaned = Slug.make(from: requested)
		var taken = slugs
		taken.remove(clips[index].slug)
		let final = Slug.unique(cleaned, taken: taken)
		clips[index].slug = final
		return final
	}
}

/// A separately recorded audio file and where it sits against the video.
public struct AudioTrack: Sendable, Equatable {
	/// The audio file, relative to the take file.
	public var file: String

	/// Seconds to add to the audio's own clock to reach the video's.
	///
	/// Positive means the recorder was started *after* the camera: its first
	/// sample belongs at video time `offset`, so everything it heard has to be
	/// pushed that much later to line up. Negative means the recorder was
	/// rolling first, and the composition begins part-way into it.
	///
	/// This is the number the alignment pane changes, and the reason clip times
	/// are on the video's clock: it can be corrected at any point without
	/// touching a cut.
	public var offset: Double

	public init(file: String, offset: Double = 0) {
		self.file = file
		self.offset = offset
	}
}

/// A named span of the take.
public struct Clip: Identifiable, Sendable, Equatable {

	/// Stable within one editing session, and not written to the file.
	///
	/// The file has the slug, which is what the assembly file references and
	/// what a human recognises. A table view needs an identity that survives a
	/// rename, and a slug does not, so it gets one that is not in the file.
	public let id: UUID

	/// The identifier the assembly file references. Lower-case, hyphenated.
	public var slug: String

	/// What it is, in words. May be empty — a slug alone is a usable clip.
	public var name: String

	/// Start and end on the take's clock, in seconds.
	public var start: Double
	public var end: Double

	/// Anything worth saying about it: a retake, a flub, a note for the edit.
	public var note: String?

	/// How it is drawn. See ``ClipColor`` for why it is a name.
	public var color: ClipColor

	/// Labels a project can select on.
	///
	/// The slug names *this* clip; a tag names a kind of clip. The composer can
	/// then say "every clip tagged `b-roll`, here" instead of listing twelve
	/// slugs and having to come back and add the thirteenth — which is the
	/// difference between an assembly file that survives a re-cut and one that
	/// has to be maintained alongside it.
	public var tags: [String]

	/// How much to turn this clip up or down, in decibels.
	///
	/// **A decision, not a measurement.** Loudness is measured per *recording*
	/// — see ``Measured/loudness`` — and for a take somebody speaks through at
	/// one level, that is the right grain: one pass serves every programme that
	/// uses it. Within one recording it is not. Two children at the same
	/// microphone are ten decibels apart, and a single figure for the whole
	/// take brings all of it to target while leaving them exactly as far apart
	/// as they were. That is the thing this fixes, and the cutting window is
	/// where it belongs: it is the one place the clips can be heard against
	/// each other.
	///
	/// Nought is left out of the file, so a take nobody has levelled does not
	/// carry `gain: 0` on every clip looking like a decision.
	public var gain: Double

	/// Where this clip sorts among others selected together.
	///
	/// A thousand by default, and the number is deliberately not 0 or 1: the
	/// point is that there is room on *both* sides without renumbering
	/// anything. A clip that must come first gets 500, one that must come last
	/// gets 1500, and neither has to know what the others chose.
	public var order: Int

	public static let defaultOrder = 1000

	public init(
		id: UUID = UUID(),
		slug: String,
		name: String = "",
		start: Double,
		end: Double,
		note: String? = nil,
		color: ClipColor = .default,
		tags: [String] = [],
		order: Int = Clip.defaultOrder,
		gain: Double = 0
	) {
		self.id = id
		self.slug = slug
		self.name = name
		// Ordered on the way in, so nothing downstream has to ask. A drag that
		// crosses its own start is the ordinary way to make one of these.
		self.start = Swift.min(start, end)
		self.end = Swift.max(start, end)
		self.note = note
		self.color = color
		// Tags are slugs too: they are written in a project file and typed by
		// hand, so `B-Roll` and `b-roll` must not be two different tags.
		self.tags = tags.map { Slug.make(from: $0) }.filter { !$0.isEmpty }
		self.order = order
		self.gain = gain
	}

	public var duration: Double { end - start }

	/// The clip's span as a closed range on the take's clock, which is what a
	/// measuring pass wants.
	public var span: ClosedRange<Double> { start ... max(start, end) }

	public func contains(_ time: Double) -> Bool { time >= start && time < end }

	/// The end of this clip when the playhead is already at the start, and the
	/// start otherwise.
	///
	/// One key does both, because they are one question — "take me to the edge
	/// of this shot" — and which edge is obvious from where you already are.
	/// Pressing it twice walks the clip end to end; pressing it from anywhere
	/// else in the take goes to the top of the shot, which is what somebody
	/// about to play it wants.
	public func edge(from playhead: Double, within tolerance: Double = 0.002) -> Double {
		abs(playhead - start) <= tolerance ? end : start
	}

	/// Two clips are the same clip if they say the same thing, whatever their
	/// session identities are. Identity is a view concern; equality is used to
	/// decide whether the document is dirty, which is a file concern.
	public static func == (a: Clip, b: Clip) -> Bool {
		a.slug == b.slug && a.name == b.name && a.start == b.start
			&& a.end == b.end && a.note == b.note && a.color == b.color
			&& a.tags == b.tags && a.order == b.order
	}
}

/// A box for the untyped leftovers, so `Take` can stay `Sendable`.
///
/// The contents come from YAML and go straight back to it without being read,
/// so `@unchecked` is the honest annotation: nothing mutates them.
struct UnknownKeys: @unchecked Sendable {
	var storage: [String: Any]
}
