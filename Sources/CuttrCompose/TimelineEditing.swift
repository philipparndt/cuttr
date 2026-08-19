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
		if at == 0 {
			// `insertEntry(_:after:)` puts things after a path, so the first
			// position is the one case it cannot express.
			if parent.isEmpty {
				timeline.insert(entry, at: 0)
			} else if case .group(let name, var inner)? = self.entry(at: parent)?.source {
				inner.insert(entry, at: 0)
				replaceEntry(at: parent, with: TimelineEntry(
					group: name, entries: inner, transition: self.entry(at: parent)?.transition ?? 0))
			}
			return parent + [0]
		}
		insertEntry(entry, after: parent + [at - 1])
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
