import Foundation
import Testing
@testable import CuttrKit

/// The sound classifier against a real recording, on the machine it was
/// measured on.
///
/// Off by default and not part of the suite, for the same reason
/// ``TranscriptFootageTests`` is: it needs footage that is not in this
/// repository and cannot be. What it answers is the question the unit tests
/// cannot — are the laughs *where the laughs are*, out there, on a take whose
/// audio came from a recorder eleven seconds out of step with the camera.
///
/// ```
/// CUTTR_FOOTAGE=/Volumes/500G/DorisWalter70/mia-take-1.cuttr \
///   xcrun swift test --filter SoundFootageTests
/// ```
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CUTTR_FOOTAGE"] != nil))
struct SoundFootageTests {

	private var takeURL: URL {
		URL(fileURLWithPath: ProcessInfo.processInfo.environment["CUTTR_FOOTAGE"]!)
	}

	@Test func findsTheLaughsOnTheVideosClock() async throws {
		let base = takeURL.deletingLastPathComponent()
		let take = try TakeReader.read(try String(contentsOf: takeURL, encoding: .utf8))
		let video = take.video.map { URL(fileURLWithPath: $0, relativeTo: base) }
		let audio = take.audio.map { URL(fileURLWithPath: $0.file, relativeTo: base) }
		let probed = try await MediaProbe.probe(video ?? audio!)
		let source = try #require(Transcriber.Source.forTake(
			take, videoURL: video, audioURL: audio, duration: probed.duration))

		print("listening to \(source.url.lastPathComponent), offset \(source.offset)")
		let started = Date()
		let heard = try await SoundSpotter.listen(source)
		print(String(format: "%d events in %.1f s of wall clock over %.0f s of audio",
		             heard.count, -started.timeIntervalSinceNow, probed.duration))
		for sound in heard {
			print(String(format: "  %@  %@ – %@  (recorder %.1f)  %.2f",
			             sound.kind.padding(toLength: 12, withPad: " ", startingAt: 0),
			             Timecode.string(sound.start), Timecode.string(sound.end),
			             sound.start - source.offset, sound.confidence))
		}

		#expect(!heard.isEmpty)
		// Everything inside the video, because that is what the offset is for.
		#expect(heard.allSatisfy { $0.start < probed.duration && $0.end > 0 })
		// Only kinds this program writes down.
		#expect(heard.allSatisfy { SoundEvent.known.contains($0.kind) })
		// And nothing overlapping anything else: one moment, one event.
		for (index, sound) in heard.enumerated() {
			#expect(!heard[(index + 1)...].contains { $0.overlaps(sound) })
		}

		// The six laughs measured by ear on this take, in *recorder* seconds —
		// which is how they were found, and which is exactly why they have to
		// be converted before anything is written down.
		let offset = take.audio?.offset ?? 0
		for recorderTime in [31.0, 59.5, 83.5, 150.5, 179.0, 187.5] {
			let onVideoClock = recorderTime + offset
			#expect(heard.contains {
				$0.kind == "laughter" && $0.start <= onVideoClock + 1 && $0.end >= onVideoClock
			}, "no laughter at \(Timecode.string(onVideoClock)) of video time")
		}

		// A clip made from one covers it: the classifier's window brackets the
		// laugh rather than trimming it, so the whole thing is in the clip.
		let laugh = try #require(heard.first { $0.kind == "laughter" })
		let clip = Clip(slug: "laugh", start: laugh.start, end: laugh.end)
		#expect(clip.duration >= 1)
		#expect(clip.contains(laugh.start))

		// And the take, written out with them in it, reads back the same.
		var withSounds = take
		withSounds.sounds = heard
		let written = TakeWriter.write(withSounds)
		let readBack = try TakeReader.read(written)
		#expect(readBack.sounds.count == heard.count)
		#expect(TakeWriter.write(readBack) == written)
		print(written.split(separator: "\n")
			.drop { !$0.hasPrefix("sounds:") }.prefix(13).joined(separator: "\n"))
	}
}

/// The model naming real lines from a real take.
///
/// Prints what it produced, including anything it made up, because the number
/// that matters — how often it invents — is not a thing to take on trust from
/// a commit message.
///
/// ```
/// CUTTR_FOOTAGE=/Volumes/500G/DorisWalter70/mia-take-1.cuttr \
///   xcrun swift test --filter ClipNamingFootageTests
/// ```
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CUTTR_FOOTAGE"] != nil))
struct ClipNamingFootageTests {

	private var takeURL: URL {
		URL(fileURLWithPath: ProcessInfo.processInfo.environment["CUTTR_FOOTAGE"]!)
	}

	@Test func namesADozenRealLines() async throws {
		let base = takeURL.deletingLastPathComponent()
		let take = try TakeReader.read(try String(contentsOf: takeURL, encoding: .utf8))
		let path = try #require(take.words?.path)
		let said = Transcript.read(
			try String(contentsOf: URL(fileURLWithPath: path, relativeTo: base), encoding: .utf8))
		#expect(!said.isEmpty)

		// The lines the pane lays out: a run of words with no silence in it,
		// which is the unit somebody points at and says "make that a clip".
		var lines: [Range<Int>] = []
		var at = 0
		while at < said.count {
			let line = said.segment(around: at)
			if line.count >= 6 { lines.append(line) }
			at = line.upperBound
		}
		print("\(lines.count) lines of six words or more; naming the first fifteen")
		print("availability: \(ClipNamer.availability)")

		var invented = 0
		var fellBack = 0
		for line in lines.prefix(15) {
			let span = try #require(said.span(line))
			let passage = said.text(covering: span.start ... span.end)
			let firstWords = said.phrase(line)
			let started = Date()
			let naming = await ClipNamer.propose(for: passage, orFirstWords: firstWords)
			let how: String
			switch naming.source {
			case .model: how = "model"
			case .invented(let made): how = "INVENTED “\(made)”"; invented += 1
			case .firstWords(let why): how = "first words — \(why)"; fellBack += 1
			}
			print(String(format: "%.2fs  %@  %@  ← %@",
			             -started.timeIntervalSinceNow,
			             naming.name.padding(toLength: 24, withPad: " ", startingAt: 0),
			             how.padding(toLength: 44, withPad: " ", startingAt: 0),
			             String(passage.prefix(64))))
			// Whatever happened, there is a name and it is not the model's word
			// for it unless the check let it through.
			#expect(!naming.name.isEmpty)
			if case .model = naming.source {
				#expect(ClipNamer.isGrounded(naming.name, in: passage))
			} else {
				#expect(naming.name == firstWords)
			}
		}
		print("invented \(invented), fell back \(fellBack), of \(min(lines.count, 15))")
	}
}
