import Foundation
import Testing
@testable import CuttrKit

/// From windows to events.
///
/// The classifier answers about one second of audio at a time and is asked
/// every half second, so one laugh comes back as four or five hits saying the
/// same thing. Everything here is about not writing four laughs down.
@Suite struct SoundEventMergeTests {

	private func window(_ kind: String, _ start: Double, _ confidence: Double) -> SoundEvent {
		SoundEvent(kind: kind, start: start, end: start + SoundSpotter.window,
		           confidence: confidence)
	}

	@Test func overlappingWindowsOfOneKindAreOneEvent() {
		// 150.5, 151.0, 151.5, 152.5 — the shape a real laugh arrives in.
		let merged = SoundEvent.merge([
			window("laughter", 150.5, 0.83),
			window("laughter", 151.0, 0.76),
			window("laughter", 151.5, 0.41),
			window("laughter", 152.5, 0.43),
		])
		#expect(merged.count == 1)
		#expect(merged[0].start == 150.5)
		#expect(merged[0].end == 153.5)
		// As sure as the surest window in it, not the average: the classifier
		// was certain about the middle of the laugh and vague about its edges,
		// which is what being certain about a laugh looks like.
		#expect(merged[0].confidence == 0.83)
	}

	@Test func windowsFarApartAreTwoEvents() {
		let merged = SoundEvent.merge([
			window("laughter", 31.0, 0.67),
			window("laughter", 59.5, 0.66),
		])
		#expect(merged.count == 2)
		#expect(merged.map(\.start) == [31.0, 59.5])
	}

	/// A laugh that dips for half a second is one laugh. One hop of the
	/// analysis window is bridged and no more.
	@Test func aGapOfOneHopIsBridgedAndTwoAreNot() {
		let bridged = SoundEvent.merge([
			window("laughter", 58.0, 0.61), window("laughter", 59.5, 0.66),
		])
		#expect(bridged.count == 1)
		#expect(bridged[0].end == 60.5)

		let notBridged = SoundEvent.merge([
			window("laughter", 58.0, 0.61), window("laughter", 60.5, 0.66),
		])
		#expect(notBridged.count == 2)
	}

	/// A window nobody is sure about joins an event but cannot make one.
	@Test func anEventNeedsOneWindowWorthBelieving() {
		#expect(SoundEvent.merge([
			window("laughter", 10, 0.45), window("laughter", 10.5, 0.5),
		]).isEmpty)

		// And a window below the joining line is not even evidence: it does not
		// stretch the event it sits beside.
		let merged = SoundEvent.merge([
			window("laughter", 10, 0.7), window("laughter", 10.5, 0.1),
		])
		#expect(merged.count == 1)
		#expect(merged[0].end == 11.0)
	}

	/// One second of audio is one thing that happened. A classifier saying two
	/// different things about it is a classifier that is unsure which.
	@Test func twoKindsOverTheSameSecondsBecomeTheSurerOne() {
		let merged = SoundEvent.merge([
			window("laughter", 83.5, 0.62),
			window("cough", 83.5, 0.31),
			window("cough", 84.0, 0.43),
		])
		#expect(merged.count == 1)
		#expect(merged[0].kind == "laughter")
	}

	/// And two kinds that do not overlap are two things that happened.
	@Test func twoKindsAtDifferentTimesBothSurvive() {
		let merged = SoundEvent.merge([
			window("laughter", 10, 0.7), window("applause", 40, 0.8),
		])
		#expect(merged.map(\.kind) == ["laughter", "applause"])
		// In the order they happened, whatever order the windows arrived in.
		#expect(merged.map(\.start) == [10, 40])
	}

	@Test func theAnswerDoesNotDependOnTheOrderTheWindowsArrivedIn() {
		let windows = [
			window("laughter", 150.5, 0.83), window("cough", 308.5, 0.83),
			window("laughter", 151.0, 0.76), window("laughter", 31.0, 0.67),
		]
		#expect(SoundEvent.merge(windows) == SoundEvent.merge(windows.reversed()))
	}

	@Test func nothingHeardIsNothingWrittenDown() {
		#expect(SoundEvent.merge([]).isEmpty)
	}
}

/// Which of the 303 classes become which of the seven kinds.
@Suite struct SoundEventKindTests {

