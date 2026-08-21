import Foundation
import Testing
@testable import CuttrKit

/// Taming the peaks of a real recording, on the machine it was measured on.
///
/// Off by default and not part of the suite, for the reason
/// ``SoundFootageTests`` gives: it needs footage that is not in this repository
/// and cannot be. What it answers is the question the synthesised envelopes
/// cannot — are the thresholds right on a family's recording of children in a
/// room, where the loud moment is a chair going over and the quiet one is
/// somebody two metres from the microphone.
///
/// ```
/// CUTTR_FOOTAGE=/Volumes/500G/DorisWalter70/mia-take-1.cuttr \
///   xcrun swift test --filter PeakTamingFootageTests
/// ```
///
/// **How it is scored.** With the *loudness* meter rather than with the peak
/// envelope the proposal was made from — a second opinion from a different
/// measurement, which is the only kind worth having. Three questions, and three
/// decodes rather than three per dip, because `LoudnessMeter` reads the whole
/// file however narrow the span asked about: how loud the take is, how loud the
/// moments the pass picked are, and how loud the two seconds either side of them
/// are. Moments that are not louder than their own surroundings are false
/// positives whatever the envelope thought, and the gap between the second and
/// third figures is the thing the pass claims to have found.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CUTTR_FOOTAGE"] != nil))
struct PeakTamingFootageTests {

	private var takeURL: URL {
		URL(fileURLWithPath: ProcessInfo.processInfo.environment["CUTTR_FOOTAGE"]!)
	}

	@Test func theProposedDipsAreOverTheLoudBits() async throws {
		let base = takeURL.deletingLastPathComponent()
		let take = try TakeReader.read(try String(contentsOf: takeURL, encoding: .utf8))
		// The audio somebody will actually hear, and the clock it is on: the
		// separate recorder when there is one, with the take's own offset
		// relating it to the video's clock.
		let external = take.audio.map { URL(fileURLWithPath: $0.file, relativeTo: base) }
		let url = try #require(external ?? take.video.map { URL(fileURLWithPath: $0, relativeTo: base) })
		let shift = external != nil ? (take.audio?.offset ?? 0) : 0

		let started = Date()
		let wave = try await WaveformExtractor.extract(url: url)
		let found = PeakTaming.excursions(
			in: wave.envelope(ratePerSecond: PeakTaming.rate),
			ratePerSecond: PeakTaming.rate)
		let proposed = PeakTaming.propose(over: wave, shift: shift, existing: take.levels)
		let dips = (proposed.count - take.levels.count) / 4
		print(String(format: "%@: %.0f s of audio, read in %.1f s",
		             url.lastPathComponent, wave.duration, -started.timeIntervalSinceNow))
		print(String(format: "%d excursions, %d dips proposed, %.2f%% of the take under one",
		             found.count, dips,
		             found.map(\.duration).reduce(0, +) / max(1, wave.duration) * 100))

		/// The cut the proposal makes at the middle of an excursion.
		func cut(_ excursion: PeakTaming.Excursion) -> Double {
			let middle = (excursion.start + excursion.end) / 2 + shift
			return GainCurve.gain(at: middle, in: proposed)
				- GainCurve.gain(at: middle, in: take.levels)
		}

		let tamed = found.filter { cut($0) < 0 }
		for excursion in tamed {
			print(String(format: "  %@  %5.0f ms  +%4.1f dB over its neighbourhood  →  %.1f dB off",
			             Timecode.string(excursion.start + shift),
			             excursion.duration * 1000, excursion.excess, cut(excursion)))
		}

		// And the second opinion, in three decodes: the take, the moments the
		// pass picked, and the seconds around them.
		//
		// Four hundred milliseconds centred on each moment rather than the moment
		// itself, because that is the window the loudness meter is defined over:
		// asked about ten milliseconds it reports the audio around them, which is
		// the very thing being compared against. This is the spec's momentary
		// window, and it is what "how loud is that bang" means to an ear.
		let insides = tamed.map { excursion in
			let middle = (excursion.start + excursion.end) / 2
			return max(0, middle - 0.2) ... min(wave.duration, middle + 0.2)
		}
		let arounds = tamed.flatMap { excursion in
			[max(0, excursion.start - 2) ... max(0, excursion.start - 0.05),
			 min(wave.duration, excursion.end + 0.05) ... min(wave.duration, excursion.end + 2)]
		}.filter { $0.upperBound > $0.lowerBound }
		let whole = try await LoudnessMeter.measure(url: url)
		let picked = try await LoudnessMeter.measure(url: url, ranges: insides)
		let round = try await LoudnessMeter.measure(url: url, ranges: arounds)
		let loud = try #require(picked.integrated)
		let around = try #require(round.integrated)
		let average = tamed.map { cut($0) }.reduce(0, +) / Double(max(1, tamed.count))
		print(String(format: "take %.1f LUFS / %.1f dBFS", whole.integrated ?? 0, whole.peak))
		print(String(format: "picked %.1f LUFS / %.1f dBFS, around %.1f / %.1f", loud, picked.peak, around, round.peak))
		print(String(format: "→ %+.1f LU and %+.1f dB of peak over; average cut %.1f leaves %+.1f LU, %+.1f dB",
		             loud - around, picked.peak - round.peak, average,
		             loud - around + average, picked.peak - round.peak + average))

		#expect(!tamed.isEmpty)
		// What it picked is near the top of the recording's own range, measured
		// off the file rather than off the envelope the pass read. Not *the*
		// loudest moment necessarily — on one of the two recordings this was
		// measured against it was, and on the other the loudest moment is a
		// child shouting for most of a second, which this deliberately leaves
		// alone: turning that down is a decision about the performance.
		#expect(picked.peak >= whole.peak - 10,
		        "the take peaks at \(whole.peak) and the picked moments at \(picked.peak)")
		// And they are louder than what surrounds them by the *loudness* meter
		// as well as by the envelope they were found with — a second opinion,
		// K-weighted and gated, from a different decode. Measured: +5.3 LU on
		// one recording and +3.7 on the other, against the twelve to
		// twenty-five decibels of peak the envelope saw, which is what
		// K-weighting does to a thump.
		#expect(loud - around > 2)
		// The cuts are repairs and not a policy: each one is worth making and
		// none of them is bottomless.
		#expect(tamed.allSatisfy { cut($0) <= -3 && cut($0) >= -18 })
		// A repair rather than a pass over the whole take: a fraction of a per
		// cent of the seconds, not a tenth of them.
		#expect(found.map(\.duration).reduce(0, +) < wave.duration * 0.05)
		// Nothing off the front, and nothing left on the recorder's clock.
		#expect(proposed.allSatisfy { $0.at >= 0 })
		#expect(proposed.map(\.at) == proposed.map(\.at).sorted())
	}
}
