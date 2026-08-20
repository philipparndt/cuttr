import AppKit
import Testing
@testable import CuttrCompose
@testable import CuttrUI

/// Window tabbing, which this program does not use.
///
/// The document switcher in the title bar is how you get from one take to
/// another, and the bar is drawn by the program — so a tab bar arriving above
/// it lands on top of the window's own furniture.
///
/// Neither of these was enough, and it is worth knowing why. `tabbingMode`
/// declines *automatic* tabbing; it does not refuse an explicit
/// `addTabbedWindow`, which `AppDelegate.present(_:)` was calling on every
/// window it opened. So a group was formed anyway, and the observer these tests
/// stand in for then tore it apart on the very notification the tabbing caused.
/// `DocumentPlaceTests.nothingIsEverPutInATabGroup` is the one that checks no
/// group is ever formed in the first place.
@MainActor @Suite struct WindowTabbingTests {

	/// Every window says no. This is the part that was already true, and it is
	/// not sufficient on its own: it stops a window joining a group, and does
	/// nothing about a group macOS restored from a previous launch.
	@Test func noWindowJoinsATabGroup() throws {
		let cutting = MainWindowController(document: TakeDocument())
		let composing = ComposeWindowController(document: ComposeDocument())
		#expect(cutting.windowForTesting.tabbingMode == .disallowed)
		#expect(composing.windowForTesting.tabbingMode == .disallowed)
		// Including the scene window, which used to ask to be a tab of the
		// project it belongs to.
		var project = Project()
		project.scenes = ["card": Scene()]
		let scene = SceneWindowController(
			document: SceneDocument(project: project, baseURL: nil, name: "card"),
			projectURL: nil)
		#expect(scene.windowForTesting.tabbingMode == .disallowed)
	}

	/// And a window that finds itself in one leaves. Two windows are put in a
	/// group by hand — which is what a restored arrangement amounts to — and
	/// the one that becomes key takes itself out.
	@Test func aWindowThatWakesUpInAGroupLeavesIt() throws {
		let first = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
		                     styleMask: [.titled, .closable], backing: .buffered, defer: false)
		let second = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
		                      styleMask: [.titled, .closable], backing: .buffered, defer: false)
		first.addTabbedWindow(second, ordered: .above)
		#expect(first.tabGroup?.windows.count == 2)

		// The same thing the delegate does when a window becomes key.
		if let group = second.tabGroup, group.windows.count > 1 {
			second.moveTabToNewWindow(nil)
		}
		#expect(second.tabGroup?.windows.count ?? 1 == 1)
		#expect(first.tabGroup?.windows.count ?? 1 == 1)
	}
}
