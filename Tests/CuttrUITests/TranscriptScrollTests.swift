import AppKit
import Testing
@testable import CuttrKit
@testable import CuttrUI

/// Where the reader is, across a rebuild.
@MainActor @Suite struct TranscriptScrollTests {

	/// Long enough to scroll, in lines a speaker can be assigned to.
	private func said() -> Transcript {
		var words: [Word] = []
		var t = 0.0
		for line in 0..<40 {
			for word in 0..<6 {
				words.append(Word(start: t, end: t + 0.3, text: "line\(line)word\(word)"))
				t += 0.3
			}
			t += 1.0   // a rest, so every six words is a line
		}
		return Transcript(words: words)
	}

	private func pane() -> TranscriptPane {
		let pane = TranscriptPane(frame: NSRect(x: 0, y: 0, width: 320, height: 220))
		pane.layoutSubtreeIfNeeded()
		return pane
	}

	/// Naming a speaker lays the pane out again. Somebody labelling line forty
	/// was thrown back to line one on every keystroke.
	@Test func namingASpeakerLeavesTheReaderWhereTheyWere() {
		let pane = pane()
		let transcript = said()
		pane.show(transcript, words: nil)
		pane.layoutSubtreeIfNeeded()

		pane.scrollForTesting(to: 600)
		let before = pane.scrollOffsetForTesting
		#expect(before > 400)

		// The same words, now with somebody's name on the first line — which is
		// what assigning does.
		var named = transcript
		_ = named.assign("mia", from: 0)
		pane.show(named, words: nil, cast: [Speaker(slug: "mia", name: "Mia")])
		pane.layoutSubtreeIfNeeded()

		#expect(abs(pane.scrollOffsetForTesting - before) < 20)
	}

	/// A different take has no position worth keeping.
	@Test func anotherTakeStartsAtTheTop() {
		let pane = pane()
		pane.show(said(), words: nil)
		pane.layoutSubtreeIfNeeded()
		pane.scrollForTesting(to: 600)

		pane.show(Transcript(words: [Word(start: 0, end: 1, text: "different")]), words: nil)
		pane.layoutSubtreeIfNeeded()
		#expect(pane.scrollOffsetForTesting < 20)
	}
}
