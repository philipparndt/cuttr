import CuttrKit
import Foundation
import Testing
@testable import CuttrCompose

/// The files a resolve reads, and how often it really reads them.
///
/// Resolving happens on the main thread on every change to a project, from
/// sixty-odd places, and dragging an overlay along the programme is dozens of
/// changes a second. Every one of those used to re-read and re-parse every take
/// and every tracked-face sidecar. The only thing worth asserting about the fix
/// is that the work is not done twice — and that it *is* done again when the
/// file actually changed, which is the way a cache goes wrong.
@Suite(.serialized) struct ResolvedFilesTests {

	private func folder() throws -> URL {
		let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
			.appendingPathComponent("cuttr-files-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
		return url
	}

	private func writeTake(_ url: URL, end: Double) throws {
		try TakeWriter.write(Take(video: "a.mov", clips: [Clip(slug: "intro", start: 0, end: end)]))
			.write(to: url, atomically: true, encoding: .utf8)
	}

	// MARK: - Takes

	@Test func anUnchangedTakeIsParsedOnce() throws {
		let folder = try folder()
		defer { try? FileManager.default.removeItem(at: folder) }
		let url = folder.appendingPathComponent("one.cuttr")
		try writeTake(url, end: 10)

		let files = ResolvedFiles.shared
		files.forget()
		for _ in 0 ..< 20 { _ = try files.take(at: url) }
		#expect(files.reads(of: url) == 1,
		        "the take was parsed \(files.reads(of: url)) times for twenty resolves")
	}

	@Test func theSameTakeComesBackTheSame() throws {
		let folder = try folder()
		defer { try? FileManager.default.removeItem(at: folder) }
		let url = folder.appendingPathComponent("one.cuttr")
		try writeTake(url, end: 10)

		ResolvedFiles.shared.forget()
		let first = try ResolvedFiles.shared.take(at: url)
		let again = try ResolvedFiles.shared.take(at: url)
		#expect(first == again)
		#expect(again.clips[0].end == 10)
	}

	/// The way a cache goes wrong. A take re-cut in another window has to be
	/// seen, or the programme is resolved against a file nobody has any more.
	@Test func aTakeThatChangedIsReadAgain() throws {
		let folder = try folder()
		defer { try? FileManager.default.removeItem(at: folder) }
		let url = folder.appendingPathComponent("one.cuttr")
		try writeTake(url, end: 10)

		ResolvedFiles.shared.forget()
		#expect(try ResolvedFiles.shared.take(at: url).clips[0].end == 10)

		// A different length as well as a different time, because the stamp is
		// both — a date on its own has a resolution and two writes can land
		// inside it.
		try writeTake(url, end: 1234.5)
		#expect(try ResolvedFiles.shared.take(at: url).clips[0].end == 1234.5,
		        "a re-cut take was served from the cache")
		#expect(ResolvedFiles.shared.reads(of: url) == 2)
	}

	/// A file that has gone is still an error and still says so, rather than
	/// the last good copy being handed back for ever.
	@Test func aTakeThatIsNotThereStillThrows() throws {
		let folder = try folder()
		defer { try? FileManager.default.removeItem(at: folder) }
		let url = folder.appendingPathComponent("gone.cuttr")
		ResolvedFiles.shared.forget()
		#expect(throws: (any Error).self) { _ = try ResolvedFiles.shared.take(at: url) }
	}

	// MARK: - Anchor paths

	/// The expensive one: a line per tracked frame.
	@Test func anUnchangedAnchorPathIsParsedOnce() throws {
		let folder = try folder()
		defer { try? FileManager.default.removeItem(at: folder) }
		let url = folder.appendingPathComponent("mia.path")
		// Twenty seconds at twenty-five a second, which is a short shot.
		let lines = (0 ..< 500).map { "\(Double($0) / 25) 0.5 0.5" }.joined(separator: "\n")
		try lines.write(to: url, atomically: true, encoding: .utf8)

		let files = ResolvedFiles.shared
		files.forget()
		for _ in 0 ..< 20 { _ = files.anchorPath(at: url) }
		#expect(files.reads(of: url) == 1,
		        "500 samples were parsed \(files.reads(of: url)) times")
		#expect(files.anchorPath(at: url)?.samples.count == 500)
	}

	@Test func anAnchorPathThatChangedIsReadAgain() throws {
		let folder = try folder()
		defer { try? FileManager.default.removeItem(at: folder) }
		let url = folder.appendingPathComponent("mia.path")
		try "0 0.5 0.5".write(to: url, atomically: true, encoding: .utf8)

		ResolvedFiles.shared.forget()
		#expect(ResolvedFiles.shared.anchorPath(at: url)?.samples.count == 1)
		try "0 0.5 0.5\n1 0.6 0.6\n2 0.7 0.7".write(to: url, atomically: true, encoding: .utf8)
		#expect(ResolvedFiles.shared.anchorPath(at: url)?.samples.count == 3,
		        "a re-tracked shot was served from the cache")
	}

	@Test func anAnchorPathThatIsNotThereIsNothing() throws {
		let folder = try folder()
		defer { try? FileManager.default.removeItem(at: folder) }
		ResolvedFiles.shared.forget()
		#expect(ResolvedFiles.shared.anchorPath(at: folder.appendingPathComponent("no.path"))
			== nil)
	}

	// MARK: - Through a real resolve

	/// The whole point, end to end: resolving the same project over and over —
	/// which is what a drag does — reads each file once.
	@Test func resolvingRepeatedlyReadsTheTakeOnce() throws {
		let folder = try folder()
		defer { try? FileManager.default.removeItem(at: folder) }
		let take = folder.appendingPathComponent("one.cuttr")
		try writeTake(take, end: 30)

		var project = Project(takes: ["one.cuttr"])
		project.timeline = [try TimelineEntry(text: "intro")]

		ResolvedFiles.shared.forget()
		for _ in 0 ..< 30 {
			_ = try Resolver.resolve(project, baseURL: folder)
		}
		#expect(ResolvedFiles.shared.reads(of: take) == 1,
		        "thirty resolves read the take \(ResolvedFiles.shared.reads(of: take)) times")
	}

	/// And it still resolves to the same thing it did before there was a cache.
	@Test func aCachedResolveSaysWhatAFreshOneSays() throws {
		let folder = try folder()
		defer { try? FileManager.default.removeItem(at: folder) }
		try writeTake(folder.appendingPathComponent("one.cuttr"), end: 30)

		var project = Project(takes: ["one.cuttr"])
		project.timeline = [try TimelineEntry(text: "intro")]

		ResolvedFiles.shared.forget()
		let cold = try Resolver.resolve(project, baseURL: folder)
		let warm = try Resolver.resolve(project, baseURL: folder)
		#expect(cold.duration == warm.duration)
		#expect(cold.clips.count == warm.clips.count)
		#expect(cold.clips.first?.clip.slug == warm.clips.first?.clip.slug)
	}
}
