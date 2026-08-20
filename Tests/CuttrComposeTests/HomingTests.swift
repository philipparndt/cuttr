import CuttrKit
import Foundation
import Testing
@testable import CuttrCompose

/// Dragging an overlay from one place in the file to another.
///
/// The rule worth holding still is the one about coming *out*: nothing about
/// dropping a caption on the heading for the loose ones says it should move on
/// the programme, so it must not. Everything here measures that the way the
/// programme measures it — by resolving before and after and comparing the
/// times, rather than by reading the span back and hoping it means the same.
@Suite struct OverlayHomingTests {

	private func fixture() throws -> URL {
		let directory = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("cuttr-homing-\(UUID().uuidString)")
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

	/// When each overlay is on, keyed by what it says — which is the only thing
	/// about it that a move must not change.
	private func times(_ project: Project, _ directory: URL) throws -> [String: [String]] {
		let resolved = try Resolver.resolve(project, baseURL: directory)
		var out: [String: [String]] = [:]
		for shown in resolved.overlays {
			out[shown.overlay.described, default: []]
				.append(String(format: "%.3f–%.3f", shown.start, shown.end))
		}
		return out
	}

	// MARK: - Out to the top level

	@Test func unNestingOntoTheRootKeepsTheTimesAndUsesTheName() throws {
		let directory = try fixture()
		defer { try? FileManager.default.removeItem(at: directory) }
		var project = try ProjectReader.read(header + """
		timeline:
		  - clip: one
		  - group: build
		    clips: [two, three]
		    overlays:
		      - text: On the section
		""")
		let before = try times(project, directory)
		let resolved = try Resolver.resolve(project, baseURL: directory)
		project.moveOverlay(at: .entry(path: [1], index: 0), into: nil, in: resolved)

		#expect(project.timeline[1].overlays.isEmpty)
		#expect(project.overlays.count == 1)
		// A section has a name, and a name is what survives a re-cut — so that
		// is what it is written as rather than the times it happens to be at.
		#expect(project.overlays[0].span == .marks(from: .group("build"), to: .group("build")))
		#expect(try times(project, directory) == before)
	}

	@Test func unNestingFromALabelledPlacementUsesTheLabel() throws {
		let directory = try fixture()
		defer { try? FileManager.default.removeItem(at: directory) }
		var project = try ProjectReader.read(header + """
		timeline:
		  - clip: one
		  - clip: two
		    as:   middle
		    overlays:
		      - text: On the middle
		""")
		let before = try times(project, directory)
		let resolved = try Resolver.resolve(project, baseURL: directory)
		project.moveOverlay(at: .entry(path: [1], index: 0), into: nil, in: resolved)
		#expect(project.overlays[0].span == .marks(from: .group("middle"), to: .group("middle")))
		#expect(try times(project, directory) == before)
	}

	@Test func unNestingFromAClipUsedOnceUsesItsSlug() throws {
		let directory = try fixture()
		defer { try? FileManager.default.removeItem(at: directory) }
		var project = try ProjectReader.read(header + """
		timeline:
		  - clip: one
		  - clip: two
		    overlays:
		      - text: On the second
		""")
		let before = try times(project, directory)
		let resolved = try Resolver.resolve(project, baseURL: directory)
		project.moveOverlay(at: .entry(path: [1], index: 0), into: nil, in: resolved)
		#expect(project.overlays[0].span
			== .marks(from: .clip(ClipReference("two")), to: .clip(ClipReference("two"))))
		#expect(try times(project, directory) == before)
	}

	/// The case the name cannot survive. `from: one` finds both uses, so
	/// naming the clip would widen the caption from two seconds to seven.
	@Test func unNestingFromAClipUsedTwiceFallsBackToTimes() throws {
		let directory = try fixture()
		defer { try? FileManager.default.removeItem(at: directory) }
		var project = try ProjectReader.read(header + """
		timeline:
		  - clip: one
		  - clip: two
		  - clip: one
		    overlays:
		      - text: The second time
		""")
		let before = try times(project, directory)
		let resolved = try Resolver.resolve(project, baseURL: directory)
		project.moveOverlay(at: .entry(path: [2], index: 0), into: nil, in: resolved)
		#expect(project.overlays[0].span == .times(from: 5, to: 7))
		#expect(try times(project, directory) == before)
	}

	@Test func unNestingFromACardWithNoNameFallsBackToTimes() throws {
		let directory = try fixture()
		defer { try? FileManager.default.removeItem(at: directory) }
		var project = try ProjectReader.read(header + """
		timeline:
		  - clip: one
		  - card: 00:03.000
		    overlays:
		      - text: On the card
		""")
		let before = try times(project, directory)
		let resolved = try Resolver.resolve(project, baseURL: directory)
		project.moveOverlay(at: .entry(path: [1], index: 0), into: nil, in: resolved)
		#expect(project.overlays[0].span == .times(from: 2, to: 5))
		#expect(try times(project, directory) == before)
	}

