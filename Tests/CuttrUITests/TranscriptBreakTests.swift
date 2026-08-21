import AppKit
import Foundation
import Testing
@testable import CuttrKit
@testable import CuttrUI

/// Ending a line by hand, in the pane and in the document.
///
/// The transcript is laid out from the recording's own silences, and on the turn
/// of a conversation where nobody paused it hands back one line where there were
/// two. `B` says so, and because a line is what a speaker is assigned to and
/// what the menu plays, saying so has to leave those two where they were.
///
/// Nothing here dispatches a key event: `handleKey` and the seams under it are
/// asked directly, because an unclaimed key reaches `NSResponder` and beeps on
/// the machine running the suite.
@MainActor @Suite struct TranscriptBreakPaneTests {

	/// One line of invented German — no gap reaches half a second and nothing
	/// is punctuated, so the recogniser runs both turns together.
	private func said() -> Transcript {
		Transcript(words: [
			Word(start: 0.0, end: 0.4, text: "und"),
			Word(start: 0.4, end: 0.8, text: "dann"),
			Word(start: 0.8, end: 1.2, text: "kam"),
			Word(start: 1.2, end: 1.6, text: "der"),
			Word(start: 1.6, end: 2.0, text: "Werkzeugkasten"),
		])
	}

	private func pane(_ transcript: Transcript? = nil,
	                  cast: [Speaker] = []) -> TranscriptPane {
		_ = NSApplication.shared
		let pane = TranscriptPane(frame: NSRect(x: 0, y: 0, width: 420, height: 300))
		pane.show(transcript ?? said(),
		          words: Words(path: "w.words", recogniser: .speechAnalyzer, locale: "de-DE"),
		          cast: cast)
		return pane
	}

	// MARK: - What lands on the page

	@Test func theBreakIsOnThePageWhereItWasPutIn() {
		#expect(pane().shownText == "und dann kam der Werkzeugkasten")
		var broken = said()
		broken.addBreak(before: 2)
		// A new line and nothing else: no ellipsis, because there is no silence
		// there to select, play or cut.
		#expect(pane(broken).shownText == "und dann\nkam der Werkzeugkasten")
	}

	/// The margin says who is speaking on both halves, because the name was
	/// never a fact about the line — it is a fact about each word, and both
	/// halves keep theirs.
	@Test func bothHalvesOfABrokenLineKeepTheirNameInTheMargin() {
		var broken = said()
		broken.assign("papa", to: 0 ..< 5)
		broken.addBreak(before: 2)
		let pane = pane(broken, cast: [Speaker(slug: "papa", name: "Papa")])
		let lines = pane.shownText.components(separatedBy: "\n")
		#expect(lines.count == 2)
		#expect(lines.allSatisfy { $0.hasPrefix("Papa") })
		#expect(lines[0].hasSuffix("und dann"))
		#expect(lines[1].hasSuffix("kam der Werkzeugkasten"))
	}

	/// And a keystroke on the second half is about the second half. This is the
	/// point of the whole thing: the two people who were on one line can now be
	/// told apart.
	@Test func aNameOnTheSecondHalfIsAboutTheSecondHalfOnly() {
		var broken = said()
		broken.addBreak(before: 2)
		let pane = pane(broken, cast: [Speaker(slug: "papa", name: "Papa"),
		                               Speaker(slug: "mia", name: "Mia")])
		var asked: (Range<Int>, String?)?
		pane.onAssign = { asked = ($0, $1) }
		pane.selectForTest(word: 3)
		pane.assignFromKey(2)
		#expect(asked?.1 == "mia")
		// Widened to the whole line by the transcript, and that line is the
		// half below the break.
		broken.assign(asked?.1, to: asked?.0 ?? 0 ..< 0)
		#expect(broken.words.map(\.speaker) == [nil, nil, "mia", "mia", "mia"])
	}

	// MARK: - The key

	@Test func theKeyEndsTheLineBeforeTheWordUnderTheCaret() {
		let pane = pane()
		var asked: Int?
		pane.onBreakLine = { asked = $0 }
		pane.selectForTest(word: 2)
		pane.breakLineAtCaret()
		#expect(asked == 2)
	}

