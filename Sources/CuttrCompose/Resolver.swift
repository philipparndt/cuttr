import CoreGraphics
import CuttrKit
import Foundation

public enum ResolveError: LocalizedError {
	case takeUnreadable(String, String)
	case unknownClip(ClipReference)
	case ambiguousClip(String, [String])
	case missingMedia(ClipReference)
	case missingSound(String)
	case unknownAnchor(String)
	case emptyQuery(String)
	case emptyGroup(String)
	case unknownGroup(String)
	case noReference(String)
	case nothingOnTheTimeline
	case emptyProgramme

	public var errorDescription: String? {
		switch self {
		case .takeUnreadable(let path, let why):
			return "Could not read the take \(path): \(why)"
		case .unknownClip(let reference):
			return "No clip called `\(reference)` in any of this project's takes."
		case .ambiguousClip(let slug, let takes):
			return "`\(slug)` is in more than one take (\(takes.joined(separator: ", "))). "
				+ "Write it as `\(takes[0])/\(slug)`."
		case .missingMedia(let reference):
			return "The take that `\(reference)` comes from has no video or audio file."
		case .missingSound(let path):
			return "No sound file at `\(path)`. Paths under `sounds:` are relative to "
				+ "the project file, the same as the takes."
		case .unknownAnchor(let name):
			return "No anchor called `\(name)` in any of this project's takes. "
				+ "Anchors are marked in the cutting window, on the take."
		case .emptyGroup(let name):
			return "The section `@\(name)` has nothing in it."
		case .unknownGroup(let name):
			return "No section called `@\(name)` on this timeline."
		case .emptyQuery(let source):
			return "`\(source)` matches no clips. Check the tag \u{2014} tags are lower-case and hyphenated."
		case .noReference(let slug):
			return "`match: {reference: \(slug)}` names a clip that is not on this timeline, "
				+ "or whose take has not been analysed."
		case .nothingOnTheTimeline:
			return "This project has no clips yet. Add them under `timeline:` — by slug "
				+ "(`- intro`), as a query (`- \"#b-roll\"`), or in a `group:`."
		case .emptyProgramme:
			return "Nothing to render: every clip on the timeline resolved to zero length."
		}
	}
}

/// One clip of the programme, placed on the programme's clock.
public struct ResolvedClip: Sendable {
	/// Decibels to apply so this clip sits at the programme's target loudness.
	/// Zero when nothing has been measured, which is the honest default: an
	/// unmeasured clip is left exactly as it was recorded.
	public var gain: Double = 0
	/// The take's gain curve over this clip, on the **programme's** clock.
	///
	/// Decibels, and added to ``gain`` rather than replacing it — see
	/// ``CuttrKit/GainCurve``. Put on the programme's clock here because that is
	/// the clock the mix is written on, and the mapping is a fact this function
	/// knows and the renderer does not: the same clip used twice contributes the
	/// same repair at two different moments of the finished programme.
	///
	/// Cut to the clip's own span with a point at each edge, so the whole of the
	/// clip is covered and a dip that starts before the cut still arrives
	/// part-way down. Empty for a take with no curve, which is what keeps every
	/// programme that has never seen one rendering exactly as it did.
	public var levels: [LevelPoint] = []
	/// The grade to apply: the take's own look, over its profile, with whatever
	/// the automatic match worked out.
	public var look: Look = .none

	public let reference: ClipReference
	public let takeName: String
	public let clip: Clip
	/// The media, already resolved against the take file's own directory.
	public let videoURL: URL?
	public let audioURL: URL?
	/// Seconds to add to the audio file's clock to reach the video's, carried
	/// through from the take. This is why cutting and composing are two files:
	/// an alignment corrected in the take is corrected in every project that
	/// uses it, without anybody re-exporting anything.
	public let audioOffset: Double
	/// Where this clip sits in the finished programme.
	/// Which timeline entry put this clip here.
	///
	/// A path rather than a name, because that is what the panel has when
	/// somebody selects a row — and it is the only way to tell one placement of
	/// a clip from another when the same clip is used twice.
	public var entry: [Int] = []
	public let start: Double
	/// How long this clip overlaps the one before it — in seconds, nought for a
	/// cut. The programme's clock already has it: the clip starts this much
	/// earlier than the one before it ended.
	public var transition: Double = 0
	/// What is drawn while the two shots overlap, with `seconds` already cut
	/// down to the overlap that fitted.
	public var blend: Transition = .cut
	/// The presentation treatments on this placement, in the order the file had
	/// them and each one's `at:` on the take's clock — kept sorted, because the
	/// mapping below walks them and expects to meet them in order.
	///
	/// A treatment with no hold moves the picture and gives the programme back
	/// nothing, which is legal and costs the clock nothing.
	public var presentations: [Presentation] = []

	/// How much longer this clip is on the programme than it is on the take.
	public var held: Double { presentations.reduce(0) { $0 + $1.hold } }

	public var end: Double { start + duration }

	/// **Not** the clip's own length any more. A held clip occupies its own
	/// length plus every hold on it: nothing of the recording is skipped, the
	/// picture merely stands still part-way through.
	public var duration: Double { clip.duration + held }

