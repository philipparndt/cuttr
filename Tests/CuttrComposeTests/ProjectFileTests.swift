import CoreGraphics
import Foundation
import Testing
@testable import CuttrCompose

@Suite struct ProjectFileTests {

	private func sample() -> Project {
		Project(
			takes: ["takes/take-01.cuttr", "takes/take-02.cuttr"],
			output: Output(width: 1920, height: 1080, framesPerSecond: 25, file: "out.mov"),
			timeline: [
				TimelineEntry(clip: ClipReference("take-01/intro")),
				TimelineEntry(clip: ClipReference("demo-install")),
			],
			overlays: [
				Overlay(kind: .text("Installing the driver", style: "lower-third"),
				        span: .clips(from: ClipReference("intro"), to: ClipReference("demo-install")),
				        arrival: .slide(.left, over: 0.4),
				        departure: .slide(.right, over: 0.4)),
				Overlay(kind: .spinner(Spinner(style: .dots, size: 0.09, speed: 1.5)),
				        span: .clips(from: ClipReference("intro"), to: ClipReference("intro")),
				        arrival: .fade(over: 0.25), departure: .fade(over: 0.25),
				        anchor: "mia-eye", offset: CGPoint(x: 0, y: -0.18)),
			])
	}

	@Test func roundTrips() throws {
		let back = try ProjectReader.read(ProjectWriter.write(sample()))
		#expect(back == sample())
	}

	@Test func writingIsStable() {
		#expect(ProjectWriter.write(sample()) == ProjectWriter.write(sample()))
	}

	@Test func readsWhatSomebodyWouldTypeByHand() throws {
		let project = try ProjectReader.read("""
		cuttr-project: 1
		takes: takes/take-01.cuttr
		output:
		  size: 3840x2160
		  fps: 30
		timeline:
		  - intro
		  - clip: demo-install
		overlays:
		  - text: Hello
		    from: intro
		    in: fade
		    out: right
		""")
		#expect(project.takes == ["takes/take-01.cuttr"])
		#expect(project.output.width == 3840)
		#expect(project.output.framesPerSecond == 30)
		// A bare string on the timeline is a clip, because a file of straight
		// cuts should be allowed to look like a list.
		#expect(project.timeline.map(\.source.description) == ["intro", "demo-install"])
		#expect(project.overlays.count == 1)
		// `from` with no `to` is one clip, not an error.
		#expect(project.overlays[0].span == .clips(from: ClipReference("intro"), to: ClipReference("intro")))
		#expect(project.overlays[0].arrival == .fade(over: 0.4))
		#expect(project.overlays[0].departure == .slide(.right, over: 0.4))
	}

	@Test func timesCanBeWrittenWhereClipsGo() throws {
		let project = try ProjectReader.read("""
		timeline: [intro]
		overlays:
		  - text: Chapter one
		    from: 00:05.000
		    to: 00:12.500
		""")
		#expect(project.overlays[0].span == .times(from: 5, to: 12.5))
	}

	@Test func stylesLayerOnTheBuiltInOfTheSameName() throws {
		let project = try ProjectReader.read("""
		timeline: [intro]
		styles:
		  lower-third:
		    size: 0.08
		""")
		let style = project.style(named: "lower-third")
		#expect(style.size == 0.08)
		// The other eight fields are the built-in's: overriding a style means
		// changing the line you care about, not restating all of them.
		#expect(style.font == TextStyle.lowerThird.font)
		#expect(style.position == TextStyle.lowerThird.position)
	}

	@Test func builtInStylesExistWithoutBeingWrittenDown() {
		let project = Project(timeline: [TimelineEntry(clip: ClipReference("a"))])
		#expect(project.style(named: "title").size == TextStyle.title.size)
		// Both spellings, because both get typed.
		#expect(project.style(named: "center") == project.style(named: "centre"))
		// An unknown name falls back rather than rendering nothing.
		#expect(project.style(named: "nonsense") == TextStyle.lowerThird)
	}

	@Test func coloursReadAndWriteAsHex() {
		#expect(RGBA(hex: "#ffffff") == .white)
		#expect(RGBA(hex: "f24c59")?.r ?? 0 > 0.9)
		#expect(RGBA(hex: "#00000080")?.a ?? 0 == Double(128) / 255)
		#expect(RGBA(hex: "nope") == nil)
		// Opaque colours lose the alpha, because `#ffffff` is what a person
		// writes and `#ffffffff` is what a program writes.
		#expect(RGBA.white.hex == "#ffffff")
	}

