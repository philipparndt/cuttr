import CuttrKit
import Foundation
import Testing
@testable import CuttrCompose

/// An overlay written inside a clip but pinned to the programme's clock.
///
/// The one way an overlay can be quietly wrong. Written inside a clip with no
/// range it covers that clip and follows it through every re-cut; written inside
/// a clip with `from:`/`to:` it is pinned to the programme, so the moment
/// anything upstream changes length the clip moves and the overlay does not.
///
/// Found on a real project: three spinners five seconds early, playing over the
/// shot before the one they were written on, and nothing anywhere said so. The
/// file was intact and round-tripped byte for byte — which is exactly why it was
/// so hard to see.
@Suite struct DriftedOverlayTests {

	private func project(_ overlayTimes: String, extra: String = "") throws -> Project {
		try ProjectReader.read("""
			timeline:
			  - {card: 00:05.000, fill: "#101010"}\(extra)
			  - card:  00:05.000
			    fill:  "#202020"
			    overlays:
			      - spinner: bars
			        words: [""]
			\(overlayTimes)
			""")
	}

	private func resolve(_ project: Project) throws -> ResolvedProject {
		try Resolver.resolve(project, baseURL: URL(fileURLWithPath: NSTemporaryDirectory()))
	}

	/// Times that sit on the entry are not a problem and say nothing.
	@Test func timesThatStillTouchTheirEntryAreQuiet() throws {
		let resolved = try resolve(try project("""
			        from:   00:06.000
			        to:     00:08.000
			"""))
		#expect(resolved.warnings.isEmpty)
		#expect(resolved.overlays.count == 1)
	}

	/// The real case: a shot inserted above it pushed the entry along and the
	/// times stayed where they were.
	@Test func timesThatHaveDriftedOffTheirEntryAreSaidOutLoud() throws {
		let drifted = try project("""
			        from:   00:06.000
			        to:     00:08.000
			""", extra: "\n  - {card: 00:05.000, fill: \"#303030\"}")
		let resolved = try resolve(drifted)
		#expect(resolved.warnings.count == 1)
		#expect(resolved.warnings.first?.contains("pinned to programme times") == true)
		// And it names the spelling that would have survived.
		#expect(resolved.warnings.first?.contains("within:") == true)
		// It is still on the programme — this says so, it does not delete it.
		#expect(resolved.overlays.count == 1)
	}

	/// An overlay with no range at all covers its entry and follows it, which is
	/// why the five spinners written that way on the real project were still
	/// exactly right.
	@Test func noRangeMeansItFollowsTheClip() throws {
		let project = try ProjectReader.read("""
			timeline:
			  - {card: 00:05.000, fill: "#101010"}
			  - card:  00:05.000
			    fill:  "#202020"
			    overlays:
			      - spinner: bars
			        words: [""]
			""")
		let resolved = try resolve(project)
		#expect(resolved.warnings.isEmpty)
		#expect(resolved.overlays.first?.start == 5)
		#expect(resolved.overlays.first?.end == 10)
	}

	/// A top-level overlay is *supposed* to be on the programme's clock, so it
	/// is never warned about.
	@Test func aTopLevelOverlayIsNotWarnedAbout() throws {
		let project = try ProjectReader.read("""
			timeline:
			  - {card: 00:05.000, fill: "#101010"}
			overlays:
			  - spinner: bars
			    words: [""]
			    from:  00:01.000
			    to:    00:02.000
			""")
		#expect(try resolve(project).warnings.isEmpty)
	}
}

/// What to write for an overlay that lives inside a clip, so the next re-cut
/// does not leave it behind.
@Suite struct SpanInsideTests {

	private func fixture() throws -> (URL, ResolvedProject, Project) {
		let directory = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("cuttr-inside-\(UUID().uuidString)")
		try FileManager.default.createDirectory(
			at: directory.appendingPathComponent("takes"), withIntermediateDirectories: true)
		try Data().write(to: directory.appendingPathComponent("a.mov"))
		try TakeWriter.write(Take(video: "../a.mov", clips: [
			Clip(slug: "one", start: 0, end: 5),
			Clip(slug: "two", start: 5, end: 12),
		])).write(to: directory.appendingPathComponent("takes/t.cuttr"),
		          atomically: true, encoding: .utf8)
		let project = try ProjectReader.read("""
			takes: [takes/t.cuttr]
			timeline: [one, two]
			""")
		return (directory, try Resolver.resolve(project, baseURL: directory), project)
	}

	/// The drag is written against the clip, so the numbers are offsets into it
	/// rather than places on the programme.
	@Test func aDragInsideAClipIsWrittenAgainstThatClip() throws {
		let (directory, resolved, project) = try fixture()
		defer { try? FileManager.default.removeItem(at: directory) }
		// The second shot runs 5–12. Dragged to 6–8, that is one to three
		// seconds into it.
		let span = Overlay.Span.inside(project.timeline[1], start: 6, end: 8, in: resolved)
		#expect(span == .within(.clip(ClipReference("two")), from: 1, to: 3))
	}

	/// And it cannot be dragged outside the clip it is inside, which is the
	/// other half of not drifting.
	@Test func itCannotBeDraggedPastTheClipItIsIn() throws {
		let (directory, resolved, project) = try fixture()
		defer { try? FileManager.default.removeItem(at: directory) }
		let span = Overlay.Span.inside(project.timeline[1], start: 6, end: 40, in: resolved)
		#expect(span == .within(.clip(ClipReference("two")), from: 1, to: 7))
	}

	/// The point of it: written this way, a shot inserted above does not leave
	/// the overlay behind.
	@Test func itSurvivesAShotInsertedAboveIt() throws {
		let (directory, resolved, read) = try fixture()
		var project = read
		defer { try? FileManager.default.removeItem(at: directory) }
		guard let span = Overlay.Span.inside(project.timeline[1], start: 6, end: 8, in: resolved)
		else { Issue.record("no span"); return }
		project.timeline[1].overlays = [Overlay(
			kind: .text("on it", style: nil), span: span)]

		// On the programme as written: one to three seconds into the second shot.
		let before = try Resolver.resolve(project, baseURL: directory)
		#expect(before.overlays.first?.start == 6)

		// Now push everything along by putting a card at the top.
		project.timeline.insert(TimelineEntry(source: .card(Card(duration: 4))), at: 0)
		let after = try Resolver.resolve(project, baseURL: directory)
		#expect(after.overlays.first?.start == 10)
		#expect(after.warnings.isEmpty)

		// Where programme times would have stayed at six and drifted off it.
		var pinned = project
		pinned.timeline[2].overlays = [Overlay(
			kind: .text("on it", style: nil), span: .times(from: 6, to: 8))]
		let drifted = try Resolver.resolve(pinned, baseURL: directory)
		#expect(drifted.overlays.first?.start == 6)
		#expect(drifted.warnings.count == 1)
	}

	/// A card has no clip to be relative to, so there is nothing to write and
	/// the caller's own arithmetic stands.
	@Test func aCardHasNothingToBeRelativeTo() throws {
		let (directory, resolved, _) = try fixture()
		defer { try? FileManager.default.removeItem(at: directory) }
		let card = TimelineEntry(source: .card(Card(duration: 3)))
		#expect(Overlay.Span.inside(card, start: 1, end: 2, in: resolved) == nil)
	}
}
