@preconcurrency import AVFoundation
import Foundation

/// Bringing a meme into a project.
///
/// The whole design of this is that there is nothing new downstream. A meme is
/// a short recording with one span cut out of it, which is a take — so what
/// arrives is a `.cuttr` file beside the project's other takes, pointing at an
/// mp4 in `memes/`, with one clip covering the whole thing. The library lists
/// it, the timeline takes it, the resolver resolves it and the renderer renders
/// it, and not one of them had to learn the word.
public enum MemeDownload {

	/// The folder downloads go in, beside the project. Named rather than
	/// derived from anything, so that a person looking at the folder knows what
	/// they are looking at and can delete it.
	public static let folderName = "memes"

	public struct Downloaded: Sendable {
		/// The take file written for it.
		public let take: URL
		/// The media, in `memes/`.
		public let video: URL
		/// What a project writes to put it on the programme.
		public let slug: String
	}

	/// How the bytes arrive. Injected for the same reason the search's is: what
	/// this file decides — the name, the slug, the take — is decided the same
	/// way whether the bytes came off the network or out of a test.
	public typealias Fetch = @Sendable (URL) async throws -> Data

	public static let live: Fetch = { url in
		var request = URLRequest(url: url)
		request.timeoutInterval = 60
		let (data, response) = try await URLSession.shared.data(for: request)
		if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
			throw MemeError.providerDown(.giphy, "the download came back HTTP \(http.statusCode)")
		}
		return data
	}

	// MARK: - Naming

	/// What to call it, as a file and as a reference.
	///
	/// GIPHY titles are written for a search engine — "Facepalm GIF by Cartoon
	/// Hangover" — and the part somebody would type is the first word or two.
	/// The rest is not thrown away: the title as the service gave it goes into
	/// the take's `source:` block, so nothing is lost and the reference stays
	/// short enough to write in a project file by hand.
	public static func slug(for result: MemeResult, taken: Set<String> = []) -> String {
		var title = result.title
		// "<what it is> GIF by <who made it>". Everything from the GIF on is
		// the service's own furniture.
		for marker in [" GIF by ", " Sticker by ", " GIF", " Sticker"] {
			if let range = title.range(of: marker) {
				title = String(title[title.startIndex..<range.lowerBound])
				break
			}
		}
		var slug = Slug.make(from: title)
		// A file name, and something to type. Cut at a hyphen so the tail is a
		// whole word rather than half of one.
		if slug.count > 32, let cut = slug.prefix(33).lastIndex(of: "-") {
			slug = String(slug[slug.startIndex..<cut])
		}
		// A meme with no usable title still needs a name, and the service's own
		// identifier is the one thing it is guaranteed to have.
		if slug.isEmpty { slug = Slug.make(from: "\(result.provider.rawValue)-\(result.id)") }
		return Slug.unique(slug, taken: taken)
	}

	/// The take a downloaded meme is.
	///
	/// One clip, covering all of it, because that is what a meme is: there is
	/// nothing to cut out of two seconds of a cat. It is an ordinary clip and
	/// can be trimmed on the programme like any other, which is the point.
	public static func take(for result: MemeResult, video path: String, duration: Double,
	                        slug: String) -> Take {
		Take(
			video: path,
			clips: [Clip(slug: slug, name: result.title, start: 0, end: max(duration, 0.04))],
			source: TakeSource(
				provider: result.provider.rawValue,
				id: result.id,
				page: result.page?.absoluteString,
				title: result.title.isEmpty ? nil : result.title,
				attribution: result.provider.attribution))
	}

	/// A path from one file to another, when both are under one folder.
	///
	/// Every path in a project is relative to the file that holds it — that is
	/// what makes a project, its takes and its media one folder somebody can
	/// copy to another disk. A take in `takes/` pointing at media in `memes/`
	/// therefore writes `../memes/…`, and works out that way rather than being
	/// spelled out, so moving either folder does not need this code changed.
	///
	/// `standardized` and deliberately not `standardizedFileURL`, which is the
	/// one that consults the file system — and which produced an absolute path
	/// here on the first real download. The media had just been written and the
	/// take file had not, so the same folder standardized to `/tmp/…` for the
	/// one that existed and stayed `/private/tmp/…` for the one that did not:
	/// two paths with nothing in common, and no relative path between them.
	/// Comparing them as text is both correct and the only thing that can be
	/// correct, since one of the two files is always about to be created.
	public static func relativePath(from base: URL, to target: URL) -> String {
		let baseParts = base.standardized.deletingLastPathComponent().pathComponents
		let targetParts = target.standardized.pathComponents
		var shared = 0
		while shared < baseParts.count, shared < targetParts.count,
		      baseParts[shared] == targetParts[shared] { shared += 1 }
		let ups = baseParts.count - shared
		guard ups <= 3 else { return target.path }
		return (Array(repeating: "..", count: ups) + targetParts[shared...]).joined(separator: "/")
	}

	// MARK: - Doing it

	/// Downloads one, writes its take, and says where both went.
	///
	/// `takes` is where the project keeps its take files and `project` is the
	/// folder the project file sits in; the media goes in `memes/` under the
	/// latter. Both are required rather than derived, because a project that
	/// has not been saved has no folder and a meme has nowhere to be — which is
	/// the same rule that already applies to adding a take.
	public static func fetch(
		_ result: MemeResult, project: URL, takes: URL, fetch: Fetch = live
	) async throws -> Downloaded {
		let memes = project.appendingPathComponent(folderName, isDirectory: true)
		try FileManager.default.createDirectory(at: memes, withIntermediateDirectories: true)
		try FileManager.default.createDirectory(at: takes, withIntermediateDirectories: true)

		let slug = slug(for: result, taken: namesInUse(memes: memes, takes: takes))
		let suffix = result.video.pathExtension.isEmpty ? "mp4" : result.video.pathExtension
		var video = memes.appendingPathComponent(slug).appendingPathExtension(suffix)

		let data = try await fetch(result.video)
		guard !data.isEmpty else { throw MemeError.noVideo(result.title) }
		try data.write(to: video, options: .atomic)

		var info = try await MediaProbe.probe(video)
		guard info.hasVideo else {
			try? FileManager.default.removeItem(at: video)
			throw MemeError.noVideo(result.title)
		}
		// The file is kept as it came.
		//
		// It used to get a track of its own silence stitched under it, because
		// AVFoundation's exporter refused a composition whose audio track never
		// had anything put in it — a programme of one silent meme would not
		// export at all. That was a bug in the renderer, and it has been fixed:
		// empty tracks are dropped before the export sees them, and a hole in a
		// lane is heard as silence rather than pulling the next shot's sound
		// forward. So a meme is now the file the service served, with the
		// extension it came with, and no re-muxing on the way in.
		//
		// What it does *not* have is sound: a meme from a GIF search never did.
		// Both services serve these as silent mp4s because they are GIFs
		// underneath, and Giphy's Clips — the ones with audio — are behind an
		// endpoint that answers 403 to an ordinary key.
		let takeURL = takes.appendingPathComponent(slug).appendingPathExtension("cuttr")
		let take = take(for: result, video: relativePath(from: takeURL, to: video),
		                duration: info.duration, slug: slug)
		try TakeWriter.write(take).write(to: takeURL, atomically: true, encoding: .utf8)
		return Downloaded(take: takeURL, video: video, slug: slug)
	}

	/// Names already spoken for, so a second facepalm does not overwrite the
	/// first.
	private static func namesInUse(memes: URL, takes: URL) -> Set<String> {
		let manager = FileManager.default
		let listed = (try? manager.contentsOfDirectory(atPath: memes.path)) ?? []
		let existing = (try? manager.contentsOfDirectory(atPath: takes.path)) ?? []
		// The names as the folder gives them, without their extensions, and as
		// text: `URL(fileURLWithPath:)` on a bare name resolves it against the
		// working directory, so this was a set of absolute paths that no slug
		// could ever match — and the second facepalm quietly overwrote the
		// first.
		return Set((listed + existing).map { ($0 as NSString).deletingPathExtension })
	}

	/// The same picture with a silent audio track under it.
	///
	/// Passthrough, so the video is copied rather than re-encoded: a meme that
	/// has been through an H.264 transcode on the way in should not go through
	/// a second one on the way to disk. The silence is a real file of real
	/// zeroes rather than an empty range in the composition, because an empty
	/// range is exactly what the exporter objected to in the first place.
	///
	/// Returns the new file, which is a `.mov`: it is a QuickTime container
	/// now, and calling it `.mp4` would be a lie told to whoever reads the
	/// folder.
	static func withSilence(_ url: URL, duration: Double) async throws -> URL {
		let silence = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("cuttr-silence-\(UUID().uuidString).wav")
		defer { try? FileManager.default.removeItem(at: silence) }
		try writeSilence(to: silence, seconds: max(duration, 0.1))

		let composition = AVMutableComposition()
		let source = AVURLAsset(url: url)
		let span = CMTimeRange(start: .zero, duration: try await source.load(.duration))
		guard let videoTrack = composition.addMutableTrack(
			withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
			let audioTrack = composition.addMutableTrack(
				withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid),
			let sourceVideo = try await source.loadTracks(withMediaType: .video).first
		else { throw MemeError.noVideo(url.lastPathComponent) }
		try videoTrack.insertTimeRange(span, of: sourceVideo, at: .zero)
		let quiet = AVURLAsset(url: silence)
		if let quietTrack = try await quiet.loadTracks(withMediaType: .audio).first {
			try audioTrack.insertTimeRange(
				CMTimeRange(start: .zero, duration: min(span.duration,
				                                        try await quiet.load(.duration))),
				of: quietTrack, at: .zero)
		}

		let output = url.deletingPathExtension().appendingPathExtension("mov")
		try? FileManager.default.removeItem(at: output)
		guard let session = AVAssetExportSession(
			asset: composition, presetName: AVAssetExportPresetPassthrough)
		else { throw MemeError.noVideo(url.lastPathComponent) }
		session.outputURL = output
		session.outputFileType = .mov
		await session.export()
		guard session.status == .completed else {
			try? FileManager.default.removeItem(at: output)
			// Not fatal. A meme with no sound still plays and still renders in
			// any programme that has sound elsewhere in it; only the all-memes
			// programme is the one that would have failed.
			throw MemeError.providerDown(
				.giphy, session.error?.localizedDescription ?? "could not add a silent track")
		}
		return output
	}

	/// A WAV of nothing, for as long as the picture runs.
	///
	/// The buffer is made in the file's own `processingFormat` rather than in
	/// the format the file is written in, and that is not a detail: an
	/// `AVAudioFile` converts on the way out, and handing it a buffer in the
	/// on-disk format instead fails with `ExtAudioFileWrite` −50, which is what
	/// this did on the first attempt.
	static func writeSilence(to url: URL, seconds: Double) throws {
		let file = try AVAudioFile(forWriting: url, settings: [
			AVFormatIDKey: kAudioFormatLinearPCM,
			AVSampleRateKey: 48000.0,
			AVNumberOfChannelsKey: 2,
			AVLinearPCMBitDepthKey: 16,
			AVLinearPCMIsFloatKey: false,
			AVLinearPCMIsBigEndianKey: false,
			AVLinearPCMIsNonInterleaved: false,
		])
		guard let buffer = AVAudioPCMBuffer(
			pcmFormat: file.processingFormat,
			frameCapacity: AVAudioFrameCount(file.processingFormat.sampleRate * seconds))
		else { throw MemeError.noVideo(url.lastPathComponent) }
		// Zeroes, which is what a fresh buffer already holds. Saying so because
		// the absence of a fill loop here looks like an omission and is not.
		buffer.frameLength = buffer.frameCapacity
		try file.write(from: buffer)
	}
}
