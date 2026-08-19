import CoreGraphics
import CuttrKit
import Foundation

/// The programme, for a while, pretending to be film.
///
/// Not a thing drawn over the picture — the picture itself, changed: bars close
/// in to a wider shape, the colour goes to something that was never quite what
/// the sensor saw, and the grain arrives. It is the one overlay that is *under*
/// everything else, because a caption over a film-graded shot is a caption on
/// the programme, not a caption that has been developed.
///
/// It fades in and out like anything else, and that is the whole point of it
/// being an overlay rather than a grade: `in:` and `out:` decide how long the
/// bars take to close, and a clip can go to film and come back inside its own
/// length without anything else in the project knowing.
public struct Film: Sendable, Equatable {

	/// The shape the picture is taken to. Bars where the programme is taller
	/// than this, columns where it is wider.
	public var ratio: Ratio
	public var tint: Tint
	/// How much of the tint, 0 for none and 1 for all of it.
	public var strength: Double
	/// How much grain, against a sensible amount of it.
	public var grain: Double
	/// How dark the corners go.
	public var vignette: Double

	public init(
		ratio: Ratio = Ratio(16, 9), tint: Tint = .warm,
		strength: Double = 0.7, grain: Double = 0.4, vignette: Double = 0.35
	) {
		self.ratio = ratio
		self.tint = tint
		self.strength = strength
		self.grain = grain
		self.vignette = vignette
	}

	/// What the colour goes to.
	///
	/// Named for the stock rather than for the arithmetic, because that is how
	/// anybody chooses one: nobody wants "saturation 0.62, temperature +900",
	/// they want the shot to look like the summer of a film they remember.
	public enum Tint: String, Sendable, CaseIterable {
		/// Nothing. For a letterbox and grain with the colour left alone.
		case none
		/// Warm, slightly faded — the daylight stock everybody pictures.
		case warm
		/// Cold and clean, the colour of a winter interior.
		case cool
		/// Brown, and old.
		case sepia
		/// Black and white.
		case noir
		/// Colour pulled out and contrast pushed in — bleach bypass.
		case bleach

		/// The grade, as this program's own look. One place, so what the
		/// renderer does and what the panel says are the same thing.
		public var look: Look {
			switch self {
			case .none: return .none
			case .warm: return Look(exposure: 0.05, temperature: 900, tint: 6,
			                        saturation: 0.85, contrast: 1.06)
			case .cool: return Look(temperature: -900, tint: -4, saturation: 0.8, contrast: 1.08)
			case .sepia: return Look(temperature: 1200, tint: 10, saturation: 0.25, contrast: 1.1)
			case .noir: return Look(saturation: 0, contrast: 1.2)
			case .bleach: return Look(saturation: 0.35, contrast: 1.25)
			}
		}
	}

	/// A shape, kept as the two numbers somebody wrote rather than as their
	/// quotient: `2.39:1` written back as `2.39:1` and not as `2.39`.
	public struct Ratio: Sendable, Equatable {
		public var width: Double
		public var height: Double

		public init(_ width: Double, _ height: Double) {
			self.width = width > 0 ? width : 16
			self.height = height > 0 ? height : 9
		}

		/// `16:9`, `2.39:1`, or a bare number meaning that against 1.
		public init?(_ text: String) {
			let parts = text.split(separator: ":", maxSplits: 1)
			if parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]),
			   w > 0, h > 0 {
				self.init(w, h)
				return
			}
			guard parts.count == 1, let value = Double(parts[0]), value > 0 else { return nil }
			self.init(value, 1)
		}

		public var value: Double { width / height }

		public var written: String {
			func trim(_ number: Double) -> String {
				number == number.rounded() ? String(Int(number)) : String(format: "%g", number)
			}
			return "\(trim(width)):\(trim(height))"
		}

		/// The ones worth offering. Anything else can still be written.
		public static let offered: [Ratio] = [
			Ratio(2.39, 1), Ratio(2, 1), Ratio(1.85, 1), Ratio(16, 9), Ratio(4, 3), Ratio(1, 1),
		]
	}

	/// How thick the bars are at full strength, as a fraction of the frame.
	///
	/// Two numbers, because a frame can be taller or wider than what is asked
	/// for and one of them is always nought. Worked out here rather than in the
	/// drawing so the preview and the render cannot disagree.
	public func bars(in size: CGSize) -> (vertical: Double, horizontal: Double) {
		guard size.width > 0, size.height > 0 else { return (0, 0) }
		let frame = size.width / size.height
		if ratio.value > frame {
			// Wider than the programme: bars top and bottom.
			let kept = frame / ratio.value
			return (max(0, (1 - kept) / 2), 0)
		}
		// Taller — or the same, in which case nothing.
		let kept = ratio.value / frame
		return (0, max(0, (1 - kept) / 2))
	}
}
