import Foundation
import Testing
@testable import CuttrKit

/// Which clock a transcript's times are on.
///
/// The one thing about this feature that has to be right. A take's words come
/// from the separate recorder, which has a clock of its own; `audio + offset =
/// video` is the only thing relating the two, and a transcript that skipped
/// that step would be found out the first time somebody re-aligned — by which
/// point every clip named from it would be named after the wrong sentence.
@Suite struct TranscriberClockTests {

	@Test func theOffsetIsAppliedToEveryWord() {
		// The take this was measured against: the recorder was rolling 11.093 s
		// before the camera, so `audio + offset = video` moves every word
		// earlier by that much.
		let take = Take(video: "mia/IMG_1800.mov",
		                audio: AudioTrack(file: "mia/mia.wav", offset: -11.093))
		let source = Transcriber.Source.forTake(
			take,
			videoURL: URL(fileURLWithPath: "/x/mia/IMG_1800.mov"),
			audioURL: URL(fileURLWithPath: "/x/mia/mia.wav"),
			duration: 315.2)
		#expect(source?.url.lastPathComponent == "mia.wav")
		#expect(source?.offset == -11.093)

		let heard = Word(start: 100, end: 100.5, text: "so")
		let placed = source?.onVideoClock(heard)
		#expect(placed?.start == 88.907)
		#expect(placed?.end == 89.407)
	}

	@Test func aRecorderStartedAfterTheCameraPushesWordsLater() {
		// The other sign, because a test and a doc comment have disagreed about
		// this one before.
		let take = Take(video: "a.mov", audio: AudioTrack(file: "b.wav", offset: 2.5))
		let source = Transcriber.Source.forTake(
			take, videoURL: URL(fileURLWithPath: "/a.mov"),
			audioURL: URL(fileURLWithPath: "/b.wav"), duration: 60)
		#expect(source?.onVideoClock(Word(start: 10, end: 10.4, text: "x"))?.start == 12.5)
	}

	@Test func wordsOutsideTheTakeAreDropped() {
		// A recorder rolling before the camera heard things no clip can contain.
		let source = Transcriber.Source(url: URL(fileURLWithPath: "/b.wav"),
		                                offset: -11.093, limit: 0 ... 315.2)
		#expect(source.onVideoClock(Word(start: 2, end: 2.4, text: "early")) == nil)
		#expect(source.onVideoClock(Word(start: 330, end: 330.4, text: "late")) == nil)
		// One that straddles the first frame is the take's first word, and it
		// keeps the time it was actually said at.
		let straddling = source.onVideoClock(Word(start: 11, end: 11.4, text: "half"))
		#expect(straddling != nil)
		#expect(straddling!.start < 0)
	}

	@Test func anAudioOnlyTakeIsOnItsOwnClock() {
		// No video, so there is no second clock and the offset — whatever the
		// file happens to say — means nothing.
		let take = Take(audio: AudioTrack(file: "b.wav", offset: 9))
		let source = Transcriber.Source.forTake(
			take, videoURL: nil, audioURL: URL(fileURLWithPath: "/b.wav"), duration: 60)
		#expect(source?.offset == 0)
	}

	@Test func withNoSeparateRecorderTheVideoIsTranscribed() {
		let take = Take(video: "a.mov")
		let source = Transcriber.Source.forTake(
			take, videoURL: URL(fileURLWithPath: "/a.mov"), audioURL: nil, duration: 60)
		#expect(source?.url.lastPathComponent == "a.mov")
		#expect(source?.offset == 0)
	}
}
