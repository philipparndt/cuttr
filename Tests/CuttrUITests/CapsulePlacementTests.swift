import AppKit
import Testing
@testable import CuttrCompose
@testable import CuttrUI

/// Where the capsule starts, which is not a number somebody gets to choose.
@MainActor @Suite struct CapsulePlacementTests {

	private func gap(in window: NSWindow?) -> CGFloat? {
		guard let window else { return nil }
		window.makeKeyAndOrderFront(nil)
		window.layoutIfNeeded()
		let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
			.compactMap { window.standardWindowButton($0) }
		guard let right = buttons.map({ $0.convert($0.bounds, to: nil).maxX }).max() else { return nil }
		func find(_ view: NSView) -> NSView? {
			if view is DocumentCapsule { return view }
			for sub in view.subviews { if let hit = find(sub) { return hit } }
			return nil
		}
		guard let capsule = window.contentView.flatMap(find) else { return nil }
		return capsule.convert(capsule.bounds, to: nil).minX - right
	}

	/// It used to be 78 while the buttons ended at 79, so the capsule sat one
	/// point over the zoom button — close enough to look deliberate.
	@Test func theCapsuleClearsTheTrafficLights() throws {
		let take = MainWindowController(document: TakeDocument())
		let project = ComposeWindowController(document: ComposeDocument())
		for window in [take.windowForTesting, project.windowForTesting] {
			guard let gap = gap(in: window) else {
				Issue.record("no capsule in the window")
				continue
			}
			#expect(gap > 8)
			// And not adrift on the other side either.
			#expect(gap < 40)
		}
	}
}
