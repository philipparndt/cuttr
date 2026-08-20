import AVFoundation
import Foundation
import SoundAnalysis

/// The sounds in a take that are not words, worked out on this machine.
///
/// **Nothing leaves the machine**, for the same reason nothing leaves it in
/// ``Transcriber``: the classifier is a model that ships with macOS and has no
/// network path at all. Somebody's unreleased footage stays theirs.
///
/// **The times come back on the video's clock.** It listens to whichever file
/// the transcriber would have listened to — usually the separate recorder,
/// which has a clock of its own — and hands every hit through the same
/// ``Transcriber/Source`` that moves a word onto the take's clock. A sound
/// event written down on the wrong clock is the exact failure this program
/// exists to avoid, and there is one piece of arithmetic in the program that
/// can make it, not two.
///
/// It is fast enough not to be worth thinking about: 332 seconds of a real
/// recording read in two and a half, which is a hundred and thirty times faster
/// than listening to it.
public enum SoundSpotter {

	/// A second at a time, hopping half a second.
	///
	/// The window is what the model was trained on and the overlap is what
	/// stops a laugh that straddles a boundary from being half a laugh twice.
	/// The price is that one event arrives as four or five hits, which is what
	/// ``SoundEvent/merge(_:joining:floor:bridging:)`` is for.
	public static let window = 1.0
	public static let overlap = 0.5

	public enum Trouble: LocalizedError {
		case noClassifier(String)
		case noAudio(URL)
		case unreadable(URL, String)

		public var errorDescription: String? {
			switch self {
			case .noClassifier(let message):
				return "This Mac's sound classifier would not start: \(message)"
			case .noAudio(let url):
				return "\(url.lastPathComponent) has no audio to listen to."
			case .unreadable(let url, let message):
				return "Could not read \(url.lastPathComponent): \(message)"
			}
		}
	}

	/// How far along, in the same shape ``Transcriber/Progress`` uses, so a
	/// window showing one can show the other without a second kind of bar.
	public struct Progress: Sendable {
		public let seconds: Double
		public let total: Double
		public let note: String

		public var fraction: Double { total > 0 ? min(seconds / total, 1) : 0 }
	}

	/// Listens to `source` and reports the events worth writing down, on the
	/// video's clock, in the order they happened.
	public static func listen(
		_ source: Transcriber.Source,
		onProgress: @Sendable @escaping (Progress) -> Void = { _ in }
	) async throws -> [SoundEvent] {
		let asset = AVURLAsset(url: source.url)
		let tracks: [AVAssetTrack]
		do { tracks = try await asset.loadTracks(withMediaType: .audio) }
		catch { throw Trouble.unreadable(source.url, error.localizedDescription) }
		guard !tracks.isEmpty else { throw Trouble.noAudio(source.url) }
		let length = (try? await asset.load(.duration).seconds) ?? 0

		let analyzer: SNAudioFileAnalyzer
		let request: SNClassifySoundRequest
		do {
			analyzer = try SNAudioFileAnalyzer(url: source.url)
			request = try SNClassifySoundRequest(classifierIdentifier: .version1)
		} catch {
			throw Trouble.noClassifier(error.localizedDescription)
		}
		request.windowDuration = CMTime(seconds: window, preferredTimescale: 48_000)
		request.overlapFactor = overlap

		let collected = Collector(total: length, onProgress: onProgress)
		do { try analyzer.add(request, withObserver: collected) }
		catch { throw Trouble.noClassifier(error.localizedDescription) }

		await withCheckedContinuation { done in
			analyzer.analyze { _ in done.resume() }
		}

		// Merged first, then moved: the merge is about windows of one recording
		// and knows nothing about takes, and moving five windows one at a time
		// only to merge them afterwards would be the same answer reached the
		// long way round.
		return SoundEvent.merge(collected.windows).compactMap(source.onVideoClock)
	}

	/// What the classifier says, kept only where it says something this program
	/// writes down.
	///
	/// `@unchecked Sendable` and a lock, because `SNAudioFileAnalyzer` calls
	/// back on a queue of its own and the array is read once, afterwards, on
	/// whichever thread resumed the continuation.
	private final class Collector: NSObject, SNResultsObserving, @unchecked Sendable {
		private let lock = NSLock()
		private var found: [SoundEvent] = []
		private let total: Double
		private let onProgress: @Sendable (Progress) -> Void

		init(total: Double, onProgress: @escaping @Sendable (Progress) -> Void) {
			self.total = total
			self.onProgress = onProgress
		}

		var windows: [SoundEvent] { lock.withLock { found } }

		func request(_ request: SNRequest, didProduce result: SNResult) {
			guard let heard = result as? SNClassificationResult else { return }
			let start = heard.timeRange.start.seconds
			let end = start + heard.timeRange.duration.seconds
			guard start.isFinite, end.isFinite else { return }
			var window: [SoundEvent] = []
			for guess in heard.classifications {
				guard guess.confidence >= SoundEvent.joining,
				      let kind = SoundEvent.kind(forClassifier: guess.identifier)
				else { continue }
				window.append(SoundEvent(kind: kind, start: start, end: end,
				                         confidence: guess.confidence))
			}
			guard !window.isEmpty else {
				onProgress(Progress(seconds: start, total: total, note: "listening for laughter…"))
				return
			}
			lock.withLock { found += window }
			onProgress(Progress(seconds: start, total: total, note: "listening for laughter…"))
		}

		func request(_ request: SNRequest, didFailWithError error: Error) {}
	}
}
