import AppKit
import Testing
@testable import CuttrUI

/// The bar at the top of the window, and what happens to it in full screen.
///
/// The bar is a view in the *content* view and not anything in the titlebar,
/// which is what keeps it on screen when macOS takes the titlebar away. What it
/// holds still has to be measured again: the traffic lights go into the
/// titlebar that slides down, and the room kept for them was worked out once
/// when the bar arrived in its window and never again.
@Suite @MainActor struct FullScreenBarTests {

	// MARK: - The measurement

	@Test func aWindowedBarClearsTheButtons() {
		#expect(DocumentBar.room(clearing: [22, 42, 62], inFullScreen: false) == 82)
	}

	/// Nothing to clear in full screen. Asking the buttons AppKit left behind
	/// gives their last windowed frame, which is a measurement of where they
	/// used to be — eighty-two points of nothing at the leading edge, and the
	/// capsule sitting where furniture that is no longer there had pushed it.
	@Test func fullScreenKeepsNoRoomForButtonsThatAreNotThere() {
		let full = DocumentBar.room(clearing: [22, 42, 62], inFullScreen: true)
		#expect(full == DocumentBar.edgeOfTheScreen)
		#expect(full < DocumentBar.room(clearing: [22, 42, 62], inFullScreen: false))
	}

	/// A window with the buttons taken away falls back rather than sitting the
	/// capsule in the corner.
	@Test func noButtonsAtAllFallsBackToTheOldNumber() {
		#expect(DocumentBar.room(clearing: [], inFullScreen: false)
			== DocumentBar.trafficLights)
	}

	// MARK: - Against a real window

	@Test func aRealWindowsButtonsAreCleared() {
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
		                      styleMask: [.titled, .closable, .miniaturizable, .resizable,
		                                  .fullSizeContentView],
		                      backing: .buffered, defer: false)
		guard let zoom = window.standardWindowButton(.zoomButton) else {
			Issue.record("no traffic lights on a titled window"); return
		}
		#expect(DocumentBar.roomForTrafficLights(in: window) == zoom.frame.maxX + 20)
	}

	/// Hidden buttons are not buttons. They can be taken away without the style
	/// mask saying anything about it.
	@Test func buttonsThatAreHiddenAreNotMeasured() {
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
		                      styleMask: [.titled, .closable, .miniaturizable, .resizable],
		                      backing: .buffered, defer: false)
		for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
			window.standardWindowButton(kind)?.isHidden = true
		}
		#expect(DocumentBar.roomForTrafficLights(in: window) == DocumentBar.trafficLights)
	}

	// MARK: - The toolbar getting out of the way

	/// The empty toolbar is what makes the 52-point band and centres the
	/// traffic lights in it. Full screen has neither of those to do, and an
	/// empty toolbar AppKit still draws sits across the top of a content view
	/// that now runs to the top of the screen — over the capsule and the clock.
	@Test func theEmptyToolbarStepsAsideInFullScreen() {
		let place = DocumentPlace(size: NSSize(width: 900, height: 600))
		let toolbar = place.window.toolbar
		#expect(toolbar != nil, "the band is made by a toolbar and there is not one")
		#expect(toolbar?.isVisible == true)

		place.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification))
		#expect(toolbar?.isVisible == false, "the toolbar is still over the bar in full screen")

		place.windowWillExitFullScreen(Notification(name: NSWindow.willExitFullScreenNotification))
		#expect(toolbar?.isVisible == true, "the band did not come back")
	}

	/// The bar is content, not titlebar, and that is the whole of why it is on
	/// screen in full screen at all. Moving it into an
	/// `NSTitlebarAccessoryViewController` is the tidy-looking change that
	/// would lose it, so the arrangement is written down here.
	@Test func theBarLivesInTheContentView() {
		let place = DocumentPlace(size: NSSize(width: 900, height: 600))
		let bar = place.window.contentView?.subviews.contains { $0 is DocumentBar }
		#expect(bar == true, "the bar is not in the content view")
		#expect(place.window.titlebarAccessoryViewControllers.isEmpty,
		        "the bar has moved into the titlebar, where full screen hides it")
		#expect(place.window.styleMask.contains(.fullSizeContentView),
		        "without this the content stops below the titlebar")
	}
}
