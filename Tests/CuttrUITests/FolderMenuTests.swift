import AppKit
import CuttrCompose
import Testing
@testable import CuttrUI

/// What each kind of row offers, and where a take can be dropped.
///
/// A menu is the only way to make a folder, so a row that does not offer it is
/// a feature nobody can reach.
@Suite @MainActor struct FolderMenuTests {

	private func tree(_ folders: [Project.Folder] = []) -> MaterialTree {
		_ = NSApplication.shared
		var found = ComposeDocument.Vocabulary()
		found.takeNames = ["mia-1", "leni"]
		found.items = found.takeNames.map {
			.init(take: $0, slug: "\($0)-clip", name: "", tags: [], start: 0, length: 5,
			      reference: "\($0)-clip")
		}
		let takes = found.takeNames.map {
			ComposeDocument.TakeEntry(path: "takes/\($0).cuttr",
			                          url: URL(fileURLWithPath: "/\($0)"),
			                          name: $0, clips: 1, problem: nil)
		}
		let tree = MaterialTree(frame: NSRect(x: 0, y: 0, width: 320, height: 600))
		tree.reload(found, takes: takes, folders: folders)
		tree.layoutSubtreeIfNeeded()
		return tree
	}

	/// The row a thing is on, found by what it is.
	private func row(_ tree: MaterialTree, _ name: String) -> Int? {
		let outline = tree.tableForTesting
		for index in 0 ..< outline.numberOfRows {
			guard let held = outline.item(atRow: index) as? MaterialTree.Held else { continue }
			switch held.node.row {
			case .root(let root) where root.title == name: return index
			case .folder(let found, _) where found == name: return index
			case .take(let found, _, _, _) where found == name: return index
			default: continue
			}
		}
		return nil
	}

	private func titles(_ tree: MaterialTree, at row: Int) -> [String] {
		let outline = tree.tableForTesting
		outline.selectRowIndexes([row], byExtendingSelection: false)
		guard let held = outline.item(atRow: row) as? MaterialTree.Held else { return [] }
		return tree.menuForTesting(held)?.items.map(\.title) ?? []
	}

	// MARK: - What each row offers

	@Test func theTakesRootOffersANewFolder() throws {
		let tree = tree()
		let at = try #require(row(tree, "takes"))
		#expect(titles(tree, at: at).contains("New Folder…"))
	}

	@Test func aFolderOffersRenamingAndRemoving() throws {
		let tree = tree([Project.Folder(name: "Interviews")])
		let at = try #require(row(tree, "Interviews"))
		let said = titles(tree, at: at)
		#expect(said.contains { $0.hasPrefix("Rename") })
		#expect(said.contains("Remove Folder"))
		#expect(said.contains("New Folder…"), "a folder cannot make a sibling")
	}

	@Test func aTakeOffersMovingToAFolder() throws {
		let tree = tree([Project.Folder(name: "Interviews")])
		let at = try #require(row(tree, "mia-1"))
		#expect(titles(tree, at: at).contains("Move to Folder"))
	}

	/// Every folder there is, plus a new one — so the whole arrangement can be
	/// done from the row without going anywhere else first.
	@Test func theMoveSubmenuListsEveryFolderAndANewOne() {
		let tree = tree([Project.Folder(name: "Interviews"),
		                 Project.Folder(name: "B-roll")])
		let said = tree.foldersMenu(for: "takes/mia-1.cuttr").items.map(\.title)
		#expect(said.contains("Interviews"))
		#expect(said.contains("B-roll"))
		#expect(said.contains("New Folder…"))
		#expect(!said.contains("Out of the Folder"), "it is not in one")
	}

	@Test func aTakeInAFolderIsOfferedTheWayOut() {
		let tree = tree([Project.Folder(name: "Interviews",
		                                takes: ["takes/mia-1.cuttr"])])
		let said = tree.foldersMenu(for: "takes/mia-1.cuttr")
		#expect(said.items.map(\.title).contains("Out of the Folder"))
		// And the one it is in is ticked.
		#expect(said.items.first { $0.title == "Interviews" }?.state == .on)
	}

	// MARK: - Dropping one in

	@Test func aTakeCanBeDroppedOnAFolder() throws {
		let tree = tree([Project.Folder(name: "Interviews")])
		let at = try #require(row(tree, "Interviews"))
		let outline = tree.tableForTesting
		let held = try #require(outline.item(atRow: at) as? MaterialTree.Held)

		var moved: (take: String, folder: String?)?
		tree.onMoveTake = { moved = ($0, $1) }
		#expect(tree.dropForTesting("takes/mia-1.cuttr", on: held))
		#expect(moved?.take == "takes/mia-1.cuttr")
		#expect(moved?.folder == "Interviews")
	}

	/// The root is how a take comes back out of a folder.
	@Test func droppingOnTheTakesRootTakesItOut() throws {
		let tree = tree([Project.Folder(name: "Interviews",
		                                takes: ["takes/mia-1.cuttr"])])
		let at = try #require(row(tree, "takes"))
		let outline = tree.tableForTesting
		let held = try #require(outline.item(atRow: at) as? MaterialTree.Held)

		var moved: (take: String, folder: String?)?
		tree.onMoveTake = { moved = ($0, $1) }
		#expect(tree.dropForTesting("takes/mia-1.cuttr", on: held))
		#expect(moved?.folder == nil, "it was not taken out")
	}

	/// Dropping a take on another files it beside its neighbour, which is what
	/// the gesture looks like it should do.
	@Test func droppingOnATakeFilesItWhereThatTakeIs() throws {
		let tree = tree([Project.Folder(name: "Interviews",
		                                takes: ["takes/leni.cuttr"])])
		let outline = tree.tableForTesting
		tree.fold(take: "Interviews")
		let at = try #require(row(tree, "leni"))
		let held = try #require(outline.item(atRow: at) as? MaterialTree.Held)

		var moved: (take: String, folder: String?)?
		tree.onMoveTake = { moved = ($0, $1) }
		#expect(tree.dropForTesting("takes/mia-1.cuttr", on: held))
		#expect(moved?.folder == "Interviews")
	}

	/// A scene is not a place to put a take.
	@Test func aTakeCannotBeDroppedOnJustAnything() throws {
		let tree = tree()
		let at = try #require(row(tree, "scenes"))
		let outline = tree.tableForTesting
		let held = try #require(outline.item(atRow: at) as? MaterialTree.Held)
		#expect(!tree.dropForTesting("takes/mia-1.cuttr", on: held))
	}
}
