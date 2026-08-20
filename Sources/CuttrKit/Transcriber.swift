@preconcurrency import AVFoundation
import Foundation
import Speech

/// What was said in a take, worked out on this machine.
///
/// **Nothing leaves the machine.** Both recognisers here are pinned to the
/// device: `SpeechAnalyzer` runs a model that was downloaded to this Mac and
/// has no network path at all, and the older `SFSpeechRecognizer` is asked for
/// `requiresOnDeviceRecognition` and refused outright if it says it cannot —
/// see ``Trouble/wouldLeaveTheMachine``. Somebody's unreleased footage is not
/// something a cutting program may post to a server because it was convenient.
///
/// **The times come back on the video's clock.** The recogniser is pointed at
/// whichever file has the better microphone, which for a real shoot is the
/// separate recorder, and that file has a clock of its own. ``Source`` carries
/// the offset that relates the two and applies it to every word before it
/// leaves here, so nothing downstream — not the sidecar, not the pane, not the
/// clip made out of a sentence — has to remember. See ``Source/onVideoClock``.
public enum Transcriber {

	// MARK: - Where the audio is, and what its clock means

	/// The file to listen to, and how its clock relates to the take's.
	public struct Source: Sendable {
		public let url: URL
		/// Seconds to add to this file's own clock to reach the video's — the
		/// take's ``AudioTrack/offset`` when the separate recorder is being
		/// transcribed, and zero when the video's own track is.
		public let offset: Double
		/// The take's clock, for throwing away what falls outside it. A
		/// recorder started before the camera and stopped after it hears
		/// minutes that no clip can ever contain.
		public let limit: ClosedRange<Double>?

		public init(url: URL, offset: Double, limit: ClosedRange<Double>? = nil) {
			self.url = url
			self.offset = offset
			self.limit = limit
		}

		/// Which file to transcribe for this take, and what its offset is.
		///
		/// The separate recorder when there is one. It is in the take because
		/// the camera's microphone was not good enough to cut with, and a
		/// recogniser has the same difficulty with it that a person does.
		public static func forTake(
			_ take: Take, videoURL: URL?, audioURL: URL?, duration: Double = 0
		) -> Source? {
			let limit = duration > 0 ? 0 ... duration : nil
			if let audioURL, take.audio != nil {
				// An audio-only take has no second clock: the clips are on the
				// recorder's own, and the offset means nothing. Applying it
				// there would shift every word by a number that is in the file
				// only because somebody once aligned a video that has since
				// been removed.
				let offset = take.video == nil ? 0 : (take.audio?.offset ?? 0)
				return Source(url: audioURL, offset: offset, limit: limit)
			}
			if let videoURL { return Source(url: videoURL, offset: 0, limit: limit) }
			return nil
		}

		/// One word, moved onto the video's clock, or `nil` if it lands outside
		/// the take.
		///
		/// The one function in this file that has to be right. Everything else
		/// is plumbing around a model; this is the sentence "positive offset
		/// means the recorder was started after the camera" written as
		/// arithmetic, and it is unit-tested against both signs.
		public func onVideoClock(_ word: Word) -> Word? {
			let moved = Word(start: word.start + offset, end: word.end + offset, text: word.text)
			guard let limit else { return moved }
			// Overlap, not containment: a word that begins a hair before the
			// first frame is still the first word of the take.
			guard moved.end > limit.lowerBound, moved.start < limit.upperBound else { return nil }
			return moved
		}
	}

	// MARK: - What can go wrong, said out loud

	/// The ways this can fail, written for somebody who now has to do something
	/// about it. Every one of them says what.
	public enum Trouble: LocalizedError {
		case noRecogniser
		case localeNotSupported(asked: String, available: [String])
		case modelNotInstalled(locale: String)
		case notAuthorised
		case wouldLeaveTheMachine(locale: String)
		case noAudio(URL)
		case unreadable(URL, String)
		case nothingHeard