	/// A time on the programme's clock, expressed on this take's clock.
	///
	/// Piecewise, and this is the method the whole feature turns on. Walking
	/// the holds in order: anything before the next one maps straight across;
	/// anything inside one is the moment the hold began — the take's clock
	/// stands still while the picture does; anything after it has that hold's
	/// length taken off, and the walk carries on with the rest.
	public func takeTime(forProgramme time: Double) -> Double {
		var remaining = time - start
		for shown in presentations where shown.hold > 0 {
			// How far into the clip this treatment is, on the take's clock.
			// It is compared against `remaining`, which has already had every
			// earlier hold taken off it — so the two are on the same clock by
			// the time they meet, and neither has to know how many holds have
			// gone by.
			let begins = shown.at - clip.start
			if remaining <= begins { break }
			if remaining < begins + shown.hold { return clip.start + begins }
			remaining -= shown.hold
		}
		return clip.start + remaining
	}

	/// The reverse: a time on the take's clock put back on the programme's, by
	/// adding every hold that has already happened by then.
	///
	/// A take time that falls exactly on a hold maps to where the hold *begins*
	/// — the first moment the picture is showing that frame — which is what
	/// makes this the inverse of the method above.
	public func programmeTime(forTake time: Double) -> Double {
		var out = start + (time - clip.start)
		for shown in presentations where shown.hold > 0 {
			guard shown.at < time else { break }
			out += shown.hold
		}
		return out
	}

	/// One stretch of this clip as it plays: where it comes from in the take,
	/// how much of the take that is, and where it lands on the programme.
	public struct Playing: Sendable, Equatable {
		public let from: Double
		/// How much of the take this stretch plays. Nought for a held frame,
		/// which plays one frame for however long the hold lasts.
		public let take: Double
		public let at: Double
		public let length: Double
		public var isHeld: Bool { take == 0 }
	}

	/// How this clip is actually laid down: one stretch when nothing is held,
	/// and a split with a frozen stretch between for each hold.
	///
	/// The renderer's answer and the strip's, so neither has to work out where
	/// a hold falls for itself.
	public var playing: [Playing] {
		var out: [Playing] = []
		var from = clip.start
		var at = start
		for shown in presentations where shown.hold > 0 {
			let mark = min(max(shown.at, clip.start), clip.end)
			let run = mark - from
			if run > 0 {
				out.append(Playing(from: from, take: run, at: at, length: run))
				at += run
			}
			out.append(Playing(from: mark, take: 0, at: at, length: shown.hold))
			at += shown.hold
			from = mark
		}
		let rest = clip.end - from
		if rest > 0 { out.append(Playing(from: from, take: rest, at: at, length: rest)) }
		return out
	}

	/// The rectangle the picture occupies at a moment of the **programme**,
	/// and whether a treatment is on at all.
	///
	/// One place, so the compositor, the strip and the panel cannot disagree
	/// about where the picture is. See ``Presentation/frame(at:)`` for the
	/// easing; this method's job is only to find which treatment a programme
	/// time is inside and hand it the time on its own terms.
	public func picture(atProgramme time: Double) -> Presentation.Rectangle {
		var passed: Double = 0
		for shown in presentations {
			// The treatment's span on the programme's clock: the ramp out, the
			// hold, and the ramp back.
			let begins = start + (shown.at - clip.start) + passed - shown.ramp
			let ends = begins + shown.ramp + shown.hold + shown.ramp
			if time < begins { break }
			if time <= ends { return shown.frame(at: time - begins) }
			passed += shown.hold
		}
		return .whole
	}

	/// This clip's level at a moment of the programme, in decibels: the flat
	/// figure and whatever the curve is doing there, added.
	///
	/// The one place the sum is written down, so the mix, a dissolve's two ends
	/// and anything that asks later cannot disagree about it.
	public func level(at time: Double) -> Double {
		gain + GainCurve.gain(at: time, in: levels)
	}
}

/// A card, placed on the programme's clock.
///
/// A type of its own rather than a widened ``ResolvedClip``, and the reason is
/// what the fields of that one are: a reference, a take name, a clip, two media
/// URLs, an audio offset, a measured gain and a grade. Every one of them is a
/// fact about a recording, and a card has no recording. Widening would have
/// made eight fields optional and pushed an `if let` into the trim dialog, the
/// grade, the loudness pass and the anchor mapping — none of which can ever
/// mean anything for a card — in exchange for one merged array. This way each
/// type is entirely about one kind of thing, and the one place that genuinely
/// wants them interleaved says so: ``ResolvedProject/programme``.
public struct ResolvedCard: Sendable, Equatable {
	public let card: Card
	/// Which timeline entry put this here — a path, the same as a clip's.
	public var entry: [Int] = []
	public let start: Double
	/// How long this overlaps what came before it, in seconds. A card can be
	/// dissolved into exactly as a shot can.
	public var transition: Double = 0
	public var blend: Transition = .cut
	public var duration: Double { card.duration }
	public var end: Double { start + card.duration }
}

/// A sound, placed on the programme's clock with its file found.
public struct ResolvedSound: Sendable {
	public let sound: Sound
	/// Where in the file this one is written, for the panel.
	public let origin: Origin
	/// The file, already resolved against the project's own folder.
	public let url: URL
	public let start: Double
	public let end: Double
	public var duration: Double { end - start }
}

