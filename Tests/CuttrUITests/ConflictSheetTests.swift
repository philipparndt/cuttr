import AppKit
import CuttrKit
import Testing
@testable import CuttrUI

/// The chooser, driven rather than looked at.
///
/// Nothing here checks what it looks like. What it checks is that the rows say
/// the right thing, that nothing can be written until every one is answered,
/// and that the words are the program's own — which is the whole claim the
/// sheet makes.
///
/// Buttons are pressed through their own target and action rather than by
/// sending a key event: an unhandled key press reaches `NSResponder` and beeps
/// on the machine the test is running on.
@Suite @MainActor struct ConflictSheetTests {

	private func clip(_ slug: String, _ start: Double, _ end: Double,
	                  name: String = "") -> Clip {
		Clip(slug: slug, name: name, start: start, end: end)
	}

	private func choose(_ conflicts: [TakeMerge.Conflict]) -> ProjectSharing.MustChoose {
		let take = Take(video: "a.mov", clips: [])
		return ProjectSharing.MustChoose(
			takes: [("takes/one.cuttr", TakeMerge.Merged(take: take, conflicts: conflicts))],
			projects: [])
	}

	// MARK: - What a row says

	@Test func aClipRowSaysBothSidesAsTimecode() {
		let rows = ConflictSheet.rows(for: choose([
			.init(subject: .clip(slug: "intro",
			                     mine: clip("intro", 0, 12, name: "Intro"),
			                     theirs: clip("intro", 0, 14, name: "Intro"))),
		]))
		#expect(rows.count == 1)
		#expect(rows[0].title == "Intro")
		#expect(rows[0].mine == "00:00.000 → 00:12.000")
		#expect(rows[0].theirs == "00:00.000 → 00:14.000")
		// Which file, because two takes can each have an `intro`.
		#expect(rows[0].file == "one.cuttr")
	}

	/// A clip one side deleted has no times to show, and "removed" is the
	/// honest word for it.
	@Test func aRemovedClipSaysSo() {
		let rows = ConflictSheet.rows(for: choose([
			.init(subject: .clip(slug: "intro", mine: clip("intro", 0, 12), theirs: nil)),
		]))
		#expect(rows[0].theirs == "removed")
	}

	/// The offset is the only thing relating the video's clock to the
	/// recorder's, so its row has to be readable as an alignment.
	@Test func anAlignmentRowSaysTheOffsetWithItsSign() {
		let rows = ConflictSheet.rows(for: choose([
			.init(subject: .audio(mine: AudioTrack(file: "m.wav", offset: 1.234),
			                      theirs: AudioTrack(file: "m.wav", offset: -0.5))),
		]))
		#expect(rows[0].title == "the recorder's alignment")
		#expect(rows[0].mine == "m.wav +00:01.234")
		#expect(rows[0].theirs == "m.wav −00:00.500")
	}

	/// No git words anywhere a person reads. Somebody who reads a diff for a
	/// living is using a git client; this is for everybody else.
	@Test func theRowsUseTheProgramsOwnWords() {
		let rows: [ConflictSheet.Row] = ConflictSheet.rows(for: choose([
			.init(subject: .clip(slug: "a", mine: clip("a", 0, 1), theirs: clip("a", 0, 2))),
			.init(subject: .audio(mine: AudioTrack(file: "m.wav", offset: 1),
			                      theirs: AudioTrack(file: "m.wav", offset: 2))),
		]))
		var text = ConflictSheet.explanation
		for row in rows { text += " " + row.title + " " + row.mine + " " + row.theirs }
		let said = text.lowercased()
		for word in ["fast-forward", "rebase", "hunk", "commit", "merge", "upstream", "stash"] {
			#expect(!said.contains(word), "the sheet says \(word)")
		}
	}

	// MARK: - Nothing is written until it is answered

	@Test func everyRowHasToBeAnsweredBeforeThereIsAnythingToWrite() {
		let rows = [
			ConflictSheet.Row(id: "clip:a", title: "A", mine: "1", theirs: "2", file: "one.cuttr"),
			ConflictSheet.Row(id: "clip:b", title: "B", mine: "3", theirs: "4", file: "one.cuttr"),
		]
		let sheet = ConflictSheet(rows: rows) { _ in }
		sheet.loadView()

		#expect(!sheet.isAnswered)
		sheet.choose(.mine, forRow: 0)
		#expect(!sheet.isAnswered, "one of two answered is not answered")
		sheet.choose(.theirs, forRow: 1)
		#expect(sheet.isAnswered)
		#expect(sheet.choice(for: "clip:a") == .mine)
		#expect(sheet.choice(for: "clip:b") == .theirs)
	}

	@Test func answeringAgainChangesTheAnswer() {
		let rows = [ConflictSheet.Row(id: "clip:a", title: "A", mine: "1", theirs: "2",
		                              file: "one.cuttr")]
		let sheet = ConflictSheet(rows: rows) { _ in }
		sheet.loadView()

		sheet.choose(.mine, forRow: 0)
		sheet.choose(.theirs, forRow: 0)
		#expect(sheet.choice(for: "clip:a") == .theirs)
	}

	/// Nothing to decide means no sheet at all. A sheet saying "no conflicts"
	/// is a sheet about this program's plumbing rather than about somebody's
	/// work — the same rule the versions list follows.
	@Test func thereIsNoSheetWhenThereIsNothingToChoose() {
		let view = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
		#expect(!ConflictSheet.present(over: view, rows: []) { _ in })
	}
}
