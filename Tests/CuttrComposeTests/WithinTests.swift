import CuttrKit
import CoreGraphics
import Foundation
import Testing
@testable import CuttrCompose

/// An overlay written inside a clip, on for only part of it.
@Suite struct WithinTests {

	/// Real files, because a span written `within:` a clip is resolved by
	/// finding that clip on the timeline.
	private func fixture(_ lead: Double = 4) throws -> URL {
		let directory = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("cuttr-within-\(UUID().uuidString)")
		try FileManager.default.createDirectory(
			at: directory.appendingPathComponent("takes"), withIntermediateDirectories: true)
		try Data().write(to: directory.appendingPathComponent("a.mov"))
		let take = Take(video: "../a.mov", clips: [
			Clip(slug: "opening", start: 0, end: lead, tags: ["a-roll"]),
			Clip(slug: "middle", start: 10, end: 20, tags: ["a-roll"]),
		])
		try TakeWriter.write(take).write(
			to: directory.appendingPathComponent("takes/take-01.cuttr"),
			atomically: true, encoding: .utf8)
		return directory
	}

	private func programme(_ overlayText: String, lead: Double = 4) throws -> ResolvedProject {
		let directory = try fixture(lead)
		defer { try? FileManager.default.removeItem(at: directory) }
		let project = try ProjectReader.read("""
		takes:
		  - takes/take-01.cuttr

		output:
		  size: 1920x1080
		  fps:  25
		  file: out.mov

		timeline:
		  - clip: opening
		  - clip: middle
		\(overlayText)
		""")
		return try Resolver.resolve(project, baseURL: directory)
	}

	/// Written inside an entry with no range, it covers the whole of it.
	@Test func noRangeCoversTheWholeEntry() throws {
		let work = try programme("""
		    overlays:
		      - effect: confetti
		""")
		let shown = try #require(work.overlays.first)
		#expect(shown.start == 4)
		#expect(shown.end == 14)
	}

	/// **The thing that was missing.** `within:` puts it on a stretch of the
	/// clip, measured from where the clip starts — so it is 1.5s to 4s *into*
	/// the clip, not 1.5s to 4s into the programme.
	@Test func withinPutsItOnAStretchOfTheClip() throws {
		let work = try programme("""
		    overlays:
		      - effect: confetti
		        within: middle
		        from:   00:01.500
		        to:     00:04.000
		""")
		let shown = try #require(work.overlays.first)
		#expect(shown.start == 5.5, "it is at \(shown.start), not 1.5s into the clip")
		#expect(shown.end == 8)
	}

	/// And it survives the clip moving, which is the whole reason `within:`
	/// exists: the same range written as programme times would be left behind.
	@Test func withinFollowsTheClipWhenItMoves() throws {
		let said = """
		    overlays:
		      - effect: confetti
		        within: middle
		        from:   00:01.500
		        to:     00:04.000
		"""
		let before = try #require(try programme(said).overlays.first)
		// Lengthen the clip in front of it and the range comes with it.
		let after = try #require(try programme(said, lead: 9).overlays.first)
		#expect(before.start == 5.5)
		#expect(after.start == 10.5, "the range did not follow the clip")
		#expect(after.end - after.start == before.end - before.start)
	}

	/// Programme times written inside an entry are the trap `within:` avoids,
	/// and the resolver says so rather than letting it pass.
	@Test func programmeTimesInsideAnEntryAreCalledOut() throws {
		let work = try programme("""
		    overlays:
		      - effect: confetti
		        from:   00:40.000
		        to:     00:44.000
		""")
		#expect(work.warnings.contains { $0.contains("within:") },
		        "nothing warned that the times no longer touch the clip")
	}

	/// It round-trips: a stretch of a clip comes back out as a stretch of that
	/// clip and not as the programme times it happens to land on.
	@Test func aStretchRoundTripsAsAStretch() throws {
		let project = Project(
			output: Output(width: 1920, height: 1080, framesPerSecond: 25, file: "out.mov"),
			overlays: [Overlay(kind: .effect(Effect()),
			                   span: .within(.clip(ClipReference("middle")), from: 1.5, to: 4),
			                   arrival: .cut, departure: .cut)])
		let written = ProjectWriter.write(project)
		#expect(written.contains("within:"))
		#expect(try ProjectReader.read(written) == project)
	}
}
