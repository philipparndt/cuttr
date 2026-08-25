import AppKit
import CuttrKit
import Foundation
import Testing
@testable import CuttrCompose
@testable import CuttrUI

/// Treatments as rows in the programme tree.
///
/// A clip with three of them is one clip and three things filed under it, each
/// with its own row, its own place in the panel, and its own Delete. The
/// alternative was a list of three inside the clip's own form, which is a
/// column somebody has to count down to find the second one and leaves nothing
/// on screen saying which the panel is about.
///
/// Nothing here dispatches a key event: the tree's own methods are called, the
/// way the tree calls them. An unclaimed key walks up to `NSResponder` and beeps
/// on the machine running the tests.
@MainActor @Suite struct PresentationTreeTests {

	private func made(_ at: Double, _ scene: String) -> Presentation {
		Presentation(
			at: at, into: Presentation.Rectangle(x: 0.04, y: 0.2, width: 0.44, height: 0.6),
			hold: 4, scene: scene, parameters: ["one": "a line"])
	}

	private func project() -> Project {
		var entry = TimelineEntry(clip: ClipReference("install"))
		entry.presentations = [made(4, "bullets"), made(11, "boxes"), made(18, "the-catch")]
		return Project(timeline: [entry])
	}

	private func panel(_ project: Project) -> ProgrammePanel {
		_ = NSApplication.shared
		let panel = ProgrammePanel(frame: NSRect(x: 0, y: 0, width: 420, height: 600))
		panel.reload(project, vocabulary: ComposeDocument.Vocabulary())
		return panel
	}

	/// One clip, and three rows under it.
	@Test func aClipCarriesItsTreatmentsAsRows() {
		let panel = self.panel(project())
		let outline = panel.outlineForTesting
		#expect(outline.numberOfRows == 5, "one clip, three treatments, and the loose heading")
		// The clip first, then its treatments in the order the file has them.
		var selections: [ProjectSelection] = []
		for row in 0..<outline.numberOfRows {
			panel.selectRow(row)
			selections.append(panel.selectionForTesting)
		}
		#expect(selections[0] == .entry([0]))
		#expect(selections[1] == .presentation(path: [0], index: 0))
		#expect(selections[2] == .presentation(path: [0], index: 1))
		#expect(selections[3] == .presentation(path: [0], index: 2))
	}

	/// A clip with none of them grows no rows, so a project that has never
	/// heard of the feature looks exactly as it did.
	@Test func aClipWithNoTreatmentsCarriesNothing() {
		let panel = self.panel(Project(timeline: [TimelineEntry(clip: ClipReference("install"))]))
		// The clip, and the heading the loose overlays live under.
		#expect(panel.outlineForTesting.numberOfRows == 2)
	}

	/// Delete takes off the one that is selected, and only that one.
	@Test func deleteTakesOffTheSelectedTreatment() {
		let panel = self.panel(project())
		var written: Project?
		panel.onChange = { written = $0 }

		panel.selectRow(2)   // the second treatment
		panel.deleteSelected()
		let left = try? #require(written?.timeline.first?.presentations)
		#expect(left?.count == 2)
		#expect(left?.map(\.scene) == ["bullets", "the-catch"])
	}

	/// And Delete on the clip itself still takes the clip, treatments and all —
	/// the row that is selected is the thing that goes.
	@Test func deleteOnTheClipTakesTheWholeThing() {
		let panel = self.panel(project())
		var written: Project?
		panel.onChange = { written = $0 }

		panel.selectRow(0)
		panel.deleteSelected()
		#expect(written?.timeline.isEmpty == true)
	}

	/// Moving one past another moves *when it happens*, which is a different
	/// thing from what an overlay's order means — those decide what is drawn on
	/// top of what.
	@Test func aTreatmentCanBeMovedPastItsNeighbour() {
		let panel = self.panel(project())
		var written: Project?
		panel.onChange = { written = $0 }

		panel.selectRow(1)
		panel.moveSelectedForTesting(by: 1)
		#expect(written?.timeline[0].presentations.map(\.scene) == ["boxes", "bullets", "the-catch"])
	}

