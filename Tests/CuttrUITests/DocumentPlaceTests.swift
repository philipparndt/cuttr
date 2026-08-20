import AppKit
import Testing
@testable import CuttrCompose
@testable import CuttrKit
@testable import CuttrUI

/// One place to work, and the documents take turns in it.
///
/// These assert on *outcomes* — how many document windows are on screen, which
/// one, and what frame it is in — rather than on a handler having fired. That
/// distinction is the whole reason this file exists: the switcher was reported
/// fixed twice on the strength of tests that watched a closure run, while
/// nothing on the screen changed.
@MainActor @Suite struct DocumentPlaceTests {

	static let takeFile = """
		cuttr: 1

		video: media/clip.mov

		clips:
		  - slug:  mia-intro
		    name:  Mia, Intro
		    start: 00:00.000
		    end:   00:02.000
		"""

	/// A project with a take file beside it, written somewhere temporary.
	private func project() throws -> (URL, URL) {
		let folder = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("cuttr-place-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		let take = folder.appendingPathComponent("mia-take-1.cuttr")
		// Written as text, with media in it: a take with no `video:` and no
		// `audio:` is refused by the reader, and `open(_:)` answers a refusal
		// with a modal alert — which in a test process waits for a button
		// nobody is going to press.
		try Self.takeFile.write(to: take, atomically: true, encoding: .utf8)
		let projectFile = folder.appendingPathComponent("programme.cuttrproj")
		var made = Project(takes: ["mia-take-1.cuttr"], output: Output(file: "out.mov"))
		made.timeline = []
		try ProjectWriter.write(made).write(to: projectFile, atomically: true, encoding: .utf8)
		return (projectFile, take)
	}

	/// A delegate holding one project window, already in a known place.
	private func inThePlace(_ frame: NSRect) throws
		-> (AppDelegate, ComposeWindowController, URL, URL) {
		_ = NSApplication.shared
		let (projectFile, take) = try project()
		let document = ComposeDocument()
		try document.read(from: projectFile)
		let composer = ComposeWindowController(document: document)
		let delegate = AppDelegate()
		delegate.adoptForTesting(composers: [composer])
		delegate.reveal(composer.window)
		composer.window?.setFrame(frame, display: false)
		return (delegate, composer, projectFile, take)
	}

	/// Opening a take from a project puts the take where the project was.
	///
	/// This is the fault as the user reported it: "double click on a take should
	/// open the take within the same window… it only opens sometimes and then in
	/// a different window". What it did was call `addTabbedWindow` — which forms
	/// a group whatever `tabbingMode` says — and then have the delegate's own
	/// key-window observer tear the group apart, leaving the take in a window of
	/// its own, cascaded away and often behind the project.
	@Test func openingATakeTakesTheProjectsPlace() throws {
		let place = NSRect(x: 140, y: 96, width: 1320, height: 764)
		let (delegate, composer, _, take) = try inThePlace(place)
		let projectWindow = try #require(composer.window)

		delegate.open(take)

		#expect(delegate.documentWindows.count == 2, "the take did not open at all")
		let onScreen = delegate.documentWindows.filter(\.isVisible)
		#expect(onScreen.count == 1,
		        "\(onScreen.count) document windows are on screen, not one")
		let shown = try #require(onScreen.first)
		#expect(shown !== projectWindow, "the project is still the thing in front")
		#expect(projectWindow.isVisible == false, "the project is still on screen behind it")
		// And in the place, not cascaded 58 points down and right from it.
		#expect(shown.frame == place, "the take opened at \(shown.frame), not \(place)")
	}