	@Test func anOverlayThatAlreadySaysWhenItIsOnKeepsSayingIt() throws {
		let directory = try fixture()
		defer { try? FileManager.default.removeItem(at: directory) }
		var project = try ProjectReader.read(header + """
		timeline:
		  - clip: one
		  - group: build
		    clips: [two, three]
		    overlays:
		      - text:   A stretch
		        within: three
		        from:   00:01.000
		        to:     00:02.000
		""")
		let before = try times(project, directory)
		let resolved = try Resolver.resolve(project, baseURL: directory)
		project.moveOverlay(at: .entry(path: [1], index: 0), into: nil, in: resolved)
		#expect(project.overlays[0].span
			== .within(.clip(ClipReference("three")), from: 1, to: 2))
		#expect(try times(project, directory) == before)
	}

	// MARK: - Into an entry

	@Test func droppingOnAnEntryConstrainsItToThatEntry() throws {
		let directory = try fixture()
		defer { try? FileManager.default.removeItem(at: directory) }
		var project = try ProjectReader.read(header + """
		timeline:
		  - clip: one
		  - clip: two
		overlays:
		  - text: Anywhere
		    from: 00:00.000
		    to:   00:09.000
		""")
		let resolved = try Resolver.resolve(project, baseURL: directory)
		project.moveOverlay(at: .project(0), into: [1], in: resolved)

		#expect(project.overlays.isEmpty)
		#expect(project.timeline[1].overlays.count == 1)
		// It covers the placement now, and says so by having nothing to say.
		#expect(project.timeline[1].overlays[0].appearances.isEmpty)
		let after = try Resolver.resolve(project, baseURL: directory)
		#expect(after.overlays.count == 1)
		#expect((after.overlays[0].start, after.overlays[0].end) == (2, 5))
	}

	@Test func draggingBetweenTwoEntriesFollowsThePointer() throws {
		let directory = try fixture()
		defer { try? FileManager.default.removeItem(at: directory) }
		var project = try ProjectReader.read(header + """
		timeline:
		  - clip: one
		    overlays:
		      - text: Moving
		  - clip: two
		""")
		let resolved = try Resolver.resolve(project, baseURL: directory)
		let landed = project.moveOverlay(at: .entry(path: [0], index: 0), into: [1], in: resolved)
		#expect(landed == .entry(path: [1], index: 0))
		#expect(project.timeline[0].overlays.isEmpty)
		let after = try Resolver.resolve(project, baseURL: directory)
		#expect((after.overlays[0].start, after.overlays[0].end) == (2, 5))
	}

	@Test func droppingOnASectionCoversTheWholeSection() throws {
		let directory = try fixture()
		defer { try? FileManager.default.removeItem(at: directory) }
		var project = try ProjectReader.read(header + """
		timeline:
		  - clip: one
		    overlays:
		      - text: Moving
		  - group: build
		    clips: [two, three]
		""")
		let resolved = try Resolver.resolve(project, baseURL: directory)
		project.moveOverlay(at: .entry(path: [0], index: 0), into: [1], in: resolved)
		let after = try Resolver.resolve(project, baseURL: directory)
		#expect((after.overlays[0].start, after.overlays[0].end) == (2, 9))
	}

	@Test func movingItWhereItAlreadyIsChangesNothing() throws {
		let directory = try fixture()
		defer { try? FileManager.default.removeItem(at: directory) }
		var project = try ProjectReader.read(header + """
		timeline:
		  - clip: one
		    overlays:
		      - text:   A stretch
		        within: one
		        from:   00:00.500
		        to:     00:01.000
		""")
		let was = project
		let resolved = try Resolver.resolve(project, baseURL: directory)
		project.moveOverlay(at: .entry(path: [0], index: 0), into: [0], in: resolved)
		#expect(project == was)
	}

	// MARK: - Adding one where it will live

	@Test func aNewOverlayCanBeMadeInsideAnEntry() throws {
		var project = try ProjectReader.read("""
		timeline:
		  - group: build
		    clips: [two, three]
		""")
		let landed = project.addOverlay(
			Overlay(kind: .text("New", style: nil), appearances: []), into: [0])
		#expect(landed == .entry(path: [0], index: 0))
		#expect(project.timeline[0].overlays.count == 1)
		// And one made at the root goes where the top-level list is.
		#expect(project.addOverlay(
			Overlay(kind: .text("Loose", style: nil), span: .times(from: 0, to: 1)), into: nil)
			== .project(0))
	}
}
