import AppKit

/// Every scroll view in the program, made the same way.
///
/// `NSScroller` decides whether it is horizontal or vertical from the *shape of
/// its frame* when it is created, and a scroll view built before autolayout has
/// given it a size creates both against a degenerate frame — so the horizontal
/// one comes up vertical: a short capsule standing on end in the bottom-right
/// corner, where a scrollbar should be lying down.
///
/// Handing it two correctly shaped scrollers is the fix, but only in this order:
/// `hasHorizontalScroller` has to be true *before* `horizontalScroller` is
/// assigned, or the assignment is dropped on the floor and AppKit keeps the one
/// it made itself. That is the bit the previous attempt got wrong, and it is
/// why the same stub kept coming back.
///
/// Overlay scrollers on top of that: they are drawn over the content as a knob
/// that fades, so nothing is reserved, nothing is tiled, and a table that fits
/// shows no furniture at all.
@MainActor
enum TableScroll {

	static func make(_ table: NSTableView) -> NSScrollView {
		// Columns keep the widths they were given; the pane scrolls to reach
		// them. Letting AppKit squeeze them to fit makes the ones on the right —
		// which is where tags and paths live — unreadable slivers.
		table.columnAutoresizingStyle = .noColumnAutoresizing
		return wrap(table)
	}

	/// A scroll view around anything, with both scrollers the right way round.
	static func wrap(_ view: NSView, horizontal: Bool = true) -> NSScrollView {
		let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 260))
		scroll.hasVerticalScroller = true
		scroll.hasHorizontalScroller = horizontal
		// Wider than tall, and taller than wide. That is the whole trick — and
		// it only counts after the two lines above.
		scroll.verticalScroller = NSScroller(frame: NSRect(x: 0, y: 0, width: 15, height: 200))
		if horizontal {
			scroll.horizontalScroller = NSScroller(frame: NSRect(x: 0, y: 0, width: 200, height: 15))
		}
		scroll.scrollerStyle = .overlay
		scroll.autohidesScrollers = true
		scroll.drawsBackground = false
		scroll.documentView = view
		return scroll
	}
}
