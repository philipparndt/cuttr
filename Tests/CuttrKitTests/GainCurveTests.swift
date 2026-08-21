import Foundation
import Testing
@testable import CuttrKit

/// The arithmetic of a level that changes over the take.
///
/// All of it without a window, because all of it has a right answer: the mix,
/// the render and the line drawn over the waveform are the same three functions,
/// and if they were three copies of the arithmetic they would be three
/// approximations of it.
@Suite struct GainCurveTests {

	private let dip = [
		LevelPoint(at: 1.0, gain: 0),
		LevelPoint(at: 1.1, gain: -12),
		LevelPoint(at: 1.3, gain: -12),
		LevelPoint(at: 1.4, gain: 0),
	]

	/// A take nobody has drawn a curve on is left exactly as it was recorded.
	@Test func noCurveIsNoChange() {
		#expect(GainCurve.amplitude(at: 3, in: []) == 1)
		#expect(GainCurve.gain(at: 3, in: []) == 0)
		#expect(GainCurve.clipped([], from: 0, to: 10).isEmpty)
		#expect(GainCurve.ramps([], from: 0, to: 10).isEmpty)
	}

	/// Held at both ends, so two points are a complete statement about a whole
	/// recording rather than a statement about the seconds between them.
	@Test func theEndsAreHeld() {
		#expect(abs(GainCurve.gain(at: 0, in: dip) - 0) < 1e-9)
		#expect(abs(GainCurve.gain(at: 900, in: dip) - 0) < 1e-9)
		let single = [LevelPoint(at: 5, gain: -6)]
		#expect(abs(GainCurve.gain(at: 0, in: single) + 6) < 1e-9)
		#expect(abs(GainCurve.gain(at: 500, in: single) + 6) < 1e-9)
	}

