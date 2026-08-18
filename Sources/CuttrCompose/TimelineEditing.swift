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
