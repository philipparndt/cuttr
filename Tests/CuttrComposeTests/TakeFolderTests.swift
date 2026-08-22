import CuttrKit
import Foundation
import Testing
@testable import CuttrCompose

/// Arranging a project's takes into folders.
///
/// A folder *refers* to takes; it does not contain them. `takes:` stays the flat
/// list of everything the project draws on, because that is what the resolver,
/// the vocabulary, the exporter and sharing all read — so the two can disagree,
/// and most of what is worth checking here is which one wins.
@Suite struct TakeFolderTests {

	private func project() -> Project {
		var made = Project(takes: ["takes/mia-1.cuttr", "takes/leni.cuttr",
		                           "takes/b-roll-1.cuttr"])
		made.folders = [
			Project.Folder(name: "Interviews", takes: ["takes/mia-1.cuttr",
			                                           "takes/leni.cuttr"]),
			Project.Folder(name: "B-roll"),
		]
		return made
	}

	// MARK: - Which one wins

	@Test func aTakeKnowsWhichFolderItIsIn() {
		let made = project()
		#expect(made.folder(of: "takes/mia-1.cuttr") == "Interviews")
		#expect(made.folder(of: "takes/b-roll-1.cuttr") == nil, "it is in none")
	}

	@Test func theLooseOnesAreTheRest() {
		#expect(project().looseTakes == ["takes/b-roll-1.cuttr"])
	}

	/// The project's order, not the order the folder happens to list them in:
	/// the project's is somebody's arrangement and the file already keeps it.
	@Test func aFoldersTakesComeInTheProjectsOrder() {
		var made = project()
		made.folders[0].takes = ["takes/leni.cuttr", "takes/mia-1.cuttr"]
		#expect(made.takes(in: "Interviews") == ["takes/mia-1.cuttr", "takes/leni.cuttr"])
	}

	/// A hand-edited file, and it has to open.
	@Test func aFolderNamingATakeTheProjectDoesNotListIsIgnored() {
		var made = project()
		made.folders[1].takes = ["takes/gone.cuttr"]
		#expect(made.takes(in: "B-roll").isEmpty)
		#expect(made.folder(of: "takes/gone.cuttr") == "B-roll",
		        "the folder still names it; there is simply no such take")
	}

	/// Not a state this program can produce, and one a text editor can.
	@Test func aTakeNamedByTwoFoldersBelongsToTheFirst() {
		var made = project()
		made.folders[1].takes = ["takes/mia-1.cuttr"]
		#expect(made.folder(of: "takes/mia-1.cuttr") == "Interviews")
		#expect(made.takes(in: "B-roll").isEmpty, "it appeared in both")
	}

	// MARK: - Editing

	@Test func aFolderIsMadeOnceUnderOneName() {
		var made = project()
		made.addFolder(named: "Outtakes")
		#expect(made.folders.map(\.name) == ["Interviews", "B-roll", "Outtakes"])
		made.addFolder(named: "Outtakes")
		#expect(made.folders.count == 3, "the same name was added twice")
		made.addFolder(named: "   ")
		#expect(made.folders.count == 3, "a folder with no name was made")
	}

	@Test func renamingKeepsItsTakesAndItsPlace() {
		var made = project()
		made.renameFolder("Interviews", to: "Talking heads")
		#expect(made.folders.map(\.name) == ["Talking heads", "B-roll"])
		#expect(made.takes(in: "Talking heads").count == 2)
	}

	/// An arrangement is not the material.
	@Test func removingAFolderLeavesItsTakesInTheProject() {
		var made = project()
		made.removeFolder("Interviews")
		#expect(made.folders.map(\.name) == ["B-roll"])
		#expect(made.takes.count == 3, "removing a folder took its takes with it")
		#expect(made.looseTakes.count == 3)
	}

	@Test func movingATakeTakesItOutOfWhereItWas() {
		var made = project()
		made.move(take: "takes/mia-1.cuttr", toFolder: "B-roll")
		#expect(made.folder(of: "takes/mia-1.cuttr") == "B-roll")
		#expect(made.takes(in: "Interviews") == ["takes/leni.cuttr"])
	}

	@Test func movingATakeOutLeavesItLoose() {
		var made = project()
		made.move(take: "takes/mia-1.cuttr", toFolder: nil)
		#expect(made.folder(of: "takes/mia-1.cuttr") == nil)
		#expect(made.takes.contains("takes/mia-1.cuttr"), "it left the project")
	}

	@Test func aTakeLeavingTheProjectLeavesItsFolder() {
		var made = project()
		made.forgetTakeInFolders("takes/mia-1.cuttr")
		#expect(made.takes(in: "Interviews") == ["takes/leni.cuttr"])
	}

	// MARK: - The file

	@Test func foldersRoundTripByteForByte() throws {
		let once = ProjectWriter.write(project())
		let back = try ProjectReader.read(once)
		#expect(ProjectWriter.write(back) == once)
		#expect(back.folders == project().folders)
	}

	/// The reason to be able to make one before there is anything to put in it.
	@Test func anEmptyFolderSurvivesASave() throws {
		let back = try ProjectReader.read(ProjectWriter.write(project()))
		#expect(back.folders.last?.name == "B-roll")
		#expect(back.folders.last?.takes.isEmpty == true, "the empty folder was dropped")
	}

	/// Nothing changes in a file nobody has arranged.
	@Test func aProjectWithNoFoldersWritesNoBlock() {
		let plain = Project(takes: ["takes/mia-1.cuttr"])
		#expect(!ProjectWriter.write(plain).contains("folders:"))
	}

	/// `takes:` is untouched, which is the whole point of the shape.
	@Test func takesIsUnchangedByAnArrangement() throws {
		let back = try ProjectReader.read(ProjectWriter.write(project()))
		#expect(back.takes == ["takes/mia-1.cuttr", "takes/leni.cuttr",
		                       "takes/b-roll-1.cuttr"])
	}
}
