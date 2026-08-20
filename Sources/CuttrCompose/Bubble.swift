import CoreGraphics
import Foundation

/// Somebody in the picture, saying something.
///
/// Three drawings of one idea: a speech bubble with a tail, a thought bubble
/// with a trail of shrinking puffs, and a box with an arrow. They share
/// everything except the outline — the words, how they wrap, the paper, the
/// line, the wobble, and what they point at — so they are one kind with a
/// ``Shape`` rather than three kinds that would each need all of it again.
///
/// **The one line it takes to write one.**
///
/// ```yaml
///   - bubble: still thinks glitter is a colour
///     anchor: mia-eye
/// ```
///
/// `anchor:` means something slightly different here than it does anywhere
/// else, and the difference is worth knowing. Every other overlay *sits* on its
/// anchor. A bubble stands off from it by its ``Overlay/offset`` and points at
/// it — and it travels with the face, which is the whole reason a tail can stay
/// short.
///
/// What a bubble does not do is follow the anchor *exactly*. Words that move
/// under the reader cannot be read, and a tracker's answer jitters from one
/// sample to the next, so the paper follows the slow part of the movement and
/// the tail follows the rest. See ``follow``.
public struct Bubble: Sendable, Equatable {

	/// Which of the three drawings.
	public enum Shape: String, Sendable, CaseIterable {
		/// A round-cornered bubble with a tapered tail. What somebody says.
		case speech
		/// A scalloped cloud with a trail of shrinking puffs. What somebody
		/// thinks, which is the joke most of the time.
		case thought
		/// A box with an arrow drawn to whatever it is about. For labelling a
		/// thing rather than putting words in a mouth.
		case box
	}

	public var shape: Shape

	/// The words. Wrapped to ``width`` and never wider, so the bubble grows
	/// downward rather than off the side of the frame.
	public var text: String

	/// The text style, from the project's `styles:`. Defaults to `bubble`,
	/// which is dark ink on nothing — a caption's white would be invisible on
	/// paper.
	public var style: String?

	/// The paper.
	public var fill: RGBA
	/// The drawn line: the outline, the tail, the arrow.
	public var line: RGBA

	/// The widest the words may get, as a fraction of the frame **width**.
	///
	/// A maximum rather than a size: three words make a small bubble and a
	/// sentence makes a tall one. Nobody should have to measure a bubble by
	/// hand, and the only number that has to be guessed at is the one that
	/// decides where the line breaks — which is a question about reading rather
	/// than about this bubble.
	public var width: Double

	/// The wobble.
	///
	/// The same number gives the same shaky line on every machine and every
	/// render, which is the only way a hand-drawn look can also be a repeatable
	/// one. It is the same idea, and the same word, as an effect's `seed:`.
	public var seed: Int

	/// How much the line breathes, as a multiple of what reads as alive.
	///
	/// A drawn bubble that is perfectly still next to a moving face reads as a
	/// sticker. So the line is redrawn a few times a second — see
	/// ``Bubbling/drawingsPerSecond`` and ``Bubbling/breath`` for how often and
	/// by how much — and this is the dial on it: one is the amount that was
	/// chosen by looking, two is twice as lively, and **nought is the still
	/// drawing**, exactly the bubble this program drew before any of it existed.
	///
	/// A multiple rather than a distance, because the distance is a fraction of
	/// the frame with a reason beside it and nobody nudging a bubble wants to
	/// rediscover that reason. What moves is the outline, the thought bubble's
	/// puffs and the box arrow's shaft. Never the words: text that moves is text
	/// nobody can read, and the bubble exists to be read.
	public var breath: Double

	/// Whether the paper travels with the anchor.
	///
	/// It does. A bubble that stays where the face was when it came on is a
	/// bubble with a tail stretching further across the shot every second, and it
	/// stops looking like something she is saying.
	///
	/// **What it costs, and what pays for it.** Words that move under the reader
	/// cannot be read, and a tracker's answer jitters from sample to sample — so
	/// what the paper follows is not the anchor but the *slow part* of the anchor:
	/// a centred average over ``OverlayLayers/settling`` seconds, which passes a
	/// walk through untouched and flattens the jitter to nothing. And where a
	/// breathing bubble steps its drawing, the paper steps with it, because where
	/// the paper sits is part of the drawing. See ``OverlayLayers/settled(_:at:)``.
	///
	/// `false` puts it back where it was: placed once, where the face was when it
	/// came on, and still. Which is right for a bubble pinned to the corner of a
	/// graphic, and for a shot where the face barely moves and the stillest thing
	/// is the best thing.
	public var follow: Bool

	/// A fixed point to point at, normalised, origin bottom-left.
	///
	/// For the things that are not faces — a hat on a table, a corner of a
	/// card — and for a programme with no footage in it at all, which is what
	/// makes a bubble something the examples can show. `anchor:` wins where
	/// both are written: a tracked face is a better answer than a guess.
	public var at: CGPoint?

	public init(
		shape: Shape = .speech,
		text: String = "",
		style: String? = nil,
		fill: RGBA = Bubble.paper,
		line: RGBA = Bubble.ink,
		width: Double = 0.32,
		seed: Int = 1,
		breath: Double = 1,
		follow: Bool = true,
		at: CGPoint? = nil
	) {
		self.shape = shape
		self.text = text
		self.style = style
		self.fill = fill
		self.line = line
		self.width = width
		self.seed = seed
		self.breath = max(0, breath)
		self.follow = follow
		self.at = at
	}

	/// Not quite white: paper, at the warmth a comic is printed on. Flat white
	/// against a rendered frame reads as a hole in the picture.
	public static let paper = RGBA(r: 1, g: 0.992, b: 0.953)
	/// Not quite black, for the same reason the other way round.
	public static let ink = RGBA(r: 0.09, g: 0.094, b: 0.11)

	/// How far off the thing it points at a bubble stands when nobody says.
	///
	/// In fractions of the frame **height** on both axes, as every offset in
	/// this format is. Up and to the right, because a bubble drawn over the
	/// face it is pointing at hides the face — and a tail with nowhere to go is
	/// no tail at all.
	///
	/// Written into the file the first time it is saved rather than kept as a
	/// secret default: where a bubble sits is the number somebody will want to
	/// nudge, and a number nobody can see is a number nobody can nudge.
	public static let standoff = CGPoint(x: 0.1, y: 0.22)

	/// The style a bubble's words are drawn in when the file names none.
	///
	/// Dark, centred, no plate. It is in ``TextStyle/builtIn`` under the name
	/// `bubble`, so a project that wants another face writes four lines under
	/// `styles:` and changes nothing else.
	public static let textStyle = TextStyle(
		font: "Noteworthy Bold",
		size: 0.036,
		color: Bubble.ink,
		background: RGBA(r: 0, g: 0, b: 0, a: 0),
		padding: 0.018,
		cornerRadius: 0,
		position: CGPoint(x: 0.5, y: 0.5),
		alignment: .centre)
}
