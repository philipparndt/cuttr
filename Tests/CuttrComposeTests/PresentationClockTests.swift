import CuttrKit
import Foundation
import Testing
@testable import CuttrCompose

/// The clock, which is the substance of the feature.
///
/// A hold makes the programme longer without skipping any of the recording, so
/// the straight line between programme time and take time becomes a staircase.
/// Every reader of it goes through ``ResolvedClip/takeTime(forProgramme:)`` and
/// ``ResolvedClip/programmeTime(forTake:)``, so those two are tested hardest of
/// anything here: an anchor is sampled on the take's clock and mapped forward,
/// and a caller that assumed a straight line would put a tracked face where the
/// recording would have been if it had not stopped.
@Suite struct PresentationClockTests {

	private func clip(_ holds: [(at: Double, hold: Double)],
	                  from: Double = 0, to: Double = 10,
	                  start: Double = 0) -> ResolvedClip {
		ResolvedClip(
			reference: ClipReference(take: "take-01", slug: "demo"),
			takeName: "take-01",
			clip: Clip(slug: "demo", start: from, end: to),
			videoURL: nil, audioURL: nil, audioOffset: 0,
			start: start,
			presentations: holds.map {
				Presentation(at: $0.at, into: Presentation.Rectangle(
					x: 0.05, y: 0.2, width: 0.4, height: 0.4),
					hold: $0.hold, scene: "bullets")
			})
	}

	/// A clip with no treatment is exactly what it was: the straight line, and
	/// every project that has never heard of this feature keeps it.
	@Test func aClipWithNoHoldsIsUnchanged() {
		let plain = clip([], from: 4, to: 9, start: 20)
		#expect(plain.duration == 5)
		#expect(plain.end == 25)
		#expect(plain.takeTime(forProgramme: 22) == 6)
		#expect(plain.programmeTime(forTake: 6) == 22)
	}

	@Test func aHoldMakesTheProgrammeLongerByExactlyIt() {
		let held = clip([(at: 3, hold: 6)])
		#expect(held.duration == 16)
		#expect(held.end == 16)
	}

	/// Before the hold, nothing has happened yet.
	@Test func timeBeforeAHoldMapsStraightAcross() {
		let held = clip([(at: 3, hold: 6)])
		#expect(held.takeTime(forProgramme: 1) == 1)
		#expect(held.takeTime(forProgramme: 3) == 3)
		#expect(held.programmeTime(forTake: 1) == 1)
	}

	/// Inside it the take's clock stands still — every programme moment of the
	/// hold is the one frame the hold began on.
	@Test func timeInsideAHoldStandsStill() {
		let held = clip([(at: 3, hold: 6)])
		#expect(held.takeTime(forProgramme: 3.5) == 3)
		#expect(held.takeTime(forProgramme: 6) == 3)
		#expect(held.takeTime(forProgramme: 8.99) == 3)
	}

	/// And after it, the recording carries on from where it stopped. Nothing is
	/// skipped: this is the assertion that separates a hold from a cut to a
	/// still.
	@Test func timeAfterAHoldPicksUpWhereItStopped() {
		let held = clip([(at: 3, hold: 6)])
		#expect(held.takeTime(forProgramme: 9) == 3)
		#expect(held.takeTime(forProgramme: 9.5) == 3.5)
		#expect(held.takeTime(forProgramme: 16) == 10)
	}

	/// The property everything else rests on. Sampled across the whole clip,
	/// mapping a take time forward and back has to land where it started —
	/// except inside a hold, where several programme times share one take time
	/// and only the first can come back.
	@Test func theMappingIsInverseToItselfAcrossAHold() {
		let held = clip([(at: 3, hold: 6)], start: 12)
		for step in 0...100 {
			let take = 0 + Double(step) / 10
			let there = held.programmeTime(forTake: take)
			let back = held.takeTime(forProgramme: there)
			#expect(abs(back - take) < 1e-9, "take \(take) came back as \(back)")
		}
	}

	/// Two holds in one clip, which is where an implementation that subtracts
	/// the total rather than walking them in order goes wrong.
	@Test func twoHoldsInOneClipEachCountOnce() {
		let held = clip([(at: 2, hold: 4), (at: 7, hold: 3)])
		#expect(held.duration == 17)

		// Between the two: one hold has passed, the second has not.
		#expect(held.takeTime(forProgramme: 6) == 2)      // still in the first
		#expect(held.takeTime(forProgramme: 6.5) == 2.5)  // just out of it
		#expect(held.takeTime(forProgramme: 11) == 7)     // arriving at the second
		#expect(held.takeTime(forProgramme: 13) == 7)     // inside it
		#expect(held.takeTime(forProgramme: 14) == 7)
		#expect(held.takeTime(forProgramme: 15) == 8)     // out the far side
		#expect(held.takeTime(forProgramme: 17) == 10)

		#expect(held.programmeTime(forTake: 2) == 2)
		#expect(held.programmeTime(forTake: 2.5) == 6.5)
		#expect(held.programmeTime(forTake: 7) == 11)
		#expect(held.programmeTime(forTake: 8) == 15)
	}

	/// A clip that does not begin at the head of its take, placed somewhere
	/// other than the head of the programme. Both offsets are in the arithmetic
	/// and getting either the wrong way round is invisible until it is not.
	@Test func aTrimmedClipPlacedLateIsStillRight() {
		let held = clip([(at: 30, hold: 5)], from: 25, to: 40, start: 100)
		#expect(held.duration == 20)
		#expect(held.takeTime(forProgramme: 100) == 25)
		#expect(held.takeTime(forProgramme: 105) == 30)
		#expect(held.takeTime(forProgramme: 107) == 30)
		#expect(held.takeTime(forProgramme: 110) == 30)
		#expect(held.takeTime(forProgramme: 112) == 32)
		#expect(held.programmeTime(forTake: 32) == 112)
	}

	/// A treatment that moves the picture and gives no time back costs the
	/// clock nothing, so a project can push the picture aside over a scene it
	/// has already made room for.
	@Test func aTreatmentWithNoHoldChangesNoTime() {
		let held = clip([(at: 3, hold: 0)])
		#expect(held.duration == 10)
		#expect(held.takeTime(forProgramme: 5) == 5)
		#expect(held.programmeTime(forTake: 5) == 5)
	}
}
