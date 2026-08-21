import AppKit
import CuttrKit
import Testing
@testable import CuttrCompose
@testable import CuttrUI

/// Zooming the "when it is on" strip.
///
/// The complaint this answers: on a long programme a pixel of that strip is
/// worth seconds, so a range could be dragged roughly and never placed. All of
/// it is arithmetic with a right answer — a scroll, or a key, and what stretch
/// of the programme is on screen afterwards — so none of it needs a mouse to be
/// checked.
@MainActor @Suite struct SpanZoomTests {

	private func strip() -> SpanStrip {
		let strip = SpanStrip(frame: NSRect(x: 0, y: 0, width: 216, height: 68))
		strip.duration = 100
		strip.showing = (start: 40, end: 60)
		return strip
	}

	/// The point of anchoring on the pointer: the moment under it does not
	/// move. A strip that kept its centre instead would walk the thing being
	/// aimed at off the edge in two turns of the wheel.
	@Test func zoomingKeepsTheMomentUnderThePointerWhereItIs() {
		let strip = self.strip()
		#expect(abs(strip.timeForTesting(atFraction: 0.25) - 45) < 0.01)
		strip.zoom(by: 0.5, aboutFraction: 0.25)
		#expect(abs(strip.timeForTesting(atFraction: 0.25) - 45) < 0.01)
		let shown = strip.shownForTesting
		#expect(abs((shown.end - shown.start) - 10) < 0.01)
	}

	/// `showing` stays the bounds. Zooming in at the very edge cannot show a
	/// second the overlay could not have been on anyway.
	@Test func aZoomCannotEscapeWhatTheStripIsAbout() {
		let strip = self.strip()
		for _ in 0 ..< 8 { strip.zoom(by: 0.7, aboutFraction: 0) }
		#expect(strip.shownForTesting.start >= 40)
		#expect(strip.shownForTesting.end <= 60)
		for _ in 0 ..< 8 { strip.zoom(by: 0.7, aboutFraction: 1) }
		#expect(strip.shownForTesting.start >= 40)
		#expect(strip.shownForTesting.end <= 60)
	}

	/// And zooming out lands back on the whole of it rather than on a window
	/// wider than the bounds.
	@Test func zoomingRightOutIsFittingIt() {
		let strip = self.strip()
		var reported: [(start: Double, end: Double)?] = []
		strip.onZoom = { reported.append($0) }
		strip.zoom(by: 0.25, aboutFraction: 0.5)
		strip.zoom(by: 20, aboutFraction: 0.5)
		#expect(strip.shownForTesting.start == 40)
		#expect(strip.shownForTesting.end == 60)
		#expect(reported.count == 2)
		#expect(reported.last! == nil)
	}

	/// It stops where a pixel stops being worth anything: two clocks at the
	/// ends that no longer differ are not a picture of a stretch of programme.
	@Test func zoomingInStopsBeforeTheStripStopsMeaningAnything() {
		let strip = self.strip()
		for _ in 0 ..< 40 { strip.zoom(by: 0.5, aboutFraction: 0.5) }
		let shown = strip.shownForTesting
		#expect(shown.end - shown.start >= 0.25)
		#expect(shown.end - shown.start < 0.26)
		#expect(Timecode.string(shown.start) != Timecode.string(shown.end))
	}

	/// The clocks at the ends are drawn from what is shown, so they tell the
	/// truth about a zoomed strip rather than about the whole entry.
	@Test func theClocksAtTheEndsSayWhatIsShown() {
		let strip = self.strip()
		strip.zoom(by: 0.1, aboutFraction: 0.5)
		let shown = strip.shownForTesting
		#expect(abs(shown.start - strip.timeForTesting(atFraction: 0)) < 0.001)
		#expect(abs(shown.end - strip.timeForTesting(atFraction: 1)) < 0.001)
		#expect(Timecode.string(shown.start) != Timecode.string(40))
	}

