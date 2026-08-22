import CuttrKit
import Foundation

/// Merging two people's edits to one project, on the same rule ``TakeMerge``
/// uses: a value at a time, keyed by the name the file already has for it.
///
/// **What the key is.** A timeline entry is keyed by its `as:` label where it
/// has one, and a section by its `@name`. Those are the file's own handles —
/// the thing `within:` and `from:` point at — so keying by them is keying by
/// what the project already treats as an identity. An entry with neither gets a
/// key from what it is and how many like it came before it, which is stable for
/// as long as nobody reorders that run of clips, and is honest about not being
/// stable when somebody does.
///
/// Sections are merged through: a shot added to the introduction on one machine
/// and another added to the wrap-up on another are two edits to two different
/// places, and a project whose whole timeline conflicted whenever two people
/// touched it would not be worth pressing the button for.
///
/// As with a take, this returns a value. ``ProjectWriter`` stays the only thing
/// that writes a project.
public enum ProjectMerge {

	public struct Conflict: Sendable, Equatable, Identifiable {
		public enum Subject: Sendable, Equatable {
			/// Both changed the same entry of the programme, differently.
			case entry(key: String, mine: TimelineEntry?, theirs: TimelineEntry?)
			/// Both changed the finished film's shape.
			case output(mine: Output, theirs: Output)
			/// Both changed which takes the project draws from.
			case takes(mine: [String], theirs: [String])
			/// Both changed what is laid over the picture.
			case overlays(mine: [Overlay], theirs: [Overlay])
		}

		public var subject: Subject

		public init(subject: Subject) { self.subject = subject }

		public var id: String {
			switch subject {
			case .entry(let key, _, _): return "entry:\(key)"
			case .output: return "output"
			case .takes: return "takes"
			case .overlays: return "overlays"
			}
		}

		public var title: String {
			switch subject {
			case .entry(let key, let mine, let theirs):
				return (mine ?? theirs).map { $0.source.description } ?? key
			case .output: return "the film's size and rate"
			case .takes: return "which takes this uses"
			case .overlays: return "what is over the picture"
			}
		}
	}

	public typealias Side = TakeMerge.Side

	public struct Merged: Sendable {
		public var project: Project
		public var conflicts: [Conflict]
		public var isClean: Bool { conflicts.isEmpty }

		public init(project: Project, conflicts: [Conflict]) {
			self.project = project
			self.conflicts = conflicts
		}
	}

	// MARK: - Merging

	public static func merge(base: Project?, mine: Project, theirs: Project) -> Merged {
		var out = mine
		var conflicts: [Conflict] = []

		let (timeline, entryConflicts) = mergeEntries(
			base: base?.timeline, mine: mine.timeline, theirs: theirs.timeline, at: "")
		out.timeline = timeline
		conflicts += entryConflicts

		switch pick(base?.output, mine.output, theirs.output) {
		case .settled(let value): out.output = value
		case .disputed:
			conflicts.append(.init(subject: .output(mine: mine.output, theirs: theirs.output)))
		}
		// Takes are a list of paths and two people adding one each is the
		// ordinary way a project grows, so they are unioned rather than
		// disputed. Order follows mine, with theirs appended.
		out.takes = union(mine.takes, theirs.takes)

		switch pick(base?.overlays, mine.overlays, theirs.overlays) {
		case .settled(let value): out.overlays = value
		case .disputed:
			conflicts.append(.init(subject: .overlays(mine: mine.overlays,
			                                          theirs: theirs.overlays)))
		}

		// Named blocks, merged key by key: two people each adding a style have
		// not disagreed, and a dictionary is the one shape where that is
		// obvious.
		out.styles = mergeNamed(base?.styles, mine.styles, theirs.styles)
		out.scenes = mergeNamed(base?.scenes, mine.scenes, theirs.scenes)
		out.profiles = mergeNamed(base?.profiles, mine.profiles, theirs.profiles)
		out.sounds = whicheverMoved(base?.sounds, mine.sounds, theirs.sounds)

		// The order the file declared its blocks in is somebody's arrangement,
		// and mine is the one on this screen. Names only theirs has go after.
		var order = mine.declaredOrder
		for (block, names) in theirs.declaredOrder {
			order[block] = union(order[block] ?? [], names)
		}
		out.declaredOrder = order

		var unknown = theirs.unknownKeys
		for (key, value) in mine.unknownKeys { unknown[key] = value }
		out.unknownKeys = unknown

		return Merged(project: out, conflicts: conflicts)
	}

	public static func resolve(_ merged: Merged, choosing choices: [String: Side]) -> Project {
		var project = merged.project
		for conflict in merged.conflicts {
			guard choices[conflict.id] == .theirs else { continue }
			switch conflict.subject {
			case .entry(let key, _, let theirs):
				project.timeline = replacing(key, with: theirs, in: project.timeline, at: "")
			case .output(_, let theirs): project.output = theirs
			case .takes(_, let theirs): project.takes = theirs
			case .overlays(_, let theirs): project.overlays = theirs
			}
		}
		return project
	}

	// MARK: - The programme

	/// What a timeline entry is called, for merging purposes.
	///
	/// `as:` first, then a section's name — the two handles the file itself
	/// uses. Failing both, what it is and how many like it have come before,
	/// which is enough for the common case of a run of distinct clips.
	static func key(_ entry: TimelineEntry, occurrence: Int, under prefix: String) -> String {
		let own: String
		if let label = entry.label, !label.isEmpty {
			own = "as:\(label)"
		} else if case .group(let name, _) = entry.source {
			own = "@\(name)"
		} else {
			own = "\(entry.source.description)#\(occurrence)"
		}
		return prefix.isEmpty ? own : "\(prefix)/\(own)"
	}

