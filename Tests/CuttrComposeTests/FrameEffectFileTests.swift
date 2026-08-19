import Foundation
import Testing
@testable import CuttrCompose

/// The two new kinds, through the file and back.
///
/// The project file is the product, so what is tested is not that the values
/// survive but that the *bytes* do: a project nobody has touched has to come
/// out of a newer version of this program exactly as it went into an older one,
/// or a one-word edit arrives as a rewritten file.
@Suite struct FrameEffectFileTests {

	private func project(_ kind: Overlay.Kind) -> Project {
		Project(
			timeline: [TimelineEntry(clip: ClipReference("intro"))],
			overlays: [Overlay(kind: kind,
			                   span: .clips(from: ClipReference("intro"), to: ClipReference("intro")),
			                   arrival: .fade(over: 0.5), departure: .fade(over: 0.5))])
	}

	@Test func anAberrationSurvivesTheFile() throws {
		for kind in Aberration.Kind.allCases {
			// Only the linear kind carries an angle. A radial one is given none
			// here because it would not be written and so could not come back —
			// which is the writer being right rather than the test being kind.
			let one = project(.aberration(Aberration(
				kind: kind, amount: 0.9, angle: kind == .linear ? 30 : 0)))
			let text = ProjectWriter.write(one)
			let back = try ProjectReader.read(text)
			#expect(back.overlays == one.overlays, "\(kind) did not come back")
			#expect(ProjectWriter.write(back) == text, "\(kind) was rewritten by a round trip")
		}
	}

	/// Only what is not the default. A plain radial aberration is one line.
	@Test func anAberrationWritesOnlyWhatItHasChanged() throws {
		let text = ProjectWriter.write(project(.aberration(Aberration())))
		#expect(text.contains("  - aberration: radial\n"))
		#expect(!text.contains("amount:"))
		#expect(!text.contains("angle:"))
		// And a radial one never writes an angle, because it has no use for one.
		let turned = ProjectWriter.write(project(.aberration(Aberration(kind: .radial, angle: 90))))
		#expect(!turned.contains("angle:"))
		#expect(ProjectWriter.write(try ProjectReader.read(text)) == text)
	}

	/// `aberration: 0.6` — somebody who means the amount and does not care
	/// which kind, which is the commoner of the two things to mean.
	@Test func aBareNumberIsTheAmount() throws {
		let read = try ProjectReader.read("""
			cuttr-project: 1
			timeline:
			  - clip: intro
			overlays:
			  - aberration: 0.6
			    from:   intro
			""")
		#expect(read.overlays.count == 1)
		guard case .aberration(let aberration) = read.overlays.first?.kind else {
			Issue.record("it did not come back as an aberration")
			return
		}
		#expect(aberration.kind == .radial)
		#expect(aberration.amount == 0.6)
	}

	@Test func everyTapeConditionSurvivesTheFile() throws {
		for condition in Tape.Condition.allCases {
			var tape = Tape(condition, seed: 12)
			tape.chroma = 0.62
			let one = project(.tape(tape))
			let text = ProjectWriter.write(one)
			let back = try ProjectReader.read(text)
			#expect(back.overlays == one.overlays, "\(condition) did not come back")
			#expect(ProjectWriter.write(back) == text, "\(condition) was rewritten by a round trip")
			#expect(text.contains("  - tape:    \(condition.rawValue)\n"))
			#expect(text.contains("chroma:  0.62"))
			#expect(text.contains("seed:    12"))
		}
	}

	/// A knob that still says what the condition says is not written at all —
	/// that is what makes the condition a choice rather than a label.
	@Test func aTapeWritesOnlyTheKnobsItHasTurned() throws {
		let text = ProjectWriter.write(project(.tape(Tape(.worn))))
		#expect(text.contains("  - tape:    worn\n"))
		for knob in ["jitter", "band", "chroma", "scanlines", "dropouts", "seed"] {
			#expect(!text.contains("\(knob):"), "\(knob) was written when it did not need to be")
		}
		#expect(ProjectWriter.write(try ProjectReader.read(text)) == text)
	}

	/// Writing the same project twice writes the same bytes.
	@Test func writingIsStable() {
		let stacked = Project(
			timeline: [TimelineEntry(clip: ClipReference("intro"))],
			overlays: [
				Overlay(kind: .aberration(Aberration(kind: .linear, amount: 0.3, angle: 12)),
				        span: .clips(from: ClipReference("intro"), to: ClipReference("intro"))),
				Overlay(kind: .film(Film()),
				        span: .clips(from: ClipReference("intro"), to: ClipReference("intro"))),
				Overlay(kind: .tape(Tape(.chewed)),
				        span: .clips(from: ClipReference("intro"), to: ClipReference("intro"))),
			])
		#expect(ProjectWriter.write(stacked) == ProjectWriter.write(stacked))
	}

	/// The order of the list is the order they are drawn in, so the file has to
	/// keep it. Two projects that differ only in which way round two overlays
	/// are written are two different programmes.
	@Test func theOrderOfTheListSurvivesTheFile() throws {
		let lens = Overlay(kind: .aberration(Aberration()),
		                   span: .clips(from: ClipReference("intro"), to: ClipReference("intro")))
		let film = Overlay(kind: .film(Film()),
		                   span: .clips(from: ClipReference("intro"), to: ClipReference("intro")))
		let under = Project(timeline: [TimelineEntry(clip: ClipReference("intro"))],
		                    overlays: [lens, film])
		let over = Project(timeline: [TimelineEntry(clip: ClipReference("intro"))],
		                   overlays: [film, lens])
		#expect(ProjectWriter.write(under) != ProjectWriter.write(over))
		#expect(try ProjectReader.read(ProjectWriter.write(under)).overlays == [lens, film])
		#expect(try ProjectReader.read(ProjectWriter.write(over)).overlays == [film, lens])
	}
}