	/// And the same key takes it back out, so the way to undo it is the way it
	/// was done.
	@Test func theSameKeyTakesTheBreakBackOut() {
		var broken = said()
		broken.addBreak(before: 2)
		let pane = pane(broken)
		var asked: Int?
		pane.onBreakLine = { asked = $0 }
		// The caret on the first word of the half below the break.
		pane.selectForTest(word: 2)
		pane.breakLineAtCaret()
		#expect(asked == 2)
		// Which is what the document does with it.
		broken.removeBreak(before: 2)
		#expect(broken.lines == [0 ..< 5])
	}

	/// A line the recording ends is not somebody's to end again — and it says
	/// so rather than doing nothing, because a key that silently declines is a
	/// key somebody presses twice.
	@Test func theRecordingsOwnLineEndsAreLeftAlone() {
		let said = Transcript(words: [
			Word(start: 0.0, end: 0.4, text: "fertig"),
			Word(start: 1.4, end: 1.8, text: "weiter"),
		])
		let pane = pane(said)
		var asked: Int?
		var note = ""
		pane.onBreakLine = { asked = $0 }
		pane.onStatus = { note = $0 }
		pane.selectForTest(word: 1)
		pane.breakLineAtCaret()
		#expect(asked == nil)
		#expect(note.contains("already ends the line here"))
	}

	@Test func thereIsNoLineToEndBeforeTheFirstWord() {
		let pane = pane()
		var asked: Int?
		var note = ""
		pane.onBreakLine = { asked = $0 }
		pane.onStatus = { note = $0 }
		pane.selectForTest(word: 0)
		pane.breakLineAtCaret()
		#expect(asked == nil)
		#expect(note.contains("before the first word"))
	}

	/// The pane claims `b` only while the caret is in the words, the same as
	/// every other letter it claims — with no window there is no focus, so the
	/// key goes back to the window that would otherwise lose it.
	@Test func theKeyIsDeclinedWhenTheWordsAreNotFocused() {
		let pane = pane()
		let event = NSEvent.keyEvent(
			with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
			windowNumber: 0, context: nil, characters: "b",
			charactersIgnoringModifiers: "b", isARepeat: false, keyCode: 11)!
		// A question asked of the pane, not a key sent to a view.
		#expect(pane.handleKey(event) == false)
	}

	// MARK: - The menu

	@Test func theMenuEndsTheLineBeforeTheWordUnderThePointer() {
		let pane = pane()
		var asked: Int?
		pane.onBreakLine = { asked = $0 }
		let at = (pane.shownText as NSString).range(of: "kam").location
		let menu = pane.menuForTest(at: at)
		let item = menu?.items.first { $0.title == "End the line before this word" }
		#expect(item != nil)
		if let action = item?.action { _ = pane.perform(action) }
		#expect(asked == 2)
	}

	/// Over a break somebody put in, the same item offers the other direction.
	@Test func theMenuOffersToJoinALineSomebodyBroke() {
		var broken = said()
		broken.addBreak(before: 2)
		let pane = pane(broken)
		let at = (pane.shownText as NSString).range(of: "kam").location
		let titles = pane.menuForTest(at: at)?.items.map(\.title) ?? []
		#expect(titles.contains("Join this line to the one above"))
		#expect(titles.contains("End the line before this word") == false)
	}

	/// Not on a pause, and not on the first word of a line the recording ended:
	/// there is one boundary an item like this can be about, and neither of
	/// those is one somebody can move.
	@Test func theMenuOffersNothingWhereThereIsNoBoundaryToMove() {
		let said = Transcript(words: [
			Word(start: 0.0, end: 0.4, text: "fertig"),
			Word(start: 1.4, end: 1.8, text: "weiter"),
		])
		let pane = pane(said)
		let shown = pane.shownText as NSString
		for at in [shown.range(of: "…").location, shown.range(of: "weiter").location, 0] {
			let titles = pane.menuForTest(at: at)?.items.map(\.title) ?? []
			#expect(titles.contains { $0.hasPrefix("End the line") } == false)
			#expect(titles.contains { $0.hasPrefix("Join this line") } == false)
		}
	}
}

/// The document's side: the break is an edit like any other, it reaches the
/// sidecar, and a guess standing on the line being split still stands on both
/// halves of it.
@MainActor @Suite struct TranscriptBreakDocumentTests {

