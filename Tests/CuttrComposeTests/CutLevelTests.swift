@preconcurrency import AVFoundation
import CuttrKit
import Foundation
import Testing
@testable import CuttrCompose

/// The level at a cut between two shots levelled differently.
///
/// The audio renderer does not step a volume: a change written at the cut is
/// smoothed across roughly the next render buffer, so a loud shot followed by a
/// quiet one used to play the first fraction of the quiet shot at the loud
/// shot's level — a burst at every such cut, heard from a real programme where
/// one recording sat at +20 dB and the next at −12. The two shots go on two
/// lanes now and each lane is put at its level while it is carrying nothing,
/// which is what these check — on the mix, and then on the file that comes
/// out, because the smoothing is the encoder's and not the mix's.
@Suite struct CutLevelTests {

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

	/// A steady tone, so that any change in what comes out is the mix's.
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

	/// One recording, two clips of it: the first as it is, the second thirty
	/// decibels down.
	private func fixture() async throws -> URL {
		let directory = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("cuttr-cutlevel-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		try await silentVideo(at: directory.appendingPathComponent("black.mov"), seconds: 6)
		try tone(at: directory.appendingPathComponent("rec.wav"), seconds: 6)
		try TakeWriter.write(Take(
			video: "black.mov", audio: AudioTrack(file: "rec.wav"),
			clips: [Clip(slug: "loud", start: 0, end: 2),
			        Clip(slug: "quiet", start: 2, end: 4, gain: -30)]))
			.write(to: directory.appendingPathComponent("t.cuttr"),
			       atomically: true, encoding: .utf8)
		return directory
	}

	private func resolve(_ directory: URL, _ timeline: String = "[loud, quiet]") throws -> ResolvedProject {
		let project = try ProjectReader.read("takes: [t.cuttr]\ntimeline: \(timeline)\n")
		return try Resolver.resolve(project, baseURL: directory)
	}

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

	/// The two shots are on two lanes, and the quiet one's lane is already at
	/// its level well before the cut — with nothing on the lane to hear it
	/// change through.
	@Test func theIncomingLevelIsSetWhileItsLaneIsEmpty() async throws {
		let directory = try await fixture()
		defer { try? FileManager.default.removeItem(at: directory) }
		let built = try await Renderer.build(try resolve(directory), host: .export)
		let audio = built.composition.tracks(withMediaType: .audio)
		#expect(audio.count == 2)
		let mix = try #require(built.audioMix)
		let quiet = Float(Levelling.amplitude(-30))
		// The lane the quiet shot is on: silent, then at the quiet level from
		// the settling before the cut, and unchanged through it.
		let lane = try #require(mix.inputParameters.first { input in
			ramps(of: input).contains { abs($0.to - quiet) < 1e-4 }
		})
		let written = ramps(of: lane)
		let arrives = try #require(written.first { abs($0.to - quiet) < 1e-4 })
		#expect(abs(arrives.start - (2 - Renderer.settling)) < 1e-3,
		        "the level was put on the lane at \(arrives.start)")
		#expect(abs(arrives.from - quiet) < 1e-4, "and it was put there as a step, not a ramp")
		#expect(!written.contains { $0.start > 1.5 && $0.start < 2.5 && $0.from > quiet * 1.01 },
		        "nothing on the quiet lane changes level at the cut: \(written)")
		// And the lane before it: only silence, at nought.
		let before = written.filter { $0.end <= 2 - Renderer.settling + 1e-6 }
		#expect(before.allSatisfy { $0.from == 0 && $0.to == 0 })
	}

	/// **The measurement.** What comes out of the encoder, either side of the
	/// cut: the head of the quiet shot is as quiet as the rest of it, and the
	/// tail of the loud shot is as loud as the rest of *it* — the change was
	/// not bought by fading the loud shot out early.
	@Test func theQuietShotIsQuietFromItsFirstMoment() async throws {
		let directory = try await fixture()
		defer { try? FileManager.default.removeItem(at: directory) }
		let out = directory.appendingPathComponent("out.mov")
		try await Renderer.export(try resolve(directory), to: out)
		let wave = try await WaveformExtractor.extract(url: out, bucketsPerSecond: 100)
		func peak(_ from: Double, _ to: Double) -> Float {
			wave.extremes(from: from, to: to).map { max(abs($0.min), abs($0.max)) } ?? 0
		}
		let loudBody = peak(0.5, 1.5)
		let loudTail = peak(1.85, 1.99)
		let quietHead = peak(2.01, 2.2)
		let quietBody = peak(2.5, 3.5)
		#expect(quietBody > 0, "the quiet shot is there")
		#expect(quietBody < loudBody / 20, "and it is thirty decibels down: \(quietBody) vs \(loudBody)")
		// Before the fix the head measured eight times the body.
		#expect(quietHead < quietBody * 1.5,
		        "the head of the quiet shot is \(quietHead), its body \(quietBody)")
		#expect(loudTail > loudBody * 0.7,
		        "the tail of the loud shot is \(loudTail), its body \(loudBody)")
	}
}
