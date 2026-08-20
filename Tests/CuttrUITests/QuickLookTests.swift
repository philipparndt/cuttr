import AppKit
import Testing
@testable import CuttrCompose
@testable import CuttrUI

/// What space over the programme tree plays, and where it refuses to fire.
///
/// Nothing here dispatches a key event into a view. The cases that matter most
/// are the ones where the key is *not* ours — with nothing selected, with a
/// modifier held, while a name is being typed — and an unclaimed key event sent
/// into a view walks up to `NSResponder`, which answers it by beeping on the
/// machine the tests are running on. So the handler is asked instead, which is
/// the same question the outline asks it.
@MainActor @Suite struct QuickLookTests {

	/// Two cards and a section, resolvable without any media.
	private func programme() throws -> (Project, ResolvedProject) {
		let project = Project(timeline: [
			TimelineEntry(source: .card(Card(duration: 4)), label: "first"),
			TimelineEntry(source: .group("middle", [
				TimelineEntry(source: .card(Card(duration: 6))),
				TimelineEntry(source: .card(Card(duration: 2))),
			])),
			TimelineEntry(source: .card(Card(duration: 5)), label: "last"),
		])
		let resolved = try Resolver.resolve(
			project, baseURL: URL(fileURLWithPath: NSTemporaryDirectory()))
		return (project, resolved)
	}

	private func space(_ flags: NSEvent.ModifierFlags = []) -> NSEvent {
		NSEvent.keyEvent(
			with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
			windowNumber: 0, context: nil, characters: " ",
			charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!
	}

	// MARK: - What the selection means

	/// A card is its length, on the programme's clock — which is what the
	/// resolver laid down for that entry and not what the file says about it.
	@Test func anEntryIsItsOwnStretch() throws {
		let (_, resolved) = try programme()
		#expect(QuickLook.span(of: .entry([0]), in: resolved) == QuickLook.Span(start: 0, end: 4))
		#expect(QuickLook.span(of: .entry([2]), in: resolved) == QuickLook.Span(start: 12, end: 17))
	}

	/// A section is its extent: everything inside it, from the first frame to
	/// the last.
	@Test func aSectionIsEverythingInsideIt() throws {
		let (_, resolved) = try programme()
		#expect(QuickLook.span(of: .section("middle", path: [1]), in: resolved)
			== QuickLook.Span(start: 4, end: 12))
	}

	/// And it is the same stretch the right-click menu already plays, which
	/// finds the section by name in the resolved programme. One row, two ways to
	/// ask, one answer.
	@Test func aSectionAgreesWithThePreviewMenu() throws {
		let (_, resolved) = try programme()
		let group = try #require(resolved.groups.first { $0.name == "middle" })
		let span = try #require(QuickLook.span(of: .section("middle", path: [1]), in: resolved))
		#expect(span.start == group.start)
		#expect(span.end == group.end)
	}

