import AppKit
import CuttrCompose
import CuttrKit
import Testing
@testable import CuttrUI

/// The panels, assembled and reloaded.
///
/// Nothing here checks what anything looks like. What it checks is that putting
/// a project into each panel does not make AppKit throw — which is the way both
/// of this program's launch crashes announced themselves, and neither was found
/// without somebody sitting in front of it.
@Suite @MainActor struct PanelTests {

	private func project() -> Project {
		Project(
			takes: ["take-01.cuttr"],
			output: Output(width: 1920, height: 1080, framesPerSecond: 25,
			               file: "out.mov", audio: AudioTarget(), matchReference: "intro"),
			timeline: [
				TimelineEntry(clip: ClipReference("intro")),
				TimelineEntry(group: "middle", entries: [
					TimelineEntry(clip: ClipReference("demo")),
					try! TimelineEntry(query: "#b-roll"),
				]),
				TimelineEntry(list: [ClipReference("a"), ClipReference("b")], transition: 0.5),
				TimelineEntry(card: Card(duration: 4, fill: .gradient(
					top: RGBA(hex: "#202030")!, bottom: RGBA(hex: "#050508")!)), label: "titles"),
			],
			overlays: [
				Overlay(kind: .text("Installing", style: "lower-third"),
				        span: .clips(from: ClipReference("intro"), to: ClipReference("demo"))),
				Overlay(kind: .spinner(Spinner(words: [SpinnerWord("one"), SpinnerWord("two", duration: 2)])),
				        spans: [.times(from: 1, to: 4), .marks(from: .group("middle"), to: .group("middle"))],
				        anchor: "mia-eye", offset: CGPoint(x: 0.02, y: -0.18)),
			],
			sounds: [
				Sound(file: "music/opening.wav",
				      span: .marks(from: .group("titles"), to: .group("titles")),
				      gain: -6, arrival: .fade(over: 0.5), departure: .fade(over: 1.5),
				      ducks: 8),
				Sound(file: "sting.wav", span: .times(from: 12, to: 13)),
			])
	}

	private func vocabulary() -> ComposeDocument.Vocabulary {
		var found = ComposeDocument.Vocabulary()
		found.clips = ["intro", "demo"]
		found.tags = ["b-roll"]
		found.anchors = ["mia-eye"]
		found.groups = ["middle"]
		found.takeNames = ["take-01"]
		found.items = [
			.init(take: "take-01", slug: "intro", name: "Intro", tags: ["b-roll"],
			      length: 4, reference: "intro"),
			.init(take: "take-01", slug: "demo", name: "Demo", tags: [],
			      length: 9, reference: "demo"),
		]
		return found
	}

	/// Every selection the panel can be asked to show, one after another — the
	/// grid is thrown away and remade each time, and that is where it broke.
	@Test func propertiesShowEverySelection() {
		_ = NSApplication.shared
		let panel = PropertiesPanel()
		let project = self.project()
		let selections: [ProjectSelection] = [
			.output, .entry([0]), .entry([1]), .entry([1, 0]), .entry([1, 1]), .entry([2]),
			.entry([3]), .overlay(.project(0)), .overlay(.project(1)), .sound(0), .sound(1), .output,
			// Gone: a selection that outlived the thing it named.
			.entry([9]), .overlay(.project(9)), .sound(9),
		]
		for selection in selections {
			panel.reload(project, vocabulary: vocabulary(), selection: selection)
		}
		panel.layoutSubtreeIfNeeded()
	}

	@Test func programmeShowsTheTree() {
		_ = NSApplication.shared
		let panel = ProgrammePanel()
		panel.reload(project(), vocabulary: vocabulary())
		panel.reload(Project(), vocabulary: ComposeDocument.Vocabulary())
		panel.reload(project(), vocabulary: vocabulary())
		panel.layoutSubtreeIfNeeded()
	}

	@Test func libraryListsTheMaterial() {
		_ = NSApplication.shared
		let library = LibraryView()
		library.reload(vocabulary())
		library.reload(ComposeDocument.Vocabulary())
		library.layoutSubtreeIfNeeded()
	}