	@Test func aTreatmentCanBeDuplicated() {
		let panel = self.panel(project())
		var written: Project?
		panel.onChange = { written = $0 }

		panel.selectRow(1)
		panel.duplicateSelectedForTesting()
		#expect(written?.timeline[0].presentations.map(\.scene)
			== ["bullets", "bullets", "boxes", "the-catch"])
	}

	/// A treatment can only be written inside the entry it is on, so there is
	/// nowhere for a drag to take it — and a drag that always fails is worse
	/// than one that cannot be started.
	@Test func aTreatmentIsNotDragged() {
		let panel = self.panel(project())
		let outline = panel.outlineForTesting
		let item = try? #require(outline.item(atRow: 1))
		#expect(panel.outlineView(outline, pasteboardWriterForItem: item as Any) == nil)
		// The clip above it still is.
		let clip = try? #require(outline.item(atRow: 0))
		#expect(panel.outlineView(outline, pasteboardWriterForItem: clip as Any) != nil)
	}

	// MARK: - A look at one

	/// A folder with a recording in it, and a take that cuts one clip out of it.
	///
	/// Empty files: whether the media is *there* is all the resolver has to
	/// decide, and what is inside it is the player's business.
	private func fixture() throws -> URL {
		let directory = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("cuttr-presentation-tree-\(UUID().uuidString)")
		try FileManager.default.createDirectory(
			at: directory.appendingPathComponent("takes"), withIntermediateDirectories: true)
		try Data().write(to: directory.appendingPathComponent("screen.mov"))
		try TakeWriter.write(Take(video: "../screen.mov", clips: [
			Clip(slug: "install", start: 0, end: 24),
		])).write(to: directory.appendingPathComponent("takes/take-01.cuttr"),
		          atomically: true, encoding: .utf8)
		return directory
	}

	private func looking() throws -> (ProgrammePanel, ResolvedProject, URL) {
		let directory = try fixture()
		let project = try ProjectReader.read("""
		takes: [takes/take-01.cuttr]
		timeline:
		  - clip: install
		    presentations:
		      - at:    00:04.000
		        into:  [0.04, 0.2, 0.44, 0.6]
		        hold:  5
		        ramp:  0.6
		        scene: bullets
		      - at:    00:12.000
		        into:  [0.52, 0.2, 0.44, 0.6]
		        hold:  4
		        ramp:  0.6
		        scene: boxes
		""")
		let resolved = try Resolver.resolve(project, baseURL: directory)
		let panel = self.panel(project)
		panel.resolved = resolved
		// A look needs somewhere to hang: the panel puts itself beside the row,
		// inside the window the tree is in.
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
		                      styleMask: [.titled], backing: .buffered, defer: true)
		window.contentView?.addSubview(panel)
		return (panel, resolved, directory)
	}

	/// Space over a treatment plays the whole gesture: the picture leaving, the
	/// hold, and the picture coming back.
	///
	/// Not only the hold. What somebody looks at a treatment for is whether the
	/// travel reads right, and a look that began with the picture already aside
	/// would show them everything except the thing they were about to tune.
	@Test func aLookAtATreatmentIsTheWholeGesture() throws {
		let (panel, _, directory) = try looking()
		defer { try? FileManager.default.removeItem(at: directory) }

		panel.selectRow(1)
		#expect(panel.lookRows() == [.presentation(path: [0], index: 0)])
		#expect(panel.lookSpan() == QuickLook.Span(start: 3.4, end: 9.6))
	}

	/// And the second one is where the first hold has already pushed it to —
	/// `at:` is on the take's clock and the programme is five seconds longer by
	/// the time it arrives.
	@Test func aLookAtTheSecondIsPushedAlongByTheFirstHold() throws {
		let (panel, _, directory) = try looking()
		defer { try? FileManager.default.removeItem(at: directory) }

		panel.selectRow(2)
		#expect(panel.lookSpan() == QuickLook.Span(start: 16.4, end: 21.6))
	}

	/// A treatment with no hold is still a look: the picture goes aside over
	/// the ramp and comes straight back, which is a second and a bit and is
	/// exactly what somebody wants to watch when they are setting the ramp.
	@Test func aTreatmentWithNoHoldIsStillALook() throws {
		let directory = try fixture()
		defer { try? FileManager.default.removeItem(at: directory) }
		let project = try ProjectReader.read("""
		takes: [takes/take-01.cuttr]
		timeline:
		  - clip: install
		    presentations:
		      - at:    00:04.000
		        into:  [0.04, 0.2, 0.44, 0.6]
		        ramp:  0.6
		        scene: bullets
		""")
		let panel = self.panel(project)
		panel.resolved = try Resolver.resolve(project, baseURL: directory)
		panel.selectRow(1)
		#expect(panel.lookSpan() == QuickLook.Span(start: 3.4, end: 4.6))
	}

	/// The look says which treatment it is about, because three of them under
	/// one clip is three looks that would otherwise all be called the same
	/// thing.
	@Test func theLookIsNamedForItsScene() throws {
		let (panel, _, directory) = try looking()
		defer { try? FileManager.default.removeItem(at: directory) }
		panel.selectRow(2)
		panel.showLook()
		#expect(panel.lookPanelForTesting?.titleForTesting == "boxes")
		panel.closeLook()
	}

	/// The row says which one it is at a glance: when it happens, what plays,
	/// which way the picture goes and how long it stops. Three rows that all
	/// said "presentation" would be three rows nobody could tell apart.
	@Test func theRowSaysWhichOneItIs() {
		let panel = self.panel(project())
		let view = panel.outlineView(panel.outlineForTesting,
		                             viewFor: nil,
		                             item: panel.outlineForTesting.item(atRow: 1) as Any)
		#expect(view != nil)
		#expect(String(describing: type(of: view!)).contains("PresentationRow"))
	}
}
