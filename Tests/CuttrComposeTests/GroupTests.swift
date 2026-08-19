import CuttrKit
import Foundation
import Testing
@testable import CuttrCompose

/// Sections of a programme, and overlays hung on them.
///
/// The reason groups exist: `from: intro to: demo` is right until somebody adds
/// a third shot to the introduction, and then the caption stops half-way through
/// a section it was meant to cover. `from: @introduction` cannot go wrong that
/// way, because it names the section rather than its current first and last shot.
@Suite struct GroupTests {

	private func fixture() throws -> URL {
		let directory = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("cuttr-groups-\(UUID().uuidString)")
		try FileManager.default.createDirectory(
			at: directory.appendingPathComponent("takes"), withIntermediateDirectories: true)
		try Data().write(to: directory.appendingPathComponent("a.mov"))
		let take = Take(video: "../a.mov", clips: [
			Clip(slug: "one", start: 0, end: 2),
			Clip(slug: "two", start: 2, end: 5),
			Clip(slug: "three", start: 5, end: 9),
			Clip(slug: "four", start: 9, end: 10),
		])
		try TakeWriter.write(take).write(
			to: directory.appendingPathComponent("takes/take-01.cuttr"),
			atomically: true, encoding: .utf8)
		return directory
	}

	private let header = "takes: [takes/take-01.cuttr]\n"

	@Test func aGroupIsFlattenedInOrder() throws {
		let directory = try fixture()
		defer { try? FileManager.default.removeItem(at: directory) }
		let project = try ProjectReader.read(header + """
		timeline:
		  - group: introduction
		    clips:
		      - one
		      - two
		  - group: the-build
		    clips:
		      - three
		      - four
		""")
		let resolved = try Resolver.resolve(project, baseURL: directory)
		#expect(resolved.clips.map(\.reference.slug) == ["one", "two", "three", "four"])
		#expect(resolved.duration == 10)
	}

	@Test func anOverlayCanBeHungOnASection() throws {
		let directory = try fixture()
		defer { try? FileManager.default.removeItem(at: directory) }
		let project = try ProjectReader.read(header + """
		timeline:
		  - group: introduction
		    clips: [one, two]
		  - group: the-build
		    clips: [three, four]
		overlays:
		  - text: Introduction
		    group: introduction
		  - text: The build
		    from: "@the-build"
		""")
		let resolved = try Resolver.resolve(project, baseURL: directory)
		// one is 0–2 and two is 2–5, so the section is 0–5 — and it stays 0–5
		// whatever the shots inside it are called.
		#expect(resolved.overlays[0].start == 0)
		#expect(resolved.overlays[0].end == 5)
		#expect(resolved.overlays[1].start == 5)
		#expect(resolved.overlays[1].end == 10)
	}

	@Test func aSpanCanRunFromOneSectionToAnother() throws {
		let directory = try fixture()
		defer { try? FileManager.default.removeItem(at: directory) }
		let project = try ProjectReader.read(header + """
		timeline:
		  - group: a
		    clips: [one]
		  - group: b
		    clips: [two]
		  - group: c
		    clips: [three]
		overlays:
		  - text: Across
		    from: "@a"
		    to: "@b"
		""")
		let resolved = try Resolver.resolve(project, baseURL: directory)
		#expect(resolved.overlays[0].start == 0)
		#expect(resolved.overlays[0].end == 5)
	}

	@Test func groupsNest() throws {
		let directory = try fixture()
		defer { try? FileManager.default.removeItem(at: directory) }
		let project = try ProjectReader.read(header + """
		timeline:
		  - group: outer
		    clips:
		      - one
		      - group: inner
		        clips: [two, three]
		      - four
		""")
		let resolved = try Resolver.resolve(project, baseURL: directory)
		#expect(resolved.clips.count == 4)
		let inner = try ProjectReader.read(header + """
		timeline:
		  - group: outer
		    clips:
		      - one
		      - group: inner
		        clips: [two, three]
		      - four
		overlays:
		  - text: Inner
		    group: inner
		  - text: Outer
		    group: outer
		""")
		let both = try Resolver.resolve(inner, baseURL: directory)
		#expect((both.overlays[0].start, both.overlays[0].end) == (2, 9))
		#expect((both.overlays[1].start, both.overlays[1].end) == (0, 10))
	}

