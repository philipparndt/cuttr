import AppKit
import CuttrCompose
import CuttrKit
import Testing
@testable import CuttrUI

/// The panel has to stand still.
///
/// Selecting a different thing changes what the form says, not where it is.
/// Every key starts at the same place down the left edge, and the form does not
/// move sideways because one selection happens to have a wider control in it —
/// which it did, because a picture spanning both columns handed its width to
/// the column of keys to share.
@Suite @MainActor struct LayoutTests {

	private func project() -> Project {
		Project(
			timeline: [
				TimelineEntry(clip: ClipReference("intro")),
				TimelineEntry(group: "middle", entries: [TimelineEntry(clip: ClipReference("demo"))]),
			],
			overlays: [
				Overlay(kind: .text("A caption long enough to matter", style: nil),
				        span: .clips(from: ClipReference("intro"), to: ClipReference("intro"))),
				Overlay(kind: .spinner(Spinner(words: [SpinnerWord("one")])),
				        spans: [.times(from: 0, to: 4), .times(from: 8, to: 12)],
				        anchor: "mia-eye"),
			])
	}

	private func keyOrigins(_ panel: PropertiesPanel) -> [CGFloat] {
		func labels(in view: NSView) -> [NSTextField] {
			view.subviews.flatMap { subview -> [NSTextField] in
				((subview as? NSTextField).map { [$0] } ?? []) + labels(in: subview)
			}
		}
		return labels(in: panel)
			.filter { !$0.isEditable && $0.font == Theme.mono && !$0.stringValue.isEmpty }
			.map { $0.convert($0.bounds, to: panel).minX }
	}

	@Test func everySelectionPutsTheKeysInTheSamePlace() {
		_ = NSApplication.shared
		let panel = PropertiesPanel()
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 900),
		                      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
		window.contentView = panel

		let project = self.project()
		var seen: Set<CGFloat> = []
		for selection: ProjectSelection in [.output, .entry([0]), .entry([1]), .overlay(0), .overlay(1)] {
			panel.reload(project, vocabulary: ComposeDocument.Vocabulary(), selection: selection)
			panel.layoutSubtreeIfNeeded()
			let origins = keyOrigins(panel)
			#expect(!origins.isEmpty, "no keys for \(selection)")
			// Every key in one form starts at the same x…
			#expect(Set(origins).count == 1, "ragged keys for \(selection): \(Set(origins).sorted())")
			seen.formUnion(origins)
		}
		// …and it is the same x in every form.
		#expect(seen.count == 1, "the form moves between selections: \(seen.sorted())")
	}

	/// The form fits whatever width the pane has.
	///
	/// A control that insists on its ideal width in a pane narrower than that is
	/// how a form comes to need a horizontal scrollbar — and then the scrollbar
	/// takes height, which changes the layout, which is the flicker.
	@Test func theFormFitsEveryWidthItIsGiven() {
		_ = NSApplication.shared
		let panel = PropertiesPanel()
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 900),
		                      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
		window.contentView = panel
		panel.reload(project(), vocabulary: ComposeDocument.Vocabulary(), selection: .overlay(1))

		for width in [300.0, 340.0, 420.0, 560.0, 700.0] {
			window.setContentSize(NSSize(width: width, height: 900))
			panel.layoutSubtreeIfNeeded()
			for row in rows(of: panel) {
				#expect(row.frame.width <= width + 0.5,
				        "a row is \(row.frame.width) wide in a \(width) pane")
			}
		}
	}

	/// Laying out twice must change nothing.
	///
	/// Anything that answers differently the second time is a loop, and a loop
	/// is what the window flickering actually is: two views taking turns to be
	/// right about a size.
	@Test func layingOutTwiceSettles() {
		_ = NSApplication.shared
		let panel = PropertiesPanel()
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 820),
		                      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
		window.contentView = panel

		for selection: ProjectSelection in [.output, .overlay(0), .overlay(1), .entry([1])] {
			panel.reload(project(), vocabulary: ComposeDocument.Vocabulary(), selection: selection)
			panel.layoutSubtreeIfNeeded()
			let first = geometry(of: panel)
			panel.needsLayout = true
			panel.layoutSubtreeIfNeeded()
			#expect(geometry(of: panel) == first, "the layout moved on its own for \(selection)")
		}
	}

	/// Every row of the form.
	private func rows(of panel: PropertiesPanel) -> [NSView] {
		func stacks(in view: NSView) -> [NSStackView] {
			view.subviews.flatMap { subview -> [NSStackView] in
				((subview as? NSStackView).map { [$0] } ?? []) + stacks(in: subview)
			}
		}
		guard let form = stacks(in: panel).first(where: { $0.orientation == .vertical }) else { return [] }
		return form.arrangedSubviews
	}

	private func geometry(of view: NSView) -> [String] {
		view.subviews.flatMap { subview in
			["\(type(of: subview)) \(NSStringFromRect(subview.frame))"] + geometry(of: subview)
		}
	}
}
/// The toolbar has three places, and things stay in theirs.
@Suite @MainActor struct ComposeBarTests {

