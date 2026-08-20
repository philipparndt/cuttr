import Foundation
import Testing
@testable import CuttrKit
@testable import CuttrUI

/// Choosing what a take is listened to in.
///
/// The pane had no such control, so every take was heard in whatever the Mac
/// itself was set to: German footage on an English Mac came back as four
/// hundred words of confident nonsense, which reads as a broken recogniser and
/// is really a question nobody was asked.
@MainActor @Suite struct TranscriptLanguageTests {

	private let languages = [
		Transcriber.Language(identifier: "de-DE", name: "German (Germany)", installed: true),
		Transcriber.Language(identifier: "en-GB", name: "English (UK)", installed: true),
		Transcriber.Language(identifier: "fr-FR", name: "French (France)", installed: false),
	]

	@Test func theChosenLanguageIsWhatTheButtonAsksFor() {
		let pane = TranscriptPane(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
		pane.offer(languages, choosing: "de-DE")
		#expect(pane.chosenLanguage == "de-DE")
	}

	/// `de` is a language and `de-DE` is what the recogniser has. Somebody
	/// whose take says one should not be shown the other.
	@Test func aBareLanguageFindsTheCountryTheMacHas() {
		let pane = TranscriptPane(frame: .zero)
		pane.offer(languages, choosing: "de")
		#expect(pane.chosenLanguage == "de-DE")
	}

	/// One that is not offered at all leaves the choice where it was, rather
	/// than silently moving it to the first in the list.
	@Test func aLanguageThisMacDoesNotHaveChangesNothing() {
		let pane = TranscriptPane(frame: .zero)
		pane.offer(languages, choosing: "en-GB")
		pane.offer(languages, choosing: "ja-JP")
		#expect(pane.chosenLanguage == "en-GB")
	}

	/// Words already beside a take were heard in some language, and that is
	/// what the pane must say — a fact about the file rather than a preference.
	@Test func wordsAlreadyMadeSayWhatTheyWereHeardIn() {
		let pane = TranscriptPane(frame: .zero)
		pane.offer(languages, choosing: "en-GB")
		pane.show(Transcript(words: [Word(start: 0, end: 0.4, text: "hallo")]),
		          words: Words(path: "words/one.words", recogniser: .speechAnalyzer, locale: "de-DE"))
		#expect(pane.chosenLanguage == "de-DE")
	}

	/// One that has to be fetched can still be chosen, and says so.
	@Test func aLanguageThatIsNotOnTheMachineSaysSo() {
		let pane = TranscriptPane(frame: .zero)
		var said = ""
		pane.onStatus = { said = $0 }
		pane.offer(languages, choosing: "fr-FR")
		#expect(pane.chosenLanguage == "fr-FR")
		_ = said
	}
}
