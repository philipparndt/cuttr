import Foundation
import Testing
@testable import CuttrKit

/// Finding where the talking starts and stops in an envelope.
@Suite struct SpeechEdgeTests {

	/// A recording with `bursts` of sound in a quiet room, at 1 ms buckets.
	private func made(_ bursts: [(start: Double, end: Double)], duration: Double = 10) -> Waveform {
		let count = Int(duration * 1000)
		var peaks = [Float](repeating: 0.001, count: count)   // the room
		for burst in bursts {
			for bucket in Int(burst.start * 1000) ..< Int(burst.end * 1000)
			where bucket >= 0 && bucket < count {
				peaks[bucket] = 0.3
			}
		}
		return Waveform(bucketsPerSecond: 1000, duration: duration, sampleRate: 48000,
		                mins: peaks.map { -$0 }, maxs: peaks)
	}

	@Test func aBurstOfSoundHasTwoEdges() {
		let edges = SpeechEdges.edges(in: made([(2.0, 3.0)]))
		#expect(edges.count == 2)
		#expect(abs((edges.first ?? 0) - 2.0) < 0.03)
		#expect(abs((edges.last ?? 0) - 3.0) < 0.03)
	}

	/// A gap shorter than the resting time is inside a sentence, not the end of
	/// one — otherwise every stop between two German words earns a mark.
	@Test func aShortGapIsNotAnEdge() {
		let edges = SpeechEdges.edges(in: made([(2.0, 3.0), (3.1, 4.0)]))
		#expect(edges.count == 2)
		#expect(abs((edges.last ?? 0) - 4.0) < 0.03)
	}

	@Test func aLongGapIsTwoRunsAndFourEdges() {
		let edges = SpeechEdges.edges(in: made([(2.0, 3.0), (4.0, 5.0)]))
		#expect(edges.count == 4)
	}

	/// A click, a chair, a door: too short to be somebody talking.
	@Test func somethingBriefIsNotTalking() {
		#expect(SpeechEdges.edges(in: made([(2.0, 2.05)])).isEmpty)
	}

	/// Nothing to find is nothing to offer, rather than marks at whatever the
	/// arithmetic happened to produce.
	@Test func aQuietRecordingHasNoEdges() {
		#expect(SpeechEdges.edges(in: made([])).isEmpty)
	}

	/// The recorder's own clock is not the video's, and the whole point of
	/// taking a shift is that the mark lands where the shape is drawn.
	@Test func theEdgesComeBackOnTheClockThatWasAskedFor() {
		let plain = SpeechEdges.edges(in: made([(2.0, 3.0)]))
		let shifted = SpeechEdges.edges(in: made([(2.0, 3.0)]), shift: -11.093)
		#expect(zip(plain, shifted).allSatisfy { abs($0 - $1 - 11.093) < 0.0001 })
	}
}
