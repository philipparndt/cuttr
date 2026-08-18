import Accelerate
// `@preconcurrency` for one type: `AVAssetTrack`, which predates `Sendable`
// and is handed to the decode queue below. The hand-off is a real one — the
// track is loaded, then used on exactly one other thread and never touched
// again here — and there is no way to say that to the checker about a type
// somebody else declared.
@preconcurrency import AVFoundation
import Foundation

/// A decoded audio file, reduced to what a timeline can draw.
///
/// Peaks rather than samples. A minute of 48 kHz stereo is 11 MB of samples and
/// about 700 pixels of timeline, so the drawing code would throw away 99.99% of
/// what it read on every frame. Two arrays of per-bucket minimum and maximum
/// hold exactly what a waveform *is* — the envelope — and let a redraw be a
/// walk over a slice.
///
/// One millisecond a bucket by default. That is the resolution the alignment
/// pane needs: an offset is nudged in milliseconds, and a bucket coarser than
/// the nudge would make the correction invisible. It costs 8 bytes a
/// millisecond, so 29 MB an hour, which is a recording-sized program's budget.
public struct Waveform: Sendable {
	public let bucketsPerSecond: Double
	public let duration: Double
	public let sampleRate: Double
	/// Per-bucket extremes, in −1…1. Parallel arrays, same count.
	public let mins: [Float]
	public let maxs: [Float]

	public var bucketCount: Int { mins.count }

	public init(bucketsPerSecond: Double, duration: Double, sampleRate: Double, mins: [Float], maxs: [Float]) {
		self.bucketsPerSecond = bucketsPerSecond
		self.duration = duration
		self.sampleRate = sampleRate
		self.mins = mins
		self.maxs = maxs
	}

	/// The extremes over a span of seconds, for one column of pixels.
	///
	/// Returns `nil` outside the recording rather than a flat line at zero, so
	/// the timeline can draw "there is nothing here" differently from silence —
	/// which is the difference between the audio having ended and the room
	/// having gone quiet, and it matters when aligning.
	public func extremes(from start: Double, to end: Double) -> (min: Float, max: Float)? {
		guard bucketCount > 0 else { return nil }
		let lo = Int((start * bucketsPerSecond).rounded(.down))
		let hi = Int((end * bucketsPerSecond).rounded(.up))
		guard hi > 0, lo < bucketCount else { return nil }
		let a = Swift.max(0, lo)
		let b = Swift.min(bucketCount, Swift.max(hi, a + 1))
		guard a < b else { return nil }
		var lowest: Float = 0
		var highest: Float = 0
		mins.withUnsafeBufferPointer { p in
			vDSP_minv(p.baseAddress! + a, 1, &lowest, vDSP_Length(b - a))
		}
		maxs.withUnsafeBufferPointer { p in
			vDSP_maxv(p.baseAddress! + a, 1, &highest, vDSP_Length(b - a))
		}
		return (lowest, highest)
	}

	/// An amplitude envelope at a coarser rate, for the aligner.
	///
	/// `max(|min|, |max|)` per bucket rather than RMS: what two microphones in
	/// one room agree on is *when* things happened, and a peak envelope keeps
	/// the attack of each transient where RMS smears it over the window. The
	/// aligner is looking for the same door closing in two recordings.
	public func envelope(ratePerSecond: Double) -> [Float] {
		let stride = Swift.max(1, Int((bucketsPerSecond / ratePerSecond).rounded()))
		var out = [Float]()
		out.reserveCapacity(bucketCount / stride + 1)
		var i = 0
		while i < bucketCount {
			let end = Swift.min(i + stride, bucketCount)
			var lo: Float = 0, hi: Float = 0
			mins.withUnsafeBufferPointer { vDSP_minv($0.baseAddress! + i, 1, &lo, vDSP_Length(end - i)) }
			maxs.withUnsafeBufferPointer { vDSP_maxv($0.baseAddress! + i, 1, &hi, vDSP_Length(end - i)) }
			out.append(Swift.max(abs(lo), abs(hi)))
			i = end
		}
		return out
	}
}