	@Test func theInspectorPutsThemTogether() {
		_ = NSApplication.shared
		let inspector = ProjectInspector()
		inspector.reload(project(), vocabulary: vocabulary())
		inspector.insert(reference: "#b-roll")
		inspector.layoutSubtreeIfNeeded()
	}
}

/// The library folds its sections away.
@Suite @MainActor struct LibraryFoldingTests {

	private func vocabulary() -> ComposeDocument.Vocabulary {
		var found = ComposeDocument.Vocabulary()
		found.takeNames = ["take-01"]
		found.tags = ["b-roll"]
		found.anchors = ["mia-eye"]
		found.items = [
			.init(take: "take-01", slug: "intro", name: "Intro", tags: ["b-roll"],
			      length: 4, reference: "intro"),
			.init(take: "take-01", slug: "demo", name: "Demo", tags: [],
			      length: 9, reference: "demo"),
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

	@Test func foldingAHeadingHidesWhatIsUnderIt() throws {
		_ = NSApplication.shared
		let library = LibraryView()
		library.reload(vocabulary())
		let table = try #require(self.table(in: library))
		let all = table.numberOfRows

		// The take's heading is the first row; folding it takes its clips away
		// and leaves everything else.
		library.fold("take-01")
		#expect(table.numberOfRows == all - 2)
		library.fold("take-01")
		#expect(table.numberOfRows == all)
	}
}

/// What the space bar means depends on where the keyboard is.
@Suite @MainActor struct ClipTableFocusTests {

	@Test func theListKnowsWhetherItHasTheKeyboard() throws {
		_ = NSApplication.shared
		let clips = ClipTable()
		let other = NSTextField(string: "")
		let holder = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
		clips.frame = holder.bounds
		holder.addSubview(clips)
		holder.addSubview(other)

		let window = NSWindow(contentRect: holder.bounds, styleMask: [.titled],
		                      backing: .buffered, defer: false)
		window.contentView = holder
		window.makeKeyAndOrderFront(nil)

		func table(in view: NSView) -> NSTableView? {
			for subview in view.subviews {
				if let found = subview as? NSTableView { return found }
				if let found = table(in: subview) { return found }
			}
			return nil
		}
		let list = try #require(table(in: clips))

		window.makeFirstResponder(other)
		#expect(!clips.hasKeyboard, "the list claims the keyboard while a field has it")
		window.makeFirstResponder(list)
		#expect(clips.hasKeyboard)
	}
}

/// What a row on the programme says about itself.
@Suite @MainActor struct EntryRowTests {

	/// A trimmed placement and a whole one look the same otherwise, and the
	/// same clip twice in a section is usually two different lengths of it.
	@Test func aTrimmedPlacementSaysSo() {
		let whole = TimelineEntry(clip: ClipReference("clip-4"))
		#expect(ProgrammePanel.EntryRow.trimmed(whole) == nil)

		let head = TimelineEntry(clip: ClipReference("clip-4"), trim: (1.5, 0))
		#expect(ProgrammePanel.EntryRow.trimmed(head) == "head −00:01.500")

		let tail = TimelineEntry(clip: ClipReference("clip-4"), trim: (0, 0.4))
		#expect(ProgrammePanel.EntryRow.trimmed(tail) == "tail −00:00.400")

		let both = TimelineEntry(clip: ClipReference("clip-4"), trim: (1.5, 0.4))
		#expect(ProgrammePanel.EntryRow.trimmed(both) == "head −00:01.500  tail −00:00.400")
	}

	/// How it arrives, for everything that is not a cut — and a list of forty
	/// cuts saying `cut` forty times says nothing.
	@Test func howItArrivesIsOnTheRow() {
		let cut = TimelineEntry(clip: ClipReference("clip-4"))
		#expect(ProgrammePanel.EntryRow.arrival(cut) == nil)

		let dissolve = TimelineEntry(clip: ClipReference("clip-4"), transition: 0.5)
		#expect(ProgrammePanel.EntryRow.arrival(dissolve) == "⤫ dissolve 0.5s")

		let dip = TimelineEntry(clip: ClipReference("clip-4"),
		                        transition: Transition(.dipToBlack, seconds: 1))
		#expect(ProgrammePanel.EntryRow.arrival(dip) == "⤫ dip to black 1s")

		// A cut written with a length beside it is still a cut.
		let odd = TimelineEntry(clip: ClipReference("clip-4"),
		                        transition: Transition(.cut, seconds: 2))
		#expect(ProgrammePanel.EntryRow.arrival(odd) == nil)
	}
}

/// The take's own grade, which had no controls at all until now.
@Suite @MainActor struct LookPanelTests {

	@Test func draggingASliderWritesTheLook() {
		_ = NSApplication.shared
		let panel = LookPanel()
		var written: [(Look, Bool)] = []
		panel.onChange = { written.append(($0, $1)) }
		panel.show(Look(exposure: 0.5))

		panel.set("exposure", to: -1.25)
		#expect(panel.current.exposure == -1.25)
		panel.set("saturation", to: 1.4)
		panel.set("contrast", to: 0.9)
		panel.set("temperature", to: 800)
		panel.set("tint", to: -12)
		#expect(panel.current == Look(exposure: -1.25, temperature: 800, tint: -12,
		                              saturation: 1.4, contrast: 0.9))
		#expect(written.count == 5)
		// Showing what the document has does not write anything back.
		panel.show(Look(exposure: 2))
		#expect(written.count == 5)
		#expect(panel.current.exposure == 2)
	}