	private func document() throws -> TakeDocument {
		let words = Words(path: "words/a.words", recogniser: .speechAnalyzer, locale: "de-DE")
		let document = TakeDocument(take: Take(video: "a.mov", words: words))
		try document.setTranscript(Transcript(words: [
			Word(start: 0.0, end: 0.4, text: "und"),
			Word(start: 0.4, end: 0.8, text: "dann"),
			Word(start: 0.8, end: 1.2, text: "kam"),
			Word(start: 1.2, end: 1.6, text: "der"),
			Word(start: 1.6, end: 2.0, text: "Werkzeugkasten"),
		]), recogniser: .speechAnalyzer, locale: "de-DE")
		return document
	}

	@Test func endingALineIsAnEditLikeAnyOther() throws {
		let document = try document()
		#expect(document.isDirty == false)
		#expect(document.breakLine(before: 2))
		#expect(document.transcript.lines == [0 ..< 2, 2 ..< 5])
		#expect(document.isDirty)
		// And one press of ⌘Z takes it back, because it is a transcript like
		// any other transcript.
		document.undoManager.undo()
		#expect(document.transcript.lines == [0 ..< 5])
		#expect(document.isDirty == false)
	}

	@Test func theSameCallTakesItBackOut() throws {
		let document = try document()
		document.breakLine(before: 2)
		#expect(document.breakLine(before: 2))
		#expect(document.transcript.lines == [0 ..< 5])
		// Nothing to do where the recording already ends the line.
		#expect(document.breakLine(before: 0) == false)
	}

	/// A guess about the line being split is a guess about both halves: it was
	/// made from that line's voice, and the bottom half is part of that line.
	/// Left alone, breaking a line would silently take an offer off the page.
	@Test func anOfferOnTheLineBeingSplitStandsOnBothHalves() throws {
		let document = try document()
		document.suggest([0: "mia"])
		document.breakLine(before: 2)
		#expect(document.suggestedSpeakers == [0: "mia", 2: "mia"])
		// Both lines are offered a name, so both are lines to look at.
		#expect(document.transcript.lines.allSatisfy {
			document.suggestedSpeakers[$0.lowerBound] == "mia"
		})
	}

	/// The break reaches the file, and the file it reaches is one an older
	/// build reads as the words it always read.
	@Test func theBreakGoesToTheSidecarAndComesBack() throws {
		let folder = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("cuttr-break-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: folder) }

		let document = try document()
		document.breakLine(before: 2)
		let file = folder.appendingPathComponent("a.cuttr")
		try document.write(to: file)
		#expect(document.isDirty == false)

		let sidecar = try String(
			contentsOf: folder.appendingPathComponent("words/a.words"), encoding: .utf8)
		#expect(sidecar.contains("# line: break"))

		let reopened = TakeDocument()
		try reopened.read(from: file)
		#expect(reopened.transcript.lines == [0 ..< 2, 2 ..< 5])
		#expect(reopened.isDirty == false)
		// And saving it again writes the same bytes, which is the rule the
		// sidecar lives by.
		try reopened.write(to: file)
		#expect(try String(contentsOf: folder.appendingPathComponent("words/a.words"),
		                   encoding: .utf8) == sidecar)
	}

	/// Asking for the words again replaces every one of them, and the breaks
	/// are carried across and resolved against the new ones — which is the
	/// whole reason they are times and not word indices.
	@Test func aBreakSurvivesBeingTranscribedAgain() throws {
		let document = try document()
		document.breakLine(before: 2)
		// The same audio, heard again, with an `äh` nobody caught the first
		// time: every index has moved and the break has not.
		try document.setTranscript(Transcript(words: [
			Word(start: 0.0, end: 0.2, text: "äh"),
			Word(start: 0.2, end: 0.4, text: "und"),
			Word(start: 0.4, end: 0.8, text: "dann"),
			Word(start: 0.8, end: 1.2, text: "kam"),
			Word(start: 1.2, end: 1.6, text: "der"),
			Word(start: 1.6, end: 2.0, text: "Werkzeugkasten"),
		]), recogniser: .speechAnalyzer, locale: "de-DE")
		#expect(document.transcript.hasBreak(before: 3))
		#expect(document.transcript.lines == [0 ..< 3, 3 ..< 6])
	}
}
