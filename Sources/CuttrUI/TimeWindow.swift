import CoreGraphics
import Foundation

/// Which stretch of a clock a strip is showing, and the arithmetic of moving it.
///
/// Two strips in this program draw a stretch of the programme along their width
/// and let somebody zoom into it: the properties column's "when it is on", and
/// the Play page's programme timeline. The arithmetic is the same arithmetic,
/// and this program has been bitten twice this week by the same question having
/// two answers — where a clip is, and what colour a film is — so it is written
/// once here and both strips ask it.
///
/// A value rather than a view, so it can be tested without a window and held by
/// whatever outlives the view. The forms these strips live in are thrown away
/// and rebuilt after every edit, so a zoom kept only in a view lasts until the
/// next letter typed into a field.
struct TimeWindow: Equatable {

	/// The bounds a zoom cannot escape.
	var limits: (start: Double, end: Double)

	/// Which part of ``limits`` is being looked at, or `nil` for all of it.
	var zoomed: (start: Double, end: Double)?

	/// The least a strip will show.
	///
	/// A quarter of a second across a panel's width is a millisecond or two to
	/// the pixel, which is finer than anything in this program is placed to.
	/// Past that the clocks at the ends stop differing and the strip has stopped
	/// being a picture of anything.
	static let leastShown = 0.25

	init(limits: (start: Double, end: Double) = (0, 0),
	     zoomed: (start: Double, end: Double)? = nil) {
		self.limits = limits
		self.zoomed = zoomed
	}

	static func == (a: TimeWindow, b: TimeWindow) -> Bool {
		a.limits == b.limits && a.zoomed?.start == b.zoomed?.start
			&& a.zoomed?.end == b.zoomed?.end
	}

	/// What is shown, resolved.
	///
	/// Clamped on the way out rather than on the way in, so a zoom that outlived
	/// a rebuild — or a change of which clip the strip is about — keeps its
	/// magnification and slides inside the new bounds rather than being thrown
	/// away or left pointing outside them.
	var shown: (start: Double, end: Double) {
		let whole = limits.end - limits.start
		guard let zoomed, whole > 0 else { return limits }
		let span = min(max(Self.leastShown, zoomed.end - zoomed.start), whole)
		let start = min(max(limits.start, zoomed.start), limits.end - span)
		return (start, start + span)
	}

	/// Whether anything is hidden, which is what decides if a pan means
	/// anything and whether a gesture should be claimed at all.
	var isZoomed: Bool {
		let shown = shown
		return shown.start > limits.start + 1e-9 || shown.end < limits.end - 1e-9
	}

	/// Zooms about a fraction of the width, keeping the moment under it still.
	///
	/// A factor below one shows less. The moment under the pointer staying put
	/// is the whole of the interaction: zooming on a strip that keeps its centre
	/// instead walks the thing being aimed at off the edge in two turns of the
	/// wheel.
	mutating func zoom(by factor: Double, aboutFraction fraction: CGFloat) {
		let whole = limits.end - limits.start
		guard whole > 0 else { return }
		let shown = shown
		let span = shown.end - shown.start
		let held = Double(min(max(0, fraction), 1))
		let at = shown.start + held * span
		let want = min(max(span * factor, Self.leastShown), whole)
		guard want < whole else { zoomed = nil; return }
		let start = min(max(limits.start, at - held * want), limits.end - want)
		zoomed = (start, start + want)
	}

	/// The whole of it again.
	mutating func fit() { zoomed = nil }

	/// Frames one stretch, with a margin — "show me this range".
	mutating func reveal(from start: Double, to end: Double) {
		let whole = limits.end - limits.start
		guard whole > 0 else { return }
		let want = min(max((end - start) * 1.3, Self.leastShown), whole)
		guard want < whole else { zoomed = nil; return }
		let middle = (start + end) / 2
		let from = min(max(limits.start, middle - want / 2), limits.end - want)
		zoomed = (from, from + want)
	}

	/// Slides what is shown along, in points of a track this wide. Does nothing
	/// while the whole of it is on screen, so the gesture falls through to
	/// whatever is behind rather than being eaten by a strip with nowhere to go.
	mutating func pan(byPoints points: CGFloat, trackWidth: CGFloat) {
		guard isZoomed, trackWidth > 0 else { return }
		let shown = shown
		let span = shown.end - shown.start
		let by = Double(points / trackWidth) * span
		let start = min(max(limits.start, shown.start + by), limits.end - span)
		zoomed = (start, start + span)
	}

	/// Keeps a moment on screen: when it has run off the shown stretch, the
	/// stretch pages along so the moment sits a tenth of the way in. Says
	/// whether anything moved.
	///
	/// A page rather than a glide. The playhead moving across a still view is
	/// how a person reads where they are; a view sliding under a still
	/// playhead is a view in which nothing can be aimed at. So the view stays
	/// put until the playhead reaches its edge, then jumps once, the way every
	/// editor's timeline follows playback.
	@discardableResult
	mutating func follow(_ time: Double) -> Bool {
		guard isZoomed else { return false }
		let shown = shown
		let span = shown.end - shown.start
		guard span > 0, time < shown.start - 1e-9 || time > shown.end + 1e-9 else { return false }
		let start = min(max(limits.start, time - span * 0.1), limits.end - span)
		zoomed = (start, start + span)
		return true
	}

	// MARK: - The mapping

	/// Where a moment sits along a track, as a fraction of it.
	func fraction(of time: Double) -> CGFloat {
		let shown = shown
		let span = shown.end - shown.start
		guard span > 0 else { return 0 }
		return CGFloat((time - shown.start) / span)
	}

	/// What moment a fraction of the way along a track means, held inside what
	/// is shown.
	func time(atFraction fraction: CGFloat) -> Double {
		let shown = shown
		let span = shown.end - shown.start
		guard span > 0 else { return shown.start }
		return min(shown.end, max(shown.start, shown.start + Double(fraction) * span))
	}
}
