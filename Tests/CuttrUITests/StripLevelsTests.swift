import AppKit
import CuttrKit
import Testing
@testable import CuttrCompose
@testable import CuttrUI

/// The levels lane on the preview strip: a take's gain curve, edited through
/// the clips of it the programme plays.
///
/// What is written is the *take's* curve, whole, on the take's clock — the
/// points outside the clip are somebody's work and go back untouched — and a
/// press that changes nothing writes nothing, the same rule the overlay bars
/// follow.
@MainActor @Suite struct StripLevelsTests {

	/// One take of one clip, from ten to twenty seconds of a recording that is
	/// not there — the lane draws its curve whether or not the sound decodes.
	private func strip(levels: [LevelPoint] = []) throws -> ProgrammeStrip {
		let directory = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("cuttr-strip-levels-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		try TakeWriter.write(Take(video: "black.mov",
		                          clips: [Clip(slug: "one", start: 10, end: 20)],
		                          levels: levels))
			.write(to: directory.appendingPathComponent("t.cuttr"),
			       atomically: true, encoding: .utf8)
		let project = try ProjectReader.read("takes: [t.cuttr]\ntimeline: [one]\n")
		let strip = ProgrammeStrip(frame: NSRect(x: 0, y: 0, width: 662, height: 300))
		strip.resolved = try Resolver.resolve(project, baseURL: directory)
		strip.layoutSubtreeIfNeeded()
		strip.drawForTesting()
		return strip
	}

	@Test func theLaneIsDrawnUnderTheClips() throws {
		let strip = try strip()
		let lane = try #require(strip.levelsLaneForTesting)
		#expect(lane.height == strip.levelsRowHeight)
		#expect(lane.minX == strip.gutterForTesting)
	}

	/// ⌥-dragging across two seconds of the clip lays a dip over exactly that
	/// stretch: four points, on the take's clock, twelve decibels down between
	/// the edges.
	@Test func anOptionDragLaysAFourPointDip() throws {
		let strip = try strip()
		var written: [LevelPoint]?
		strip.onSetLevels = { _, levels in written = levels; return true }
		let lane = try #require(strip.levelsLaneForTesting)
		strip.dragLevelsForTesting(
			from: NSPoint(x: strip.xForTesting(2), y: lane.midY),
			to: NSPoint(x: strip.xForTesting(4), y: lane.midY), option: true)
		let dip = try #require(written, "the dip was not written")
		// The four, and the pin at each end of the clip.
		#expect(dip.count == 6)
		let ats = dip.map(\.at)
		let wanted = [10, 11.94, 12.0, 14.0, 14.06, 20]
		#expect(zip(ats, wanted).allSatisfy { abs($0 - $1) < 0.02 }, "points at \(ats)")
		#expect(dip.map(\.gain) == [0, 0, -12, -12, 0, 0])
	}

	/// A click on a point chooses it and writes nothing.
	@Test func aClickOnAPointWritesNothing() throws {
		let strip = try strip(levels: [LevelPoint(at: 12, gain: -6)])
		var written: [LevelPoint]?
		strip.onSetLevels = { _, levels in written = levels; return true }
		let point = try #require(strip.levelsPointForTesting(time: 2, gain: -6))
		strip.dragLevelsForTesting(from: point, to: point)
		#expect(written == nil, "selecting a point rewrote the take")
		#expect(strip.selectedLevelForTesting == 0)
	}

	/// And a drag moves it: in time along the take's clock, in level down the
	/// lane, and the whole curve is what goes to the file.
	@Test func draggingAPointMovesIt() throws {
		let strip = try strip(levels: [LevelPoint(at: 12, gain: -6), LevelPoint(at: 25, gain: 3)])
		var written: [LevelPoint]?
		strip.onSetLevels = { _, levels in written = levels; return true }
		let from = try #require(strip.levelsPointForTesting(time: 2, gain: -6))
		let to = try #require(strip.levelsPointForTesting(time: 3, gain: -12))
		strip.dragLevelsForTesting(from: from, to: to)
		let moved = try #require(written, "the drag wrote nothing")
		// The moved point, the untouched one past the clip, and a pin at each
		// edge of the clip.
		#expect(moved.count == 4, "\(moved)")
		let inside = try #require(moved.first { $0.at > 10.5 && $0.at < 19.5 })
		#expect(abs(inside.at - 13) < 0.02, "moved to \(inside.at)")
		#expect(abs(inside.gain + 12) < 0.11, "moved to \(inside.gain) dB")
		#expect(moved.contains(LevelPoint(at: 25, gain: 3)), "a point outside the clip was lost")
	}

	/// A take with no curve has the nought line, and a click on it starts one.
	@Test func aClickOnTheLineMakesAPoint() throws {
		let strip = try strip()
		var written: [LevelPoint]?
		strip.onSetLevels = { _, levels in written = levels; return true }
		let from = try #require(strip.levelsPointForTesting(time: 5, gain: 0))
		let to = try #require(strip.levelsPointForTesting(time: 5, gain: -6))
		strip.dragLevelsForTesting(from: from, to: to)
		let made = try #require(written, "the click made nothing")
		// The point, pinned at nought at both ends of the clip: the rest of the
		// take is not taken down six decibels with it.
		#expect(made.count == 3, "\(made)")
		#expect(made.first == LevelPoint(at: 10, gain: 0))
		#expect(made.last == LevelPoint(at: 20, gain: 0))
		#expect(abs(made[1].at - 15) < 0.02)
		#expect(abs(made[1].gain + 6) < 0.11)
	}

	/// The point of the pins: whatever is done inside the clip, the curve
	/// outside it is the curve it was.
	@Test func editingInsideAClipLeavesTheRestOfTheTakeAlone() throws {
		let before = [LevelPoint(at: 12, gain: -6), LevelPoint(at: 25, gain: 3)]
		let strip = try strip(levels: before)
		var written: [LevelPoint]?
		strip.onSetLevels = { _, levels in written = levels; return true }
		let from = try #require(strip.levelsPointForTesting(time: 2, gain: -6))
		let to = try #require(strip.levelsPointForTesting(time: 8, gain: 6))
		strip.dragLevelsForTesting(from: from, to: to)
		let after = try #require(written)
		for at in [0.0, 5, 9.9, 20.1, 22, 25, 40] {
			#expect(abs(GainCurve.gain(at: at, in: after) - GainCurve.gain(at: at, in: before)) < 0.15,
			        "the curve moved at \(at), outside the clip")
		}
		#expect(GainCurve.gain(at: 18, in: after) > 4, "and did move inside it")
	}

	/// A pin is only written along with a change: a click that makes none
	/// leaves a take with no curve exactly that.
	@Test func pinsAreNotWrittenOnTheirOwn() throws {
		let strip = try strip(levels: [LevelPoint(at: 12, gain: -6)])
		var written: [LevelPoint]?
		strip.onSetLevels = { _, levels in written = levels; return true }
		let point = try #require(strip.levelsPointForTesting(time: 2, gain: -6))
		strip.dragLevelsForTesting(from: point, to: point)
		#expect(written == nil)
	}

	/// The dip's arithmetic: it sits on whatever the curve was doing at its
	/// edges, and the points it covers go.
	@Test func aDipSitsOnTheCurveAndClearsWhatItCovers() {
		let curve = [LevelPoint(at: 0, gain: -3), LevelPoint(at: 12.5, gain: 4), LevelPoint(at: 30, gain: -3)]
		let dipped = ProgrammeStrip.dip(over: curve, from: 12, to: 14)
		#expect(dipped.count == 6)
		#expect(!dipped.contains { $0.at == 12.5 })
		let inside = dipped.filter { $0.at >= 12 && $0.at <= 14 }
		#expect(inside.count == 2)
		// Twelve under what the curve was at each edge, to the tenth the file
		// writes — not twelve under nought.
		let edges = [GainCurve.gain(at: 11.94, in: curve), GainCurve.gain(at: 14.06, in: curve)]
		#expect(zip(inside, edges).allSatisfy { abs($0.gain - ($1 - 12)) < 0.11 },
		        "the dip is \(inside), the curve at its edges \(edges)")
	}
}
