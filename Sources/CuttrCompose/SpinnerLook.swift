import CoreGraphics

/// The proportions of a spinner, in one place.
///
/// A spinner is drawn twice — as layers, for anything laid over the finished
/// frame, and as pixels, for anything that has to go behind somebody — and
/// those two must be the same spinner. Numbers written out twice drift: the
/// ring gets a hair thicker in one of them, somebody moves an overlay behind a
/// person, and it changes shape.
enum SpinnerLook {
	/// Diameter of a dot, as a fraction of the spinner's own diameter.
	static let dot: CGFloat = 0.16
	static let dots = 12

	/// A bar: how wide, how long, and how many.
	static let barWidth: CGFloat = 0.09
	static let barLength: CGFloat = 0.28
	static let bars = 12

	/// The ring and the arc: how far in from the edge, how thick, how far round.
	static let ringInset: CGFloat = 0.12
	static let ringWidth: CGFloat = 0.10
	static let ringSweep: CGFloat = 0.75
	static let arcSweep: CGFloat = 0.28

	/// The orbit's track and its travelling dot.
	static let orbitDot: CGFloat = 0.2

	/// The pulse, which breathes rather than turns.
	static let pulseInset: CGFloat = 0.14
	static let pulseWidth: CGFloat = 0.08

	/// The three bouncing dots.
	static let bounceDot: CGFloat = 0.26
	static let bounce = 3
	static let bounceRise: CGFloat = 0.28

	/// The gap between the spinner and the first of its words.
	static let wordGap: CGFloat = 0.45
}
