import Foundation
import Testing
@testable import CuttrKit

/// The arithmetic that turns a run of words into a cut.
///
/// Almost all of it is on maps built by hand rather than on decoded audio,
/// because the question here is not "did the detector find the speech" — that
/// is ``SpeechEdgeTests`` — but "given that it did, where do the marks go".
/// A hand-made map says exactly where the talking is, so an expectation can be
/// a number rather than a tolerance.
@Suite struct SpeechMapTests {

	/// Talking from 1 to 3 and again from 3.8 to 6, in a ten-second recording.
	private var twoSentences: SpeechMap {
		SpeechMap(runs: [1.0 ... 3.0, 3.8 ... 6.0], bounds: 0 ... 10)
	}

	/// The same, with only three tenths of a second between them — the shortest
	/// gap ``SpeechEdges/restingFor`` will call a stop at all is a quarter of a
	/// second, so this is about as tight as two runs ever get.
	private var closeSentences: SpeechMap {
		SpeechMap(runs: [1.0 ... 3.0, 3.3 ... 5.0], bounds: 0 ... 10)
	}

	// MARK: - Reading the shape

	/// A recording with `bursts` of sound in a quiet room, at 1 ms buckets.
	private func made(_ bursts: [(start: Double, end: Double)], duration: Double = 10) -> Waveform {
		let count = Int(duration * 1000)
		var peaks = [Float](repeating: 0.001, count: count)
		for burst in bursts {
			for bucket in Int(burst.start * 1000) ..< Int(burst.end * 1000)
			where bucket >= 0 && bucket < count {
				peaks[bucket] = 0.3
			}
		}
		return Waveform(bucketsPerSecond: 1000, duration: duration, sampleRate: 48000,
		                mins: peaks.map { -$0 }, maxs: peaks)
	}

	@Test func theEdgesPairUpIntoRuns() {
		let map = SpeechMap.of(made([(2.0, 3.0), (5.0, 6.0)]))
		#expect(map.runs.count == 2)
		#expect(abs(map.runs[0].lowerBound - 2.0) < 0.03)
		#expect(abs(map.runs[1].upperBound - 6.0) < 0.03)
		// And back out again in the shape the timeline snaps to, unchanged.
		#expect(map.edges == SpeechEdges.edges(in: made([(2.0, 3.0), (5.0, 6.0)])))
	}

	/// The lead-in and the run-out are stretches of quiet like any other. A
	/// clip at the very top of a take has air available to it, and a listing
	/// that began at the first word would not say so.
	@Test func theQuietIsWhatTheRunsLeaveOver() {
		let quiet = twoSentences.quiet
		#expect(quiet.count == 3)
		#expect(quiet[0] == 0 ... 1.0)
		#expect(quiet[1] == 3.0 ... 3.8)
		#expect(quiet[2] == 6.0 ... 10)
	}

	@Test func aRecordingWithNoTalkingInItIsAllQuiet() {
		let map = SpeechMap(runs: [], bounds: 0 ... 10)
		#expect(map.quiet == [0 ... 10])
		#expect(map.isEmpty)
	}

	@Test func aMarkInTheMiddleOfASentenceIsInNoQuietAtAll() {
		#expect(twoSentences.quiet(at: 2.0) == 2.0 ... 2.0)
		#expect(twoSentences.isSpeaking(at: 2.0))
		// Measured from the nearer end, so it says how much would be missing.
		#expect(abs(twoSentences.depthIntoSpeech(at: 2.2) - 0.8) < 1e-9)
		#expect(abs(twoSentences.depthIntoSpeech(at: 2.9) - 0.1) < 1e-9)
	}

	/// A mark exactly on an edge is in the quiet, not in the speech. It is the
	/// case that matters: a refined mark lands there, and being in the quiet is
	/// the reason it has air to take.
	@Test func aMarkOnAnEdgeIsInTheQuiet() {
		#expect(!twoSentences.isSpeaking(at: 3.0))
		#expect(twoSentences.quiet(at: 3.0) == 3.0 ... 3.8)
		#expect(abs(twoSentences.quiet(after: 3.0) - 0.8) < 1e-9)
		#expect(abs(twoSentences.quiet(before: 3.8) - 0.8) < 1e-9)
	}

