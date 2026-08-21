import Foundation

/// One point on a take's gain curve: a moment, and how loud it should be there.
///
/// On the *video's* clock, like every other time in a take — see ``Take``. A
/// curve written against the recorder's own clock would move every point in it
/// the first time somebody corrected the alignment, which is the one thing the
/// single clock exists to prevent.
public struct LevelPoint: Sendable, Equatable {

	/// When, on the take's clock, in seconds.
	public var at: Double

	/// How much to turn the recording up or down here, in decibels.
	///
	/// Added to ``Take/gain`` and to ``Clip/gain`` rather than replacing
	/// either — see ``GainCurve`` for why.
	public var gain: Double

	public init(at: Double, gain: Double) {
		self.at = at
		self.gain = gain
	}
}

/// A level that changes over the recording, and the arithmetic of it.
///
/// The third and finest of three gains. ``Take/gain`` balances one recording
/// against another and ``Clip/gain`` balances the clips inside one; neither can
/// do anything about the door that slams in the middle of a sentence, because
/// both are a single number for a span somebody wants to keep. A curve is that
/// number as a function of time, so a plosive can come down twelve decibels for
/// eighty milliseconds and leave the sentence around it exactly as it was.
///
/// **The three add.** A point says −9 and the curve takes nine decibels off
/// whatever the take and the clip already asked for, which is what keeps the
/// two coarse knobs worth having: levelling a take against the others does not
/// undo the plosive somebody tamed, and taming a plosive does not have to know
/// what the take was levelled to. An absolute curve would have to be redrawn
/// every time either of them moved.
///
/// **Linear between points, and linear in amplitude.** Not eased, and not
/// linear in decibels. `AVMutableAudioMixInputParameters.setVolumeRamp` moves
/// the volume — the amplitude — in a straight line between two values, so a
/// curve defined that way is exactly one ramp per interval: nothing is
/// subdivided, nothing drifts, and the monitor, the render and the line drawn
/// over the waveform are one piece of arithmetic rather than three
/// approximations of it. Defined in decibels instead, the middle of a fade from
/// −20 dB to 0 dB would sit five decibels away from where the mix actually puts
/// it, and the line over the waveform would be a picture of something nobody
/// would hear. An ease is then a point somebody adds, which is how an
/// automation lane has always worked and is what audio people expect.
///
/// **Held at the ends.** Before the first point and after the last, the curve
/// is that point's level. A two-point curve is a complete statement about a
/// whole recording, which is what makes one worth drawing at all.
public enum GainCurve {

	/// The curve's amplitude at `time` — the ratio a mix multiplies by, and
	/// what the waveform is drawn through.
	///
	/// One for a curve with no points in it, so an untouched take is left
	/// exactly as it was recorded.
	public static func amplitude(at time: Double, in points: [LevelPoint]) -> Double {
		guard let first = points.first, let last = points.last else { return 1 }
		if time <= first.at { return Levelling.amplitude(first.gain) }
		if time >= last.at { return Levelling.amplitude(last.gain) }
		guard let next = points.firstIndex(where: { $0.at > time }), next > 0 else {
			return Levelling.amplitude(last.gain)
		}
		let before = points[next - 1], after = points[next]
		let span = after.at - before.at
		// Two points at one instant are a step, and the later one wins. That is
		// the only way to write a step, since a ramp of no length is not one.
		guard span > 0 else { return Levelling.amplitude(after.gain) }
		let from = Levelling.amplitude(before.gain)
		let to = Levelling.amplitude(after.gain)
		return from + (to - from) * ((time - before.at) / span)
	}

	/// The same, in decibels: what the file says, and what a person reads off
	/// the lane.
	public static func gain(at time: Double, in points: [LevelPoint]) -> Double {
		guard !points.isEmpty else { return 0 }
		let ratio = amplitude(at: time, in: points)
		guard ratio > 0 else { return -.infinity }
		return 20 * log10(ratio)
	}

	/// This curve over one span, with a point at each end of it.
	///
	/// What a clip needs, and what the monitor needs. The points inside the span
	/// are its own; the two at the edges are the curve *evaluated* there,
	/// because a dip that began before the clip did arrives part-way down and
	/// leaving that edge out would silently flatten it.
	///
	/// Empty in, empty out. A take with no curve must resolve and render to
	/// exactly the numbers it did before there were curves.
	public static func clipped(_ points: [LevelPoint], from: Double, to: Double) -> [LevelPoint] {
		guard !points.isEmpty else { return [] }
		let end = Swift.max(from, to)
		var out = [LevelPoint(at: from, gain: gain(at: from, in: points))]
		out += points.filter { $0.at > from && $0.at < end }
		if end > from { out.append(LevelPoint(at: end, gain: gain(at: end, in: points))) }
		return out
	}

	/// Sorted by time, which is the only order a curve has.
	///
	/// Unlike the clips, whose file order is kept — two clips may legitimately
	/// cover the same seconds, and re-ordering a list somebody arranged is the
	/// churn an as-text tool cannot afford. A curve is one function of time: two
	/// orderings of the same points are the same curve, so a hand-written file
	/// whose points are out of order is read as the curve it plainly means
	/// rather than as a sawtooth. Nothing is dropped and nothing is rounded, so
	/// the file gets back what it gave.
	///
	/// Stable, so two points written at one instant — which is how a step is
	/// written — keep the order they were written in.
	public static func tidied(_ points: [LevelPoint]) -> [LevelPoint] {
		points.enumerated()
			.sorted { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }
			.map(\.element)
	}

	/// How far a point may be dragged, in decibels.
	///
	/// The range the lane is drawn over, so that dragging cannot put a point
	/// somewhere it cannot be seen. Deep rather than symmetrical: this is a
	/// tool for taking a door slam off the top of a sentence, and the lift a
	/// quiet stretch needs is a couple of decibels where the cut a plosive needs
	/// is twenty. A number outside it is still legal in the file — somebody who
	/// types −40 means it — and is drawn against the edge of the lane.
	public static let editable: ClosedRange<Double> = -24 ... 6

	/// The steps to hand a mix, over one span: a from-level, a to-level and the
	/// seconds between them.
	///
	/// Straight off consecutive points, because that is what the interpolation
	/// already is. The span is expected to have come through ``clipped(_:from:to:)``,
	/// so the first point is at `from` and the last at `to` and the whole of it
	/// is covered — a mix left uncovered plays at whatever the last ramp said,
	/// which for the lane of a programme is silence.
	///
	/// A single point covers the span flat: a ramp of no length would leave the
	/// clip unset, and "one point means this level throughout" is what holding
	/// the ends already says.
	public static func ramps(
		_ points: [LevelPoint], from: Double, to: Double
	) -> [(start: Double, end: Double, from: Double, to: Double)] {
		guard let first = points.first, to > from else { return [] }
		guard points.count > 1 else {
			return [(from, to, first.gain, first.gain)]
		}
		var out: [(start: Double, end: Double, from: Double, to: Double)] = []
		// The head, when the first point starts after the span does — held, the
		// same as the curve is held before its first point.
		if first.at > from { out.append((from, first.at, first.gain, first.gain)) }
		for (index, point) in points.dropLast().enumerated() {
			let next = points[index + 1]
			guard next.at > point.at else { continue }
			out.append((point.at, next.at, point.gain, next.gain))
		}
		// The tail, when the last point stops short of the end of the span:
		// held, the same as it is held past the end of the curve.
		if let last = points.last, last.at < to {
			out.append((last.at, to, last.gain, last.gain))
		}
		return out
	}
}
