import CuttrKit
import Foundation
import Testing
@testable import CuttrCompose

/// Overlays written inside a timeline entry.
///
/// The case that made this necessary: a clip used twice is two placements, and
/// `from: intro` finds both of them. Naming each placement with `as:` and
/// hanging a caption on the name works, but it means inventing two names to say
/// something the file's own structure already knew. Written inside the entry,
/// the caption belongs to that entry and to nothing else.
@Suite struct NestedOverlayTests {

	private func fixture() throws -> URL {
		let directory = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("cuttr-nested-\(UUID().uuidString)")
		try FileManager.default.createDirectory(
			at: directory.appendingPathComponent("takes"), withIntermediateDirectories: true)
		try Data().write(to: directory.appendingPathComponent("a.mov"))
		let take = Take(video: "../a.mov", clips: [
			Clip(slug: "one", start: 0, end: 2),
			Clip(slug: "two", start: 2, end: 5),
			Clip(slug: "three", start: 5, end: 9),
		])
		try TakeWriter.write(take).write(
			to: directory.appendingPathComponent("takes/take-01.cuttr"),
			atomically: true, encoding: .utf8)
		return directory
	}

	private let header = "takes: [takes/take-01.cuttr]\n"

	// MARK: - The file

	@Test func anOverlayCanBeWrittenInsideAnEntry() throws {
		let project = try ProjectReader.read("""
		timeline:
		  - clip: one
		    overlays:
		      - text: Hello
		        in:   {fade: true, over: 0.4}
		  - group: build
		    clips: [two, three]
		    overlays:
		      - spinner: dots
		overlays:
		  - text: Chapter one
		    from: 00:10.000
		    to:   00:14.000
		""")
		#expect(project.timeline[0].overlays.count == 1)
		#expect(project.timeline[0].overlays[0].kind == .text("Hello", style: nil))
		#expect(project.timeline[0].overlays[0].arrival == .fade(over: 0.4))
		#expect(project.timeline[1].overlays.count == 1)
		// No range of its own: it covers what the entry lays down, and having
		// nothing to say about when it is on is how it says that.
		#expect(project.timeline[0].overlays[0].appearances.isEmpty)
		// The top-level list is untouched and still means what it meant.
		#expect(project.overlays.count == 1)
		#expect(project.overlays[0].span == .times(from: 10, to: 14))
	}

	@Test func aNestedOverlayRoundTrips() throws {
		let project = try ProjectReader.read("""
		timeline:
		  - clip: one
		    as:   opening
		    overlays:
		      - text:  Hello
		        style: title
		  - group: build
		    clips: [two, three]
		    overlays:
		      - spinner: ring
		        from: two
		        to:   three
		      - effect: confetti
		""")
		let written = ProjectWriter.write(project)
		let back = try ProjectReader.read(written)
		#expect(back == project)
		#expect(ProjectWriter.write(back) == written)
	}

	@Test func aProjectWithNoNestedOverlaysIsUnchanged() throws {
		// The rule the whole format lives by: the emitter must not move a byte
		// of a file it has nothing new to say about.
		let text = """
		# cuttr project — the assembly. Clips are referenced by slug.
		cuttr-project: 1

		takes:
		  - takes/take-01.cuttr

		output:
		  size: 1920x1080
		  fps:  25

		timeline:
		  - clip: one
		  - group: build
		    clips:
		      - clip: two
		      - clip: three

		overlays:
		  - text:   Chapter one
		    from:   00:00.000
		    to:     00:04.000
		    in:     {slide: left, over: 0.4}
		    out:    {slide: right, over: 0.4}

		"""
		let project = try ProjectReader.read(text)
		#expect(ProjectWriter.write(project) == text)
	}

