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
			///
			/// `tracking` is the space between the letters, as a fraction of
			/// the type size — the one typographic setting a title card wants
			/// that a caption never does, so it lives on the part rather than
			/// on the style. Positive opens it up, which is what a word set in
			/// capitals across a title needs; negative closes it.
			case text(String, style: String?, tracking: Double = 0)
			/// A rectangle, which with a small height is a rule and with equal
			/// sides is a block. Rounded by `corner`.
			///
			/// `kind` is what it is the shape *of*, and it can be said again on
			/// a key: a key naming a different one morphs between them over
			/// that interval rather than cutting. It defaults to a rectangle,
			/// which is what every shape part was before there were kinds, so a
			/// project written then still says exactly what it always said.
			case shape(fill: RGBA, corner: Double, kind: ShapeKind = .rectangle)
			/// A progress bar. How full it is is `progress` on a key.
			case bar(Bar)
			/// The spinner this program already has, standing in a scene: the
			/// same styles and the same drawing as one over a shot, because a
			/// second implementation of a spinner is a spinner that eventually
			/// disagrees with itself.
			///
			/// With `progress` on a key it stops going round and fills up
			/// instead — a ring that reaches that fraction. The styles are for
			/// the case where there is nothing to show but that it is still
			/// going, and a spinner that knows how far it has got has something
			/// better to say.
			case spinner(Spinner)
			/// A column of credits: blocks of a role and the names under it.
			///
			/// The one part whose *layout* is the thing, rather than its
			/// position — the position is `x` and `y` on a key, as for every
			/// other part, and a roll scrolls because those keys move it. See
			/// ``Scene/Roll`` for why this could not be said with text parts.
			case roll(Roll)
			/// A file beside the project — a logo, a badge, a texture.
			case image(String)
			/// A folder of frames, one per frame of the picture. See
			/// ``FrameSequence``: the one part kind with no drawing in it,
			/// because whatever made the frames did the drawing.
			case frames(FrameSequence)
			/// A React component beside the project, baked to frames and then
			/// drawn as one. See ``Component``.
			///
			/// It becomes a ``frames(_:)`` part the moment anything looks at
			/// pixels — ``sequence(at:)`` is where that happens — so neither
			/// render path knows a browser was involved and there is one
			/// implementation of putting a sequence on the picture rather than
			/// two.
			case component(Component)
			/// The whole frame, filled. What an intro screen stands on.
			///
			/// Not a shape at `width: 1, height: 1`: that is what somebody had
			/// to write before, and it goes wrong the moment the output is a
			/// different shape from the one it was written at — a 4:3 render of
			/// a scene written at 16:9 left the corners showing. A background
			/// is defined as "the frame", so there is nothing to get wrong.
			case background(Background)
		}
	}

	/// What a background is filled with: one colour, or two with a ramp
	/// between them.
	///
	/// Two stops rather than a list, because two is what a title card uses and
	/// a list of five is a gradient editor — a thing this program would then
	/// have to draw. A file that wants more can say so later; nothing here
	/// stops it.
	///
	/// **A flat fill is a gradient whose stops are the same colour.** The file
	/// still spells one colour as one word — `to` is `nil` for it, and stays
	/// `nil`, because `background: "#101418"` is what somebody writes and what
	/// they get back. But every piece of arithmetic here reads a missing `to`
	/// as "the same as `from`", which is what makes ramping from a flat colour
	/// into a gradient fall out of the interpolation instead of needing a rule
	/// of its own. See ``at(_:keys:)``.
	public struct Background: Sendable, Equatable {
		public var from: RGBA
		/// `nil` for a flat colour — which is to say, the same colour as
		/// ``from``. Kept optional rather than filled in so that the one word
		/// somebody wrote is the one word written back.
		public var to: RGBA?
		/// Degrees anticlockwise from left-to-right, so `90` runs up the frame
		/// and `0` runs across it. The same convention as ``Key/rotation``.
		public var angle: Double
		/// A picture beside the project, filling the frame — a photograph, a
		/// texture, a still somebody drew somewhere else.
		///
		/// Over the fill rather than instead of it, so a PNG with transparency
		/// in it sits on the colour and a picture of the wrong shape has
		/// something behind the edges it does not reach. A background that is
		/// *only* a picture is one whose colours nobody set, which costs one
		/// word in the file and no rule here.
		///
		/// Filled to the frame, not fitted: a background is the ground, and
		/// ground with a margin round it is not ground. The overflow is
		/// centred, which is the only place it can go without asking.
		public var image: String?

		public init(from: RGBA, to: RGBA? = nil, angle: Double = 90, image: String? = nil) {
			self.from = from
			self.to = to
			self.angle = angle
			self.image = image
		}

		/// Where the ramp starts and ends, in unit coordinates of the frame.
		///
		/// Measured across the frame's diagonal rather than its width, so a
		/// gradient at 45° reaches both corners instead of stopping short of
		/// them.
		public func ends(in size: CGSize) -> (start: CGPoint, end: CGPoint) {
			let radians = angle * .pi / 180
			let centre = CGPoint(x: size.width / 2, y: size.height / 2)
			// Half the projection of the frame onto the gradient's direction:
			// the distance from the middle to the edge, along that line.
			let reach = (abs(cos(radians)) * size.width + abs(sin(radians)) * size.height) / 2
			let dx = cos(radians) * reach, dy = sin(radians) * reach
			return (CGPoint(x: centre.x - dx, y: centre.y - dy),
			        CGPoint(x: centre.x + dx, y: centre.y + dy))
		}

		/// This background as the keys have it at a moment: both stops and the
		/// angle, ready to be drawn.
		///
		/// The part declares what it is *before the first key says otherwise*,
		/// and a key states what changes there. So a key's `color` is the first
		/// stop, its `to` is the second, its `angle` is the direction, and
		/// anything a key leaves out is what the part said.
		///
		/// A key stating `to` or `angle` is what makes the whole thing a ramp.
		/// Nothing stating either of them takes the path this had before there
		/// were gradient keys — the declared `to`, tinted at the first stop by
		/// `color` — because a flat background must go on being drawn as one
		/// fill, and every scene written before now must come out the same
		/// pixels it always did.
		///
		/// `keys` wants to be ``Scene/filled(_:)``, so that a stop stated once
		/// holds from there.
		public func at(_ time: Double, keys: [Key]) -> Background {
			guard Scene.movesTheGradient(keys) else {
				let now = Scene.state(of: keys, at: time)
				return Background(from: now?.color ?? from, to: to, angle: angle, image: image)
			}
			// Resolved against the part *before* interpolating, not after: a
			// flat fill is two stops of the same colour, so a background that
			// starts flat and ends ramped has a second stop at both ends and
			// the ramp between them is ordinary arithmetic.
			let resolved = keys.map { key -> Key in
				var out = key
				let start = key.color ?? from
				out.color = start
				out.to = key.to ?? to ?? start
				out.angle = key.angle ?? angle
				return out
			}
			guard let now = Scene.state(of: resolved, at: time) else {
				return Background(from: from, to: to, angle: angle, image: image)
			}
			// The picture is carried through rather than interpolated: it is a
			// fact about the part, not about the moment. A key can tint what is
			// behind it and cannot swap it for another photograph.
			return Background(from: now.color ?? from, to: now.to,
			                  angle: now.angle ?? angle, image: image)
		}
	}

	/// Whether any key states the gradient itself rather than only tinting its
	/// first stop.
	///
	/// The one thing that decides which of the two paths a background is drawn
	/// by, so both render paths ask it and neither guesses.
	public static func movesTheGradient(_ keys: [Key]) -> Bool {
		keys.contains { $0.to != nil || $0.angle != nil }
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
		/// What a bar, or a determinate spinner, has got to: nought to one.
		///
		/// On the key rather than on the part for the same reason `x` is — it
		/// is the thing that moves. A bar that fills over three seconds is
		/// `progress: 0` at one key and `progress: 1` at another, and the
		/// easing between them is the easing that key already carries.
		public var progress: Double?
		/// What a shape part is the shape of, when it is not what it was.
		///
		/// Naming a different kind here morphs into it across the interval
		/// ending at this key. Left out, it is whatever it already was, which
		/// is why a shape that never changes says its kind once or not at all.
		public var shape: ShapeKind?
		/// The part's colour here, if it is not the one the part was declared
		/// with: a text part's ink, a shape's fill, a background's first stop.
		///
		/// On the key rather than on the part because that is the whole point —
		/// a title that arrives white and settles into the house colour is two
		/// keys and one extra field, where before it was two text parts crossed
		/// over each other.
		public var color: RGBA?
		/// A background's far stop here — the other end of the ramp.
		///
		/// The same word the part declares it with, and beside `color`, which
		/// is the near one. Between them a background is animated in the thing
		/// it actually is: a gradient that ramps into another gradient, rather
		/// than a flat colour that can move while the ramp behind it cannot.
		///
		/// A key says *flat* by stating `to` equal to `color`, because a flat
		/// fill is a gradient whose stops are the same colour. There is nothing
		/// to say "no ramp from here": a `nil` here means inherited, as it does
		/// in every other field.
		public var to: RGBA?
		/// A background's ramp direction here, in degrees, the same convention
		/// the part declares.
		///
		/// Turned the short way round between two keys — 350 to 10 is twenty
		/// degrees, not three hundred and forty — because that is what the two
		/// numbers look like on screen. Which means a full turn cannot be
		/// written as 0 to 360, since those are the same direction: say 120 and
		/// 240 on the way and it goes round.
		public var angle: Double?
		/// How it gets here from the key before.
		public var ease: Ease

		public init(
			t: Double, x: Double? = nil, y: Double? = nil, opacity: Double? = nil,
			scale: Double? = nil, rotation: Double? = nil,
			width: Double? = nil, height: Double? = nil,
			progress: Double? = nil, shape: ShapeKind? = nil, color: RGBA? = nil,
			to: RGBA? = nil, angle: Double? = nil,
			ease: Ease = .inOut
		) {
			self.progress = progress
			self.shape = shape
			self.t = t
			self.x = x
			self.y = y
			self.opacity = opacity
			self.scale = scale
			self.rotation = rotation
			self.width = width
			self.height = height
			self.color = color
			self.to = to
			self.angle = angle
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
			// No default of its own, unlike the others: a part with no colour
			// anywhere is a part drawn in the colour it was declared with, and
			// filling in a colour here would quietly override that. The kind of
			// a shape is the same — it belongs to the part until a key says
			// otherwise.
			filled.color = key.color ?? last.color
			filled.shape = key.shape ?? last.shape
			// The far stop and the angle, carried like the colour and for the
			// same reason: a background with none of them anywhere is drawn the
			// way the part declares it, and a default here would quietly
			// override that.
			filled.to = key.to ?? last.to
			filled.angle = key.angle ?? last.angle
			// Carried forward and not defaulted, like the colour and the kind.
			// A part with no `progress` at any key has never been told how far
			// it has got, which is not the same as being told nought: it is how
			// a spinner says it does not know.
			filled.progress = key.progress ?? last.progress
			out.append(filled)
			last = filled
		}
		return out
	}

	/// The part's values at a moment: the two keys either side of it, eased
	/// between.
	///
	/// Before the first key it is the first, after the last it is the last —
	/// which is what `fillMode: .both` does for the layer version. The two
	/// render paths and the editor's stage all ask this, so there is one answer
	/// to "where is it now" rather than three that agree until somebody
	/// changes one of them.
	public static func state(of keys: [Key], at time: Double) -> Key? {
		guard let first = keys.first, let last = keys.last else { return nil }
		if time <= first.t { return first }
		if time >= last.t { return last }
		guard let next = keys.firstIndex(where: { $0.t > time }), next > 0 else { return last }
		let before = keys[next - 1], after = keys[next]
		let span = max(after.t - before.t, 0.0001)
		let fraction = eased(after.ease, (time - before.t) / span)

		func between(_ a: Double?, _ b: Double?) -> Double? {
			guard let a, let b else { return b ?? a }
			return a + (b - a) * fraction
		}
		/// The gradient's angle, turned the short way round.
		///
		/// Not ``Key/rotation``, which is linear on purpose — a part told to go
		/// from nought to seven hundred and twenty spins twice, and that is a
		/// thing somebody means. A gradient's direction is not: 350 and 10 are
		/// twenty degrees apart wherever they are written, and going the other
		/// way round is nothing anybody asked for.
		func turning(_ a: Double?, _ b: Double?) -> Double? {
			guard let a, let b else { return b ?? a }
			var delta = (b - a).truncatingRemainder(dividingBy: 360)
			if delta > 180 { delta -= 360 }
			if delta <= -180 { delta += 360 }
			return a + delta * fraction
		}
		return Key(
			t: time,
			x: between(before.x, after.x), y: between(before.y, after.y),
			opacity: between(before.opacity, after.opacity),
			scale: between(before.scale, after.scale),
			rotation: between(before.rotation, after.rotation),
			width: between(before.width, after.width),
			height: between(before.height, after.height),
			progress: between(before.progress, after.progress),
			// The kind is the one it is coming *from*: what it is turning into
			// is a separate question, and `morph(of:at:)` is where it is asked.
			shape: before.shape ?? after.shape,
			color: RGBA.between(before.color, after.color, fraction),
			to: RGBA.between(before.to, after.to, fraction),
			angle: turning(before.angle, after.angle),
			ease: after.ease)
	}

	public static func eased(_ ease: Ease, _ t: Double) -> Double {
		let t = max(0, min(1, t))
		switch ease {
		case .linear: return t
		case .in: return t * t
		case .out: return 1 - pow(1 - t, 2)
		case .inOut: return t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
		}
	}

	/// The last moment anything in the scene does something.
	///
	/// Not how long the scene *is* — a scene has no length of its own, it plays
	/// for as long as the overlay that uses it is on screen. This is only the
	/// point after which nothing more happens, which is what an editor with
	/// nothing else to go on has to guess from.
	public var lastKeyTime: Double {
		parts.flatMap(\.keys).map(\.t).max() ?? 0
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
