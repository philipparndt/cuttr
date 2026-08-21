import CuttrKit
import Foundation

/// Editing the timeline as a tree.
///
/// The timeline nests — a group holds entries, and one of those may be another
/// group — so an editor showing it as a list needs a way to name a position
/// inside it. A path does that: `[2]` is the third entry, `[2, 0]` is the first
/// entry of the group that is the third entry.
///
/// All of it here rather than in the window, because it is arithmetic on a tree
/// and arithmetic on a tree is exactly the sort of thing that is wrong in a way
/// nobody notices until a project comes back in the wrong order. It can be
/// tested without a window; a table view cannot.
extension Project {

	/// One row of a flattened timeline, ready to be listed.
	public struct Row: Sendable {
		public let path: [Int]
		public let depth: Int
		public let entry: TimelineEntry
	}

	/// The timeline as a list, groups followed by their contents, indented.
	public var rows: [Row] {
		var out: [Row] = []
		func walk(_ entries: [TimelineEntry], at prefix: [Int], depth: Int) {
			for (index, entry) in entries.enumerated() {
				let path = prefix + [index]
				out.append(Row(path: path, depth: depth, entry: entry))
				if case .group(_, let inner) = entry.source {
					walk(inner, at: path, depth: depth + 1)
				}
			}
		}
		walk(timeline, at: [], depth: 0)
		return out
	}

	public func entry(at path: [Int]) -> TimelineEntry? {
		var list = timeline
		for (step, index) in path.enumerated() {
			guard index < list.count else { return nil }
			if step == path.count - 1 { return list[index] }
			guard case .group(_, let inner) = list[index].source else { return nil }
			list = inner
		}
		return nil
	}

	public mutating func replaceEntry(at path: [Int], with entry: TimelineEntry) {
		modify(at: path) { list, index in list[index] = entry }
	}

	public mutating func removeEntry(at path: [Int]) {
		modify(at: path) { list, index in list.remove(at: index) }
	}

	/// Inserts after `path`, or at the end of the top level when it is `nil`.
	///
	/// After rather than before, because adding happens while looking at the
	/// thing you want the new one to follow. A group is the exception: adding
	/// with a group selected puts the new entry *inside* it, which is what
	/// selecting a group and pressing plus obviously means.
	public mutating func insertEntry(_ entry: TimelineEntry, after path: [Int]?) {
		guard let path, !path.isEmpty else {
			timeline.append(entry)
			return
		}
		if case .group(let name, var inner)? = self.entry(at: path)?.source {
			inner.append(entry)
			replaceEntry(at: path, with: TimelineEntry(
				group: name, entries: inner, transition: self.entry(at: path)?.transition ?? 0))
			return
		}
		modify(at: path) { list, index in list.insert(entry, at: index + 1) }
	}

	/// Puts an entry at a position given as parent-and-index, which is what a
	/// drop lands as, and answers with the path it ended up at.
	///
	/// An index past the end appends, which is what dropping *on* a section
	/// means: nowhere in particular inside it.
	@discardableResult
	public mutating func insertEntry(_ entry: TimelineEntry, into parent: [Int], at index: Int) -> [Int] {
		let count = children(of: parent)?.count ?? 0
		let at = min(max(0, index), count)
		// Straight into the list at that index.
		//
		// It used to say `insertEntry(after: parent + [at - 1])`, which is the
		// same thing except when the entry before is a *section*: "after" a
		// section means inside it, deliberately, because that is what adding
		// to a selected section means. So dropping something at the end of a
		// timeline whose last entry is a section put it inside the section, and
		// dragging two entries there lost them both — the second went in after
		// the first had already moved.
		if parent.isEmpty {
			timeline.insert(entry, at: at)
		} else if case .group(let name, var inner)? = self.entry(at: parent)?.source,
		          var holder = self.entry(at: parent) {
			inner.insert(entry, at: at)
			// Rebuilt from the section itself so its own name, transition and
			// anything else it carries survive having something put in it.
			holder.source = .group(name, inner)
			replaceEntry(at: parent, with: holder)
		}
		return parent + [at]
	}

