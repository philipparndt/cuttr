import AppKit
import CuttrCompose
import Testing
@testable import CuttrUI

/// What a project is made of, as a tree.
///
/// The window used to say this twice: a takes table that knew there were
/// fifteen clips in `Mia 1` and could not show you one, and a library that knew
/// every clip and listed `Mia 1` fifteen times in a column. What is worth
/// checking about the tree that replaced them is its *shape* — which is a
/// function of the vocabulary and a search string, and needs no window.
@Suite struct MaterialTreeTests {

	private func item(_ take: String, _ slug: String, name: String = "",
	                  tags: [String] = [], start: Double = 0) -> ComposeDocument.Vocabulary.Item {
		.init(take: take, slug: slug, name: name, tags: tags, start: start, length: 5,
		      reference: slug)
	}

	private func vocabulary() -> ComposeDocument.Vocabulary {
		var found = ComposeDocument.Vocabulary()
		// Deliberately not alphabetical: the project's order is somebody's.
		found.takeNames = ["Leni", "Mia 1"]
		found.items = [
			item("Leni", "outro", tags: ["keep"]),
			item("Mia 1", "intro", name: "Intro", tags: ["b-roll"]),
			item("Mia 1", "demo-install", tags: ["b-roll"]),
		]
		found.tags = ["b-roll", "keep"]
		found.anchors = ["mia-eye"]
		found.anchorTakes = ["mia-eye": "Mia 1"]
		found.scenes = ["title-card"]
		return found
	}

	private func root(_ tree: [Material.Node], _ which: Material.Root) -> Material.Node {
		tree.first { $0.row == .root(which) }!
	}

	private func names(_ nodes: [Material.Node]) -> [String] {
		nodes.map { node in
			switch node.row {
			case .root(let r): return r.title
			case .take(let name, _, _, _): return name
			case .memes: return "memes"
			case .clip(let item): return item.slug
			case .scene(let name): return name
			case .anchor(let name, _): return name
			case .tag(let name, _): return name
			}
		}
	}

	// MARK: - The four roots

	@Test func thereAreFourRootsInOrder() {
		let tree = Material.tree(of: vocabulary())
		#expect(names(tree) == ["takes", "scenes", "anchors", "tags"])
	}

	/// The shape of the panel should not change with the contents of the
	/// project, or somebody learns where `Anchors` is and cannot find it in the
	/// project that has none.
	@Test func aRootWithNothingInItIsStillThere() {
		var empty = ComposeDocument.Vocabulary()
		empty.takeNames = []
		let tree = Material.tree(of: empty)
		#expect(names(tree) == ["takes", "scenes", "anchors", "tags"])
		#expect(tree.allSatisfy { $0.children.isEmpty })
	}

	// MARK: - Takes and their clips

	@Test func aTakesClipsAreItsChildren() {
		let tree = Material.tree(of: vocabulary())
		let takes = root(tree, .takes)
		#expect(names(takes.children) == ["Leni", "Mia 1"])
		#expect(names(takes.children[1].children) == ["intro", "demo-install"])
	}

	/// The order the project lists them in, whatever they sort as.
	@Test func takesAreInTheProjectsOrder() {
		let tree = Material.tree(of: vocabulary())
		#expect(names(root(tree, .takes).children) == ["Leni", "Mia 1"])
	}

	@Test func aClipHasNothingUnderIt() {
		let tree = Material.tree(of: vocabulary())
		let clips = root(tree, .takes).children[1].children
		#expect(clips.allSatisfy { $0.children.isEmpty })
	}

	/// A moved take is the commonest fault in a project, and the first anybody
	/// should hear of it is here.
	@Test func aTakeThatCannotBeReadSaysSo() {
		let takes = [ComposeDocument.TakeEntry(
			path: "takes/Mia 1.cuttr", url: URL(fileURLWithPath: "/nowhere"),
			name: "Mia 1", clips: 0, problem: "no such file")]
		let tree = Material.tree(of: vocabulary(), takes: takes)
		guard case .take(_, _, _, let problem) = root(tree, .takes).children[1].row else {
			Issue.record("no take row"); return
		}
		#expect(problem == "no such file")
	}

	// MARK: - Tags

