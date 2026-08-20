@preconcurrency import AVFoundation
import Foundation
import Speech

/// What Apple's own recogniser noticed about the voice while it was listening.
///
/// `SFSpeechRecognitionResult` carries a `SFVoiceAnalytics` beside the words:
/// pitch, jitter, shimmer and voicing, one value per frame, measured by the
/// same model that produced the transcript. It costs nothing extra to ask for
/// and it involves no foreign model at all — which is why it is tried before
/// anything that has to be fetched.
///
/// **On the device.** `requiresOnDeviceRecognition` is set and the recogniser
/// is refused if it says it cannot honour it, exactly as ``Transcriber`` does.
/// Somebody's unreleased footage is not something a cutting program may post to
/// a server because it was convenient.
///
/// **What it is not.** `Speech.framework` has no diarisation in it — there is
/// no speaker symbol anywhere in the framework, and this is not one. It is four
/// numbers about the larynx, and whether four numbers about the larynx separate
/// two people in a room is a question to answer by measuring rather than by
/// arguing. See the report in `docs/speakers.md` for what it came to here.
public enum VoiceAnalytics {

	/// One line's worth, as a vector to cluster.
	public struct Sample: Sendable {
		public let start: Double
		public let end: Double
		/// Mean and spread of each of the four, in that order.
		public let features: [Double]
		/// How many frames went into it. A line the recogniser barely heard
		/// gives a vector of almost nothing.
		public let frames: Int

		public init(start: Double, end: Double, features: [Double], frames: Int) {
			self.start = start
			self.end = end
			self.features = features
			self.frames = frames
		}
	}

	public enum Trouble: LocalizedError {
		case noRecogniser
		case wouldLeaveTheMachine
		case notAuthorised
		case nothingHeard
		case noAnalytics(segments: Int, metadata: Bool)

		public var errorDescription: String? {
			switch self {
			case .noRecogniser:
				return "This Mac has no speech recogniser to ask about the voices."
			case .wouldLeaveTheMachine:
				return "The only recogniser this Mac has would send the audio to Apple, so"
					+ " nothing was measured. Nothing has been uploaded."
			case .notAuthorised:
				return "cuttr has not been allowed to use speech recognition."
					+ " Privacy & Security → Speech Recognition, in System Settings."
			case .nothingHeard:
				return "The recogniser heard nothing it could measure."
			case .noAnalytics(let segments, let metadata):
				return "The on-device recogniser returned \(segments) segments"
					+ (metadata ? " with" : " and no") + " recognition metadata, and voice"
					+ " analytics on none of them. `SFVoiceAnalytics` is declared on"
					+ " `SFTranscriptionSegment` but this machine's on-device model does not"
					+ " fill it in, so there is nothing here to tell two voices apart with."
			}
		}
	}

	/// Pitch, jitter, shimmer and voicing over each span, on the video's clock.
	///
	/// The recogniser is asked once for the whole file and the frames are then
	/// cut up by span, because asking it sixty-eight times would be sixty-eight
	/// model loads.
	public static func measure(
		url: URL, spans: [(start: Double, end: Double)],
		offset: Double = 0, locale: Locale = .current
	) async throws -> [Sample] {
		let (frames, segments, metadata) = try await frames(url: url, locale: locale)
		guard !frames.isEmpty else {
			throw Trouble.noAnalytics(segments: segments, metadata: metadata)
		}
		return spans.map { span in
			// The frames are on the file's own clock; the spans are on the
			// video's, like every other time in a take. One subtraction, here,
			// and nothing above this line has two clocks to think about.
			let from = span.start - offset
			let to = span.end - offset
			let inside = frames.filter { $0.at >= from && $0.at < to }
			guard inside.count >= 2 else {
				return Sample(start: span.start, end: span.end,
				              features: [Double](repeating: 0, count: 8), frames: inside.count)
			}
			var features: [Double] = []
			for column in 0 ..< 4 {
				let values = inside.map { $0.values[column] }
				let mean = values.reduce(0, +) / Double(values.count)
				features.append(mean)
			}
			for column in 0 ..< 4 {
				let values = inside.map { $0.values[column] }
				let mean = features[column]
				let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
				features.append(variance.squareRoot())
			}
			return Sample(start: span.start, end: span.end, features: features, frames: inside.count)
		}
	}

	struct Frame: Sendable {
		let at: Double
		/// Pitch, jitter, shimmer, voicing.
		let values: [Double]
	}

	/// Every analytics frame in the file, on the file's own clock — and, so the
	/// failure can be reported rather than guessed at, how many segments came
	/// back and whether there was any metadata at all.
	typealias Answer = (frames: [Frame], segments: Int, metadata: Bool)

