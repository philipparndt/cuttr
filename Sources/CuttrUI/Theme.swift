import AppKit
import CuttrKit

/// The palette and the metrics, in one place.
///
/// Fixed and dark rather than following the system appearance. A waveform is
/// judged by eye — is that a breath or the start of the word — and the same
/// grey has to mean the same amplitude in every session. A light mode would
/// need a second set of contrasts tuned against a white ground, and nobody
/// grades audio on white.
public enum Theme {
	public static let background = NSColor(calibratedWhite: 0.10, alpha: 1)
	public static let panel = NSColor(calibratedWhite: 0.14, alpha: 1)
	public static let rule = NSColor(calibratedWhite: 0.24, alpha: 1)
	public static let text = NSColor(calibratedWhite: 0.88, alpha: 1)
	public static let dimText = NSColor(calibratedWhite: 0.55, alpha: 1)

	/// The camera's own audio, and the separate recorder's. Two hues, because
	/// the whole alignment task is telling one from the other at a glance.
	public static let cameraWave = NSColor(calibratedRed: 0.42, green: 0.62, blue: 0.85, alpha: 1)
	public static let externalWave = NSColor(calibratedRed: 0.95, green: 0.72, blue: 0.32, alpha: 1)

	/// The clip palette.
	///
	/// Chosen to stay apart from each other *and* from the two waveform hues,
	/// because a clip bar sits directly above a camera lane drawn in blue and a
	/// recorder lane drawn in amber. The clip blue is darker and the clip amber
	/// redder than the waveforms they sit over, which is what keeps a coloured
	/// region from reading as part of the audio underneath it.
	public static func base(_ color: ClipColor) -> NSColor {
		switch color {
		case .green:  return NSColor(calibratedRed: 0.36, green: 0.82, blue: 0.60, alpha: 1)
		case .blue:   return NSColor(calibratedRed: 0.36, green: 0.58, blue: 0.95, alpha: 1)
		case .amber:  return NSColor(calibratedRed: 0.95, green: 0.62, blue: 0.25, alpha: 1)
		case .violet: return NSColor(calibratedRed: 0.68, green: 0.52, blue: 0.95, alpha: 1)
		case .rose:   return NSColor(calibratedRed: 0.95, green: 0.42, blue: 0.55, alpha: 1)
		case .teal:   return NSColor(calibratedRed: 0.30, green: 0.78, blue: 0.80, alpha: 1)
		}
	}

	/// The bar's outline, its fill, and the wash over the waveform lanes.
	///
	/// Three alphas of one hue rather than three colours. The wash is faint on
	/// purpose: several of them overlap, and each one has to stay readable
	/// through the others — two stacked regions at 0.30 would be a solid block.
	public static func clipStroke(_ color: ClipColor) -> NSColor { base(color) }
	public static func clipFill(_ color: ClipColor, selected: Bool) -> NSColor {
		base(color).withAlphaComponent(selected ? 0.55 : 0.28)
	}
	public static func clipWash(_ color: ClipColor, selected: Bool) -> NSColor {
		base(color).withAlphaComponent(selected ? 0.20 : 0.10)
	}

	/// The uncommitted in/out span, before it becomes a clip.
	public static let pendingFill = NSColor(calibratedRed: 0.90, green: 0.55, blue: 0.30, alpha: 0.22)
	public static let pendingStroke = NSColor(calibratedRed: 0.95, green: 0.62, blue: 0.35, alpha: 0.9)

	public static let playhead = NSColor(calibratedRed: 0.95, green: 0.30, blue: 0.35, alpha: 1)

	/// The editor's own furniture: a card ground that lifts off the panel, a
	/// rule that separates without drawing a line anybody notices, and one
	/// accent — the same blue the system uses for selection, so a selected row
	/// looks selected rather than decorated.
	public static let card = NSColor(calibratedWhite: 0.17, alpha: 1)
	public static let cardHigh = NSColor(calibratedWhite: 0.21, alpha: 1)
	public static let accent = NSColor(calibratedRed: 0.30, green: 0.56, blue: 0.95, alpha: 1)
	public static let faintText = NSColor(calibratedWhite: 0.40, alpha: 1)

	/// One hue per kind of thing a project names, used everywhere that kind
	/// appears — in the library, on the programme, on its badge, in the
	/// properties. Colour is how somebody learns what `#` and `@` mean without
	/// being told.
	public enum Kind { case clip, query, list, section, text, spinner, anchor, tag, take }

	public static func color(_ kind: Kind) -> NSColor {
		switch kind {
		case .clip, .take: return base(.green)
		case .query, .tag: return base(.amber)
		case .list: return base(.teal)
		case .section: return base(.violet)
		case .text: return NSColor(calibratedWhite: 0.85, alpha: 1)
		case .spinner: return base(.rose)
		case .anchor: return base(.teal)
		}
	}

	public static let mono = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
	public static let monoSmall = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
	public static let label = NSFont.systemFont(ofSize: 11, weight: .medium)
	public static let heading = NSFont.systemFont(ofSize: 10, weight: .semibold)
	public static let body = NSFont.systemFont(ofSize: 12, weight: .regular)
	public static let bodyStrong = NSFont.systemFont(ofSize: 12, weight: .medium)
}
