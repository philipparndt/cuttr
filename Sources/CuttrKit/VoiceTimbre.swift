import Accelerate
@preconcurrency import AVFoundation
import Foundation

/// What a voice sounds like, measured off the samples.
///
/// **Not pitch.** Pitch over this footage is one blob from 150 to 350 Hz with
/// no valley in it: a close mic on a child and on an adult woman land in the
/// same place, and forcing a two-way split on it flips labels mid-sentence.
/// That was measured before any of this was written and is not worth
/// rediscovering.
///
/// What is measured here is the *shape of the mouth and throat* that made the
/// sound, which is a different thing from how fast the cords were vibrating and
/// is what actually differs between a seven-year-old and a grown woman. A short
/// vocal tract puts its formants high; a long one puts them low; and the child
/// speaks in a smaller room of her own head whatever note she happens to be
/// on. Mel-frequency cepstral coefficients are the standard way to write that
/// down, and they are the front end of every speaker system there has ever
/// been, neural or not.
///
/// **Nothing over the network, and no model at all.** This is a Fourier
/// transform, a bank of triangles and a cosine transform — Accelerate, which
/// ships with the machine. There is no file to fetch, no licence to weigh and
/// nothing that could send audio anywhere even by accident.
public enum VoiceTimbre {

	/// One line's worth of voice, as a vector to cluster.
	public struct Sample: Sendable {
		/// The span it was measured over, on the video's clock.
		public let start: Double
		public let end: Double
		/// Mean and spread of each coefficient over the voiced frames.
		public let features: [Double]
		/// How much of the span was loud enough to measure. A line that is
		/// mostly silence is a line whose vector is mostly noise.
		public let voiced: Double

		public init(start: Double, end: Double, features: [Double], voiced: Double) {
			self.start = start
			self.end = end
			self.features = features
			self.voiced = voiced
		}
	}

	public enum Trouble: LocalizedError {
		case noAudio(URL)
		case unreadable(URL, String)

		public var errorDescription: String? {
			switch self {
			case .noAudio(let url): return "\(url.lastPathComponent) has no audio to listen to."
			case .unreadable(let url, let why): return "Could not read \(url.lastPathComponent): \(why)"
			}
		}
	}

	/// 16 kHz mono. Speech above 8 kHz is breath and sibilance, and decoding
	/// four times as many samples to throw them away is four times the wait.
	public static let rate: Double = 16_000
	/// 25 ms of samples, every 10 ms — the window every speech front end has
	/// used since the seventies, and for the reason that a mouth cannot change
	/// shape faster than that.
	static let window = 400
	static let hop = 160
	static let filters = 26
	/// Thirteen coefficients, and the first is thrown away: it is the loudness
	/// of the frame, which is how near the microphone was and not who was
	/// talking.
	static let coefficients = 13

	// MARK: - Measuring a take

	/// One span's voiced frames, each a row of cepstral coefficients.
	public struct Frames: Sendable {
		public let start: Double
		public let end: Double
		/// The frames worth using, `c1` upwards. `c0` is the loudness of the
		/// frame, which is how near the microphone was, and is dropped.
		public let cepstra: [[Double]]
		/// How much of the span was loud enough to measure.
		public let voiced: Double

		public init(start: Double, end: Double, cepstra: [[Double]], voiced: Double) {
			self.start = start
			self.end = end
			self.cepstra = cepstra
			self.voiced = voiced
		}
	}

	/// Every voiced frame in each of these spans, on the file's own clock.
	///
	/// The spans come in on the *video's* clock, like every other time in a
	/// take, and `offset` is what relates the two — the take's
	/// ``AudioTrack/offset``, subtracted here because it was added to get from
	/// the recorder's clock to the video's. Nothing above this line has to
	/// think about two clocks, which is the only way that stays true.
	public static func frames(
		url: URL, spans: [(start: Double, end: Double)], offset: Double = 0
	) async throws -> [Frames] {
		let samples = try await decode(url: url)
		var out: [Frames] = []
		for span in spans {
			let first = Swift.max(0, Int(((span.start - offset) * rate).rounded()))
			let last = Swift.min(samples.count, Int(((span.end - offset) * rate).rounded()))
			guard last - first >= window else {
				out.append(Frames(start: span.start, end: span.end, cepstra: [], voiced: 0))
				continue
			}
			var cepstra: [[Double]] = []
			var energies: [Double] = []
			var index = first
			while index + window <= last {
				let slice = Array(samples[index ..< index + window])
				energies.append(power(slice))
				cepstra.append(Array(cepstrum(slice).dropFirst()))
				index += hop
			}
			// Only the frames with a voice in them. A line is speech with gaps
			// in it, and the gaps are the room — averaging them in measures the
			// room and not the person. The floor is relative to the line's own
			// loudest frame, so a quiet passage is not thrown away wholesale.
			let loudest = energies.max() ?? 0
			let floor = Swift.max(loudest * 0.02, 1e-9)
			let kept = cepstra.indices.filter { energies[$0] > floor }
			out.append(Frames(
				start: span.start, end: span.end,
				cepstra: kept.map { cepstra[$0] },
				voiced: cepstra.isEmpty ? 0 : Double(kept.count) / Double(cepstra.count)))
		}
		return out
	}