	/// Moves an entry to a parent and an index — a drag, in other words.
	///
	/// Both ends move as the tree changes underneath them, and that is the whole
	/// difficulty. Taking the entry out shifts everything after it up by one:
	/// the destination *inside* a shared parent, and the destination's own path
	/// when the entry came from above it. Getting the second wrong writes into a
	/// path that no longer exists, and the entry is simply gone — a move that
	/// deletes.
	///
	/// A section cannot be dropped into itself or into anything it contains;
	/// that is refused rather than half-done.
	@discardableResult
	public mutating func moveEntry(at from: [Int], toParent parent: [Int], index: Int) -> [Int] {
		guard let entry = self.entry(at: from) else { return from }
		if parent.count >= from.count, Array(parent.prefix(from.count)) == from { return from }

		var at = index < 0 ? Int.max : index
		if from.count == parent.count + 1, Array(from.dropLast()) == parent, (from.last ?? 0) < at {
			at -= 1
		}
		removeEntry(at: from)
		return insertEntry(entry, into: shifting(parent, removing: from), at: at)
	}

	/// Moves several entries at once, keeping the order they were in.
	///
	/// One at a time does not work, and the reason is the same shifting that
	/// makes a single move difficult: every move re-numbers the paths of the
	/// ones still waiting. So the entries are lifted first — deepest and last
	/// first, so each removal leaves the rest where they were — and put back in
	/// their original order at the destination, which is corrected for however
	/// many of them came out ahead of it.
	///
	/// Anything inside something else being moved is left alone: dragging a
	/// section and one of its own clips means the section, and putting the clip
	/// beside it as well would be taking it out of what it is being dragged
	/// with.
	@discardableResult
	public mutating func moveEntries(at paths: [[Int]], toParent parent: [Int],
	                                 index: Int) -> [[Int]] {
		// Refuse the whole move rather than half of it: dropping a section into
		// itself is meaningless and doing the rest anyway is a surprise.
		for path in paths where parent.count >= path.count
			&& Array(parent.prefix(path.count)) == path { return paths }

		// In the order they appear, so they arrive in that order too.
		let ordered = Self.outermost(paths)
		let lifted = ordered.compactMap { entry(at: $0) }
		guard lifted.count == ordered.count else { return paths }

		// How many came out of the destination ahead of where they are going.
		var at = index < 0 ? Int.max : index
		for path in ordered where path.count == parent.count + 1
			&& Array(path.dropLast()) == parent && (path.last ?? 0) < at {
			at -= 1
		}

		var destination = parent
		for path in ordered.reversed() {
			removeEntry(at: path)
			destination = shifting(destination, removing: path)
		}

		var landed: [[Int]] = []
		for (offset, entry) in lifted.enumerated() {
			landed.append(insertEntry(entry, into: destination, at: at == Int.max ? Int.max : at + offset))
		}
		return landed
	}

	/// The children an path holds, or the top level for the empty path.
	private func children(of parent: [Int]) -> [TimelineEntry]? {
		if parent.isEmpty { return timeline }
		if case .group(_, let inner)? = entry(at: parent)?.source { return inner }
		return nil
	}

	/// Where a path ends up once `removed` has been taken out from beside it.
	private func shifting(_ path: [Int], removing removed: [Int]) -> [Int] {
		let level = removed.count - 1
		guard level >= 0, path.count > level,
		      Array(path.prefix(level)) == Array(removed.prefix(level)),
		      path[level] > removed[level] else { return path }
		var out = path
		out[level] -= 1
		return out
	}

	/// Moves an entry within its own parent. Returns where it ended up.
	@discardableResult
	public mutating func moveEntry(at path: [Int], by offset: Int) -> [Int] {
		guard let index = path.last else { return path }
		var landed = path
		modify(at: path) { list, index in
			let target = index + offset
			guard target >= 0, target < list.count else { return }
			let entry = list.remove(at: index)
			list.insert(entry, at: target)
			landed = path.dropLast() + [target]
		}
		_ = index
		return landed
	}

