import CoreGraphics
import Foundation
import Testing
@testable import CuttrKit

@Suite struct TakeFileTests {

	private func sample() -> Take {
		Take(
			video: "media/take-01.mov",
			audio: AudioTrack(file: "media/take-01-mic.wav", offset: 1.234),
			clips: [
				Clip(slug: "intro", name: "Intro — hello and welcome", start: 1.5, end: 12.3),
				Clip(slug: "demo-install", name: "Installing the driver", start: 14.02, end: 63.88,
				     note: "retake; the second one is cleaner"),
			])
	}

	@Test func roundTrips() throws {
		let written = TakeWriter.write(sample())
		let back = try TakeReader.read(written)
		#expect(back == sample())
	}

	@Test func writingIsStableForTheSameTake() {
		// The whole reason the emitter is hand-written: re-saving an unchanged
		// take must produce an unchanged file, or every commit is a rewrite.
		#expect(TakeWriter.write(sample()) == TakeWriter.write(sample()))
	}

	@Test func readsWhatSomebodyWouldTypeByHand() throws {
		let take = try TakeReader.read("""
		video: a.mov
		audio: b.wav
		clips:
		  - name: Just a name
		    start: 90
		    end: 01:40.500
		""")
		#expect(take.video == "a.mov")
		#expect(take.audio == AudioTrack(file: "b.wav", offset: 0))
		#expect(take.clips.count == 1)
		// No slug in the file, so one is derived — the reference has to exist
		// from the moment the file is read, not from the next save.
		#expect(take.clips[0].slug == "just-a-name")
		#expect(take.clips[0].start == 90)
		#expect(take.clips[0].end == 100.5)
	}

	@Test func theShortAudioFormIsWrittenWhenThereIsNoOffset() {
		var take = sample()
		take.audio = AudioTrack(file: "b.wav", offset: 0)
		#expect(TakeWriter.write(take).contains("audio: b.wav"))
		#expect(!TakeWriter.write(take).contains("offset"))
	}

	@Test func duplicateSlugsInAFileAreMadeUnique() throws {
		let take = try TakeReader.read("""
		video: a.mov
		clips:
		  - slug: intro
		    start: 0
		    end: 1
		  - slug: intro
		    start: 2
		    end: 3
		""")
		#expect(take.clips.map(\.slug) == ["intro", "intro-2"])
	}

	@Test func aNameThatLooksLikeSomethingElseSurvives() throws {
		// `no`, `12`, a leading `-`, an embedded `: ` — each is valid YAML for
		// something other than the string that was meant.
		for name in ["no", "12", "- take", "Chapter 2: the driver", "  padded  ", "#1", "true"] {
			let take = Take(video: "a.mov", clips: [Clip(slug: "x", name: name, start: 0, end: 1)])
			let back = try TakeReader.read(TakeWriter.write(take))
			#expect(back.clips.first?.name == name, "name: \(name)")
		}
	}

	@Test func coloursRoundTripAndTheDefaultIsNotWritten() throws {
		var take = Take(video: "a.mov", clips: [
			Clip(slug: "a", start: 0, end: 1),
			Clip(slug: "b", start: 1, end: 2, color: .rose),
		])
		let text = TakeWriter.write(take)
		// A take nobody has colour-coded should not carry a `color:` line on
		// every clip explaining that it is the usual one.
		#expect(text.components(separatedBy: "color:").count == 2)
		#expect(text.contains("color: rose"))
		take = try TakeReader.read(text)
		#expect(take.clips.map(\.color) == [.green, .rose])
	}

	@Test func anUnknownColourFallsBackRatherThanFailing() throws {
		// A palette can lose a name between versions; a take is worth more than
		// its colouring.
		let take = try TakeReader.read("""
		video: a.mov
		clips:
		  - slug: a
		    start: 0
		    end: 1
		    color: chartreuse
		""")
		#expect(take.clips.first?.color == .green)
	}

	@Test func trimmingOrdersTheEdges() {
		var take = Take(video: "a.mov", clips: [Clip(slug: "a", start: 5, end: 10)])
		let id = take.clips[0].id
		let moved = take.setTimes(start: 12, end: 8, for: id)
		#expect(moved)
		#expect(take.clips[0].start == 8)
		#expect(take.clips[0].end == 12)
		// Nothing starts before the recording does.
		take.setTimes(start: -3, end: 4, for: id)
		#expect(take.clips[0].start == 0)
	}

	@Test func anchorsBelongToTheTakeAndRoundTrip() throws {
		let take = Take(video: "a.mov", clips: [Clip(slug: "two-shot", start: 0, end: 30)], anchors: [
			Anchor(name: "mia-eye", from: 0, to: 28.5, markedAt: 1.2,
			       point: CGPoint(x: 0.42, y: 0.56), path: "anchors/mia-eye.path"),
			Anchor(name: "sam-eye", from: 3, to: 30, markedAt: 1.2,
			       point: CGPoint(x: 0.71, y: 0.54), path: "anchors/sam-eye.path"),
		])
		let back = try TakeReader.read(TakeWriter.write(take))
		#expect(back.anchors.count == 2)
		#expect(back.anchors.map(\.name) == ["mia-eye", "sam-eye"])
		#expect(back.anchors[1].from == 3)
		#expect(back.anchors[1].to == 30)
		#expect(abs(back.anchors[1].point.x - 0.71) < 0.0001)
		#expect(back == take)
	}

