import Foundation
import Testing
@testable import CuttrKit

/// The transcript, against a real recording, on the machine it was measured on.
///
/// Off by default and not part of the suite, because it needs footage that is
/// not in this repository and cannot be: it is minutes of somebody's video on
/// an external disk. What it is for is the question the unit tests cannot
/// answer — are the times *right*, out there, on a take whose audio came from a
/// separate recorder eleven seconds out of step with the camera.
///
/// ```
/// CUTTR_FOOTAGE=/Volumes/500G/DorisWalter70/mia-take-1.cuttr \
///   xcrun swift test --filter TranscriptFootageTests
/// ```
///
/// It prints where it put the sidecar. Checking a word against the picture is
/// then one `ffmpeg -ss` away, which is how the numbers in the commit message
/// were arrived at.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CUTTR_FOOTAGE"] != nil))
struct TranscriptFootageTests {

	private var takeURL: URL {
		URL(fileURLWithPath: ProcessInfo.processInfo.environment["CUTTR_FOOTAGE"]!)
	}

	@Test func transcribesARealTakeOntoTheVideosClock() async throws {
		let base = takeURL.deletingLastPathComponent()
		let take = try TakeReader.read(try String(contentsOf: takeURL, encoding: .utf8))
		let video = take.video.map { URL(fileURLWithPath: $0, relativeTo: base) }
		let audio = take.audio.map { URL(fileURLWithPath: $0.file, relativeTo: base) }
		let probed = try await MediaProbe.probe(video ?? audio!)
		let source = try #require(Transcriber.Source.forTake(
			take, videoURL: video, audioURL: audio, duration: probed.duration))

		print("listening to \(source.url.lastPathComponent), offset \(source.offset)")
		let started = Date()
		let made = try await Transcriber.transcribe(
			source, locale: Locale(identifier: "de-DE"))
		print(String(format: "%d words in %.1f s of wall clock, %@, %@",
		             made.transcript.count, -started.timeIntervalSinceNow,
		             made.recogniser.rawValue, made.locale))

		#expect(!made.transcript.isEmpty)
		// Every word inside the video, because that is what the offset is for.
		#expect(made.transcript.words.allSatisfy { $0.start < probed.duration })

		let out = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent(takeURL.deletingPathExtension().lastPathComponent + ".words")
		try made.transcript
			.write(name: takeURL.deletingPathExtension().lastPathComponent,
			       recogniser: made.recogniser.rawValue, locale: made.locale)
			.write(to: out, atomically: true, encoding: .utf8)
		print("sidecar: \(out.path)")

		// A handful of times to check against the picture by hand.
		for index in stride(from: 0, to: made.transcript.count, by: 60) {
			let word = made.transcript.words[index]
			print(String(format: "  %@  %@", Timecode.string(word.start), word.text))
		}
	}

	/// The offset, proved against the camera's own microphone.
	///
	/// The take's words come from the separate recorder, eleven seconds out of
	/// step with the picture. The camera heard the same room at the same
	/// moments, on the video's clock by definition — so transcribing *its*
	/// track, which needs no offset at all, gives a second opinion that was
	/// arrived at independently. If the conversion were missing, dropped or
	/// inverted, the two would disagree by eleven seconds and this would say so
	/// in the first line it printed.
	///
	/// The camera microphone is across the room and mishears half of it, so
	/// this compares *when* speech starts after a pause and not what was said.
	@Test func theSameSpeechLandsAtTheSameVideoTimeFromEitherMicrophone() async throws {
		let base = takeURL.deletingLastPathComponent()
		let take = try TakeReader.read(try String(contentsOf: takeURL, encoding: .utf8))
		let video = try #require(take.video.map { URL(fileURLWithPath: $0, relativeTo: base) })
		let audio = try #require(take.audio.map { URL(fileURLWithPath: $0.file, relativeTo: base) })
		let offset = try #require(take.audio?.offset)
		let duration = try await MediaProbe.probe(video).duration

		let fromRecorder = try await Transcriber.transcribe(
			Transcriber.Source(url: audio, offset: offset, limit: 0 ... duration),
			locale: Locale(identifier: "de-DE")).transcript
		let fromCamera = try await Transcriber.transcribe(
			Transcriber.Source(url: video, offset: 0, limit: 0 ... duration),
			locale: Locale(identifier: "de-DE")).transcript

		// Where somebody starts speaking after a clear pause, in each.
		func onsets(_ transcript: Transcript, after gap: Double = 1.5) -> [Double] {
			var found: [Double] = []
			var previous: Double?
			for word in transcript.words {
				if previous == nil || word.start - previous! >= gap { found.append(word.start) }
				previous = word.end
			}
			return found
		}
		let mine = onsets(fromRecorder)
		let theirs = onsets(fromCamera)
		#expect(mine.count > 10)

		var differences: [Double] = []
		for time in mine {
			guard let nearest = theirs.min(by: { abs($0 - time) < abs($1 - time) }) else { continue }
			// Beyond a second is the two microphones having heard different
			// things, not the clock being out; eleven seconds of offset could
			// not hide inside this window.
			if abs(nearest - time) < 1 { differences.append(time - nearest) }
		}
		#expect(differences.count > 10)
		let sorted = differences.map(abs).sorted()
		let median = sorted[sorted.count / 2]
		print(String(format: "%d onsets agreed to a median of %.0f ms", sorted.count, median * 1000))
		#expect(median < 0.2)
	}
}
