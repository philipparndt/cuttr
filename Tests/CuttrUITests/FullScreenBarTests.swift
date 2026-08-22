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
}
