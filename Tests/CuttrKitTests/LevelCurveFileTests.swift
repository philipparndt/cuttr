import Foundation
import Testing
@testable import CuttrKit

/// The gain curve, in the file.
///
/// The take file is the product, so the three things that matter about a new
/// list are that it comes back exactly as it went in, that a take nobody has
/// touched does not grow it, and that what somebody wrote around it survives.
@Suite struct LevelCurveFileTests {

	private func take(_ levels: [LevelPoint]) -> Take {
		Take(video: "a.mov",
		     clips: [Clip(slug: "one", name: "One", start: 0, end: 2)],
		     levels: levels)
	}

	private let dip = [
		LevelPoint(at: 12.26, gain: 0),
		LevelPoint(at: 12.3, gain: -11.5),
		LevelPoint(at: 12.42, gain: -11.5),
		LevelPoint(at: 12.46, gain: 0),
	]

	@Test func aCurveSurvivesTheFile() throws {
		let written = TakeWriter.write(take(dip))
		let read = try TakeReader.read(written)
		#expect(read.levels == dip)
	}

	/// One point a line, in the flow form a scene's keys are written in.
	@Test func aPointIsOneLine() {
		let written = TakeWriter.write(take(dip))
		#expect(written.contains("levels:"))
		#expect(written.contains("  - {at: 00:12.300, gain: -11.5}\n"))
	}

	/// A take nobody has drawn a curve on does not carry a block saying so.
	@Test func anEmptyCurveIsNotWrittenDown() {
		#expect(!TakeWriter.write(take([])).contains("levels:"))
	}

	/// The rule the whole emitter exists for.
	@Test func writingIsStableForTheSameCurve() throws {
		let once = TakeWriter.write(take(dip))
		let twice = TakeWriter.write(try TakeReader.read(once))
		#expect(once == twice)
	}

	/// A hand-written one reads, in every spelling somebody would type it in:
	/// bare seconds, a timecode, the block form, and out of order.
	@Test func readsWhatSomebodyWouldTypeByHand() throws {
		let take = try TakeReader.read("""
		video: a.mov
		levels:
		  - {at: 90, gain: -3}
		  - at:   00:01.500
		    gain: -6
		  - {at: 00:00.500}
		clips: []
		""")
		#expect(take.levels.map(\.at) == [0.5, 1.5, 90])
		// A point with no level is a moment somebody marked and has not decided
		// about, which is nought and reads perfectly well.
		#expect(take.levels.map(\.gain) == [0, -6, -3])
	}

	/// A value somebody typed comes back as they typed it rather than being
	/// rounded into a different number on the next save.
	@Test func aHandTypedLevelIsNotRewritten() throws {
		let text = """
			cuttr: 1
			video: a.mov

			levels:   # dB against the clock, on top of the take's level
			  - {at: 00:00.500, gain: -3.25}

			clips:
			  - slug:  one
			    name:  One
			    start: 00:00.000
			    end:   00:01.000   # 00:01.000
			"""
		let read = try TakeReader.read(text)
		#expect(read.levels == [LevelPoint(at: 0.5, gain: -3.25)])
		let written = TakeWriter.write(read)
		#expect(written.contains("  - {at: 00:00.500, gain: -3.25}\n"))
		#expect(TakeWriter.write(try TakeReader.read(written)) == written)
	}

	/// The curve is under the flat level it adds to, because reading the two
	/// together is the only way the sum makes sense.
	@Test func theCurveIsWrittenUnderTheFlatLevel() {
		var t = take(dip)
		t.gain = -4
		let written = TakeWriter.write(t)
		let level = try! #require(written.range(of: "\ngain:"))
		let curve = try! #require(written.range(of: "\nlevels:"))
		let clips = try! #require(written.range(of: "\nclips:"))
		#expect(level.lowerBound < curve.lowerBound)
		#expect(curve.lowerBound < clips.lowerBound)
	}

	/// A comment somebody wrote above a point stays above *that* point when the
	/// file is written again — a list item is addressed by what it says, so it
	/// does not slide onto the point below when one is added above it.
	@Test func aNoteAboveAPointStaysWithIt() throws {
		let text = """
			cuttr: 1
			video: a.mov

			levels:   # dB against the clock, on top of the take's level
			  - {at: 00:12.260, gain: 0}
			  # the door in the hall
			  - {at: 00:12.300, gain: -11.5}
			  - {at: 00:12.420, gain: -11.5}
			  - {at: 00:12.460, gain: 0}

			clips:
			  - slug:  one
			    name:  One
			    start: 00:00.000
			    end:   00:01.000   # 00:01.000
			"""
		var read = try TakeReader.read(text)
		// Everything from `video:` down, byte for byte. Only the top differs:
		// the emitter writes its own header line and a blank line under
		// `cuttr:`, neither of which a hand-written file need have.
		let body = try #require(text.range(of: "video:")).lowerBound
		#expect(TakeWriter.write(read).hasSuffix(text[body...] + "\n"))
		// A point added *before* the one the note is about, and the note is
		// still about the door rather than about whatever is now above it.
		read.setLevel(-2, at: 5)
		let written = TakeWriter.write(read)
		let lines = written.components(separatedBy: "\n")
		let note = try #require(lines.firstIndex(of: "  # the door in the hall"))
		#expect(lines[note + 1] == "  - {at: 00:12.300, gain: -11.5}")
	}

	/// A file written before curves existed reads and writes exactly as it did.
	@Test func aFileWithNoCurveIsUnchanged() throws {
		let text = """
			cuttr: 1
			video: a.mov

			clips:
			  - slug:  one
			    name:  One
			    start: 00:00.000
			    end:   00:01.000   # 00:01.000
			"""
		let read = try TakeReader.read(text)
		#expect(read.levels.isEmpty)
		let written = TakeWriter.write(read)
		#expect(!written.contains("levels:"))
		let body = try #require(text.range(of: "video:")).lowerBound
		#expect(written.hasSuffix(text[body...] + "\n"))
	}

	/// And a key this version does not know, beside a curve it does, is still
	/// carried through: `levels:` is taken out of the mapping before the rest is
	/// kept, so it cannot arrive twice.
	@Test func anUnknownKeyBesideACurveIsKept() throws {
		let read = try TakeReader.read("""
		video: a.mov
		chapters: [one, two]
		levels:
		  - {at: 00:01.000, gain: -6}
		clips: []
		""")
		let written = TakeWriter.write(read)
		#expect(written.contains("chapters:"))
		#expect(written.components(separatedBy: "levels:").count == 2)
		#expect(try TakeReader.read(written).levels == [LevelPoint(at: 1, gain: -6)])
	}
}
