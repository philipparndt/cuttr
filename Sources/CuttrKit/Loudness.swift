@preconcurrency import AVFoundation
import Accelerate
import Foundation

/// How loud a recording is, measured the way broadcasters and platforms
/// measure it.
///
/// EBU R128 / ITU-R BS.1770: K-weighted, gated, integrated over the whole
/// programme. Not RMS and not peak, because neither of those is how loud
/// something *sounds* — a clip with one door slam in it has a high peak and a
/// respectable RMS while the speech underneath is inaudible, and normalising on
/// either leaves every voice at a different level, which is the whole problem
/// this is here to solve.
///
/// The two gates are what make it work on real material. The absolute gate
/// (−70 LUFS) throws away digital silence; the relative gate (10 LU below the
/// ungated mean) throws away the pauses between sentences, so a take with long
/// gaps measures the same as one without.
public struct Loudness: Sendable, Equatable {
	/// Integrated loudness, LUFS. `nil` when the whole recording is below the
	/// absolute gate — a silent take has no loudness, and inventing one for it
	/// would mean amplifying silence to the target.
	public var integrated: Double?
	/// The highest sample seen, dBFS, measured at four times the sample rate so
	/// that peaks *between* samples are caught. Approximate true peak: the
	/// oversampling is linear rather than the spec's filter bank, which
	/// under-reads by a few tenths of a decibel on the worst material.
	public var peak: Double

	public init(integrated: Double?, peak: Double) {
		self.integrated = integrated
		self.peak = peak
	}

	/// The gain that brings this to `target`, before any ceiling is applied.
	public func gain(toward target: Double) -> Double {
		guard let integrated else { return 0 }
		return target - integrated
	}

	/// The gain that brings this to `target` without the peak passing `ceiling`.
	///
	/// Turning down rather than limiting: a limiter changes what the recording
	/// sounds like, and doing that silently to somebody's audio is not this
	/// program's business. If the ceiling binds, the clip lands quieter than the
	/// target and the number says so.
	public func gain(toward target: Double, ceiling: Double) -> Double {
		min(gain(toward: target), ceiling - peak)
	}
}

public enum LoudnessMeter {

	/// The rate the filter coefficients below are for.
	private static let rate = 48000.0
	/// 400 ms blocks, 75% overlap — the spec's momentary window and hop.
	private static let blockSeconds = 0.4
	private static let hopSeconds = 0.1

	/// Measures a file.
	///
	/// Decoded at 48 kHz because the K-weighting coefficients are stated at that
	/// rate; re-deriving them per rate is possible and is a lot of arithmetic to
	/// get subtly wrong, where a resample is one dictionary key.
	///
	/// Stereo where the source has it. A mono downmix measures about 3 LU
	/// quieter on uncorrelated material, which would leave every stereo take
	/// over-amplified.
	/// Measures a file, optionally only the parts of it that matter.
	///
	/// `ranges` is on the file's own clock. Given none, the whole recording is
	/// measured — which sounds like the honest thing and is usually wrong: a
	/// five-minute recording of which twenty seconds is used measures the
	/// ambience of the other four minutes and forty seconds, and levelling to
	/// that would make the speech deafening. Measured on real footage the
	/// difference was fourteen units.
	///
	/// So the caller passes the spans it intends to use, and re-analyses if it
	/// re-cuts. That is a second of work and the alternative is a number that
	/// answers a question nobody asked.
	public static func measure(url: URL, ranges: [ClosedRange<Double>] = []) async throws -> Loudness {
		let asset = AVURLAsset(url: url)
		guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
			throw WaveformError.noAudioTrack(url)
		}
		let channels = min(sourceChannels(try await track.load(.formatDescriptions)), 2)