	@Test func panningSlidesTheWindowAndStopsAtTheBounds() {
		let strip = self.strip()
		strip.zoom(by: 0.25, aboutFraction: 0.5)
		let span = strip.shownForTesting.end - strip.shownForTesting.start
		strip.pan(byPoints: 40)
		#expect(strip.shownForTesting.start > 45)
		strip.pan(byPoints: 10_000)
		#expect(abs(strip.shownForTesting.end - 60) < 0.001)
		#expect(abs((strip.shownForTesting.end - strip.shownForTesting.start) - span) < 0.001)
		strip.pan(byPoints: -10_000)
		#expect(abs(strip.shownForTesting.start - 40) < 0.001)
	}

	/// A strip showing all of what it is about has nowhere to pan, and says so
	/// by doing nothing — the swipe belongs to the form it sits in.
	@Test func thereIsNothingToPanWhenTheWholeThingIsShown() {
		let strip = self.strip()
		strip.pan(byPoints: 200)
		#expect(strip.shownForTesting.start == 40)
		#expect(strip.shownForTesting.end == 60)
	}

	/// `z`: the selected range, framed with a margin.
	@Test func revealingFramesOneRange() {
		let strip = self.strip()
		strip.ranges = [SpanStrip.Range(start: 50, end: 51, movable: true)]
		strip.reveal(from: 50, to: 51)
		let shown = strip.shownForTesting
		#expect(shown.start < 50)
		#expect(shown.end > 51)
		#expect(shown.end - shown.start < 2)
	}

	/// A zoom outlives a change of what the strip is about, because the panel
	/// hands it back to a rebuilt strip. It keeps its magnification and slides
	/// inside the new bounds rather than pointing outside them.
	@Test func aZoomHandedToASmallerWindowSlidesInside() {
		let strip = self.strip()
		strip.zoom(by: 0.1, aboutFraction: 1)
		let span = strip.shownForTesting.end - strip.shownForTesting.start
		strip.showing = (start: 0, end: 5)
		let shown = strip.shownForTesting
		#expect(shown.start >= 0)
		#expect(shown.end <= 5)
		#expect(abs((shown.end - shown.start) - span) < 0.001)
	}

	/// The keys, on the view that has the keyboard. `=` and `-` by character,
	/// and by physical position as well: on a German layout `=` is Shift+0 and
	/// comes back as "0", which is how half the shortcuts in this program came
	/// to work only on a US keyboard.
	@Test func theZoomKeysWorkByCharacterAndByPosition() {
		let strip = self.strip()
		strip.ranges = [SpanStrip.Range(start: 44, end: 46, movable: true)]
		strip.keyDown(with: press("="))
		let once = strip.shownForTesting.end - strip.shownForTesting.start
		#expect(once < 20)
		// About the selected range, not about the middle of the view.
		#expect(strip.shownForTesting.start < 45)
		#expect(strip.shownForTesting.end > 45)

		strip.keyDown(with: press("0", keyCode: 24))
		#expect(strip.shownForTesting.end - strip.shownForTesting.start < once)

		strip.keyDown(with: press("f"))
		#expect(strip.shownForTesting.start == 40)
		#expect(strip.shownForTesting.end == 60)
	}
}

/// `i` and `o` on the "when it is on" strip: the two letters that mean in and
/// out in the cutting window and in the trim dialog, meaning the same thing
/// here.
///
/// Tested through the key the keyboard actually delivers — the strip is what
/// holds the focus while ranges are being placed, and the project window's
/// monitor claims only the space bar and the arrows — and asserted on the value
/// that ends up in the project, which is the only thing that matters.
@MainActor @Suite struct SpanEdgeKeyTests {