/// An overlay with its times worked out.
public struct ResolvedOverlay: Sendable {
	/// The overlay itself.
	///
	/// Settable, and for one reason: a panel dragging an overlay across a
	/// picture has a value that is not in the file yet and has to draw it. The
	/// alternative was for the preview to work out where a bubble would go with
	/// arithmetic of its own, which is exactly the second implementation this
	/// program keeps refusing to have. See ``showing(_:)``.
	public var overlay: Overlay
	/// Where in the file this one is written.
	///
	/// The overlay itself is not the answer: what is resolved is the overlay
	/// *as it is at one appearance*, so an overlay that says something else the
	/// second time is not equal to the one in the file. Matching by value found
	/// nothing, and the panel lost the picture and the anchor as soon as
	/// anybody typed a word into a range.
	public let origin: Origin
	/// Which of that overlay's appearances — a caption on twice is two of
	/// these, and a drag on the second bar moves the second one.
	public let appearance: Int
	public let start: Double
	/// How long this clip overlaps the one before it — a dissolve, in seconds,
	/// nought for a cut. The programme's clock already has it: the clip starts
	/// this much earlier than the one before it ended.
	public var transition: Double = 0
	public let end: Double
	/// The anchor's path, already mapped onto the programme's clock. `nil` for
	/// an overlay that does not follow anything.
	public let path: AnchorPath?

	public var duration: Double { end - start }

	/// The same appearance, at the same times, on the same anchor path, with a
	/// different overlay in it.
	///
	/// What a drag is: everything about *when* and *what it follows* is settled
	/// and only the numbers being dragged have changed, so re-resolving the
	/// project sixty times a second to see them would be the wrong tool by
	/// several orders of magnitude.
	public func showing(_ overlay: Overlay) -> ResolvedOverlay {
		var out = self
		out.overlay = overlay
		return out
	}
}

/// A named section of the programme, once its contents are laid out.
public struct ResolvedGroup: Sendable, Equatable {
	public let name: String
	/// Which timeline entry put this clip here.
	///
	/// A path rather than a name, because that is what the panel has when
	/// somebody selects a row — and it is the only way to tell one placement of
	/// a clip from another when the same clip is used twice.
	public var entry: [Int] = []
	public let start: Double
	/// How long this clip overlaps the one before it — a dissolve, in seconds,
	/// nought for a cut. The programme's clock already has it: the clip starts
	/// this much earlier than the one before it ended.
	public var transition: Double = 0
	public let end: Double
	public var duration: Double { end - start }
	/// How deeply nested, so the strip can draw sections inside sections.
	public let depth: Int
}

/// A project with every reference followed and every time worked out.
public struct ResolvedProject: Sendable {
	public let project: Project
	/// The folder the project file is in, for the things a scene may name —
	/// a logo, a badge, a texture.
	public var baseURL: URL = URL(fileURLWithPath: ".")
	public let clips: [ResolvedClip]
	/// The stretches with no footage behind them, in the order they play.
	public var cards: [ResolvedCard] = []
	public let overlays: [ResolvedOverlay]
	/// Music and the rest, in the order it starts.
	public var sounds: [ResolvedSound] = []
	public let groups: [ResolvedGroup]
	/// What was skipped, and why.
	///
	/// A project being built is half-built most of the time: a section made
	/// and not yet filled, a caption hung on it before there is anything under
	/// it. Refusing to resolve any of that leaves the window with an empty
	/// preview and the render button greyed, which is a poor way to be told
	/// "you have not finished". These are said beside the picture instead, and
	/// the programme is whatever *does* resolve.
	public var warnings: [String] = []
	/// Every anchor the takes brought, with its path on the programme's clock.
	public let anchors: [(anchor: Anchor, path: AnchorPath?)]
	public var duration: Double { max(clips.last?.end ?? 0, cards.last?.end ?? 0) }

	/// Everything that occupies time, in the order it plays.
	///
	/// The renderer's instruction list is a sequence of stretches of programme
	/// and does not care which kind each one is; everything else — the grade,
	/// the trim dialog, the strip's take names — wants one kind or the other.
	/// So they are kept apart and put in order here, which is the only place
	/// that needs them together.
	public var programme: [Placement] {
		(clips.map(Placement.clip) + cards.map(Placement.card))
			.sorted { $0.start < $1.start }
	}
}

/// One thing on the programme: a shot, or a card.
public enum Placement: Sendable {
	case clip(ResolvedClip)
	case card(ResolvedCard)

	public var start: Double {
		switch self {
		case .clip(let clip): return clip.start
		case .card(let card): return card.start
		}
	}

	public var duration: Double {
		switch self {
		case .clip(let clip): return clip.duration
		case .card(let card): return card.duration
		}
	}

	public var end: Double { start + duration }

	/// How long this overlaps what came before it.
	public var transition: Double {
		switch self {
		case .clip(let clip): return clip.transition
		case .card(let card): return card.transition
		}
	}

	public var blend: Transition {
		switch self {
		case .clip(let clip): return clip.blend
		case .card(let card): return card.blend
		}
	}

	/// The card's fill, for the one that has one.
	public var fill: Card.Fill? {
		if case .card(let card) = self { return card.card.fill }
		return nil
	}
}

public enum Resolver {