		public var errorDescription: String? {
			switch self {
			case .noRecogniser:
				return "This Mac has no on-device speech recogniser. macOS 26 or later has one;"
					+ " before that, Dictation has to be switched on in System Settings."
			case .localeNotSupported(let asked, let available):
				let list = available.prefix(8).joined(separator: ", ")
				return "No on-device model speaks \(asked). It knows: \(list)"
					+ (available.count > 8 ? ", and \(available.count - 8) more." : ".")
			case .modelNotInstalled(let locale):
				return "The \(locale) speech model is not on this Mac yet, and it could not be"
					+ " fetched. Adding \(locale) under Keyboard → Dictation in System Settings"
					+ " downloads it."
			case .notAuthorised:
				return "cuttr has not been allowed to use speech recognition."
					+ " Privacy & Security → Speech Recognition, in System Settings."
			case .wouldLeaveTheMachine(let locale):
				return "The only \(locale) recogniser this Mac has would send the audio to Apple,"
					+ " so nothing was transcribed. Nothing has been uploaded."
			case .noAudio(let url):
				return "\(url.lastPathComponent) has no audio to transcribe."
			case .unreadable(let url, let message):
				return "Could not read \(url.lastPathComponent): \(message)"
			case .nothingHeard:
				return "The recogniser heard nothing it could write down."
			}
		}
	}

	/// How far along, and what it is doing.
	///
	/// The note matters as much as the number: fetching a language model is a
	/// few hundred megabytes over somebody's connection, and a bar that sits at
	/// zero without saying why reads as a hang.
	public struct Progress: Sendable {
		public let seconds: Double
		public let total: Double
		public let note: String

		public var fraction: Double { total > 0 ? min(seconds / total, 1) : 0 }
	}

	/// A finished transcript and where it came from.
	public struct Made: Sendable {
		public let transcript: Transcript
		public let recogniser: Words.Recogniser
		/// The locale actually used, which may not be the one asked for: asking
		/// for `de` gets `de-DE`, and the file records what happened rather
		/// than what was requested.
		public let locale: String
	}

	/// A language this Mac can be asked for, and whether its model is here.
	///
	/// Named in the reader's own language rather than in itself, because
	/// somebody looking for German is as likely to be looking for "German" as
	/// for "Deutsch", and the tag is shown beside it for anybody who thinks in
	/// tags.
	public struct Language: Sendable, Equatable, Identifiable {
		public let identifier: String
		public let name: String
		/// Whether the model is on the machine already. A language that is not
		/// can still be chosen — it is fetched on the first take — but saying
		/// so beforehand is the difference between a wait and a hang.
		public let installed: Bool

		public var id: String { identifier }
	}

