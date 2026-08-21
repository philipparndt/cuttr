import AppKit
import CuttrCompose
import CuttrKit
import Testing
@testable import CuttrUI

/// Copying an entry and everything hung on it: the gesture and the two keys.
///
/// What a copy *is* belongs to ``CuttrCompose/Project`` and is tested there.
/// These are about the three ways of asking for one — ⌥ with the mouse, ⌘C and
/// ⌘V, and the menu on a row — and about what the pasteboard carries between
/// them, which is the only part of it that leaves this program.
@Suite @MainActor struct CopyingTests {

	private func caption(_ text: String) -> Overlay {
		Overlay(kind: .text(text, style: nil), appearances: [], arrival: .cut, departure: .cut)
	}

	private func programme() -> Project {
		Project(timeline: [
			TimelineEntry(clip: ClipReference("one"), label: "shot",
			              overlays: [caption("Hello")],
			              sounds: [Sound(file: "sting.wav", span: nil)]),
			TimelineEntry(group: "end", entries: [TimelineEntry(clip: ClipReference("four"))]),
		])
	}

	private func panel(_ project: Project) -> ProgrammePanel {
		_ = NSApplication.shared
		let panel = ProgrammePanel(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
		panel.reload(project, vocabulary: ComposeDocument.Vocabulary())
		panel.layoutSubtreeIfNeeded()
		return panel
	}

	private func board(_ name: String) -> NSPasteboard {
		let board = NSPasteboard(name: .init("copying-test-\(name)-\(UUID().uuidString)"))
		board.clearContents()
		return board
	}

	// MARK: - ⌘C

	/// What goes on the pasteboard is the file's own text, and it comes back as
	/// the entry it was — the caption and the sting inside it included.
	@Test func theCopyOnThePasteboardIsWhatTheFileWouldWrite() throws {
		let panel = self.panel(programme())
		panel.selectRow(0)
		let board = self.board("write")
		#expect(panel.write(board))

		let text = try #require(board.string(forType: ProgrammePanel.entriesType))
		#expect(text.hasPrefix("  - clip: one"))
		// The same bytes on plain text, so ⌘V in the project file's own editor
		// puts the lines in by hand.
		#expect(board.string(forType: .string) == text)

		let back = try ProjectReader.read("timeline:\n" + text).timeline
		#expect(back == [programme().timeline[0]])
	}

	/// A section carries its contents, because the pasteboard carries the entry
	/// and the entry *is* its contents.
	@Test func copyingASectionCarriesWhatIsInIt() throws {
		let panel = self.panel(programme())
		// Row 0 is the clip, 1 its caption, 2 its sound; the section is row 3.
		panel.selectRow(3)
		let board = self.board("section")
		#expect(panel.write(board))
		let text = try #require(board.string(forType: ProgrammePanel.entriesType))
		let back = try ProjectReader.read("timeline:\n" + text).timeline
		#expect(back == [programme().timeline[1]])
	}

	/// A caption is a row in this tree too, and it carries the path of the entry
	/// it hangs on. ⌘C with one selected must not copy the shot it belongs to.
	@Test func copyingWithACaptionSelectedCopiesNothing() {
		let panel = self.panel(programme())
		// Row 0 is the clip, row 1 the caption written inside it.
		panel.selectRow(1)
		let board = self.board("carried")
		#expect(panel.write(board) == false)
	}

	@Test func copyingWithNothingSelectedCopiesNothing() {
		let panel = self.panel(programme())
		panel.selectOutput()
		#expect(panel.write(board("empty")) == false)
	}

	// MARK: - ⌘V

	/// Pasting is adding, so it lands where the `＋` button's things land: after
	/// the selected entry.
	@Test func pastingPutsItAfterTheSelectedEntry() {
		let panel = self.panel(programme())
		panel.selectRow(0)
		let board = self.board("paste")
		#expect(panel.write(board))

		var written: Project?
		panel.onChange = { written = $0 }
		#expect(panel.paste(from: board))
		#expect(written?.timeline.map { $0.source.description } == ["one", "one", "@end"])
		// And the name is freed, or a caption hung on `@shot` would come to
		// cover both of them and everything in between.
		#expect(written?.timeline.map(\.label) == ["shot", "shot-2", nil])
		#expect(written?.timeline[1].overlays.count == 1)
		#expect(written?.timeline[1].sounds.map(\.file) == ["sting.wav"])
	}

	/// A section is a place to put things, so a paste with one selected goes
	/// inside it — the same rule adding follows.
	@Test func pastingWithASectionSelectedPutsItInside() {
		let panel = self.panel(programme())
		panel.selectRow(0)
		let board = self.board("into-section")
		#expect(panel.write(board))

		var written: Project?
		panel.onChange = { written = $0 }
		panel.selectRow(3)     // the section
		#expect(panel.paste(from: board))
		#expect(written?.rows.map(\.entry.source.description) == ["one", "@end", "four", "one"])
	}

	/// Nothing selected has to mean something, and the end of the programme is
	/// the only answer that is not a guess about which row was meant.
	@Test func pastingWithNothingSelectedGoesOnTheEnd() {
		let panel = self.panel(programme())
		panel.selectRow(0)
		let board = self.board("nothing-selected")
		#expect(panel.write(board))

		var written: Project?
		panel.onChange = { written = $0 }
		panel.selectOutput()
		#expect(panel.paste(from: board))
		#expect(written?.timeline.map { $0.source.description } == ["one", "@end", "one"])
	}

	/// Lines lifted out of a project file are a timeline, so they paste.
	@Test func textFromTheFileItselfPastes() {
		let panel = self.panel(Project())
		let board = self.board("from-the-file")
		let item = NSPasteboardItem()
		item.setString("  - clip: intro\n    as:   opening\n", forType: .string)
		board.writeObjects([item])

		var written: Project?
		panel.onChange = { written = $0 }
		#expect(panel.paste(from: board))
		#expect(written?.timeline.first?.source.description == "intro")
		#expect(written?.timeline.first?.label == "opening")
	}

	/// And a sentence copied out of some other program is not an entry naming a
	/// clip nobody has.
	@Test func textThatIsNotATimelinePastesNothing() {
		let panel = self.panel(programme())
		let board = self.board("junk")
		let item = NSPasteboardItem()
		item.setString("nothing to do with any of this", forType: .string)
		board.writeObjects([item])

		var written: Project?
		panel.onChange = { written = $0 }
		#expect(panel.paste(from: board) == false)
		#expect(panel.canPaste(from: board) == false)
		#expect(written == nil)
	}

	// MARK: - The keys, and the path they take

	/// ⌘C and ⌘V are the menu's, and the menu aims them down the responder
	/// chain with no target — so the panel the tree is in has to answer them.
	/// This is the whole route: the item's action, and the object that responds
	/// to it.
	@Test func theEditMenuAimsCopyAndPasteAtWhoeverHasTheSelection() throws {
		_ = NSApplication.shared
		let edit = try #require(MainMenu.build().items
			.compactMap(\.submenu).first { $0.title == "Edit" })
		let copyItem = try #require(edit.items.first { $0.title == "Copy" })
		let pasteItem = try #require(edit.items.first { $0.title == "Paste" })
		#expect(copyItem.action == #selector(NSText.copy(_:)))
		#expect(copyItem.keyEquivalent == "c")
		#expect(copyItem.target == nil, "a target here would stop it reaching the tree")
		#expect(pasteItem.action == #selector(NSText.paste(_:)))
		#expect(pasteItem.keyEquivalent == "v")

		let panel = self.panel(programme())
		#expect(panel.responds(to: #selector(NSText.copy(_:))))
		#expect(panel.responds(to: #selector(NSText.paste(_:))))
	}

