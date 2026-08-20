import AppKit
import CuttrCompose
import CuttrKit
import ObjectiveC
import Testing
@testable import CuttrUI

/// Every constraint AppKit has to break, as it breaks it.
///
/// Two crashes came from the same shape and neither was caught by a test that
/// looked at the result of a layout. Both were *required* constraints that could
/// not all hold — a folded pane's height against the floor the window put under
/// it, and a folded pane's zero-height content against the room a table's scroll
/// view insists on. Autolayout does not refuse those. It breaks one, logs
/// `layout constraints are not satisfiable`, and marks the window as needing
/// another pass to look for an arrangement that works; and through nested split
/// views that costs so many passes that AppKit raises
/// `The window has been marked as needing another Layout Window pass, but it has
/// already had more … than there are views in the window` out of the layout pass,
/// which it turns into a crash.
///
/// A test that asserts on frames only notices when the damage happens to be
/// visible at the size it chose. This notices the cause: AppKit calls
/// `engine:willBreakConstraint:dueToMutuallyExclusiveConstraints:` on a view
/// every single time, so hooking that catches the next one wherever it is.
@MainActor
enum ConstraintConflicts {

	/// Only conflicts in the window under test, because the hook is
	/// process-wide and other suites build windows of their own.
	nonisolated(unsafe) static weak var watching: NSWindow?
	nonisolated(unsafe) static var reports: [String] = []
	nonisolated(unsafe) private static var hooked = false

	static func watch(_ window: NSWindow) {
		hook()
		reports = []
		watching = window
	}

	static func stop() {
		watching = nil
	}

	private static func hook() {
		guard !hooked else { return }
		hooked = true
		let selector = NSSelectorFromString(
			"engine:willBreakConstraint:dueToMutuallyExclusiveConstraints:")
		guard let method = class_getInstanceMethod(NSView.self, selector) else {
			Issue.record("AppKit no longer reports broken constraints this way")
			return
		}
		let original = method_getImplementation(method)
		typealias Fn = @convention(c) (AnyObject, Selector, AnyObject,
		                               NSLayoutConstraint, NSArray) -> Void
		let block: @convention(block) (AnyObject, AnyObject, NSLayoutConstraint,
		                              NSArray) -> Void = { view, engine, breaking, among in
			if let view = view as? NSView, view.window != nil, view.window === watching {
				let all = ((among as? [NSLayoutConstraint]) ?? []).map { "\($0)" }
				reports.append("broke \(breaking) among:\n    "
					+ all.joined(separator: "\n    "))
			}
			unsafeBitCast(original, to: Fn.self)(view, selector, engine, breaking, among)
		}
		method_setImplementation(method, imp_implementationWithBlock(block))
	}

	/// What went wrong, ready to put in a failure message.
	static var complaint: String {
		"\(reports.count) constraint conflict(s):\n" + reports.prefix(3).joined(separator: "\n")
	}
}

/// Nothing either window does to itself may leave autolayout with a system it
/// cannot solve.
@Suite(.serialized) @MainActor struct ConstraintConflictTests {

	private func take() -> Take {
		var clips: [Clip] = []
		for i in 0..<24 {
			clips.append(Clip(slug: "clip-\(i)", name: "clip number \(i)",
			                  start: Double(i) * 3, end: Double(i) * 3 + 2.5,
			                  note: "a note about clip \(i)", tags: ["b-roll", "tag-\(i % 4)"]))
		}
		var take = Take(video: "a.mov", clips: clips)
		// Anchors matter: the table that would not settle was the one with rows
		// in it, and an empty table is laid out against a different rectangle.
		for i in 0..<6 {
			_ = take.add(Anchor(name: "anchor-\(i)", from: Double(i), to: Double(i) + 5,
			                    markedAt: Double(i), point: CGPoint(x: 0.5, y: 0.5)))
		}
		return take
	}

