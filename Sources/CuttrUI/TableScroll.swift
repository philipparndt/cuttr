import AppKit

/// Every scroll view in the program, made the same way.
///
/// Which is: the way AppKit makes them. Scrollbars are the framework's job —
/// which way round they go, how wide they are, whether they float over the
/// content or take room from it, whether they are always visible because
/// somebody chose that in System Settings. None of that is this program's
/// business, and every line here that tried to help made it worse: hand-built
/// `NSScroller`s, a forced `scrollerStyle` overriding what the person using the
/// machine asked for. All of it is gone.
///
/// Two decisions are genuinely ours and stay. A scroll view is created with a
/// real frame rather than at zero, because a view sized 0×0 sets its parts up
/// against a degenerate rectangle before autolayout has said anything — the one
/// way this does go wrong by itself. And a list of a single column says it never
/// scrolls sideways, so no horizontal scrollbar is ever asked for: not hidden,
/// not autohidden, not there.
@MainActor
enum TableScroll {

	/// A table with several columns worth reading: they keep the widths they
	/// were given and the pane scrolls sideways to reach them, because letting
	/// AppKit squeeze them to fit makes the ones on the right — which is where
	/// tags and paths live — unreadable slivers.
	static func make(_ table: NSTableView) -> NSScrollView {
		table.columnAutoresizingStyle = .noColumnAutoresizing
		return wrap(table)
	}

	/// A list of one column, which fills the pane and never scrolls sideways.
	static func fitting(_ table: NSTableView) -> NSScrollView {
		table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
		let scroll = wrap(table, horizontal: false)
		table.autoresizingMask = [.width]
		return scroll
	}

	/// A scroll view around anything.
	static func wrap(_ view: NSView, horizontal: Bool = true) -> NSScrollView {
		let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 260))
		scroll.hasVerticalScroller = true
		scroll.hasHorizontalScroller = horizontal
		scroll.autohidesScrollers = true
		scroll.drawsBackground = false
		scroll.documentView = view
		return scroll
	}
}