	private func find<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
		view.subviews.flatMap { subview -> [T] in
			((subview as? T).map { [$0] } ?? []) + find(type, in: subview)
		}
	}

	private func panel(_ project: Project, at playhead: Double,
	                   resolved: ResolvedProject? = nil) -> (PropertiesPanel, NSWindow, SpanStrip) {
		_ = NSApplication.shared
		let panel = PropertiesPanel()
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 800),
		                      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
		window.contentView = panel
		panel.resolved = resolved
		panel.playhead = { playhead }
		panel.reload(project, vocabulary: ComposeDocument.Vocabulary(),
		             selection: .overlay(.project(0)))
		panel.layoutSubtreeIfNeeded()
		let strip = find(SpanStrip.self, in: panel).first!
		window.makeFirstResponder(strip)
		return (panel, window, strip)
	}

	private func cards() throws -> (Project, ResolvedProject) {
		let project = Project(
			timeline: [
				TimelineEntry(source: .card(Card(duration: 4)), label: "first"),
				TimelineEntry(source: .card(Card(duration: 6)), label: "second"),
			],
			overlays: [])
		let resolved = try Resolver.resolve(
			project, baseURL: URL(fileURLWithPath: NSTemporaryDirectory()))
		return (project, resolved)
	}

	@Test func oSetsTheOutOfTheSelectedRangeFromThePlayhead() {
		var project = Project(
			timeline: [TimelineEntry(clip: ClipReference("intro"))],
			overlays: [Overlay(kind: .spinner(Spinner()), spans: [.times(from: 1, to: 4)])])
		let (panel, _, strip) = self.panel(project, at: 2.5)
		panel.onChange = { project = $0 }

		strip.keyDown(with: press("o"))
		#expect(project.overlays[0].spans == [.times(from: 1, to: 2.5)])
		#expect(strip.noticeForTesting == nil)
	}

	@Test func iSetsTheInAndLeavesTheOutAlone() {
		var project = Project(
			timeline: [TimelineEntry(clip: ClipReference("intro"))],
			overlays: [Overlay(kind: .spinner(Spinner()), spans: [.times(from: 1, to: 4)])])
		let (panel, _, strip) = self.panel(project, at: 2.5)
		panel.onChange = { project = $0 }

		strip.keyDown(with: press("i"))
		#expect(project.overlays[0].spans == [.times(from: 2.5, to: 4)])
	}

	/// The second range, when it is the one selected — not the first.
	@Test func theKeysAreAboutTheRangeTheStripHasSelected() {
		var project = Project(
			timeline: [TimelineEntry(clip: ClipReference("intro"))],
			overlays: [Overlay(kind: .spinner(Spinner()),
			                   spans: [.times(from: 0, to: 4), .times(from: 5, to: 9)])])
		let (panel, _, strip) = self.panel(project, at: 6)
		panel.onChange = { project = $0 }
		strip.onSelect?(1)
		strip.selected = 1

		strip.keyDown(with: press("i"))
		#expect(project.overlays[0].spans == [.times(from: 0, to: 4), .times(from: 6, to: 9)])
	}

	/// A range written as `within:` a shot stays written that way: the keys go
	/// through the same door a drag does, so the two numbers are still seconds
	/// into that shot and travel with it.
	@Test func aRangeInsideAShotIsStillWrittenThatWay() throws {
		var (project, resolved) = try cards()
		project.overlays = [Overlay(kind: .text("inside", style: nil),
		                            spans: [.within(.group("second"), from: 1, to: 3)])]
		let (panel, _, strip) = self.panel(project, at: 6, resolved: resolved)
		panel.onChange = { project = $0 }

		// The second card runs 4…10, so the range is on the programme's clock
		// from 5 to 7 and the playhead at 6 is two seconds into the shot.
		strip.keyDown(with: press("o"))
		#expect(project.overlays[0].spans == [.within(.group("second"), from: 1, to: 2)])
	}

	/// A range hung on a whole section is not dragged and is not typed into
	/// either — and the strip says so rather than quietly doing nothing, since a
	/// key that does nothing looks exactly like one that was never wired up.
	@Test func aRangeHungOnASectionIsRefusedAndSaysWhy() throws {
		var (project, resolved) = try cards()
		project.overlays = [Overlay(kind: .text("all of it", style: nil),
		                            spans: [.marks(from: .group("second"),
		                                           to: .group("second"))])]
		let before = project
		let (panel, _, strip) = self.panel(project, at: 6, resolved: resolved)
		panel.onChange = { project = $0 }
		#expect(strip.ranges.first?.movable == false)

		strip.keyDown(with: press("i"))
		#expect(project == before)
		#expect(strip.noticeForTesting?.contains("section") == true)
	}

	/// An in on top of its own out is a moment, not a range.
	@Test func anInPastTheOutIsRefused() {
		var project = Project(
			timeline: [TimelineEntry(clip: ClipReference("intro"))],
			overlays: [Overlay(kind: .spinner(Spinner()), spans: [.times(from: 1, to: 4)])])
		let before = project
		let (panel, _, strip) = self.panel(project, at: 9)
		panel.onChange = { project = $0 }

		strip.keyDown(with: press("i"))
		#expect(project == before)
		#expect(strip.noticeForTesting?.contains("out") == true)

		// And the other way round, at the other end.
		let (second, _, third) = self.panel(project, at: 0.5)
		second.onChange = { project = $0 }
		third.keyDown(with: press("o"))
		#expect(project == before)
		#expect(third.noticeForTesting?.contains("in") == true)
	}

	/// The playhead somewhere else on the programme entirely: the panel would
	/// otherwise clamp it into the shot and write a number nobody asked for.
	@Test func aPlayheadOffWhatTheRangeIsOverIsRefused() throws {
		var (project, resolved) = try cards()
		project.overlays = [Overlay(kind: .text("inside", style: nil),
		                            spans: [.within(.group("second"), from: 1, to: 3)])]
		let before = project
		let (panel, _, strip) = self.panel(project, at: 1, resolved: resolved)
		panel.onChange = { project = $0 }

		strip.keyDown(with: press("o"))
		#expect(project == before)
		#expect(strip.noticeForTesting?.contains("playhead") == true)
	}

	/// The form is rebuilt as soon as the project comes back, and the strip has
	/// to come back with the keyboard and with the zoom — otherwise `i` works
	/// and the `o` after it lands nowhere, and the strip somebody had zoomed in
	/// on jumps back out under them.
	@Test func theStripKeepsTheKeyboardAndTheZoomAcrossTheEdit() throws {
		var (project, resolved) = try cards()
		project.overlays = [Overlay(kind: .text("over it all", style: nil),
		                            spans: [.times(from: 1, to: 9)])]
		// The playhead moves between the two keys, as it does when somebody
		// plays up to one end and then to the other.
		var at = 2.0
		let (panel, window, strip) = self.panel(project, at: 0, resolved: resolved)
		panel.playhead = { at }
		panel.onChange = { project = $0 }
		strip.zoom(by: 0.5, aboutFraction: 0.5)
		let zoomed = strip.shownForTesting
		#expect(zoomed.end - zoomed.start < 10)

		strip.keyDown(with: press("i"))
		#expect(project.overlays[0].spans == [.times(from: 2, to: 9)])
		panel.reload(project, vocabulary: ComposeDocument.Vocabulary(),
		             selection: .overlay(.project(0)))
		panel.layoutSubtreeIfNeeded()
		let rebuilt = find(SpanStrip.self, in: panel).first
		#expect(rebuilt !== strip, "the form was not rebuilt, so this proves nothing")
		#expect(window.firstResponder === rebuilt)
		#expect(abs((rebuilt?.shownForTesting.start ?? 0) - zoomed.start) < 0.001)
		#expect(abs((rebuilt?.shownForTesting.end ?? 0) - zoomed.end) < 0.001)

		// And the second key lands, because the first did not take the focus
		// away with it.
		at = 7
		rebuilt?.keyDown(with: press("o"))
		#expect(project.overlays[0].spans == [.times(from: 2, to: 7)])
	}

	/// Nothing to write against: the panel says so rather than writing a zero.
	@Test func withoutAClockNothingIsWritten() {
		var project = Project(
			timeline: [TimelineEntry(clip: ClipReference("intro"))],
			overlays: [Overlay(kind: .spinner(Spinner()), spans: [.times(from: 1, to: 4)])])
		let before = project
		let (panel, _, strip) = self.panel(project, at: 2)
		panel.playhead = nil
		panel.onChange = { project = $0 }

		strip.keyDown(with: press("i"))
		#expect(project == before)
		#expect(strip.noticeForTesting != nil)
	}
}

/// A key press, built by hand.
///
/// Only keys the view under test claims are ever sent in: an unclaimed one
/// falls through to `NSResponder`, which has nowhere to send it and **beeps** —
/// from a test run that is a noise on somebody's machine while they are working.
@MainActor private func press(_ key: String, keyCode: UInt16 = 0) -> NSEvent {
	NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
	                 windowNumber: 0, context: nil, characters: key,
	                 charactersIgnoringModifiers: key, isARepeat: false, keyCode: keyCode)!
}
