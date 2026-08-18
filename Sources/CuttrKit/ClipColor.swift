import Foundation

/// The colour a clip is drawn in.
///
/// Named rather than a hex value, and the reason is the file. A cut list is
/// meant to be read and edited by hand, and `color: amber` says something a
/// human can act on where `color: "#f2b852"` is a number nobody can check. It
/// also means the palette can be adjusted — a shade that turned out to be hard
/// to tell from its neighbour on a laptop screen — without rewriting anybody's
/// takes.
///
/// What they are *for*: overlapping clips. Two attempts at the same sentence,
/// or a wide clip with three short ones inside it, are ordinary things to want
/// and impossible to see when every bar is the same green. The colour is the
/// operator's own scheme — takes versus pickups, speaker A versus speaker B,
/// keep versus maybe — and this program deliberately does not assign it a
/// meaning.
public enum ClipColor: String, CaseIterable, Sendable, Codable {
	case green, blue, amber, violet, rose, teal

	/// What a clip gets when nothing says otherwise, and the one value that is
	/// left out of the file: a take nobody has colour-coded should not carry a
	/// `color:` line on every clip explaining that it is the usual one.
	public static let `default` = ClipColor.green

	/// For the swatch's tooltip and the menu item.
	public var title: String { rawValue.capitalized }

	public static func named(_ name: String) -> ClipColor? {
		ClipColor(rawValue: name.trimmingCharacters(in: .whitespaces).lowercased())
	}
}
