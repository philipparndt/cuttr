import AVFoundation
import Foundation
import Testing
@testable import CuttrKit

/// The decode path, against files a decoder actually opens.
///
/// The aligner's own tests hand it arrays. These write two real WAVs and go
/// through `AVAssetReader`, which is where the bucket arithmetic, the carry
/// across sample buffers and the mono mixdown live — none of which an array can
/// exercise, and all of which are the kind of thing that is off by one frame in
/// a way nobody notices until an alignment is out by a bucket.
@Suite struct WaveformExtractorTests {

	@Test func decodesAFileAndAlignsTwoOfThem() async throws {
		let directory = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("cuttr-waveform-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }

		let rate = 48000.0
		let master = Fixture.master(seconds: 45, rate: rate, seed: 4)
		// The camera rolls first; the recorder starts 1.234 s later, quieter,
		// and hears noise the camera does not.
		let cameraURL = directory.appendingPathComponent("camera.wav")
		let micURL = directory.appendingPathComponent("mic.wav")
		try Fixture.writeWAV(Fixture.window(master, from: 0, seconds: 30, rate: rate, gain: 1.0, noise: 0.008, seed: 11),
		                     rate: rate, to: cameraURL)
		try Fixture.writeWAV(Fixture.window(master, from: 1.234, seconds: 30, rate: rate, gain: 0.55, noise: 0.02, seed: 13),
		                     rate: rate, to: micURL)

		let camera = try await WaveformExtractor.extract(url: cameraURL)
		let mic = try await WaveformExtractor.extract(url: micURL)

		#expect(abs(camera.duration - 30) < 0.01)
		#expect(abs(camera.bucketsPerSecond - 1000) < 1)
		#expect(camera.sampleRate == rate)
		#expect(camera.bucketCount == mic.bucketCount)
		// Something was actually decoded, rather than thirty seconds of zeroes.
		#expect(camera.maxs.max()! > 0.3)

		let alignment = try #require(AudioAligner.align(videoAudio: camera, audio: mic))
		#expect(abs(alignment.offset - 1.234) <= 0.002, "got \(alignment.offset)")
		#expect(alignment.confidence > 0.5)
	}

	@Test func aFileWithNoAudioIsRefusedByName() async throws {
		let url = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("cuttr-empty-\(UUID().uuidString).wav")
		try Data().write(to: url)
		defer { try? FileManager.default.removeItem(at: url) }
		await #expect(throws: WaveformError.self) {
			_ = try await WaveformExtractor.extract(url: url)
		}
	}

	enum Fixture {
		/// Room tone with irregular decaying bursts in it — aperiodic, so the
		/// correlation has exactly one answer. A tone, or anything with a
		/// period, matches equally well at every multiple of it.
		static func master(seconds: Double, rate: Double, seed: UInt64) -> [Float] {
			var state = seed
			func next() -> Double {
				state = state &* 6364136223846793005 &+ 1442695040888963407
				return Double(state >> 11) / Double(1 << 53)
			}
			let count = Int(seconds * rate)
			var out = (0 ..< count).map { _ in Float((next() - 0.5) * 0.02) }
			var at = 0.0
			while at < seconds {
				at += 0.25 + next() * 1.35
				let start = Int(at * rate)
				guard start < count else { break }
				let frequency = 180 + next() * 2000
				let length = Int((0.03 + next() * 0.15) * rate)
				let amplitude = 0.3 + next() * 0.6
				for k in 0 ..< length where start + k < count {
					let decay = exp(-Double(k) / (Double(length) / 4))
					out[start + k] += Float(amplitude * decay * sin(2 * .pi * frequency * Double(k) / rate))
				}
			}
			return out
		}

		static func window(_ master: [Float], from: Double, seconds: Double, rate: Double,
		                   gain: Float, noise: Float, seed: UInt64) -> [Float] {
			var state = seed
			func next() -> Float {
				state = state &* 6364136223846793005 &+ 1442695040888963407
				return Float(Double(state >> 11) / Double(1 << 53)) - 0.5
			}
			let offset = Int(from * rate)
			return (0 ..< Int(seconds * rate)).map { i in
				let j = offset + i
				let value = (j >= 0 && j < master.count ? master[j] * gain : 0) + next() * noise * 2
				return max(-1, min(1, value))
			}
		}

		/// A 16-bit mono WAV, written by hand. The alternative is
		/// `AVAudioFile`, which would test that AVFoundation can read what
		/// AVFoundation wrote.
		static func writeWAV(_ samples: [Float], rate: Double, to url: URL) throws {
			var data = Data()
			func append<T>(_ value: T) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
			let byteCount = UInt32(samples.count * 2)
			data.append(contentsOf: Array("RIFF".utf8))
			append(UInt32(36 + byteCount))
			data.append(contentsOf: Array("WAVEfmt ".utf8))
			append(UInt32(16))              // PCM header length
			append(UInt16(1))               // format: PCM
			append(UInt16(1))               // channels
			append(UInt32(rate))
			append(UInt32(rate) * 2)        // bytes a second
			append(UInt16(2))               // block align
			append(UInt16(16))              // bits a sample
			data.append(contentsOf: Array("data".utf8))
			append(byteCount)
			for sample in samples { append(Int16(max(-1, min(1, sample)) * 32000)) }
			try data.write(to: url)
		}
	}
}