	@Test func anEmptyProjectIsAProject() throws {
		// A project is created before it has anything in it — that is what
		// creating one is for — so the format has to be able to hold nothing.
		// Whether there is anything to *render* is the resolver's question.
		#expect(try ProjectReader.read("").timeline.isEmpty)
		#expect(try ProjectReader.read("# just a comment\n").timeline.isEmpty)
		#expect(try ProjectReader.read("takes: [a.cuttr]\n").takes == ["a.cuttr"])
		#expect(try ProjectReader.read("timeline: []\n").timeline.isEmpty)
	}

	@Test func anEmptyProjectSurvivesBeingSavedAndOpened() throws {
		let empty = Project(output: Output(file: "out.mov"))
		let text = ProjectWriter.write(empty)
		let back = try ProjectReader.read(text)
		#expect(back.timeline.isEmpty)
		#expect(back.output.file == "out.mov")
		// And the file says where the clips go, so the next person to open it
		// in an editor has somewhere to type.
		#expect(text.contains("timeline:"))
	}

	@Test func aFutureVersionIsRefusedRatherThanMisread() {
		#expect(throws: ProjectError.self) {
			try ProjectReader.read("cuttr-project: 99\ntimeline: [a]\n")
		}
	}

	@Test func keysFromANewerVersionAreNotDeleted() throws {
		let project = try ProjectReader.read("cuttr-project: 1\ntimeline: [a]\nmusic: bed.wav\n")
		#expect(project.unknownKeys["music"] as? String == "bed.wav")
		#expect(ProjectWriter.write(project).contains("music: bed.wav"))
	}

	/// An overlay that comes back: three ranges, written as a list, read as a
	/// list, and unchanged by the round trip.
	@Test func severalRangesSurviveTheFile() throws {
		let overlay = Overlay(kind: .text("Still going", style: nil), spans: [
			.clips(from: ClipReference("intro"), to: ClipReference("demo-install")),
			.times(from: 12, to: 20.5),
			.marks(from: .group("outro"), to: .group("outro")),
		])
		let project = Project(
			takes: ["takes/take-01.cuttr"],
			timeline: [TimelineEntry(clip: ClipReference("intro"))],
			overlays: [overlay])

		let text = ProjectWriter.write(project)
		let back = try ProjectReader.read(text)
		#expect(back.overlays.first?.spans.count == 3)
		#expect(back.overlays == project.overlays)
		#expect(ProjectWriter.write(back) == text)
	}

	/// A spinner that comes back saying something else: one overlay, two
	/// appearances, each with its own words.
	@Test func whatItSaysAtEachAppearanceSurvivesTheFile() throws {
		let overlay = Overlay(
			kind: .spinner(Spinner(words: [SpinnerWord("Thinking")])),
			appearances: [
				.init(.times(from: 0, to: 8)),
				.init(.times(from: 10, to: 18), words: [SpinnerWord("Still thinking"),
				                                        SpinnerWord("Nearly", duration: 2)]),
			],
			anchor: "mia-eye")
		let project = Project(
			timeline: [TimelineEntry(clip: ClipReference("intro"))], overlays: [overlay])

		let text = ProjectWriter.write(project)
		let back = try ProjectReader.read(text)
		#expect(back.overlays == project.overlays)
		#expect(ProjectWriter.write(back) == text)

		// The first says the overlay's words, the second says its own.
		#expect(back.overlays[0].shown(at: back.overlays[0].appearances[0]).kind
			== .spinner(Spinner(words: [SpinnerWord("Thinking")])))
		if case .spinner(let spinner) = back.overlays[0]
			.shown(at: back.overlays[0].appearances[1]).kind {
			#expect(spinner.words.map(\.text) == ["Still thinking", "Nearly"])
			#expect(spinner.words[1].duration == 2)
		} else {
			Issue.record("the second appearance is not a spinner")
		}
	}

	/// A caption that says something else the second time it is on.
	@Test func aCaptionCanSaySomethingElseAtOneAppearance() throws {
		let overlay = Overlay(
			kind: .text("Installing", style: nil),
			appearances: [
				.init(.clips(from: ClipReference("intro"), to: ClipReference("intro"))),
				.init(.clips(from: ClipReference("outro"), to: ClipReference("outro")),
				      text: "Installed"),
			])
		let project = Project(
			timeline: [TimelineEntry(clip: ClipReference("intro"))], overlays: [overlay])
		let back = try ProjectReader.read(ProjectWriter.write(project))
		#expect(back.overlays == project.overlays)
		#expect(back.overlays[0].shown(at: back.overlays[0].appearances[1]).kind
			== .text("Installed", style: nil))
	}

	/// Every spinner there is, written and read back.
	///
	/// The list is the enum, so a style added without a line in the reader or a
	/// line in the writer fails here rather than in somebody's render.
	@Test func everySpinnerStyleSurvivesTheFile() throws {
		let project = Project(
			timeline: [TimelineEntry(clip: ClipReference("intro"))],
			overlays: Spinner.Style.allCases.map { style in
				Overlay(kind: .spinner(Spinner(style: style)),
				        span: .clips(from: ClipReference("intro"), to: ClipReference("intro")))
			})
		let back = try ProjectReader.read(ProjectWriter.write(project))
		#expect(back.overlays.count == Spinner.Style.allCases.count)
		for (overlay, style) in zip(back.overlays, Spinner.Style.allCases) {
			guard case .spinner(let spinner) = overlay.kind else {
				Issue.record("\(style) came back as something else")
				continue
			}
			#expect(spinner.style == style)
		}
	}

	/// A stretch of a clip, written and read back.
	@Test func aStretchOfAClipSurvivesTheFile() throws {
		let project = Project(
			timeline: [TimelineEntry(clip: ClipReference("intro"))],
			overlays: [
				Overlay(kind: .spinner(Spinner()),
				        span: .within(.clip(ClipReference("intro")), from: 2.5, to: 6)),
				Overlay(kind: .text("section", style: nil),
				        appearances: [
					        .init(.within(.group("middle"), from: 0, to: 4)),
					        .init(.within(.clip(ClipReference("outro")), from: 1, to: 2)),
				        ]),
			])
		let text = ProjectWriter.write(project)
		#expect(text.contains("within: intro"))
		let back = try ProjectReader.read(text)
		#expect(back.overlays == project.overlays)
		#expect(ProjectWriter.write(back) == text)
	}

	/// One range still writes the way it always did — a project nobody has
	/// touched must not come out rewritten.
	@Test func oneRangeIsStillWrittenInLine() {
		let text = ProjectWriter.write(sample())
		#expect(text.contains("    from:   intro\n"))
		#expect(!text.contains("when:"))
	}
}

