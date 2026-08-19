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

		let outermost = paths.filter { path in
			!paths.contains { other in
				other.count < path.count && Array(path.prefix(other.count)) == other
			}
		}
		// In the order they appear, so they arrive in that order too.
		let ordered = outermost.sorted { a, b in
			for (x, y) in zip(a, b) where x != y { return x < y }
			return a.count < b.count
		}
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
	private mutating func modify(at path: [Int], _ change: (inout [TimelineEntry], Int) -> Void) {
		func recurse(_ list: inout [TimelineEntry], _ path: ArraySlice<Int>) {
			guard let index = path.first, index < list.count else { return }
			if path.count == 1 {
				change(&list, index)
				return
			}
			guard case .group(let name, var inner) = list[index].source else { return }
			recurse(&inner, path.dropFirst())
			list[index] = TimelineEntry(
				group: name, entries: inner, transition: list[index].transition)
		}
		recurse(&timeline, path[...])
	}
}