	static func frames(url: URL, locale: Locale) async throws -> Answer {
		guard await authorised() else { throw Trouble.notAuthorised }
		guard let recogniser = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer()
		else { throw Trouble.noRecogniser }
		guard recogniser.isAvailable else { throw Trouble.noRecogniser }
		guard recogniser.supportsOnDeviceRecognition else { throw Trouble.wouldLeaveTheMachine }

		let request = SFSpeechURLRecognitionRequest(url: url)
		request.requiresOnDeviceRecognition = true
		// Partial results, and this is not an optimisation.
		//
		// `SFSpeechRecognizer` treats a file as a run of utterances and starts
		// again at each one: asked for final results only, a five-minute
		// interview came back as five characters, because the last utterance is
		// all the final result holds. Every callback re-reports the utterance in
		// progress from its beginning, so the way to see the whole file is to
		// take every callback and let later ones supersede earlier ones for the
		// same timestamps.
		request.shouldReportPartialResults = true
		request.taskHint = .dictation
		request.addsPunctuation = true

		return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Answer, Error>) in
			let box = Once(continuation)
			let gathered = Gathered()
			recogniser.recognitionTask(with: request) { result, error in
				if let error { box.fail(error); return }
				guard let result else { return }
				gathered.take(result)
				guard result.isFinal else { return }
				box.finish(gathered.answer())
			}
		}
	}

	/// What the callbacks have said so far, keyed by when it was said.
	///
	/// Not `Sendable` by inspection — the recognition callback is the only
	/// thing that touches it and it arrives on one queue — but the lock is
	/// cheap and the alternative is a promise about Apple's threading.
	private final class Gathered: @unchecked Sendable {
		private let lock = NSLock()
		/// Keyed to the centisecond, which is finer than the 10 ms frames the
		/// analytics come in and coarse enough that the same segment reported
		/// twice lands on the same key.
		private var frames: [Int: Frame] = [:]
		private var segments = 0
		private var metadata = false

		func take(_ result: SFSpeechRecognitionResult) {
			lock.lock()
			defer { lock.unlock() }
			metadata = metadata || result.speechRecognitionMetadata != nil
			let all = result.bestTranscription.segments
			segments = Swift.max(segments, all.count)
			for segment in all {
				guard let analytics = segment.voiceAnalytics else { continue }
				let pitch = analytics.pitch
				let jitter = analytics.jitter
				let shimmer = analytics.shimmer
				let voicing = analytics.voicing
				let count = Swift.min(
					pitch.acousticFeatureValuePerFrame.count,
					Swift.min(jitter.acousticFeatureValuePerFrame.count,
					          Swift.min(shimmer.acousticFeatureValuePerFrame.count,
					                    voicing.acousticFeatureValuePerFrame.count)))
				for frame in 0 ..< count {
					// Every frame, and `voicing` as a fourth number rather than
					// as a gate. It came back between 0.02 and 0.15 on real
					// speech, so it is not the probability the name suggests and
					// thresholding it at a half threw away all but 51 frames of
					// a five-minute take.
					let voiced = voicing.acousticFeatureValuePerFrame[frame]
					let at = segment.timestamp + Double(frame) * pitch.frameDuration
					frames[Int((at * 100).rounded())] = Frame(
						at: at,
						values: [pitch.acousticFeatureValuePerFrame[frame],
						         jitter.acousticFeatureValuePerFrame[frame],
						         shimmer.acousticFeatureValuePerFrame[frame],
						         voiced])
				}
			}
		}

		func answer() -> Answer {
			lock.lock()
			defer { lock.unlock() }
			return (frames.keys.sorted().map { frames[$0]! }, segments, metadata)
		}
	}

	private static func authorised() async -> Bool {
		if SFSpeechRecognizer.authorizationStatus() == .authorized { return true }
		return await withCheckedContinuation { continuation in
			SFSpeechRecognizer.requestAuthorization { status in
				continuation.resume(returning: status == .authorized)
			}
		}
	}

	/// A recognition task's callback fires more than once, and a continuation
	/// may be resumed exactly once. Everywhere else in this program that is a
	/// stream; here it is one answer, so it is guarded rather than modelled.
	private final class Once: @unchecked Sendable {
		private let lock = NSLock()
		private var continuation: CheckedContinuation<Answer, Error>?

		init(_ continuation: CheckedContinuation<Answer, Error>) {
			self.continuation = continuation
		}

		func finish(_ answer: Answer) {
			lock.lock(); let taken = continuation; continuation = nil; lock.unlock()
			taken?.resume(returning: answer)
		}

		func fail(_ error: Error) {
			lock.lock(); let taken = continuation; continuation = nil; lock.unlock()
			taken?.resume(throwing: error)
		}
	}
}