	// MARK: - Refinement

	/// The complaint the whole thing starts from: a word time is not the moment
	/// the sound began. Here it is 60 ms late, and the mark comes back on the
	/// sound.
	@Test func theInMarkGoesToWhereTheSoundStarts() {
		let cut = twoSentences.cut(from: 1.06, to: 2.94)
		#expect(cut.refined.lowerBound == 1.0)
		#expect(abs(cut.startMoved + 0.06) < 1e-9)
	}

	/// And the out mark to the end of the decay, which is a hair past where the
	/// last word was said to stop.
	@Test func theOutMarkGoesToWhereTheSoundStops() {
		let cut = twoSentences.cut(from: 1.0, to: 2.9)
		#expect(cut.refined.upperBound == 3.0)
		#expect(abs(cut.endMoved - 0.1) < 1e-9)
	}

	/// Starts for one end and stops for the other, never both. An in mark sat
	/// beside the *end* of a run must not be dragged onto it — that would open
	/// the clip after the sentence it was cut from.
	@Test func aMarkIsNeverPulledOntoTheWrongKindOfEdge() {
		// 2.95 is 50 ms from the run's end at 3.0 and nowhere near a start.
		let cut = twoSentences.cut(from: 2.95, to: 5.0)
		#expect(cut.refined.lowerBound == 2.95)
	}

	/// Deep inside a sentence there is no moment the sound started, so the mark
	/// stays where the recogniser put it. Nothing is invented.
	@Test func aMarkInTheMiddleOfASentenceIsLeftAlone() {
		let cut = twoSentences.cut(from: 2.0, to: 2.5)
		#expect(cut.refined == 2.0 ... 2.5)
		#expect(cut.startMoved == 0)
		#expect(cut.endMoved == 0)
	}

	/// The guarantee: it can never take in a word nobody selected.
	///
	/// The second word of a run, with the first only 150 ms long — inside the
	/// reach. Told where the previous word ended, the mark cannot go back past
	/// it, so `Ja` stays out of the clip.
	@Test func refinementNeverCrossesIntoTheWordBefore() {
		let map = SpeechMap(runs: [1.0 ... 3.0], bounds: 0 ... 10)
		let free = map.cut(from: 1.15, to: 2.0)
		#expect(free.refined.lowerBound == 1.0)   // it would, given the room
		let bounded = map.cut(from: 1.15, to: 2.0, after: 1.15)
		#expect(bounded.refined.lowerBound == 1.15)
	}

	@Test func refinementNeverCrossesIntoTheWordAfter() {
		let map = SpeechMap(runs: [1.0 ... 3.0], bounds: 0 ... 10)
		#expect(map.cut(from: 1.0, to: 2.9).refined.upperBound == 3.0)
		#expect(map.cut(from: 1.0, to: 2.9, before: 2.9).refined.upperBound == 2.9)
	}

	/// And it cannot reach further than ``SpeechMap/reach`` even with all the
	/// room in the world: a mark half a second out is a mark about a different
	/// sound, and moving it there would be guessing.
	@Test func refinementReachesOnlySoFar() {
		let cut = twoSentences.cut(from: 0.4, to: 2.0)
		#expect(cut.refined.lowerBound == 0.4)
	}

	// MARK: - Handles

	/// The default, where the pause is long enough for both neighbours to have
	/// all of it.
	@Test func aMarkTakesAirUpToTheHandle() {
		let cut = twoSentences.cut(from: 1.0, to: 3.0)
		#expect(abs(cut.startHandle - SpeechMap.handle) < 1e-9)
		#expect(abs(cut.endHandle - SpeechMap.handle) < 1e-9)
		#expect(abs(cut.span.lowerBound - 0.75) < 1e-9)
		#expect(abs(cut.span.upperBound - 3.25) < 1e-9)
		// And it says how much there was, which is not the same as how much it
		// took: a full handle out of a wide pause and a full handle out of a
		// pause that had exactly that much are different situations.
		#expect(cut.quietBefore == 1.0)
		#expect(abs(cut.quietAfter - 0.8) < 1e-9)
	}