	/// What this Mac will listen in.
	///
	/// The one thing this had to have and did not. The language came from the
	/// system, so a Mac set to English transcribed German footage *as English*
	/// and produced four hundred words of confident nonsense — the failure that
	/// looks like a broken recogniser and is really a question nobody was
	/// asked.
	public static func languages() async -> [Language] {
		let display = Locale.current
		func named(_ identifier: String, installed: Bool) -> Language {
			Language(identifier: identifier,
			         name: display.localizedString(forIdentifier: identifier) ?? identifier,
			         installed: installed)
		}
		if #available(macOS 26, *), SpeechTranscriber.isAvailable {
			let installed = Set(await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) })
			let all = await SpeechTranscriber.supportedLocales.map { $0.identifier(.bcp47) }
			return all.sorted().map { named($0, installed: installed.contains($0)) }
		}
		// The old recogniser downloads its own models and does not say which it
		// has, so every one it supports is offered as if it were here.
		return SFSpeechRecognizer.supportedLocales()
			.map { $0.identifier(.bcp47) }
			.sorted()
			.map { named($0, installed: true) }
	}

	// MARK: - Doing it

	/// Transcribes `source`, on this machine, onto the video's clock.
	///
	/// The modern recogniser when this system has it, the old one when it does
	/// not. Which was used comes back in ``Made/recogniser`` and is written
	/// into the take, because the two do not hear the same thing and a
	/// transcript nobody can attribute is one nobody can judge.
	public static func transcribe(
		_ source: Source,
		locale: Locale = .current,
		onProgress: @Sendable @escaping (Progress) -> Void = { _ in }
	) async throws -> Made {
		if #available(macOS 26, *), SpeechTranscriber.isAvailable {
			return try await withAnalyzer(source, locale: locale, onProgress: onProgress)
		}
		return try await withRecognizer(source, locale: locale, onProgress: onProgress)
	}

	// MARK: - SpeechAnalyzer, the one with word times

	@available(macOS 26, *)
	private static func withAnalyzer(
		_ source: Source, locale: Locale,
		onProgress: @Sendable @escaping (Progress) -> Void
	) async throws -> Made {
		guard let spoken = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
			let known = await SpeechTranscriber.supportedLocales.map { $0.identifier(.bcp47) }
			throw Trouble.localeNotSupported(asked: locale.identifier(.bcp47), available: known.sorted())
		}

		// `audioTimeRange` is the whole point: without it the result is a
		// paragraph of text with no idea when any of it was said, which is a
		// transcript somebody can read and not one this program can cut with.
		//
		// No volatile results — those are for a live caption that refines
		// itself as it goes, and this is a file being read from disk. Asking
		// for them would mean sifting drafts out of the stream for nothing.
		let transcriber = SpeechTranscriber(
			locale: spoken,
			transcriptionOptions: [],
			reportingOptions: [],
			attributeOptions: [.audioTimeRange])

		try await install(for: transcriber, locale: spoken, onProgress: onProgress)

		let asset = AVURLAsset(url: source.url)
		let tracks: [AVAssetTrack]
		do { tracks = try await asset.loadTracks(withMediaType: .audio) }
		catch { throw Trouble.unreadable(source.url, error.localizedDescription) }
		guard let track = tracks.first else { throw Trouble.noAudio(source.url) }
		let duration = (try? await asset.load(.duration).seconds) ?? 0

		// What the model wants to be fed. Asked for rather than assumed: it is
		// 16 kHz mono today and the number is not this program's business.
		let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
			?? AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000,
			                 channels: 1, interleaved: false)!

		let input = try AudioFeed(
			asset: asset, track: track, format: format, url: source.url,
			total: duration, onProgress: onProgress)

		let analyzer = SpeechAnalyzer(modules: [transcriber])
		let collecting = Task { () -> [Word] in
			var found: [Word] = []
			for try await result in transcriber.results where result.isFinal {
				found += words(in: result.text)
			}
			return found
		}

		do {
			_ = try await analyzer.analyzeSequence(input)
			try await analyzer.finalizeAndFinishThroughEndOfInput()
		} catch {
			collecting.cancel()
			await analyzer.cancelAndFinishNow()
			throw error
		}

		let heard = try await collecting.value
		guard !heard.isEmpty else { throw Trouble.nothingHeard }
		return Made(
			transcript: Transcript(words: heard.compactMap(source.onVideoClock)),
			recogniser: .speechAnalyzer,
			locale: spoken.identifier(.bcp47))
	}

	/// One word per run of the attributed string, because that is what asking
	/// for `audioTimeRange` produces: the recogniser attributes each token with
	/// the stretch of audio it came from, and the runs are therefore the words.
	@available(macOS 26, *)
	private static func words(in text: AttributedString) -> [Word] {
		var found: [Word] = []
		for run in text.runs {
			guard let range = run.audioTimeRange else { continue }
			let spoken = String(text[run.range].characters)
				.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !spoken.isEmpty else { continue }
			let start = range.start.seconds
			let end = range.end.seconds
			guard start.isFinite, end.isFinite else { continue }
			found.append(Word(start: start, end: end, text: spoken))
		}
		return found
	}

	/// Makes sure the language model is on this Mac, fetching it if it is not.
	///
	/// The download is the honest thing to do rather than an error telling
	/// somebody to go and find it in System Settings: it is the same download
	/// either way, and this one can say how far along it is. It is still only a
	/// few hundred megabytes *once* — the model stays on the machine, and the
	/// second take in a session does not wait for it.
	@available(macOS 26, *)
	private static func install(
		for transcriber: SpeechTranscriber, locale: Locale,
		onProgress: @Sendable @escaping (Progress) -> Void
	) async throws {
		let name = locale.identifier(.bcp47)
		switch await AssetInventory.status(forModules: [transcriber]) {
		case .installed:
			break
		case .unsupported:
			throw Trouble.modelNotInstalled(locale: name)
		case .supported, .downloading:
			onProgress(Progress(seconds: 0, total: 1, note: "fetching the \(name) model…"))
			guard let request = try? await AssetInventory
				.assetInstallationRequest(supporting: [transcriber])
			else { throw Trouble.modelNotInstalled(locale: name) }
			let watching = Task { @Sendable in
				while !Task.isCancelled {
					onProgress(Progress(
						seconds: request.progress.fractionCompleted, total: 1,
						note: "fetching the \(name) model…"))
					try? await Task.sleep(nanoseconds: 200_000_000)
				}
			}
			defer { watching.cancel() }
			do { try await request.downloadAndInstall() }
			catch { throw Trouble.modelNotInstalled(locale: name) }
		@unknown default:
			break
		}
		// Reserved so the system does not evict the model between takes. It is
		// released when another locale needs the slot; there is nothing to undo.
		_ = try? await AssetInventory.reserve(locale: locale)
	}

	// MARK: - SFSpeechRecognizer, for a system without the above

	private static func withRecognizer(
		_ source: Source, locale: Locale,
		onProgress: @Sendable @escaping (Progress) -> Void
	) async throws -> Made {
		guard let recognizer = SFSpeechRecognizer(locale: locale) else {
			let known = SFSpeechRecognizer.supportedLocales().map { $0.identifier(.bcp47) }
			throw Trouble.localeNotSupported(asked: locale.identifier(.bcp47), available: known.sorted())
		}
		// Asked before anything is read, because the answer is the difference
		// between transcribing and uploading. `requiresOnDeviceRecognition` is
		// set as well — belt and braces, since a recogniser that says it can do
		// it on device and then does not would be a silent upload.
		guard recognizer.supportsOnDeviceRecognition else {
			throw Trouble.wouldLeaveTheMachine(locale: locale.identifier(.bcp47))
		}
		guard await authorised() else { throw Trouble.notAuthorised }

		let request = SFSpeechURLRecognitionRequest(url: source.url)
		request.requiresOnDeviceRecognition = true
		request.shouldReportPartialResults = false
		request.addsPunctuation = true

		onProgress(Progress(seconds: 0, total: 1, note: "listening…"))

		let segments: [SFTranscriptionSegment] = try await withCheckedThrowingContinuation { done in
			// Resumed exactly once: `shouldReportPartialResults` is off, so
			// there is one final result, and an error ends it either way.
			let box = OnceBox(done)
			recognizer.recognitionTask(with: request) { result, error in
				if let error { box.fail(error); return }
				guard let result, result.isFinal else { return }
				box.finish(result.bestTranscription.segments)
			}
		}

		let heard = segments.compactMap { segment -> Word? in
			let spoken = segment.substring.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !spoken.isEmpty else { return nil }
			return Word(start: segment.timestamp,
			            end: segment.timestamp + segment.duration,
			            text: spoken)
		}
		guard !heard.isEmpty else { throw Trouble.nothingHeard }
		return Made(
			transcript: Transcript(words: heard.compactMap(source.onVideoClock)),
			recogniser: .speechRecognizer,
			locale: locale.identifier(.bcp47))
	}

	private static func authorised() async -> Bool {
		switch SFSpeechRecognizer.authorizationStatus() {
		case .authorized: return true
		case .denied, .restricted: return false
		default:
			return await withCheckedContinuation { done in
				SFSpeechRecognizer.requestAuthorization { done.resume(returning: $0 == .authorized) }
			}
		}
	}
}

