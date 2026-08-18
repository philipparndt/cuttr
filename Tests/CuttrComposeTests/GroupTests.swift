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

	@Test func anEmptySectionIsAnErrorRatherThanAZeroLengthSpan() throws {
		let directory = try fixture()
		defer { try? FileManager.default.removeItem(at: directory) }
		let project = try ProjectReader.read(header + "timeline:\n  - group: nothing\n    clips: []\n")
		#expect(throws: ResolveError.self) { try Resolver.resolve(project, baseURL: directory) }
	}

	@Test func aSectionNobodyDefinedIsNamed() throws {
		let directory = try fixture()
		defer { try? FileManager.default.removeItem(at: directory) }
		let project = try ProjectReader.read(header + """
		timeline: [one]
		overlays:
		  - text: Nowhere
		    group: missing
		""")
		#expect(throws: ResolveError.self) { try Resolver.resolve(project, baseURL: directory) }
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
