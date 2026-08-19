import CoreGraphics
import Foundation

/// Something built out of parts, moved by keyframes: a title card, a lower
/// third with a rule that draws itself, an end plate.
///
/// The point is that somebody who is not this program's author can make one.
/// Everything a scene is made of is in the project file — the parts, where they
/// start, where they go, and when — so it is diffed, reviewed, copied between
/// projects, and edited by anything that edits text. No plug-in to install, no
/// binary to lose, no render that cannot be reproduced next year.
///
/// A scene takes parameters. That is what makes it a *template* rather than one
/// title: `{{title}}` in a part's text is filled in by the overlay that uses the
/// scene, so an intro built once is used in every episode with a different name
/// on it.
public struct Scene: Sendable, Equatable {

	public var parts: [Part]

	public init(parts: [Part] = []) {
		self.parts = parts
	}

	/// One thing in the scene, and how it moves.
	public struct Part: Sendable, Equatable {
		public var content: Content
		/// At least one. Anything a key does not say is what it was at the key
		/// before — so a part that only moves says its position twice and its
		/// opacity once.
		public var keys: [Key]

		public init(content: Content, keys: [Key]) {
			self.content = content
			self.keys = keys
		}

		public enum Content: Sendable, Equatable {
			/// Words, in a named style. `{{name}}` is filled in from `with:`.
			case text(String, style: String?)
			/// A rectangle, which with a small height is a rule and with equal
			/// sides is a block. Rounded by `corner`.
			case shape(fill: RGBA, corner: Double)
			/// A file beside the project — a logo, a badge, a texture.
			case image(String)
		}
	}

	/// Where a part is at one moment. Times are seconds from the start of the
	/// scene, not the programme: a scene is a thing that can be used twice.
	public struct Key: Sendable, Equatable {
		public var t: Double
		/// Unit coordinates of the frame, origin bottom-left. The middle of the
		/// part sits here.
		public var x: Double?
		public var y: Double?
		public var opacity: Double?
		public var scale: Double?
		/// Degrees, anticlockwise.
		public var rotation: Double?
		/// For shapes and images: fractions of the frame's width and height.
		public var width: Double?
		public var height: Double?
		/// How it gets here from the key before.
		public var ease: Ease

		public init(
			t: Double, x: Double? = nil, y: Double? = nil, opacity: Double? = nil,
			scale: Double? = nil, rotation: Double? = nil,
			width: Double? = nil, height: Double? = nil, ease: Ease = .inOut
		) {
			self.t = t
			self.x = x
			self.y = y
			self.opacity = opacity
			self.scale = scale
			self.rotation = rotation
			self.width = width
			self.height = height
			self.ease = ease
		}
	}

	public enum Ease: String, Sendable, CaseIterable {
		case linear
		/// Slow to start. For something leaving.
		case `in`
		/// Slow to stop. For something arriving — which is most things.
		case out
		case inOut
	}

	/// Every value a part has at each of its keys, with the gaps filled in from
	/// the key before.
	///
	/// Done here rather than at render time because it is arithmetic with a
	/// right answer, and because both the preview and the export have to agree
	/// about it to the frame.
	public static func filled(_ keys: [Key]) -> [Key] {
		var out: [Key] = []
		var last = Key(t: 0, x: 0.5, y: 0.5, opacity: 1, scale: 1, rotation: 0,
		               width: 0.2, height: 0.02, ease: .out)
		for key in keys.sorted(by: { $0.t < $1.t }) {
			var filled = key
			filled.x = key.x ?? last.x
			filled.y = key.y ?? last.y
			filled.opacity = key.opacity ?? last.opacity
			filled.scale = key.scale ?? last.scale
			filled.rotation = key.rotation ?? last.rotation
			filled.width = key.width ?? last.width
			filled.height = key.height ?? last.height
			out.append(filled)
			last = filled
		}
		return out
	}

	/// The text of a part, with `{{name}}` replaced from the overlay's `with:`.
	///
	/// Unknown names are left as they are rather than blanked: a title card that
	/// says `{{title}}` on screen is somebody's missing parameter, said out
	/// loud, which is easier to fix than an empty frame.
	public static func fill(_ text: String, with parameters: [String: String]) -> String {
		var out = text
		for (name, value) in parameters {
			out = out.replacingOccurrences(of: "{{\(name)}}", with: value)
			out = out.replacingOccurrences(of: "{{ \(name) }}", with: value)
		}
		return out
	}
}
