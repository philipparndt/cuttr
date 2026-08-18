import Foundation
import Testing
@testable import CuttrKit

@Suite struct AudioAlignmentTests {

	/// A minute and a half of something that sounds like a room: mostly quiet,
	/// with transients scattered through it.
	///
	/// Generated rather than recorded, and deliberately: the property being
	/// tested is that a known offset comes back, and only a synthetic signal
	/// has a known offset. A real pair of recordings would test the aligner
	/// against somebody's guess about what the answer is.
	private func master(seconds: Double, rate: Double, seed: UInt64) -> [Float] {
		var state = seed
		func next() -> Double {
			// A plain LCG, so the fixture is the same on every machine and in
			// every Swift release. `Double.random` is neither.
			state = state &* 6364136223846793005 &+ 1442695040888963407
			return Double(state >> 11) / Double(1 << 53)
		}
		let count = Int(seconds * rate)
		var out = [Float](repeating: 0, count: count)
		var i = 0
		while i < count {
			// Room tone.
			out[i] = Float(next() * 0.02)
			i += 1
		}
		// Transients, at irregular intervals, each decaying over ~80 ms.
		var at = 0
		while at < count {
			at += Int((0.15 + next() * 1.2) * rate)
			guard at < count else { break }
			let peak = Float(0.3 + next() * 0.7)
			let length = Int((0.02 + next() * 0.06) * rate)
			for k in 0 ..< length where at + k < count {
				out[at + k] = max(out[at + k], peak * Float(exp(-Double(k) / (Double(length) / 3))))
			}
		}
		return out
	}

	/// A window of the master, as a recording of its own, through a microphone
	/// that is not the other one: different gain, and noise nobody else heard.
	private func recording(_ master: [Float], from: Int, count: Int, gain: Float, noise: Float, seed: UInt64) -> Waveform {
		var state = seed
		func next() -> Float {
			state = state &* 6364136223846793005 &+ 1442695040888963407
			return Float(Double(state >> 11) / Double(1 << 53))
		}
		var values = [Float](repeating: 0, count: count)
		for i in 0 ..< count {
			let source = from + i
			values[i] = (source >= 0 && source < master.count ? master[source] * gain : 0) + next() * noise
		}
		return Waveform(bucketsPerSecond: 1000, duration: Double(count) / 1000,
		                sampleRate: 48000, mins: values.map { -$0 }, maxs: values)
	}

	@Test func findsAPositiveOffsetToTheMillisecond() {
		let source = master(seconds: 90, rate: 1000, seed: 7)
		// The camera rolls first; the recorder is started 1.234 s later, so its
		// first sample belongs at video time +1.234.
		let video = recording(source, from: 0, count: 60_000, gain: 1.0, noise: 0.01, seed: 11)
		let audio = recording(source, from: 1234, count: 60_000, gain: 0.55, noise: 0.02, seed: 13)

		let result = AudioAligner.align(videoAudio: video, audio: audio)
		let alignment = try! #require(result)
		#expect(abs(alignment.offset - 1.234) <= 0.001, "got \(alignment.offset)")
		#expect(alignment.confidence > 0.5)
	}

	@Test func findsANegativeOffsetToo() {
		let source = master(seconds: 90, rate: 1000, seed: 21)
		let video = recording(source, from: 2000, count: 60_000, gain: 1.0, noise: 0.01, seed: 31)
		let audio = recording(source, from: 765, count: 60_000, gain: 1.4, noise: 0.01, seed: 37)
		// video index i is master i+2000; audio index j is master j+765.
		let expected = (765.0 - 2000.0) / 1000

		let alignment = try! #require(AudioAligner.align(videoAudio: video, audio: audio))
		#expect(abs(alignment.offset - expected) <= 0.001, "got \(alignment.offset)")
	}

	@Test func aBoundedSearchFindsTheSameAnswer() {
		let source = master(seconds: 90, rate: 1000, seed: 5)
		let video = recording(source, from: 3000, count: 60_000, gain: 1.0, noise: 0.01, seed: 41)
		let audio = recording(source, from: 2500, count: 60_000, gain: 1.0, noise: 0.01, seed: 43)

		let full = try! #require(AudioAligner.align(videoAudio: video, audio: audio))
		let bounded = try! #require(AudioAligner.align(videoAudio: video, audio: audio,
		                                              around: -0.4, searchRange: 0.5))
		#expect(abs(full.offset - bounded.offset) <= 0.001)
	}

	@Test func silenceHasNoAnswerRatherThanAConfidentWrongOne() {
		let flat = Waveform(bucketsPerSecond: 1000, duration: 30, sampleRate: 48000,
		                    mins: [Float](repeating: 0, count: 30_000),
		                    maxs: [Float](repeating: 0, count: 30_000))
		let source = master(seconds: 40, rate: 1000, seed: 3)
		let real = recording(source, from: 0, count: 30_000, gain: 1, noise: 0.01, seed: 9)
		#expect(AudioAligner.align(videoAudio: real, audio: flat) == nil)
	}

	@Test func aRecordingTooShortToProbeIsDeclinedRatherThanGuessed() {
		let source = master(seconds: 40, rate: 1000, seed: 4)
		let video = recording(source, from: 0, count: 30_000, gain: 1, noise: 0.01, seed: 8)
		let tiny = Waveform(bucketsPerSecond: 1000, duration: 0.005, sampleRate: 48000,
		                    mins: [0, 0, 0, 0, 0], maxs: [0.5, 0.2, 0.9, 0.1, 0.3])
		#expect(AudioAligner.align(videoAudio: video, audio: tiny) == nil)
	}
}
