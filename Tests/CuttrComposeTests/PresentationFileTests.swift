import CuttrKit
import Foundation
import Testing
@testable import CuttrCompose

/// A presentation treatment as it is written down.
///
/// The file is the product, so this suite is about the file: that a treatment
/// survives being read and written unchanged, that a project with none writes
/// nothing new, and that a treatment is a fact about *one placement* rather
/// than about the clip — which is the whole reason it is written inside the
/// entry rather than beside the overlays at the top.
@Suite struct PresentationFileTests {

	@Test func aTreatmentIsReadFromTheEntry() throws {
		let project = try ProjectReader.read("""
		timeline:
		  - clip: install-demo
		    presentations:
		      - at:    00:12.000
		        into:  [0.04, 0.22, 0.4, 0.4]
		        hold:  6
		        ramp:  0.6
		        scene: bullets
		        with:  {one: "Download it", two: "Open it"}
		""")
		let shown = try #require(project.timeline.first?.presentations.first)
		#expect(shown.at == 12)
		#expect(shown.into == Presentation.Rectangle(x: 0.04, y: 0.22, width: 0.4, height: 0.4))
		#expect(shown.hold == 6)
		#expect(shown.ramp == 0.6)
		#expect(shown.scene == "bullets")
		#expect(shown.parameters == ["one": "Download it", "two": "Open it"])
		#expect(shown.reveal == .together)
	}

	/// Every optional key left out. What comes back is a treatment with the
	/// defaults, and — the part that matters — writing it puts none of them
	/// back in.
	@Test func aPlainTreatmentStaysPlain() throws {
		let project = try ProjectReader.read("""
		timeline:
		  - clip: install-demo
		    presentations:
		      - at:    00:04.000
		        into:  [0.5, 0.1, 0.45, 0.8]
		        scene: boxes
		""")
		#expect(project.timeline[0].presentations[0].ramp == 0.6)
		#expect(project.timeline[0].presentations[0].hold == 0)
		let written = ProjectWriter.write(project)
		#expect(written.contains("""
		    presentations:
		      - at:    00:04.000
		        into:  [0.5, 0.1, 0.45, 0.8]
		        scene: boxes
		"""))
		// The defaults are not written back: a treatment that said nothing
		// about its ramp or its hold does not acquire lines saying so.
		#expect(!written.contains("ramp"))
		#expect(!written.contains("hold"))
		#expect(!written.contains("reveal"))
	}

	@Test func aTreatmentRoundTripsByteForByte() throws {
		let project = try ProjectReader.read("""
		timeline:
		  - clip: install-demo
		    presentations:
		      - at:    00:12.000
		        into:  [0.04, 0.22, 0.4, 0.4]
		        hold:  6
		        ramp:  1.2
		        scene: bullets
		        with:  {one: "Download it", three: "Drag it across", two: "Open it"}
		        reveal: one-by-one
		      - at:    00:30.000
		        into:  [0.5, 0.2, 0.45, 0.6]
		        hold:  4
		        scene: boxes
		  - clip: two
		""")
		let written = ProjectWriter.write(project)
		let back = try ProjectReader.read(written)
		#expect(back == project)
		// The rule the whole emitter exists for: saving an unchanged project
		// changes no bytes.
		#expect(ProjectWriter.write(back) == written)
		// One key wider all the way down, because this treatment has a
		// `reveal:` in it and the column is the width of the widest key the
		// treatment actually has.
		#expect(written.contains("""
		    presentations:
		      - at:     00:12.000
		        into:   [0.04, 0.22, 0.4, 0.4]
		        hold:   6
		        ramp:   1.2
		        scene:  bullets
		"""))
		// And the second, which has no `reveal:`, is not.
		#expect(written.contains("""
		      - at:    00:30.000
		        into:  [0.5, 0.2, 0.45, 0.6]
		        hold:  4
		        scene: boxes
		"""))
	}

	/// The reason for `presentations:` living where it does. A treatment is
	/// about this use of the recording; the same clip placed again is not
	/// stopped, and a reader that hung treatments off the clip would stop both.
	@Test func theSameClipPlacedTwiceIsTreatedOnlyWhereAsked() throws {
		let project = try ProjectReader.read("""
		timeline:
		  - clip: install-demo
		    presentations:
		      - at:    00:02.000
		        into:  [0.05, 0.2, 0.4, 0.4]
		        hold:  3
		        scene: bullets
		  - clip: install-demo
		""")
		#expect(project.timeline[0].presentations.count == 1)
		#expect(project.timeline[1].presentations.isEmpty)
	}

	/// A treatment with no scene holds the picture and shows nothing, which is
	/// a pause nobody asked for. Skipped whole rather than half-read.
	@Test func aTreatmentWithNothingToShowIsNotOne() throws {
		let project = try ProjectReader.read("""
		timeline:
		  - clip: install-demo
		    presentations:
		      - at:   00:02.000
		        into: [0.05, 0.2, 0.4, 0.4]
		        hold: 3
		      - at:    00:06.000
		        scene: bullets
		""")
		#expect(project.timeline[0].presentations.isEmpty)
	}

	/// The rule every nested block here follows: a project that has none of
	/// this writes exactly what it wrote before, so the feature costs nothing
	/// to a file that does not use it.
	@Test func aProjectWithNoTreatmentsWritesNoBlock() throws {
		let project = try ProjectReader.read("""
		timeline:
		  - clip: one
		  - clip: two
		""")
		let written = ProjectWriter.write(project)
		#expect(!written.contains("presentations"))
		#expect(written.hasSuffix("timeline:\n  - clip: one\n  - clip: two\n"))
	}
}