	@Test func aNestedOverlayIsWrittenInsideItsEntry() throws {
		let project = Project(
			timeline: [TimelineEntry(
				clip: ClipReference("one"),
				overlays: [Overlay(kind: .text("Hello", style: nil), appearances: [],
				                   arrival: .cut, departure: .cut)])])
		let written = ProjectWriter.write(project)
		#expect(written.contains("""
		  - clip: one
		    overlays:
		      - text:   Hello
		        in:     cut
		        out:    cut
		"""))
		// And nothing appeared in the top-level list on the way out.
		#expect(!written.contains("\noverlays:\n"))
	}

	// MARK: - The clock

	@Test func aNestedOverlayCoversItsPlacementExactly() throws {
		let directory = try fixture()
		defer { try? FileManager.default.removeItem(at: directory) }
		let project = try ProjectReader.read(header + """
		timeline:
		  - clip: one
		  - clip: two
		    overlays:
		      - text: On the second
		""")
		let resolved = try Resolver.resolve(project, baseURL: directory)
		#expect(resolved.overlays.count == 1)
		// two runs 2–5 on the take, and it is second on the programme, so it is
		// at 2–5 there too.
		#expect(resolved.overlays[0].start == 2)
		#expect(resolved.overlays[0].end == 5)
	}

	@Test func aNestedOverlayOnASectionCoversTheWholeSection() throws {
		let directory = try fixture()
		defer { try? FileManager.default.removeItem(at: directory) }
		let project = try ProjectReader.read(header + """
		timeline:
		  - clip: one
		  - group: build
		    clips: [two, three]
		    overlays:
		      - spinner: dots
		""")
		let resolved = try Resolver.resolve(project, baseURL: directory)
		#expect(resolved.overlays.count == 1)
		#expect(resolved.overlays[0].start == 2)
		#expect(resolved.overlays[0].end == 9)
	}

	@Test func theSameClipTwiceGetsTheOverlayItWasGiven() throws {
		let directory = try fixture()
		defer { try? FileManager.default.removeItem(at: directory) }
		// The case a name cannot express. `from: one` would find both.
		let project = try ProjectReader.read(header + """
		timeline:
		  - clip: one
		    overlays:
		      - text: First time
		  - clip: two
		  - clip: one
		    overlays:
		      - text: Second time
		""")
		let resolved = try Resolver.resolve(project, baseURL: directory)
		#expect(resolved.overlays.count == 2)
		let first = try #require(resolved.overlays.first {
			$0.overlay.kind == .text("First time", style: nil)
		})
		let second = try #require(resolved.overlays.first {
			$0.overlay.kind == .text("Second time", style: nil)
		})
		// one is 0–2, then two is 2–5, then one again is 5–7.
		#expect((first.start, first.end) == (0, 2))
		#expect((second.start, second.end) == (5, 7))
	}

	@Test func aNestedOverlayThatWritesASpanKeepsIt() throws {
		let directory = try fixture()
		defer { try? FileManager.default.removeItem(at: directory) }
		let project = try ProjectReader.read(header + """
		timeline:
		  - clip: one
		  - group: build
		    clips: [two, three]
		    overlays:
		      - text:   A stretch of the third
		        within: three
		        from:   00:01.000
		        to:     00:02.000
		      - text: On the clock
		        from: 00:00.500
		        to:   00:01.500
		""")
		let resolved = try Resolver.resolve(project, baseURL: directory)
		#expect(resolved.overlays.count == 2)
		// three sits at 5–9 on the programme, so one second into it is 6.
		#expect((resolved.overlays[0].start, resolved.overlays[0].end) == (6, 7))
		// And `from:`/`to:` on the programme's own clock still means that,
		// wherever the overlay happens to be filed.
		#expect((resolved.overlays[1].start, resolved.overlays[1].end) == (0.5, 1.5))
	}

	@Test func aNestedOverlayKnowsWhereItWasWritten() throws {
		let directory = try fixture()
		defer { try? FileManager.default.removeItem(at: directory) }
		let project = try ProjectReader.read(header + """
		timeline:
		  - clip: one
		  - group: build
		    clips: [two, three]
		    overlays:
		      - spinner: dots
		  - clip: three
		    overlays:
		      - text: A
		      - text: B
		overlays:
		  - text: Loose
		    from: 00:00.000
		    to:   00:01.000
		""")
		let resolved = try Resolver.resolve(project, baseURL: directory)
		#expect(resolved.overlays.map(\.origin) == [
			.entry(path: [1], index: 0),
			.entry(path: [2], index: 0),
			.entry(path: [2], index: 1),
			.project(0),
		])
		// And the address finds the overlay again in the file it came from.
		for shown in resolved.overlays {
			#expect(project.overlay(at: shown.origin)?.kind == shown.overlay.kind)
		}
	}

	@Test func aNestedOverlayOnAnEmptySectionIsSaidRatherThanThrown() throws {
		let directory = try fixture()
		defer { try? FileManager.default.removeItem(at: directory) }
		let project = try ProjectReader.read(header + """
		timeline:
		  - clip: one
		  - group: unfinished
		    clips: []
		    overlays:
		      - text: Not yet
		""")
		let resolved = try Resolver.resolve(project, baseURL: directory)
		#expect(resolved.overlays.isEmpty)
		#expect(resolved.warnings.count == 2)
	}

	@Test func editingReachesAnOverlayWhereverItIsWritten() throws {
		var project = try ProjectReader.read("""
		timeline:
		  - group: build
		    clips:
		      - clip: two
		        overlays:
		          - text: Inside
		""")
		project.editOverlay(at: .entry(path: [0, 0], index: 0)) {
			$0.kind = .text("Changed", style: nil)
		}
		#expect(project.overlay(at: .entry(path: [0, 0], index: 0))?.kind
			== .text("Changed", style: nil))
		// Editing something inside a section used to rebuild the section from
		// its name and its transition, which dropped everything else it held.
		guard case .group(let name, let inner) = project.timeline[0].source else {
			Issue.record("the section went missing")
			return
		}
		#expect(name == "build")
		#expect(inner.count == 1)
	}
}
