import Foundation
import Testing
@testable import CuttrKit

/// A clip's level, in the file.
///
/// The take file is the product, so the two things that matter about a new key
/// are that it comes back exactly as it went in, and that a take nobody has
/// touched does not grow it.
@Suite struct ClipGainFileTests {

	private func take(_ gains: [Double]) -> Take {
		Take(video: "a.mov", clips: gains.enumerated().map { index, gain in
			Clip(slug: "c\(index)", name: "C\(index)",
			     start: Double(index), end: Double(index) + 1, gain: gain)
		})
	}

	@Test func aLevelSurvivesTheFile() throws {
		let written = TakeWriter.write(take([-3.5, 0, 6.25]))
		let read = try TakeReader.read(written)
		#expect(read.clips.map(\.gain) == [-3.5, 0, 6.25])
	}

	/// Nought is left out, so a take nobody has levelled does not carry
	/// `gain: 0` on every clip looking like a decision.
	@Test func noughtIsNotWrittenDown() {
		let written = TakeWriter.write(take([0, 0]))
		#expect(!written.contains("gain:"))
		#expect(TakeWriter.write(take([0, -2])).contains("gain:  -2"))
	}

	/// The rule the whole emitter exists for: re-saving an unchanged take
	/// produces an unchanged file.
	@Test func writingIsStableForTheSameLevels() throws {
		let once = TakeWriter.write(take([-3.5, 0, 6.25]))
		let twice = TakeWriter.write(try TakeReader.read(once))
		#expect(once == twice)
	}

	/// And a value somebody typed by hand comes back as they typed it, rather
	/// than being rounded into a different number on the next save.
	@Test func aHandTypedLevelIsNotRewritten() throws {
		let text = """
			cuttr: 1
			video: a.mov

			clips:
			  - slug:  one
			    name:  One
			    start: 00:00.000
			    end:   00:01.000
			    gain:  -3.25
			"""
		let read = try TakeReader.read(text)
		#expect(read.clips.first?.gain == -3.25)
		let written = TakeWriter.write(read)
		#expect(written.contains("gain:  -3.25"))
		#expect(TakeWriter.write(try TakeReader.read(written)) == written)
	}

	/// A whole number reads and writes without a decimal point pretending to be
	/// precision it does not have.
	@Test func aWholeNumberOfDecibelsIsWrittenAsOne() {
		#expect(TakeWriter.write(take([-6])).contains("gain:  -6\n"))
	}

	/// A file written before levels existed reads exactly as it did.
	@Test func aFileWithNoLevelsIsUnchanged() throws {
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
		#expect(read.clips.first?.gain == 0)
		#expect(!TakeWriter.write(read).contains("gain:"))
	}
}
