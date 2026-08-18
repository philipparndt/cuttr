import Testing
@testable import CuttrKit

/// The program's central verb.
///
/// These exist because of a bug report: "when creating a clip mark, the focus
/// is lost, so the next mark cannot be created." That one was in the window —
/// marking opened a rename field that swallowed the next keystroke — but the
/// report is impossible to tell apart from a marking rule that only works once,
/// and a verb this important should not rest on a screenshot.
@Suite struct MarkTests {

	@Test func aRunOfMarksMakesARunOfClips() {
		var take = Take(video: "a.mov")
		for time in [3.0, 7.5, 11.25] {
			#expect(take.mark(at: time) != nil, "at \(time)")
		}
		#expect(take.clips.map(\.slug) == ["clip-1", "clip-2", "clip-3"])
		// Contiguous: each one closes off everything since the last, which is
		// the whole point of the key.
		#expect(take.clips.map(\.start) == [0, 3.0, 7.5])
		#expect(take.clips.map(\.end) == [3.0, 7.5, 11.25])
	}

	@Test func markingTwiceInTheSamePlaceIsRefused() {
		var take = Take(video: "a.mov")
		#expect(take.mark(at: 3) != nil)
		// Not an empty clip, and not a duplicate: nothing at all.
		#expect(take.mark(at: 3) == nil)
		#expect(take.clips.count == 1)
	}

	@Test func markingInsideAClipSplitsIt() {
		var take = Take(video: "a.mov", clips: [
			Clip(slug: "intro", name: "Intro", start: 0, end: 10, color: .rose),
		])
		// On the clip's own lane. A mark in another colour would make a new
		// clip overlapping this one instead, which is what lanes are for.
		let tail = take.mark(at: 4, color: .rose)
		#expect(tail != nil)
		#expect(take.clips.count == 2)
		#expect(take.clips[0].end == 4)
		#expect(take.clips[1].start == 4)
		#expect(take.clips[1].end == 10)
		// Two halves of one clip are two of the same thing.
		#expect(take.clips[1].name == "Intro")
		#expect(take.clips[1].color == .rose)
		#expect(take.clips.map(\.slug) == ["intro", "intro-2"])
	}

	@Test func splittingOnAClipsOwnEdgeDoesNothing() {
		var take = Take(video: "a.mov", clips: [Clip(slug: "a", start: 0, end: 10)])
		#expect(take.mark(at: 0.001, color: .green) == nil)
		#expect(take.mark(at: 9.999, color: .green) == nil)
		#expect(take.clips.count == 1)
	}

	@Test func aMarkAfterAGapStartsAtTheLastClipsEnd() {
		var take = Take(video: "a.mov", clips: [Clip(slug: "a", start: 0, end: 5)])
		// The playhead is well past the clip; the new one begins where that one
		// left off, not where the playhead was when it was made.
		let clip = take.mark(at: 20)
		#expect(clip?.start == 5)
		#expect(clip?.end == 20)
	}

	@Test func newClipsTakeTheChosenColour() {
		var take = Take(video: "a.mov")
		take.mark(at: 3, color: .violet)
		take.mark(at: 6, color: .violet)
		#expect(take.clips.allSatisfy { $0.color == .violet })
	}

	@Test func slugsStayUniqueAcrossMarksAndSplits() {
		var take = Take(video: "a.mov")
		for time in stride(from: 2.0, through: 20.0, by: 2.0) { take.mark(at: time) }
		take.mark(at: 3)    // splits clip-2
		take.mark(at: 7)    // splits another
		#expect(Set(take.clips.map(\.slug)).count == take.clips.count)
	}
}

/// Colour is which line of clips is being cut, so two colours can cover the
/// same seconds. This is what makes overlapping clips possible at all.
@Suite struct LaneTests {

	@Test func eachColourIsItsOwnRunOfClips() {
		var take = Take(video: "a.mov")
		take.mark(at: 5, color: .green)
		take.mark(at: 10, color: .green)
		// A rose mark ignores the green clips entirely and starts from the top
		// of the take, so it overlaps both of them.
		let rose = take.mark(at: 8, color: .rose)
		#expect(rose?.start == 0)
		#expect(rose?.end == 8)
		#expect(take.clips.count == 3)
	}

	@Test func markingOnALaneDoesNotSplitAnotherLanesClip() {
		var take = Take(video: "a.mov", clips: [
			Clip(slug: "wide", start: 0, end: 20, color: .green),
		])
		let made = take.mark(at: 10, color: .rose)
		// The green clip is untouched: a rose mark cannot split it.
		#expect(take.clips[0].end == 20)
		#expect(made?.color == .rose)
		#expect(made?.start == 0)
		#expect(made?.end == 10)
	}

	@Test func markingOnTheSameLaneStillSplits() {
		var take = Take(video: "a.mov", clips: [
			Clip(slug: "wide", start: 0, end: 20, color: .green),
		])
		#expect(take.mark(at: 10, color: .green) != nil)
		#expect(take.clips.count == 2)
		#expect(take.clips[0].end == 10)
	}

	@Test func lanesAreTheColoursInUse() {
		var take = Take(video: "a.mov")
		#expect(take.lanes.isEmpty)
		take.mark(at: 5, color: .rose)
		take.mark(at: 5, color: .blue)
		// Palette order, not the order they were cut in, so a lane does not
		// move under somebody when they add a clip.
		#expect(take.lanes == [.blue, .rose])
		// Recolouring the only blue clip retires that lane.
		take.setColor(.rose, for: take.clips.first { $0.color == .blue }!.id)
		#expect(take.lanes == [.rose])
	}
}
