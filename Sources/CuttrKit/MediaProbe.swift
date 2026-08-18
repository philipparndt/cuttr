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

public enum MediaProbe {

	/// Reads duration, frame rate and track layout.
	///
	/// `async` because `AVAsset`'s synchronous properties were deprecated for a
	/// good reason: on a file that is still being written, or one on a network
	/// volume, they block whichever thread asks — which for this app is the one
	/// drawing the timeline.
	public static func probe(_ url: URL) async throws -> MediaInfo {
		let asset = AVURLAsset(url: url)
		let duration = try await asset.load(.duration).seconds
		let videoTracks = try await asset.loadTracks(withMediaType: .video)
		let audioTracks = try await asset.loadTracks(withMediaType: .audio)

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