	/// And no tab group is formed on the way, so no system tab bar arrives over
	/// a title bar this program draws itself.
	@Test func nothingIsEverPutInATabGroup() throws {
		let (delegate, composer, _, take) = try inThePlace(
			NSRect(x: 100, y: 100, width: 1200, height: 800))
		delegate.open(take)
		for window in delegate.documentWindows {
			#expect(window.tabGroup?.windows.count ?? 1 == 1,
			        "a window is in a tab group of \(window.tabGroup?.windows.count ?? 1)")
		}
		_ = composer
	}

	/// Never two windows showing one document — including when the same file
	/// arrives under a different spelling of its path.
	@Test func oneDocumentIsNeverOpenTwice() throws {
		let (delegate, _, _, take) = try inThePlace(
			NSRect(x: 100, y: 100, width: 1200, height: 800))
		delegate.open(take)
		delegate.open(take)
		#expect(delegate.documentWindows.count == 2, "a second window opened on the same take")

		// `/var/folders/…` and `/private/var/folders/…` are one file under two
		// names. Plain `==` on the URLs said they were two documents.
		let other = URL(fileURLWithPath: "/private" + take.standardizedFileURL.path)
		if FileManager.default.fileExists(atPath: other.path) {
			delegate.open(other)
			#expect(delegate.documentWindows.count == 2,
			        "the same take opened again under \(other.path)")
		}
	}

	/// Choosing a document from the switcher's list goes to it.
	///
	/// Driven through the real control — the rows it builds, a selection in it,
	/// and the `↵` it prints on itself — and asserted on *which document is in
	/// front afterwards*. The test this replaces asserted that the table had an
	/// action, which it had all along.
	@Test func choosingAnOpenDocumentInTheSwitcherGoesToIt() throws {
		let (delegate, composer, _, take) = try inThePlace(
			NSRect(x: 160, y: 120, width: 1280, height: 800))
		let projectWindow = try #require(composer.window)
		delegate.open(take)
		let takeWindow = try #require(delegate.showing)
		#expect(takeWindow !== projectWindow)

		// The list as the capsule would build it, from the take we are in.
		let groups = delegate.switcherGroups(current: takeWindow)
		let switcher = DocumentSwitcher.Switcher(groups)
		switcher.loadView()
		let rows = switcher.shownForTesting
		guard let wanted = rows.firstIndex(of: composer.composeDocument.displayName) else {
			Issue.record("the project is not in \(rows)")
			return
		}
		switcher.selectForTesting(wanted)
		switcher.chooseForTesting()

		let landed = delegate.showing === takeWindow ? "still the take" : "neither"
		#expect(delegate.showing === projectWindow, .init(rawValue:
			"after choosing the project the document in front is \(landed)"))
		#expect(takeWindow.isVisible == false, "the take is still on screen too")
		// And the project came back into the same place rather than its own.
		#expect(projectWindow.frame == NSRect(x: 160, y: 120, width: 1280, height: 800))
	}

	/// And back again, which is the gesture the user described doing: open a
	/// take from a project, switch back, open another, switch by keyboard.
	@Test func switchingBackAndForthIsTheSameEveryTime() throws {
		let (delegate, composer, _, take) = try inThePlace(
			NSRect(x: 200, y: 150, width: 1240, height: 780))
		let projectWindow = try #require(composer.window)
		delegate.open(take)
		let takeWindow = try #require(delegate.showing)

		// Ten times, because a gesture that works only sometimes is the
		// complaint. `⇧⌘]` and `⇧⌘[` walk the documents.
		for turn in 1...10 {
			delegate.nextDocument(nil)
			#expect(delegate.showing === takeWindow || delegate.showing === projectWindow)
			#expect(delegate.documentWindows.filter(\.isVisible).count == 1,
			        "turn \(turn): \(delegate.documentWindows.filter(\.isVisible).count) on screen")
			delegate.previousDocument(nil)
			#expect(delegate.documentWindows.filter(\.isVisible).count == 1,
			        "turn \(turn): \(delegate.documentWindows.filter(\.isVisible).count) on screen")
		}
		#expect(delegate.documentWindows.count == 2,
		        "windows accumulated: \(delegate.documentWindows.count)")
	}

	/// Closing the document on screen leaves the next one in its place, rather
	/// than an empty screen with documents still open.
	@Test func theNextDocumentTakesThePlace() throws {
		let (delegate, composer, _, take) = try inThePlace(
			NSRect(x: 180, y: 130, width: 1220, height: 770))
		let projectWindow = try #require(composer.window)
		delegate.open(take)
		let takeWindow = try #require(delegate.showing)
		takeWindow.close()
		#expect(delegate.showing === projectWindow,
		        "nothing came back after the take closed")
		#expect(delegate.documentWindows.count == 1)
	}
}
