import CuttrKit
import Foundation
import Testing
@testable import CuttrCompose

@Suite struct ResolverTests {

	/// A folder with two takes and a dummy media file in it.
	///
	/// Written to disk rather than injected, because the resolver's job is
	/// following relative paths out of a project file into take files and out of
	/// those into media — and a fake filesystem would test everything except
	/// that.
	private func fixture() throws -> URL {
		let directory = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("cuttr-resolve-\(UUID().uuidString)")
		try FileManager.default.createDirectory(
			at: directory.appendingPathComponent("takes"), withIntermediateDirectories: true)
		try Data().write(to: directory.appendingPathComponent("a.mov"))
		try Data().write(to: directory.appendingPathComponent("b.mov"))

		let one = Take(video: "../a.mov", clips: [
			Clip(slug: "intro", start: 0, end: 5, tags: ["a-roll"]),
			Clip(slug: "demo", start: 5, end: 15, tags: ["a-roll"]),
			Clip(slug: "hands", start: 20, end: 24, tags: ["b-roll"], order: 900),
		])
		let two = Take(video: "../b.mov", clips: [
			Clip(slug: "wrap", start: 0, end: 3, tags: ["a-roll"]),
			Clip(slug: "sky", start: 10, end: 12, tags: ["b-roll", "reject"]),
			Clip(slug: "street", start: 30, end: 36, tags: ["b-roll"], order: 1100),
		])
		try TakeWriter.write(one).write(
			to: directory.appendingPathComponent("takes/take-01.cuttr"), atomically: true, encoding: .utf8)
		try TakeWriter.write(two).write(
			to: directory.appendingPathComponent("takes/take-02.cuttr"), atomically: true, encoding: .utf8)
		return directory
	}

	private let takes = "takes:\n  - takes/take-01.cuttr\n  - takes/take-02.cuttr\n"

	@Test func laysClipsEndToEndOnOneClock() throws {
		let directory = try fixture()
		defer { try? FileManager.default.removeItem(at: directory) }
		let project = try ProjectReader.read(takes + """
		timeline:
		  - intro
		  - take-02/wrap
		""")
		let resolved = try Resolver.resolve(project, baseURL: directory)
		#expect(resolved.clips.map(\.start) == [0, 5])
		#expect(resolved.duration == 8)
		// Media resolved out of the take's own directory, not the project's.
		#expect(resolved.clips[0].videoURL?.lastPathComponent == "a.mov")
		#expect(resolved.clips[1].videoURL?.lastPathComponent == "b.mov")
	}

	@Test func aQueryExpandsInClipOrder() throws {
		let directory = try fixture()
		defer { try? FileManager.default.removeItem(at: directory) }
		let project = try ProjectReader.read(takes + """
		timeline:
		  - query: "#b-roll and not #reject"
		""")
		let resolved = try Resolver.resolve(project, baseURL: directory)
		// `hands` is 900 and `street` is 1100, so the clips' own order decides —
		// not the order the takes are listed in, which would give the reverse.
		#expect(resolved.clips.map(\.reference.slug) == ["hands", "street"])
		#expect(resolved.clips.map(\.start) == [0, 4])
	}

	@Test func equalOrdersFallBackToTakeOrderThenTime() throws {
		let directory = try fixture()
		defer { try? FileManager.default.removeItem(at: directory) }
		let project = try ProjectReader.read(takes + "timeline:\n  - \"#a-roll\"\n")
		let resolved = try Resolver.resolve(project, baseURL: directory)
		// All three are 1000, so: take-01 before take-02, and within take-01 the
		// earlier clip first. A query has to return the same programme twice.
		#expect(resolved.clips.map(\.reference.slug) == ["intro", "demo", "wrap"])
	}

	@Test func anExplicitListKeepsTheOrderWritten() throws {
		let directory = try fixture()
		defer { try? FileManager.default.removeItem(at: directory) }
		let project = try ProjectReader.read(takes + "timeline:\n  - clips: [street, intro, hands]\n")
		let resolved = try Resolver.resolve(project, baseURL: directory)
		// A list is a statement about order; `order:` does not get to override it.
		#expect(resolved.clips.map(\.reference.slug) == ["street", "intro", "hands"])
	}

	@Test func anEmptyTimelineIsNamedRatherThanRendered() throws {
		let directory = try fixture()
		defer { try? FileManager.default.removeItem(at: directory) }
		let project = try ProjectReader.read(takes)
		// Readable, savable, openable — and it says what to do next rather than
		// failing as though the file were broken.
		#expect(throws: ResolveError.self) { try Resolver.resolve(project, baseURL: directory) }
	}

	@Test func aQueryThatFindsNothingIsAnErrorRatherThanASilentGap() throws {
		let directory = try fixture()
		defer { try? FileManager.default.removeItem(at: directory) }
		let project = try ProjectReader.read(takes + "timeline:\n  - \"#nonexistent\"\n")
		#expect(throws: ResolveError.self) { try Resolver.resolve(project, baseURL: directory) }
	}

	@Test func anAmbiguousSlugIsNamedRatherThanGuessed() throws {
		let directory = try fixture()
		defer { try? FileManager.default.removeItem(at: directory) }
		// Both takes get a clip called `same`.
		for name in ["take-01", "take-02"] {
			let url = directory.appendingPathComponent("takes/\(name).cuttr")
			var take = try TakeReader.read(try String(contentsOf: url, encoding: .utf8))
			take.clips.append(Clip(slug: "same", start: 40, end: 42))
			try TakeWriter.write(take).write(to: url, atomically: true, encoding: .utf8)
		}
		let project = try ProjectReader.read(takes + "timeline:\n  - same\n")
		#expect(throws: ResolveError.self) { try Resolver.resolve(project, baseURL: directory) }
		// Qualified, it is fine.
		let qualified = try ProjectReader.read(takes + "timeline:\n  - take-02/same\n")
		#expect(try Resolver.resolve(qualified, baseURL: directory).clips.count == 1)
	}

	@Test func overlaysBoundToClipsGetTheirTimesFromTheProgramme() throws {
		let directory = try fixture()
		defer { try? FileManager.default.removeItem(at: directory) }
		let project = try ProjectReader.read(takes + """
		timeline:
		  - intro
		  - demo
		  - take-02/wrap
		overlays:
		  - text: Chapter one
		    from: intro
		    to: demo
		""")
		let resolved = try Resolver.resolve(project, baseURL: directory)
		// intro is 0–5, demo is 5–15: the caption covers both, and it does so
		// without anybody writing a time down. Re-cutting the take moves it.
		#expect(resolved.overlays[0].start == 0)
		#expect(resolved.overlays[0].end == 15)
	}
}
