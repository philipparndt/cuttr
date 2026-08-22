import AppKit
import CuttrCompose
import Testing
@testable import CuttrUI

/// Takes arranged into folders, in the tree.
///
/// The arrangement lives in the project file and the tree is a view of it, so
/// what is worth checking here is the *shape* — which is a function of the
/// vocabulary, the takes and the folders, and needs no window.
@Suite struct MaterialFolderTests {

	private func entry(_ name: String) -> ComposeDocument.TakeEntry {
		.init(path: "takes/\(name).cuttr", url: URL(fileURLWithPath: "/\(name)"),
		      name: name, clips: 1, problem: nil)
	}

	private func vocabulary() -> ComposeDocument.Vocabulary {
		var found = ComposeDocument.Vocabulary()
		found.takeNames = ["mia-1", "leni", "b-roll-1"]
		found.items = found.takeNames.map {
			.init(take: $0, slug: "\($0)-clip", name: "", tags: [], start: 0, length: 5,
			      reference: "\($0)-clip")
		}
		return found
	}

	private var takes: [ComposeDocument.TakeEntry] {
		["mia-1", "leni", "b-roll-1"].map(entry)
	}

	private func names(_ nodes: [Material.Node]) -> [String] {
		nodes.map { node in
			switch node.row {
			case .root(let r): return r.title
			case .folder(let name, _): return name
			case .take(let name, _, _, _): return name
			case .memes: return "memes"
			case .clip(let item): return item.slug
			case .scene(let name): return name
			case .anchor(let name, _): return name
			case .tag(let name, _): return name
			}
		}
	}

	private func takesRoot(_ tree: [Material.Node]) -> Material.Node {
		tree.first { $0.row == .root(.takes) }!
	}

	// MARK: - The shape

	/// Folders first, then the loose ones, so the arrangement reads as an
	/// arrangement rather than as names scattered among names.
	@Test func foldersComeFirstAndLooseTakesAfter() {
		let folders = [Project.Folder(name: "Interviews",
		                              takes: ["takes/mia-1.cuttr", "takes/leni.cuttr"])]
		let root = takesRoot(Material.tree(of: vocabulary(), takes: takes, folders: folders))
		#expect(names(root.children) == ["Interviews", "b-roll-1"])
		#expect(names(root.children[0].children) == ["mia-1", "leni"])
	}

	/// A take's clips are still its children, a level further in.
	@Test func aTakeInAFolderStillHoldsItsClips() {
		let folders = [Project.Folder(name: "Interviews", takes: ["takes/mia-1.cuttr"])]
		let root = takesRoot(Material.tree(of: vocabulary(), takes: takes, folders: folders))
		#expect(names(root.children[0].children[0].children) == ["mia-1-clip"])
	}

	/// Nothing changes in a project nobody has arranged.
	@Test func aProjectWithNoFoldersIsDrawnAsItWas() {
		let root = takesRoot(Material.tree(of: vocabulary(), takes: takes))
		#expect(names(root.children) == ["mia-1", "leni", "b-roll-1"])
	}

	@Test func anEmptyFolderIsStillShown() {
		let folders = [Project.Folder(name: "B-roll")]
		let root = takesRoot(Material.tree(of: vocabulary(), takes: takes, folders: folders))
		#expect(names(root.children) == ["B-roll", "mia-1", "leni", "b-roll-1"])
		#expect(root.children[0].children.isEmpty)
	}

    /// The first folder that names a take wins it, so it appears once.
	@Test func aTakeNamedByTwoFoldersAppearsOnce() {
		let folders = [Project.Folder(name: "One", takes: ["takes/mia-1.cuttr"]),
		               Project.Folder(name: "Two", takes: ["takes/mia-1.cuttr"])]
		let root = takesRoot(Material.tree(of: vocabulary(), takes: takes, folders: folders))
		#expect(names(root.children[0].children) == ["mia-1"])
		#expect(root.children[1].children.isEmpty, "it appeared in both")
	}

	@Test func aFolderNamingATakeThatIsNotThereHoldsNothing() {
		let folders = [Project.Folder(name: "Gone", takes: ["takes/nowhere.cuttr"])]
		let root = takesRoot(Material.tree(of: vocabulary(), takes: takes, folders: folders))
		#expect(root.children[0].children.isEmpty)
		#expect(names(root.children) == ["Gone", "mia-1", "leni", "b-roll-1"])
	}

	// MARK: - Dragging and searching

	/// A folder is a container of containers: everything in everything it
	/// holds, on the same rule a take follows.
	@Test func aFolderDragsEveryClipUnderIt() {
		let folders = [Project.Folder(name: "Interviews",
		                              takes: ["takes/mia-1.cuttr", "takes/leni.cuttr"])]
		let root = takesRoot(Material.tree(of: vocabulary(), takes: takes, folders: folders))
		#expect(root.children[0].references == ["mia-1-clip", "leni-clip"])
	}

	/// A match is shown with its parents — both of them, now that there are two.
	@Test func aMatchKeepsItsFolderAsWellAsItsTake() {
		let folders = [Project.Folder(name: "Interviews", takes: ["takes/mia-1.cuttr"])]
		let root = takesRoot(Material.tree(of: vocabulary(), takes: takes, folders: folders,
		                                   matching: "mia-1-clip"))
		#expect(names(root.children) == ["Interviews"])
		#expect(names(root.children[0].children) == ["mia-1"])
		#expect(names(root.children[0].children[0].children) == ["mia-1-clip"])
	}
}
