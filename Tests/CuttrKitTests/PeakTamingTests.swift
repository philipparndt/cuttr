import Foundation
import Testing
@testable import CuttrKit

/// Finding the loud bits, on envelopes made here.
///
/// A synthesised envelope rather than a recording, because what is being tested
/// is the judgement and not the decoder: speech at one level with a door slam in
/// it is four lines of arithmetic to write down and is exactly the case the pass
/// exists for. What it *cannot* answer — whether the thresholds are right on
/// real audio — is `PeakTamingFootageTests`, and that one prints numbers rather
/// than asserting taste.
@Suite struct PeakTamingTests {

	private let rate = PeakTaming.rate

	/// Speech at a steady level, with bursts where asked for.
	///
	/// −24 dBFS for the talking and a burst at whatever is asked, which is how a
	/// plosive two inches from a microphone actually looks against a voice a
	/// metre away.
	private func envelope(
		seconds: Double, bursts: [(at: Double, seconds: Double, dB: Double)] = []
	) -> [Float] {
		var out = [Float](repeating: Float(Levelling.amplitude(-24)),
		                  count: Int(seconds * rate))
		for burst in bursts {
			let from = Int(burst.at * rate)
			let to = min(out.count, from + max(1, Int(burst.seconds * rate)))
			for bucket in from..<to { out[bucket] = Float(Levelling.amplitude(burst.dB)) }
		}
		return out
	}

	@Test func aSteadyTakeHasNoPeaks() {
		let found = PeakTaming.excursions(in: envelope(seconds: 20), ratePerSecond: rate)
		#expect(found.isEmpty)
	}

	/// The door in the hall: an eighth of a second, twenty decibels above the
	/// voice around it.
	@Test func aBurstIsFoundWhereItIs() throws {
		let found = PeakTaming.excursions(
			in: envelope(seconds: 20, bursts: [(at: 8, seconds: 0.12, dB: -4)]),
			ratePerSecond: rate)
		#expect(found.count == 1)
		let peak = try #require(found.first)
		#expect(abs(peak.start - 8) < 0.02)
		#expect(abs(peak.end - 8.12) < 0.02)
		#expect(abs(peak.excess - 20) < 0.5)
	}

	/// Somebody getting louder is not a peak. This is the difference between a
	/// repair and a decision about the performance, and the only thing that
	/// tells them apart is how long it goes on for.
	@Test func aLoudStretchIsNotAPeak() {
		let found = PeakTaming.excursions(
			in: envelope(seconds: 40, bursts: [(at: 10, seconds: 8, dB: -4)]),
			ratePerSecond: rate)
		#expect(found.isEmpty)
	}

	/// A take that drifts — somebody walks away from the microphone and comes
	/// back — is measured against the level *around* each moment, so the quiet
	/// half is not one long excursion and a plop in it is still found.
	@Test func aDriftingTakeIsMeasuredLocally() throws {
		var envelope = self.envelope(seconds: 60)
		for bucket in 0..<Int(20 * rate) { envelope[bucket] = Float(Levelling.amplitude(-36)) }
		// A plop in the quiet half, sixteen decibels over *that* level and four
		// decibels under the loud half's ordinary speech.
		for bucket in Int(10 * rate)..<Int(10.1 * rate) {
			envelope[bucket] = Float(Levelling.amplitude(-20))
		}
		let found = PeakTaming.excursions(in: envelope, ratePerSecond: rate)
		#expect(found.count == 1)
		#expect(abs((found.first?.start ?? 0) - 10) < 0.05)
	}

	/// A flicker in the middle of a slam is one slam. Merged before the length
	/// is judged, or a long one would be read as a run of short ones.
	@Test func twoKnocksCloseTogetherAreOne() {
		let found = PeakTaming.excursions(
			in: envelope(seconds: 20, bursts: [(at: 8, seconds: 0.08, dB: -4),
			                                   (at: 8.12, seconds: 0.08, dB: -4)]),
			ratePerSecond: rate)
		#expect(found.count == 1)
	}

	// MARK: - What is proposed

