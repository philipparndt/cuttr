import Foundation

/// A point in time on a recording, in seconds.
///
/// Seconds rather than a frame count, and `Double` rather than `CMTime`.
///
/// A frame count would be the obvious choice for a video editor and is the
/// wrong one here, because half of what this program lines up is *audio*: a
/// separate recorder samples at 48 kHz and knows nothing about 25 or 30 frames
/// a second, and the whole point of the alignment pane is to express an offset
/// finer than a frame. Counting frames would round the answer away before it
/// could be shown.
///
/// `Double` rather than `CMTime` because a cut list is a text file that people
/// and other programs read. A `CMTime` is a rational with a timescale attached,
/// and round-tripping one through `00:12.300` invents a denominator that was
/// never in the file. The conversion to `CMTime` happens once, at the edge, in
/// ``Timecode/cmTime(preferredTimescale:)``, where a player needs one.
///
/// Precision: a `Double` holds a whole number of microseconds exactly out past
/// a hundred hours, so nothing a recording can be long enough to lose.
public enum Timecode {

	/// Parses `HH:MM:SS.mmm`, `MM:SS.mmm`, `SS.mmm` or a bare number of seconds.
	///
	/// All four are accepted because all four get typed. The app writes one
	/// form (``string(_:)``), but the file is meant to be edited by hand, and
	/// somebody who writes `90` for a minute and a half is not making a mistake
	/// that is worth an error message.
	///
	/// A leading `-` is accepted and applies to the whole value, which is what
	/// an audio offset needs: `-00:01.250` is the audio running early.
	public static func parse(_ text: String) -> Double? {
		var s = text.trimmingCharacters(in: .whitespaces)
		guard !s.isEmpty else { return nil }

		var sign = 1.0
		if s.hasPrefix("-") { sign = -1; s.removeFirst() }
		else if s.hasPrefix("+") { s.removeFirst() }

		// Split on `:` and fold from the left, so the same code reads two
		// fields or three: each field is sixty times the one after it.
		let fields = s.split(separator: ":", omittingEmptySubsequences: false)
		guard fields.count <= 3 else { return nil }

		var total = 0.0
		for (index, field) in fields.enumerated() {
			guard let value = Double(field), value >= 0, field.rangeOfCharacter(from: rejected) == nil
			else { return nil }
			// Only the last field may be fractional; `1.5:00` is not a time.
			if index < fields.count - 1 && value != value.rounded(.down) { return nil }
			total = total * 60 + value
		}
		return sign * total
	}

	/// `Double(_:)` accepts things a timecode is not — `1e3`, `0x10`, `inf`,
	/// and a `-` in the middle of a field. Rejecting the characters is cheaper
	/// and clearer than re-implementing the number grammar.
	private static let rejected = CharacterSet(charactersIn: "eExXnNiIfF+-")

	/// Formats for the file and for the screen: `MM:SS.mmm`, or
	/// `HH:MM:SS.mmm` once there is an hour to show.
	///
	/// The hours field appears only when it is non-zero, which is what makes a
	/// column of clip times readable — most takes are minutes long, and
	/// `00:00:12.300` spends four characters saying so. A parser that accepts
	/// both forms is what buys this, and it does.
	public static func string(_ seconds: Double) -> String {
		let negative = seconds < 0
		// Round once, in milliseconds, so that 12.9996 shows as 13.000 rather
		// than as 12.1000 from a floor of the seconds and a round of the rest.
		let ms = Int((abs(seconds) * 1000).rounded())
		let (whole, milli) = (ms / 1000, ms % 1000)
		let (h, m, s) = (whole / 3600, (whole / 60) % 60, whole % 60)
		let sign = negative ? "-" : ""
		if h > 0 {
			return String(format: "%@%d:%02d:%02d.%03d", sign, h, m, s, milli)
		}
		return String(format: "%@%02d:%02d.%03d", sign, m, s, milli)
	}

	/// A signed offset, always with its sign, for the alignment field.
	public static func offsetString(_ seconds: Double) -> String {
		(seconds < 0 ? "" : "+") + string(seconds)
	}
}

/// Snapping to the frames a video actually has.
///
/// Cut marks are placed against audio, which is continuous, but the renderer
/// hands whole frames to an encoder. A mark half-way through a frame is a mark
/// the renderer has to round, and rounding it *there* means the file says one
/// thing and the output is another. So the app rounds here, where it can be
/// seen, and the file holds the rounded value.
///
/// The rate is `nominal`: what the track declares. Variable-rate recordings
/// (a screen capture is usually one) do not have a grid to snap to at all,
/// which is why ``FrameGrid/none`` exists and is not an error.
public struct FrameGrid: Sendable, Equatable {
	public let framesPerSecond: Double

	public init(framesPerSecond: Double) { self.framesPerSecond = framesPerSecond }

	/// No grid: audio-only, or a recording whose frame rate is not fixed.
	public static let none = FrameGrid(framesPerSecond: 0)

	public var hasGrid: Bool { framesPerSecond > 0 }

	/// The nearest frame boundary, or the time unchanged when there is no grid.
	public func snap(_ seconds: Double) -> Double {
		guard hasGrid else { return seconds }
		return (seconds * framesPerSecond).rounded() / framesPerSecond
	}

	/// One frame, in seconds — the step an arrow key takes.
	///
	/// Without a grid, 10 ms: small enough to be a fine step and large enough
	/// that holding the key crosses a sentence.
	public var frameDuration: Double { hasGrid ? 1 / framesPerSecond : 0.01 }
}
