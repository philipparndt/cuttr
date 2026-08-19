import CoreGraphics
import Foundation

/// The programme played off a tape that has been played too often.
///
/// Not one effect but five, and the reason they are one overlay is that no
/// single one of them says "video tape" on its own: scanlines alone are a
/// monitor, a wobble alone is a bad export, chroma smeared sideways alone is a
/// broken decoder. Together they are a VHS, and the five knobs are there so
/// somebody can have four of them and not the fifth.
///
/// Everything is deterministic from ``seed`` and the time, so a render can be
/// repeated. That is not a nicety: a director who liked the third take has to
/// be able to get that one back, and "it is random" is not an answer.
public struct Tape: Sendable, Equatable {

	/// How the tape has been treated. Named for the tape rather than for the
	/// five numbers, because that is how anybody chooses one — the numbers are
	/// there to disagree with afterwards.
	public enum Condition: String, Sendable, CaseIterable {
		/// A good tape on a good machine: lines, a little colour smear, and
		/// nothing else.
		case clean
		/// Played a hundred times. The tracking wanders, a band of noise
		/// crawls up the picture, the colour runs.
		case worn
		/// The one the machine has been eating. Everything, and dropouts.
		case chewed
	}

	public var condition: Condition
	/// The tracking wobble: rows of the picture pushed sideways, by different
	/// amounts, changing as it plays. 1 is a fifth of the frame at its worst.
	public var jitter: Double
	/// The band of brighter noise that crawls up the frame. 1 is a broad one.
	public var band: Double
	/// Colour running sideways off the edges in the picture — the thing VHS is
	/// least able to hide, because it carried the colour at a quarter of the
	/// detail of the brightness.
	public var chroma: Double
	/// The lines. 1 puts every other line half way into shadow, which is more
	/// than any monitor ever did and is what somebody will ask for anyway.
	public var scanlines: Double
	/// White streaks where the tape has lost its oxide, a field at a time.
	public var dropouts: Double
	/// The same number gives the same wobble, every render, on every machine.
	public var seed: Int

	public init(_ condition: Condition = .worn, seed: Int = 1) {
		self.condition = condition
		self.seed = seed
		let settings = Self.settings(condition)
		jitter = settings.jitter
		band = settings.band
		chroma = settings.chroma
		scanlines = settings.scanlines
		dropouts = settings.dropouts
	}

	/// What each condition is, as the five numbers. One place, so the panel and
	/// the writer cannot disagree about what `worn` means — the writer leaves a
	/// knob out of the file exactly when it is still what the condition says.
	public static func settings(
		_ condition: Condition
	) -> (jitter: Double, band: Double, chroma: Double, scanlines: Double, dropouts: Double) {
		switch condition {
		case .clean: return (0.05, 0, 0.15, 0.25, 0)
		case .worn: return (0.35, 0.4, 0.4, 0.35, 0.2)
		case .chewed: return (0.8, 0.8, 0.7, 0.45, 0.7)
		}
	}
}