	/// Flat between two points that say the same thing — the floor of the dip
	/// is the dip, not a slope through it.
	@Test func aFlatStretchIsFlat() {
		for time in [1.1, 1.15, 1.2, 1.25, 1.3] {
			#expect(abs(GainCurve.gain(at: time, in: dip) + 12) < 1e-9,
			        "at \(time) it was \(GainCurve.gain(at: time, in: dip))")
		}
	}

	/// **The interpolation is linear in amplitude, not in decibels**, because
	/// that is what `setVolumeRamp` does: half way from 0 dB to −20 dB the mix
	/// plays 0.55 of the amplitude, which is −5.2 dB and not −10. Defining the
	/// curve the other way would leave the picture and the sound five decibels
	/// apart in the middle of every fade.
	@Test func halfWayIsHalfTheAmplitude() {
		let fade = [LevelPoint(at: 0, gain: -20), LevelPoint(at: 1, gain: 0)]
		#expect(abs(GainCurve.amplitude(at: 0.5, in: fade) - 0.55) < 1e-9)
		#expect(abs(GainCurve.gain(at: 0.5, in: fade) + 5.19) < 0.01)
	}

	/// A point's own level comes back exactly, which is what makes the number in
	/// the file the number somebody set.
	@Test func aPointReadsBackAsItself() {
		for point in dip {
			#expect(abs(GainCurve.gain(at: point.at, in: dip) - point.gain) < 1e-9)
		}
	}

	/// Out of order in the file is the same curve, because a curve is one
	/// function of time. Nothing is dropped and nothing is rounded.
	@Test func pointsAreSortedAndNothingIsLost() {
		let jumbled = [LevelPoint(at: 3, gain: -1), LevelPoint(at: 1, gain: -2),
		               LevelPoint(at: 2, gain: -3.25)]
		let tidy = GainCurve.tidied(jumbled)
		#expect(tidy.map(\.at) == [1, 2, 3])
		#expect(tidy.map(\.gain) == [-2, -3.25, -1])
	}

	/// Two points at one instant are a step, and the later one wins — the only
	/// way to write one, since a ramp of no length is not a ramp.
	@Test func twoPointsAtOneInstantAreAStep() {
		let step = [LevelPoint(at: 1, gain: 0), LevelPoint(at: 1, gain: -9)]
		#expect(abs(GainCurve.gain(at: 1.5, in: step) + 9) < 1e-9)
	}

	/// A clip gets the curve over its own span, with a point at each edge: a dip
	/// that began before the cut arrives part-way down, and dropping that edge
	/// would silently flatten it.
	@Test func aSpanKeepsItsEdges() {
		let over = GainCurve.clipped(dip, from: 1.05, to: 1.2)
		#expect(over.count == 3)
		#expect(over.first?.at == 1.05)
		#expect(abs((over.first?.gain ?? 0) - GainCurve.gain(at: 1.05, in: dip)) < 1e-9)
		// Part-way down the shoulder, so neither 0 nor −12.
		#expect((over.first?.gain ?? 0) < -1 && (over.first?.gain ?? 0) > -11)
		#expect(over.last?.at == 1.2)
		#expect(abs((over.last?.gain ?? 0) + 12) < 1e-9)
	}

	/// And a span the curve says nothing about is still covered, flat, so the
	/// mix is never left to a default.
	@Test func aSpanBeyondTheCurveIsCoveredFlat() {
		let over = GainCurve.clipped(dip, from: 8, to: 9)
		#expect(over.count == 2)
		#expect(over.allSatisfy { abs($0.gain) < 1e-9 })
	}

	/// The ramps cover the whole span end to end. A gap in them is a stretch of
	/// programme the mix has not been told about, which on a composition's lane
	/// is silence.
	@Test func theRampsCoverTheWholeSpan() {
		let moves = GainCurve.ramps(GainCurve.clipped(dip, from: 0.5, to: 2), from: 0.5, to: 2)
		#expect(moves.first?.start == 0.5)
		#expect(moves.last?.end == 2)
		for (index, move) in moves.enumerated() where index > 0 {
			#expect(abs(move.start - moves[index - 1].end) < 1e-9)
		}
		// And they are the levels the curve says, at both ends of each of them.
		for move in moves {
			#expect(abs(move.from - GainCurve.gain(at: move.start, in: dip)) < 1e-6)
			#expect(abs(move.to - GainCurve.gain(at: move.end, in: dip)) < 1e-6)
		}
	}

	/// One point covers its span flat rather than writing a ramp of no length,
	/// which would leave the clip unset.
	@Test func onePointCoversTheSpan() {
		let moves = GainCurve.ramps([LevelPoint(at: 1, gain: -6)], from: 0, to: 4)
		#expect(moves.count == 1)
		#expect(moves.first?.start == 0)
		#expect(moves.first?.end == 4)
		#expect(moves.first?.from == -6)
	}

	/// The three levels add, and the sum is written down in one place.
	@Test func theThreeLevelsAdd() {
		var take = Take(video: "a.mov", clips: [Clip(slug: "one", start: 0, end: 2, gain: -1)])
		take.gain = -3
		take.levels = dip
		#expect(abs(take.level(at: 0) + 3) < 1e-9)
		#expect(abs(take.level(at: 1.2) + 15) < 1e-9)
		// And a clip's own trim is still on top of that, which is the renderer's
		// arithmetic — see ResolvedClip.level(at:).
		#expect(abs(take.level(at: 1.2) + take.clips[0].gain + 16) < 1e-9)
	}

	// MARK: - Editing

	@Test func aPointIsAddedInOrderAndFoundAgain() {
		var take = Take(video: "a.mov")
		let first = take.setLevel(-6, at: 4)
		let second = take.setLevel(-2, at: 1)
		#expect(take.levels.map(\.at) == [1, 4])
		#expect(take.levels[second].gain == -2)
		#expect(take.levels[first == 0 ? 1 : first].gain == -6)
	}

	/// A click a hair from an existing point is that point. Otherwise a wide
	/// zoom would grow a second point under the first and put a step in the
	/// curve that nobody asked for and nobody can see.
	@Test func aClickNearAPointMovesIt() {
		var take = Take(video: "a.mov", levels: [LevelPoint(at: 4, gain: -6)])
		let index = take.setLevel(-9, at: 4.02, within: 0.05)
		#expect(index == 0)
		#expect(take.levels.count == 1)
		#expect(take.levels[0].gain == -9)
		#expect(take.levels[0].at == 4)
	}

	/// A drag cannot take a point past its neighbours: the thing being held has
	/// to stay the thing being held for the length of the drag.
	@Test func aDragCannotCrossItsNeighbours() {
		var take = Take(video: "a.mov", levels: dip)
		take.moveLevel(1, to: 9, gain: -3)
		#expect(take.levels[1].at < take.levels[2].at)
		#expect(take.levels[1].gain == -3)
		take.moveLevel(1, to: -5, gain: -3)
		#expect(take.levels[1].at >= take.levels[0].at)
		#expect(take.levels.map(\.at) == take.levels.map(\.at).sorted())
	}

	@Test func aPointIsRemovedAndTheRestStay() {
		var take = Take(video: "a.mov", levels: dip)
		take.removeLevel(at: 1)
		#expect(take.levels.count == 3)
		#expect(take.levels.map(\.at) == [1.0, 1.3, 1.4])
		// And an index that is not there is not a crash.
		take.removeLevel(at: 99)
		#expect(take.levels.count == 3)
	}
}