	/// Reads the takes a project names, follows every slug, and lays the
	/// programme out on one clock.
	///
	/// `baseURL` is the project file's directory: every path in the file is
	/// relative to it, which is what lets a project, its takes and its media
	/// travel as one folder.
	/// `files` is the read-through cache. It defaults to the shared one, which
	/// is what the program wants — the whole point is that it survives from one
	/// resolve to the next. A test hands in its own, so that asserting how many
	/// times a file was parsed is a statement about *that* test rather than
	/// about whatever else the suite happened to be resolving at the time.
	public static func resolve(_ project: Project, baseURL: URL,
	                           files: ResolvedFiles = .shared) throws -> ResolvedProject {
		// Said explicitly, because `URL(fileURLWithPath:relativeTo:)` only
		// treats the base as a folder when it ends in a slash — and a URL built
		// by `appendingPathComponent` does not. Without this, every relative
		// path in the project resolves against the folder *above* the one the
		// project is in, which fails as a missing file rather than as anything
		// that points at the cause.
		let baseURL = URL(fileURLWithPath: baseURL.path, isDirectory: true)
		// Load the takes, keyed by the name a reference would use: the file's
		// own name without its extension.
		var takes: [(name: String, take: Take, directory: URL)] = []
		for path in project.takes {
			let url = URL(fileURLWithPath: path, relativeTo: baseURL).standardizedFileURL
			do {
				// Read through the cache: unchanged since the last resolve means
				// unparsed this time. See ``ResolvedFiles``.
				let take = try files.take(at: url)
				takes.append((url.deletingPathExtension().lastPathComponent, take, url.deletingLastPathComponent()))
			} catch {
				throw ResolveError.takeUnreadable(path, error.localizedDescription)
			}
		}

		func find(_ reference: ClipReference) throws -> (name: String, take: Take, directory: URL, clip: Clip) {
			let candidates = takes.filter { reference.take == nil || $0.name == reference.take }
				.compactMap { entry -> (String, Take, URL, Clip)? in
					guard let clip = entry.take.clips.first(where: { $0.slug == reference.slug }) else { return nil }
					return (entry.name, entry.take, entry.directory, clip)
				}
			guard let first = candidates.first else { throw ResolveError.unknownClip(reference) }
			// Ambiguity is named rather than guessed at. Picking the first take
			// would work until the day somebody adds a second `intro`, and then
			// it would quietly render the wrong shot.
			guard candidates.count == 1 else {
				throw ResolveError.ambiguousClip(reference.slug, candidates.map(\.0))
			}
			return first
		}

		/// Every clip a query selects, across every take, in a defined order.
		///
		/// Sorted by the clip's own `order` first — which is the field's whole
		/// purpose — then by the order the takes are listed in, then by where
		/// the clip sits in its take. The last two are tie-breakers rather than
		/// policy: they exist so that a query returns the same programme twice
		/// running, which a set does not.
		func select(_ query: ClipQuery) -> [(name: String, take: Take, directory: URL, clip: Clip)] {
			var found: [(index: Int, entry: (String, Take, URL, Clip))] = []
			for (index, entry) in takes.enumerated() {
				for clip in entry.take.clips where query.matches(takeName: entry.name, clip: clip) {
					found.append((index, (entry.name, entry.take, entry.directory, clip)))
				}
			}
			return found.sorted { a, b in
				if a.entry.3.order != b.entry.3.order { return a.entry.3.order < b.entry.3.order }
				if a.index != b.index { return a.index < b.index }
				return a.entry.3.start < b.entry.3.start
			}.map { $0.entry }
		}

		var clips: [ResolvedClip] = []
		var cards: [ResolvedCard] = []
		var cursor = 0.0
		/// How long the last thing laid down was, whatever kind it was.
		///
		/// A dissolve is never longer than half of either side, and "either
		/// side" now includes a card — so the length has to be carried rather
		/// than read off the end of the clip list, which no longer knows what
		/// came immediately before.
		var previousLength: Double?
		/// Where each named section begins and ends, once its contents are laid
		/// out. Recorded while flattening rather than computed afterwards,
		/// because a group's extent is exactly what its entries produced — and
		/// a group that produced nothing has no extent at all.
		var groups: [String: (start: Double, end: Double)] = [:]
		var groupDepth: [String: Int] = [:]
		/// What each entry laid down, keyed by its path.
		///
		/// This is what an overlay written inside an entry covers. A name
		/// cannot say it: `from: intro` finds every use of `intro`, and the
		/// whole reason for writing an overlay inside a placement is to mean
		/// *that* placement and no other. A path is the only thing that tells
		/// two uses of one clip apart, and the layout is the only thing that
		/// knows where each of them ended up.
		var extents: [[Int]: (start: Double, end: Double)] = [:]
		/// What was skipped along the way, for the panel to say beside the
		/// picture rather than instead of it.
		var warnings: [String] = []

		/// A dissolve waiting to be applied to the next clip laid down.
		///
		/// Carried rather than applied at once, because the entry that asks for
		/// it may be a section or a query: what dissolves is the first clip that
		/// comes out of it, whatever that turns out to be.
		var pending = Transition.cut

		/// `as:` names this placement, and a named placement is a section of
		/// one entry — the same thing an overlay hangs on, so nothing
		/// downstream has to learn a new idea. A card wants one more than a
		/// clip does: `@intro` is the only way a title finds it.
		func name(_ label: String?, from: Double, to: Double, depth: Int) {
			guard let label else { return }
			let existing = groups[label]
			groups[label] = (min(existing?.start ?? from, from), max(existing?.end ?? to, to))
			groupDepth[label] = groupDepth[label] ?? depth
		}

		func lay(out entries: [TimelineEntry], depth: Int = 0, at prefix: [Int] = []) throws {
			for (position, entry) in entries.enumerated() {
				let path = prefix + [position]
				if entry.transition.duration > 0 { pending = entry.transition }
				if case .group(let name, let inner) = entry.source {
					let start = cursor
					try lay(out: inner, depth: depth + 1, at: path)
					// An empty section is a section somebody has just made,
					// and making one is half of an act whose other half is
					// filling it. It contributes nothing and is skipped, and
					// that is not worth saying: a programme built question by
					// question is thirteen empty sections for most of an
					// afternoon, and thirteen lines of warning about work in
					// progress is a program complaining that somebody has not
					// finished yet.
					//
					// The tree already says it, quietly and in the right place:
					// the section is there with nothing under it.
					//
					// An overlay hung on the name is a different matter — the
					// name is not registered, so it is dropped, and *that* is
					// warned about where it happens.
					guard cursor > start else { continue }
					// A name used twice extends the first one rather than
					// replacing it: two `@interview` sections are one section
					// with something in between, which is what an overlay hung
					// on it should cover.
					let existing = groups[name]
					groups[name] = (min(existing?.start ?? start, start), max(existing?.end ?? cursor, cursor))
					groupDepth[name] = min(groupDepth[name] ?? depth, depth)
					extents[path] = (start, cursor)
					continue
				}

				if case .card(let card) = entry.source {
					// A card of no length is not a frame of nothing, it is
					// nothing — the same rule a clip trimmed to nothing gets.
					guard card.duration > 0 else { continue }
					var overlap = 0.0
					var blend = Transition.cut
					if pending.duration > 0, let previousLength {
						overlap = min(pending.duration, previousLength / 2, card.duration / 2)
						blend = Transition(pending.kind, seconds: overlap, edge: pending.edge)
						cursor -= overlap
					}
					pending = .cut
					let placedAt = cursor
					cards.append(ResolvedCard(
						card: card, entry: path, start: cursor,
						transition: overlap, blend: blend))
					cursor += card.duration
					previousLength = card.duration
					name(entry.label, from: placedAt, to: cursor, depth: depth)
					extents[path] = (placedAt, cursor)
					continue
				}

				let found: [(name: String, take: Take, directory: URL, clip: Clip)]
				switch entry.source {
				case .clip(let reference):
					found = [try find(reference)]
				case .list(let references):
					found = try references.map(find)
				case .query(let query, let source):
					let selected = select(query)
					// A query that matches nothing is almost always a typo in a
					// tag, and silently rendering a shorter programme is the
					// worst way to find that out.
					guard !selected.isEmpty else { throw ResolveError.emptyQuery(source) }
					found = selected
				case .group, .card:
					continue   // both handled above
				}

				let trim = entry.trim
				let label = entry.label
				// Sorted here, once, because both the mapping and the layout
				// walk them in order and neither should have to wonder.
				let treatments = entry.presentations.sorted { $0.at < $1.at }
				// A list or a query is several clips, and an overlay written on
				// that entry covers all of them: from where the first one
				// started to where the last one ended.
				var laid: (start: Double, end: Double)?
				for entry in found {
					// Trimmed for this placement only: the take keeps its own
					// marks, and the same shot used twice can be a different
					// length each time.
					var clip = entry.clip
					if trim.head > 0 || trim.tail > 0 {
						clip.start += max(0, trim.head)
						clip.end -= max(0, trim.tail)
					}
					guard clip.duration > 0 else { continue }
					// A dissolve is an overlap: the incoming clip starts before
					// the outgoing one ends, and the programme is shorter by
					// exactly that much. Never longer than half of either clip,
					// or a three-second dissolve between two-second shots would
					// run past both.
					var overlap = 0.0
					var blend = Transition.cut
					if pending.duration > 0, let previousLength {
						overlap = min(pending.duration, previousLength / 2, clip.duration / 2)
						blend = Transition(pending.kind, seconds: overlap, edge: pending.edge)
						cursor -= overlap
					}
					pending = .cut
					let placedAt = cursor
					let video = entry.take.video.map {
						URL(fileURLWithPath: $0, relativeTo: entry.directory).standardizedFileURL
					}
					let audio = entry.take.audio.map {
						URL(fileURLWithPath: $0.file, relativeTo: entry.directory).standardizedFileURL
					}
					guard video != nil || audio != nil else {
						throw ResolveError.missingMedia(ClipReference(take: entry.name, slug: entry.clip.slug))
					}
					clips.append(ResolvedClip(
						reference: ClipReference(take: entry.name, slug: entry.clip.slug),
						takeName: entry.name,
						clip: clip,
						videoURL: video,
						audioURL: audio,
						audioOffset: entry.take.audio?.offset ?? 0,
						entry: path,
						start: cursor,
						transition: overlap,
						blend: blend,
						// `at:` is on the take's clock, the same clock the clip
						// marks are on, so which clip of a list a treatment
						// belongs to is a question the file already answers.
						presentations: treatments.filter {
							$0.at >= clip.start && $0.at <= clip.end
						}))
					// The programme is longer by the holds. Everything after
					// this clip begins later, and `previousLength` — which is
					// what a dissolve is allowed half of — is the length as
					// played, not as recorded.
					let played = clip.duration + clips[clips.count - 1].held
					cursor += played
					previousLength = played
					name(label, from: placedAt, to: cursor, depth: depth)
					laid = (min(laid?.start ?? placedAt, placedAt), cursor)
				}
				extents[path] = laid
			}
		}
		guard !project.timeline.isEmpty else { throw ResolveError.nothingOnTheTimeline }
		try lay(out: project.timeline)
		// A programme of nothing but cards is a programme: an intro screen with
		// a title over it and no footage at all is a thing somebody makes.
		guard !clips.isEmpty || !cards.isEmpty else { throw ResolveError.emptyProgramme }

		// Levels and grades.
		//
		// Both are worked out here rather than at render time, because both are
		// a comparison between what a take measured and what the programme
		// wants — and the programme is what this function knows about. The
		// renderer is handed numbers, not a policy.
		let takesByName = Dictionary(uniqueKeysWithValues: takes.map { ($0.name, $0.take) })
		let referenceCast: [Double]? = project.output.matchReference.flatMap { slug in
			clips.first { $0.reference.slug == slug }
				.flatMap { takesByName[$0.takeName]?.measured.cast }
		}
		if project.output.matchReference != nil, referenceCast == nil {
			throw ResolveError.noReference(project.output.matchReference ?? "")
		}

		for index in clips.indices {
			guard let take = takesByName[clips[index].takeName] else { continue }

			if let audio = project.output.audio, let loudness = take.measured.loudness {
				let peak = take.measured.peak ?? -.infinity
				clips[index].gain = Loudness(integrated: loudness, peak: peak)
					.gain(toward: audio.target, ceiling: audio.ceiling)
			}
			// And then the clip's own trim, which is a different question. The
			// take's figure brings the *recording* to a target; a trim is a
			// correction between clips of the same recording, which no take-wide
			// measurement can make — two children at one microphone are ten
			// decibels apart and stay that way however the take is matched.
			//
			// Added rather than replacing, so a project matching to a target
			// still does and a take nobody has levelled is unchanged. The
			// ceiling above guards the automatic match; it does not overrule a
			// number somebody typed, because that number is the decision.
			clips[index].gain += take.gain + clips[index].clip.gain

			// And the curve, which is the same decision at a finer grain: three
			// levels, all in decibels, all added. Carried as points rather than
			// folded into the figure above because it is not one figure — the
			// whole of what it says is that the level is different at 4:31 than
			// it is at 4:32.
			clips[index].levels = GainCurve.clipped(
				take.levels, from: clips[index].clip.start, to: clips[index].clip.end
			).map { point in
				LevelPoint(at: clips[index].programmeTime(forTake: point.at), gain: point.gain)
			}

			// The take's own look over the profile it names, and then the match.
			// The match is a `gain` the take may already carry from an analysis
			// pass; computing it here as well means a project can be re-matched
			// against a different reference without re-analysing anything.
			var look = take.look.over(take.look.profile.flatMap { project.profiles[$0] } ?? .none)
			if let reference = referenceCast, let cast = take.measured.cast {
				look.gain = Look.match(cast: cast, to: reference)
			}
			clips[index].look = look
		}

		// Anchors come from the takes, with their solved paths read in and put
		// on the programme's clock. A take that is used twice contributes its
		// anchors once: a face is tracked once, not once per appearance.
		//
		// Sidecar paths are relative to the *take* file, not the project, which
		// is what lets a take and its tracking travel together into any
		// programme that wants them.
		var paths: [String: AnchorPath] = [:]
		var anchorsByName: [String: Anchor] = [:]
		for entry in takes {
			for anchor in entry.take.anchors {
				anchorsByName[anchor.name] = anchor
				// The expensive one: a line per tracked frame, twenty-five a
				// second for as long as the shot runs, and it had not changed
				// since the last keystroke either.
				guard let sidecar = anchor.path,
				      let solved = files.anchorPath(
					      at: URL(fileURLWithPath: sidecar, relativeTo: entry.directory))
				else { continue }

				// Every clip this shot overlaps, not the one clip it was solved
				// over — that is the point of tracking a shot rather than a
				// subclip. The same face followed once can serve a clip near the
				// start of the programme and another near the end.
				var samples: [(time: Double, point: CGPoint)] = []
				var covered: [ClosedRange<Double>] = []
				for clip in clips where clip.takeName == entry.name {
					let low = max(clip.clip.start, anchor.from)
					let high = min(clip.clip.end, anchor.to)
					guard high > low else { continue }
					let inside = solved.samples.filter { $0.time >= low && $0.time <= high }
					guard !inside.isEmpty else { continue }
					var mapped: [(time: Double, point: CGPoint)] = []
					for sample in inside {
						let when = clip.programmeTime(forTake: sample.time)
						// A hold between this sample and the last one: the
						// picture was standing still for all of it, so the mark
						// was too. Without this the path slides across the hold
						// and the tracked face ends up where the recording
						// would have been if it had never stopped — which is
						// the drift the mapping exists to prevent.
						if let previous = mapped.last,
						   when - previous.time > (sample.time - clip.takeTime(forProgramme: previous.time)) + 1e-6 {
							mapped.append((when - 1e-4, previous.point))
						}
						mapped.append((time: when, point: sample.point))
					}
					// Held at the last known position right up to the moment the
					// next stretch begins, so a gap between two uses of the shot
					// is a hold and a jump rather than a slide across the cut.
					if let previous = samples.last, let first = mapped.first, first.time > previous.time {
						samples.append((first.time - 1e-4, previous.point))
					}
					samples.append(contentsOf: mapped)
					covered.append(mapped[0].time ... mapped[mapped.count - 1].time)
				}
				guard !samples.isEmpty else { continue }
				paths[anchor.name] = AnchorPath(samples: samples, covered: covered.sorted { $0.lowerBound < $1.lowerBound })
			}
		}

		/// Where a mark is on the programme, once for each time it is there.
		///
		/// A clip used twice is two places, not one long one. Spanning from the
		/// first to the last covered everything in between — which is why using
		/// a clip twice was awkward: an overlay hung on it swallowed whatever
		/// came between the two uses.
		func places(_ endpoint: Overlay.Span.Endpoint) throws -> [(start: Double, end: Double)] {
			let found = endpoint.places(in: clips) { groups[$0] }
			// A clip that is not in the programme is a mistake in the file and
			// is said so. A *section* that is not there — never made, renamed,
			// or made and not yet filled — takes this overlay off the programme
			// instead: it used to take the whole programme off, which is a hard
			// way to be told that a section you are still building is still
			// empty.
			if case .clip(let reference) = endpoint, found.isEmpty {
				throw ResolveError.unknownClip(reference)
			}
			return found
		}

		/// A written range, on the programme's clock — once for each time the
		/// material it names is used. One function, because an overlay and a
		/// sound say when they happen in the same words and must get the same
		/// answer.
		func when(_ span: Overlay.Span) throws -> [(start: Double, end: Double)] {
			switch span {
			case .times(let a, let b):
				return [(a, b)]
			case .within(let mark, let a, let b):
				// Timed from where the clip or section starts, so it travels
				// with it — and once for each time that clip is used.
				return try places(mark).map { ($0.start + a, $0.start + b) }
			case .marks(let from, let to):
				// Mark-bound, which is the point: the caption belongs to a
				// section of the programme, so re-cutting the takes moves it.
				let heads = try places(from)
				let tails = try places(to)
				if from == to { return heads }
				// From the first time the head is used to the first end of the
				// tail after it, so a range across the programme is one range
				// rather than every combination.
				var spans: [(start: Double, end: Double)] = []
				for head in heads {
					guard let tail = tails.first(where: { $0.end >= head.end })
						?? tails.last else { continue }
					spans.append((head.start, max(tail.end, head.end)))
				}
				return spans
			}
		}

		var overlays: [ResolvedOverlay] = []

		/// One overlay, wherever it is written, on to the programme's clock.
		///
		/// `covering` is what it falls back to when it says nothing about when
		/// it is on — the placement it was written inside. There is no such
		/// thing at the top level, which is why an overlay there without a
		/// range is dropped by the reader instead.
		func place(
			_ overlay: Overlay, from origin: Origin,
			covering: (start: Double, end: Double)?
		) throws {
			if let name = overlay.anchor, anchorsByName[name] == nil {
				throw ResolveError.unknownAnchor(name)
			}
			guard !overlay.appearances.isEmpty else {
				// Exactly the placement, which is the point of the spelling:
				// the same clip used twice is two placements, and a caption
				// written inside the second one is on over the second one.
				guard let covering else {
					warnings.append("\(overlay.described) is written on a timeline entry "
						+ "that lays nothing down, so it is not on the programme.")
					return
				}
				overlays.append(ResolvedOverlay(
					overlay: overlay, origin: origin, appearance: 0,
					start: covering.start, end: covering.end,
					path: overlay.anchor.flatMap { paths[$0] }))
				return
			}
			// One resolved overlay per range. Everything downstream — the layer
			// tree, the transitions, the anchor following — is about a thing
			// that is on from one moment to another, so an overlay that is on
			// three times is three of those and nothing else changes.
			for (position, appearance) in overlay.appearances.enumerated() {
				let spans = try when(appearance.span)
				if spans.isEmpty, case .marks(let from, _) = appearance.span,
				   case .group(let name) = from {
					warnings.append("Nothing is called `@\(name)` on this timeline, "
						+ "so \(overlay.described) is not on it.")
				}
				// Written inside an entry, and pinned to programme times that
				// have drifted off it.
				//
				// This is the one way an overlay can be quietly wrong. Written
				// inside a clip with no range it *covers* that clip and follows
				// it through every re-cut. Written inside a clip with
				// `from:`/`to:`, it is pinned to the programme's clock — so the
				// moment anything upstream changes length, the clip moves and
				// the overlay does not. It was found on a real project: three
				// spinners five seconds early, playing over the shot before the
				// one they were written on, and nothing anywhere said so.
				//
				// Said rather than corrected. The times are what somebody wrote
				// and this cannot know which of the two they meant — but it can
				// refuse to let it pass in silence, and name `within:` as the
				// spelling that would have survived.
				if let covering, case .times = appearance.span {
					let outside = spans.filter {
						$0.end <= covering.start + 0.001 || $0.start >= covering.end - 0.001
					}
					if !outside.isEmpty {
						warnings.append("\(overlay.described) is written inside a "
							+ "timeline entry but pinned to programme times, and those "
							+ "times no longer touch it — so it plays over something "
							+ "else. Write it as `within:` that clip, or take the "
							+ "range off to cover the whole of it.")
					}
				}
				for span in spans where span.end > span.start {
					// What it says *here*: a spinner that comes back saying
					// something else is one overlay with two appearances, and by
					// the time it reaches the layer tree it is simply two
					// overlays that agree about everything but their words.
					overlays.append(ResolvedOverlay(
						overlay: overlay.shown(at: appearance), origin: origin, appearance: position,
						start: span.start, end: span.end,
						path: overlay.anchor.flatMap { paths[$0] }))
				}
			}
		}

		// The ones written inside the timeline first, because that is the order
		// the file puts them in — and the order of this list is the order they
		// are drawn, which decides what a film overlay or an aberration is a
		// lens on. `timeline:` comes before `overlays:` on the page.
		func nested(_ entries: [TimelineEntry], at prefix: [Int]) throws {
			for (position, entry) in entries.enumerated() {
				let path = prefix + [position]
				for (index, overlay) in entry.overlays.enumerated() {
					try place(overlay, from: .entry(path: path, index: index),
					          covering: extents[path])
				}
				if case .group(_, let inner) = entry.source { try nested(inner, at: path) }
			}
		}
		try nested(project.timeline, at: [])

		for (index, overlay) in project.overlays.enumerated() {
			try place(overlay, from: .project(index), covering: nil)
		}

		// And the treatments' scenes, which are ordinary scene overlays laid on
		// the stretch the picture is held for.
		//
		// Made here rather than written in the file because they are not a
		// second thing to keep in step: what the file says is `scene: bullets`
		// on a treatment, and when that scene is on is decided entirely by the
		// hold. Anything downstream — the layer pass, the painter, the preview
		// — sees a scene overlay and treats it as one.
		for clip in clips {
			var passed: Double = 0
			for shown in clip.presentations {
				defer { passed += shown.hold }
				guard shown.hold > 0, !shown.scene.isEmpty else { continue }
				// What the scene cannot work out for itself: how long it is up,
				// whether its lines arrive together, and which part of the
				// frame the picture has left free. A built-in reads these; an
				// authored scene ignores them, as it ignores any parameter it
				// does not name.
				var parameters = shown.parameters
				parameters["hold"] = String(shown.hold)
				parameters["reveal"] = shown.reveal.rawValue
				let free = shown.into.free
				parameters["column-x"] = String(free.x)
				parameters["column-width"] = String(free.width)
				guard project.scene(named: shown.scene, with: parameters) != nil else {
					// Named and not rendered empty. A hold with nothing in it
					// is six seconds of a still picture and no explanation of
					// why, which is the worst way to find out a name is wrong.
					warnings.append("Nothing is called `\(shown.scene)`, so the "
						+ "presentation on `\(clip.reference)` holds the picture and "
						+ "shows nothing.")
					continue
				}
				let begins = clip.start + (shown.at - clip.clip.start) + passed
				overlays.append(ResolvedOverlay(
					overlay: Overlay(
						kind: .scene(shown.scene, with: parameters),
						appearances: [Overlay.Appearance(
							.times(from: begins, to: begins + shown.hold))],
						// The scene's own keys bring its parts in and take them
						// out; an overlay slide over the top of that would be
						// two animations arguing. It dissolves at the edges
						// only because the hold has hard ends and a scene that
						// vanishes with the picture's first frame of movement
						// reads as a dropped frame.
						arrival: .fade(over: 0.25),
						departure: .fade(over: 0.25)),
					origin: .entry(path: clip.entry, index: 0), appearance: 0,
					start: begins, end: begins + shown.hold, path: nil))
			}
		}

		// Spelled out rather than chained: the type checker gives up on the
		// one-expression version of this and says so.
		var resolvedGroups: [ResolvedGroup] = []
		for (name, range) in groups {
			resolvedGroups.append(ResolvedGroup(
				name: name, start: range.start, end: range.end, depth: groupDepth[name] ?? 0))
		}
		resolvedGroups.sort { a, b in
			a.depth == b.depth ? a.start < b.start : a.depth < b.depth
		}

		// The sounds, on the same clock and out of the same folder as everything
		// else the project names. A sound that is on twice is two of these, the
		// same way an overlay is.
		var sounds: [ResolvedSound] = []

		/// One sound, wherever it is written, on to the programme's clock.
		///
		/// `covering` is what it plays for when it says nothing — the placement
		/// it was written inside, exactly as an overlay written there is drawn
		/// for. There is no such thing at the top level, which is why a sound
		/// there without a range is dropped by the reader instead.
		func lay(
			_ sound: Sound, from origin: Origin, covering: (start: Double, end: Double)?
		) throws {
			let url = URL(fileURLWithPath: sound.file, relativeTo: baseURL).standardizedFileURL
			// Said now rather than discovered as a silent track. A missing
			// recording is named when a take is resolved, and a missing piece of
			// music should be named the same way — the commonest thing to go
			// wrong with a path is that it is wrong.
			guard FileManager.default.fileExists(atPath: url.path) else {
				throw ResolveError.missingSound(sound.file)
			}
			guard let span = sound.span else {
				guard let covering, covering.end > covering.start else {
					warnings.append("The sound `\(sound.file)` is written on a timeline entry "
						+ "that lays nothing down, so it does not play.")
					return
				}
				sounds.append(ResolvedSound(
					sound: sound, origin: origin, url: url,
					start: covering.start, end: covering.end))
				return
			}
			for where_ in try when(span) where where_.end > where_.start {
				sounds.append(ResolvedSound(
					sound: sound, origin: origin, url: url,
					start: where_.start, end: where_.end))
			}
		}

		func nestedSounds(_ entries: [TimelineEntry], at prefix: [Int]) throws {
			for (position, entry) in entries.enumerated() {
				let path = prefix + [position]
				for (index, sound) in entry.sounds.enumerated() {
					try lay(sound, from: .entry(path: path, index: index), covering: extents[path])
				}
				if case .group(_, let inner) = entry.source { try nestedSounds(inner, at: path) }
			}
		}
		try nestedSounds(project.timeline, at: [])
		for (index, sound) in project.sounds.enumerated() {
			try lay(sound, from: .project(index), covering: nil)
		}
		sounds.sort { $0.start < $1.start }

		let resolvedAnchors = anchorsByName.keys.sorted().map {
			(anchor: anchorsByName[$0]!, path: paths[$0])
		}
		var resolved = ResolvedProject(
			project: project, baseURL: baseURL, clips: clips, cards: cards,
			overlays: overlays, sounds: sounds, groups: resolvedGroups,
			anchors: resolvedAnchors)
		// What a component's frames are, and whether they are still what the
		// project asks for. Said beside the picture rather than fixed here:
		// baking is seconds to minutes and resolving happens on every keystroke,
		// and a preview that quietly showed the last bake as though it were the
		// render would be the one failure `docs/remotion.md` says is worse than
		// an empty rectangle.
		warnings += ComponentBaker.staleness(project, from: baseURL)
		resolved.warnings = warnings
		return resolved
	}
}