	/// Reset is "the footage as it was shot" — but the matched gain is a
	/// measurement, not a decision, and throwing it away means analysing again.
	@Test func resetKeepsWhatWasMeasured() {
		_ = NSApplication.shared
		let panel = LookPanel()
		var last: Look?
		panel.onChange = { look, _ in last = look }
		panel.show(Look(profile: "camera-a", exposure: 1, saturation: 1.5,
		                gain: [1.1, 1, 0.9]))
		panel.reset()
		#expect(last?.exposure == 0)
		#expect(last?.saturation == 1)
		#expect(last?.profile == nil)
		#expect(last?.gain == [1.1, 1, 0.9])
	}
}

/// Right-clicking a clip, in the two lists that show one.
@Suite @MainActor struct OpenInTakeTests {

	private func vocabulary() -> ComposeDocument.Vocabulary {
		var found = ComposeDocument.Vocabulary()
		found.takeNames = ["mia-take-1"]
		found.items = [
			.init(take: "mia-take-1", slug: "clip-2", name: "", tags: [],
			      start: 196.46, length: 53.2, reference: "clip-2"),
		]
		return found
	}

	/// The library names the clip and the take it is in, and hands back the
	/// item — with the moment it starts, so nobody has to read the take again.
	@Test func theLibraryOffersTheClipUnderThePointer() {
		_ = NSApplication.shared
		let library = LibraryView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
		library.reload(vocabulary())
		library.layoutSubtreeIfNeeded()
		var opened: ComposeDocument.Vocabulary.Item?
		library.onOpenInTake = { opened = $0 }

		guard let menu = library.rowMenu(for: click(in: library, at: NSPoint(x: 40, y: 40))) else {
			// The row may be laid out elsewhere in a window this small; what
			// must not happen is a menu on nothing.
			#expect(opened == nil)
			return
		}
		#expect(menu.items.first?.title.contains("clip-2") == true)
		#expect(menu.items.first?.title.contains("mia-take-1") == true)
		menu.performActionForItem(at: 0)
		#expect(opened?.slug == "clip-2")
		#expect(abs((opened?.start ?? 0) - 196.46) < 0.001)
	}

	/// And an entry on the programme hands back its path, which is what tells
	/// one use of a clip from another.
	@Test func theProgrammeOffersThePlacementUnderThePointer() {
		_ = NSApplication.shared
		let panel = ProgrammePanel(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
		panel.reload(Project(timeline: [
			TimelineEntry(clip: ClipReference("clip-1")),
			TimelineEntry(clip: ClipReference("clip-2")),
		]), vocabulary: vocabulary())
		panel.layoutSubtreeIfNeeded()
		var path: [Int]?
		panel.onOpenInTake = { path = $0 }

		guard let menu = panel.outlineMenu(for: click(in: panel, at: NSPoint(x: 40, y: 40)))
		else { return }
		menu.performActionForItem(at: 0)
		#expect(path != nil)
	}

	private func click(in view: NSView, at point: NSPoint) -> NSEvent {
		NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [],
		                   timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
		                   clickCount: 1, pressure: 1)!
	}
}

