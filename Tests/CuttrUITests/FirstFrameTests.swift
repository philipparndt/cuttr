import AppKit
import CuttrCompose
import CuttrKit
import Testing
@testable import CuttrUI

/// The frame a panel asked for before there was one to give it.
///
/// Opening a project reads it, resolves it and reloads every panel in the same
/// breath, and only then goes away and builds the composition the frames are
/// cut out of. A panel that is already on screen — the project page, which is
/// where a window with nothing in it opens — therefore asks for its picture at
/// the one instant nothing can answer, and it used to keep the blank it was
/// given: this form is rebuilt when the selection or the project changes, and a
/// build finishing is neither of those. What it looked like from the outside was
/// a project page with an empty picture in its head that filled in the moment
/// somebody switched windows and something unrelated rebuilt the form.
///
/// So the window says when the frames can be had, and these are about the
/// second ask.
@Suite @MainActor struct FirstFrameTests {

	/// The window's `poster`, with the build stubbed out: nothing to give until
	/// `built`, and a count of what it was asked for.
	@MainActor private final class Pictures {
		var built = false
		private(set) var asks = 0
		/// Whether answers are held back, so a test can decide what order they
		/// come back in. The real one decodes on another queue and hands the
		/// frame over whenever it has it.
		var holding = false
		private var held: [() -> Void] = []

		func poster(_ time: Double, _ done: @escaping (NSImage?) -> Void) {
			asks += 1
			// What there was to give at the moment of the asking, which is the
			// whole subject: the same question asked twice has two answers.
			let answer = built ? Pictures.frame : nil
			if holding { held.append { done(answer) } } else { done(answer) }
		}

		/// Answers one of the held questions, by the order it was asked in.
		func answer(ask index: Int) { held[index]() }

		/// Grey, and small. Nothing here looks at it; it only has to be an image
		/// rather than the absence of one.
		private static let frame: NSImage = {
			let image = NSImage(size: NSSize(width: 16, height: 9))
			image.lockFocus()
			NSColor.gray.setFill()
			NSRect(x: 0, y: 0, width: 16, height: 9).fill()
			image.unlockFocus()
			return image
		}()
	}

	/// Two cards and a caption over the first, which resolves without a frame of
	/// footage anywhere — a card is a whole picture made of nothing but the file
	/// it is written in.
	private func project() -> Project {
		var project = Project(
			output: Output(width: 1920, height: 1080, framesPerSecond: 25),
			timeline: [
				TimelineEntry(source: .card(Card(duration: 2)), label: "one"),
				TimelineEntry(source: .card(Card(duration: 2)), label: "two"),
			])
		project.overlays = [Overlay(kind: .text("hello", style: nil),
		                            span: .times(from: 0, to: 2))]
		return project
	}

	private func panel(_ pictures: Pictures, selection: ProjectSelection) -> PropertiesPanel {
		_ = NSApplication.shared
		let panel = PropertiesPanel()
		let project = self.project()
		panel.resolved = try? Resolver.resolve(
			project, baseURL: URL(fileURLWithPath: NSTemporaryDirectory()))
		panel.poster = { time, done in pictures.poster(time, done) }
		panel.reload(project, vocabulary: ComposeDocument.Vocabulary(), selection: selection)
		return panel
	}

	/// The head of the project page, which is the one that came up blank.
	@Test func theHeadGetsItsFrameWhenTheCompositionIsFinallyBuilt() {
		let pictures = Pictures()
		let panel = panel(pictures, selection: .output)
		#expect(pictures.asks == 1, "the head asks as soon as the form is built")
		#expect(panel.thumbnailForTesting == nil,
		        "and there is nothing to give it: the composition is still being built")

