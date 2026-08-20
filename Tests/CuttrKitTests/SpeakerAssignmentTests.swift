import Foundation
import Testing
@testable import CuttrKit

/// Labelling an interview without pressing four hundred keys.
@Suite struct SpeakerAssignmentTests {

	/// Six lines, split by full stops rather than by silence — which is what a
	/// real interview looks like, and the reason the carry-forward matters.
	private func interview() -> Transcript {
		Transcript(words: (0 ..< 6).flatMap { line in
			[Word(start: Double(line) * 2, end: Double(line) * 2 + 1, text: "wort"),
			 Word(start: Double(line) * 2 + 1, end: Double(line) * 2 + 1.9, text: "ende\(line).")]
		})
	}

	private func speakers(_ said: Transcript) -> [String?] {
		said.lines.map { said.speaker(ofLine: $0) }
	}

	@Test func theTakeIsSixLines() {
		#expect(interview().lines.count == 6)
	}

	/// The first press on an untouched take paints to the end, because every
	/// line agrees with the one under the cursor: they are all unassigned.
	@Test func oneKeyOnAFreshTakeNamesTheWholeThing() {
		var said = interview()
		#expect(said.assign("papa", from: 0) == 6)
		#expect(speakers(said) == Array(repeating: "papa", count: 6))
	}

	/// And the next press, on the next line, paints from there. Two people
	/// taking turns is one key per turn — not one key per word.
	@Test func eachTurnIsOneKey() {
		var said = interview()
		said.assign("papa", from: 0)
		said.assign("mia", from: said.lines[1].lowerBound)
		#expect(speakers(said) == ["papa", "mia", "mia", "mia", "mia", "mia"])
		said.assign("papa", from: said.lines[2].lowerBound)
		said.assign("mia", from: said.lines[3].lowerBound)
		#expect(speakers(said) == ["papa", "mia", "papa", "mia", "mia", "mia"])
	}

	/// Going back to correct one turn does not wipe out the rest of the take:
	/// the run stops at the first line somebody already answered differently.
	@Test func correctingOneTurnStopsAtTheNextOne() {
		var said = interview()
		said.assign("papa", from: 0)
		said.assign("mia", from: said.lines[2].lowerBound)
		#expect(speakers(said) == ["papa", "papa", "mia", "mia", "mia", "mia"])
		// Line 1 was papa and so was line 0 before it, so only line 1 changes:
		// line 2 is mia and stops the run.
		#expect(said.assign("oma", from: said.lines[1].lowerBound) == 1)
		#expect(speakers(said) == ["papa", "oma", "mia", "mia", "mia", "mia"])
	}

	/// Taking a name back off is the same operation with nobody in it.
	@Test func nobodyIsAnAnswerToo() {
		var said = interview()
		said.assign("papa", from: 0)
		said.assign(nil, from: said.lines[4].lowerBound)
		#expect(speakers(said) == ["papa", "papa", "papa", "papa", nil, nil])
	}

	/// A word index that is not in the take is answered rather than crashed —
	/// a click lands where it lands.
	@Test func anIndexOutsideTheTakeChangesNothing() {
		var said = interview()
		#expect(said.assign("papa", from: 99) == 0)
		#expect(said.speakers.isEmpty)
		var empty = Transcript()
		#expect(empty.assign("papa", from: 0) == 0)
	}

	/// Changing a slug reaches every word that named it, which is what makes
	/// it safe to have written it four hundred times.
	@Test func renamingReachesEveryWord() {
		var said = interview()
		said.assign("papa", from: 0)
		said.assign("mia", from: said.lines[3].lowerBound)
		#expect(said.rename("papa", to: "vater") == 6)
		#expect(said.speakers == ["vater", "mia"])
	}

	/// Who is in the sidecar, in the order they are first heard — which is what
	/// the pane offers when the take's own cast is empty.
	@Test func theSidecarSaysWhoIsInIt() {
		var said = interview()
		said.assign("papa", from: 0)
		said.assign("mia", from: said.lines[1].lowerBound)
		said.assign("papa", from: said.lines[2].lowerBound)
		#expect(said.speakers == ["papa", "mia"])
	}
}