	/// One laugh sets five branches of the taxonomy off at once. Written out
	/// as five events that is five lines in the file for one thing that
	/// happened.
	@Test func theLaughterFamilyIsOneKind() {
		for said in ["laughter", "giggling", "belly_laugh", "chuckle_chortle",
		             "snicker", "baby_laughter"] {
			#expect(SoundEvent.kind(forClassifier: said) == "laughter")
		}
		#expect(SoundEvent.kind(forClassifier: "clapping") == "applause")
		#expect(SoundEvent.kind(forClassifier: "baby_crying") == "crying")
	}

	/// And the folding happens before the merge, so the five branches of one
	/// laugh end up as one event rather than five overlapping ones fighting.
	@Test func theWholeFamilyOverOneSecondIsOneLaugh() {
		let merged = SoundEvent.merge(
			["laughter": 0.83, "giggling": 0.68, "belly_laugh": 0.54, "chuckle_chortle": 0.46]
				.map { SoundEvent(kind: SoundEvent.kind(forClassifier: $0.key)!,
				                  start: 150.5, end: 151.5, confidence: $0.value) })
		#expect(merged.count == 1)
		#expect(merged[0].kind == "laughter")
		#expect(merged[0].confidence == 0.83)
	}

	/// The other 290-odd change no cut and are not written down.
	@Test func afridgeHumIsNotWrittenDown() {
		#expect(SoundEvent.kind(forClassifier: "hum") == nil)
		#expect(SoundEvent.kind(forClassifier: "car_passing_by") == nil)
		// Measured on real footage: it fires on laughter and never on a sneeze.
		#expect(SoundEvent.kind(forClassifier: "sneeze") == nil)
	}

	/// The identifier is the fact and the label is the presentation of it. What
	/// goes in the file must not change meaning with the system language, so
	/// these two are deliberately not the same string.
	@Test func theLabelIsTranslatedAndTheIdentifierIsNot() {
		let laugh = SoundEvent(kind: "laughter", start: 0, end: 1)
		#expect(laugh.label(in: Locale(identifier: "de-DE")) == "Lachen")
		#expect(laugh.label(in: Locale(identifier: "en-GB")) == "laughter")
		// A language nobody has written a table for shows the identifier, which
		// is English and is at least true.
		#expect(laugh.label(in: Locale(identifier: "fi-FI")) == "laughter")
		#expect(laugh.kind == "laughter")
	}

	/// And a kind this version has never heard of still shows something true.
	@Test func anUnknownKindLabelsItself() {
		#expect(SoundEvent(kind: "sigh", start: 0, end: 1)
			.label(in: Locale(identifier: "de-DE")) == "sigh")
	}
}

/// One clock.
///
/// The classifier listens to the separate recorder, which has a clock of its
/// own. This is the arithmetic that relates the two, and it is the same
/// arithmetic a word goes through.
@Suite struct SoundEventClockTests {

	/// The real take: `audio.offset` is −11.093, so the laugh the classifier
	/// heard at 150.5 seconds of recorder time is at 139.407 of video time.
	@Test func aLaughIsMovedOntoTheVideosClock() throws {
		let source = Transcriber.Source(url: URL(fileURLWithPath: "/mia.wav"), offset: -11.093)
		let moved = try #require(source.onVideoClock(
			SoundEvent(kind: "laughter", start: 150.5, end: 153.5, confidence: 0.83)))
		#expect(abs(moved.start - 139.407) < 0.0005)
		#expect(abs(moved.end - 142.407) < 0.0005)
		// Everything else about it survives the journey.
		#expect(moved.kind == "laughter")
		#expect(moved.confidence == 0.83)
	}

	/// And the other sign. Positive means the recorder was started *after* the
	/// camera, so its first sample belongs later on the video's clock — the
	/// sentence the house rules say a test and a doc comment once disagreed
	/// about.
	@Test func aRecorderStartedLateMovesItsSoundsLater() throws {
		let source = Transcriber.Source(url: URL(fileURLWithPath: "/mia.wav"), offset: 4.5)
		let moved = try #require(source.onVideoClock(
			SoundEvent(kind: "applause", start: 10, end: 12)))
		#expect(moved.start == 14.5)
		#expect(moved.end == 16.5)
	}

	/// A word and a laugh from the same second of the same file land on the
	/// same second of the video, because there is one piece of arithmetic and
	/// not two.
	@Test func aWordAndALaughAgreeWithEachOther() throws {
		let source = Transcriber.Source(url: URL(fileURLWithPath: "/mia.wav"), offset: -11.093)
		let word = try #require(source.onVideoClock(Word(start: 150.5, end: 153.5, text: "ha")))
		let laugh = try #require(source.onVideoClock(
			SoundEvent(kind: "laughter", start: 150.5, end: 153.5)))
		#expect(word.start == laugh.start)
		#expect(word.end == laugh.end)
	}

	/// A recorder rolling before the camera hears minutes no clip can contain.
	@Test func aLaughOutsideTheTakeIsNotInTheTake() {
		let source = Transcriber.Source(
			url: URL(fileURLWithPath: "/mia.wav"), offset: -11.093, limit: 0 ... 300)
		#expect(source.onVideoClock(SoundEvent(kind: "laughter", start: 1, end: 3)) == nil)
		// Overlap, not containment: a laugh that begins a hair before the first
		// frame is still the take's.
		#expect(source.onVideoClock(SoundEvent(kind: "laughter", start: 10, end: 13)) != nil)
	}
}