/// A continuation that may be resumed from a callback that fires more than
/// once. `SFSpeechRecognizer` does, on some errors.
private final class OnceBox: @unchecked Sendable {
	private let lock = NSLock()
	private var continuation: CheckedContinuation<[SFTranscriptionSegment], Error>?

	init(_ continuation: CheckedContinuation<[SFTranscriptionSegment], Error>) {
		self.continuation = continuation
	}

	func finish(_ value: [SFTranscriptionSegment]) {
		lock.withLock { continuation.take() }?.resume(returning: value)
	}

	func fail(_ error: Error) {
		lock.withLock { continuation.take() }?.resume(throwing: error)
	}
}

private extension Optional {
	/// Takes the value out, leaving nothing behind.
	mutating func take() -> Wrapped? {
		defer { self = nil }
		return self
	}
}

// MARK: - Feeding the analyser

/// The audio of a file, as the buffers a ``SpeechAnalyzer`` eats.
///
/// Pulled rather than pushed, and that is the point. The obvious shape is an
/// `AsyncStream` that a decode loop fills as fast as the disk allows, and it
/// has no backpressure: the recogniser is slower than the decoder, so a
/// forty-minute take would sit in memory as a hundred and fifty megabytes of
/// PCM waiting to be listened to. Here the analyser asks for the next buffer
/// and the next buffer is decoded, so what is in flight is one of them.
///
/// The decode itself happens on a queue of its own. `copyNextSampleBuffer`
/// blocks, and blocking a thread of the cooperative pool holds a core that
/// every other task in the program is queued behind — the same reason the
/// waveform extractor has a queue.
@available(macOS 26, *)
private struct AudioFeed: AsyncSequence, Sendable {
	typealias Element = AnalyzerInput

