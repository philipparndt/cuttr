import AppKit
import Foundation
import Testing
@testable import CuttrKit
@testable import CuttrUI

/// The document's side of it: a guess is not a record until somebody says so,
/// and labelling an interview is an edit like any other.
@MainActor @Suite struct SpeakerDocumentTests {

	/// Already transcribed and already saved, so that what makes it dirty in
	/// each test below is the one thing the test is about.
	private func document() throws -> TakeDocument {
		let words = Words(path: "words/a.words", recogniser: .speechAnalyzer, locale: "de-DE")
		let document = TakeDocument(take: Take(video: "a.mov", words: words))
		try document.setTranscript(Transcript(words: [
			Word(start: 0.0, end: 0.4, text: "Wie"),
			Word(start: 0.4, end: 0.8, text: "geht's?"),
			Word(start: 0.8, end: 1.2, text: "Gut."),
			Word(start: 1.2, end: 1.6, text: "Und"),
			Word(start: 1.6, end: 2.0, text: "sonst?"),
			Word(start: 2.0, end: 2.4, text: "Auch."),
		]), recogniser: .speechAnalyzer, locale: "de-DE")
		return document
	}

	@Test func namingSomebodyMakesTheDocumentDirty() throws {
		let document = try document()
		#expect(document.isDirty == false)
		document.addSpeaker(named: "Mia")
		document.assignSpeaker("mia", from: 0)
		#expect(document.isDirty)
		#expect(document.transcript.speakers == ["mia"])
	}

	/// A carry-forward that painted forty lines the wrong colour has to be one
	/// press of ⌘Z, or nobody will risk the keystroke that makes this fast.
	@Test func theWholeCarryForwardIsOneUndo() throws {
		let document = try document()
		document.assignSpeaker("papa", from: 0)
		#expect(document.transcript.words.allSatisfy { $0.speaker == "papa" })
		document.undoManager.undo()
		#expect(document.transcript.speakers.isEmpty)
		#expect(document.isDirty == false)
	}

	/// A guess sits beside the transcript and not in it. Nothing in the file
	/// changes until somebody keeps it.
	@Test func aGuessIsNotARecord() throws {
		let document = try document()
		document.suggest([0: "papa", 2: "mia"])
		#expect(document.transcript.speakers.isEmpty)
		#expect(document.isDirty == false)

		document.acceptSuggestions()
		#expect(document.transcript.speaker(ofLine: 0 ..< 2) == "papa")
		#expect(document.transcript.speaker(ofLine: 2 ..< 3) == "mia")
		#expect(document.suggestedSpeakers.isEmpty)
		// And anybody the guess invented joins the cast, or their name would
		// have nowhere to live.
		#expect(document.take.speakers.map(\.slug).sorted() == ["mia", "papa"])
	}

	/// Answering a line by hand retires the guess about it: the pane must not
	/// go on offering an answer to a question already settled.
	@Test func confirmingALineRetiresTheGuessesItCovers() throws {
		let document = try document()
		document.suggest([0: "papa", 2: "mia", 3: "papa", 5: "mia"])
		document.assignSpeaker("oma", from: 2)
		// From line 1 on, all four lines agreed (nobody), so the run reached
		// the end and took every guess after it with it.
		#expect(document.suggestedSpeakers == [0: "papa"])
	}

	/// Renaming touches the name and not the slug, which is why it is one line
	/// of one file and not four hundred.
	@Test func renamingLeavesTheReferenceAlone() throws {
		let document = try document()
		document.addSpeaker(named: "Mia")
		document.assignSpeaker("mia", from: 0)
		document.renameSpeaker("mia", to: "Mia Walter")
		#expect(document.take.speakerTitle("mia") == "Mia Walter")
		#expect(document.transcript.speakers == ["mia"])
	}

	/// Removing somebody takes them off the words too, so nothing points at a
	/// person the take no longer has.
	@Test func removingSomebodyTakesThemOffTheWords() throws {
		let document = try document()
		document.addSpeaker(named: "Mia")
		document.assignSpeaker("mia", from: 0)
		document.removeSpeaker("mia")
		#expect(document.take.speakers.isEmpty)
		#expect(document.transcript.speakers.isEmpty)
	}

	/// The whole point of the slug: two people called Mia are two people.
	@Test func twoSpeakersNeverShareASlug() throws {
		let document = try document()
		let first = document.addSpeaker(named: "Mia")
		let second = document.addSpeaker(named: "Mia")
		#expect(first?.slug == "mia")
		#expect(second?.slug == "mia-2")
	}
}