	private static func keyed(_ entries: [TimelineEntry],
	                          under prefix: String) -> [(key: String, entry: TimelineEntry)] {
		var seen: [String: Int] = [:]
		return entries.map { entry in
			let shape = entry.source.description
			let n = seen[shape, default: 0]
			seen[shape] = n + 1
			return (key(entry, occurrence: n, under: prefix), entry)
		}
	}

	private static func mergeEntries(base: [TimelineEntry]?, mine: [TimelineEntry],
	                                 theirs: [TimelineEntry],
	                                 at prefix: String) -> ([TimelineEntry], [Conflict]) {
		let b = base.map { Dictionary(keyed($0, under: prefix).map { ($0.key, $0.entry) },
		                              uniquingKeysWith: { a, _ in a }) }
		let mineKeyed = keyed(mine, under: prefix)
		let theirsKeyed = keyed(theirs, under: prefix)
		let m = Dictionary(mineKeyed.map { ($0.key, $0.entry) }, uniquingKeysWith: { a, _ in a })
		let t = Dictionary(theirsKeyed.map { ($0.key, $0.entry) }, uniquingKeysWith: { a, _ in a })

		var order = mineKeyed.map(\.key)
		order += theirsKeyed.map(\.key).filter { m[$0] == nil }

		var out: [TimelineEntry] = []
		var conflicts: [Conflict] = []
		for key in order {
			let mineEntry = m[key], theirsEntry = t[key], baseEntry = b?[key]

			// Two sections of the same name on both sides: merge through them
			// rather than calling the pair a conflict. This is the case that
			// makes the feature worth having — two people working in two
			// different parts of the programme.
			if case .group(let name, let mineInside)? = mineEntry?.source,
			   case .group(_, let theirsInside)? = theirsEntry?.source {
				var baseInside: [TimelineEntry]?
				if case .group(_, let inside)? = baseEntry?.source { baseInside = inside }
				let (inside, deeper) = mergeEntries(base: baseInside, mine: mineInside,
				                                    theirs: theirsInside, at: key)
				var merged = mineEntry!
				// Everything about the section other than its contents still
				// merges as one value; the contents have just been done.
				if let baseEntry, let theirsEntry, shell(of: baseEntry) == shell(of: mineEntry!) {
					merged = theirsEntry
				}
				merged.source = .group(name, inside)
				out.append(merged)
				conflicts += deeper
				continue
			}

			switch pick(base == nil ? nil : baseEntry, mineEntry, theirsEntry) {
			case .settled(let entry):
				if let entry { out.append(entry) }
			case .disputed:
				if let mineEntry { out.append(mineEntry) }
				conflicts.append(.init(subject: .entry(key: key, mine: mineEntry,
				                                       theirs: theirsEntry)))
			}
		}
		return (out, conflicts)
	}

	/// An entry with its contents emptied, so a section can be compared on
	/// everything *except* what is inside it.
	private static func shell(of entry: TimelineEntry) -> TimelineEntry {
		var bare = entry
		if case .group(let name, _) = entry.source { bare.source = .group(name, []) }
		return bare
	}

	private static func replacing(_ key: String, with entry: TimelineEntry?,
	                              in entries: [TimelineEntry],
	                              at prefix: String) -> [TimelineEntry] {
		var out: [TimelineEntry] = []
		for (found, existing) in keyed(entries, under: prefix) {
			if found == key {
				if let entry { out.append(entry) }
				continue
			}
			if key.hasPrefix(found + "/"), case .group(let name, let inside) = existing.source {
				var deeper = existing
				deeper.source = .group(name, replacing(key, with: entry, in: inside, at: found))
				out.append(deeper)
				continue
			}
			out.append(existing)
		}
		return out
	}

	// MARK: - The rule, once

	private enum Choice<T> {
		case settled(T)
		case disputed
	}

	private static func pick<T: Equatable>(_ base: T?, _ mine: T, _ theirs: T) -> Choice<T> {
		if mine == theirs { return .settled(mine) }
		guard let base else { return .disputed }
		if base == mine { return .settled(theirs) }
		if base == theirs { return .settled(mine) }
		return .disputed
	}

	private static func whicheverMoved<T: Equatable>(_ base: T?, _ mine: T, _ theirs: T) -> T {
		if mine == theirs { return mine }
		guard let base, base == mine else { return mine }
		return theirs
	}

	private static func union(_ mine: [String], _ theirs: [String]) -> [String] {
		var out = mine
		for one in theirs where !out.contains(one) { out.append(one) }
		return out
	}

	/// Two dictionaries of named blocks, merged name by name. A name only one
	/// side has is kept; a name both changed keeps mine, because a style is a
	/// look and the one on this screen is the one somebody is working to.
	private static func mergeNamed<T: Equatable>(_ base: [String: T]?, _ mine: [String: T],
	                                             _ theirs: [String: T]) -> [String: T] {
		var out = mine
		for (name, value) in theirs {
			guard let existing = out[name] else { out[name] = value; continue }
			if let was = base?[name], was == existing { out[name] = value }
		}
		// A name both sides removed stays removed; one only I removed stays
		// removed too, on the same rule the clips use.
		if let base {
			for name in base.keys where mine[name] == nil && theirs[name] == base[name] {
				out[name] = nil
			}
		}
		return out
	}
}
