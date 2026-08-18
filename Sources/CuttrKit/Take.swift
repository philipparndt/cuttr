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

	/// Points followed through the picture — an eye, usually — for overlays that
	/// have to sit on somebody. See ``Anchor`` for why they belong to the take
	/// rather than to a programme that uses it.
	public var anchors: [Anchor]

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
		anchors: [Anchor] = [], unknownKeys: [String: Any] = [:]
	) {
		self.video = video
		self.audio = audio
		self.clips = clips
		self.anchors = anchors
		self.unknown = UnknownKeys(storage: unknownKeys)
	}

	public static func == (a: Take, b: Take) -> Bool {
		a.video == b.video && a.audio == b.audio && a.clips == b.clips && a.anchors == b.anchors
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
		order: Int = Clip.defaultOrder
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
	}

	public var duration: Double { end - start }

	public func contains(_ time: Double) -> Bool { time >= start && time < end }

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
