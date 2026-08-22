import AppKit
import AVFoundation
import CuttrCompose
import CuttrKit
import Testing
@testable import CuttrUI

/// Pressing Share, through the window rather than through `ProjectSharing`.
///
/// The sharing itself is covered against a real remote by
/// `SharingRoundTripTests`. What was never covered is the wiring — the menu
/// item, the capsule's row, `AppDelegate` forwarding, the window's own guard
/// clauses — and every one of those fails *silently* if it is wrong. "Nothing
/// happens" is exactly what a broken wire looks like, and it is what got
/// reported.
/// **Serialized, and it has to be.** Every test here builds a real window and
/// a real repository, and pressing Share leaves a detached task doing git.
/// Run in parallel they abort the test process — signal 6, no failure
/// recorded, which reads as a crash in the build rather than a fault in a
/// test. `LevelCurveTests` learned the same thing about building windows.
@MainActor @Suite(.serialized) struct ShareButtonTests {

	/// A project in a real work tree with a real remote, both on this disk.
	private func open() throws -> (ComposeWindowController, URL) {
		_ = NSApplication.shared
		let home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
			.appendingPathComponent("cuttr-share-ui-\(UUID().uuidString)", isDirectory: true)
			.resolvingSymlinksInPath().standardizedFileURL
		try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

		let origin = home.appendingPathComponent("origin.git")
		let git = ProjectVersions.Plumbing(root: home)
		_ = git.run(["init", "--bare", "--quiet", "--initial-branch=main", origin.path])

		let work = home.appendingPathComponent("work")
		_ = git.run(["clone", "--quiet", origin.path, work.path])
		let inside = ProjectVersions.Plumbing(root: work)
		_ = inside.run(["config", "user.email", "test@localhost"])
		_ = inside.run(["config", "user.name", "Test"])

		let file = work.appendingPathComponent("film.cuttrproj")
		try ProjectWriter.write(Project(timeline: [TimelineEntry(card: Card(duration: 3))]))
			.write(to: file, atomically: true, encoding: .utf8)
		_ = inside.run(["add", "-A"])
		_ = inside.run(["commit", "-q", "-m", "first"])
		_ = inside.run(["push", "--quiet", "--set-upstream", "origin", "main"])

		let document = ComposeDocument()
		try document.read(from: file)
		let controller = ComposeWindowController(document: document)
		_ = controller.windowForTesting
		return (controller, home)
	}

	/// The whole of the report: press it and something happens.
	@Test func pressingShareSaysSomething() throws {
		let (controller, home) = try open()
		defer { try? FileManager.default.removeItem(at: home) }

		controller.shareProject(nil)
		#expect(!controller.saidForTesting.isEmpty,
		        "Share said nothing at all, which is what a broken wire looks like")
	}

	/// And it reaches the sharing rather than stopping at a guard.
	@Test func shareGetsPastTheGuardsToTheWork() throws {
		let (controller, home) = try open()
		defer { try? FileManager.default.removeItem(at: home) }

		controller.shareProject(nil)
		// The guards each say their own thing; getting to the work says this.
		#expect(controller.saidForTesting == "sharing…",
		        "Share stopped before it began: \(controller.saidForTesting)")
	}

	/// A project with no file has nowhere to share from, and says so rather
	/// than doing nothing.
	@Test func anUnsavedProjectSaysSo() {
		_ = NSApplication.shared
		let controller = ComposeWindowController(document: ComposeDocument())
		_ = controller.windowForTesting
		controller.shareProject(nil)
		#expect(controller.saidForTesting.contains("save the project"))
	}

	/// A project outside any repository says so too.
	@Test func aProjectOnAFootageVolumeSaysSo() throws {
		_ = NSApplication.shared
		let folder = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("cuttr-nowhere-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: folder) }
		let file = folder.appendingPathComponent("film.cuttrproj")
		try ProjectWriter.write(Project()).write(to: file, atomically: true, encoding: .utf8)

		let document = ComposeDocument()
		try document.read(from: file)
		let controller = ComposeWindowController(document: document)
		_ = controller.windowForTesting
		controller.shareProject(nil)
		#expect(controller.saidForTesting.contains("not in a git repository"),
		        "it said: \(controller.saidForTesting)")
	}

	/// The menu item exists and is enabled, which is the other way a button
	/// does nothing.
	@Test func theMenuItemIsThereAndAnswered() throws {
		let (controller, home) = try open()
		defer { try? FileManager.default.removeItem(at: home) }

		let item = NSMenuItem(title: "Share…",
		                      action: #selector(AppDelegate.shareProject(_:)),
		                      keyEquivalent: "s")
		#expect(controller.validateMenuItem(item), "the Share item is greyed out")
		#expect(controller.responds(to: #selector(ComposeWindowController.shareProject(_:))))
	}
}

/// A programme with no footage in it.
///
/// Cards and scenes are a whole intro screen made of nothing but the file it
/// is written in — a real project, and one whose composition has no video
/// track at all. Asking `AVAssetImageGenerator` for a frame of one throws an
/// Objective-C exception from inside AVFoundation that nothing in Swift can
/// catch, so it does not fail: it takes the program down.
///
/// It took the test process down, which is the only reason anybody found out.
@MainActor @Suite(.serialized) struct PictureLessProgrammeTests {

	private func window(_ text: String) throws -> ComposeWindowController {
		_ = NSApplication.shared
        let document = ComposeDocument(project: try ProjectReader.read(text))
		document.apply(document.project)
		let controller = ComposeWindowController(document: document)
		_ = controller.windowForTesting
		return controller
	}

	/// The condition itself, against real compositions.
	///
	/// Reaching the throw needs a *built* composition, and a window in a test
	/// has none — so a test that presses the info page passes whether or not
	/// the guard is there. That is what the first version of this did.
	@Test func aCompositionWithNoVideoTrackHasNoFrameToGive() throws {
		let empty = AVMutableComposition()
		#expect(!ComposeWindowController.hasPicture(empty),
		        "a programme of cards was asked for a frame")

		let withPicture = AVMutableComposition()
		_ = withPicture.addMutableTrack(withMediaType: .video,
		                                preferredTrackID: kCMPersistentTrackID_Invalid)
		#expect(ComposeWindowController.hasPicture(withPicture),
		        "a programme with footage was refused one")

		// Sound alone is still no picture: a programme can be a card with music
		// under it and no frames anywhere.
		let soundOnly = AVMutableComposition()
		_ = soundOnly.addMutableTrack(withMediaType: .audio,
		                              preferredTrackID: kCMPersistentTrackID_Invalid)
		#expect(!ComposeWindowController.hasPicture(soundOnly))
	}

	@Test func askingForAFrameOfCardsIsSafeAndSaysNothing() throws {
		let controller = try window("""
			timeline:
			  - {card: 00:10.000, fill: "#101010"}
			""")
		controller.show(.preview)

		var asked = false
		var picture: NSImage?
		controller.posterForTesting(at: 1) { picture = $0; asked = true }
		#expect(asked, "the poster never answered")
		#expect(picture == nil, "it found a frame in a programme with no picture")
	}

	/// And the info page, which is what asks for one on the way in.
	@Test func openingTheInfoPageOnAProgrammeOfCardsIsSafe() throws {
		let controller = try window("""
			timeline:
			  - {card: 00:04.000, fill: "#202020"}
			  - {card: 00:04.000, fill: "#303030"}
			""")
		controller.show(.project)
		controller.show(.preview)
		controller.show(.project)
		#expect(controller.modeForTesting == .project)
	}
}
