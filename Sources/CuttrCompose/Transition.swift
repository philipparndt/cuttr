import Foundation

/// How one shot becomes the next.
///
/// Every one of these is an *overlap*: the incoming clip starts before the
/// outgoing one ends, and the programme is shorter by exactly that much. That
/// is the whole arrangement — the arithmetic in the resolver, the two video
/// lanes, the audio ramp — and none of it changes with the kind. What changes
/// is one function: what to draw when both shots are on screen at once.
///
/// Which is why there can be a dozen of these and only one of them costs
/// anything to add. A cut is the absence of an overlap, so it is a kind here
/// with no duration rather than a special case elsewhere.
public struct Transition: Sendable, Equatable {

	public enum Kind: String, Sendable, CaseIterable {
		/// No overlap at all.
		case cut
		/// One mixes into the other. The one everybody means by "transition".
		case dissolve
		/// Out through black and back. A scene change rather than a join —
		/// black between two shots reads as time passing.
		case dipToBlack
		/// The same through white, which reads as a jump rather than a rest.
		case dipToWhite
		/// A hard edge crossing the frame, one shot behind it.
		case wipe
		/// Both shots move: the old one leaves as the new one arrives, as
		/// though the frame slid along to it.
		case push
		/// The new shot slides in over the old one, which stays where it is.
		case slide
		/// Both go soft, mix while they are soft, and come back sharp. A
		/// dissolve that hides a mismatch instead of showing it twice.
		case blur
		/// A dissolve with the frame blown out at the middle of it.
		case flash
		/// A circle opening from the centre. The oldest one there is.
		case iris

		/// What it is called where somebody has to choose it.
		public var title: String {
			switch self {
			case .dipToBlack: return "dip to black"
			case .dipToWhite: return "dip to white"
			default: return rawValue
			}
		}

		/// Whether the kind goes in a direction. The rest ignore the edge, and
		/// showing a direction control beside them is a way of asking a
		/// question with no answer.
		public var directional: Bool {
			switch self {
			case .wipe, .push, .slide: return true
			default: return false
			}
		}

		/// What it writes in the file. The two-word ones are hyphenated there
		/// because a slug in this format never contains a space.
		public var written: String {
			switch self {
			case .dipToBlack: return "dip-to-black"
			case .dipToWhite: return "dip-to-white"
			default: return rawValue
			}
		}

		public init?(written: String) {
			switch written.lowercased() {
			case "dip-to-black", "diptoblack", "dip to black", "black": self = .dipToBlack
			case "dip-to-white", "diptowhite", "dip to white", "white": self = .dipToWhite
			case "none": self = .cut
			default:
				guard let found = Kind(rawValue: written.lowercased()) else { return nil }
				self = found
			}
		}
	}

	/// Which way it travels, for the kinds that travel. Named for where the
	/// incoming shot comes *from*, the way a door is named for the side it
	/// opens on.
	public enum Edge: String, Sendable, CaseIterable {
		case left, right, up, down
	}

	public var kind: Kind
	/// How long the two shots are on screen together.
	public var seconds: Double
	public var edge: Edge

	public init(_ kind: Kind = .cut, seconds: Double = 0.5, edge: Edge = .left) {
		self.kind = kind
		self.seconds = seconds
		self.edge = edge
	}

	public static let cut = Transition(.cut, seconds: 0)

	public static func dissolve(over seconds: Double) -> Transition {
		Transition(.dissolve, seconds: seconds)
	}

	/// How much of the programme it takes up. A cut takes none however long
	/// somebody wrote beside it, which is what keeps a kind changed to `cut` in
	/// the panel from leaving an overlap behind.
	public var duration: Double { kind == .cut ? 0 : max(0, seconds) }
}

/// A bare number is a dissolve, in the file and here.
///
/// The format has said `transition: 0.5` since before there was anything else
/// to say, and files written then still mean what they said. Rather than
/// translating that in one place and hoping every other place remembers, the
/// type itself reads a number the way the file does.
extension Transition: ExpressibleByFloatLiteral, ExpressibleByIntegerLiteral {
	public init(floatLiteral value: Double) {
		self = value > 0 ? .dissolve(over: value) : .cut
	}

	public init(integerLiteral value: Int) {
		self = value > 0 ? .dissolve(over: Double(value)) : .cut
	}
}
