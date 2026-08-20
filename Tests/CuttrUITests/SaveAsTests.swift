import Foundation
import Testing
@testable import CuttrCompose
@testable import CuttrUI

/// Saving a project somewhere else.
///
/// The paths in a project are relative to where the project sits, so the whole
/// question is whether they still find their files afterwards.
@MainActor @Suite struct SaveAsTests {

	private func folders() throws -> (here: URL, there: URL) {
		let root = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("cuttr-saveas-\(UUID().uuidString)")
		let here = root.appendingPathComponent("here")
		let there = root.appendingPathComponent("there")
		for folder in [here, there, here.appendingPathComponent("takes")] {
			try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		}
		return (here, there)
	}

	@Test func aProjectSavedElsewhereStillFindsItsTakes() throws {
		let (here, there) = try folders()
		defer { try? FileManager.default.removeItem(at: here.deletingLastPathComponent()) }
		let project = try ProjectReader.read("""
			takes: [takes/one.cuttr, /Volumes/card/two.cuttr]
			timeline:
			  - group: middle
			    clips: [{card: 00:01.000, fill: "#000000"}]
			    sounds:
			      - file: media/inside.wav
			        from: 00:00.000
			        to:   00:01.000
			sounds:
			  - file: media/music.wav
			    from: 00:00.000
			    to:   00:01.000
			""")
		let document = ComposeDocument(project: project, url: here.appendingPathComponent("p.cuttrproj"))
		try document.saveAs(there.appendingPathComponent("p.cuttrproj"))

		// One folder over, so one step up and back down again.
		#expect(document.project.takes.first == "../here/takes/one.cuttr")
		// An absolute path is somebody saying where the file is. Left alone.
		#expect(document.project.takes.last == "/Volumes/card/two.cuttr")
		#expect(document.project.sounds.first?.file == "../here/media/music.wav")
		guard case .group(_, let inside) = document.project.timeline.first?.source else {
			Issue.record("the section came back as something else")
			return
		}
		_ = inside
		#expect(document.project.timeline.first?.sounds.first?.file == "../here/media/inside.wav")
		// And what is on disk says the same thing.
		let written = try String(contentsOf: there.appendingPathComponent("p.cuttrproj"), encoding: .utf8)
		#expect(written.contains("../here/takes/one.cuttr"))
	}

	/// Saved beside itself — under another name in the same folder — nothing
	/// moves, so nothing is rewritten.
	@Test func aProjectSavedInItsOwnFolderKeepsItsPathsAsTheyAre() throws {
		let (here, _) = try folders()
		defer { try? FileManager.default.removeItem(at: here.deletingLastPathComponent()) }
		let project = try ProjectReader.read("takes: [takes/one.cuttr]\n")
		let document = ComposeDocument(project: project, url: here.appendingPathComponent("p.cuttrproj"))
		try document.saveAs(here.appendingPathComponent("copy.cuttrproj"))
		#expect(document.project.takes == ["takes/one.cuttr"])
	}

	/// The case this started as: an untitled project has nowhere to be relative
	/// to, so its paths are whatever they already say.
	@Test func anUntitledProjectIsJustWritten() throws {
		let (here, _) = try folders()
		defer { try? FileManager.default.removeItem(at: here.deletingLastPathComponent()) }
		let document = ComposeDocument(project: try ProjectReader.read("takes: [takes/one.cuttr]\n"))
		try document.saveAs(here.appendingPathComponent("p.cuttrproj"))
		#expect(document.project.takes == ["takes/one.cuttr"])
		#expect(document.url?.lastPathComponent == "p.cuttrproj")
	}
}