	/// Runs `change` on the array that owns `path`, with the index in it.
	mutating func modify(at path: [Int], _ change: (inout [TimelineEntry], Int) -> Void) {
		func recurse(_ list: inout [TimelineEntry], _ path: ArraySlice<Int>) {
			guard let index = path.first, index < list.count else { return }
			if path.count == 1 {
				change(&list, index)
				return
			}
			guard case .group(let name, var inner) = list[index].source else { return }
			recurse(&inner, path.dropFirst())
			// Only the contents are replaced. Rebuilding the entry from its
			// name and its transition dropped everything else it carried —
			// which was harmless while a group carried nothing else, and stops
			// being harmless the moment it carries overlays of its own.
			list[index].source = .group(name, inner)
		}
		recurse(&timeline, path[...])
	}

	/// Changes one entry where it stands.
	///
	/// `modify(at:)` hands out the array and the index because most of what
	/// happens here is inserting and removing; this is for the cases that only
	/// want the entry — reordering the overlays or the sounds written inside it,
	/// which is what the tree's arrows do now that both live there.
	public mutating func editEntry(at path: [Int], _ change: (inout TimelineEntry) -> Void) {
		modify(at: path) { list, at in change(&list[at]) }
	}


	// MARK: - Copying

	/// Every name the timeline answers to: the sections, and the `as:` labels.
	///
	/// One set, because they are one namespace. An overlay hangs on `@name`
	/// without caring which of the two put the name there, and the resolver
	/// keeps both in the same dictionary — so two entries answering to one name
	/// are not two things a caption picks between, they are *one* stretch of
	/// programme reaching from the first to the last of them. A caption hung on
	/// that quietly covers everything in between, which is the failure this set
	/// exists to prevent.
	public var entryNames: Set<String> {
		var out: Set<String> = []
		func walk(_ entries: [TimelineEntry]) {
			for entry in entries {
				if let label = entry.label { out.insert(label) }
				if case .group(let name, let inner) = entry.source {
					out.insert(name)
					walk(inner)
				}
			}
		}
		walk(timeline)
		return out
	}

	/// A copy of an entry with everything hung on it, named so that nothing on
	/// the programme answers to two things.
	///
	/// This is the operation the whole feature is: somebody has built a shot up
	/// with a film look, a bubble, a caption and a sting, wants the same
	/// treatment on a different shot, and should not have to hang any of it
	/// again. Copy the entry, then change which clip it points at.
	///
	/// **What comes with it.** The overlays and the sounds written *inside* the
	/// entry, and — for a section — everything inside it, with whatever those
	/// entries have written inside them, all the way down. A section whose
	/// contents did not come would make the word a lie.
	///
	/// **What does not.** An overlay or a sound in the project's own list that
	/// *names* this entry stays exactly where it is and goes on covering what
	/// it covered. It is not written inside the entry, so it is not part of it —
	/// the tree files it under the entry it names, but that is where it is shown
	/// rather than where it lives. Two of the three cases are not copyable
	/// honestly in any event: one that names the entry's own `@name` would have
	/// to be rebound to whatever the copy is called, which is a change to a list
	/// nobody pointed at, and one that names a *clip* already covers the copy,
	/// because it names material and the copy is another use of the same
	/// material.
	///
	/// **The names.** Every `as:` label and every section name in the copy is
	/// made unique against the ones the timeline already uses — `shot` becomes
	/// `shot-2` — because a duplicate that left them alone would produce
	/// exactly the ambiguity above. References *within* the copy follow it: a
	/// caption inside the copied section that said `within: @shot` says
	/// `within: @shot-2` afterwards, so the copy is as self-contained as the
	/// original was. A name that is free is left alone, which is what makes
	/// this the right function for a paste from somewhere else as well.
	///
	/// A span bound to a **clip** is a different matter and is left as it is:
	/// the copy plays the same material, so `from: intro` now finds two places
	/// and a caption hung on it comes on over both. That is not this operation
	/// misbehaving, it is what putting the same clip on the programme twice has
	/// always meant, and `as:` with a name is the file's own answer to it.
	public func copy(of entry: TimelineEntry, avoiding extra: Set<String> = []) -> TimelineEntry {
		var taken = entryNames.union(extra)
		var renames: [String: String] = [:]
		// Two passes, because a name is used before it is read: an overlay on
		// the first entry of a section may hang on the name of the last, so
		// nothing can be rebound until every name in the copy is settled.
		let renamed = Self.renaming(entry, taken: &taken, recording: &renames)
		return Self.rebinding(renamed, to: renames)
	}

