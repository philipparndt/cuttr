import AppKit
import Foundation
import Testing
@testable import CuttrCompose
@testable import CuttrKit
@testable import CuttrUI

/// The Play page's programme timeline: zooming it, and putting an overlay's
/// ends where the playhead is.
///
/// The keys went onto the wrong strip first — the small one in the properties
/// column that shows a single overlay's ranges — so nothing anybody pressed on
/// the page they were looking at did anything. This is that page.
@MainActor @Suite struct ProgrammeStripKeyTests {

	private func programme() throws -> (ProgrammeStrip, ResolvedProject) {
		let project = try ProjectReader.read("""
			timeline:
			  - {card: 00:10.000, fill: "#101010"}
			overlays:
			  - text: over it
			    from: 00:02.000
			    to:   00:06.000
			""")
		let resolved = try Resolver.resolve(
			project, baseURL: URL(fileURLWithPath: NSTemporaryDirectory()))
		let strip = ProgrammeStrip(frame: NSRect(x: 0, y: 0, width: 662, height: 200))
		strip.resolved = resolved
		// Drawing is what records where the bars are, and a key is about a bar.
		strip.layoutSubtreeIfNeeded()
		strip.drawForTesting()
		return (strip, resolved)
	}

	private func key(_ character: String) -> NSEvent {
		NSEvent.keyEvent(
			with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
			windowNumber: 0, context: nil, characters: character,
			charactersIgnoringModifiers: character, isARepeat: false, keyCode: 0)!
	}

	// MARK: - The keys

	/// `o` puts the out at the playhead, and leaves the in alone.
	@Test func oSetsTheOutAtThePlayhead() throws {
		let (strip, _) = try programme()
		var written: (Origin, Int, Double, Double)?
		strip.onMoveOverlay = { written = ($0, $1, $2, $3) }
		strip.selectFirstBarForTesting()
		strip.playhead = 4
		strip.keyDown(with: key("o"))
		#expect(written?.2 == 2)
		#expect(written?.3 == 4)
	}

	@Test func iSetsTheInAndLeavesTheOutAlone() throws {
		let (strip, _) = try programme()
		var written: (Origin, Int, Double, Double)?
		strip.onMoveOverlay = { written = ($0, $1, $2, $3) }
		strip.selectFirstBarForTesting()
		strip.playhead = 3
		strip.keyDown(with: key("i"))
		#expect(written?.2 == 3)
		#expect(written?.3 == 6)
	}

	/// Nothing selected is a sentence, not silence. A key that quietly fails
	/// reads exactly like a key that was never implemented — which is how this
	/// was reported three times.
	@Test func withNothingSelectedItSaysSo() throws {
		let (strip, _) = try programme()
		var written = false
		strip.onMoveOverlay = { _, _, _, _ in written = true }
		strip.playhead = 4
		strip.keyDown(with: key("o"))
		#expect(written == false)
		#expect(strip.noticeForTesting?.contains("click an overlay") == true)
	}

	/// An out at or before the in is refused with a reason rather than written
	/// as an inside-out range.
	@Test func anOutBeforeTheInIsRefused() throws {
		let (strip, _) = try programme()
		var written = false
		strip.onMoveOverlay = { _, _, _, _ in written = true }
		strip.selectFirstBarForTesting()
		strip.playhead = 1
		strip.keyDown(with: key("o"))
		#expect(written == false)
		#expect(strip.noticeForTesting?.contains("at or before the in") == true)
	}

	// MARK: - The zoom

	@Test func theWholeProgrammeIsShownToBeginWith() throws {
		let (strip, resolved) = try programme()
		#expect(strip.shownForTesting.start == 0)
		#expect(abs(strip.shownForTesting.end - resolved.duration) < 1e-9)
	}

	/// Zooming in shows less, and the moment under the pointer stays where it
	/// is — the whole of the interaction.
	@Test func zoomingInShowsLessAboutThePointer() throws {
		let (strip, _) = try programme()
		let before = strip.timeForTesting(atFraction: 0.5)
		strip.zoomForTesting(by: 0.5, atFraction: 0.5)
		let shown = strip.shownForTesting
		#expect(shown.end - shown.start < 10)
		#expect(abs(strip.timeForTesting(atFraction: 0.5) - before) < 0.05)
	}

	@Test func fittingShowsTheWholeThingAgain() throws {
		let (strip, resolved) = try programme()
		strip.zoomForTesting(by: 0.25, atFraction: 0.2)
		#expect(strip.shownForTesting.end - strip.shownForTesting.start < 10)
		strip.keyDown(with: key("f"))
		#expect(abs(strip.shownForTesting.end - resolved.duration) < 1e-9)
	}

	/// `Z` frames the selected overlay, which is the useful thing to zoom to.
	@Test func zFramesTheSelectedOverlay() throws {
		let (strip, _) = try programme()
		strip.selectFirstBarForTesting()
		strip.keyDown(with: key("z"))
		let shown = strip.shownForTesting
		#expect(shown.start < 2)
		#expect(shown.end > 6)
		#expect(shown.end - shown.start < 6)
	}

	/// A zoom cannot show anything that is not on the programme.
	@Test func aZoomStaysInsideTheProgramme() throws {
		let (strip, resolved) = try programme()
		for _ in 0 ..< 12 { strip.zoomForTesting(by: 0.6, atFraction: 0) }
		#expect(strip.shownForTesting.start >= 0)
		#expect(strip.shownForTesting.end <= resolved.duration + 1e-9)
		for _ in 0 ..< 12 { strip.zoomForTesting(by: 0.6, atFraction: 1) }
		#expect(strip.shownForTesting.end <= resolved.duration + 1e-9)
	}
}