	@Test func whereYouAreIsLeftWhatYouCanDoIsRight() {
		_ = NSApplication.shared
		let bar = ComposeBar()
		bar.setStatus("00:12.345")
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 38),
		                      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
		window.contentView = bar
		bar.frame = NSRect(x: 0, y: 0, width: 1200, height: 38)
		bar.layoutSubtreeIfNeeded()

		func find<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
			view.subviews.flatMap { subview -> [T] in
				((subview as? T).map { [$0] } ?? []) + find(type, in: subview)
			}
		}
		let render = find(NSButton.self, in: bar).first { $0.title == "Render…" }
		let modes = find(NSSegmentedControl.self, in: bar).first
		let clock = find(NSTextField.self, in: bar).first { $0.stringValue == "00:12.345" }

		let renderFrame = try! #require(render).convert(render!.bounds, to: bar)
		let modesFrame = try! #require(modes).convert(modes!.bounds, to: bar)
		let clockFrame = try! #require(clock).convert(clock!.bounds, to: bar)

		#expect(modesFrame.minX < 20, "the modes are not on the left: \(modesFrame)")
		#expect(renderFrame.maxX > bar.bounds.width - 120,
		        "render is not on the right: \(renderFrame)")
		#expect(abs(clockFrame.midX - bar.bounds.midX) < 12,
		        "the clock is not centred: \(clockFrame.midX) against \(bar.bounds.midX)")
		#expect(clockFrame.minX > modesFrame.maxX)
		#expect(clockFrame.maxX < renderFrame.minX)
	}
}

/// The anchors switch belongs to the picture.
@Suite @MainActor struct AnchorSwitchTests {

	@Test func itIsOnlyThereOnThePreview() {
		_ = NSApplication.shared
		let bar = ComposeBar()
		func anchors(in view: NSView) -> NSButton? {
			for subview in view.subviews {
				if let button = subview as? NSButton, button.title == "Anchors" { return button }
				if let found = anchors(in: subview) { return found }
			}
			return nil
		}
		let button = anchors(in: bar)
		#expect(button != nil)
		bar.setMode(0)
		#expect(button?.isHidden == true, "the editor has no picture to put markers on")
		bar.setMode(2)
		#expect(button?.isHidden == false)
		bar.setMode(1)
		#expect(button?.isHidden == true)
	}
}

/// The file fragment is a teaching pane, not a working one.
@Suite @MainActor struct WritesPaneTests {

	@Test func itStartsFoldedAndOpensWhenAsked() {
		_ = NSApplication.shared
		let inspector = ProjectInspector()
		inspector.reload(Project(timeline: [TimelineEntry(clip: ClipReference("intro"))]),
		                 vocabulary: ComposeDocument.Vocabulary())
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
		                      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
		window.contentView = inspector
		inspector.layoutSubtreeIfNeeded()

		func text(in view: NSView) -> NSTextView? {
			for subview in view.subviews {
				if let found = subview as? NSTextView { return found }
				if let found = text(in: subview) { return found }
			}
			return nil
		}
		func button(in view: NSView) -> NSButton? {
			for subview in view.subviews {
				if let found = subview as? NSButton,
				   found.attributedTitle.string.contains("WHAT THIS WRITES") { return found }
				if let found = button(in: subview) { return found }
			}
			return nil
		}

		let fragment = text(in: inspector)
		#expect(fragment != nil)
		let folded = fragment?.enclosingScrollView?.frame.height ?? 0
		#expect(folded < 4, "the fragment pane is open to begin with: \(folded)")

		button(in: inspector)?.performClick(nil)
		inspector.layoutSubtreeIfNeeded()
		#expect((fragment?.enclosingScrollView?.frame.height ?? 0) > 100)
	}
}
