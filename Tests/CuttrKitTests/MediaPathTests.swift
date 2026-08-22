import Foundation
import Testing
@testable import CuttrKit

/// How a file this program writes refers to another file on the disk.
///
/// The case that started this: a sound in
/// `/Users/mia/Desktop/dingsda/dingsda-cuttr/media/` written into the project
/// beside it as an absolute path. The project has since moved to
/// `/Volumes/500G` and the path names a file that is not there any more on the
/// only machine that ever had it.
@Suite struct MediaPathTests {

	private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

	// MARK: - Under the project

	/// The reported case. Media in a subfolder of the project's folder is
	/// written as a subfolder path and nothing else.
	@Test func mediaInASubfolderIsRelative() {
		#expect(MediaPath.relative(url("/a/b/media/music.mp3"), toFolder: url("/a/b"))
			== "media/music.mp3")
	}

	@Test func mediaBesideTheProjectIsJustItsName() {
		#expect(MediaPath.relative(url("/a/b/music.mp3"), toFolder: url("/a/b")) == "music.mp3")
	}

	/// A name with spaces, brackets and a comma in it — which is what a track
	/// downloaded from the internet is actually called, and the file that found
	/// this bug.
	@Test func anAwkwardNameIsStillJustAPath() {
		let awkward = "/a/b/media/Cartoon, Fred V - All We've Ever Known [NCS Release].mp3"
		#expect(MediaPath.relative(url(awkward), toFolder: url("/a/b"))
			== "media/Cartoon, Fred V - All We've Ever Known [NCS Release].mp3")
	}

	// MARK: - Above it

	@Test func aStepOrTwoUpIsStillOneFolderSomebodyWouldCopy() {
		#expect(MediaPath.relative(url("/a/music.mp3"), toFolder: url("/a/b")) == "../music.mp3")
		#expect(MediaPath.relative(url("/music.mp3"), toFolder: url("/a/b")) == "../../music.mp3")
	}

	/// Past that it is two unrelated places on a disk, and an absolute path at
	/// least says where the file actually is.
	@Test func somewhereElseEntirelyStaysAbsolute() {
		#expect(MediaPath.relative(url("/Volumes/500G/x.mp3"), toFolder: url("/a/b/c"))
			== "/Volumes/500G/x.mp3")
	}

	@Test func howFarItWillClimbCanBeRaised() {
		#expect(MediaPath.relative(url("/music.mp3"), toFolder: url("/a/b/c")) == "/music.mp3")
		#expect(MediaPath.relative(url("/music.mp3"), toFolder: url("/a/b/c"), ups: 3)
			== "../../../music.mp3")
	}

	// MARK: - Beside a file rather than in a folder

	@Test func besideAFileMeansBesideTheFolderItIsIn() {
		#expect(MediaPath.relative(url("/a/b/media/x.mp3"), beside: url("/a/b/film.cuttrproj"))
			== "media/x.mp3")
	}

	/// `standardized` and not `standardizedFileURL`: the second consults the
	/// file system, and one of the two files here is often about to be created.
	/// `/tmp` standardising to `/private/tmp` for the one that exists and not
	/// for the one that does not leaves two paths with nothing in common.
	@Test func aFolderThatDoesNotExistYetStillGetsARelativePath() {
		let folder = url("/tmp/nowhere-\(UUID().uuidString)")
		#expect(MediaPath.relative(folder.appendingPathComponent("media/x.mp3"),
		                           toFolder: folder) == "media/x.mp3")
	}

	@Test func aDotSegmentIsNotPartOfTheAnswer() {
		#expect(MediaPath.relative(url("/a/b/./media/x.mp3"), toFolder: url("/a/b"))
			== "media/x.mp3")
	}

	// MARK: - What somebody typed

	/// Dragging a file onto a text field puts its absolute path in, and so does
	/// pasting one out of the Finder. That is the door the reported bug came
	/// through — the file panel beside the field had always written a relative
	/// path.
	@Test func anAbsolutePathDroppedIntoAFieldIsTidied() {
		#expect(MediaPath.tidy("/a/b/media/music.mp3", against: url("/a/b"))
			== "media/music.mp3")
	}

	/// Something already relative is what somebody meant. Re-deriving it
	/// against a folder would be inventing a path nobody asked for.
	@Test func somethingAlreadyRelativeIsLeftAlone() {
		#expect(MediaPath.tidy("media/music.mp3", against: url("/a/b")) == "media/music.mp3")
		#expect(MediaPath.tidy("../music.mp3", against: url("/a/b")) == "../music.mp3")
	}

	@Test func whitespaceRoundWhatWasPastedGoes() {
		#expect(MediaPath.tidy("  media/music.mp3  ", against: url("/a/b")) == "media/music.mp3")
		#expect(MediaPath.tidy("  /a/b/media/music.mp3 ", against: url("/a/b"))
			== "media/music.mp3")
	}

	/// A project that has never been saved has no folder to be relative to, and
	/// an absolute path is the only true thing to write.
	@Test func withNoProjectFolderTheAbsolutePathStands() {
		#expect(MediaPath.tidy("/a/b/media/music.mp3", against: nil)
			== "/a/b/media/music.mp3")
	}

	@Test func nothingTypedStaysNothing() {
		#expect(MediaPath.tidy("", against: url("/a/b")) == "")
		#expect(MediaPath.tidy("   ", against: url("/a/b")) == "")
	}
}