/// The sounds in the take file.
@Suite struct SoundEventFileTests {

	private func take() -> Take {
		Take(video: "a.mov",
		     audio: AudioTrack(file: "b.wav", offset: -11.093),
		     clips: [Clip(slug: "intro", name: "Intro", start: 0, end: 10)],
		     sounds: [
		     	SoundEvent(kind: "laughter", start: 19.907, end: 21.907, confidence: 0.67),
		     	SoundEvent(kind: "cough", start: 297.407, end: 298.407, confidence: 0.83),
		     ])
	}

	@Test func soundsSurviveBeingWrittenAndReadBack() throws {
		let read = try TakeReader.read(TakeWriter.write(take()))
		#expect(read.sounds.count == 2)
		#expect(read.sounds[0].kind == "laughter")
		#expect(abs(read.sounds[0].start - 19.907) < 0.0005)
		#expect(abs(read.sounds[0].end - 21.907) < 0.0005)
		#expect(read.sounds[0].confidence == 0.67)
		#expect(read.sounds[1].kind == "cough")
	}

	@Test func writingIsStableForTheSameSounds() throws {
		// The house rule, extended to the new block: a re-save nobody meant
		// must not be a diff.
		let once = TakeWriter.write(take())
		#expect(TakeWriter.write(try TakeReader.read(once)) == once)
	}

	/// The rest of the file is untouched. A take with no sounds in it writes
	/// exactly the bytes it wrote before there was such a thing as a sound.
	@Test func aTakeWithNoSoundsSaysNothingAboutThem() {
		var quiet = take()
		quiet.sounds = []
		let written = TakeWriter.write(quiet)
		#expect(!written.contains("sounds:"))
		#expect(!written.contains("laughter"))
	}

	/// A file written by a later version must survive being opened and saved
	/// by an older one — so a kind this build has never heard of is kept as it
	/// was written, and so is anything else in the block.
	@Test func aKindThisVersionDoesNotKnowIsCarriedThrough() throws {
		let read = try TakeReader.read("""
		video: a.mov

		sounds:
		  - sound:      sigh
		    start:      00:10.000
		    end:        00:11.500
		    confidence: 0.71
		""")
		#expect(read.sounds.count == 1)
		#expect(read.sounds[0].kind == "sigh")
		#expect(TakeWriter.write(read).contains("sound:      sigh"))
	}

	/// Written by hand, which is the point of the file being text: a laugh the
	/// classifier missed is four lines to add, and three of them are optional.
	@Test func readsWhatSomebodyWouldTypeByHand() throws {
		let read = try TakeReader.read("""
		video: a.mov
		sounds:
		  - sound: laughter
		    start: 90
		    end: 01:40.500
		""")
		#expect(read.sounds.count == 1)
		#expect(read.sounds[0].start == 90)
		#expect(read.sounds[0].end == 100.5)
		// Nobody said how sure they were, and somebody typing it is as sure as
		// it gets.
		#expect(read.sounds[0].confidence == 1)
	}

	@Test func aBlockWithNothingInItIsSkippedRatherThanFatal() throws {
		let read = try TakeReader.read("""
		video: a.mov
		sounds:
		  - start: 10
		    end: 11
		  - sound: laughter
		    start: 20
		    end: 21
		""")
		#expect(read.sounds.count == 1)
		#expect(read.sounds[0].kind == "laughter")
	}
}
