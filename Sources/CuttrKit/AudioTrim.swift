import AVFoundation

/// A stretch of an audio file, written out as a file of its own.
///
/// For the times a project's `start:` is not enough: a sound that has to go
/// somewhere else as well, or a file whose first minute nobody wants to carry
/// around. The original is read and never touched — what comes out is a copy,
/// at a path that did not exist before.
///
/// Uncompressed in, uncompressed out, at the depth it came in at: a WAV trimmed
/// to a WAV is the same samples and fewer of them. Anything else is written as
/// AAC in an `.m4a`, because that is the one compressed format this system
/// will encode, and decoding an MP3 to write it again as a WAV five times the
/// size is not what somebody trimming a song meant.
public enum AudioTrim {

	public enum Failure: LocalizedError, Equatable {
		case exists(String)
		case sameFile
		case nothingThere(length: Double)
		case unreadable(String)

		public var errorDescription: String? {
			switch self {
			case .exists(let path): return "There is already a file at \(path). Nothing is overwritten; name another."
			case .sameFile: return "The copy cannot be the file it is cut from."
			case .nothingThere(let length):
				return "Nothing of the file is in that stretch. It is \(Timecode.string(length)) long."
			case .unreadable(let why): return "The audio could not be read: \(why)"
			}
		}
	}

	/// The extension a trimmed copy of `source` gets: its own when that is an
	/// uncompressed container, `m4a` otherwise.
	public static func kind(for source: URL) -> String {
		let own = source.pathExtension.lowercased()
		return ["wav", "aif", "aiff", "caf"].contains(own) ? own : "m4a"
	}

	/// Writes `source` from `start` to `end` — or to its end — at `target`, and
	/// says how many seconds went down.
	@discardableResult
	public static func write(_ source: URL, from start: Double, to end: Double? = nil,
	                         at target: URL) throws -> Double {
		guard source.standardizedFileURL != target.standardizedFileURL else { throw Failure.sameFile }
		guard !FileManager.default.fileExists(atPath: target.path) else {
			throw Failure.exists(target.path)
		}
		let input: AVAudioFile
		do { input = try AVAudioFile(forReading: source) }
		catch { throw Failure.unreadable(error.localizedDescription) }

		let format = input.processingFormat
		let rate = format.sampleRate
		let first = AVAudioFramePosition((max(0, start) * rate).rounded())
		let last = min(input.length, end.map { AVAudioFramePosition(($0 * rate).rounded()) } ?? input.length)
		guard last > first else { throw Failure.nothingThere(length: Double(input.length) / rate) }

		var settings: [String: Any]
		if ["wav", "aif", "aiff", "caf"].contains(target.pathExtension.lowercased()) {
			// The depth it came in at where that is known, sixteen bits where
			// it is not — which is a compressed file being written out flat.
			let depth = input.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int ?? 16
			let float = input.fileFormat.settings[AVLinearPCMIsFloatKey] as? Bool ?? false
			settings = [
				AVFormatIDKey: kAudioFormatLinearPCM,
				AVSampleRateKey: rate,
				AVNumberOfChannelsKey: format.channelCount,
				AVLinearPCMBitDepthKey: depth,
				AVLinearPCMIsFloatKey: float,
				AVLinearPCMIsBigEndianKey: target.pathExtension.lowercased().hasPrefix("aif"),
				AVLinearPCMIsNonInterleaved: false,
			]
		} else {
			settings = [
				AVFormatIDKey: kAudioFormatMPEG4AAC,
				AVSampleRateKey: rate,
				AVNumberOfChannelsKey: format.channelCount,
				// A quality rather than a bit rate. The rates an encoder will
				// take depend on the sample rate — 128 kbit/s is refused outright
				// for a voice memo at 8 kHz — and it knows which it can do.
				AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
			]
		}

		do {
			try FileManager.default.createDirectory(
				at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
			let output = try AVAudioFile(forWriting: target, settings: settings,
			                             commonFormat: format.commonFormat,
			                             interleaved: format.isInterleaved)
			input.framePosition = first
			let chunk: AVAudioFrameCount = 1 << 16
			guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
				throw Failure.unreadable("no room to read into")
			}
			var left = last - first
			while left > 0 {
				try input.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(chunk), left)))
				guard buffer.frameLength > 0 else { break }
				try output.write(from: buffer)
				left -= Int64(buffer.frameLength)
			}
		} catch {
			// Half a file is worse than none: it has the name of the thing
			// somebody asked for and is not it.
			try? FileManager.default.removeItem(at: target)
			if let failure = error as? Failure { throw failure }
			throw Failure.unreadable(error.localizedDescription)
		}
		return Double(last - first) / rate
	}
}
