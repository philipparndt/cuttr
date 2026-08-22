import AppKit
import Testing
@testable import CuttrCompose
@testable import CuttrUI

/// Clicking an overlay's bar on the preview strip selects it, and does not
/// write anything.
///
/// It used to write. `mouseUp` handed the bar's two ends to `onMoveOverlay`
/// whether or not the pointer had moved, and that is not the nothing it looks
/// like: the range is re-spelled on the way through, so selecting an overlay
/// written `within:` a clip could rewrite it as programme times, and one with
/// no range at all could be given one. A click that edits the file while
/// somebody is only trying to look at something is the worst kind of edit —
/// and until now there was no undo on a project to take it back with.
@MainActor @Suite struct StripClickTests {

	private func strip() throws -> ProgrammeStrip {
		let project = try ProjectReader.read("""
			timeline:
			  - {card: 00:10.000, fill: "#101010"}
			overlays:
			  - text: over it
			    from: 00:02.000
			    to:   00:06.000
			""")
		let strip = ProgrammeStrip(frame: NSRect(x: 0, y: 0, width: 662, height: 200))
		strip.resolved = try Resolver.resolve(
			project, baseURL: URL(fileURLWithPath: NSTemporaryDirectory()))
		strip.layoutSubtreeIfNeeded()
		// Drawing is what records where the bars are.
		strip.drawForTesting()
		return strip
	}

	@Test func aClickWritesNothing() throws {
		let strip = try strip()
		var wrote = false
		strip.onMoveOverlay = { _, _, _, _ in wrote = true }

		strip.clickFirstBarForTesting()
		#expect(!wrote, "selecting an overlay rewrote it")
	}

	/// And a drag still writes, or the fix would have taken the feature with it.
	@Test func aDragStillWrites() throws {
		let strip = try strip()
		var moved: (start: Double, end: Double)?
		strip.onMoveOverlay = { _, _, start, end in moved = (start, end) }

		strip.clickFirstBarForTesting(movingBy: 1.5)
		guard let moved else { Issue.record("a drag wrote nothing"); return }
		#expect(moved.start > 2.0, "the bar was written back where it started")
	}
}
