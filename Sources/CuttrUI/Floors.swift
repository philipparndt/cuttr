import AppKit

/// How small a pane may be made — said so that it can lose.
///
/// A floor is the natural thing to write as a *required* constraint: this list
/// must never be squeezed to nothing. It is also the shape of a crash. A floor
/// applies to a view whose height somebody else decides — a split view sizes
/// its arranged subviews, a tab view gives the item that is not selected no
/// size at all, and a window has no size until it is given one. When the
/// container's height is zero, or is fixed at less than the sum of the floors
/// inside it, a required floor is one half of a system with no solution.
///
/// Autolayout's answer to that is to break one of the constraints, log
/// `layout constraints are not satisfiable`, and mark the window as needing
/// another pass to look for an arrangement that works. Through nested split
/// views and the scroll views inside them, looking again is expensive, and a
/// window is allowed only so many passes before AppKit raises
/// `The window has been marked as needing another Layout Window pass, but it
/// has already had more … than there are views in the window` out of the layout
/// pass — which AppKit turns into a crash. Two of those shipped.
///
/// Just under required says the same thing about every arrangement that is
/// possible, and gives way on the ones that are not: a floor at 999 beats every
/// preference in this program — a split view remembers a dragged divider at 250,
/// panes ask for their preferred size at 250 — while never being half of an
/// unsatisfiable pair. Nothing is broken, so nothing is re-added and re-broken,
/// so the pass settles.
///
/// The precedent is already here: `ProjectInspector` holds the tree's width at
/// 700 for exactly this reason.
extension NSLayoutConstraint {

	/// This constraint is a floor: it should win, but it must be able to lose.
	var asFloor: NSLayoutConstraint {
		priority = .floor
		return self
	}
}

extension NSLayoutConstraint.Priority {

	/// Above every preference in this program, below `required`.
	static let floor = NSLayoutConstraint.Priority(999)
}

/// A frame big enough to lay a window's furniture out in.
///
/// Views are assembled before anything has been told how big it is, and a view
/// created at 0×0 does not stay neutral about that: its autoresizing mask turns
/// the zero frame into `width == 0` and `height == 0` at *required* priority,
/// and every content minimum inside it is then half of a system with no
/// solution. The number does not matter and is never seen — the real size
/// arrives the moment the window has one — it only has to be roomy.
///
/// `TableScroll` already records the same lesson for scroll views.
extension CGRect {
	static var roomToLayOutIn: NSRect { NSRect(x: 0, y: 0, width: 1200, height: 800) }
}
