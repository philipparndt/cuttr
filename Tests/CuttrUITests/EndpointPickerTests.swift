import AppKit
import CuttrCompose
import CuttrKit
import Testing
@testable import CuttrUI

/// What an overlay can hang on, and how it is shown.
///
/// The list a combo box offered was both ambiguous and short: `clip-4` with no
/// take on it, and no `as:` placements at all.
@Suite @MainActor struct EndpointPickerTests {

	private func vocabulary() -> ComposeDocument.Vocabulary {
		var found = ComposeDocument.Vocabulary()
		found.groups = ["questions"]
		found.labels = ["question1"]
		found.takeNames = ["mia-take-1", "mia-take-2"]
		found.items = [
			.init(take: "mia-take-1", slug: "clip-4", name: "The answer", tags: [],
			      length: 4, reference: "mia-take-1/clip-4"),
			.init(take: "mia-take-2", slug: "clip-4", name: "Again", tags: [],
			      length: 5, reference: "mia-take-2/clip-4"),
			.init(take: "mia-take-1", slug: "intro", name: "Intro", tags: [],
			      length: 3, reference: "intro"),
		]
		return found
	}

	@Test func everyKindOfNameIsOffered() {
		let catalogue = EndpointCatalogue(vocabulary())
		#expect(catalogue.entries.contains { $0.kind == .section && $0.reference == "@questions" })
		#expect(catalogue.entries.contains { $0.kind == .placement && $0.reference == "@question1" })
		#expect(catalogue.entries.filter { $0.kind == .clip }.count == 3)
	}

	/// The file writes the short form; the panel shows the long one.
	@Test func aBareSlugIsShownWithItsTake() {
		let catalogue = EndpointCatalogue(vocabulary())
		#expect(catalogue.path(for: .clip(ClipReference("intro"))) == "mia-take-1/intro")
		#expect(catalogue.path(for: .clip(ClipReference("mia-take-2/clip-4"))) == "mia-take-2/clip-4")
		#expect(catalogue.path(for: .group("question1")) == "@question1")
		// A slug that is not there is shown as the file has it, not invented.
		#expect(catalogue.path(for: .clip(ClipReference("gone"))) == "gone")
		#expect(catalogue.knows(.clip(ClipReference("gone"))) == false)
		// Either spelling of a clip that is there is a clip that is there: a
		// project may write the take on the front whether or not it has to.
		#expect(catalogue.knows(.clip(ClipReference("mia-take-1/intro"))))
		#expect(catalogue.knows(.clip(ClipReference("intro"))))
		#expect(catalogue.knows(.clip(ClipReference("mia-take-2/clip-4"))))
		#expect(catalogue.knows(.group("question1")))
	}

	@Test func searchingMatchesWordByWord() {
		let catalogue = EndpointCatalogue(vocabulary())
		#expect(catalogue.matching("mia 4").count == 2)
		#expect(catalogue.matching("take-1/clip").map(\.path) == ["mia-take-1/clip-4"])
		#expect(catalogue.matching("answer").map(\.path) == ["mia-take-1/clip-4"])
		#expect(catalogue.matching("").count == catalogue.entries.count)
	}

	/// The dialog opens on what the overlay already hangs on, headings and all.
	@Test func itOpensOnWhatIsSetAndGroupsByTake() {
		_ = NSApplication.shared
		var chosen: String?
		let picker = EndpointPicker(catalogue: EndpointCatalogue(vocabulary()),
		                            current: "mia-take-2/clip-4") { chosen = $0 }
		picker.loadView()
		#expect(picker.chosen?.reference == "mia-take-2/clip-4")
		#expect(picker.chosen?.path == "mia-take-2/clip-4")

		// A placement named with `as:` is reachable, which it was not before.
		picker.searchField.stringValue = "question1"
		picker.rebuild()
		#expect(picker.chosen?.reference == "@question1")
		picker.confirm()
		#expect(chosen == "@question1")
	}
}

/// Where the ends of a placement are decided.
@Suite @MainActor struct TrimDialogTests {

	private func dialog(length: Double = 5, trim: (Double, Double) = (0, 0),
	                    onDone: @escaping ((Double, Double)) -> Void = { _ in }) -> TrimDialog {
		_ = NSApplication.shared
		// No media: what is under test is the arithmetic of the two ends, and
		// the player is the cutting window's, tested where it lives.
		let made = TrimDialog(clip: "mia-take-1/clip-4", video: nil, audio: nil, audioOffset: 0,
		                      span: (start: 10, end: 10 + length), trim: trim,
		                      step: 1.0 / 25, onDone: onDone)
		made.loadView()
		return made
	}

	@Test func aFrameAtATime() {
		let dialog = self.dialog(trim: (0.5, 0))
		dialog.stepHead(by: 1)
		#expect(abs(dialog.chosen.head - 0.54) < 0.001)
		dialog.stepHead(by: -1)
		dialog.stepHead(by: -1)
		#expect(abs(dialog.chosen.head - 0.46) < 0.001)
	}

	/// Neither end may eat the other, however hard it is pushed.
	@Test func theEndsCannotCross() {
		let dialog = self.dialog(length: 2, trim: (1.5, 0.4))
		dialog.set(head: 5, tail: 0.4)
		#expect(dialog.chosen.head + dialog.chosen.tail <= 1.951)
		#expect(dialog.chosen.tail == 0.4)
		dialog.set(head: 0, tail: -3)
		#expect(dialog.chosen.tail == 0)
	}

