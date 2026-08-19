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
			],
			overlays: [
				Overlay(kind: .text("Installing", style: "lower-third"),
				        span: .clips(from: ClipReference("intro"), to: ClipReference("demo"))),
				Overlay(kind: .spinner(Spinner(words: [SpinnerWord("one"), SpinnerWord("two", duration: 2)])),
				        spans: [.times(from: 1, to: 4), .marks(from: .group("middle"), to: .group("middle"))],
				        anchor: "mia-eye", offset: CGPoint(x: 0.02, y: -0.18)),
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
			.overlay(0), .overlay(1), .output,
			// Gone: a selection that outlived the thing it named.
			.entry([9]), .overlay(9),
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
