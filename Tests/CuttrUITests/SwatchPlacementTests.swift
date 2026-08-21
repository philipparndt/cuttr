import AppKit
import Foundation
import Testing
@testable import CuttrKit
@testable import CuttrUI

/// Where the lane colours live.
///
/// Which lane the next cut goes on is true of the whole window: the timeline
/// draws every lane, the words pane cuts on to one, and the mark key marks on
/// one. On the clips pane's heading it was a window-level choice living in one
/// of four panes, and gone from the screen whenever that pane was folded away.
@MainActor @Suite struct SwatchPlacementTests {

	private func find<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
		view.subviews.flatMap { subview -> [T] in
			((subview as? T).map { [$0] } ?? []) + find(type, in: subview)
		}
	}

	@Test func theLaneColoursAreInTheBar() throws {
		_ = NSApplication.shared
		let controller = MainWindowController(document: TakeDocument())
		defer { controller.window?.close() }
		let window = controller.windowForTesting
		window.setContentSize(NSSize(width: 1400, height: 900))
		window.layoutIfNeeded()
		let root = window.contentView!
		let swatches = find(ColorSwatches.self, in: root)
		#expect(swatches.count == 1)
		let bars = find(DocumentBar.self, in: root)
		#expect(bars.count == 1)
		guard let swatch = swatches.first, let bar = bars.first else { return }
		// In the bar, and therefore not inside any pane.
		#expect(find(ColorSwatches.self, in: bar).count == 1)
		#expect(find(PaneBox.self, in: root).allSatisfy {
			find(ColorSwatches.self, in: $0).isEmpty
		})
		// And still six of them, one per lane, all clickable.
		#expect(find(NSButton.self, in: swatch).count == ClipColor.allCases.count)
	}
}
