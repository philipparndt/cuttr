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
}