	/// A short pause is split down the middle rather than given away to
	/// whichever clip was made first.
	@Test func aShortPauseIsSplitDownTheMiddle() {
		let cut = closeSentences.cut(from: 1.0, to: 3.0)
		#expect(abs(cut.endHandle - 0.15) < 1e-9)
		#expect(abs(cut.span.upperBound - 3.15) < 1e-9)
	}

	/// The one that decides whether any of this can be trusted: two clips cut
	/// from either side of one gap, neither knowing the other exists, must meet
	/// and must not overlap.
	///
	/// Run with refinement turned off — `reach` of nothing — because that is
	/// the hard case. Refinement normally puts both marks exactly on the run
	/// boundaries, where halving the gap plainly works; the guarantee has to
	/// hold when it does not, and the midpoint is what buys that. The slack
	/// goes as far as the middle of the gap in both directions, which is as
	/// wrong as a word time can be while still being a word time.
	@Test func twoClipsEitherSideOfOneGapMeetAndNeverOverlap() {
		let map = closeSentences   // 3.0 to 3.3 between them, so the middle is 3.15
		for slack in stride(from: 0.0, through: 0.15, by: 0.005) {
			let first = map.cut(from: 1.0, to: 3.0 + slack, reach: 0)
			let second = map.cut(from: 3.3 - slack, to: 5.0, reach: 0)
			#expect(abs(first.span.upperBound - second.span.lowerBound) < 1e-9,
			        "\(first.span.upperBound) against \(second.span.lowerBound) at slack \(slack)")
			#expect(abs(first.span.upperBound - 3.15) < 1e-9)
		}
	}

	/// The wider gap, where both clips get the whole handle and there is still
	/// air left between them. Nothing meets; nothing overlaps either.
	@Test func aWideGapGivesBothClipsTheWholeHandle() {
		let first = twoSentences.cut(from: 1.0, to: 3.0)
		let second = twoSentences.cut(from: 3.8, to: 6.0)
		#expect(abs(first.endHandle - SpeechMap.handle) < 1e-9)
		#expect(abs(second.startHandle - SpeechMap.handle) < 1e-9)
		#expect(first.span.upperBound < second.span.lowerBound)
	}

	/// And the part that holds whatever the marks were: a mark only ever moves
	/// inside the pause it was already in, so anything two clips share is
	/// silence. No word can end up in two of them.
	///
	/// Two marks both sitting in the same half of one pause is the case the
	/// midpoint rule cannot separate — and no rule of this shape could, since
	/// the earlier clip has no way of knowing the later one is there. What it
	/// can promise is that the overlap is quiet, and it does.
	@Test func anythingTwoClipsShareIsSilence() {
		let map = SpeechMap(runs: [1.0 ... 3.0, 4.0 ... 6.0], bounds: 0 ... 10)
		let first = map.cut(from: 1.0, to: 3.05, reach: 0)
		let second = map.cut(from: 3.10, to: 6.0, reach: 0)
		#expect(first.span.upperBound > second.span.lowerBound)   // they do overlap
		let shared = second.span.lowerBound ... first.span.upperBound
		#expect(map.quiet.contains { $0.lowerBound <= shared.lowerBound
			&& $0.upperBound >= shared.upperBound })
	}

	/// Somebody talking straight through. There is no air, so there is no
	/// handle, and nothing is taken out of the middle of a sentence to make up
	/// the difference. The clip is what was asked for.
	@Test func withNoSilenceThereIsNoHandle() {
		let solid = SpeechMap(runs: [1.0 ... 10.0], bounds: 0 ... 10)
		let cut = solid.cut(from: 3.0, to: 5.0)
		#expect(cut.span == 3.0 ... 5.0)
		#expect(cut.startHandle == 0)
		#expect(cut.endHandle == 0)
		#expect(cut.quietBefore == 0)
		#expect(cut.quietAfter == 0)
	}

	/// And two clips cut back to back out of it still cannot overlap, because
	/// neither of them moved at all.
	@Test func twoClipsInOneUnbrokenSentenceStillDoNotOverlap() {
		let solid = SpeechMap(runs: [1.0 ... 10.0], bounds: 0 ... 10)
		let first = solid.cut(from: 2.0, to: 4.0)
		let second = solid.cut(from: 4.0, to: 6.0)
		#expect(first.span.upperBound == second.span.lowerBound)
	}

	@Test func askingForNoHandleGivesAHardCutOnTheRefinedMarks() {
		let cut = twoSentences.cut(from: 1.06, to: 2.94, handle: 0)
		#expect(cut.span == cut.refined)
		#expect(cut.span == 1.0 ... 3.0)
	}

	/// The lead-in is air like any other, so a clip on the first sentence of a
	/// take is not jammed against the head of the file.
	@Test func theLeadInIsAvailableAsAir() {
		let cut = twoSentences.cut(from: 1.0, to: 3.0)
		#expect(abs(cut.span.lowerBound - 0.75) < 1e-9)
		// And a take whose first sound is right at the top has nothing to give.
		let tight = SpeechMap(runs: [0 ... 3.0], bounds: 0 ... 10)
		#expect(tight.cut(from: 0, to: 3.0).span.lowerBound == 0)
	}

	/// A start mark that has already fallen into the *previous* clip's half of
	/// the pause takes no air at all. It is standing in somebody else's room,
	/// and the handle only ever adds air within the half a clip owns.
	///
	/// The other way round it is capped rather than refused: a start mark past
	/// the middle backs off as far as the middle and stops there.
	@Test func aMarkInTheOtherHalfOfAPauseTakesNoAir() {
		let early = closeSentences.cut(from: 3.05, to: 5.0, reach: 0)   // the middle is 3.15
		#expect(abs(early.span.lowerBound - 3.05) < 1e-9)
		#expect(early.startHandle == 0)

		let late = closeSentences.cut(from: 3.25, to: 5.0, reach: 0)
		#expect(abs(late.span.lowerBound - 3.15) < 1e-9)
	}

	/// Nothing measured means nothing changed: while the audio is still being
	/// decoded, a clip is what it always was.
	@Test func withNoSpeechFoundTheSpanIsUntouched() {
		let map = SpeechMap(runs: [], bounds: 0 ... 10)
		let cut = map.cut(from: 1.0, to: 2.0)
		#expect(cut.span == 1.0 ... 2.0)
		#expect(cut.refined == 1.0 ... 2.0)
	}

	/// One clock. The recorder rolled eleven seconds before the camera, and
	/// every number that comes out of here is on the camera's.
	@Test func everythingIsOnTheClockThatWasAskedFor() {
		let plain = SpeechMap.of(made([(2.0, 3.0)]))
		let shifted = SpeechMap.of(made([(2.0, 3.0)]), shift: -11.093)
		#expect(abs(shifted.bounds.lowerBound + 11.093) < 1e-9)
		#expect(zip(plain.edges, shifted.edges).allSatisfy { abs($0 - $1 - 11.093) < 1e-9 })
		let here = plain.cut(from: 2.0, to: 3.0)
		let there = shifted.cut(from: 2.0 - 11.093, to: 3.0 - 11.093)
		#expect(abs(here.span.lowerBound - 11.093 - there.span.lowerBound) < 1e-9)
	}

	/// A span given the wrong way round is still a span.
	@Test func aBackwardsSpanIsTakenAsWritten() {
		#expect(twoSentences.cut(from: 3.0, to: 1.0).asked == 1.0 ... 3.0)
	}

	// MARK: - What the transcript contributes

	@Test func theTranscriptSaysWhatAMarkMayNotCross() {
		let said = Transcript(words: [
			Word(start: 1.0, end: 1.15, text: "Ja"),
			Word(start: 1.15, end: 1.60, text: "genau"),
			Word(start: 2.40, end: 2.90, text: "wirklich"),
		])
		let room = said.neighbours(of: 1.15 ... 1.60)
		#expect(room.before == 1.15)
		#expect(room.after == 2.40)
		// Nothing on either side of the whole take.
		let ends = said.neighbours(of: 1.0 ... 2.90)
		#expect(ends.before == nil)
		#expect(ends.after == nil)
	}
}