	/// The mark goes where the picture is, both ends, and both ends come back.
	@Test func theMarksFollowThePlayheadAndReset() {
		let dialog = self.dialog(length: 8, trim: (0, 0))
		dialog.at = 2.5
		dialog.headHere()
		#expect(abs(dialog.chosen.head - 2.5) < 0.001)
		dialog.at = 6
		dialog.tailHere()
		#expect(abs(dialog.chosen.tail - 2) < 0.001)
		dialog.resetTrim()
		#expect(dialog.chosen.head == 0)
		#expect(dialog.chosen.tail == 0)
	}

	/// Nothing is written until Done, so a search for the right frame is one
	/// change to the project rather than forty.
	@Test func itWritesOnceAtTheEnd() {
		var written: [(Double, Double)] = []
		let dialog = self.dialog(trim: (0, 0)) { written.append($0) }
		dialog.set(head: 0.2, tail: 0)
		dialog.set(head: 0.4, tail: 0.1)
		#expect(written.isEmpty)
		dialog.done()
		#expect(written.count == 1)
		#expect(abs(written[0].0 - 0.4) < 0.001)
		#expect(abs(written[0].1 - 0.1) < 0.001)
	}
}

/// The band under the picture: what it keeps, and what a drag on it does.
@Suite @MainActor struct TrimTimelineTests {

	@Test func aHandleDragMovesOneEndOnly() {
		_ = NSApplication.shared
		let timeline = TrimTimeline(frame: NSRect(x: 0, y: 0, width: 216, height: 56))
		timeline.length = 10
		timeline.trim = (0, 0)
		var reported: [(Double, Double, Bool)] = []
		timeline.onTrim = { reported.append(($0, $1, $2)) }

		// The band is inset by 8 either side, so 200 points is ten seconds.
		func drag(from: CGFloat, to: CGFloat) {
			timeline.mouseDown(with: click(at: from))
			timeline.mouseDragged(with: click(at: to))
			timeline.mouseUp(with: click(at: to))
		}
		drag(from: 8, to: 48)
		#expect(abs(timeline.trim.head - 2) < 0.05)
		#expect(timeline.trim.tail == 0)
		// Live during the drag, and once more when it is let go.
		#expect(reported.last?.2 == true)

		drag(from: 208, to: 168)
		#expect(abs(timeline.trim.tail - 2) < 0.05)
		#expect(abs(timeline.trim.head - 2) < 0.05)
	}

	/// A click anywhere else is a scrub, not a trim.
	@Test func clickingTheMiddleScrubs() {
		_ = NSApplication.shared
		let timeline = TrimTimeline(frame: NSRect(x: 0, y: 0, width: 216, height: 56))
		timeline.length = 10
		var scrubbed: Double?
		timeline.onScrub = { scrubbed = $0 }
		timeline.onTrim = { _, _, _ in Issue.record("a click in the middle trimmed") }
		timeline.mouseDown(with: click(at: 108))
		timeline.mouseUp(with: click(at: 108))
		#expect(abs((scrubbed ?? 0) - 5) < 0.05)
	}

	private func click(at x: CGFloat) -> NSEvent {
		NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: x, y: 30),
		                   modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
		                   eventNumber: 0, clickCount: 1, pressure: 1)!
	}
}

/// The keyboard, in the dialog that has a text field in it.
///
/// A sheet hands its keyboard to the first text field it can find, and a field
/// editor eats every key: space typed a space and `i` typed an `i`. What holds
/// the keyboard is the timeline.
@Suite @MainActor struct TrimKeysTests {

	@Test func theTimelineTakesTheKeys() {
		_ = NSApplication.shared
		let timeline = TrimTimeline(frame: NSRect(x: 0, y: 0, width: 216, height: 56))
		#expect(timeline.acceptsFirstResponder)
		var pressed: [String] = []
		timeline.onKey = { pressed.append($0); return $0 != "x" }
		for key in [" ", "i", "o", "x"] { timeline.keyDown(with: press(key)) }
		#expect(pressed == [" ", "i", "o", "x"])
	}

	/// And the dialog does something with each of them.
	@Test func spaceAndTheMarksAreWired() {
		_ = NSApplication.shared
		var written: [(Double, Double)] = []
		let dialog = TrimDialog(clip: "clip-4", video: nil, audio: nil, audioOffset: 0,
		                        span: (start: 0, end: 8), trim: (0, 0), step: 1.0 / 25,
		                        onDone: { written.append($0) })
		dialog.loadView()
		dialog.at = 2
		dialog.keyed("i")
		dialog.at = 6
		dialog.keyed("o")
		#expect(abs(dialog.chosen.head - 2) < 0.001)
		#expect(abs(dialog.chosen.tail - 2) < 0.001)
		#expect(dialog.keyed(" "))
		#expect(dialog.keyed("q") == false)
		#expect(written.isEmpty)
	}

	private func press(_ key: String) -> NSEvent {
		NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
		                 windowNumber: 0, context: nil, characters: key,
		                 charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0)!
	}
}