/// Delete, in the four lists that have a minus button.
@Suite @MainActor struct DeleteKeyTests {

	private func press(_ character: Character) -> NSEvent {
		NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
		                 windowNumber: 0, context: nil, characters: String(character),
		                 charactersIgnoringModifiers: String(character),
		                 isARepeat: false, keyCode: 51)!
	}

	@Test func bothDeletesCountAndNothingElseDoes() {
		_ = NSApplication.shared
		#expect(isDelete(press(Character(UnicodeScalar(NSDeleteCharacter)!))))
		#expect(isDelete(press(Character(UnicodeScalar(NSBackspaceCharacter)!))))
		#expect(isDelete(press(Character(UnicodeScalar(NSDeleteFunctionKey)!))))
		#expect(isDelete(press("x")) == false)
		#expect(isDelete(press(" ")) == false)
	}

	/// The programme: delete takes the selected entry off it.
	@Test func deleteTakesAnEntryOffTheProgramme() {
		_ = NSApplication.shared
		let panel = ProgrammePanel(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
		panel.reload(Project(timeline: [
			TimelineEntry(clip: ClipReference("one")),
			TimelineEntry(clip: ClipReference("two")),
		]), vocabulary: ComposeDocument.Vocabulary())
		panel.layoutSubtreeIfNeeded()
		var written: Project?
		panel.onChange = { written = $0 }

		// Selecting the first row the way a click would.
		panel.selectRow(0)
		panel.deleteSelected()
		#expect(written?.timeline.count == 1)
		#expect(written?.timeline.first?.source.description == "two")
	}

	/// And nothing happens when nothing is selected, rather than the first row
	/// quietly disappearing.
	@Test func deleteWithNothingSelectedDoesNothing() {
		_ = NSApplication.shared
		let panel = ProgrammePanel(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
		panel.reload(Project(timeline: [TimelineEntry(clip: ClipReference("one"))]),
		             vocabulary: ComposeDocument.Vocabulary())
		var written: Project?
		panel.onChange = { written = $0 }
		panel.selectOutput()
		panel.deleteSelected()
		#expect(written == nil)
	}
}

/// A project that has not been saved yet.
///
/// Everything a project points at is relative to where it sits, so an untitled
/// one used to resolve to nothing at all — which greys the render button and
/// empties the preview without saying why. A programme made of nothing but the
/// file it is written in has nowhere to point, and needs nowhere.
@Suite @MainActor struct UntitledProjectTests {

	private func intro() -> Project {
		var project = Project(timeline: [
			TimelineEntry(source: .card(Card(duration: 1.1)), label: "intro"),
		])
		project.scenes["intro"] = Scene(parts: [
			Scene.Part(content: .text("Hello", style: nil), keys: [Scene.Key(t: 0, opacity: 1)]),
		])
		project.overlays = [
			Overlay(kind: .scene("intro", with: [:]),
			        span: .marks(from: .group("intro"), to: .group("intro"))),
		]
		return project
	}

	@Test func anIntroScreenResolvesBeforeItIsSaved() {
		let document = ComposeDocument()
		document.apply(intro())
		#expect(document.resolved != nil, "an untitled card-and-scene project did not resolve")
		#expect(abs((document.resolved?.duration ?? 0) - 1.1) < 0.001)
		#expect(document.problem == nil)
	}

	/// And one that does point at something says what to do rather than going
	/// quiet.
	@Test func anUnsavedProjectWithTakesSaysWhy() {
		let document = ComposeDocument()
		var project = intro()
		project.takes = ["takes/one.cuttr"]
		document.apply(project)
		#expect(document.resolved == nil)
		#expect(document.problem?.contains("Save the project") == true)
	}
}

/// What a row says about a stretch of programme that has something on it.
@Suite @MainActor struct CarriedTests {

	private func panel() -> ProgrammePanel {
		_ = NSApplication.shared
		let panel = ProgrammePanel(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
		var project = Project(timeline: [
			TimelineEntry(source: .card(Card(duration: 1.1)), label: "intro"),
			TimelineEntry(source: .card(Card(duration: 1.1)), label: "next"),
			TimelineEntry(source: .card(Card(duration: 1.1))),
		])
		project.scenes["card"] = Scene(parts: [])
		project.overlays = [
			Overlay(kind: .scene("card", with: [:]),
			        span: .marks(from: .group("intro"), to: .group("intro"))),
			Overlay(kind: .text("hello", style: nil),
			        span: .within(.group("next"), from: 0, to: 1)),
		]
		panel.reload(project, vocabulary: ComposeDocument.Vocabulary())
		return panel
	}

	/// A card is a hole in the programme — black, a second long — and the only
	/// interesting thing about one is what somebody put on it.
	@Test func aCardSaysWhatIsOnIt() {
		let panel = self.panel()
		let intro = TimelineEntry(source: .card(Card(duration: 1.1)), label: "intro")
		#expect(panel.carried(by: intro) == "@intro · scene card")

		let next = TimelineEntry(source: .card(Card(duration: 1.1)), label: "next")
		#expect(panel.carried(by: next) == "@next · caption")

		// A placement nobody named carries nothing, and says nothing.
		#expect(panel.carried(by: TimelineEntry(source: .card(Card(duration: 1.1)))) == "")
	}

	/// A name with nothing hung on it still shows, because that is how somebody
	/// finds out an overlay is pointing at the wrong one.
	@Test func aNameWithNothingOnItStillShows() {
		let panel = self.panel()
		let lonely = TimelineEntry(clip: ClipReference("shot"), label: "unused")
		#expect(panel.carried(by: lonely) == "@unused")
	}

	@Test func bothEndsOfASpanCount() {
		#expect(ProgrammePanel.hangs(.marks(from: .group("a"), to: .group("b")), on: "b"))
		#expect(ProgrammePanel.hangs(.within(.group("a"), from: 0, to: 1), on: "a"))
		#expect(ProgrammePanel.hangs(.times(from: 0, to: 1), on: "a") == false)
		#expect(ProgrammePanel.hangs(.clips(from: ClipReference("a"), to: ClipReference("a")),
		                             on: "a") == false)
	}
}

