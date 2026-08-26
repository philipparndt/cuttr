import AVFoundation
import Foundation

/// What the app needs to know about a media file before it can show it.
public struct MediaInfo: Sendable, Equatable {
	public let url: URL
	public let duration: Double
	/// The frames a cut mark can land on, or ``FrameGrid/none`` for audio and
	/// for variable-rate recordings.
	public let grid: FrameGrid
	public let hasVideo: Bool
	public let hasAudio: Bool
	/// Pixel dimensions of the video track, for sizing the player pane.
	public let naturalSize: CGSize
}

/// A file macOS will hand over and cannot decode.
///
/// **Why this exists as its own error.** A `.webm` is offered by every open
/// panel in this program, because macOS knows the extension, gives it a type —
/// `org.webmproject.webm` — and says that type conforms to `public.movie`. So
/// it can be chosen. It cannot be read: AVFoundation has no VP8, no VP9 and no
/// Matroska, and answers `Cannot Open` with an error code.
///
/// What that produced was a take that resolved, appeared in the material tree,
/// and had no picture, no waveform and no render — with `The operation could not
/// be completed` somewhere off to one side. This says which file, what format,
/// and what to do instead.
public struct Unreadable: LocalizedError, Sendable, Equatable {
	public let url: URL
	/// What the format is called, when it has a name worth using. `nil` for one
	/// nobody would recognise by name, where the extension says more.
	public let format: String?

	public init(url: URL, format: String?) {
		self.url = url
		self.format = format
	}

	public var errorDescription: String? {
		let file = url.lastPathComponent
		guard let format else {
			return "cuttr cannot read \(file) — macOS has no decoder for it. "
				+ "Convert it to .mov or .mp4 first."
		}
		return "cuttr cannot read \(format) — macOS has no decoder for it, so nothing "
			+ "on this Mac can open \(file) except a browser. Convert it to .mov or "
			+ ".mp4 first."
	}

	/// What a format is called, for the ones somebody would recognise by name.
	///
	/// Only used once a file has *already* failed to open, so this is about
	/// wording and never about deciding whether something will work. Guessing
	/// that from an extension is how a format that starts being supported goes
	/// on being refused.
	static func named(_ url: URL) -> String? {
		switch url.pathExtension.lowercased() {
		case "webm": return "WebM"
		case "mkv": return "Matroska"
		case "ogv", "ogg", "oga": return "Ogg"
		case "flv": return "Flash Video"
		case "wmv", "asf": return "Windows Media"
		case "rm", "rmvb": return "RealMedia"
		default: return nil
		}
	}
}

public enum MediaProbe {

	/// Reads duration, frame rate and track layout.
	///
	/// `async` because `AVAsset`'s synchronous properties were deprecated for a
	/// good reason: on a file that is still being written, or one on a network
	/// volume, they block whichever thread asks — which for this app is the one
	/// drawing the timeline.
	public static func probe(_ url: URL) async throws -> MediaInfo {
		let asset = AVURLAsset(url: url)
		let duration: Double
		let videoTracks: [AVAssetTrack]
		let audioTracks: [AVAssetTrack]
		do {
			duration = try await asset.load(.duration).seconds
			videoTracks = try await asset.loadTracks(withMediaType: .video)
			audioTracks = try await asset.loadTracks(withMediaType: .audio)
		} catch {
			// A file that is *there* and will not open. Said as itself rather
			// than as AVFoundation's code, because the commonest cause is a
			// format every open panel in this program offers and nothing here
			// can read — see ``Unreadable``.
			guard FileManager.default.fileExists(atPath: url.path) else { throw error }
			throw Unreadable(url: url, format: Unreadable.named(url))
		}
		// Open, and with nothing in it. A container macOS can parse whose
		// streams it cannot decode comes out this way rather than as a failure,
		// and a take with no tracks is as useless as one that would not open.
		guard !videoTracks.isEmpty || !audioTracks.isEmpty else {
			throw Unreadable(url: url, format: Unreadable.named(url))
		}

		var grid = FrameGrid.none
		var size = CGSize.zero
		if let track = videoTracks.first {
			let (rate, natural) = try await track.load(.nominalFrameRate, .naturalSize)
			// A rate of zero is what a variable-rate recording reports, and a
			// screen capture usually is one. No grid is the truthful answer;
			// snapping to an invented 30 fps would move every mark somebody set.
			if rate > 0 { grid = FrameGrid(framesPerSecond: Double(rate)) }
			size = natural
		}

		return MediaInfo(
			url: url,
			duration: duration.isFinite ? duration : 0,
			grid: grid,
			hasVideo: !videoTracks.isEmpty,
			hasAudio: !audioTracks.isEmpty,
			naturalSize: size
		)
	}
}
