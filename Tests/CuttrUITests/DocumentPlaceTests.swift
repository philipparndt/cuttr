import AppKit
import Testing
@testable import CuttrCompose
@testable import CuttrKit
@testable import CuttrUI

/// One window, and the document in it changes.
///
/// These assert on *outcomes* — how many windows exist, which document each one
/// holds, what frame it has, and that the frame is the same afterwards — rather
/// than on a handler having fired. That distinction is the whole reason this
/// file exists: the switcher was reported fixed twice on the strength of tests
/// that watched a closure run, while nothing on the screen changed.
///
/// The count of windows is the assertion that matters most here, and it is the
/// one the model before this could not pass. That one opened a window per
/// document and ordered all but one out, which looks like a switch from the
/// inside and is several windows from the outside — the Window menu lists them,
/// Mission Control shows them, and the user said so twice.
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

	/// A project with two take files beside it, written somewhere temporary.
	private func project() throws -> (project: URL, first: URL, second: URL) {
		let folder = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("cuttr-place-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		// Written as text, with media in them: a take with no `video:` and no
		// `audio:` is refused by the reader, and `open(_:)` answers a refusal
		// with a modal alert — which in a test process waits for a button
		// nobody is going to press.
		let first = folder.appendingPathComponent("mia-take-1.cuttr")
		let second = folder.appendingPathComponent("walter-take-2.cuttr")
		for url in [first, second] {
			try Self.takeFile.write(to: url, atomically: true, encoding: .utf8)
		}
		let projectFile = folder.appendingPathComponent("programme.cuttrproj")
		var made = Project(takes: ["mia-take-1.cuttr", "walter-take-2.cuttr"],
		                   output: Output(file: "out.mov"))
		made.timeline = []
		made.scenes = ["intro": SceneDocument.starter]
		try ProjectWriter.write(made).write(to: projectFile, atomically: true, encoding: .utf8)
		return (projectFile, first, second)
	}

	private struct Open {
		let delegate: AppDelegate
		let composer: ComposeWindowController
		let files: (project: URL, first: URL, second: URL)
	}

	/// A delegate with one project on screen, in a known frame.
	private func inThePlace(_ frame: NSRect) throws -> Open {
		_ = NSApplication.shared
		let files = try project()
		let document = ComposeDocument()
		try document.read(from: files.project)
		let composer = ComposeWindowController(document: document)
		let delegate = AppDelegate()
		delegate.adoptForTesting(composers: [composer])
		delegate.reveal(composer)
		composer.window?.setFrame(frame, display: false)
		return Open(delegate: delegate, composer: composer, files: files)
	}

	/// Opening a take from a project changes what is in the window. It does not
	/// open a window.
	///
	/// This is the fault as the user reported it, twice: "it still seems to open
	/// a new window instead of just switching the contents when navigating to
	/// the take editor". They were right and they could tell — a window
	/// vanishing while another appears at the same coordinates is still two
	/// windows.
	@Test func openingATakeChangesWhatIsInTheWindow() throws {
		let place = NSRect(x: 140, y: 96, width: 1320, height: 764)
		let open = try inThePlace(place)
		let window = try #require(open.composer.window)

		open.delegate.open(open.files.first)

		#expect(open.delegate.documentWindows.count == 1,
		        "\(open.delegate.documentWindows.count) windows, not one")
		#expect(open.delegate.documentWindows.first === window,
		        "the window somebody was working in is not the one on screen")
		// The take is what is in it, and the project is not.
		let showing = try #require(open.delegate.showing as? MainWindowController)
		#expect(showing.takeDocument.url?.standardizedFileURL
			== open.files.first.standardizedFileURL)
		#expect(open.composer.window == nil,
		        "the project still thinks it has a window")
		// And the window kept its frame, because it is the same window.
		#expect(window.frame == place, "the window moved to \(window.frame)")
		// The take's own view is what the window is showing.
		#expect(showing.contentRoot.window === window,
		        "the take's view is not in the window")
		#expect(open.composer.contentRoot.window == nil,
		        "the project's view is still in the window")
	}

	/// The window is still one window after ten switches each way, and still in
	/// the same frame.
	///
	/// Ten because "it only opens sometimes" is the complaint. `⇧⌘]` and `⇧⌘[`
	/// walk the documents.
	@Test func switchingIsTheSameEveryTimeAndKeepsTheFrame() throws {
		let place = NSRect(x: 200, y: 150, width: 1240, height: 780)
		let open = try inThePlace(place)
		let window = try #require(open.composer.window)
		open.delegate.open(open.files.first)
		#expect(window.frame == place)

		for turn in 1...10 {
			open.delegate.nextDocument(nil)
			#expect(open.delegate.documentWindows.count == 1,
			        "turn \(turn): \(open.delegate.documentWindows.count) windows")
			#expect(window.frame == place, "turn \(turn): the frame is \(window.frame)")
			open.delegate.previousDocument(nil)
			#expect(open.delegate.documentWindows.count == 1,
			        "turn \(turn) back: \(open.delegate.documentWindows.count) windows")
			#expect(window.frame == place, "turn \(turn) back: \(window.frame)")
			#expect(open.delegate.showing != nil, "turn \(turn): nothing is on screen")
		}
		// Exactly one document is in the window at a time, and both are still
		// open.
		#expect(open.delegate.documents.count == 2,
		        "documents accumulated: \(open.delegate.documents.count)")
	}

	/// A frame somebody has dragged to survives a switch, which is the point of
	/// it being the same window.
	@Test func aDraggedFrameSurvivesASwitch() throws {
		let open = try inThePlace(NSRect(x: 100, y: 100, width: 1200, height: 800))
		let window = try #require(open.composer.window)
		open.delegate.open(open.files.first)

		// Somebody drags the window somewhere odd and resizes it.
		let dragged = NSRect(x: 233, y: 87, width: 1077, height: 691)
		window.setFrame(dragged, display: false)
		open.delegate.nextDocument(nil)
		#expect(window.frame == dragged, "the frame became \(window.frame)")
		open.delegate.nextDocument(nil)
		#expect(window.frame == dragged, "and back it became \(window.frame)")
		#expect(open.delegate.documentWindows.count == 1)
	}

	/// No tab group is formed on the way, so no system tab bar arrives over a
	/// title bar this program draws itself.
	@Test func nothingIsEverPutInATabGroup() throws {
		let open = try inThePlace(NSRect(x: 100, y: 100, width: 1200, height: 800))
		open.delegate.open(open.files.first)
		for window in open.delegate.documentWindows {
			#expect(window.tabbingMode == .disallowed)
			#expect(window.tabGroup?.windows.count ?? 1 == 1,
			        "a window is in a tab group of \(window.tabGroup?.windows.count ?? 1)")
		}
	}

	/// Never two documents on one file — including when the same file arrives
	/// under a different spelling of its path.
	@Test func oneDocumentIsNeverOpenTwice() throws {
		let open = try inThePlace(NSRect(x: 100, y: 100, width: 1200, height: 800))
		open.delegate.open(open.files.first)
		open.delegate.open(open.files.first)
		#expect(open.delegate.documents.count == 2, "a second take opened on the same file")
		#expect(open.delegate.documentWindows.count == 1)

		// `/var/folders/…` and `/private/var/folders/…` are one file under two
		// names. Plain `==` on the URLs said they were two documents.
		let other = URL(fileURLWithPath: "/private" + open.files.first.standardizedFileURL.path)
		if FileManager.default.fileExists(atPath: other.path) {
			open.delegate.open(other)
			#expect(open.delegate.documents.count == 2,
			        "the same take opened again under \(other.path)")
		}
	}

	/// The double click in the takes list — where the gesture actually starts —
	/// arrives at a switch of contents in the same window.
	@Test func theDoubleClickInTheTakesListSwapsInPlace() throws {
		let place = NSRect(x: 160, y: 120, width: 1280, height: 800)
		let open = try inThePlace(place)
		let window = try #require(open.composer.window)

		// Through the list's own `doubleAction` path, not through the delegate.
		open.composer.takesForTesting.chooseRowForTesting(0)

		#expect(open.delegate.documentWindows.count == 1,
		        "the double click opened a window")
		#expect(open.delegate.documentWindows.first === window)
		#expect(open.delegate.showing is MainWindowController,
		        "the double click did not reach the take")
		#expect(window.frame == place)
	}

	/// And with ⌥ held it opens beside, which is the explicit way to have two
	/// takes on screen at once.
	@Test func optionDoubleClickOpensASecondWindow() throws {
		let open = try inThePlace(NSRect(x: 160, y: 120, width: 1280, height: 800))
		let first = try #require(open.composer.window)

		open.composer.takesForTesting.chooseRowForTesting(0, aside: true)

		#expect(open.delegate.documentWindows.count == 2,
		        "⌥ did not give the take a window of its own")
		let places = open.delegate.placesForTesting
		#expect(places.count == 2)
		// Two windows, two different documents, and the project still on screen
		// in the one it was in.
		let held = places.compactMap { $0.showing }
		#expect(held.count == 2)
		#expect(held[0] !== held[1], "both windows hold the same document")
		#expect(places.contains { $0.window === first && $0.showing === open.composer },
		        "the project left the window it was in")
		// Not exactly on top of each other, which is the whole point of two.
		let frames = Set(places.map { $0.window.frame.origin.debugDescription })
		#expect(frames.count == places.count,
		        "two windows at one origin: \(frames)")
	}

	/// ⌥⌘N moves the document on screen into a window of its own and leaves the
	/// rest where they were.
	@Test func theDocumentOnScreenCanMoveToItsOwnWindow() throws {
		let open = try inThePlace(NSRect(x: 120, y: 90, width: 1240, height: 780))
		open.delegate.open(open.files.first)
		#expect(open.delegate.documentWindows.count == 1)

		open.delegate.moveToNewWindow(nil)

		#expect(open.delegate.documentWindows.count == 2,
		        "⌥⌘N did not make a second window")
		let places = open.delegate.placesForTesting
		#expect(places.count == 2)
		#expect(places.map(\.documents.count) == [1, 1],
		        "the documents did not split one each")
		// And the project came back on screen in the window the take left.
		#expect(places[0].showing === open.composer,
		        "nothing came forward in the window the take left")
	}

	/// Choosing a document from the switcher's list goes to it.
	///
	/// Driven through the real control — the rows it builds, a selection in it,
	/// and the `↵` it prints on itself — and asserted on which document is in
	/// the window afterwards. The test this replaces asserted that the table had
	/// an action, which it had all along.
	@Test func choosingAnOpenDocumentInTheSwitcherGoesToIt() throws {
		let place = NSRect(x: 160, y: 120, width: 1280, height: 800)
		let open = try inThePlace(place)
		let window = try #require(open.composer.window)
		open.delegate.open(open.files.first)
		let take = try #require(open.delegate.showing)

		let groups = open.delegate.switcherGroups()
		let switcher = DocumentSwitcher.Switcher(groups)
		switcher.loadView()
		let rows = switcher.shownForTesting
		guard let wanted = rows.firstIndex(of: open.composer.composeDocument.displayName) else {
			Issue.record("the project is not in \(rows)")
			return
		}
		switcher.selectForTesting(wanted)
		switcher.chooseForTesting()

		let landed = open.delegate.showing === take ? "still the take" : "neither"
		#expect(open.delegate.showing === open.composer, .init(rawValue:
			"after choosing the project the document in the window is \(landed)"))
		#expect(open.delegate.documentWindows.count == 1, "a window opened")
		#expect(window.frame == place, "the frame became \(window.frame)")
	}

	/// The switcher lists a take that has never been opened, and choosing it
	/// opens it into the window somebody is in.
	///
	/// "Maybe we should show directly all scenes and takes in the dropdown" —
	/// which makes the capsule a navigator rather than a list of windows.
	@Test func theSwitcherListsWhatIsReachableNotOnlyWhatIsOpen() throws {
		let open = try inThePlace(NSRect(x: 100, y: 100, width: 1200, height: 800))
		let window = try #require(open.composer.window)
		open.delegate.open(open.files.first)

		let rows = open.delegate.switcherGroups()
		let flat = rows.flatMap(\.entries).map(\.name)
		#expect(flat.contains("walter-take-2"),
		        "a take of this project that is not open is missing from \(flat)")
		#expect(flat.contains("intro"), "the project's scene is missing from \(flat)")
		// The open take is in the list once, not twice: once under what is open
		// and again under what is in the project.
		#expect(flat.filter { $0 == "mia-take-1" }.count == 1,
		        "the open take is listed \(flat.filter { $0 == "mia-take-1" }.count) times")
		// Three headings in order: what is open, what is in this project, what
		// was recent — and the middle one names the project.
		#expect(rows.first?.title == "Open Documents")
		#expect(rows.dropFirst().first?.title
			== "In \(open.composer.composeDocument.displayName)")

		// And choosing the one that is not open opens it here.
		let switcher = DocumentSwitcher.Switcher(rows)
		switcher.loadView()
		let listed = switcher.shownForTesting
		guard let wanted = listed.firstIndex(of: "walter-take-2") else {
			Issue.record("walter-take-2 is not in \(listed)")
			return
		}
		switcher.selectForTesting(wanted)
		switcher.chooseForTesting()
		#expect(open.delegate.documentWindows.count == 1, "it opened a window")
		#expect(open.delegate.documentWindows.first === window)
		let now = try #require(open.delegate.showing as? MainWindowController)
		#expect(now.takeDocument.url?.standardizedFileURL
			== open.files.second.standardizedFileURL,
			"the document in the window is \(now.takeDocument.displayName)")
	}

	/// ⌥ while choosing in the switcher opens beside rather than in place.
	@Test func optionInTheSwitcherOpensBeside() throws {
		let open = try inThePlace(NSRect(x: 100, y: 100, width: 1200, height: 800))
		open.delegate.open(open.files.first)

		let switcher = DocumentSwitcher.Switcher(open.delegate.switcherGroups())
		switcher.loadView()
		let rows = switcher.shownForTesting
		guard let wanted = rows.firstIndex(of: "walter-take-2") else {
			Issue.record("walter-take-2 is not in \(rows)")
			return
		}
		switcher.selectForTesting(wanted)
		switcher.chooseForTesting(aside: true)

		#expect(open.delegate.documentWindows.count == 2,
		        "⌥ in the switcher opened in place")
		#expect(open.delegate.documents.count == 3)
	}

	/// The filter narrows every group, not only the first.
	@Test func theFilterNarrowsAcrossEveryGroup() throws {
		let open = try inThePlace(NSRect(x: 100, y: 100, width: 1200, height: 800))
		open.delegate.open(open.files.first)
		let groups = open.delegate.switcherGroups()
		#expect(groups.count >= 2, "there is only one group to filter")

		let switcher = DocumentSwitcher.Switcher(groups)
		switcher.loadView()
		switcher.setFilter("walter")
		let kept = switcher.shownForTesting
		#expect(kept.contains("walter-take-2"),
		        "the unopened take was filtered out of \(kept)")
		#expect(!kept.contains("mia-take-1"), "the filter kept \(kept)")
		// And a heading with nothing left under it goes with its rows.
		for (index, row) in kept.enumerated() where row.hasPrefix("# ") {
			#expect(index + 1 < kept.count && !kept[index + 1].hasPrefix("# "),
			        "an empty heading is left in \(kept)")
		}

		// A filter that matches nothing leaves nothing, rather than leaving the
		// headings behind.
		switcher.setFilter("zzzzz")
		#expect(switcher.shownForTesting.isEmpty,
		        "\(switcher.shownForTesting) survived a filter that matches nothing")
	}

	/// ⇧⌘P opens the same list, anchored on the window's own bar.
	@Test func theKeyboardOpensTheSameList() throws {
		let open = try inThePlace(NSRect(x: 100, y: 100, width: 1200, height: 800))
		open.delegate.open(open.files.first)
		defer { DocumentSwitcher.close() }

		open.delegate.showDocumentPalette(nil)
		// It is anchored under the capsule of the bar the window owns, so the
		// list it shows is the list the capsule shows.
		let listed = DocumentSwitcher.filterForTesting("")
		#expect(!listed.isEmpty, "⇧⌘P showed nothing")
		#expect(listed.contains("walter-take-2"),
		        "⇧⌘P shows a different list from the capsule: \(listed)")
	}

	/// Closing the document on screen leaves the next one in its place, in the
	/// same window, rather than closing the window on four takes at once.
	@Test func closingADocumentLeavesTheWindowAndTheNextDocument() throws {
		let place = NSRect(x: 180, y: 130, width: 1220, height: 770)
		let open = try inThePlace(place)
		let window = try #require(open.composer.window)
		open.delegate.open(open.files.first)
		#expect(open.delegate.documents.count == 2)

		open.delegate.closeDocument(nil)

		#expect(open.delegate.showing === open.composer,
		        "nothing came back after the take closed")
		#expect(open.delegate.documents.count == 1,
		        "the take is still open: \(open.delegate.documents.count) documents")
		#expect(open.delegate.documentWindows.count == 1, "the window closed too")
		#expect(window.frame == place)

		// And the last one takes the window with it.
		open.delegate.closeDocument(nil)
		#expect(open.delegate.documents.isEmpty)
		#expect(open.delegate.documentWindows.isEmpty,
		        "an empty window is left over")
	}

	// MARK: - What the switch must not lose

	/// The bar is the window's: one of them, the same object across a switch,
	/// with its name changed rather than rebuilt.
	@Test func theBarBelongsToTheWindowAndUpdates() throws {
		let open = try inThePlace(NSRect(x: 100, y: 100, width: 1200, height: 800))
		let place = try #require(open.delegate.placesForTesting.first)
		let bar = place.bar
		#expect(bar.capsuleForTesting.spans.project.upperBound > 0)

		open.delegate.open(open.files.first)
		#expect(place.bar === bar, "the bar was replaced rather than updated")
		// One bar in the window, not one per document.
		var found = 0
		func count(_ view: NSView) {
			if view is DocumentBar { found += 1 }
			for sub in view.subviews { count(sub) }
		}
		place.window.contentView.map(count)
		#expect(found == 1, "\(found) bars in the window")
	}

	/// Which rail item is lit is the document's, and it comes back with it.
	///
	/// This is the state that would go missing quietly: the view tree is kept
	/// whole between turns on screen, so this passes by construction — and it is
	/// asserted because "by construction" is exactly what stops being true when
	/// somebody rebuilds the content view instead of re-parenting it.
	@Test func aDocumentKeepsWhatItWasLookingAt() throws {
		let open = try inThePlace(NSRect(x: 100, y: 100, width: 1200, height: 800))
		// The project is looking at its Text page.
		open.composer.railForTesting.clickForTesting(2)
		#expect(open.composer.modeForTesting == .text)

		open.delegate.open(open.files.first)
		let take = try #require(open.delegate.showing as? MainWindowController)
		// And the take at its Words pane.
		take.railForTesting.clickForTesting(2)
		let words = take.panesForTesting?.current

		open.delegate.reveal(open.composer)
		#expect(open.composer.modeForTesting == .text,
		        "the project came back on a different page")
		#expect(open.composer.railForTesting.selected == 2,
		        "the project's rail lost which item was lit")

		open.delegate.reveal(take)
		#expect(take.panesForTesting?.current === words,
		        "the take came back on a different pane")
		#expect(take.railForTesting.selected == 2,
		        "the take's rail lost which item was lit")
	}

	/// And the keyboard comes back where it was, which the view tree does *not*
	/// carry: a first responder belongs to the window, and swapping the content
	/// view drops it.
	@Test func theKeyboardComesBackWhereItWas() throws {
		let open = try inThePlace(NSRect(x: 100, y: 100, width: 1200, height: 800))
		let window = try #require(open.composer.window)
		open.delegate.open(open.files.first)
		let take = try #require(open.delegate.showing as? MainWindowController)
		window.layoutIfNeeded()

		// Whatever the take opened with — its timeline, by design.
		let was = window.firstResponder
		open.delegate.reveal(open.composer)
		open.delegate.reveal(take)
		let now = window.firstResponder
		#expect(now === was || now is TimelineView,
		        "the keyboard came back on \(type(of: now as Any))")
	}
}