/// A spinner that says things, which is the terminal idiom: the glyph turning
/// means "still going" and the words mean "going at this now".
@Suite struct SpinnerWordTests {

	@Test func wordsWithoutTimingsShareTheSpanEvenly() {
		let spinner = Spinner(words: [SpinnerWord("maybe green"),
		                              SpinnerWord("oh no yellow"),
		                              SpinnerWord("lets use green")])
		let schedule = spinner.schedule(over: 9)
		#expect(schedule.count == 3)
		#expect(schedule.allSatisfy { abs($0.duration - 3) < 1e-9 })
	}

	@Test func statedTimingsAreKeptAndTheRestShareWhatIsLeft() {
		let spinner = Spinner(words: [SpinnerWord("quick", duration: 1),
		                              SpinnerWord("slow", duration: 5),
		                              SpinnerWord("whatever")])
		let schedule = spinner.schedule(over: 10)
		#expect(schedule[0].duration == 1)
		#expect(schedule[1].duration == 5)
		#expect(abs(schedule[2].duration - 4) < 1e-9)
	}

	@Test func aWordNobodyCanReadIsNotWhatWasMeant() {
		// The stated durations already fill the span, so there is nothing to
		// share — and zero seconds is not an answer.
		let spinner = Spinner(words: [SpinnerWord("long", duration: 10), SpinnerWord("squeezed")])
		#expect(spinner.schedule(over: 10)[1].duration >= 0.4)
	}

	@Test func wordsRoundTripThroughTheFile() throws {
		let project = try ProjectReader.read("""
		timeline: [intro]
		overlays:
		  - spinner: dots
		    from: intro
		    anchor: mia-eye
		    offset: [0, -0.18]
		    words:
		      - maybe green
		      - {text: oh no yellow, for: 0.8}
		      - lets use green
		""")
		guard case .spinner(let spinner) = project.overlays[0].kind else {
			Issue.record("expected a spinner"); return
		}
		#expect(spinner.words.map(\.text) == ["maybe green", "oh no yellow", "lets use green"])
		#expect(spinner.words[1].duration == 0.8)
		#expect(spinner.words[0].duration == nil)

		let back = try ProjectReader.read(ProjectWriter.write(project))
		guard case .spinner(let again) = back.overlays[0].kind else {
			Issue.record("expected a spinner"); return
		}
		#expect(again.words == spinner.words)
	}
}

/// The panel teaches the format by showing what it is about to write, so the
/// fragments have to be the real thing rather than a rendering of it.
@Suite struct FragmentTests {

    @Test func aTimelineFragmentIsWhatTheFileWouldSay() throws {
        let entry = TimelineEntry(group: "introduction", entries: [
            TimelineEntry(clip: ClipReference("intro")),
            try TimelineEntry(query: "#b-roll"),
        ])
        let fragment = ProjectWriter.fragment(for: entry)
        #expect(fragment.contains("- group: introduction"))
        #expect(fragment.contains("- clip: intro"))
        // And it parses, which is the check that it is the format and not a
        // description of it.
        let back = try ProjectReader.read(fragment)
        #expect(back.rows.map(\.entry.source.description) == ["@introduction", "intro", "#b-roll"])
    }

