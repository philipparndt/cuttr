import CuttrCompose
import CuttrKit
import Foundation

/// What a project is made of, as a tree.
///
/// **Why a tree and not two lists.** The window used to say this twice. A takes
/// table knew there were fifteen clips in `Mia 1` and could not show you one; a
/// library knew every clip and listed `Mia 1` fifteen times in a column. Between
/// them they answered one question — what have I got to work with — and answered
/// half of it each, in two stacked panes with a drag handle between them.
///
/// Four roots, because there are four kinds of name a project refers to. A
/// take's clips are its children, which is the join neither list could make.
///
/// **Tags are a root and not children of a take.** A tag *spans* takes:
/// `#b-roll` means every clip tagged so, wherever it was cut, and that is what
/// dragging one puts on the programme. Under a take it would appear once per
/// take that had it and every copy would drag the same thing, which is a list
/// that lies about what its rows mean.
///
/// Everything here is a function of ``ComposeDocument/Vocabulary`` and a search
/// string. No view, no state, so the shape of the tree can be checked without a
/// window — which is most of what is worth checking about it.
public enum Material {

	/// The four headings, in the order they are shown.
	public enum Root: String, CaseIterable, Sendable {
		case takes, scenes, anchors, tags

		public var title: String { rawValue }

		public var kind: Theme.Kind? {
			switch self {
			case .takes: return .take
			case .scenes: return .scene
			case .anchors, .tags: return nil
			}
		}
	}

	public enum Row: Sendable, Equatable {
		case root(Root)
		/// A take the project lists. `problem` is what went wrong reading it —
		/// a moved take is the commonest fault in a project, and the first
		/// anybody should hear of it is here.
		case take(name: String, path: String, clips: Int, problem: String?)
		/// Every downloaded meme, under one row.
		///
		/// A meme is a take with a single clip in it, so listing them take by
		/// take is a page of headings with one line under each. They are
		/// material of a kind — short, borrowed, interchangeable — and what
		/// somebody wants is to see the ones they have and drag one out. The
		/// library folded them into one heading for this reason and the tree
		/// keeps it.
		case memes(count: Int)
		case clip(ComposeDocument.Vocabulary.Item)
		case scene(String)
		case anchor(name: String, take: String)
		case tag(String, count: Int)

		/// What a project file writes to mean this, or nothing for a row that
		/// is a heading rather than material.
		public var reference: String? {
			switch self {
			case .root, .memes: return nil
			// A take is not written as one reference — see ``Node/references``.
			case .take: return nil
			case .clip(let item): return item.reference
			case .scene(let name): return name
			case .anchor(let name, _): return name
			case .tag(let name, _): return "#\(name)"
			}
		}

		/// The colour that says what kind of thing this is. Selection is said in
		/// value rather than in hue precisely so that these keep meaning
		/// something — see ``MarkedRow``.
		public var kind: Theme.Kind? {
			switch self {
			case .root(let root): return root.kind
			case .take, .memes: return .take
			case .clip: return .clip
			case .scene: return .scene
			case .anchor: return .anchor
			case .tag: return .tag
			}
		}
	}

	/// A row and whatever hangs under it. Two levels below a root and no more:
	/// a clip has no children, and its tags are shown *on* it, because a row
	/// that folds to reveal two words is a triangle nobody presses twice.
	public struct Node: Sendable, Equatable {
		public var row: Row
		public var children: [Node]

		public init(_ row: Row, _ children: [Node] = []) {
			self.row = row
			self.children = children
		}

		/// Everything this row puts on the programme when it is dragged.
		///
		/// One reference for a clip, a tag, an anchor or a scene. For a take,
		/// every clip it holds, in the order the take holds them — a first
		/// assembly is made by dropping whole takes, and the alternative was a
		/// row that looks draggable and is not. A heading drags nothing.
		public var references: [String] {
			if let own = row.reference { return [own] }
			guard case .take = row else { return [] }
			return children.compactMap(\.row.reference)
		}
	}