	/// A tag spans takes, so filing it under one would be filing it under an
	/// arbitrary one of several.
	@Test func aTagIsListedOnceAndNotUnderATake() {
		let tree = Material.tree(of: vocabulary())
		let tags = root(tree, .tags)
		#expect(names(tags.children) == ["b-roll", "keep"])
		guard case .tag(_, let count) = tags.children[0].row else {
			Issue.record("no tag row"); return
		}
		#expect(count == 2, "b-roll is on two clips")
		// And nowhere under the takes.
		for take in root(tree, .takes).children {
			#expect(take.children.allSatisfy { if case .tag = $0.row { return false } else { return true } })
		}
	}

	// MARK: - Memes

	/// A meme is a take with one clip in it, so a row each would be a page of
	/// headings with one line under them.
	@Test func memesAreFoldedIntoOneRow() {
		var found = vocabulary()
		found.takeNames += ["meme-a", "meme-b"]
		found.memeTakes = ["meme-a", "meme-b"]
		found.items += [item("meme-a", "shrug"), item("meme-b", "facepalm")]

		let takes = root(Material.tree(of: found), .takes)
		#expect(names(takes.children) == ["Leni", "Mia 1", "memes"])
		#expect(names(takes.children[2].children) == ["shrug", "facepalm"])
	}

	// MARK: - What a row drags

	@Test func aClipDragsItsReference() {
		let tree = Material.tree(of: vocabulary())
		let clip = root(tree, .takes).children[1].children[0]
		#expect(clip.references == ["intro"])
	}

	@Test func aTakeDragsEveryClipItHoldsInOrder() {
		let tree = Material.tree(of: vocabulary())
		#expect(root(tree, .takes).children[1].references == ["intro", "demo-install"])
	}

	@Test func aTagDragsAsAHash() {
		let tree = Material.tree(of: vocabulary())
		#expect(root(tree, .tags).children[0].references == ["#b-roll"])
	}

	/// A heading is not material.
	@Test func aRootDragsNothing() {
		let tree = Material.tree(of: vocabulary())
		#expect(tree.allSatisfy { $0.references.isEmpty })
	}

	// MARK: - Searching

	/// A match is shown *with* its parents: a clip row with no take above it
	/// cannot say where it came from, which is the one thing this tree exists
	/// to say.
	@Test func aClipIsFoundUnderItsTake() {
		let tree = Material.tree(of: vocabulary(), matching: "demo")
		let takes = root(tree, .takes)
		#expect(names(takes.children) == ["Mia 1"], "the take holding the match went missing")
		#expect(names(takes.children[0].children) == ["demo-install"])
	}

	/// Somebody searching for a take wants the take, not the one clip in it
	/// that happens to share a word.
	@Test func aTakeThatMatchesShowsAllItsClips() {
		let tree = Material.tree(of: vocabulary(), matching: "mia 1")
		let takes = root(tree, .takes)
		#expect(names(takes.children) == ["Mia 1"])
		#expect(names(takes.children[0].children) == ["intro", "demo-install"])
	}

	@Test func aClipIsFoundByItsTag() {
		let tree = Material.tree(of: vocabulary(), matching: "keep")
		#expect(names(root(tree, .takes).children) == ["Leni"])
	}

	@Test func scenesAnchorsAndTagsAreSearchedToo() {
		#expect(names(root(Material.tree(of: vocabulary(), matching: "title"), .scenes).children)
			== ["title-card"])
		#expect(names(root(Material.tree(of: vocabulary(), matching: "eye"), .anchors).children)
			== ["mia-eye"])
		#expect(names(root(Material.tree(of: vocabulary(), matching: "roll"), .tags).children)
			== ["b-roll"])
	}

	/// The roots stay, holding nothing, so the panel keeps its shape.
	@Test func nothingMatchingLeavesTheRoots() {
		let tree = Material.tree(of: vocabulary(), matching: "nothing here")
		#expect(names(tree) == ["takes", "scenes", "anchors", "tags"])
		#expect(tree.allSatisfy { $0.children.isEmpty })
	}

	@Test func anEmptySearchIsEverything() {
		#expect(Material.tree(of: vocabulary(), matching: "   ")
			== Material.tree(of: vocabulary()))
	}
}