    @Test func anOverlayFragmentParsesBack() throws {
        let overlay = Overlay(
            kind: .text("Installing the driver", style: "lower-third"),
            span: .clips(from: ClipReference("intro"), to: ClipReference("demo")),
            arrival: .slide(.left, over: 0.4), departure: .fade(over: 0.3))
        let back = try ProjectReader.read(
            "timeline: [intro]\n" + ProjectWriter.fragment(for: overlay))
        #expect(back.overlays.count == 1)
        #expect(back.overlays[0].arrival == .slide(.left, over: 0.4))
        #expect(back.overlays[0].departure == .fade(over: 0.3))
    }

    @Test func anOutputFragmentParsesBack() throws {
        let output = Output(width: 3840, height: 2160, framesPerSecond: 30,
                            file: "out.mov", audio: AudioTarget(target: -16, ceiling: -1),
                            matchReference: "intro")
        let back = try ProjectReader.read(
            ProjectWriter.fragment(for: output) + "timeline: [intro]\n")
        #expect(back.output.width == 3840)
        #expect(back.output.audio?.target == -16)
        #expect(back.output.matchReference == "intro")
    }

    @Test func fragmentsMatchTheWholeFile() {
        // If these ever drift, the panel is teaching a format the writer does
        // not produce.
        let project = Project(
            timeline: [TimelineEntry(clip: ClipReference("intro"))],
            overlays: [Overlay(kind: .text("Hello", style: nil),
                               span: .clips(from: ClipReference("intro"), to: ClipReference("intro")))])
        let whole = ProjectWriter.write(project)
        for line in ProjectWriter.fragment(for: project.timeline[0])
            .split(separator: "\n").dropFirst() {
            #expect(whole.contains(line), "\(line)")
        }
        for line in ProjectWriter.fragment(for: project.overlays[0])
            .split(separator: "\n").dropFirst() {
            #expect(whole.contains(line), "\(line)")
        }
    }

}
/// How one shot becomes the next, in the file.
///
/// The oldest spelling has to keep working and keep *writing* the same, or
/// every project in existence churns the first time it is opened by a version
/// that knows about wipes.
@Suite struct TransitionFileTests {

	@Test func aBareNumberIsStillADissolveAndStillWritesAsOne() throws {
		let text = """
		cuttr-project: 1
		timeline:
		  - clip: intro
		  - clip: demo
		    transition: 0.5
		"""
		let project = try ProjectReader.read(text)
		#expect(project.timeline[1].transition == .dissolve(over: 0.5))
		// Written back as the number it was: no churn in anybody's diff.
		let written = ProjectWriter.write(project)
		#expect(written.contains("transition: 0.5"))
		#expect(!written.contains("dissolve"))
	}

	@Test func everyKindSurvivesTheFile() throws {
		var project = Project(timeline: [TimelineEntry(clip: ClipReference("first"))])
		for kind in Transition.Kind.allCases where kind != .cut {
			project.timeline.append(TimelineEntry(
				clip: ClipReference("next-\(kind.rawValue)"),
				transition: Transition(kind, seconds: 0.6, edge: .down)))
		}
		let text = ProjectWriter.write(project)
		let back = try ProjectReader.read(text)
		#expect(back.timeline.count == project.timeline.count)
		for (mine, theirs) in zip(project.timeline, back.timeline) {
			#expect(mine.transition.kind == theirs.transition.kind)
			#expect(abs(mine.transition.duration - theirs.transition.duration) < 0.001)
			// The direction is only kept where it means something.
			if mine.transition.kind.directional {
				#expect(mine.transition.edge == theirs.transition.edge)
			}
		}
		// And saving what was read changes nothing.
		#expect(ProjectWriter.write(back) == text)
	}

	@Test func aKindCanBeNamedOnItsOwn() throws {
		let text = """
		cuttr-project: 1
		timeline:
		  - clip: intro
		  - clip: demo
		    transition: dip-to-black
		  - clip: outro
		    transition: {wipe: right, over: 0.8}
		"""
		let project = try ProjectReader.read(text)
		#expect(project.timeline[1].transition.kind == .dipToBlack)
		// A kind named alone gets a length that suits it: a dip has to sit on
		// the black for a moment to read as one.
		#expect(project.timeline[1].transition.duration == 1)
		#expect(project.timeline[2].transition == Transition(.wipe, seconds: 0.8, edge: .right))
	}

	/// A kind nobody knows is a mistake worth stopping on, not a silent cut.
	@Test func anUnknownKindIsRefused() {
		let text = """
		cuttr-project: 1
		timeline:
		  - clip: intro
		  - clip: demo
		    transition: starwipe
		"""
		#expect(throws: (any Error).self) { try ProjectReader.read(text) }
	}
}
