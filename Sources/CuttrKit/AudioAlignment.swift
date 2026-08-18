import Accelerate
import Foundation

/// Where the aligner thinks the second recording sits.
public struct Alignment: Sendable, Equatable {
	/// Seconds to add to the audio's clock to reach the video's — the value
	/// that goes into ``AudioTrack/offset``.
	public let offset: Double

	/// The normalised correlation at that offset, −1…1.
	///
	/// Shown rather than thresholded away. Two microphones in one room usually
	/// land at 0.6–0.95; a lavalier under a jumper against a camera across the
	/// room can be 0.3 and still be right. The number is the honest thing to
	/// put next to the answer, and the operator has a waveform in front of them
	/// to check it against.
	public let confidence: Double

	/// Where in the audio the match was measured, for the UI to jump to.
	public let probeStart: Double
	public let probeDuration: Double
}

/// Finding the offset between a camera's own audio and a separate recorder.
///
/// The method is normalised cross-correlation of amplitude envelopes, in two
/// passes.
///
/// Envelopes rather than samples, because the two recordings are not the same
/// signal: different microphones, different positions, different preamps and
/// different response. What they share is *timing* — the same door, the same
/// clap, the same plosive — and an envelope is what is left when everything
/// except timing has been thrown away. Correlating samples would look for a
/// phase match that is not there.
///
/// Normalised — Pearson rather than a plain dot product — because otherwise the
/// loudest place in the file wins every lag and the answer is always "line the
/// peaks up", which is right only by luck.
///
/// Two passes because the two costs pull opposite ways. A 100 Hz envelope over
/// a whole recording is cheap enough to search exhaustively and can only ever
/// be right to 10 ms; a 1 kHz envelope is right to 1 ms and too expensive to
/// search over an hour. So: find the second at 100 Hz, then find the
/// millisecond at 1 kHz within ±20 ms of it.
public enum AudioAligner {

	/// The rates of the two passes, and the window the second one searches.
	private static let coarseRate: Double = 100
	private static let fineRate: Double = 1000
	private static let refineWindow: Double = 0.020

	/// How much of the audio is used as the probe.
	///
	/// Twenty seconds, taken from the most eventful part of the recording
	/// rather than the start. The start of a take is somebody walking to their
	/// mark and a camera settling, which correlates with everything and
	/// distinguishes nothing.
	private static let probeSeconds: Double = 20

	/// Aligns `audio` against `videoAudio`.
	///
	/// `searchRange` bounds the offsets considered, in seconds either way.
	/// `nil` searches every overlap, which is what the "Align" button does: it
	/// costs a second on an hour of material and asks the operator nothing.
	/// Pass a range when refining an offset that is already roughly right.
	public static func align(
		videoAudio: Waveform,
		audio: Waveform,
		around expected: Double = 0,
		searchRange: Double? = nil
	) -> Alignment? {
		let coarse = correlate(
			reference: videoAudio.envelope(ratePerSecond: coarseRate),
			probeSource: audio.envelope(ratePerSecond: coarseRate),
			rate: coarseRate,
			probeSeconds: probeSeconds,
			around: expected,
			searchRange: searchRange
		)
		guard let coarse else { return nil }

		// Second pass at 1 kHz, in a window the first pass has already earned.
		// Re-probed from the same place in the audio, so the two passes are
		// measuring the same twenty seconds and the refinement is a refinement.
		let fine = correlate(
			reference: videoAudio.envelope(ratePerSecond: fineRate),
			probeSource: audio.envelope(ratePerSecond: fineRate),
			rate: fineRate,
			probeSeconds: probeSeconds,
			around: coarse.offset,
			searchRange: refineWindow,
			probeStartHint: coarse.probeStart
		)
		return fine ?? coarse
	}

