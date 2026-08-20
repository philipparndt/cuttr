import AppKit
import Testing
@testable import CuttrCompose
@testable import CuttrUI

/// What stretch of the programme the "when it is on" strip is about.
@MainActor @Suite struct SpanWindowTests {

	/// A strip told to show one entry maps its whole width to that entry, so a
	/// second in the middle of a clip is in the middle of the strip — rather
	/// than the clip being a thumbnail at one end of the programme.
	@Test func aStripAboutOneEntryMapsItsWidthToThatEntry() {
		let strip = SpanStrip(frame: NSRect(x: 0, y: 0, width: 216, height: 40))
		strip.duration = 100
		strip.showing = (start: 40, end: 60)
		// Ends of the track are the ends of the entry.
		#expect(abs(strip.timeForTesting(atFraction: 0) - 40) < 0.5)
		#expect(abs(strip.timeForTesting(atFraction: 1) - 60) < 0.5)
		#expect(abs(strip.timeForTesting(atFraction: 0.5) - 50) < 0.5)
		// And nothing outside it can be pointed at.
		#expect(strip.timeForTesting(atFraction: -1) == 40)
		#expect(strip.timeForTesting(atFraction: 2) == 60)
	}

	/// Left alone, it is the whole programme — which is what a top-level
	/// overlay is about.
	@Test func withoutAWindowItIsTheWholeProgramme() {
		let strip = SpanStrip(frame: NSRect(x: 0, y: 0, width: 216, height: 40))
		strip.duration = 100
		#expect(abs(strip.timeForTesting(atFraction: 0) - 0) < 0.5)
		#expect(abs(strip.timeForTesting(atFraction: 1) - 100) < 0.5)
	}

	/// An entry's extent is what the panel asks for, and it is the resolver
	/// that knows it.
	@Test func anEntrysExtentComesFromTheProgramme() throws {
		let project = Project(timeline: [
			TimelineEntry(source: .card(Card(duration: 4))),
			TimelineEntry(source: .card(Card(duration: 6))),
		])
		let resolved = try Resolver.resolve(project, baseURL: URL(fileURLWithPath: NSTemporaryDirectory()))
		let second = Project.extent(of: [1], in: resolved)
		#expect(second?.start == 4)
		#expect(second?.end == 10)
	}

	/// The case that was missed: a bubble written at the top level, on for three
	/// seconds of a four-second clip, was offered the whole programme to aim at
	/// — because the range was taken from where the overlay is *written* rather
	/// than from what its span is tied to.
	@Test func anOverlayInsideAClipIsAboutThatClip() throws {
		let project = Project(timeline: [
			TimelineEntry(source: .card(Card(duration: 4)), label: "first"),
			TimelineEntry(source: .card(Card(duration: 6)), label: "second"),
		])
		let resolved = try Resolver.resolve(
			project, baseURL: URL(fileURLWithPath: NSTemporaryDirectory()))
		let panel = PropertiesPanel(frame: NSRect(x: 0, y: 0, width: 380, height: 800))
		panel.resolved = resolved
		panel.reload(project, vocabulary: ComposeDocument.Vocabulary(), selection: .output)

		// `within: second, from: 1, to: 3` — written at the top level.
		let overlay = Overlay(
			kind: .text("inside", style: nil),
			span: .within(.group("second"), from: 1, to: 3))
		let bounds = panel.boundsForTesting(.project(0), overlay)
		#expect(bounds?.start == 4)
		#expect(bounds?.end == 10)
	}
}
