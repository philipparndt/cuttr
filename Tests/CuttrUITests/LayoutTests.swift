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
}
