import Testing
@testable import CuttrKit

@Suite struct TimecodeTests {

	@Test func readsEveryFormThatGetsTyped() {
		#expect(Timecode.parse("12.5") == 12.5)
		#expect(Timecode.parse("90") == 90)
		#expect(Timecode.parse("01:30.250") == 90.25)
		#expect(Timecode.parse("1:02:03.004") == 3723.004)
		#expect(Timecode.parse(" 00:01.500 ") == 1.5)
	}

	@Test func signsApplyToTheWholeValue() {
		#expect(Timecode.parse("-00:01.250") == -1.25)
		#expect(Timecode.parse("+00:01.250") == 1.25)
	}

	@Test func rejectsThingsThatAreNotTimes() {
		#expect(Timecode.parse("") == nil)
		#expect(Timecode.parse("abc") == nil)
		#expect(Timecode.parse("1e3") == nil)         // Double() would take this
		#expect(Timecode.parse("0x10") == nil)
		#expect(Timecode.parse("inf") == nil)
		#expect(Timecode.parse("1:2:3:4") == nil)
		#expect(Timecode.parse("1.5:00") == nil)      // only the last field may be fractional
		#expect(Timecode.parse("1:-2") == nil)
	}

	@Test func hoursAppearOnlyWhenThereAreSome() {
		#expect(Timecode.string(1.5) == "00:01.500")
		#expect(Timecode.string(90.25) == "01:30.250")
		#expect(Timecode.string(3723.004) == "1:02:03.004")
	}

	@Test func roundsInMillisecondsRatherThanTwice() {
		// A floor of the seconds plus a round of the remainder gives 12.1000
		// here, which is not a time.
		#expect(Timecode.string(12.9996) == "00:13.000")
	}

	@Test func roundTripsThroughText() {
		for seconds in [0.0, 0.001, 1.5, 59.999, 60.0, 3599.999, 3600.0, 7322.125] {
			let text = Timecode.string(seconds)
			#expect(Timecode.parse(text) == seconds, "\(text)")
		}
	}

	@Test func offsetsAlwaysCarryTheirSign() {
		#expect(Timecode.offsetString(1.234) == "+00:01.234")
		#expect(Timecode.offsetString(-1.234) == "-00:01.234")
		#expect(Timecode.offsetString(0) == "+00:00.000")
	}

	@Test func aFrameGridRoundsToRealFrames() {
		let grid = FrameGrid(framesPerSecond: 25)
		#expect(grid.snap(1.03) == 1.04)
		#expect(grid.frameDuration == 0.04)
		// A variable-rate recording has no grid, and inventing one would move
		// every mark somebody placed.
		#expect(FrameGrid.none.snap(1.03) == 1.03)
		#expect(FrameGrid.none.hasGrid == false)
	}
}