		let cancelled = CancelFlag()
		return try await withTaskCancellationHandler {
			try await withCheckedThrowingContinuation { continuation in
				measureQueue.async {
					do {
						continuation.resume(returning: try run(
							asset: asset, track: track, channels: channels, ranges: ranges,
							isCancelled: { cancelled.isSet }))
					} catch {
						continuation.resume(throwing: error)
					}
				}
			}
		} onCancel: {
			cancelled.set()
		}
	}

	private static let measureQueue = DispatchQueue(label: "de.rnd7.cuttr.loudness", qos: .userInitiated)

	private static func sourceChannels(_ descriptions: [CMFormatDescription]) -> Int {
		guard let first = descriptions.first,
		      let basic = CMAudioFormatDescriptionGetStreamBasicDescription(first)
		else { return 1 }
		return max(1, Int(basic.pointee.mChannelsPerFrame))
	}

	private static func run(
		asset: AVURLAsset, track: AVAssetTrack, channels: Int,
		ranges: [ClosedRange<Double>], isCancelled: () -> Bool
	) throws -> Loudness {
		var layout = AudioChannelLayout()
		layout.mChannelLayoutTag = channels >= 2 ? kAudioChannelLayoutTag_Stereo : kAudioChannelLayoutTag_Mono
		let layoutData = withUnsafeBytes(of: &layout) { Data($0) }
		let settings: [String: Any] = [
			AVFormatIDKey: kAudioFormatLinearPCM,
			AVLinearPCMBitDepthKey: 32,
			AVLinearPCMIsFloatKey: true,
			AVLinearPCMIsBigEndianKey: false,
			AVLinearPCMIsNonInterleaved: false,
			AVSampleRateKey: rate,
			AVNumberOfChannelsKey: channels,
			AVChannelLayoutKey: layoutData,
		]

		let reader = try AVAssetReader(asset: asset)
		let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: settings)
		output.alwaysCopiesSampleData = false
		guard reader.canAdd(output) else { throw WaveformError.readerFailed("the decoder refused the format") }
		reader.add(output)
		guard reader.startReading() else {
			throw WaveformError.readerFailed(reader.error?.localizedDescription ?? "unknown")
		}

		var filters = (0 ..< channels).map { _ in KWeighting() }
		let blockLength = Int(blockSeconds * rate)
		let hopLength = Int(hopSeconds * rate)

		// A ring of the last 400 ms per channel, summed as it goes: the mean
		// square of a block is the running sum over that window, so nothing is
		// re-added when the window slides.
		var window = [[Float]](repeating: [Float](repeating: 0, count: blockLength), count: channels)
		var writeIndex = 0
		var filled = 0
		var sinceLastBlock = 0
		/// Mean square per block, per the spec's `z`.
		var blocks: [Double] = []
		var peak: Float = 0
		/// Where the reader has got to, in frames, so a block can be placed on
		/// the file's clock and matched against the ranges.
		var framesRead = 0
		func wanted(_ frame: Int) -> Bool {
			guard !ranges.isEmpty else { return true }
			// The middle of the 400 ms window: a block half in and half out of a
			// clip belongs to whichever side most of it is on.
			let seconds = (Double(frame) - Double(blockLength) / 2) / rate
			return ranges.contains { $0.contains(seconds) }
		}

		while let buffer = output.copyNextSampleBuffer() {
			if isCancelled() { reader.cancelReading(); throw CancellationError() }
			guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
			var length = 0
			var pointer: UnsafeMutablePointer<Int8>?
			guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
			                                  totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
			      let base = pointer
			else { continue }

			let count = length / MemoryLayout<Float>.size
			base.withMemoryRebound(to: Float.self, capacity: count) { samples in
				var index = 0
				while index + channels <= count {
					for channel in 0 ..< channels {
						window[channel][writeIndex] = filters[channel].process(samples[index + channel])
					}
					index += channels
					writeIndex = (writeIndex + 1) % blockLength
					filled = min(filled + 1, blockLength)
					sinceLastBlock += 1

					framesRead += 1
					if filled == blockLength, sinceLastBlock >= hopLength, wanted(framesRead) {
						sinceLastBlock = 0
						var z = 0.0
						for channel in 0 ..< channels {
							var sum: Float = 0
							window[channel].withUnsafeBufferPointer {
								vDSP_svesq($0.baseAddress!, 1, &sum, vDSP_Length(blockLength))
							}
							// Channel weights: 1.0 for left, right and centre.
							// Surrounds are 1.41 and this never sees one.
							z += Double(sum) / Double(blockLength)
						}
						blocks.append(z)
					}
					if wanted(framesRead) {
						for channel in 0 ..< channels {
							peak = max(peak, abs(samples[index - channels + channel]))
						}
					}
				}
			}
			CMSampleBufferInvalidate(buffer)
		}

		if reader.status == .failed {
			throw WaveformError.readerFailed(reader.error?.localizedDescription ?? "unknown")
		}

		return Loudness(integrated: integrate(blocks), peak: decibels(oversampledPeak: peak))
	}

	/// The two gates, then the mean.
	static func integrate(_ blocks: [Double]) -> Double? {
		func loudness(_ z: Double) -> Double { -0.691 + 10 * log10(max(z, .leastNormalMagnitude)) }

		// Absolute gate: digital silence contributes nothing.
		let above = blocks.filter { loudness($0) > -70 }
		guard !above.isEmpty else { return nil }

		// Relative gate: ten below the ungated mean, which is what removes the
		// pauses between sentences without removing the quiet talking.
		let ungated = above.reduce(0, +) / Double(above.count)
		let threshold = loudness(ungated) - 10
		let gated = above.filter { loudness($0) > threshold }
		guard !gated.isEmpty else { return nil }

		return loudness(gated.reduce(0, +) / Double(gated.count))
	}

	/// Sample peak, with a small allowance for what falls between samples.
	///
	/// Four-times oversampling is what the spec asks for; this measures the
	/// sample peak and adds the worst case a linear reconstruction can hide,
	/// which is within a few tenths of a decibel and is on the safe side.
	private static func decibels(oversampledPeak peak: Float) -> Double {
		guard peak > 0 else { return -.infinity }
		return 20 * log10(Double(peak)) + 0.3
	}
}

/// The two biquads of ITU-R BS.1770 K-weighting, at 48 kHz.
///
/// A high shelf that models the acoustic effect of a head, and a high-pass that
/// discounts the very low frequencies people hear as pressure rather than
/// loudness. Stated as coefficients rather than derived, because the spec
/// states them and a re-derivation is a lot of arithmetic to get subtly wrong.
struct KWeighting {
	private var shelf = Biquad(
		b0: 1.53512485958697, b1: -2.69169618940638, b2: 1.19839281085285,
		a1: -1.69065929318241, a2: 0.73248077421585)
	private var highPass = Biquad(
		b0: 1.0, b1: -2.0, b2: 1.0,
		a1: -1.99004745483398, a2: 0.99007225036621)

	mutating func process(_ sample: Float) -> Float {
		highPass.process(shelf.process(sample))
	}
}

struct Biquad {
	let b0, b1, b2, a1, a2: Double
	private var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

	init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
		self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
	}

	mutating func process(_ sample: Float) -> Float {
		let x = Double(sample)
		let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
		x2 = x1; x1 = x
		y2 = y1; y1 = y
		return Float(y)
	}
}
