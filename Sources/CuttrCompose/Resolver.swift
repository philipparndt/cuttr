import CoreGraphics
import CuttrKit
import Foundation

public enum ResolveError: LocalizedError {
	case takeUnreadable(String, String)
	case unknownClip(ClipReference)
	case ambiguousClip(String, [String])
	case missingMedia(ClipReference)
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
	public let start: Double
	public var end: Double { start + clip.duration }
	public var duration: Double { clip.duration }

	/// A time on the programme's clock, expressed on this take's clock.
	public func takeTime(forProgramme time: Double) -> Double {
		clip.start + (time - start)
	}

	/// The reverse.
	public func programmeTime(forTake time: Double) -> Double {
		start + (time - clip.start)
	}
}

/// An overlay with its times worked out.
public struct ResolvedOverlay: Sendable {
	public let overlay: Overlay
	/// Which of the project's overlays this came from.
	///
	/// The overlay itself is not the answer: what is resolved is the overlay
	/// *as it is at one appearance*, so an overlay that says something else the
	/// second time is not equal to the one in the file. Matching by value found
	/// nothing, and the panel lost the picture and the anchor as soon as
	/// anybody typed a word into a range.
	public let source: Int
	public let start: Double
	public let end: Double
	/// The anchor's path, already mapped onto the programme's clock. `nil` for
	/// an overlay that does not follow anything.
	public let path: AnchorPath?

	public var duration: Double { end - start }
}

/// A named section of the programme, once its contents are laid out.
public struct ResolvedGroup: Sendable, Equatable {
	public let name: String
	public let start: Double
	public let end: Double
	public var duration: Double { end - start }
	/// How deeply nested, so the strip can draw sections inside sections.
	public let depth: Int
}

/// A project with every reference followed and every time worked out.
public struct ResolvedProject: Sendable {
	public let project: Project
	public let clips: [ResolvedClip]
	public let overlays: [ResolvedOverlay]
	public let groups: [ResolvedGroup]
	/// Every anchor the takes brought, with its path on the programme's clock.
	public let anchors: [(anchor: Anchor, path: AnchorPath?)]
	public var duration: Double { clips.last?.end ?? 0 }
}

public enum Resolver {

	/// Reads the takes a project names, follows every slug, and lays the
	/// programme out on one clock.
	///
	/// `baseURL` is the project file's directory: every path in the file is
	/// relative to it, which is what lets a project, its takes and its media
	/// travel as one folder.
	public static func resolve(_ project: Project, baseURL: URL) throws -> ResolvedProject {
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
				let take = try TakeReader.read(try String(contentsOf: url, encoding: .utf8))
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
		var cursor = 0.0
		/// Where each named section begins and ends, once its contents are laid
		/// out. Recorded while flattening rather than computed afterwards,
		/// because a group's extent is exactly what its entries produced — and
		/// a group that produced nothing has no extent at all.
		var groups: [String: (start: Double, end: Double)] = [:]
		var groupDepth: [String: Int] = [:]

		func lay(out entries: [TimelineEntry], depth: Int = 0) throws {
			for entry in entries {
				if case .group(let name, let inner) = entry.source {
					let start = cursor
					try lay(out: inner, depth: depth + 1)
					guard cursor > start else { throw ResolveError.emptyGroup(name) }
					// A name used twice extends the first one rather than
					// replacing it: two `@interview` sections are one section
					// with something in between, which is what an overlay hung
					// on it should cover.
					let existing = groups[name]
					groups[name] = (min(existing?.start ?? start, start), max(existing?.end ?? cursor, cursor))
					groupDepth[name] = min(groupDepth[name] ?? depth, depth)
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
				case .group:
					continue   // handled above
				}

				for entry in found {
					guard entry.clip.duration > 0 else { continue }
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
						clip: entry.clip,
						videoURL: video,
						audioURL: audio,
						audioOffset: entry.take.audio?.offset ?? 0,
						start: cursor))
					cursor += entry.clip.duration
				}
			}
		}
		guard !project.timeline.isEmpty else { throw ResolveError.nothingOnTheTimeline }
		try lay(out: project.timeline)
		guard !clips.isEmpty else { throw ResolveError.emptyProgramme }

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
				guard let sidecar = anchor.path,
				      let text = try? String(
					      contentsOf: URL(fileURLWithPath: sidecar, relativeTo: entry.directory),
					      encoding: .utf8)
				else { continue }
				let solved = AnchorPath.read(text)

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
					let mapped: [(time: Double, point: CGPoint)] =
						inside.map { (time: clip.programmeTime(forTake: $0.time), point: $0.point) }
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

		var overlays: [ResolvedOverlay] = []
		for (index, overlay) in project.overlays.enumerated() {
			if let name = overlay.anchor, anchorsByName[name] == nil {
				throw ResolveError.unknownAnchor(name)
			}
			// One resolved overlay per range. Everything downstream — the layer
			// tree, the transitions, the anchor following — is about a thing
			// that is on from one moment to another, so an overlay that is on
			// three times is three of those and nothing else changes.
			for appearance in overlay.appearances {
				let start: Double
				let end: Double
				switch appearance.span {
				case .times(let a, let b):
					start = a
					end = b
				case .within(let mark, let a, let b):
					// Timed from where the clip or section starts, so it travels
					// with it.
					func extent(_ endpoint: Overlay.Span.Endpoint) throws -> (start: Double, end: Double) {
						switch endpoint {
						case .clip(let reference):
							guard let first = clips.first(where: { $0.reference.slug == reference.slug }),
							      let last = clips.last(where: { $0.reference.slug == reference.slug })
							else { throw ResolveError.unknownClip(reference) }
							return (first.start, last.end)
						case .group(let name):
							guard let range = groups[name] else { throw ResolveError.unknownGroup(name) }
							return range
						}
					}
					let where_ = try extent(mark)
					start = where_.start + a
					end = where_.start + b
				case .marks(let from, let to):
					// Mark-bound, which is the point: the caption belongs to a
					// section of the programme, so re-cutting the takes moves it.
					func extent(_ endpoint: Overlay.Span.Endpoint) throws -> (start: Double, end: Double) {
						switch endpoint {
						case .clip(let reference):
							guard let first = clips.first(where: { $0.reference.slug == reference.slug }),
							      let last = clips.last(where: { $0.reference.slug == reference.slug })
							else { throw ResolveError.unknownClip(reference) }
							return (first.start, last.end)
						case .group(let name):
							guard let range = groups[name] else { throw ResolveError.unknownGroup(name) }
							return range
						}
					}
					let a = try extent(from)
					let b = try extent(to)
					start = a.start
					end = max(b.end, a.end)
				}
				guard end > start else { continue }
				// What it says *here*: a spinner that comes back saying
				// something else is one overlay with two appearances, and by
				// the time it reaches the layer tree it is simply two overlays
				// that happen to agree about everything but their words.
				overlays.append(ResolvedOverlay(
					overlay: overlay.shown(at: appearance), source: index, start: start, end: end,
					path: overlay.anchor.flatMap { paths[$0] }))
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

		let resolvedAnchors = anchorsByName.keys.sorted().map {
			(anchor: anchorsByName[$0]!, path: paths[$0])
		}
		return ResolvedProject(project: project, clips: clips, overlays: overlays,
		                       groups: resolvedGroups, anchors: resolvedAnchors)
	}
}