	/// Grey rather than doing nothing when pressed: Copy needs an entry
	/// selected, and Paste needs something on the pasteboard.
	@Test func theMenuIsGreyWhenThereIsNothingToCopy() {
		let panel = self.panel(programme())
		let item = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)),
		                      keyEquivalent: "c")
		panel.selectOutput()
		#expect(panel.validateMenuItem(item) == false)
		panel.selectRow(0)
		#expect(panel.validateMenuItem(item))

		// And everything else the panel is the target of is its own menu, built
		// for the row it is shown on.
		let other = NSMenuItem(title: "Add", action: nil, keyEquivalent: "")
		#expect(panel.validateMenuItem(other))
	}

	// MARK: - ⌥ with the mouse

	/// The gesture, without a mouse: AppKit narrows the mask to the copy while
	/// ⌥ is held, and that mask is what the cursor is showing.
	@Test func optionIsWhatMakesADragACopy() {
		#expect(ProgrammePanel.copies([.copy]))
		#expect(ProgrammePanel.copies([.move, .copy]) == false)
		#expect(ProgrammePanel.copies([.move]) == false)
		#expect(ProgrammePanel.copies([]) == false)
	}

	/// The drop itself: the same machinery a move uses, without the removal.
	@Test func aCopyingDropLeavesTheOriginalWhereItWas() {
		let panel = self.panel(programme())
		var written: Project?
		panel.onChange = { written = $0 }

		let board = self.board("drag")
		let item = NSPasteboardItem()
		item.setString("0", forType: ProgrammePanel.entryType)
		board.writeObjects([item])
		#expect(panel.dropItems(from: board, into: [1], at: 0, copying: true))

		#expect(written?.rows.map(\.entry.source.description) == ["one", "@end", "one", "four"])
		#expect(written?.entry(at: [1, 0])?.label == "shot-2")
		#expect(written?.entry(at: [1, 0])?.overlays.count == 1)
	}

	/// And the same drop without ⌥ is still a move, which is what it always was.
	@Test func aDropWithoutOptionStillMoves() {
		let panel = self.panel(programme())
		var written: Project?
		panel.onChange = { written = $0 }

		let board = self.board("move")
		let item = NSPasteboardItem()
		item.setString("0", forType: ProgrammePanel.entryType)
		board.writeObjects([item])
		#expect(panel.dropItems(from: board, into: [1], at: 0))
		#expect(written?.rows.map(\.entry.source.description) == ["@end", "one", "four"])
	}

	// MARK: - The row menu

	/// Duplicate, where the pointer already is — and the copy is named rather
	/// than being a second answer to `@shot`.
	@Test func theRowMenuDuplicatesTheRowItWasOpenedOn() throws {
		let panel = self.panel(programme())
		var written: Project?
		panel.onChange = { written = $0 }

		let menu = try #require(panel.rowMenu(0))
		let index = try #require(menu.items.firstIndex { $0.title == "Duplicate" })
		menu.performActionForItem(at: index)

		#expect(written?.timeline.map { $0.source.description } == ["one", "one", "@end"])
		#expect(written?.timeline.map(\.label) == ["shot", "shot-2", nil])
		#expect(written?.timeline[1].sounds.map(\.file) == ["sting.wav"])
	}

	/// A caption's row has no Duplicate on it — the pair of arrows and the minus
	/// beside the tree are what an overlay is re-ordered and removed with, and
	/// duplicating one is the `＋`'s business.
	@Test func theRowMenuOfACaptionOffersNoDuplicate() throws {
		let panel = self.panel(programme())
		let menu = try #require(panel.rowMenu(1))
		#expect(!menu.items.contains { $0.title == "Duplicate" })
	}
}
