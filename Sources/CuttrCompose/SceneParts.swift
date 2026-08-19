import CoreGraphics
import Foundation

public extension Scene {

	/// A progress bar: a groove, and however much of it is filled.
	///
	/// The one number somebody thinks in — how full it is — is not here. It is
	/// `progress` on a key, beside `x` and `opacity`, because that is the thing
	/// that moves and everything that moves in a scene is on a key. A bar going
	/// from empty to full over three seconds is two keys and one field, and it
	/// gets the easing the key already carries for nothing.
	///
	/// How long and how thick it is are the key's `width` and `height`, like
	/// any other part with a size of its own. There is no separate thickness.
	struct Bar: Sendable, Equatable {
		public var fill: RGBA
		/// The groove behind it. Transparent for a bar with no track at all,
		/// which is what a line growing across a title card wants.
		public var track: RGBA
		/// Rounding, as a fraction of the frame height. A bar rounded by half
		/// its own thickness is the pill everybody draws.
		public var corner: Double
		public var direction: Direction

		public enum Direction: String, Sendable, CaseIterable {
			case right, left, up, down
		}

		public init(
			fill: RGBA = .white,
			track: RGBA = RGBA(r: 1, g: 1, b: 1, a: 0.2),
			corner: Double = 0,
			direction: Direction = .right
		) {
			self.fill = fill
			self.track = track
			self.corner = corner
			self.direction = direction
		}

		/// The groove and the filled part of it, in a box centred on the
		/// origin. Both render paths ask this, so a bar half full is half full
		/// in the same place in each of them.
		public func rects(in box: CGRect, progress: Double) -> (track: CGRect, fill: CGRect) {
			let along = max(0, min(1, progress))
			switch direction {
			case .right:
				return (box, CGRect(x: box.minX, y: box.minY,
				                    width: box.width * along, height: box.height))
			case .left:
				return (box, CGRect(x: box.maxX - box.width * along, y: box.minY,
				                    width: box.width * along, height: box.height))
			case .up:
				return (box, CGRect(x: box.minX, y: box.minY,
				                    width: box.width, height: box.height * along))
			case .down:
				return (box, CGRect(x: box.minX, y: box.maxY - box.height * along,
				                    width: box.width, height: box.height * along))
			}
		}
	}
}