	/// An overlay is the stretch it is on for, which is its own business: this
	/// one is written at the top level and hung a second into a card that starts
	/// at four, so it is on from five to seven — shorter than the entry the tree
	/// files it under.
	@Test func anOverlayIsTheStretchItIsOnFor() throws {
		var (project, _) = try programme()
		project.overlays = [Overlay(
			kind: .text("caption", style: nil),
			span: .within(.group("last"), from: 1, to: 3))]
		let resolved = try Resolver.resolve(
			project, baseURL: URL(fileURLWithPath: NSTemporaryDirectory()))
		#expect(QuickLook.span(of: .overlay(.project(0)), in: resolved)
			== QuickLook.Span(start: 13, end: 15))
	}

	/// An overlay on more than once is its first appearance. Three appearances
	/// are three looks, and a span from the first to the last would play the two
	/// stretches of programme in between that it is not on for at all.
	@Test func anOverlayOnTwiceIsTheFirstTimeItIsOn() throws {
		var (project, _) = try programme()
		project.overlays = [Overlay(
			kind: .text("caption", style: nil),
			appearances: [
				Overlay.Appearance(.within(.group("last"), from: 1, to: 3)),
				Overlay.Appearance(.within(.group("first"), from: 1, to: 2)),
			])]
		let resolved = try Resolver.resolve(
			project, baseURL: URL(fileURLWithPath: NSTemporaryDirectory()))
		// `first` is the card at nought, so the earlier appearance is 1 → 2.
		#expect(QuickLook.span(of: .overlay(.project(0)), in: resolved)
			== QuickLook.Span(start: 1, end: 2))
	}

	/// A sound written inside an entry and saying nothing about when is on for
	/// exactly as long as that entry is — which may be longer than the caption
	/// beside it and shorter than the section above it.
	@Test func aSoundIsTheStretchItIsOnFor() throws {
		let folder = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("quicklook-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: folder) }
		try Data().write(to: folder.appendingPathComponent("music.wav"))

		var (project, _) = try programme()
		project.timeline[2].sounds = [Sound(file: "music.wav", span: nil)]
		let resolved = try Resolver.resolve(project, baseURL: folder)
		#expect(QuickLook.span(of: .sound(.entry(path: [2], index: 0)), in: resolved)
			== QuickLook.Span(start: 12, end: 17))
	}

	/// Several rows are the run between them. Four shots selected are one part
	/// of the programme, and there is no other single stretch that holds all of
	/// what was asked for.
	@Test func severalRowsAreTheRunBetweenThem() throws {
		let (_, resolved) = try programme()
		#expect(QuickLook.span(of: [.entry([0]), .entry([2])], in: resolved)
			== QuickLook.Span(start: 0, end: 17))
	}

	/// Nothing selected is nothing to look at, and that is how space comes to be
	/// declined rather than answered with an empty panel.
	@Test func nothingSelectedIsNothingToLookAt() throws {
		let (_, resolved) = try programme()
		#expect(QuickLook.span(of: [], in: resolved) == nil)
	}

	/// A caption on for a tenth of a second is a real thing to select and a
	/// hopeless thing to watch, so a look is never shorter than
	/// ``QuickLook/shortest``.
	@Test func aVeryShortStretchIsStillLongEnoughToWatch() throws {
		var (project, _) = try programme()
		project.overlays = [Overlay(
			kind: .text("blink", style: nil),
			span: .within(.group("last"), from: 1, to: 1.1))]
		let resolved = try Resolver.resolve(
			project, baseURL: URL(fileURLWithPath: NSTemporaryDirectory()))
		let span = try #require(QuickLook.span(of: .overlay(.project(0)), in: resolved))
		#expect(span.start == 13)
		#expect(abs(span.duration - QuickLook.shortest) < 1e-9)
	}

	/// And one at the very end of the programme is taken off the front instead,
	/// because there is nothing after it to play.
	@Test func aShortStretchAtTheEndIsTakenOffTheFront() throws {
		var (project, _) = try programme()
		project.overlays = [Overlay(
			kind: .text("blink", style: nil),
			span: .within(.group("last"), from: 4.95, to: 5))]
		let resolved = try Resolver.resolve(
			project, baseURL: URL(fileURLWithPath: NSTemporaryDirectory()))
		let span = try #require(QuickLook.span(of: .overlay(.project(0)), in: resolved))
		#expect(span.end == resolved.duration)
		#expect(abs(span.duration - QuickLook.shortest) < 1e-9)
	}

	// MARK: - Where the key is ours, and where it is not

	@Test func spaceOverASelectedRowIsALook() {
		#expect(QuickLook.claims(space(), editing: false, hasSpan: true))
	}

	/// The three refusals, asked of the handler rather than dispatched at it.
	@Test func spaceIsDeclinedWithNothingSelected() {
		#expect(!QuickLook.claims(space(), editing: false, hasSpan: false))
	}

	@Test func spaceIsDeclinedWhileANameIsBeingTyped() {
		#expect(!QuickLook.claims(space(), editing: true, hasSpan: true))
	}

	@Test func spaceUnderAModifierIsSomebodyElsesKey() {
		for flags in [NSEvent.ModifierFlags.command, .option, .shift, .control] {
			#expect(!QuickLook.claims(space(flags), editing: false, hasSpan: true))
		}
	}

	@Test func anotherKeyIsNotALook() {
		let letter = NSEvent.keyEvent(
			with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
			windowNumber: 0, context: nil, characters: "a",
			charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
		#expect(!QuickLook.claims(letter, editing: false, hasSpan: true))
		#expect(!QuickLook.dismisses(letter))
	}

	/// Escape puts an open look away — and it is only ever asked about while one
	/// is open, so the tree keeps whatever escape meant to it otherwise.
	@Test func escapeIsTheWayOut() {
		let escape = NSEvent.keyEvent(
			with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
			windowNumber: 0, context: nil, characters: "\u{1b}",
			charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
		#expect(QuickLook.dismisses(escape))
		#expect(!QuickLook.claims(escape, editing: false, hasSpan: true))
	}

	// MARK: - The tree's own answer

	/// The tree with nothing selected declines the key, and nothing has been
	/// opened by asking.
	@Test func theTreeDeclinesSpaceWithNothingSelected() throws {
		let (project, resolved) = try programme()
		let panel = ProgrammePanel(frame: NSRect(x: 0, y: 0, width: 440, height: 600))
		panel.resolved = resolved
		panel.reload(project, vocabulary: ComposeDocument.Vocabulary())
		#expect(panel.lookSpan() == nil)
		#expect(!QuickLook.claims(space(), editing: panel.isNaming,
		                          hasSpan: panel.lookSpan() != nil))
		#expect(!panel.isLooking)
	}

	/// A row selected, and the tree knows what a look would play. The first row
	/// of this tree is the four-second card.
	@Test func theTreeClaimsSpaceForASelectedRow() throws {
		let (project, resolved) = try programme()
		let panel = ProgrammePanel(frame: NSRect(x: 0, y: 0, width: 440, height: 600))
		panel.resolved = resolved
		panel.reload(project, vocabulary: ComposeDocument.Vocabulary())
		panel.selectRow(0)
		#expect(panel.lookRows() == [.entry([0])])
		#expect(panel.lookSpan() == QuickLook.Span(start: 0, end: 4))
		#expect(QuickLook.claims(space(), editing: panel.isNaming,
		                        hasSpan: panel.lookSpan() != nil))
		// Asking is not looking: no panel has been put on screen.
		#expect(!panel.isLooking)
	}

	/// A section row carries its name, which is what makes space and the
	/// right-click menu agree about it.
	@Test func aSectionRowIsAskedForByName() throws {
		let (project, resolved) = try programme()
		let panel = ProgrammePanel(frame: NSRect(x: 0, y: 0, width: 440, height: 600))
		panel.resolved = resolved
		panel.reload(project, vocabulary: ComposeDocument.Vocabulary())
		panel.selectRow(1)
		#expect(panel.lookRows() == [.section("middle", path: [1])])
		#expect(panel.lookSpan() == QuickLook.Span(start: 4, end: 12))
	}

	/// A tree that has not resolved yet has nothing to play, whatever is
	/// selected — so the key is declined rather than opening a black panel.
	@Test func anUnresolvedProgrammeHasNothingToLookAt() throws {
		let (project, _) = try programme()
		let panel = ProgrammePanel(frame: NSRect(x: 0, y: 0, width: 440, height: 600))
		panel.reload(project, vocabulary: ComposeDocument.Vocabulary())
		panel.selectRow(0)
		#expect(panel.lookSpan() == nil)
	}

	// MARK: - Where the panel goes

	/// Beside the tree, level with the row, and clear of the column — not clear
	/// of the row, which would still cover the four rows under it.
	@Test func thePanelSitsBesideTheColumn() {
		let window = NSRect(x: 0, y: 0, width: 1200, height: 820)
		let column = NSRect(x: 0, y: 0, width: 440, height: 820)
		let row = NSRect(x: 0, y: 700, width: 440, height: 26)
		let size = QuickLook.size(for: NSSize(width: 1920, height: 1080), in: window)
		let place = QuickLook.place(size, beside: column, row: row, inside: window)
		#expect(place.minX >= column.maxX)
		#expect(!place.intersects(row))
		#expect(window.contains(place))
	}

	/// A window with no room beside the tree is the one case where the panel has
	/// to overlap the column, and then it keeps clear of the row the long way:
	/// away from the half of the tree the row is in.
	@Test func withNoRoomBesideItKeepsClearOfTheRow() {
		let window = NSRect(x: 0, y: 0, width: 700, height: 820)
		let column = NSRect(x: 0, y: 0, width: 440, height: 820)
		let size = QuickLook.size(for: NSSize(width: 1920, height: 1080), in: window)

		let low = NSRect(x: 0, y: 100, width: 440, height: 26)
		let above = QuickLook.place(size, beside: column, row: low, inside: window)
		#expect(above.minX < column.maxX)
		#expect(!above.intersects(low))
		#expect(above.minY >= low.maxY)

		let high = NSRect(x: 0, y: 700, width: 440, height: 26)
		let below = QuickLook.place(size, beside: column, row: high, inside: window)
		#expect(!below.intersects(high))
		#expect(below.maxY <= high.minY)
	}

	/// The panel the tree actually puts up lands beside the row it is about.
	///
	/// The window is never ordered front, so nothing appears on screen while the
	/// tests run — what is being checked is where the panel was told to be, which
	/// is the part that can be wrong.
	@Test func theLookLandsBesideTheSelectedRow() throws {
		let (project, resolved) = try programme()
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 820),
		                      styleMask: [.titled], backing: .buffered, defer: true)
		let panel = ProgrammePanel(frame: NSRect(x: 0, y: 0, width: 440, height: 820))
		window.contentView?.addSubview(panel)
		panel.resolved = resolved
		panel.reload(project, vocabulary: ComposeDocument.Vocabulary())
		panel.selectRow(0)
		panel.showLook()

		let frame = try #require(panel.lookFrameForTesting)
		let column = window.convertToScreen(panel.convert(panel.bounds, to: nil))
		#expect(frame.minX >= column.maxX)
		#expect(window.frame.contains(frame))

		// And it is put away without leaving a panel behind.
		panel.closeLook()
		#expect(!panel.isLooking)
	}

	/// An edit puts it away: what it was a look at may not be there any more,
	/// and the composition it was playing has been replaced.
	@Test func anEditPutsTheLookAway() throws {
		let (project, resolved) = try programme()
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 820),
		                      styleMask: [.titled], backing: .buffered, defer: true)
		let panel = ProgrammePanel(frame: NSRect(x: 0, y: 0, width: 440, height: 820))
		window.contentView?.addSubview(panel)
		panel.resolved = resolved
		panel.reload(project, vocabulary: ComposeDocument.Vocabulary())
		panel.selectRow(0)
		panel.showLook()
		panel.reload(project, vocabulary: ComposeDocument.Vocabulary())
		#expect(!panel.isLooking)
	}

	/// The picture is the programme's shape, so nothing is letterboxed inside a
	/// panel that is itself the wrong shape — and it stays a look rather than
	/// growing into the window.
	@Test func thePictureIsTheProgrammesShape() {
		let window = NSRect(x: 0, y: 0, width: 3000, height: 2000)
		let size = QuickLook.size(for: NSSize(width: 1920, height: 1080), in: window)
		#expect(size.width == 560)
		#expect(abs(size.height - QuickLookPanel.captionHeight - 560 * 9 / 16) < 1)
		let tall = QuickLook.size(for: NSSize(width: 1080, height: 1920), in: window)
		#expect(tall.height > tall.width)
	}
}