	private func project() -> Project {
		Project(
			timeline: [
				TimelineEntry(clip: ClipReference("clip-0")),
				TimelineEntry(group: "section", entries: [
					TimelineEntry(clip: ClipReference("clip-1")),
					TimelineEntry(clip: ClipReference("clip-2")),
				]),
			],
			overlays: [
				Overlay(kind: .text("A caption long enough to matter", style: nil),
				        span: .clips(from: ClipReference("clip-0"), to: ClipReference("clip-0"))),
			])
	}

	/// Collapsing a pane, at every size the column is worth having.
	///
	/// This is the gesture that crashed, twice.
	@Test func collapsingAPaneNeverLeavesAnUnsolvableLayout() {
		_ = NSApplication.shared
		let controller = MainWindowController(document: TakeDocument(take: take()))
		guard let window = controller.window, let content = window.contentView else {
			Issue.record("no window"); return
		}
		window.setContentSize(NSSize(width: 1500, height: 1000))
		window.layoutIfNeeded()

		func panes(in view: NSView) -> [FoldingPane] {
			view.subviews.flatMap { sub -> [FoldingPane] in
				((sub as? FoldingPane).map { [$0] } ?? []) + panes(in: sub)
			}
		}
		let folded = panes(in: content)
		ConstraintConflicts.watch(window)

		for height in [1000.0, 880.0, 760.0, 660.0, window.minSize.height] {
			window.setContentSize(NSSize(width: 1400, height: height))
			window.layoutIfNeeded()
			for pane in folded {
				pane.fold(true)
				window.layoutIfNeeded()
				pane.fold(false)
				window.layoutIfNeeded()
			}
			// And all of them at once, where the panes cannot add up to the
			// column however hard they try.
			for pane in folded { pane.fold(true) }
			window.layoutIfNeeded()
			for pane in folded { pane.fold(false) }
			window.layoutIfNeeded()
		}
		#expect(ConstraintConflicts.reports.isEmpty, "\(ConstraintConflicts.complaint)")
		ConstraintConflicts.stop()
		window.close()
	}

	/// Building the compose window and using all three of its modes.
	///
	/// Its panes are three deep in split views inside a tab view, and a tab
	/// view gives the item that is not showing no size at all — which is when a
	/// required floor has nothing it can be satisfied by.
	@Test func theComposeWindowNeverLeavesAnUnsolvableLayout() {
		_ = NSApplication.shared
		let document = ComposeDocument(project: project())
		let controller = ComposeWindowController(document: document)
		guard let window = controller.window, let content = window.contentView else {
			Issue.record("no window"); return
		}
		ConstraintConflicts.watch(window)
		window.setContentSize(NSSize(width: 1600, height: 1000))
		window.layoutIfNeeded()

		for mode in [ComposeWindowController.Mode.edit, .text, .preview, .edit] {
			controller.show(mode)
			window.layoutIfNeeded()
			for size in [NSSize(width: 1600, height: 1000), NSSize(width: 1300, height: 840),
			             NSSize(width: 1050, height: 700), NSSize(width: 1800, height: 1100)] {
				window.setContentSize(size)
				window.layoutIfNeeded()
			}
			// Every row of the programme, which rebuilds the properties column
			// beside it — fifteen possible sections in a scroll view.
			guard mode == .edit else { continue }
			for outline in outlines(in: content) {
				for row in 0..<outline.numberOfRows {
					outline.selectRowIndexes([row], byExtendingSelection: false)
					window.layoutIfNeeded()
				}
			}
		}
		#expect(ConstraintConflicts.reports.isEmpty, "\(ConstraintConflicts.complaint)")
		ConstraintConflicts.stop()
		window.close()
	}

	private func outlines(in view: NSView) -> [NSOutlineView] {
		view.subviews.flatMap { sub -> [NSOutlineView] in
			((sub as? NSOutlineView).map { [$0] } ?? []) + outlines(in: sub)
		}
	}
}