	private let reel: Reel

	init(asset: AVURLAsset, track: AVAssetTrack, format: AVAudioFormat, url: URL,
	     total: Double, onProgress: @escaping @Sendable (Transcriber.Progress) -> Void) throws {
		reel = try Reel(asset: asset, track: track, format: format, url: url,
		                total: total, onProgress: onProgress)
	}

	func makeAsyncIterator() -> Iterator { Iterator(reel: reel) }

	struct Iterator: AsyncIteratorProtocol {
		let reel: Reel
		func next() async -> AnalyzerInput? {
			await withCheckedContinuation { resume in
				Reel.queue.async { resume.resume(returning: reel.next()) }
			}
		}
	}

	/// The reader and its buffer. `@unchecked Sendable` because everything in
	/// here is touched on ``queue`` and nowhere else — the iterator hands the
	/// work over and waits for it.
	final class Reel: @unchecked Sendable {
		static let queue = DispatchQueue(label: "de.rnd7.cuttr.transcribe", qos: .userInitiated)

		private let reader: AVAssetReader
		private let output: AVAssetReaderOutput
		private let format: AVAudioFormat
		private let total: Double
		private let onProgress: @Sendable (Transcriber.Progress) -> Void
		private var started = false

		init(asset: AVURLAsset, track: AVAssetTrack, format: AVAudioFormat, url: URL,
		     total: Double, onProgress: @escaping @Sendable (Transcriber.Progress) -> Void) throws {
			self.format = format
			self.total = total
			self.onProgress = onProgress

			let description = format.streamDescription.pointee
			// Mono, whatever arrived. A recogniser listens to one voice and a
			// stereo pair of the same room is the same voice twice.
			var layout = AudioChannelLayout()
			layout.mChannelLayoutTag = kAudioChannelLayoutTag_Mono
			let layoutData = withUnsafeBytes(of: &layout) { Data($0) }
			let settings: [String: Any] = [
				AVFormatIDKey: kAudioFormatLinearPCM,
				AVSampleRateKey: description.mSampleRate,
				AVNumberOfChannelsKey: 1,
				AVLinearPCMBitDepthKey: Int(description.mBitsPerChannel),
				AVLinearPCMIsFloatKey: description.mFormatFlags & kAudioFormatFlagIsFloat != 0,
				AVLinearPCMIsBigEndianKey: false,
				AVLinearPCMIsNonInterleaved: false,
				AVChannelLayoutKey: layoutData,
			]

			do { reader = try AVAssetReader(asset: asset) }
			catch { throw Transcriber.Trouble.unreadable(url, error.localizedDescription) }
			let mix = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: settings)
			mix.alwaysCopiesSampleData = false
			guard reader.canAdd(mix) else {
				throw Transcriber.Trouble.unreadable(url, "the decoder refused \(Int(description.mSampleRate)) Hz mono")
			}
			reader.add(mix)
			output = mix
		}

		/// The next buffer, or `nil` at the end. On ``queue`` only.
		func next() -> AnalyzerInput? {
			if !started {
				started = true
				guard reader.startReading() else { return nil }
			}
			while let sample = output.copyNextSampleBuffer() {
				defer { CMSampleBufferInvalidate(sample) }
				guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
				var length = 0
				var pointer: UnsafeMutablePointer<Int8>?
				guard CMBlockBufferGetDataPointer(
					block, atOffset: 0, lengthAtOffsetOut: nil,
					totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
					let base = pointer, length > 0
				else { continue }

				let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
				guard bytesPerFrame > 0 else { continue }
				let frames = AVAudioFrameCount(length / bytesPerFrame)
				guard frames > 0,
				      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
				else { continue }
				buffer.frameLength = frames
				let destination = buffer.mutableAudioBufferList.pointee.mBuffers
				guard let target = destination.mData else { continue }
				memcpy(target, base, Swift.min(length, Int(destination.mDataByteSize)))

				let at = CMSampleBufferGetPresentationTimeStamp(sample)
				onProgress(Transcriber.Progress(
					seconds: at.seconds.isFinite ? at.seconds : 0,
					total: total, note: "listening…"))
				return AnalyzerInput(buffer: buffer, bufferStartTime: at)
			}
			return nil
		}
	}
}