		pictures.built = true
		panel.framesCanBeHad()
		#expect(panel.thumbnailForTesting != nil,
		        "the build finished, so the question is asked again and answered")
	}

	/// And the picture an overlay is dragged around in, which has the same
	/// arrival and the same silence.
	@Test func thePlacementPictureAsksAgainToo() throws {
		let pictures = Pictures()
		let panel = panel(pictures, selection: .overlay(.project(0)))
		let preview = try #require(panel.previewForTesting)
		#expect(preview.poster == nil, "nothing built, nothing to draw the overlay on")

		pictures.built = true
		panel.framesCanBeHad()
		#expect(preview.poster != nil, "the frame the caption appears on, once there is one")
	}

	/// Only what is missing is asked for again. Every edit builds the
	/// composition again, and a panel that re-fetched a picture already on
	/// screen would decode two frames for every one anybody looks at.
	@Test func aFrameAlreadyInTheHeadIsNotAskedForTwice() {
		let pictures = Pictures()
		pictures.built = true
		let panel = panel(pictures, selection: .output)
		#expect(panel.thumbnailForTesting != nil)

		let asked = pictures.asks
		panel.framesCanBeHad()
		#expect(pictures.asks == asked, "there is a frame in the head; it is the right one")
	}

	/// A "no frame" arriving late does not empty the head.
	///
	/// The rebuild clears the picture because the head is about to be about
	/// something else, and that is a different thing from an answer of `nil`
	/// turning up afterwards and wiping out a frame that arrived in the
	/// meantime. With two asks for the same picture in flight — the one made too
	/// early and the one made when the build finished — the early one coming
	/// back last is exactly the order this has to survive.
	@Test func aLateEmptyAnswerDoesNotWipeTheFrameThatArrived() {
		let pictures = Pictures()
		pictures.holding = true
		let panel = panel(pictures, selection: .output)
		pictures.built = true
		panel.framesCanBeHad()
		#expect(pictures.asks == 2, "asked once too early, and once when there was something")

		pictures.answer(ask: 1)
		#expect(panel.thumbnailForTesting != nil)
		pictures.answer(ask: 0)
		#expect(panel.thumbnailForTesting != nil, "the frame it has is still the frame")
	}
}

/// And the same thing in the window, taken the whole way.
///
/// The tests above are about the second ask; this one is about who makes it. A
/// project page that is already showing when a project arrives is reloaded
/// before the composition exists, so the frame in its head can only come from
/// the build saying so — and this is what goes red if that line is ever taken
/// out of the build task again.
@Suite @MainActor struct ProjectPageFrameTests {

	/// Two cards. A card is a whole picture made of nothing but the file it is
	/// written in, so this resolves and builds with no footage anywhere on disk.
	///
	/// Applied rather than handed to the initialiser, because that is what
	/// resolves it — the same step opening a file takes, and the one this is
	/// about: it resolves and hands the project round before it builds.
	private func document() -> ComposeDocument {
		let document = ComposeDocument()
		document.apply(Project(
			output: Output(width: 640, height: 360, framesPerSecond: 25),
			timeline: [
				TimelineEntry(source: .card(Card(duration: 1)), label: "one"),
				TimelineEntry(source: .card(Card(duration: 1)), label: "two"),
			]))
		return document
	}

	@Test func theInfoPageFillsInItsFrameWhenTheBuildArrives() async throws {
		_ = NSApplication.shared
		let controller = ComposeWindowController(document: document())
		defer { controller.window?.close() }
		// The page is open before the composition is. The build is a task, and
		// nothing between here and the first `await` gives it a chance to run —
		// which is the ordering somebody opening a project onto this page gets.
		controller.show(.project)
		#expect(controller.projectPanelForTesting.thumbnailForTesting == nil,
		        "there is no composition yet, so there is no frame to be had")

		// As long as the build and the decode take, and no longer.
		var waited = 0.0
		while controller.projectPanelForTesting.thumbnailForTesting == nil, waited < 20 {
			try await Task.sleep(nanoseconds: 100_000_000)
			waited += 0.1
		}
		#expect(controller.projectPanelForTesting.thumbnailForTesting != nil,
		        "the head was still empty \(waited)s after the project page opened")
	}
}