public enum WaveformError: LocalizedError {
	case noAudioTrack(URL)
	case unreadable(URL, String)
	case readerFailed(String)

	public var errorDescription: String? {
		switch self {
		case .noAudioTrack(let url):
			return "\(url.lastPathComponent) has no audio track."
		case .unreadable(let url, let message):
			// Named, because this is shown in a window that has two files open
			// and AVFoundation's own message says which problem but not which
			// file — "This media may be damaged" about one of two is no help.
			return "Could not open \(url.lastPathComponent): \(message)"
		case .readerFailed(let message):
			return "Could not read the audio: \(message)"
		}
	}
}

public enum WaveformExtractor {

	/// Decodes `url` to a peak envelope.
	///
	/// Two halves, and the split is the point. Asking the asset for its tracks
	/// is `await` — on a file still being written, or one on a network volume,
	/// the synchronous accessors block whichever thread asks, which for this app
	/// is the one drawing the timeline. Decoding is minutes of CPU and belongs
	/// on a thread of its own rather than on the cooperative pool, where a
	/// blocking call holds a core that every other task is queued behind.
	///
	/// So: `await` for the metadata, then a real thread for the work, and one
	/// function for the caller.
	public static func extract(url: URL, bucketsPerSecond: Double = 1000) async throws -> Waveform {
		let asset = AVURLAsset(url: url)
		let tracks: [AVAssetTrack]
		do { tracks = try await asset.loadTracks(withMediaType: .audio) }
		catch { throw WaveformError.unreadable(url, error.localizedDescription) }
		guard let track = tracks.first else { throw WaveformError.noAudioTrack(url) }
		// The track's own rate, so nothing is resampled on the way through.
		// Resampling would be correct and would also be the most expensive part
		// of this function, bought for nothing: peaks do not care what rate
		// they were taken at.
		let descriptions = try await track.load(.formatDescriptions)
		let rate = descriptions.lazy.compactMap { description -> Double? in
			guard let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description) else { return nil }
			return basic.pointee.mSampleRate > 0 ? basic.pointee.mSampleRate : nil
		}.first ?? 48000

