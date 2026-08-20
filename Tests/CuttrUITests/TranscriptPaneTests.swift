import AppKit
import CuttrKit
import Testing
@testable import CuttrUI

/// The transcript pane, assembled and worked, without a window.
///
/// Nothing here dispatches a key event. A key a view does not claim falls
/// through to `NSResponder`, which beeps on the machine of whoever is running
/// the suite — so the hooks are called directly, which is where the answers are
/// anyway.
@Suite @MainActor struct TranscriptPaneTests {

	private func transcript() -> Transcript {
		Transcript(words: [
			Word(start: 1.000, end: 1.180, text: "So"),
			Word(start: 1.180, end: 1.320, text: "the"),
			Word(start: 1.320, end: 1.740, text: "driver"),
			Word(start: 1.740, end: 2.310, text: "installs"),
			Word(start: 3.000, end: 3.400, text: "itself."),
		])
	}

	private func pane() -> TranscriptPane {
		_ = NSApplication.shared
		let pane = TranscriptPane()
		pane.show(transcript(), words: Words(path: "words/a.words",
		                                     recogniser: .speechAnalyzer, locale: "de-DE"))
		pane.frame = NSRect(x: 0, y: 0, width: 400, height: 260)
		pane.layoutSubtreeIfNeeded()
		return pane
	}

	@Test func itAssemblesAndShowsTheWords() {
		let pane = self.pane()
		#expect(pane.wordCount == 5)
		_ = pane.detachedHead()
		pane.layoutSubtreeIfNeeded()
	}

	@Test func aTakeWithNoWordsSaysWhatToDoAboutIt() {
		_ = NSApplication.shared
		let pane = TranscriptPane()
		pane.show(Transcript(), words: nil)
		pane.frame = NSRect(x: 0, y: 0, width: 400, height: 260)
		pane.layoutSubtreeIfNeeded()
		#expect(pane.wordCount == 0)
		// And showing it again with words in it replaces the explanation.
		pane.show(transcript(), words: nil)
		#expect(pane.wordCount == 5)
	}

	// MARK: - Selecting words is setting in and out

	@Test func selectingWordsGivesTheSpanTheyCover() {
		let pane = self.pane()
		var span: (Double, Double)?
		pane.onSelectWords = { span = ($0, $1) }
		pane.selectWords(1 ..< 4)
		#expect(span?.0 == 1.180)
		#expect(span?.1 == 2.310)
	}

	@Test func aSelectionOfCharactersBecomesASelectionOfWords() {
		// "So the driver installs itself." — `driver` starts at character 7.
		let pane = self.pane()
		var span: (Double, Double)?
		pane.onSelectWords = { span = ($0, $1) }
		pane.selectionChanged(to: NSRange(location: 7, length: 6))
		#expect(span?.0 == 1.320)
		#expect(span?.1 == 1.740)

		// Dragged from inside one word to inside another: both ends count,
		// which is what somebody sweeping across a sentence means.
		pane.selectionChanged(to: NSRange(location: 4, length: 12))
		#expect(span?.0 == 1.180)
		#expect(span?.1 == 2.310)
	}

	@Test func aSelectionThatEndsInASpaceDoesNotSwallowTheNextWord() {
		let pane = self.pane()
		var span: (Double, Double)?
		pane.onSelectWords = { span = ($0, $1) }
		// "So the " — the trailing space belongs to nothing.
		pane.selectionChanged(to: NSRange(location: 0, length: 7))
		#expect(span?.1 == 1.320)
	}

	// MARK: - The playhead and the transcript follow each other

	@Test func clickingAWordAsksForThePlayhead() {
		let pane = self.pane()
		var went: Double?
		pane.onMoveTo = { went = $0 }
		// An empty selection is what a click on a non-editable text view is.
		pane.selectionChanged(to: NSRange(location: 8, length: 0))
		#expect(went == 1.320)
	}

	@Test func thePlayheadLightsTheWordBeingSaid() {
		let pane = self.pane()
		pane.playhead = 1.4
		#expect(pane.markedWord == 2)
		pane.playhead = 2.0
		#expect(pane.markedWord == 3)
		// Silence between the two sentences: nothing is lit, because nothing
		// is being said.
		pane.playhead = 2.6
		#expect(pane.markedWord == nil)
	}

	// MARK: - Find

