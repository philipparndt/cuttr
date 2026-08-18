import CuttrKit
import Foundation
import Testing
@testable import CuttrCompose

/// Copying a project and everything under it into one folder.
@Suite struct ExportTests {

	/// Two takes in different folders, both called `take`, both pointing at
	/// media outside the project, one recording shared between them.
	private func scattered() throws -> (root: URL, project: Project) {
		let root = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("cuttr-export-\(UUID().uuidString)")
		let manager = FileManager.default
		for folder in ["proj", "a", "b", "cards"] {
			try manager.createDirectory(
				at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
		}
		try Data("one".utf8).write(to: root.appendingPathComponent("cards/shared.mov"))
		try Data("two".utf8).write(to: root.appendingPathComponent("cards/other.mov"))
		try Data("mic".utf8).write(to: root.appendingPathComponent("cards/sound.wav"))
		// Both takes have a sidecar, and both are called `mia.path` — which is
		// the collision the export has to keep apart.
		for folder in ["a", "b"] {
			try manager.createDirectory(
				at: root.appendingPathComponent("\(folder)/anchors"), withIntermediateDirectories: true)
			try Data("0 0.5 0.5\n".utf8).write(
				to: root.appendingPathComponent("\(folder)/anchors/mia.path"))
		}

		let one = Take(video: "../cards/shared.mov",
		               audio: AudioTrack(file: "../cards/sound.wav", offset: 1.5),
		               clips: [Clip(slug: "intro", start: 0, end: 5)],
		               anchors: [Anchor(name: "mia", from: 0, to: 5, markedAt: 1,
		                                point: CGPoint(x: 0.5, y: 0.5), path: "anchors/mia.path")])
		// The same recording as the first take, and an anchor with the same
		// name — both of which would collide in a flat folder.
		let two = Take(video: "../cards/shared.mov",
		               clips: [Clip(slug: "outro", start: 0, end: 3)],
		               anchors: [Anchor(name: "mia", from: 0, to: 3, markedAt: 1,
		                                point: CGPoint(x: 0.5, y: 0.5), path: "anchors/mia.path")])
		try TakeWriter.write(one).write(
			to: root.appendingPathComponent("a/take.cuttr"), atomically: true, encoding: .utf8)
		try TakeWriter.write(two).write(
			to: root.appendingPathComponent("b/take.cuttr"), atomically: true, encoding: .utf8)

		let project = Project(
			takes: ["../a/take.cuttr", "../b/take.cuttr"],
			output: Output(file: "out.mov"),
			timeline: [TimelineEntry(clip: ClipReference("intro")),
			           TimelineEntry(clip: ClipReference("outro"))])
		return (root, project)
	}

	@Test func everythingLandsInOneFolderAndResolves() throws {
		let (root, project) = try scattered()
		defer { try? FileManager.default.removeItem(at: root) }
		let target = root.appendingPathComponent("out")
		let report = try ProjectExporter.export(
			project, named: "programme", from: root.appendingPathComponent("proj"), to: target)

		#expect(report.takes.count == 2)
		// Two takes both called `take`, so the second is suffixed.
		#expect(report.takes.sorted() == ["take-2.cuttr", "take.cuttr"])
		#expect(report.renamed.contains { $0.to == "take-2.cuttr" })

		// The shared recording is copied once and pointed at twice; the wav
		// makes the second.
		#expect(report.media.sorted() == ["shared.mov", "sound.wav"])
		#expect(report.missing.isEmpty)

		// And the whole thing resolves from the new folder, which is the only
		// test that really matters.
		let exported = try ProjectReader.read(
			try String(contentsOf: target.appendingPathComponent("programme.cuttrproj"), encoding: .utf8))
		#expect(exported.takes == ["takes/take.cuttr", "takes/take-2.cuttr"])
		let resolved = try Resolver.resolve(exported, baseURL: target)
		#expect(resolved.clips.map(\.reference.slug) == ["intro", "outro"])
		#expect(resolved.clips.allSatisfy { FileManager.default.fileExists(atPath: $0.videoURL!.path) })
	}

	@Test func sidecarsAreKeptApartByTake() throws {
		let (root, project) = try scattered()
		defer { try? FileManager.default.removeItem(at: root) }
		let target = root.appendingPathComponent("out")
		_ = try ProjectExporter.export(
			project, named: "programme", from: root.appendingPathComponent("proj"), to: target)

		// Both takes have an anchor called `mia`; flat, they would be one file.
		let take = try TakeReader.read(
			try String(contentsOf: target.appendingPathComponent("takes/take.cuttr"), encoding: .utf8))
		#expect(take.anchors.first?.path == "anchors/take/mia.path")
		let other = try TakeReader.read(
			try String(contentsOf: target.appendingPathComponent("takes/take-2.cuttr"), encoding: .utf8))
		#expect(other.anchors.first?.path == "anchors/take-2/mia.path")
	}

	@Test func theAudioOffsetSurvives() throws {
		let (root, project) = try scattered()
		defer { try? FileManager.default.removeItem(at: root) }
		let target = root.appendingPathComponent("out")
		_ = try ProjectExporter.export(
			project, named: "programme", from: root.appendingPathComponent("proj"), to: target)
		let take = try TakeReader.read(
			try String(contentsOf: target.appendingPathComponent("takes/take.cuttr"), encoding: .utf8))
		// An alignment somebody spent a minute on is not something to lose in a
		// file copy.
		#expect(take.audio?.offset == 1.5)
		#expect(take.audio?.file == "../media/sound.wav")
	}

	@Test func aMissingRecordingIsReportedNotFatal() throws {
		let (root, project) = try scattered()
		defer { try? FileManager.default.removeItem(at: root) }
		try FileManager.default.removeItem(at: root.appendingPathComponent("cards/shared.mov"))
		let target = root.appendingPathComponent("out")
		let report = try ProjectExporter.export(
			project, named: "programme", from: root.appendingPathComponent("proj"), to: target)
		// One missing file must not stop the rest going, and the take still
		// points where it should so dropping the file in later fixes it.
		#expect(report.takes.count == 2)
		#expect(!report.missing.isEmpty)
		#expect(report.media == ["sound.wav"])
	}

	@Test func itRefusesToWriteIntoSomebodyElsesFolder() throws {
		let (root, project) = try scattered()
		defer { try? FileManager.default.removeItem(at: root) }
		#expect(throws: ProjectExporter.ExportError.self) {
			try ProjectExporter.export(
				project, named: "programme", from: root.appendingPathComponent("proj"),
				to: root.appendingPathComponent("cards"))
		}
	}
}