	/// Pass one: every name in the subtree, made free, recorded as it goes.
	private static func renaming(
		_ entry: TimelineEntry, taken: inout Set<String>, recording renames: inout [String: String]
	) -> TimelineEntry {
		var out = entry
		if let label = entry.label {
			let now = Slug.unique(label, taken: taken)
			taken.insert(now)
			renames[label] = now
			out.label = now
		}
		if case .group(let name, let inner) = entry.source {
			let now = Slug.unique(name, taken: taken)
			taken.insert(now)
			renames[name] = now
			out.source = .group(now, inner.map {
				renaming($0, taken: &taken, recording: &renames)
			})
		}
		return out
	}

	/// Pass two: every span inside the subtree, pointed at the copy's names.
	private static func rebinding(_ entry: TimelineEntry, to renames: [String: String])
		-> TimelineEntry
	{
		var out = entry
		for index in out.overlays.indices {
			for appearance in out.overlays[index].appearances.indices {
				out.overlays[index].appearances[appearance].span =
					rebinding(out.overlays[index].appearances[appearance].span, to: renames)
			}
		}
		for index in out.sounds.indices {
			out.sounds[index].span = out.sounds[index].span.map { rebinding($0, to: renames) }
		}
		if case .group(let name, let inner) = out.source {
			out.source = .group(name, inner.map { rebinding($0, to: renames) })
		}
		return out
	}

	private static func rebinding(_ span: Overlay.Span, to renames: [String: String])
		-> Overlay.Span
	{
		func moved(_ endpoint: Overlay.Span.Endpoint) -> Overlay.Span.Endpoint {
			// Only the names this copy brought with it. A clip endpoint names
			// material and is right as it stands, and a name from outside the
			// copy is a reference to something outside the copy.
			guard case .group(let name) = endpoint, let now = renames[name] else { return endpoint }
			return .group(now)
		}
		switch span {
		case .marks(let from, let to): return .marks(from: moved(from), to: moved(to))
		case .within(let mark, let from, let to): return .within(moved(mark), from: from, to: to)
		case .times: return span
		}
	}

	/// Duplicates an entry where it stands: the copy goes directly after the
	/// original, in the same section.
	///
	/// Directly after rather than at the end, because a duplicate is read
	/// against the thing it was made from. `into:at:` rather than
	/// ``insertEntry(_:after:)``, because "after" a *section* means inside it —
	/// deliberately, for adding — and a copy of a section put inside the
	/// original is not what anybody asked for.
	@discardableResult
	public mutating func duplicateEntry(at path: [Int]) -> [Int]? {
		guard let entry = self.entry(at: path), let index = path.last else { return nil }
		return insertEntry(copy(of: entry), into: Array(path.dropLast()), at: index + 1)
	}