		let cancelled = CancelFlag()
		return try await withTaskCancellationHandler {
			try await withCheckedThrowingContinuation { continuation in
				decodeQueue.async {
					do {
						continuation.resume(returning: try decode(
							asset: asset, track: track, rate: rate,
							bucketsPerSecond: bucketsPerSecond,
							isCancelled: { cancelled.isSet }
						))
					} catch {
						continuation.resume(throwing: error)
					}
				}
			}
		} onCancel: {
			cancelled.set()
		}
	}

	/// One decode at a time. Opening a take with a separate audio file starts
	/// two of these, and running them side by side would double the memory
	/// high-water mark to finish both at the same moment instead of one a
	/// little sooner — while the timeline is waiting to draw either.
	private static let decodeQueue = DispatchQueue(label: "de.rnd7.cuttr.waveform", qos: .userInitiated)

	/// The blocking half. Called on ``decodeQueue`` and nowhere else.
	private static func decode(
		asset: AVURLAsset,
		track: AVAssetTrack,
		rate: Double,
		bucketsPerSecond: Double,
		isCancelled: () -> Bool
	) throws -> Waveform {
		// Mixed down to mono. A waveform of one channel would miss what the
		// other one heard, and drawing two lanes for a stereo file spends half
		// the timeline saying the same thing twice.
		var layout = AudioChannelLayout()
		layout.mChannelLayoutTag = kAudioChannelLayoutTag_Mono
		let layoutData = withUnsafeBytes(of: &layout) { Data($0) }

		let settings: [String: Any] = [
			AVFormatIDKey: kAudioFormatLinearPCM,
			AVLinearPCMBitDepthKey: 32,
			AVLinearPCMIsFloatKey: true,
			AVLinearPCMIsBigEndianKey: false,
			AVLinearPCMIsNonInterleaved: false,
			AVSampleRateKey: rate,
			AVNumberOfChannelsKey: 1,
			AVChannelLayoutKey: layoutData,
		]

		let reader: AVAssetReader
		do { reader = try AVAssetReader(asset: asset) }
		catch { throw WaveformError.readerFailed(error.localizedDescription) }

		let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: settings)
		output.alwaysCopiesSampleData = false
		guard reader.canAdd(output) else { throw WaveformError.readerFailed("the decoder refused the output format") }
		reader.add(output)
		guard reader.startReading() else {
			throw WaveformError.readerFailed(reader.error?.localizedDescription ?? "unknown")
		}

		let samplesPerBucket = Swift.max(1, Int((rate / bucketsPerSecond).rounded()))
		var mins: [Float] = []
		var maxs: [Float] = []
		mins.reserveCapacity(4096)
		maxs.reserveCapacity(4096)

		// Carried across sample buffers: a decoded buffer does not end on a
		// bucket boundary, and starting a fresh bucket at each one would put a
		// spurious short bucket every few milliseconds.
		var carry = [Float]()
		carry.reserveCapacity(samplesPerBucket)

		var totalSamples = 0

		while let buffer = output.copyNextSampleBuffer() {
			if isCancelled() {
				reader.cancelReading()
				throw CancellationError()
			}
			guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
			var length = 0
			var pointer: UnsafeMutablePointer<Int8>?
			guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
			                                  totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
			      let base = pointer
			else { continue }

			let count = length / MemoryLayout<Float>.size
			totalSamples += count
			base.withMemoryRebound(to: Float.self, capacity: count) { samples in
				var index = 0
				while index < count {
					let want = samplesPerBucket - carry.count
					let take = Swift.min(want, count - index)
					if carry.isEmpty && take == samplesPerBucket {
						// The common case: a whole bucket lies inside this
						// buffer, so it is measured in place with no copy.
						var lo: Float = 0, hi: Float = 0
						vDSP_minv(samples + index, 1, &lo, vDSP_Length(take))
						vDSP_maxv(samples + index, 1, &hi, vDSP_Length(take))
						mins.append(lo)
						maxs.append(hi)
					} else {
						carry.append(contentsOf: UnsafeBufferPointer(start: samples + index, count: take))
						if carry.count == samplesPerBucket {
							var lo: Float = 0, hi: Float = 0
							carry.withUnsafeBufferPointer {
								vDSP_minv($0.baseAddress!, 1, &lo, vDSP_Length(samplesPerBucket))
								vDSP_maxv($0.baseAddress!, 1, &hi, vDSP_Length(samplesPerBucket))
							}
							mins.append(lo)
							maxs.append(hi)
							carry.removeAll(keepingCapacity: true)
						}
					}
					index += take
				}
			}
			CMSampleBufferInvalidate(buffer)
		}

		if reader.status == .failed {
			throw WaveformError.readerFailed(reader.error?.localizedDescription ?? "unknown")
		}
		// The tail: a partial bucket is still a bucket, and dropping it would
		// make the waveform end before the audio does.
		if !carry.isEmpty {
			var lo: Float = 0, hi: Float = 0
			carry.withUnsafeBufferPointer {
				vDSP_minv($0.baseAddress!, 1, &lo, vDSP_Length(carry.count))
				vDSP_maxv($0.baseAddress!, 1, &hi, vDSP_Length(carry.count))
			}
			mins.append(lo)
			maxs.append(hi)
		}

		return Waveform(
			bucketsPerSecond: rate / Double(samplesPerBucket),
			// Counted from the samples that arrived rather than taken from the
			// container's duration: the two disagree on a file whose header was
			// written before the recording stopped, and the timeline has to
			// match the array it is drawing.
			duration: Double(totalSamples) / rate,
			sampleRate: rate,
			mins: mins,
			maxs: maxs
		)
	}
}

/// A cancellation flag the decode loop can read.
///
/// `Task.isCancelled` is not available off a task, and the decode deliberately
/// runs off one. A lock rather than an atomic because this is read once per
/// sample buffer — a few thousand times over a decode — and correctness on a
/// flag two threads share is worth more here than the nanoseconds.
final class CancelFlag: @unchecked Sendable {
	private let lock = NSLock()
	private var value = false
	var isSet: Bool { lock.withLock { value } }
	func set() { lock.withLock { value = true } }
}
