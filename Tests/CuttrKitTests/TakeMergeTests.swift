import Foundation
import Testing
@testable import CuttrKit

/// Two people's edits to one take, put together.
///
/// The suite is written as the situations rather than as the code: what happens
/// when two people cut different shots, when they cut the same one, when one of
/// them re-aligns the recorder. Each of those is a scenario in the spec and a
/// thing somebody will actually do.
@Suite struct TakeMergeTests {

	private func take(_ clips: [Clip], video: String? = "a.mov",
	                  audio: AudioTrack? = nil) -> Take {
		Take(video: video, audio: audio, clips: clips)
	}

	private func clip(_ slug: String, _ start: Double, _ end: Double,
	                  name: String = "", gain: Double = 0) -> Clip {
		Clip(slug: slug, name: name, start: start, end: end, gain: gain)
	}

	// MARK: - Merging without asking

	@Test func twoPeopleChangeDifferentClips() {
		let base = take([clip("intro", 0, 10), clip("wrap-up", 20, 30)])
		var mine = base
		mine.clips[0].end = 12
		var theirs = base
		theirs.clips[1].start = 22

		let merged = TakeMerge.merge(base: base, mine: mine, theirs: theirs)
		#expect(merged.isClean)
		#expect(merged.take.clips[0].end == 12)
		#expect(merged.take.clips[1].start == 22)
	}

	/// The case git's line merge gets wrong. Two clips on neighbouring lines are
	/// two different things, and adjacency is not a disagreement.
	@Test func clipsAdjacentInTheFileDoNotCollide() {
		let base = take([clip("a", 0, 1), clip("b", 1, 2), clip("c", 2, 3)])
		var mine = base
		mine.clips[1].end = 1.5
		var theirs = base
		theirs.clips[2].end = 3.5

		#expect(TakeMerge.merge(base: base, mine: mine, theirs: theirs).isClean)
	}

	@Test func oneSideAddsAClip() {
		let base = take([clip("a", 0, 1)])
		let mine = base
		var theirs = base
		theirs.clips.append(clip("b", 1, 2))

		let merged = TakeMerge.merge(base: base, mine: mine, theirs: theirs)
		#expect(merged.isClean)
		#expect(merged.take.clips.map(\.slug) == ["a", "b"])
	}

	@Test func oneSideRemovesAClip() {
		let base = take([clip("a", 0, 1), clip("b", 1, 2)])
		var mine = base
		mine.clips.removeAll { $0.slug == "b" }
		let theirs = base

		let merged = TakeMerge.merge(base: base, mine: mine, theirs: theirs)
		#expect(merged.isClean)
		#expect(merged.take.clips.map(\.slug) == ["a"])
	}

	/// Two people trimming to the same frame have not disagreed about anything.
	@Test func bothSidesMakingTheSameChangeIsNotAConflict() {
		let base = take([clip("a", 0, 1)])
		var mine = base
		mine.clips[0].end = 5
		let theirs = mine

		let merged = TakeMerge.merge(base: base, mine: mine, theirs: theirs)
		#expect(merged.isClean)
		#expect(merged.take.clips[0].end == 5)
	}

	/// The gap that made this worth checking: `gain` was missing from `Clip.==`,
	/// so a clip somebody had levelled compared equal to the one they levelled
	/// it from, and the merge could not see the edit at all.
	@Test func aLevelledClipIsAChangedClip() {
		let base = take([clip("a", 0, 1)])
		var theirs = base
		theirs.clips[0].gain = -3

		let merged = TakeMerge.merge(base: base, mine: base, theirs: theirs)
		#expect(merged.isClean)
		#expect(merged.take.clips[0].gain == -3, "the level did not come across")
	}

	// MARK: - The take's own keys

	/// One clock. The offset is the only thing relating the video and the
	/// separate recorder, so re-aligning is independent of every cut mark —
	/// and the merge has to say so rather than calling it one edit to the take.
	@Test func oneSideRealignsWhileTheOtherRecuts() {
		let base = take([clip("a", 0, 10)], audio: AudioTrack(file: "m.wav", offset: 0))
		var mine = base
		mine.clips[0].end = 12
		var theirs = base
		theirs.audio = AudioTrack(file: "m.wav", offset: 1.234)

		let merged = TakeMerge.merge(base: base, mine: mine, theirs: theirs)
		#expect(merged.isClean)
		#expect(merged.take.clips[0].end == 12)
		#expect(merged.take.audio?.offset == 1.234)
	}

	@Test func bothSidesRealigningDifferentlyIsAConflict() {
		let base = take([clip("a", 0, 10)], audio: AudioTrack(file: "m.wav", offset: 0))
		var mine = base
		mine.audio = AudioTrack(file: "m.wav", offset: 1)
		var theirs = base
		theirs.audio = AudioTrack(file: "m.wav", offset: 2)

		let merged = TakeMerge.merge(base: base, mine: mine, theirs: theirs)
		#expect(merged.conflicts.count == 1)
		#expect(merged.conflicts.first?.id == "audio")
		// Mine stands until somebody chooses.
		#expect(merged.take.audio?.offset == 1)
	}