	/// Duplicates entries into a parent and an index — a drop with ⌥ held.
	///
	/// Simpler than ``moveEntries(at:toParent:index:)`` in the one way that
	/// matters: nothing is taken out, so nothing shifts underneath the
	/// destination and there is no arithmetic to get wrong. What is left is
	/// the two rules that are not about arithmetic. Everything is lifted before
	/// anything is put back, because inserting a copy above an original moves
	/// that original's path; and each copy is named against the project as it
	/// stands *after* the one before it went in, so duplicating two sections
	/// called `shot` gives `shot-2` and `shot-3` rather than `shot-2` twice.
	///
	/// A section and something inside it means the section, exactly as it does
	/// for a move: the child is already coming with it, and a second copy of it
	/// beside the section would be one more than anybody dragged.
	///
	/// Nothing is refused. A section *can* be copied into itself — the copy is
	/// taken before anything is inserted, so it is a plain nesting rather than
	/// the paradox the same move is.
	@discardableResult
	public mutating func duplicateEntries(at paths: [[Int]], toParent parent: [Int],
	                                      index: Int) -> [[Int]] {
		let ordered = Self.outermost(paths)
		let lifted = ordered.compactMap { entry(at: $0) }
		guard lifted.count == ordered.count else { return [] }

		var at = index < 0 ? Int.max : index
		var landed: [[Int]] = []
		for entry in lifted {
			landed.append(insertEntry(copy(of: entry), into: parent, at: at))
			if at != Int.max { at += 1 }
		}
		return landed
	}

	/// The paths that are not inside another of them, in the order they appear.
	///
	/// Both a move and a copy of several rows need exactly this: a section and
	/// one of its own clips is one thing being dragged, not two, and they have
	/// to arrive in the order the programme had them rather than the order
	/// somebody happened to click.
	public static func outermost(_ paths: [[Int]]) -> [[Int]] {
		paths.filter { path in
			!paths.contains { other in
				other.count < path.count && Array(path.prefix(other.count)) == other
			}
		}.sorted { a, b in
			for (x, y) in zip(a, b) where x != y { return x < y }
			return a.count < b.count
		}
	}

	// MARK: - Overlays, wherever they are written

	/// The overlay an origin names, from the top-level list or from an entry.
	public func overlay(at origin: Origin) -> Overlay? {
		switch origin {
		case .project(let index):
			return index < overlays.count ? overlays[index] : nil
		case .entry(let path, let index):
			guard let entry = entry(at: path), index < entry.overlays.count else { return nil }
			return entry.overlays[index]
		}
	}

	/// Changes it where it is written. One function, so that every panel that
	/// edits an overlay stops caring which of the two places it came from.
	public mutating func editOverlay(at origin: Origin, _ change: (inout Overlay) -> Void) {
		switch origin {
		case .project(let index):
			guard index < overlays.count else { return }
			change(&overlays[index])
		case .entry(let path, let index):
			modify(at: path) { list, at in
				guard index < list[at].overlays.count else { return }
				change(&list[at].overlays[index])
			}
		}
	}

	/// Takes it off, wherever it is written.
	public mutating func removeOverlay(at origin: Origin) {
		switch origin {
		case .project(let index):
			guard index < overlays.count else { return }
			overlays.remove(at: index)
		case .entry(let path, let index):
			modify(at: path) { list, at in
				guard index < list[at].overlays.count else { return }
				list[at].overlays.remove(at: index)
			}
		}
	}

	/// The sound an origin names, from the top-level list or from an entry.
	public func sound(at origin: Origin) -> Sound? {
		switch origin {
		case .project(let index):
			return index < sounds.count ? sounds[index] : nil
		case .entry(let path, let index):
			guard let entry = entry(at: path), index < entry.sounds.count else { return nil }
			return entry.sounds[index]
		}
	}

	public mutating func editSound(at origin: Origin, _ change: (inout Sound) -> Void) {
		switch origin {
		case .project(let index):
			guard index < sounds.count else { return }
			change(&sounds[index])
		case .entry(let path, let index):
			modify(at: path) { list, at in
				guard index < list[at].sounds.count else { return }
				change(&list[at].sounds[index])
			}
		}
	}

	public mutating func removeSound(at origin: Origin) {
		switch origin {
		case .project(let index):
			guard index < sounds.count else { return }
			sounds.remove(at: index)
		case .entry(let path, let index):
			modify(at: path) { list, at in
				guard index < list[at].sounds.count else { return }
				list[at].sounds.remove(at: index)
			}
		}
	}
}
