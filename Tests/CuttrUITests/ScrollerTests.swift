import AppKit
import CuttrCompose
import Testing
@testable import CuttrUI

/// The scrollbar that kept coming back standing on end.
///
/// Guessed at three times and fixed none of them, because nothing here could be
/// seen except by looking at the window. It can be: `NSScroller` reports the
/// rectangle it will draw its knob in, and a horizontal scroller's knob is
/// wider than it is tall. A scroller that thinks it is vertical says so.
@Suite @MainActor struct ScrollerTests {

	/// A scroll view with more table than room, tiled the way a window would.
	private func scroller(horizontal: Bool) -> NSScroller? {
		_ = NSApplication.shared
		let table = NSTableView()
		for index in 0..<4 {
			let column = NSTableColumn(identifier: .init("c\(index)"))
			column.width = 300
			table.addTableColumn(column)
		}
		let scroll = TableScroll.make(table)
		scroll.frame = NSRect(x: 0, y: 0, width: 220, height: 120)
		table.frame = NSRect(x: 0, y: 0, width: 1200, height: 900)
		scroll.tile()
		scroll.layoutSubtreeIfNeeded()
		return horizontal ? scroll.horizontalScroller : scroll.verticalScroller
	}

	@Test func theHorizontalScrollerLiesDown() throws {
		let scroller = try #require(self.scroller(horizontal: true))
		scroller.knobProportion = 0.5
		let knob = scroller.rect(for: .knob)
		#expect(knob.width > knob.height, "the horizontal scroller is standing on end: \(knob)")
	}

	@Test func theVerticalScrollerStandsUp() throws {
		let scroller = try #require(self.scroller(horizontal: false))
		scroller.knobProportion = 0.5
		let knob = scroller.rect(for: .knob)
		#expect(knob.height > knob.width, "the vertical scroller is lying down: \(knob)")
	}
}

/// What the window actually builds, in a window, at a size somebody uses.
@Suite @MainActor struct ScrollerInPlaceTests {

	private func window(_ content: NSView) -> NSWindow {
		_ = NSApplication.shared
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
		                      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
		window.contentView = content
		content.frame = window.contentView?.bounds ?? .zero
		window.layoutIfNeeded()
		content.layoutSubtreeIfNeeded()
		return window
	}

	private func scrollers(in view: NSView) -> [NSScroller] {
		view.subviews.flatMap { subview -> [NSScroller] in
			(subview as? NSScroller).map { [$0] } ?? scrollers(in: subview)
		}
	}

	/// An empty list has nothing to scroll, so it should show no scrollbar at
	/// all — not a stub in the corner.
	@Test func anEmptyListShowsNoScroller() {
		let panel = ProgrammePanel()
		panel.reload(Project(), vocabulary: ComposeDocument.Vocabulary())
		let window = self.window(panel)
		_ = window
		panel.layoutSubtreeIfNeeded()

		let showing = scrollers(in: panel).filter { !$0.isHidden && $0.alphaValue > 0 }
		#expect(showing.isEmpty, "scrollers on an empty list: \(showing.map(\.frame))")
	}
}