	@Test func twoPeopleInOneShotAreTwoAnchors() {
		// Nothing about tracking is single-occupancy: an anchor is a name and a
		// point, and a two-shot is two of them.
		var take = Take(video: "a.mov", clips: [Clip(slug: "two-shot", start: 0, end: 30)])
		let first = take.add(Anchor(name: "eye", from: 0, to: 30, markedAt: 1, point: .zero))
		let second = take.add(Anchor(name: "eye", from: 0, to: 30, markedAt: 1, point: .zero))
		// Named apart automatically, because a project references them by name.
		#expect(first.name == "eye")
		#expect(second.name == "eye-2")
		#expect(take.anchors.count == 2)
	}

	@Test func aTakeWithNoAnchorsWritesNoAnchorsBlock() {
		let take = Take(video: "a.mov", clips: [Clip(slug: "a", start: 0, end: 1)])
		#expect(!TakeWriter.write(take).contains("anchors:"))
	}

	@Test func theTranscriptIsANamedSidecarAndRoundTrips() throws {
		let take = Take(video: "a.mov",
		                clips: [Clip(slug: "a", start: 0, end: 1)],
		                words: Words(path: "words/take-01.words",
		                             recogniser: .speechAnalyzer, locale: "de-DE"))
		let text = TakeWriter.write(take)
		#expect(text.contains("words:"))
		#expect(text.contains("path:       words/take-01.words"))
		// Which model, and in which language. A suggestion nobody can trace is
		// one nobody trusts next year.
		#expect(text.contains("recogniser: speech-analyzer"))
		#expect(text.contains("locale:     de-DE"))
		#expect(try TakeReader.read(text) == take)
		#expect(TakeWriter.write(take) == text)
	}

	@Test func aTranscriptSomebodyWroteThemselvesIsOneLine() throws {
		// The same two spellings the audio has: the short form is what a person
		// writes when there is nothing to say beyond where the file is.
		let take = try TakeReader.read("video: a.mov\nwords: words/by-hand.words\n")
		#expect(take.words?.path == "words/by-hand.words")
		#expect(take.words?.recogniser == .hand)
		let text = TakeWriter.write(take)
		#expect(text.contains("words: words/by-hand.words"))
		#expect(try TakeReader.read(text) == take)
	}

	@Test func aRecogniserThisVersionDoesNotKnowIsNotAFailure() throws {
		let take = try TakeReader.read("""
		video: a.mov
		words:
		  path: words/a.words
		  recogniser: whisper-large-v9
		  locale: de-DE
		""")
		#expect(take.words?.path == "words/a.words")
		#expect(take.words?.recogniser == .hand)
	}

	@Test func aTakeWithNoTranscriptWritesNoWordsBlock() {
		#expect(!TakeWriter.write(Take(video: "a.mov")).contains("words:"))
	}

	@Test func keysFromANewerVersionAreNotDeleted() throws {
		let original = """
		cuttr: 1
		video: a.mov
		transcript: whisper.json
		clips:
		  - slug: intro
		    start: 0
		    end: 1
		"""
		let take = try TakeReader.read(original)
		#expect(take.unknownKeys["transcript"] as? String == "whisper.json")
		// An older build that opens this file and saves it must not silently
		// throw away what it did not understand.
		#expect(TakeWriter.write(take).contains("transcript: whisper.json"))
	}

	@Test func anEmptyFileIsAnEmptyTake() throws {
		#expect(try TakeReader.read("") == Take())
		#expect(try TakeReader.read("# nothing but a comment\n") == Take())
	}

	@Test func aTakeWithNoMediaIsRefused() {
		#expect(throws: TakeError.self) {
			try TakeReader.read("clips:\n  - slug: a\n    start: 0\n    end: 1\n")
		}
	}

	@Test func aClipWithNoTimesSaysWhichClip() {
		#expect(throws: TakeError.self) {
			try TakeReader.read("video: a.mov\nclips:\n  - slug: a\n    start: 0\n")
		}
	}

	@Test func aFutureVersionIsRefusedRatherThanMisread() {
		#expect(throws: TakeError.self) { try TakeReader.read("cuttr: 99\nvideo: a.mov\n") }
	}

	@Test func clipTimesAreOrderedOnTheWayIn() {
		// A drag that crosses its own start is the ordinary way to make one.
		let clip = Clip(slug: "x", start: 10, end: 2)
		#expect(clip.start == 2)
		#expect(clip.end == 10)
		#expect(clip.duration == 8)
	}

	@Test func addingAClipKeepsSlugsUnique() {
		var take = Take(video: "a.mov")
		take.add(Clip(slug: "", name: "Intro", start: 0, end: 1))
		take.add(Clip(slug: "", name: "Intro", start: 1, end: 2))
		#expect(take.clips.map(\.slug) == ["intro", "intro-2"])
	}

	@Test func renamingASlugCannotCollide() {
		var take = Take(video: "a.mov", clips: [
			Clip(slug: "one", start: 0, end: 1),
			Clip(slug: "two", start: 1, end: 2),
		])
		let used = take.setSlug("one", for: take.clips[1].id)
		// The caller is told what was actually used, because that is what the
		// assembly file will have to say.
		#expect(used == "one-2")
		#expect(take.clips[1].slug == "one-2")
	}
}

