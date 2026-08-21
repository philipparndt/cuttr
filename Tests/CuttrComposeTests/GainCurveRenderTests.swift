@preconcurrency import AVFoundation
import CuttrKit
import Foundation
import Testing
@testable import CuttrCompose

/// A take's gain curve, on the programme and in the file that comes out.
///
/// The resolver's half is arithmetic and is checked as arithmetic. The render's
/// half is not: `setVolumeRamp` either does what it says over the range it is
/// given or it does not, and the only way to find out is to encode a burst,
/// measure it, and compare it with the same burst rendered without the curve.
/// That is what the last test here does, and it is the one that would catch a
/// ramp written on the wrong lane or against the wrong clock.
@Suite struct GainCurveRenderTests {

	// MARK: - Media, made here

	/// A tone with a loud burst in the middle of it, as a WAV.
	///
	/// Written by hand for the reason `MixTests` gives: a header and some
	/// samples is less machinery than an encoder, and this has to be something
	/// with a known shape rather than something musical.
	private func tone(at url: URL, seconds: Double, burst: ClosedRange<Double>) throws {
		let rate = 48000
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
			let at = Double(sample) / Double(rate)
			// −26 dBFS for the tone, −6 for the burst: twenty decibels apart,
			// which is about what a door in a room is against a voice in it.
			let level = burst.contains(at) ? 0.5 : 0.05
			let value = Int16(sin(2 * .pi * 220 * at) * level * 32000)
			put16(UInt16(bitPattern: value))
		}
		try data.write(to: url)
	}

	/// A few seconds of black with no audio of its own, so the only sound in the
	/// programme is the recorder's.
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

	private func fixture(levels: [LevelPoint], clipGain: Double = 0,
	                     takeGain: Double = 0) async throws -> URL {
		let directory = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("cuttr-curve-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		try await silentVideo(at: directory.appendingPathComponent("black.mov"), seconds: 6)
		try tone(at: directory.appendingPathComponent("rec.wav"), seconds: 6, burst: 2 ... 2.5)
		var take = Take(
			video: "black.mov", audio: AudioTrack(file: "rec.wav"),
			clips: [Clip(slug: "all", start: 0, end: 6, gain: clipGain)],
			levels: levels)
		take.gain = takeGain
		try TakeWriter.write(take).write(to: directory.appendingPathComponent("t.cuttr"),
		                                atomically: true, encoding: .utf8)
		return directory
	}

	private func resolve(_ directory: URL) throws -> ResolvedProject {
		let project = try ProjectReader.read("takes: [t.cuttr]\ntimeline: [all]\n")
		return try Resolver.resolve(project, baseURL: directory)
	}

	/// The dip over the burst: down over forty milliseconds, twelve decibels off
	/// for the length of it, back up.
	private let dip = [
		LevelPoint(at: 1.96, gain: 0),
		LevelPoint(at: 2.0, gain: -12),
		LevelPoint(at: 2.5, gain: -12),
		LevelPoint(at: 2.54, gain: 0),
	]

	// MARK: - On the programme's clock

	/// The curve arrives on the clip, on the programme's clock, cut to the clip.
	@Test func theCurveComesThroughOnTheProgrammesClock() async throws {
		let directory = try await fixture(levels: dip)
		defer { try? FileManager.default.removeItem(at: directory) }
		let clip = try #require(try resolve(directory).clips.first)
		#expect(clip.levels.count == dip.count + 2)   // a point at each edge
		#expect(clip.levels.first?.at == 0)
		#expect(clip.levels.last?.at == 6)
		#expect(abs(clip.level(at: 2.2) + 12) < 1e-6)
		#expect(abs(clip.level(at: 4)) < 1e-6)
	}

	/// The same clip used twice carries the same repair at two different moments
	/// of the finished programme — which is the whole reason the curve belongs to
	/// the take and not to a project.
	@Test func aClipUsedTwiceCarriesTheDipTwice() async throws {
		let directory = try await fixture(levels: dip)
		defer { try? FileManager.default.removeItem(at: directory) }
		let project = try ProjectReader.read("takes: [t.cuttr]\ntimeline: [all, all]\n")
		let clips = try Resolver.resolve(project, baseURL: directory).clips
		#expect(clips.count == 2)
		#expect(abs(clips[0].level(at: 2.2) + 12) < 1e-6)
		// The second placement starts six seconds in, so its dip is there.
		#expect(abs(clips[1].level(at: 8.2) + 12) < 1e-6)
		#expect(abs(clips[1].level(at: 2.2)) < 1e-6)
	}

	/// All three levels add, in the one place the sum is written down.
	@Test func theThreeLevelsAddOnTheProgramme() async throws {
		let directory = try await fixture(levels: dip, clipGain: -1, takeGain: -3)
		defer { try? FileManager.default.removeItem(at: directory) }
		let clip = try #require(try resolve(directory).clips.first)
		#expect(abs(clip.gain + 4) < 1e-9)
		#expect(abs(clip.level(at: 2.2) + 16) < 1e-6)
	}

	/// A take with no curve builds exactly the mix it always built: one level
	/// per clip, and no mix at all when every level is one.
	@Test func noCurveIsTheMixItAlwaysWas() async throws {
		let directory = try await fixture(levels: [])
		defer { try? FileManager.default.removeItem(at: directory) }
		let built = try await Renderer.build(try resolve(directory), host: .export)
		#expect(built.audioMix == nil)
	}

	/// And a curve makes one, with ramps on the lane the sound is on.
	@Test func aCurveBuildsAMixWithRampsInIt() async throws {
		let directory = try await fixture(levels: dip)
		defer { try? FileManager.default.removeItem(at: directory) }
		let built = try await Renderer.build(try resolve(directory), host: .export)
		let mix = try #require(built.audioMix)
		#expect(mix.inputParameters.count == 1)
	}

	// MARK: - What comes out of the encoder

	/// **The measurement.** A burst twenty decibels over the tone around it, a
	/// dip drawn over exactly the burst, and then the file that comes out is
	/// listened to: the burst has to come down by about what the curve says, and
	/// the rest of the programme must not have moved.
	///
	/// Both renders are measured rather than the numbers being predicted,
	/// because what is being checked is `setVolumeRamp` and the encoder — an
	/// argument about how loud a tone *ought* to be would pass with the ramp on
	/// the wrong lane.
	@Test func theBurstComesDownAndTheRestDoesNot() async throws {
		let plain = try await fixture(levels: [])
		let curved = try await fixture(levels: dip)
		defer {
			try? FileManager.default.removeItem(at: plain)
			try? FileManager.default.removeItem(at: curved)
		}
		let before = plain.appendingPathComponent("out.mov")
		let after = curved.appendingPathComponent("out.mov")
		try await Renderer.export(try resolve(plain), to: before)
		try await Renderer.export(try resolve(curved), to: after)

		let burst = 2.05 ... 2.45
		let rest = 3.5 ... 5.5
		let burstBefore = try #require(
			try await LoudnessMeter.measure(url: before, ranges: [burst]).integrated)
		let burstAfter = try #require(
			try await LoudnessMeter.measure(url: after, ranges: [burst]).integrated)
		let restBefore = try #require(
			try await LoudnessMeter.measure(url: before, ranges: [rest]).integrated)
		let restAfter = try #require(
			try await LoudnessMeter.measure(url: after, ranges: [rest]).integrated)

		// The burst is down by the twelve decibels the curve asked for, within
		// what the ramps at its edges and a lossy encoder account for.
		#expect(abs((burstBefore - burstAfter) - 12) < 1.5,
		        "the burst went from \(burstBefore) to \(burstAfter) LUFS")
		// And the rest of the programme is exactly where it was, which is the
		// half that a curve applied to the whole take would fail.
		#expect(abs(restBefore - restAfter) < 0.3,
		        "the rest went from \(restBefore) to \(restAfter) LUFS")
	}
}