	/// One pass. Returns the best offset and how well it matched.
	private static func correlate(
		reference: [Float],
		probeSource: [Float],
		rate: Double,
		probeSeconds: Double,
		around expected: Double,
		searchRange: Double?,
		probeStartHint: Double? = nil
	) -> Alignment? {
		let probeLength = min(Int(probeSeconds * rate), probeSource.count)
		guard probeLength > 8, reference.count > probeLength else { return nil }

		// Where the probe may be cut from.
		//
		// Not "anywhere in the audio", which is the obvious answer and is
		// wrong. The probe is laid down inside the reference and slid, so a
		// probe taken from the last twenty seconds of the audio can only ever
		// be placed at the last twenty seconds of the reference — and the
		// offset that would move it past the end is unreachable. A probe from
		// the end therefore cannot find a positive offset at all, silently, and
		// returns whatever noise correlated best instead.
		//
		// So the probe comes from the middle, with room left at both ends to
		// slide into. That room is the largest offset this can find, and it is
		// a fifth of the shorter recording or two seconds, whichever is more —
		// against offsets that are seconds, because two people pressed record
		// one after the other.
		let overlap = min(probeSource.count, reference.count)
		let lastStart = overlap - probeLength
		guard lastStart >= 0 else { return nil }
		let slideRoom = max(overlap / 5, Int(2 * rate))
		let lowStart = min(slideRoom, lastStart)
		let highStart = max(lowStart, lastStart - slideRoom)

		let probeStart = probeStartHint.map { Int(($0 * rate).rounded()) }
			?? mostEventfulWindow(probeSource, length: probeLength, in: lowStart ... highStart)
		let start = max(0, min(probeStart, probeSource.count - probeLength))
		let probe = Array(probeSource[start ..< start + probeLength])

		// The probe, centred and scaled to unit length. Doing it once here is
		// what turns each lag into a single dot product.
		var mean: Float = 0
		vDSP_meanv(probe, 1, &mean, vDSP_Length(probeLength))
		var centred = [Float](repeating: 0, count: probeLength)
		var negativeMean = -mean
		vDSP_vsadd(probe, 1, &negativeMean, &centred, 1, vDSP_Length(probeLength))
		var norm: Float = 0
		vDSP_svesq(centred, 1, &norm, vDSP_Length(probeLength))
		guard norm > 0 else { return nil }   // silence: nothing to match
		norm = sqrt(norm)

		// Running sums of the reference and its square, so each candidate
		// window's mean and deviation are two subtractions rather than a second
		// pass over the window. Without this the search is O(lags × length)
		// twice over and takes long enough to need a progress bar.
		let (sum, sumSquares) = prefixSums(reference)

		// The lag is where in the reference the probe is laid down. Offset and
		// lag differ by where the probe was cut from the audio.
		let lagForZeroOffset = start
		var lowLag = 0
		var highLag = reference.count - probeLength
		if let searchRange {
			let centre = lagForZeroOffset + Int((expected * rate).rounded())
			let span = Int((searchRange * rate).rounded())
			lowLag = max(lowLag, centre - span)
			highLag = min(highLag, centre + span)
		}
		guard lowLag <= highLag else { return nil }

		var bestLag = lowLag
		var best: Float = -2
		let n = Float(probeLength)

		reference.withUnsafeBufferPointer { ref in
			centred.withUnsafeBufferPointer { p in
				for lag in lowLag ... highLag {
					let windowSum = sum[lag + probeLength] - sum[lag]
					let windowSquares = sumSquares[lag + probeLength] - sumSquares[lag]
					// The window's own deviation. A flat window — silence, or a
					// hard-limited passage — has none, and a correlation
					// against it is a divide by zero rather than a match.
					let variance = windowSquares - windowSum * windowSum / Double(n)
					guard variance > 1e-12 else { continue }
					var dot: Float = 0
					vDSP_dotpr(ref.baseAddress! + lag, 1, p.baseAddress!, 1, &dot, vDSP_Length(probeLength))
					// The probe is already centred, so its sum is zero and the
					// reference window's mean drops out of the numerator.
					let score = dot / (norm * Float(variance.squareRoot()))
					if score > best {
						best = score
						bestLag = lag
					}
				}
			}
		}

		guard best > -2 else { return nil }
		return Alignment(
			offset: Double(bestLag - lagForZeroOffset) / rate,
			confidence: Double(best),
			probeStart: Double(start) / rate,
			probeDuration: Double(probeLength) / rate
		)
	}

	/// The window with the most going on in it, which is the one worth probing.
	///
	/// Measured as variance, not loudness. A window of continuous loud noise
	/// correlates with every other window of continuous loud noise; a window
	/// with quiet and then a bang in it matches in exactly one place, which is
	/// what this is for.
	private static func mostEventfulWindow(_ signal: [Float], length: Int, in range: ClosedRange<Int>) -> Int {
		guard signal.count > length else { return 0 }
		let (sum, sumSquares) = prefixSums(signal)
		var bestStart = range.lowerBound
		var best = -Double.infinity
		// Stepping by a tenth of the window rather than by one: the answer only
		// has to be a good place to look from, and stepping by one costs a
		// hundred times as much to move the probe a few milliseconds.
		let step = max(1, length / 10)
		var start = range.lowerBound
		while start <= range.upperBound, start + length <= signal.count {
			let windowSum = sum[start + length] - sum[start]
			let windowSquares = sumSquares[start + length] - sumSquares[start]
			let variance = windowSquares - windowSum * windowSum / Double(length)
			if variance > best {
				best = variance
				bestStart = start
			}
			start += step
		}
		return bestStart
	}

	/// Prefix sums of a signal and of its square, in `Double`.
	///
	/// `Double` because these are sums over a million terms of numbers around
	/// 0.1: in `Float` the running total outgrows the addend and the tail of the
	/// signal stops contributing to it, which shows up as an aligner that is
	/// confident and wrong on long files.
	private static func prefixSums(_ signal: [Float]) -> ([Double], [Double]) {
		var sum = [Double](repeating: 0, count: signal.count + 1)
		var sumSquares = [Double](repeating: 0, count: signal.count + 1)
		var runningSum = 0.0
		var runningSquares = 0.0
		for i in 0 ..< signal.count {
			let v = Double(signal[i])
			runningSum += v
			runningSquares += v * v
			sum[i + 1] = runningSum
			sumSquares[i + 1] = runningSquares
		}
		return (sum, sumSquares)
	}
}
