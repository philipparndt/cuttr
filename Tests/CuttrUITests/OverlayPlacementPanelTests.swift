import AppKit
import CuttrCompose
import CuttrKit
import Testing
@testable import CuttrUI

/// `at:` in the properties panel, driven rather than looked at.
///
/// The panel is where somebody will go looking for this: `in:` and `out:` are
/// already there, and a placement that could only be typed into the file would
/// be a placement half the program knew about. So the row that offers the
/// transition offers where it sits, and nowhere else has to change.
///
/// Popups are driven through their own target and action rather than by sending
/// a key event: an unhandled key press reaches `NSResponder` and beeps on the
/// machine the test is running on.
@Suite @MainActor struct OverlayPlacementPanelTests {

	private func project(_ arrival: Overlay.Transition) -> Project {
		Project(
			output: Output(width: 1920, height: 1080, framesPerSecond: 25),
			timeline: [TimelineEntry(clip: ClipReference("intro"))],
			overlays: [Overlay(kind: .text("hello", style: nil),
			                   span: .times(from: 0, to: 4),
			                   arrival: arrival, departure: .cut)])
	}

	private func popups(in view: NSView) -> [NSPopUpButton] {
		view.subviews.flatMap { subview -> [NSPopUpButton] in
			if let popup = subview as? NSPopUpButton { return [popup] }
			return popups(in: subview)
		}
	}

	private func panel(_ start: Project) -> (PropertiesPanel, () -> Project) {
		_ = NSApplication.shared
		let panel = PropertiesPanel()
		final class Box { var project: Project; init(_ p: Project) { project = p } }
		let box = Box(start)
		panel.onChange = { [weak panel] next in
			box.project = next
			panel?.reload(next, vocabulary: ComposeDocument.Vocabulary(),
			              selection: .overlay(.project(0)))
		}
		panel.reload(start, vocabulary: ComposeDocument.Vocabulary(),
		             selection: .overlay(.project(0)))
		return (panel, { box.project })
	}

	/// The popup that offers the three placements, whichever row it is on.
	private func placements(in panel: PropertiesPanel) -> [NSPopUpButton] {
		let titles = Set(Overlay.Transition.Placement.allCases.map(\.title))
		return popups(in: panel).filter { Set($0.itemTitles) == titles }
	}

	/// A movement with a length gets the popup; a cut does not, because a cut is
	/// an instant and there is nothing to put either side of the mark.
	@Test func onlyAMovementWithALengthIsOfferedAPlacement() {
		let (fading, _) = panel(project(.fade(over: 0.4)))
		#expect(placements(in: fading).count == 1, "the arrival fades, the departure cuts")

		let (cutting, _) = panel(project(.cut))
		#expect(placements(in: cutting).isEmpty, "two cuts, nothing to place")
	}

	/// Choosing one writes it, and the row comes back showing it.
	@Test func choosingAPlacementWritesIt() {
		let (panel, project) = self.panel(project(.fade(over: 0.4)))
		#expect(project().overlays[0].arrivalPlacement == .after)

		guard let popup = placements(in: panel).first,
		      let action = popup.action,
		      let index = popup.itemTitles.firstIndex(of: Overlay.Transition.Placement.before.title)
		else {
			Issue.record("the panel offered no placement to choose")
			return
		}
		popup.selectItem(at: index)
		_ = popup.target?.perform(action, with: popup)
		#expect(project().overlays[0].arrivalPlacement == .before)
		// And the departure, which was a cut, is untouched — the two ends have
		// different defaults and one row must not answer for the other.
		#expect(project().overlays[0].departurePlacement == .before)
		#expect(project().overlays[0].departure == .cut)

		// The reloaded row shows what was chosen rather than the default.
		let shown = placements(in: panel).first
		#expect(shown?.titleOfSelectedItem == Overlay.Transition.Placement.before.title)
	}

	/// A bubble is offered it too. It is one of the kinds somebody will want it
	/// on: words that have to be read want to be up and still by the frame they
	/// are read on.
	@Test func aBubbleIsOfferedItAsWell() {
		let start = Project(
			output: Output(width: 1920, height: 1080, framesPerSecond: 25),
			timeline: [TimelineEntry(clip: ClipReference("intro"))],
			overlays: [Overlay(kind: .bubble(Bubble(text: "maybe it is")),
			                   span: .times(from: 0, to: 4),
			                   arrival: .fade(over: 0.2), departure: .fade(over: 0.2))])
		let (panel, project) = self.panel(start)
		#expect(placements(in: panel).count == 2, "a bubble fades in and out, so both ends")
		#expect(project().overlays[0].arrivalPlacement == .after)
	}
}