	/// This used to throw, and the reasoning was that a zero-length section is
	/// not a section. It is, though — it is a section somebody has just made and
	/// has not filled yet, and refusing the whole programme for it leaves an
	/// empty preview and a greyed render button while they work. Skipped, and
	/// said out loud.
	@Test func anEmptySectionIsSkippedRatherThanRefused() throws {
		let directory = try fixture()
		defer { try? FileManager.default.removeItem(at: directory) }
		let project = try ProjectReader.read(
			header + "timeline:\n  - one\n  - group: nothing\n    clips: []\n")
		let resolved = try Resolver.resolve(project, baseURL: directory)
		#expect(resolved.clips.count == 1)
		#expect(resolved.groups.contains { $0.name == "nothing" } == false)
		#expect(resolved.warnings.contains { $0.contains("@nothing") })
	}

	/// The same for an overlay pointing at a section that is not there: it comes
	/// off the programme, and the programme stays.
	@Test func aSectionNobodyDefinedIsNamed() throws {
		let directory = try fixture()
		defer { try? FileManager.default.removeItem(at: directory) }
		let project = try ProjectReader.read(header + """
		timeline: [one]
		overlays:
		  - text: Nowhere
		    group: missing
		""")
		let resolved = try Resolver.resolve(project, baseURL: directory)
		#expect(resolved.overlays.isEmpty)
		#expect(resolved.clips.count == 1)
		#expect(resolved.warnings.contains { $0.contains("@missing") && $0.contains("Nowhere") })
	}

	@Test func groupsRoundTripThroughTheFile() throws {
		let project = try ProjectReader.read("""
		timeline:
		  - group: introduction
		    clips:
		      - one
		      - query: "#b-roll"
		      - group: aside
		        clips: [two]
		overlays:
		  - text: Hello
		    from: "@introduction"
		""")
		let text = ProjectWriter.write(project)
		#expect(text.contains("- group: introduction"))
		#expect(text.contains("from:   \"@introduction\""))
		let back = try ProjectReader.read(text)
		#expect(back.timeline == project.timeline)
		#expect(back.overlays == project.overlays)
	}
}

/// A section somebody has made and not yet filled.
///
/// Half-built is the normal state of a project being worked on, and refusing to
/// resolve any of it leaves an empty preview and a greyed render button — a
/// hard way to be told that a section you are still building is still empty.
@Suite struct EmptySectionTests {

	private func resolve(_ project: Project) throws -> ResolvedProject {
		try Resolver.resolve(project, baseURL: URL(fileURLWithPath: NSTemporaryDirectory()))
	}

	private func programme(_ extra: [TimelineEntry] = []) -> Project {
		var project = Project(timeline: [
			TimelineEntry(group: "nothing", entries: []),
			TimelineEntry(source: .card(Card(duration: 2)), label: "something"),
		] + extra)
		project.scenes = [:]
		return project
	}

    @Test func anEmptySectionIsSkippedAndSaidSo() throws {
		let resolved = try resolve(programme())
		#expect(resolved.duration == 2)
		#expect(resolved.cards.count == 1)
		// Not registered as a section, because there is nothing there to hang on.
		#expect(resolved.groups.contains { $0.name == "nothing" } == false)
		#expect(resolved.warnings.count == 1)
		#expect(resolved.warnings[0].contains("@nothing"))
	}

	/// And an overlay hung on one comes off the programme rather than taking
	/// the programme with it.
	@Test func anOverlayOnAnEmptySectionIsDroppedNotFatal() throws {
		var project = programme()
		project.overlays = [
			Overlay(kind: .text("on nothing", style: nil),
			        span: .marks(from: .group("nothing"), to: .group("nothing"))),
			Overlay(kind: .text("on something", style: nil),
			        span: .marks(from: .group("something"), to: .group("something"))),
		]
		let resolved = try resolve(project)
		#expect(resolved.overlays.count == 1)
		#expect(resolved.overlays.first?.overlay.described.contains("on something") == true)
		#expect(resolved.warnings.count == 2)
		#expect(resolved.warnings.contains { $0.contains("on nothing") })
	}

	/// A section with something in it is untouched by any of this.
	@Test func aFullSectionStillResolves() throws {
		var project = Project(timeline: [
			TimelineEntry(group: "intro", entries: [
				TimelineEntry(source: .card(Card(duration: 1.5)), label: "card"),
			]),
		])
		project.overlays = [
			Overlay(kind: .text("hello", style: nil),
			        span: .marks(from: .group("intro"), to: .group("intro"))),
		]
		let resolved = try resolve(project)
		#expect(resolved.warnings.isEmpty)
		#expect(resolved.overlays.count == 1)
		#expect(resolved.groups.first?.name == "intro")
	}
}