/// A solved path knows how far it goes.
@Suite struct AnchorPathTests {

	private let path = AnchorPath(samples: [
		(10.0, CGPoint(x: 0.5, y: 0.5)),
		(11.0, CGPoint(x: 0.6, y: 0.5)),
		(12.0, CGPoint(x: 0.7, y: 0.5)),
	])

	@Test func interpolatesBetweenSamples() {
		#expect(path.point(at: 10.5)?.x == 0.55)
		#expect(path.point(at: 11.25)?.x ?? 0 > 0.62)
	}

	@Test func clampsOutsideRatherThanFlyingOff() {
		// The renderer wants an answer everywhere, and "where it last was" is
		// the honest one. A line continued past the end is a spinner leaving
		// the frame.
		#expect(path.point(at: 0)?.x == 0.5)
		#expect(path.point(at: 99)?.x == 0.7)
	}

	@Test func coverageCanHaveHolesInIt() {
		// Which is what a shot used by two subclips with other material between
		// them looks like once it has been laid onto a programme: one ascending
		// list of samples, two stretches that mean anything.
		let split = AnchorPath(
			samples: [(0.0, CGPoint(x: 0, y: 0)), (1.0, CGPoint(x: 1, y: 0)),
			          (5.0, CGPoint(x: 0, y: 0)), (6.0, CGPoint(x: 1, y: 0))],
			covered: [0.0 ... 1.0, 5.0 ... 6.0])
		#expect(split.covers(0.5))
		#expect(split.covers(5.5))
		// The gap is not tracked, and a marker must not be drawn across it.
		#expect(!split.covers(3))
		#expect(split.timeRange == 0.0 ... 6.0)
	}

	@Test func butSaysWhereItActuallyKnows() {
		// Which is what stops a marker being drawn, frozen, three minutes
		// before the clip it belongs to.
		#expect(path.timeRange == 10.0 ... 12.0)
		#expect(path.covers(11))
		#expect(!path.covers(9.9))
		#expect(!path.covers(12.1))
		#expect(AnchorPath().timeRange == nil)
		#expect(!AnchorPath().covers(0))
	}
}

/// Picking a face up again after the tracker loses it.
@Suite struct AnchorMergeTests {

	private func path(_ spans: [(Double, Double)]) -> AnchorPath {
		var samples: [(time: Double, point: CGPoint)] = []
		for (from, to) in spans {
			var t = from
			while t <= to + 1e-9 {
				samples.append((t, CGPoint(x: t / 100, y: 0.5)))
				t += 0.1
			}
		}
		return AnchorPath(samples: samples, covered: spans.map { $0.0 ... $0.1 })
	}

	@Test func mergingLeavesTheGapAlone() {
		// One anchor, two stretches, and nothing claimed in between: a hole is
		// the honest record of a face the tracker could not see.
		let merged = path([(0, 2)]).merging(path([(5, 7)]))
		#expect(merged.covered.count == 2)
		#expect(merged.covers(1))
		#expect(merged.covers(6))
		#expect(!merged.covers(3.5))
		#expect(merged.timeRange == 0.0 ... 7.0)
	}

	@Test func overlappingStretchesBecomeOne() {
		let merged = path([(0, 4)]).merging(path([(3, 8)]))
		#expect(merged.covered.count == 1)
		#expect(merged.covered.first == 0.0 ... 8.0)
	}

	@Test func theNewerSolveWins() {
		// The second was made from a mark somebody placed while looking at that
		// part of the picture, so where they disagree it is the better answer.
		let old = AnchorPath(samples: [(1.0, CGPoint(x: 0.1, y: 0.1))], covered: [0.0 ... 2.0])
		let new = AnchorPath(samples: [(1.0, CGPoint(x: 0.9, y: 0.9))], covered: [0.5 ... 1.5])
		let merged = old.merging(new)
		#expect(merged.point(at: 1)?.x == 0.9)
	}

	@Test func mergingWithNothingChangesNothing() {
		let one = path([(0, 2)])
		#expect(one.merging(AnchorPath()) == one)
		#expect(AnchorPath().merging(one) == one)
	}

	@Test func touchingSpansDoNotStayApart() {
		#expect(AnchorPath.union([0.0 ... 1.0, 1.0 ... 2.0]).count == 1)
		#expect(AnchorPath.union([0.0 ... 1.0, 3.0 ... 4.0]).count == 2)
	}
}
