import AppKit

/// A scroll view for a table, with scrollers that know which way round they go.
///
/// `NSScroller` decides whether it is horizontal or vertical from the *shape of
/// its frame* when it is created. A scroll view built before autolayout has
/// given it a size creates both scrollers against a degenerate frame, and the
/// horizontal one comes up vertical: a short capsule standing on end in the
/// bottom-right corner, staying there until a resize forces a second pass.
///
/// So both are made here with frames that are unmistakably one shape or the
/// other. Two lines, and they are the difference between a scrollbar and a
/// smudge.
///
/// Three tables wanted the same six lines of setup, which is the other reason
/// this exists: the previous two attempts at fixing this had to be made three
/// times each, and the third one drifted.
@MainActor
enum TableScroll {

	static func make(_ table: NSTableView) -> NSScrollView {
		let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 260))

		// Wider than tall, and taller than wide. That is the whole trick.
		scroll.horizontalScroller = NSScroller(frame: NSRect(x: 0, y: 0, width: 200, height: 15))
		scroll.verticalScroller = NSScroller(frame: NSRect(x: 0, y: 0, width: 15, height: 200))
		scroll.hasHorizontalScroller = true
		scroll.hasVerticalScroller = true
		scroll.autohidesScrollers = true
		scroll.drawsBackground = false

		// Columns keep the widths they were given; the pane scrolls to reach
		// them. Letting AppKit squeeze them to fit makes the ones on the right —
		// which is where tags and paths live — unreadable slivers.
		table.columnAutoresizingStyle = .noColumnAutoresizing
		scroll.documentView = table
		return scroll
	}
}