	/// The mean and spread of every coefficient over each span's voiced frames.
	public static func measure(
		url: URL, spans: [(start: Double, end: Double)], offset: Double = 0
	) async throws -> [Sample] {
		try await frames(url: url, spans: spans, offset: offset).map { span in
			Sample(start: span.start, end: span.end,
			       features: summarise(span.cepstra), voiced: span.voiced)
		}
	}

	/// Mean then spread, one after the other.
	///
	/// Both halves matter. The mean is the voice's average colour; the spread
	/// is how much it moves, and a child reading a list of salads moves a great
	/// deal more than an adult asking a prepared question.
	static func summarise(_ cepstra: [[Double]]) -> [Double] {
		let width = coefficients - 1
		guard cepstra.count >= 3 else { return [Double](repeating: 0, count: width * 2) }
		var means = [Double](repeating: 0, count: width)
		for frame in cepstra {
			for column in 0 ..< width { means[column] += frame[column] }
		}
		for column in 0 ..< width { means[column] /= Double(cepstra.count) }
		var spreads = [Double](repeating: 0, count: width)
		for frame in cepstra {
			for column in 0 ..< width {
				let step = frame[column] - means[column]
				spreads[column] += step * step
			}
		}
		for column in 0 ..< width {
			spreads[column] = (spreads[column] / Double(cepstra.count)).squareRoot()
		}
		return means + spreads
	}

	private static func power(_ frame: [Float]) -> Double {
		var total: Float = 0
		vDSP_measqv(frame, 1, &total, vDSP_Length(frame.count))
		return Double(total)
	}

	// MARK: - One frame

	/// Hamming, |FFT|², mel triangles, log, DCT-II. The whole front end.
	static func cepstrum(_ frame: [Float]) -> [Double] {
		var windowed = [Float](repeating: 0, count: window)
		vDSP_vmul(frame, 1, hamming, 1, &windowed, 1, vDSP_Length(window))

		var real = [Float](repeating: 0, count: fftSize / 2)
		var imaginary = [Float](repeating: 0, count: fftSize / 2)
		var padded = windowed + [Float](repeating: 0, count: fftSize - window)

		var spectrum = [Float](repeating: 0, count: fftSize / 2)
		real.withUnsafeMutableBufferPointer { realBuffer in
			imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
				var split = DSPSplitComplex(realp: realBuffer.baseAddress!,
				                            imagp: imaginaryBuffer.baseAddress!)
				padded.withUnsafeMutableBufferPointer { input in
					input.baseAddress!.withMemoryRebound(
						to: DSPComplex.self, capacity: fftSize / 2
					) { reinterpreted in
						vDSP_ctoz(reinterpreted, 2, &split, 1, vDSP_Length(fftSize / 2))
					}
				}
				vDSP_fft_zrip(setup, &split, 1, vDSP_Length(log2Size), FFTDirection(FFT_FORWARD))
				vDSP_zvmags(&split, 1, &spectrum, 1, vDSP_Length(fftSize / 2))
			}
		}
		// `vDSP_fft_zrip` scales by two, and the bin at zero holds Nyquist in
		// its imaginary half. Neither matters after a logarithm and a
		// difference, but the scale would if this number were ever printed.
		var quarter: Float = 0.25
		vDSP_vsmul(spectrum, 1, &quarter, &spectrum, 1, vDSP_Length(fftSize / 2))

		var banded = [Double](repeating: 0, count: filters)
		for (band, triangle) in bank.enumerated() {
			var total = 0.0
			for (bin, weight) in triangle { total += Double(spectrum[bin]) * weight }
			banded[band] = Foundation.log(Swift.max(total, 1e-10))
		}

