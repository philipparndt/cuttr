import AppKit
import CuttrCompose
import Testing
@testable import CuttrUI

/// Saying something where somebody will see it.
///
/// Everything this program said, it said in one line at the top of the window —
/// small, grey, and replaced by the next thing. A share that refused because a
/// take window was open said so there, and what came back was a report that the
/// button did nothing.
@Suite @MainActor struct ToastTests {

	private func window() -> NSWindow {
		_ = NSApplication.shared
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
		                      styleMask: [.titled], backing: .buffered, defer: false)
		window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
		return window
	}

	private func toasts(in window: NSWindow) -> [ToastView] {
		func walk(_ view: NSView) -> [ToastView] {
			(view as? ToastView).map { [$0] }
				?? view.subviews.flatMap(walk)
		}
		return window.contentView.map(walk) ?? []
	}

	@Test func oneIsShownInTheWindow() {
		let window = window()
		let presenter = ToastPresenter(window: window)
		presenter.show(Toast(.done, "sent your changes"))
		#expect(toasts(in: window).count == 1)
	}

	/// A test that looks a moment later cannot tell "nothing was said" from
	/// "it was said and faded", and those are the two answers that matter when
	/// the complaint is that a button did nothing.
	@Test func whatWasSaidIsRemembered() {
		let presenter = ToastPresenter(window: window())
		presenter.show(Toast(.news, "first"))
		presenter.show(Toast(.refusal, "second"))
		#expect(presenter.saidForTesting == ["first", "second"])
	}

	/// It is remembered even with nowhere to draw it, so a window that is not
	/// on screen yet does not swallow the record.
	@Test func itIsRememberedWithNoWindowAtAll() {
		let presenter = ToastPresenter(window: nil)
		presenter.show(Toast(.news, "said into the air"))
		#expect(presenter.saidForTesting == ["said into the air"])
	}

	/// A column of them up the side of the window is a wall, not a message.
	@Test func onlyFourAreOnScreenAtOnce() {
		let window = window()
		let presenter = ToastPresenter(window: window)
		for n in 1 ... 7 { presenter.show(Toast(.news, "number \(n)")) }
		#expect(toasts(in: window).count == 4)
		#expect(presenter.saidForTesting.count == 7, "the record forgot some")
	}

	/// A refusal names something to be done and outlives a glance.
	@Test func aRefusalStaysLongerThanTheRest() {
		#expect(Toast.Kind.refusal.lifetime > Toast.Kind.done.lifetime)
		#expect(Toast.Kind.refusal.lifetime > Toast.Kind.news.lifetime)
	}

	/// Clicking one puts it away. A toast that needed reading has been read by
	/// the time somebody reaches for it.
	@Test func clickingOnePutsItAway() {
		let window = window()
		let presenter = ToastPresenter(window: window)
		presenter.show(Toast(.news, "gone in a moment"))
		let view = toasts(in: window).first
		view?.onDismiss?()
		#expect(toasts(in: window).isEmpty)
	}

	/// And right-clicking one takes the words rather than putting it away. A
	/// refusal is often the exact sentence a report should quote, and one that
	/// cannot be copied reaches the report from memory.
	///
	/// The pasteboard itself is left alone here: this runs on somebody's own
	/// machine while they are working, and a test that helps itself to the
	/// clipboard is a test that throws away what they had on it.
	@Test func oneCanBeCopied() {
		let window = window()
		let presenter = ToastPresenter(window: window)
		presenter.show(Toast(.refusal, "save the project first"))
		let view = try? #require(toasts(in: window).first)
		let click = NSEvent.mouseEvent(
			with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
			windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
		let menu = click.flatMap { view?.menu(for: $0) }
		#expect(menu?.items.contains { $0.title == "Copy" } == true,
		        "a toast offers nothing to copy it with")
	}

	/// It goes by itself even if the presenter that drew it has been let go.
	///
	/// A document that leaves the screen is given a fresh presenter, and the one
	/// it replaces is released with its timers still to fire — held weakly, so
	/// what it drew stayed in the corner of the window for good. The toast's few
	/// seconds are the view's, not the presenter's.
	@Test func itGoesEvenWithNoPresenterLeft() throws {
		let window = window()
		var presenter: ToastPresenter? = ToastPresenter(window: window)
		presenter?.show(Toast(.news, "and then nobody was watching"))
		// Held before the presenter goes, because it is the presenter that
		// knows about it. The run loop keeps it alive until it fires.
		let goes = try #require(presenter?.goesForTesting)
		presenter = nil

		#expect(toasts(in: window).count == 1)
		goes.fire()
		#expect(toasts(in: window).isEmpty, "it stayed in the corner for good")
	}

	/// A window going away takes its toasts with it: one hanging over a window
	/// that has closed outlives what it was about.
	@Test func clearingTakesThemAll() {
		let window = window()
		let presenter = ToastPresenter(window: window)
		presenter.show(Toast(.news, "one"))
		presenter.show(Toast(.news, "two"))
		presenter.clear()
		#expect(toasts(in: window).isEmpty)
	}
}

/// What the project window says, and where.
@Suite(.serialized) @MainActor struct WindowSaysTests {

	private func window() throws -> ComposeWindowController {
		_ = NSApplication.shared
		let project = try ProjectReader.read("timeline:\n  - {card: 00:04.000}\n")
		let document = ComposeDocument(project: project)
		document.apply(project)
		let controller = ComposeWindowController(document: document)
		_ = controller.windowForTesting
		return controller
	}

	/// The one the report was about: a share that refuses says so somewhere
	/// somebody will see it. This project has never been saved, which is the
	/// first of the refusals.
	@Test func aRefusalIsSaidInTheCorner() throws {
		let controller = try window()
		controller.shareProject(nil)
		#expect(controller.saidForTesting.contains("save the project"),
		        "it said: \(controller.saidForTesting)")
		#expect(controller.toasts.saidForTesting.contains { $0.contains("save the project") },
		        "it was said in the title bar and nowhere else")
	}

	/// And the status line still carries it, because it is also the caption
	/// over the progress bar.
	@Test func theStatusLineStillHasIt() throws {
		let controller = try window()
		controller.shareProject(nil)
		#expect(!controller.saidForTesting.isEmpty)
	}

	/// The line under the title bar is where a project's own troubles are said
	/// — a component that is not there, a decoder's own words — and it is one
	/// line that truncates. So it can be taken: selectable like text, and a
	/// right-click that copies the whole of it however little of it fits.
	@Test func theProblemLineCanBeCopied() throws {
		let controller = try window()
		let window = try #require(controller.windowForTesting)
		func walk(_ view: NSView) -> [NSTextField] {
			(view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(walk)
		}
		let labels = window.contentView.map(walk) ?? []
		let problem = labels.first { field in
			field.menu?.items.contains { $0.title == "Copy Message" } == true
		}
		#expect(problem != nil, "nothing in the window offers to copy what it says")
		#expect(problem?.isSelectable == true)
	}
}
