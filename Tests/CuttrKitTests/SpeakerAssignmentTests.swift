import Foundation
import Testing
@testable import CuttrKit

/// Labelling an interview: which lines an answer is about.
@Suite struct SpeakerAssignmentTests {

	/// Six lines, split by full stops rather than by silence — which is what a
	/// real interview looks like.
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

	/// One answer is about one line.
	///
	/// It used to carry forward — a press said "from here on, it is her" and
	/// painted every following line that still agreed. One keystroke for a
	/// page is quick, and it is also one keystroke for a mistake whose extent
	/// nobody can see; beside a standing guess the page was unreadable.
	@Test func oneAnswerNamesOneLine() {
		var said = interview()
		#expect(said.assign("papa", to: 0 ..< 1) == 1)
		#expect(speakers(said) == ["papa", nil, nil, nil, nil, nil])
	}

	/// Which means correcting a line reaches that line and nothing else — from
	/// either direction, with nothing to reason about.
	@Test func correctingALineTouchesNothingElse() {
		var said = interview()
		for line in said.lines { said.assign("papa", to: line) }
		#expect(said.assign("oma", to: said.lines[1]) == 1)
		#expect(speakers(said) == ["papa", "oma", "papa", "papa", "papa", "papa"])
	}

	/// A run of lines is answered by selecting them and saying who, which is
	/// the case the carry-forward was really for — and this one says exactly
	/// which lines it is about.
	@Test func aSelectionNamesEveryLineItTouches() {
		var said = interview()
		let from = said.lines[1].lowerBound
		let to = said.lines[3].upperBound
		#expect(said.assign("mia", to: from ..< to) == 3)
		#expect(speakers(said) == [nil, "mia", "mia", "mia", nil, nil])
	}

	/// And a selection of part of a line names the whole line. A speaker
	/// belongs to a line, not to the three words somebody happened to drag
	/// across — half a line named and half not is not a state the file can
	/// hold or the pane can draw.
	@Test func partOfALineNamesTheWholeLine() {
		var said = interview()
		let middle = said.lines[2]
		#expect(said.assign("mia", to: middle.upperBound - 1 ..< middle.upperBound) == 1)
		#expect(said.words[middle.lowerBound].speaker == "mia")
		#expect(speakers(said) == [nil, nil, "mia", nil, nil, nil])
	}

	/// A selection that spans two lines and reaches into a third by one word
	/// still means three lines. Selecting *into* a line is selecting it.
	@Test func reachingIntoALineNamesIt() {
		var said = interview()
		#expect(said.assign("mia", to: said.lines[0].lowerBound ..< said.lines[2].lowerBound + 1) == 3)
		#expect(speakers(said) == ["mia", "mia", "mia", nil, nil, nil])
	}

	/// Taking a name back off is the same operation with nobody in it, and it
	/// is not the same as saying nobody knows.
	@Test func nobodyIsAnAnswerToo() {
		var said = interview()
		for line in said.lines { said.assign("papa", to: line) }
		said.assign(nil, to: said.lines[4])
		#expect(speakers(said) == ["papa", "papa", "papa", "papa", nil, "papa"])
	}

	/// A voice nobody can name is an answer, written down like any other.
	///
	/// An unanswered line is a question still open; `unknown` is an answer —
	/// somebody off camera, a voice from the next room. The distinction is what
	/// lets the pane say what is left to label.
	@Test func unknownIsAnAnswerAndNotABlank() {
		var said = interview()
		said.assign(Speaker.unknown, to: said.lines[0])
		#expect(said.speaker(ofLine: said.lines[0]) == "unknown")
		#expect(said.speaker(ofLine: said.lines[1]) == nil)
		#expect(said.speakers == ["unknown"])
	}

	/// And it takes no colour from the palette: a colour says "this person",
	/// and the point of this one is that nobody knows who it is.
	@Test func unknownTakesNoColour() {
		let colours = Speaker.colors(for: ["mia", Speaker.unknown, "papa"])
		#expect(colours[Speaker.unknown] == nil)
		#expect(colours["mia"] != nil)
		#expect(colours["papa"] != nil)
	}

	/// A word index that is not in the take is answered rather than crashed —
	/// a click lands where it lands.
	@Test func anIndexOutsideTheTakeChangesNothing() {
		var said = interview()
		#expect(said.assign("papa", to: 99 ..< 100) == 0)
		#expect(said.speakers.isEmpty)
		var empty = Transcript()
		#expect(empty.assign("papa", to: 0 ..< 1) == 0)
	}

	/// Changing a slug reaches every word that named it, which is what makes
	/// it safe to have written it four hundred times.
	@Test func renamingReachesEveryWord() {
		var said = interview()
		for line in said.lines[0 ..< 3] { said.assign("papa", to: line) }
		for line in said.lines[3 ..< 6] { said.assign("mia", to: line) }
		#expect(said.rename("papa", to: "vater") == 6)
		#expect(said.speakers == ["vater", "mia"])
	}

	/// Who is in the sidecar, in the order they are first heard — which is what
	/// the pane offers when the take's own cast is empty.
	@Test func theSidecarSaysWhoIsInIt() {
		var said = interview()
		said.assign("papa", to: said.lines[0])
		said.assign("mia", to: said.lines[1])
		said.assign("papa", to: said.lines[2])
		#expect(said.speakers == ["papa", "mia"])
	}
}