	// MARK: - Building it

	/// The whole tree, filtered by what somebody typed.
	///
	/// A root is always present, even holding nothing: the shape of the panel
	/// should not change with the contents of the project, or somebody learns
	/// where `Anchors` is and then cannot find it in the project that has none.
	public static func tree(of vocabulary: ComposeDocument.Vocabulary,
	                        takes: [ComposeDocument.TakeEntry] = [],
	                        matching needle: String = "") -> [Node] {
		let wanted = needle.trimmingCharacters(in: .whitespaces).lowercased()
		return Root.allCases.map { root in
			Node(.root(root), children(under: root, of: vocabulary, takes: takes,
			                           matching: wanted))
		}
	}

	private static func children(under root: Root,
	                             of vocabulary: ComposeDocument.Vocabulary,
	                             takes: [ComposeDocument.TakeEntry],
	                             matching needle: String) -> [Node] {
		switch root {
		case .takes:
			return takeNodes(of: vocabulary, takes: takes, matching: needle)
		case .scenes:
			return vocabulary.scenes.filter { hit(needle, $0) }.map { Node(.scene($0)) }
		case .anchors:
			return vocabulary.anchors.filter { hit(needle, $0) }.map {
				Node(.anchor(name: $0, take: vocabulary.anchorTakes[$0] ?? ""))
			}
		case .tags:
			return vocabulary.tags.filter { hit(needle, $0) }.map { tag in
				Node(.tag(tag, count: vocabulary.items.filter { $0.tags.contains(tag) }.count))
			}
		}
	}

	/// The takes, in the order the *project* lists them.
	///
	/// Not alphabetical: the order the file has them in is somebody's
	/// arrangement, and the file already keeps it.
	///
	/// A take whose own name matches shows all its clips — somebody searching
	/// for a take wants the take, not the one clip in it that happens to share
	/// a word. A take that does not match shows the clips that do, and is kept
	/// only if any do: a match has to be shown *with* its parents, because a
	/// clip row with no take above it cannot say where it came from, which is
	/// the one thing this tree exists to say.
	private static func takeNodes(of vocabulary: ComposeDocument.Vocabulary,
	                              takes: [ComposeDocument.TakeEntry],
	                              matching needle: String) -> [Node] {
		let byName = Dictionary(takes.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
		var out: [Node] = []

		for name in vocabulary.takeNames where !vocabulary.memeTakes.contains(name) {
			let all = vocabulary.items.filter { $0.take == name }
			let takeMatches = hit(needle, name)
			let clips = takeMatches ? all : all.filter { matches(needle, $0) }
			guard takeMatches || !clips.isEmpty || needle.isEmpty else { continue }
			let entry = byName[name]
			out.append(Node(
				.take(name: name, path: entry?.path ?? "",
				      clips: entry?.clips ?? all.count, problem: entry?.problem),
				clips.map { Node(.clip($0)) }))
		}

		let memes = vocabulary.items.filter {
			vocabulary.memeTakes.contains($0.take)
				&& (matches(needle, $0) || hit(needle, $0.take))
		}
		if !memes.isEmpty {
			out.append(Node(.memes(count: memes.count), memes.map { Node(.clip($0)) }))
		}
		return out
	}

	/// A clip, by either of its names or by any tag it carries.
	private static func matches(_ needle: String,
	                            _ item: ComposeDocument.Vocabulary.Item) -> Bool {
		hit(needle, [item.slug, item.name] + item.tags)
	}

	/// Plain containment, lower-cased. The library matched names this way, and
	/// a clip is matched on its tags as well as its two names — `#b-roll` is
	/// how somebody looks for b-roll.
	private static func hit(_ needle: String, _ fields: String...) -> Bool {
		hit(needle, fields)
	}

	private static func hit(_ needle: String, _ fields: [String]) -> Bool {
		guard !needle.isEmpty else { return true }
		return fields.contains { $0.lowercased().contains(needle) }
	}
}