	@Test func findTakesYouToThePhrase() {
		let pane = self.pane()
		var went: Double?
		var span: (Double, Double)?
		pane.onMoveTo = { went = $0 }
		pane.onSelectWords = { span = ($0, $1) }

		#expect(pane.find("the driver") == 1 ..< 3)
		#expect(went == 1.180)
		// Found *and* marked: the point of finding a sentence is usually to
		// cut it, so it arrives as an in/out span ready for ⏎.
		#expect(span?.0 == 1.180)
		#expect(span?.1 == 1.740)
	}

	@Test func findingAgainGoesToTheNextOneAndThenRoundAgain() {
		_ = NSApplication.shared
		let pane = TranscriptPane()
		pane.show(Transcript(words: [
			Word(start: 0, end: 1, text: "again"),
			Word(start: 1, end: 2, text: "and"),
			Word(start: 2, end: 3, text: "again"),
		]), words: nil)
		#expect(pane.find("again") == 0 ..< 1)
		#expect(pane.find("again") == 2 ..< 3)
		#expect(pane.find("again") == 0 ..< 1)
	}

	@Test func aPhraseThatIsNotThereSaysSo() {
		let pane = self.pane()
		var said: String?
		pane.onStatus = { said = $0 }
		#expect(pane.find("the lorry") == nil)
		#expect(said?.contains("no") == true)
	}

	@Test func findIgnoresAnEmptyField() {
		let pane = self.pane()
		var said: String?
		pane.onStatus = { said = $0 }
		#expect(pane.find("   ") == nil)
		#expect(said == nil)
	}
}

/// The transcript on disk, beside the take that names it.
///
/// The document owns both halves — the `words:` key in the take file and the
/// file it points at — and the two have to arrive together. A take naming a
/// sidecar that was never written is a take that opens with an empty pane and
/// no explanation.
@Suite @MainActor struct TranscriptSidecarTests {

	private func folder() -> URL {
		let url = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("cuttr-words-\(UUID().uuidString)")
		try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
		return url
	}

	@Test func aTranscriptIsWrittenBesideTheTakeAndReadBack() throws {
		let base = folder()
		defer { try? FileManager.default.removeItem(at: base) }
		let takeURL = base.appendingPathComponent("take-01.cuttr")

		let document = TakeDocument(take: Take(video: "a.mov"), url: takeURL)
		try document.setTranscript(
			Transcript(words: [
				Word(start: 1, end: 1.4, text: "So"),
				Word(start: 1.4, end: 2, text: "the driver"),
			]),
			recogniser: .speechAnalyzer, locale: "de-DE")
		try document.write(to: takeURL)

		// Named after the take, in a folder of its own, the way anchors are.
		let sidecar = base.appendingPathComponent("words/take-01.words")
		#expect(FileManager.default.fileExists(atPath: sidecar.path))
		#expect(try String(contentsOf: takeURL, encoding: .utf8)
			.contains("path:       words/take-01.words"))

		// And a second document, opening the same file, finds them.
		let reopened = TakeDocument()
		try reopened.read(from: takeURL)
		#expect(reopened.transcript.count == 2)
		#expect(reopened.transcript.words[1].text == "the driver")
		#expect(reopened.take.words?.recogniser == .speechAnalyzer)
		#expect(reopened.take.words?.locale == "de-DE")
	}

	@Test func savingAnUnchangedTakeRewritesNeitherFile() throws {
		// The house rule, extended to the second file: a re-save somebody did
		// not mean must not show up as a diff.
		let base = folder()
		defer { try? FileManager.default.removeItem(at: base) }
		let takeURL = base.appendingPathComponent("take-01.cuttr")
		let wordsURL = base.appendingPathComponent("words/take-01.words")

		let document = TakeDocument(take: Take(video: "a.mov"), url: takeURL)
		try document.setTranscript(
			Transcript(words: [Word(start: 1, end: 1.4, text: "So")]),
			recogniser: .speechAnalyzer, locale: "de-DE")
		try document.write(to: takeURL)
		let take = try String(contentsOf: takeURL, encoding: .utf8)
		let words = try String(contentsOf: wordsURL, encoding: .utf8)

		let reopened = TakeDocument()
		try reopened.read(from: takeURL)
		try reopened.write(to: takeURL)
		#expect(try String(contentsOf: takeURL, encoding: .utf8) == take)
		#expect(try String(contentsOf: wordsURL, encoding: .utf8) == words)
	}
}