	@Test func aDipIsFourPointsAroundThePeak() throws {
		let curve = PeakTaming.propose(over: waveform(seconds: 20, at: 8, dB: -4))
		#expect(curve.count == 4)
		// Down, along, along, up: back where it was on both sides, so nothing
		// outside the shoulders is touched.
		#expect(abs(curve[0].gain) < 1e-9)
		#expect(abs(curve[3].gain) < 1e-9)
		#expect(curve[1].gain == curve[2].gain)
		#expect(curve[1].gain < -10)
		// The shoulders are short — forty milliseconds — or the words either
		// side would be ducked with the door.
		#expect(abs((curve[1].at - curve[0].at) - 0.04) < 0.005)
		#expect(abs((curve[3].at - curve[2].at) - 0.04) < 0.005)
		#expect(curve.map(\.at) == curve.map(\.at).sorted())
	}

	/// The peak comes down to where it can be heard and no further. Flattening
	/// it into the speech would sound like a fault of its own.
	@Test func thePeakIsBroughtDownAndNotFlattened() throws {
		let curve = PeakTaming.propose(over: waveform(seconds: 20, at: 8, dB: -4))
		let cut = try #require(curve.map(\.gain).min())
		// Twenty decibels over, eight left standing: twelve off.
		#expect(abs(cut + 12) < 1)
	}

	/// Rounded to what the file can hold, so accepting a proposal does not leave
	/// a document that looks edited the moment it is saved.
	@Test func theNumbersAreWhatTheFileHolds() throws {
		let curve = PeakTaming.propose(over: waveform(seconds: 20, at: 8.3456, dB: -4))
		for point in curve {
			#expect(abs(point.at * 1000 - (point.at * 1000).rounded()) < 1e-9)
			#expect(abs(point.gain * 10 - (point.gain * 10).rounded()) < 1e-9)
		}
		let take = Take(video: "a.mov", levels: curve)
		#expect(try TakeReader.read(TakeWriter.write(take)).levels == curve)
	}

	/// A curve somebody has already drawn is kept, and the dips are added to it
	/// — the shoulders come back to whatever it says there rather than to nought.
	@Test func itComposesWithACurveAlreadyThere() throws {
		let existing = [LevelPoint(at: 0, gain: -3), LevelPoint(at: 20, gain: -3)]
		let curve = PeakTaming.propose(
			over: waveform(seconds: 20, at: 8, dB: -4), existing: existing)
		#expect(curve.count == existing.count + 4)
		#expect(curve.contains(existing[0]))
		let shoulder = try #require(curve.first { abs($0.at - 7.96) < 0.01 })
		#expect(abs(shoulder.gain + 3) < 0.05)
		let floor = try #require(curve.map(\.gain).min())
		#expect(abs(floor + 15) < 1)
	}

	/// And a peak somebody has already dealt with is left alone: a second pass
	/// over the same take is not a second dip, because the envelope still shows
	/// the plop after the mix has taken it out.
	@Test func aSecondPassProposesNothing() {
		let wave = waveform(seconds: 20, at: 8, dB: -4)
		let once = PeakTaming.propose(over: wave)
		let twice = PeakTaming.propose(over: wave, existing: once)
		#expect(twice == once)
	}

	/// The recorder's clock is not the video's, and a curve is on the video's.
	@Test func theOffsetPutsTheDipOnTheVideosClock() throws {
		let curve = PeakTaming.propose(over: waveform(seconds: 20, at: 8, dB: -4), shift: 11)
		let deepest = try #require(curve.min { $0.gain < $1.gain })
		#expect(abs(deepest.at - 19) < 0.05)
	}

	/// Two decibels off eighty milliseconds is four lines in a file nobody can
	/// hear the difference from.
	@Test func aPeakNotWorthTamingIsNotProposed() {
		#expect(PeakTaming.propose(over: waveform(seconds: 20, at: 8, dB: -14)).isEmpty)
	}

	/// An envelope, at the rate the pass reads one at, so the arithmetic above
	/// can be driven through the public way in as well.
	private func waveform(seconds: Double, at: Double, dB: Double) -> Waveform {
		let envelope = self.envelope(seconds: seconds,
		                            bursts: [(at: at, seconds: 0.12, dB: dB)])
		return Waveform(bucketsPerSecond: rate, duration: seconds, sampleRate: 48000,
		                mins: envelope.map { -$0 }, maxs: envelope)
	}
}