/// The overlay kinds, behind one `+`.
@Suite @MainActor struct AddOverlayTests {

	/// Every kind an overlay can be is reachable, which four of them were not:
	/// a scene, film mode, the aberration and the tape had no button at all.
	@Test func everyKindCanBeAdded() {
		_ = NSApplication.shared
		let panel = ProgrammePanel(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
		var project = Project(timeline: [TimelineEntry(clip: ClipReference("shot"))])
		project.scenes["card"] = Scene(parts: [])
		panel.reload(project, vocabulary: ComposeDocument.Vocabulary())
		var written: Project?
		panel.onChange = { written = $0; panel.reload($0, vocabulary: ComposeDocument.Vocabulary()) }

		guard let menu = panel.addOverlayMenu() else {
			Issue.record("no add menu")
			return
		}
		// The first item is the button's own face and is never chosen.
		#expect(menu.items.count == 8)
		for index in 1 ..< menu.items.count {
			menu.performActionForItem(at: index)
		}
		#expect(written?.overlays.count == 7)

		let kinds = written?.overlays.map(\.kind) ?? []
		#expect(kinds.contains { if case .text = $0 { return true } else { return false } })
		#expect(kinds.contains { if case .spinner = $0 { return true } else { return false } })
		#expect(kinds.contains { if case .scene = $0 { return true } else { return false } })
		#expect(kinds.contains { if case .effect = $0 { return true } else { return false } })
		#expect(kinds.contains { if case .film = $0 { return true } else { return false } })
		#expect(kinds.contains { if case .aberration = $0 { return true } else { return false } })
		#expect(kinds.contains { if case .tape = $0 { return true } else { return false } })

		// Each one lands on what is selected rather than on nothing.
		for overlay in written?.overlays ?? [] {
			#expect(overlay.span == .clips(from: ClipReference("shot"), to: ClipReference("shot")))
		}
	}

	/// The timeline's own `+` offers everything that can go on one — the
	/// entries, the overlays, and a sound.
	@Test func theTimelinePlusOffersEntriesAndOverlaysAndSound() {
		_ = NSApplication.shared
		let panel = ProgrammePanel(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
		panel.reload(Project(timeline: [TimelineEntry(clip: ClipReference("shot"))]),
		             vocabulary: ComposeDocument.Vocabulary())
		guard let menu = panel.addEntryMenu() else {
			Issue.record("no add menu on the timeline")
			return
		}
		let titles = menu.items.map(\.title)
		#expect(titles.contains("Clip"))
		#expect(titles.contains("Section"))
		#expect(titles.contains("Card"))
		#expect(titles.contains("Caption"))
		#expect(titles.contains("Sound"))
	}

	/// Added while a shot is selected, the caption is written inside that shot
	/// — where it covers that placement and needs no name to be found by.
	@Test func aCaptionAddedOnASelectedEntryIsWrittenInsideIt() {
		_ = NSApplication.shared
		let panel = ProgrammePanel(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
		panel.reload(Project(timeline: [
			TimelineEntry(clip: ClipReference("one")),
			TimelineEntry(clip: ClipReference("two")),
		]), vocabulary: ComposeDocument.Vocabulary())
		panel.layoutSubtreeIfNeeded()
		var written: Project?
		panel.onChange = { written = $0 }

		panel.selectRow(1)
		guard let menu = panel.addEntryMenu(),
		      let caption = menu.items.firstIndex(where: { $0.title == "Caption" })
		else {
			Issue.record("no Caption on the menu")
			return
		}
		menu.performActionForItem(at: caption)

		#expect(written?.overlays.isEmpty == true)
		#expect(written?.timeline[0].overlays.isEmpty == true)
		#expect(written?.timeline[1].overlays.count == 1)
		// No range of its own: it covers the placement it is written in.
		#expect(written?.timeline[1].overlays[0].appearances.isEmpty == true)
	}

	/// And on the heading at the end, which is the top-level list — the one
	/// place an overlay is on the programme's own clock.
	@Test func aCaptionAddedOnTheLooseHeadingIsGlobal() {
		_ = NSApplication.shared
		let panel = ProgrammePanel(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
		panel.reload(Project(timeline: [TimelineEntry(clip: ClipReference("one"))]),
		             vocabulary: ComposeDocument.Vocabulary())
		panel.layoutSubtreeIfNeeded()
		var written: Project?
		panel.onChange = { written = $0 }

		// The heading is the last row, and it is there even with nothing under
		// it — otherwise there would be no way to put the first thing there.
		panel.selectRow(panel.rowCountForTesting - 1)
		guard let menu = panel.addEntryMenu(),
		      let caption = menu.items.firstIndex(where: { $0.title == "Caption" })
		else {
			Issue.record("no Caption on the menu")
			return
		}
		menu.performActionForItem(at: caption)
		#expect(written?.overlays.count == 1)
		#expect(written?.timeline[0].overlays.isEmpty == true)
	}

	/// The same list is on a row's own menu, so adding to a shot is done where
	/// the shot is rather than somewhere else and then pointed at it.
	@Test func aRowsMenuOffersTheSameThingsAndAddsThemThere() {
		_ = NSApplication.shared
		let panel = ProgrammePanel(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
		panel.reload(Project(timeline: [
			TimelineEntry(clip: ClipReference("one")),
			TimelineEntry(clip: ClipReference("two")),
		]), vocabulary: ComposeDocument.Vocabulary())
		panel.layoutSubtreeIfNeeded()
		var written: Project?
		panel.onChange = { written = $0 }

		guard let menu = panel.rowMenu(1),
		      let add = menu.items.first(where: { $0.title == "Add" })?.submenu,
		      let caption = add.items.firstIndex(where: { $0.title == "Caption" })
		else {
			Issue.record("no Add submenu on the row")
			return
		}
		add.performActionForItem(at: caption)
		#expect(written?.timeline[1].overlays.count == 1)
	}

	/// Dragged from one shot to another, the caption belongs to the other one.
	@Test func draggingAnOverlayOntoAnotherEntryRehomesIt() {
		_ = NSApplication.shared
		let panel = ProgrammePanel(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
		panel.reload(Project(timeline: [
			TimelineEntry(clip: ClipReference("one"),
			              overlays: [Overlay(kind: .text("moving", style: nil), appearances: [])]),
			TimelineEntry(clip: ClipReference("two")),
		]), vocabulary: ComposeDocument.Vocabulary())
		panel.layoutSubtreeIfNeeded()
		var written: Project?
		panel.onChange = { written = $0 }

		#expect(panel.rehome(.entry(path: [0], index: 0), onto: [1]))
		#expect(written?.timeline[0].overlays.isEmpty == true)
		#expect(written?.timeline[1].overlays.count == 1)
	}

	/// And dropped on the heading at the end it becomes one of the global ones,
	/// still on at the moments it was on before.
	@Test func draggingAnOverlayOntoTheHeadingMakesItGlobal() {
		_ = NSApplication.shared
		let panel = ProgrammePanel(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
		panel.reload(Project(timeline: [
			TimelineEntry(clip: ClipReference("one"), label: "opening",
			              overlays: [Overlay(kind: .text("moving", style: nil), appearances: [])]),
		]), vocabulary: ComposeDocument.Vocabulary())
		panel.layoutSubtreeIfNeeded()
		var written: Project?
		panel.onChange = { written = $0 }

		// No resolved programme here, so there is nothing to work the times out
		// from — but the placement has a name, and a name is what it would have
		// been written as anyway.
		#expect(panel.rehome(.entry(path: [0], index: 0), onto: nil))
		#expect(written?.overlays.count == 1)
		#expect(written?.overlays[0].span
			== .marks(from: .group("opening"), to: .group("opening")))
		#expect(written?.timeline[0].overlays.isEmpty == true)
	}
}

/// The menu on a section.
@Suite @MainActor struct SectionMenuTests {

	@Test func aSectionOffersToPlayOnItsOwn() {
		_ = NSApplication.shared
		let panel = ProgrammePanel(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
		panel.reload(Project(timeline: [
			TimelineEntry(group: "middle", entries: [
				TimelineEntry(clip: ClipReference("shot")),
			]),
		]), vocabulary: ComposeDocument.Vocabulary())
		panel.layoutSubtreeIfNeeded()
		var asked: String?
		panel.onPreviewSection = { asked = $0 }

		guard let menu = panel.rowMenu(0) else {
			Issue.record("no menu on the section row")
			return
		}
		#expect(menu.items.first?.title.contains("middle") == true)
		menu.performActionForItem(at: 0)
		#expect(asked == "middle")
	}
}

/// Which overlays have anything to do with what is selected.
@Suite @MainActor struct OverlayFilterTests {

	/// Two clips, and three overlays: one on the first, one on the second, one
	/// written in programme times that covers both.
	private func panel() -> ProgrammePanel {
		_ = NSApplication.shared
		var project = Project(timeline: [
			TimelineEntry(source: .card(Card(duration: 2)), label: "one"),
			TimelineEntry(source: .card(Card(duration: 2)), label: "two"),
		])
		project.overlays = [
			Overlay(kind: .text("first", style: nil),
			        span: .marks(from: .group("one"), to: .group("one"))),
			Overlay(kind: .text("second", style: nil),
			        span: .marks(from: .group("two"), to: .group("two"))),
			Overlay(kind: .text("all through", style: nil), span: .times(from: 0, to: 4)),
		]
		let panel = ProgrammePanel(frame: NSRect(x: 0, y: 0, width: 500, height: 500))
		panel.reload(project, vocabulary: ComposeDocument.Vocabulary())
		panel.resolved = try? Resolver.resolve(
			project, baseURL: URL(fileURLWithPath: NSTemporaryDirectory()))
		return panel
	}

	@Test func onlyTheOnesOnOverTheSelectionPlayARole() {
		let panel = self.panel()
		#expect(panel.resolved != nil)

		// The first card: its own overlay and the one across the whole thing.
		#expect(panel.overlaysOver(.entry([0])) == [0, 2])
		// The second card: the other two.
		#expect(panel.overlaysOver(.entry([1])) == [1, 2])
		// Nothing selected is nothing to be over.
		#expect(panel.overlaysOver(.output).isEmpty)
	}

	/// A section counts everything inside it, however deeply.
	@Test func aSectionCoversWhatIsInIt() {
		_ = NSApplication.shared
		var project = Project(timeline: [
			TimelineEntry(group: "part", entries: [
				TimelineEntry(source: .card(Card(duration: 1)), label: "a"),
				TimelineEntry(source: .card(Card(duration: 1)), label: "b"),
			]),
			TimelineEntry(source: .card(Card(duration: 1)), label: "after"),
		])
		project.overlays = [
			Overlay(kind: .text("on b", style: nil),
			        span: .marks(from: .group("b"), to: .group("b"))),
			Overlay(kind: .text("after", style: nil),
			        span: .marks(from: .group("after"), to: .group("after"))),
		]
		let panel = ProgrammePanel(frame: NSRect(x: 0, y: 0, width: 500, height: 500))
		panel.reload(project, vocabulary: ComposeDocument.Vocabulary())
		panel.resolved = try? Resolver.resolve(
			project, baseURL: URL(fileURLWithPath: NSTemporaryDirectory()))
		#expect(panel.overlaysOver(.entry([0])) == [0])
	}
}

/// Overlays shown in the timeline tree, under what they hang on.
@Suite @MainActor struct TreeOverlayTests {

	private func panel() -> ProgrammePanel {
		_ = NSApplication.shared
		var project = Project(timeline: [
			TimelineEntry(clip: ClipReference("intro"), label: "opening"),
			TimelineEntry(group: "middle", entries: [
				TimelineEntry(clip: ClipReference("demo")),
			]),
		])
		project.overlays = [
			Overlay(kind: .text("on the opening", style: nil),
			        span: .marks(from: .group("opening"), to: .group("opening"))),
			Overlay(kind: .text("on the section", style: nil),
			        span: .marks(from: .group("middle"), to: .group("middle"))),
			Overlay(kind: .text("on the clip", style: nil),
			        span: .clips(from: ClipReference("demo"), to: ClipReference("demo"))),
			Overlay(kind: .text("on the clock", style: nil), span: .times(from: 0, to: 2)),
		]
		let panel = ProgrammePanel(frame: NSRect(x: 0, y: 0, width: 500, height: 600))
		panel.reload(project, vocabulary: ComposeDocument.Vocabulary())
		panel.layoutSubtreeIfNeeded()
		return panel
	}

	/// An overlay is filed under whatever it names — a placement, a section, or
	/// a clip — and the ones that name nothing go under a heading of their own.
	@Test func eachOverlayIsFiledUnderWhatItNames() {
		let panel = self.panel()
		#expect(panel.treeRowsForTesting.contains("entry opening → overlay 0"))
		#expect(panel.treeRowsForTesting.contains("entry middle → overlay 1"))
		#expect(panel.treeRowsForTesting.contains("entry demo → overlay 2"))
		#expect(panel.treeRowsForTesting.contains("loose → overlay 3"))
	}

	/// The heading for those is closed to begin with: they are the exception,
	/// and an open one pushes the timeline off the top of the pane.
	@Test func theLooseHeadingStartsClosed() {
		let panel = self.panel()
		#expect(panel.looseHeadingIsOpenForTesting == false)
	}

	/// One written inside an entry is shown under that entry, whatever it is
	/// called — which is the whole reason for writing it there.
	@Test func anOverlayWrittenInsideAnEntryIsShownUnderIt() {
		_ = NSApplication.shared
		let project = Project(timeline: [
			TimelineEntry(clip: ClipReference("intro"),
			              overlays: [Overlay(kind: .text("first", style: nil), appearances: [])]),
			TimelineEntry(group: "middle", entries: [
				TimelineEntry(clip: ClipReference("intro"),
				              overlays: [Overlay(kind: .text("second", style: nil), appearances: [])]),
			]),
		])
		let panel = ProgrammePanel(frame: NSRect(x: 0, y: 0, width: 500, height: 600))
		panel.reload(project, vocabulary: ComposeDocument.Vocabulary())
		panel.layoutSubtreeIfNeeded()
		// The same clip twice, and each caption under the use it was written
		// in — the case a name could not tell apart.
		#expect(panel.treeRowsForTesting.contains("entry intro → overlay 0#0"))
		#expect(panel.treeRowsForTesting.contains("entry intro → overlay 1.0#0"))
	}
}