	// MARK: - Conflicts

	@Test func bothSidesTrimmingOneClipIsAConflict() {
		let base = take([clip("intro", 0, 10, name: "Intro"), clip("b", 20, 30)])
		var mine = base
		mine.clips[0].end = 12
		var theirs = base
		theirs.clips[0].end = 14

		let merged = TakeMerge.merge(base: base, mine: mine, theirs: theirs)
		#expect(merged.conflicts.count == 1)
		#expect(merged.conflicts.first?.id == "clip:intro")
		#expect(merged.conflicts.first?.title == "Intro")
		// Until it is answered, the file keeps what the person already had.
		#expect(merged.take.clips[0].end == 12)
	}

	@Test func choosingTheirsTakesTheirVersion() {
		let base = take([clip("a", 0, 10), clip("b", 20, 30)])
		var mine = base
		mine.clips[0].end = 12
		var theirs = base
		theirs.clips[0].end = 14

		let merged = TakeMerge.merge(base: base, mine: mine, theirs: theirs)
		let resolved = TakeMerge.resolve(merged, choosing: ["clip:a": .theirs])
		#expect(resolved.clips[0].end == 14)
	}

	@Test func anUnansweredConflictKeepsMine() {
		let base = take([clip("a", 0, 10)])
		var mine = base
		mine.clips[0].end = 12
		var theirs = base
		theirs.clips[0].end = 14

		let merged = TakeMerge.merge(base: base, mine: mine, theirs: theirs)
		#expect(TakeMerge.resolve(merged, choosing: [:]).clips[0].end == 12)
	}

	/// Choosing their version must not move the clip down the file. A merge
	/// that reorders lines nobody touched is exactly the churn the hand-written
	/// emitter exists to prevent.
	@Test func resolvingDoesNotReorderTheFile() {
		let base = take([clip("a", 0, 1), clip("b", 1, 2), clip("c", 2, 3)])
		var mine = base
		mine.clips[1].end = 1.5
		var theirs = base
		theirs.clips[1].end = 1.8

		let merged = TakeMerge.merge(base: base, mine: mine, theirs: theirs)
		let resolved = TakeMerge.resolve(merged, choosing: ["clip:b": .theirs])
		#expect(resolved.clips.map(\.slug) == ["a", "b", "c"])
		#expect(resolved.clips[1].end == 1.8)
	}

	/// With nothing in common there is no way to tell an addition from a
	/// removal, and guessing is how a merge silently drops somebody's work.
	@Test func withNoBaseADifferenceIsAConflict() {
		let mine = take([clip("a", 0, 10)])
		let theirs = take([clip("a", 0, 20)])

		#expect(!TakeMerge.merge(base: nil, mine: mine, theirs: theirs).isClean)
	}

	// MARK: - What neither build understands

	@Test func aKeyOnlyTheirSideCarriesIsKept() {
		var base = take([clip("a", 0, 1)])
		base.unknownKeys = [:]
		let mine = base
		var theirs = base
		theirs.unknownKeys = ["grade-v2": "filmic"]

		let merged = TakeMerge.merge(base: base, mine: mine, theirs: theirs)
		#expect(merged.take.unknownKeys["grade-v2"] as? String == "filmic")
	}

	@Test func unknownKeysFromBothSidesSurvive() {
		let base = take([clip("a", 0, 1)])
		var mine = base
		mine.unknownKeys = ["mine-only": 1]
		var theirs = base
		theirs.unknownKeys = ["theirs-only": 2]

		let merged = TakeMerge.merge(base: base, mine: mine, theirs: theirs)
		#expect(merged.take.unknownKeys["mine-only"] != nil)
		#expect(merged.take.unknownKeys["theirs-only"] != nil)
	}

	// MARK: - The file the merge produces

	/// The merge returns a value and only `TakeWriter` writes, so a merged take
	/// is a take like any other — including the guarantee every other one has.
	@Test func aMergedTakeReSavesUnchanged() throws {
		let base = take([clip("a", 0, 10, name: "One"), clip("b", 20, 30, name: "Two")],
		                audio: AudioTrack(file: "m.wav", offset: 0.5))
		var mine = base
		mine.clips[0].end = 12
		var theirs = base
		theirs.clips[1].start = 22

		let merged = TakeMerge.merge(base: base, mine: mine, theirs: theirs)
		let once = TakeWriter.write(merged.take)
		let back = try TakeReader.read(once)
		#expect(TakeWriter.write(back) == once, "a merged take does not re-save unchanged")
	}

	/// No conflict marker can reach a file, because nothing here produces text
	/// at all — the merge hands back a `Take` and the emitter writes it.
	@Test func nothingAMergeProducesCarriesAConflictMarker() {
		let base = take([clip("a", 0, 10)])
		var mine = base
		mine.clips[0].end = 12
		var theirs = base
		theirs.clips[0].end = 14

		let merged = TakeMerge.merge(base: base, mine: mine, theirs: theirs)
		let text = TakeWriter.write(merged.take)
		#expect(!text.contains("<<<<<<<"))
		#expect(!text.contains("======="))
		#expect(!text.contains(">>>>>>>"))
	}
}
