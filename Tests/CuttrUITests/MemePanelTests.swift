import AppKit
import CuttrKit
import Testing
@testable import CuttrUI

/// The meme panel and the library section it fills.
///
/// Nothing here goes near GIPHY: the panel is handed results as though a search
/// had returned them, which is the only part of it a test can have an opinion
/// about. What is being checked is what the two launch crashes this program has
/// had were — that assembling the views and putting content through them does
/// not make AppKit throw — plus the two things a person would notice
/// immediately if they were wrong: the attribution the terms require, and a
/// downloaded meme being selected in the library rather than merely present.
@Suite @MainActor struct MemePanelTests {

	private func results() -> [MemeResult] {
		[
			MemeResult(provider: .giphy, id: "one", title: "Facepalm GIF by Cartoon Hangover",
			           page: URL(string: "https://giphy.com/gifs/one"),
			           video: URL(string: "https://media.giphy.com/media/one/giphy.mp4")!,
			           size: CGSize(width: 480, height: 270)),
			MemeResult(provider: .giphy, id: "two", title: "",
			           page: nil,
			           video: URL(string: "https://media.giphy.com/media/two/giphy.mp4")!),
		]
	}

	private func panel() -> MemePanel {
		let panel = MemePanel(download: { _ in "facepalm" }, onAdded: { _ in })
		panel.loadView()
		return panel
	}

	@Test func itShowsWhatCameBack() {
		_ = NSApplication.shared
		let panel = self.panel()
		panel.present(results())
		#expect(panel.shown.count == 2)
		#expect(panel.message.contains("2"))
		panel.view.layoutSubtreeIfNeeded()
	}

	@Test func theServicesMarkIsAlwaysShown() {
		// Both services require it wherever their results are, and it is shown
		// whether or not there are any — the panel is where the API is being
		// used either way.
		_ = NSApplication.shared
		#expect(panel().attribution == MemeProvider.giphy.attribution)
	}

	@Test func nothingCanBeAddedUntilSomethingIsChosen() {
		_ = NSApplication.shared
		let panel = self.panel()
		#expect(!panel.canAdd)
		panel.present(results())
		// The first is chosen for you: a grid with nothing selected in it means
		// pressing Return does nothing and no one can say why.
		#expect(panel.canAdd)
		panel.choose(1)
		#expect(panel.canAdd)
	}

	@Test func anEmptySearchSaysSoRatherThanLookingBroken() {
		_ = NSApplication.shared
		let panel = self.panel()
		panel.present([])
		#expect(!panel.message.isEmpty)
		#expect(!panel.canAdd)
	}

	@Test func theGridIsRebuiltWhenItsPaneChangesWidth() {
		// The tiles flow, so the number of rows — and the height the scroll
		// view is told about — follows the width. This is the arithmetic, not
		// the drawing.
		_ = NSApplication.shared
		let grid = MemeGrid()
		grid.setFrameSize(NSSize(width: 720, height: 400))
		grid.show(results() + results() + results())
		let wide = grid.intrinsicContentSize.height
		grid.setFrameSize(NSSize(width: 200, height: 400))
		#expect(grid.intrinsicContentSize.height > wide)
	}

	@Test func itGoesUpAsASheetAndComesDownAgain() {
		// Both of this program's launch crashes were AppKit refusing something
		// a view did while it was being put into a window, which is a moment no
		// amount of assembling a view controller alone ever reaches.
		_ = NSApplication.shared
		let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
		                      styleMask: [.titled], backing: .buffered, defer: false)
		parent.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
		MemePanel.present(over: parent.contentView!, download: { _ in "facepalm" },
		                  onAdded: { _ in })
		let sheet = parent.attachedSheet
		#expect(sheet != nil)
		if let sheet { parent.endSheet(sheet) }
	}

	@Test func settingsShowsWhereTheFileIs() {
		// It reads the real file — which may or may not be there — and must not
		// write one. Assembling it is the whole test.
		_ = NSApplication.shared
		let sheet = SettingsSheet()
		sheet.loadView()
		sheet.set("not-a-real-key", for: .giphy)
		sheet.view.layoutSubtreeIfNeeded()
	}
}

/// Memes in the library.
@Suite @MainActor struct MemeLibraryTests {

	private func vocabulary() -> ComposeDocument.Vocabulary {
		var found = ComposeDocument.Vocabulary()
		found.takeNames = ["take-01", "facepalm", "shrug"]
		found.memeTakes = ["facepalm", "shrug"]
		found.items = [
			.init(take: "take-01", slug: "intro", name: "Intro", tags: [], length: 4,
			      reference: "intro"),
			.init(take: "facepalm", slug: "facepalm", name: "Facepalm", tags: [], length: 2.4,
			      reference: "facepalm"),
			.init(take: "shrug", slug: "shrug", name: "Shrug", tags: [], length: 1.8,
			      reference: "shrug"),
		]
		return found
	}

	private func table(in view: NSView) -> NSTableView? {
		for subview in view.subviews {
			if let table = subview as? NSTableView { return table }
			if let found = table(in: subview) { return found }
		}
		return nil
	}

	@Test func memesAreOneSectionAndNotOneHeadingEach() throws {
		_ = NSApplication.shared
		let library = LibraryView()
		library.reload(vocabulary())
		let table = try #require(self.table(in: library))
		// take-01 and its clip, then one memes heading with two under it.
		#expect(table.numberOfRows == 5)
		library.fold("memes")
		#expect(table.numberOfRows == 3)
		library.fold("memes")
		#expect(table.numberOfRows == 5)
	}

	@Test func aNewMemeIsSelectedRatherThanMerelyPresent() throws {
		_ = NSApplication.shared
		let library = LibraryView()
		library.reload(vocabulary())
		let table = try #require(self.table(in: library))
		library.reveal("shrug")
		#expect(table.selectedRow >= 0)
		#expect(table.numberOfRows > table.selectedRow)
	}

	@Test func revealingOpensTheSectionAndClearsTheFilter() throws {
		// A row that is real but folded away, or filtered out, looks exactly
		// like a download that did not work.
		_ = NSApplication.shared
		let library = LibraryView()
		library.reload(vocabulary())
		let table = try #require(self.table(in: library))
		library.fold("memes")
		library.reveal("shrug")
		#expect(table.numberOfRows == 5)
		#expect(table.selectedRow == 4)
	}
}
