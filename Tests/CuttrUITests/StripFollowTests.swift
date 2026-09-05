import AppKit
import Testing
@testable import CuttrCompose
@testable import CuttrUI

/// A zoomed strip follows the playhead: when playback runs past the shown
/// stretch, the stretch pages along rather than the playhead leaving it.
///
/// Playback, and nothing else. A rebuilt preview reports nought and then where
/// it was while its item is swapped, and following *that* paged the view to
/// the top of the programme and back every time a curve point was let go of.
@MainActor @Suite struct StripFollowTests {

	private func strip() throws -> ProgrammeStrip {
		let project = try ProjectReader.read("""
			timeline:
			  - {card: 00:20.000, fill: "#101010"}
			""")
		let strip = ProgrammeStrip(frame: NSRect(x: 0, y: 0, width: 662, height: 200))
		strip.resolved = try Resolver.resolve(
			project, baseURL: URL(fileURLWithPath: NSTemporaryDirectory()))
		strip.layoutSubtreeIfNeeded()
		return strip
	}

	@Test func thePlayheadRunningOffTheRightPagesTheViewAlong() throws {
		let strip = try strip()
		// A quarter of the programme, from the start.
		strip.zoomForTesting(by: 0.25, atFraction: 0)
		let before = strip.shownForTesting
		#expect(before.end < 6)

		strip.isPlaying = true
		strip.playhead = 3
		#expect(strip.shownForTesting.start == before.start, "the view moved while the playhead was still on it")

		// Ticks of playback, a fifth of a second each, up to nine.
		for tick in stride(from: 3.2, through: 9, by: 0.2) { strip.playhead = tick }
		let after = strip.shownForTesting
		#expect(after.start <= 9 && after.end >= 9, "the playhead at 9 is off a view showing \(after)")
		#expect(abs((after.end - after.start) - (before.end - before.start)) < 1e-6, "the zoom changed")
	}

	/// A seek is not playback: a rebuilt preview's item reports nought and then
	/// where it was, and neither may move the view.
	@Test func aJumpOfThePlayheadLeavesTheViewAlone() throws {
		let strip = try strip()
		strip.zoomForTesting(by: 0.25, atFraction: 0.5)
		let before = strip.shownForTesting
		strip.isPlaying = true
		strip.playhead = 0
		strip.playhead = 0.04
		strip.playhead = 12
		#expect(strip.shownForTesting.start == before.start, "a seek paged the view: \(strip.shownForTesting)")
		// Paused, no tick follows either.
		strip.isPlaying = false
		strip.playhead = 12.2
		strip.playhead = 12.4
		#expect(strip.shownForTesting.start == before.start)
	}

	@Test func theWholeProgrammeShownNeverMoves() throws {
		let strip = try strip()
		strip.isPlaying = true
		strip.playhead = 15
		#expect(strip.shownForTesting.start == 0)
		#expect(strip.shownForTesting.end == 20)
	}

	@Test func theEndOfTheProgrammeIsAsFarAsItGoes() throws {
		let strip = try strip()
		strip.zoomForTesting(by: 0.25, atFraction: 0)
		strip.isPlaying = true
		for tick in stride(from: 0.2, through: 19.9, by: 0.2) { strip.playhead = tick }
		#expect(strip.shownForTesting.end <= 20 + 1e-9)
		#expect(strip.shownForTesting.end >= 19.9)
	}
}