		// DCT-II by hand: thirteen coefficients out of twenty-six bands is 338
		// multiplications, and reaching for `vDSP_DCT` would need a setup
		// object per frame length that is not worth the ceremony.
		var out = [Double](repeating: 0, count: coefficients)
		for k in 0 ..< coefficients {
			var total = 0.0
			for band in 0 ..< filters {
				total += banded[band] * cosineTable[k * filters + band]
			}
			out[k] = total
		}
		return out
	}

	// MARK: - The tables, built once

	private static let log2Size = 9
	private static let fftSize = 1 << log2Size   // 512, the next power of two above 400
	private static let setup = vDSP_create_fftsetup(vDSP_Length(log2Size), FFTRadix(kFFTRadix2))!

	private static let hamming: [Float] = {
		var out = [Float](repeating: 0, count: window)
		vDSP_hamm_window(&out, vDSP_Length(window), 0)
		return out
	}()

	private static let cosineTable: [Double] = {
		var out = [Double](repeating: 0, count: coefficients * filters)
		for k in 0 ..< coefficients {
			for band in 0 ..< filters {
				out[k * filters + band] = Foundation.cos(
					Double.pi * Double(k) * (Double(band) + 0.5) / Double(filters))
			}
		}
		return out
	}()

	/// Twenty-six triangles from 80 Hz to 8 kHz, evenly spaced on the mel
	/// scale — which is to say, spaced the way the ear spaces them: narrow low
	/// down where formants live, wide up top where they do not.
	private static let bank: [[(Int, Double)]] = {
		func mel(_ hertz: Double) -> Double { 2595 * Foundation.log10(1 + hertz / 700) }
		func hertz(_ mel: Double) -> Double { 700 * (Foundation.pow(10, mel / 2595) - 1) }
		let low = mel(80), high = mel(rate / 2)
		let edges = (0 ... filters + 1).map { hertz(low + (high - low) * Double($0) / Double(filters + 1)) }
		let binOf = { (frequency: Double) in Int((frequency / rate * Double(fftSize)).rounded()) }
		var out: [[(Int, Double)]] = []
		for band in 0 ..< filters {
			let left = binOf(edges[band]), middle = binOf(edges[band + 1]), right = binOf(edges[band + 2])
			var triangle: [(Int, Double)] = []
			for bin in Swift.max(left, 0) ... Swift.min(Swift.max(right, left + 1), fftSize / 2 - 1) {
				if bin < middle, middle > left {
					triangle.append((bin, Double(bin - left) / Double(middle - left)))
				} else if bin >= middle, right > middle {
					triangle.append((bin, Double(right - bin) / Double(right - middle)))
				} else if bin == middle {
					triangle.append((bin, 1))
				}
			}
			out.append(triangle)
		}
		return out
	}()

	// MARK: - Getting at the samples

	/// The whole file as mono 16 kHz floats.
	///
	/// A five-minute take is five million of them, which is 20 MB and half a
	/// second of decoding. Streaming it span by span would mean seeking sixty
	/// times, and a seek in a compressed file is a decode from the last key
	/// frame anyway.
	static func decode(url: URL) async throws -> [Float] {
		let asset = AVURLAsset(url: url)
		guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
			throw Trouble.noAudio(url)
		}
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
		catch { throw Trouble.unreadable(url, error.localizedDescription) }
		let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
		output.alwaysCopiesSampleData = false
		guard reader.canAdd(output) else {
			throw Trouble.unreadable(url, "the decoder refused 16 kHz mono float")
		}
		reader.add(output)
		guard reader.startReading() else {
			throw Trouble.unreadable(url, reader.error?.localizedDescription ?? "unknown")
		}

		var samples: [Float] = []
		samples.reserveCapacity(Int(rate) * 60)
		while let buffer = output.copyNextSampleBuffer() {
			guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
			var length = 0
			var pointer: UnsafeMutablePointer<Int8>?
			guard CMBlockBufferGetDataPointer(
				block, atOffset: 0, lengthAtOffsetOut: nil,
				totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
				let pointer else { continue }
			pointer.withMemoryRebound(to: Float.self, capacity: length / 4) { floats in
				samples.append(contentsOf: UnsafeBufferPointer(start: floats, count: length / 4))
			}
		}
		if reader.status == .failed {
			throw Trouble.unreadable(url, reader.error?.localizedDescription ?? "decode failed")
		}
		return samples
	}
}
