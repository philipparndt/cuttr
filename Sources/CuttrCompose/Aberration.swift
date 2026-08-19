import CoreGraphics
import Foundation

/// The lens failing to bring the three colours to the same place.
///
/// Every lens does it a little and a cheap one does it a lot: red comes to
/// focus slightly larger than green and blue slightly smaller, so an edge near
/// the corner of the frame carries a red fringe on one side and a blue one on
/// the other. The middle of the picture is untouched, which is the whole tell —
/// a separation that is the same everywhere reads as a printing mistake, and
/// one that grows towards the edges reads as glass.
///
/// So `radial` is the one to reach for. `linear` is kept because a flat offset
/// in a chosen direction is what a still frame of a 3-D anaglyph looks like,
/// and because somebody will want it for a title.
public struct Aberration: Sendable, Equatable {

	public enum Kind: String, Sendable, CaseIterable {
		/// Out from the middle, growing towards the edges. What a lens does.
		case radial
		/// The same offset everywhere, along ``Aberration/angle``.
		case linear
	}

	public var kind: Kind

	/// How far apart the channels go.
	///
	/// One is about one per cent of the frame between red and blue — at the
	/// corners for `radial`, everywhere for `linear`. That is already a great
	/// deal: eleven pixels of fringe on a 1080 frame. A tenth of it is the
	/// amount that reads as a lens rather than as an effect.
	public var amount: Double

	/// Which way `linear` pulls, in degrees anticlockwise from the right.
	/// Ignored by `radial`, which has a direction at every point already.
	public var angle: Double

	public init(kind: Kind = .radial, amount: Double = 0.4, angle: Double = 0) {
		self.kind = kind
		self.amount = amount
		self.angle = angle
	}
}
