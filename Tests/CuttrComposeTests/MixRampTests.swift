@preconcurrency import AVFoundation
import CuttrKit
import Foundation
import Testing
@testable import CuttrCompose

/// Two instructions on the same stretch of one lane.
///
/// A lane is written to as a list of ramps, and until this was fixed the list
/// was written straight out in whatever order a sort left it in. AVFoundation
/// has two opinions about that, and both of them are worse than they look: two
/// ramps that overlap raise an Objective-C exception — which is not an error a
/// build can catch, it is the window going away — and two that merely begin
/// together are taken silently, one replacing the other, so which of a dissolve
/// and the level it dissolves from was heard came down to the sort.
///
/// The crash was real and was reported from a cut: a piece of music set to duck
/// the programme under it, and a dissolve inside the stretch where the duck
/// fades back up.
@Suite struct MixRampTests {

	// MARK: - Media, made here

	/// A few seconds of black with no sound of its own.
	private func silentVideo(at url: URL, seconds: Double) async throws {
		let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
		let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
			AVVideoCodecKey: AVVideoCodecType.h264,
			AVVideoWidthKey: 64, AVVideoHeightKey: 36,
		])
		input.expectsMediaDataInRealTime = false
		let adaptor = AVAssetWriterInputPixelBufferAdaptor(
			assetWriterInput: input,
			sourcePixelBufferAttributes: [
				kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
			])
		writer.add(input)
		writer.startWriting()
		writer.startSession(atSourceTime: .zero)
		var buffer: CVPixelBuffer?
		CVPixelBufferCreate(nil, 64, 36, kCVPixelFormatType_32BGRA, nil, &buffer)
		let frames = Int(seconds * 25)
		if let buffer {
			for frame in 0..<frames {
				while !input.isReadyForMoreMediaData {
					try? await Task.sleep(nanoseconds: 1_000_000)
				}
				adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 25))
			}
		}
		input.markAsFinished()
		writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frames), timescale: 25))
		await writer.finishWriting()
	}

	/// A tone, as a WAV — the same hand-written header `MixTests` uses, for the
	/// same reason: this only has to be something with audio in it.
	private func tone(at url: URL, seconds: Double) throws {
		let rate = 44100
		let count = Int(Double(rate) * seconds)
		var data = Data()
		func put(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
		func put32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
		func put16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
		put("RIFF"); put32(UInt32(36 + count * 2)); put("WAVE")
		put("fmt "); put32(16); put16(1); put16(1)
		put32(UInt32(rate)); put32(UInt32(rate * 2)); put16(2); put16(16)
		put("data"); put32(UInt32(count * 2))
		for sample in 0..<count {
			let value = Int16(sin(2 * .pi * 440 * Double(sample) / Double(rate)) * 8000)
			put16(UInt16(bitPattern: value))
		}
		try data.write(to: url)
	}

	/// A take whose sound is the recorder's, so every clip on the programme has
	/// a level of its own — and, where the test asks for one, a gain curve.
	private func fixture(levels: [LevelPoint] = []) async throws -> URL {
		let directory = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("cuttr-ramps-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		try await silentVideo(at: directory.appendingPathComponent("silent.mov"), seconds: 6)
		try tone(at: directory.appendingPathComponent("rec.wav"), seconds: 6)
		try tone(at: directory.appendingPathComponent("music.wav"), seconds: 8)
		try TakeWriter.write(Take(
			video: "silent.mov", audio: AudioTrack(file: "rec.wav", offset: 0),
			clips: [Clip(slug: "one", start: 0, end: 2), Clip(slug: "two", start: 2, end: 4)],
			levels: levels))
			.write(to: directory.appendingPathComponent("t.cuttr"),
			       atomically: true, encoding: .utf8)
		return directory
	}

	private func build(_ text: String, in directory: URL) async throws -> Renderer.Built {
		let project = try ProjectReader.read("takes: [t.cuttr]\n" + text)
		return try await Renderer.build(try Resolver.resolve(project, baseURL: directory),
		                                host: .export)
	}

	// MARK: - Reading the mix back

	/// Every ramp on one lane, in order, read out of the parameters rather than
	/// out of the code that wrote them.
	private func ramps(of input: AVAudioMixInputParameters)
		-> [(start: Double, end: Double, from: Float, to: Float)] {
		var found: [(start: Double, end: Double, from: Float, to: Float)] = []
		var at = CMTime.zero
		let limit = CMTime(seconds: 60, preferredTimescale: 600)
		while at < limit {
			var from: Float = 0
			var to: Float = 0
			var range = CMTimeRange.zero
			guard input.getVolumeRamp(for: at, startVolume: &from, endVolume: &to,
			                          timeRange: &range), range.duration > .zero
			else {
				at = at + CMTime(value: 1, timescale: 600)
				continue
			}
			found.append((range.start.seconds, range.end.seconds, from, to))
			at = range.end
		}
		return found
	}

	/// The one thing a mix must never be: two ramps arguing over the same
	/// moment. AVFoundation refuses this by raising, so a mix that has it is a
	/// crash rather than a wrong level.
	private func expectNoOverlaps(_ mix: AVAudioMix, _ comment: Comment) {
		for input in mix.inputParameters {
			let written = ramps(of: input)
			for (index, ramp) in written.enumerated().dropFirst()
			where ramp.start < written[index - 1].end - 1e-9 {
				Issue.record("\(comment): \(written[index - 1]) and \(ramp) overlap")
			}
		}
	}

	// MARK: - The crash

	/// **The report.** Music ducking the programme, and a dissolve inside the
	/// stretch where the duck fades back up. The duck's ramp and the dissolve's
	/// are on the same lane and neither contains the other, which used to abort
	/// the process from inside `Renderer.build` — a preview, and then no window.
	@Test func aDissolveInsideADuckFadingBackUpIsStillOneMix() async throws {
		let directory = try await fixture()
		defer { try? FileManager.default.removeItem(at: directory) }
		let built = try await build("""
		timeline:
		  - one
		  - clip: two
		    transition: 0.5
		  - one
		sounds:
		  - file:  music.wav
		    from:  00:00.000
		    to:    00:02.200
		    ducks: 8
		    out:   {fade: true, over: 1.5}
		""", in: directory)
		let mix = try #require(built.audioMix)
		expectNoOverlaps(mix, "a dissolve inside a duck's fade")
	}

	/// The same shape from the other side: a take with a gain curve on it
	/// dissolving into the next shot. The curve covers the clip end to end and
	/// the dissolve starts inside it, because a dissolve *is* the two clips
	/// overlapping.
	@Test func aCurvedTakeDissolvingOutIsStillOneMix() async throws {
		let directory = try await fixture(levels: [
			LevelPoint(at: 0.5, gain: 0),
			LevelPoint(at: 1.0, gain: -12),
			LevelPoint(at: 3.5, gain: -12),
			LevelPoint(at: 3.9, gain: 0),
		])
		defer { try? FileManager.default.removeItem(at: directory) }
		let built = try await build("""
		timeline:
		  - one
		  - clip: two
		    transition: 0.5
		""", in: directory)
		let mix = try #require(built.audioMix)
		expectNoOverlaps(mix, "a dissolve inside a gain curve")
	}

	// MARK: - What is heard where two instructions meet

	/// A dissolve and the level it dissolves from begin at the same moment, and
	/// the dissolve is the one that was asked for there. Taken silently by
	/// AVFoundation either way, so this is not about crashing: it is about the
	/// incoming shot coming up from nothing rather than arriving at full.
	@Test func aDissolveIsHeardOverTheLevelThatStartsWithIt() async throws {
		let directory = try await fixture()
		defer { try? FileManager.default.removeItem(at: directory) }
		let built = try await build("""
		timeline:
		  - one
		  - clip: two
		    transition: 0.5
		""", in: directory)
		let mix = try #require(built.audioMix)
		expectNoOverlaps(mix, "a dissolve at a cut")
		// The incoming shot starts at 1.5 — half a second before the outgoing
		// one ends — and comes up across exactly that half second.
		let up = mix.inputParameters.flatMap { ramps(of: $0) }.first {
			abs($0.start - 1.5) < 1e-3 && $0.from < 0.01
		}
		let coming = try #require(up, "the incoming lane is taken up from nothing")
		#expect(abs(coming.end - 2.0) < 1e-3)
		#expect(coming.to > 0.99)
		// And the level it was taken up to is then held, rather than the lane
		// being left wherever the dissolve stopped.
		let held = mix.inputParameters.flatMap { ramps(of: $0) }.first {
			$0.start > 1.99 && $0.from > 0.99 && $0.to > 0.99
		}
		#expect(held != nil)
	}
}
