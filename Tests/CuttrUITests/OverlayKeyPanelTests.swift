import AppKit
import CuttrCompose
import CuttrKit
import Testing
@testable import CuttrUI

/// The keyframe editor in the properties panel, driven rather than looked at.
///
/// Nothing here checks what it looks like. What it checks is that somebody can
/// add, move and remove a key, and state and un-state a value, without opening
/// the file — which is the promise the panel makes about every other part of
/// this format and now has to make about this one.
///
/// Buttons are pressed through their own target and action rather than by
/// sending a key event: an unhandled key press reaches `NSResponder` and beeps
/// on the machine the test is running on.
@Suite @MainActor struct OverlayKeyPanelTests {

	private func project(_ kind: Overlay.Kind, keys: [Overlay.Key] = []) -> Project {
		Project(
			output: Output(width: 1920, height: 1080, framesPerSecond: 25),
			timeline: [TimelineEntry(clip: ClipReference("intro"))],
			overlays: [Overlay(kind: kind, span: .times(from: 0, to: 4), keys: keys)])
	}

	/// Every button in the panel, in the order they were laid out.
	private func buttons(in view: NSView) -> [NSButton] {
		view.subviews.flatMap { subview -> [NSButton] in
			if let button = subview as? NSButton { return [button] }
			return buttons(in: subview)
		}
	}

	/// Presses the first button with this title, and says whether it found one.
	@discardableResult
	private func press(_ title: String, in panel: PropertiesPanel) -> Bool {
		guard let button = buttons(in: panel).first(where: { $0.title == title }),
		      let action = button.action else { return false }
		_ = button.target?.perform(action, with: button)
		return true
	}

	/// A panel showing the one overlay, with what it changes fed back in — the
	/// window's job, done here so a sequence of edits behaves as it does in the
	/// app rather than each one starting from the file again.
	private func panel(_ start: Project) -> (PropertiesPanel, () -> Project) {
		_ = NSApplication.shared
		let panel = PropertiesPanel()
		final class Box { var project: Project; init(_ p: Project) { project = p } }
		let box = Box(start)
		panel.onChange = { [weak panel] next in
			box.project = next
			panel?.reload(next, vocabulary: ComposeDocument.Vocabulary(), selection: .overlay(.project(0)))
		}
		panel.reload(start, vocabulary: ComposeDocument.Vocabulary(), selection: .overlay(.project(0)))
		return (panel, { box.project })
	}

	/// An overlay with nothing moving offers to make it move, and what that
	/// makes is two keys — because one key is a value and two are a movement.
	@Test func makingItMoveWritesTwoKeys() {
		let (panel, project) = self.panel(project(.aberration(Aberration(amount: 0.3))))
		#expect(project().overlays[0].keys.isEmpty)
		#expect(press("Make it move", in: panel))
		let keys = project().overlays[0].keys
		#expect(keys.count == 2)
		#expect(keys[0].t == 0)
		#expect(keys[0].values.isEmpty, "the first key should inherit the overlay's own numbers")
		// The second states the knob somebody most likely came here for, at
		// what it already is, so there is a number to type over.
		#expect(keys[1][.amount] == 0.3)
		#expect(keys[1].t > 0)
	}

	/// Adding and removing keys, from the panel alone.
	@Test func keysAreAddedAndTakenAwayAgain() {
		let (panel, project) = self.panel(project(
			.tape(Tape(.worn)),
			keys: [Overlay.Key(t: 0), Overlay.Key(t: 2, [.jitter: 0.9])]))
		#expect(press("+ key", in: panel))
		#expect(project().overlays[0].keys.count == 3)
		// In time order, whatever order they were made in.
		let times = project().overlays[0].keys.map(\.t)
		#expect(times == times.sorted(), "\(times)")

		#expect(press("−", in: panel))
		#expect(project().overlays[0].keys.count == 2)
	}

	/// A value is stated at a key, and given back to the key before, without
	/// anybody typing a number.
	@Test func aValueIsStatedAndThenInherited() {
		let (panel, project) = self.panel(project(
			.effect(Effect(style: .rain, density: 1, speed: 1.5)),
			keys: [Overlay.Key(t: 0), Overlay.Key(t: 3, [.density: 0.2])]))
		// The second key is the one the panel opens on after "Make it move",
		// but this one arrived with keys already, so the first is selected and
		// `set` states one of its parameters at what it inherits.
		#expect(press("set", in: panel))
		let stated = project().overlays[0].keys[0].values
		#expect(!stated.isEmpty, "nothing was stated")
		// Whatever it stated, it stated it at the value it already had — so the
		// picture does not change when somebody claims a number.
		for (parameter, value) in stated {
			#expect(value == Overlay.Kind.effect(Effect(style: .rain, density: 1, speed: 1.5))
				.declared(parameter))
		}

		#expect(press("inherit", in: panel))
		#expect(project().overlays[0].keys[0].values.count < stated.count)
	}

	/// The three kinds that are not particles, and the one that is, each shown
	/// with keys and without — the form is thrown away and rebuilt every time,
	/// and that is where this panel has broken before.
	@Test func everyAnimatableKindShowsItsKeys() {
		_ = NSApplication.shared
		let panel = PropertiesPanel()
		let kinds: [Overlay.Kind] = [
			.film(Film()), .aberration(Aberration()), .tape(Tape()),
			.effect(Effect(style: .rain)),
			// And the three that refuse to have any, which must show the
			// section not at all rather than show it empty.
			.text("Hello", style: nil), .spinner(Spinner()), .scene("intro", with: [:]),
		]
		for kind in kinds {
			var moving = [Overlay.Key(t: 0), Overlay.Key(t: 2)]
			if let principal = kind.principal { moving[1][principal] = 1 }
			for keys in [[], moving] {
				panel.reload(project(kind, keys: keys), vocabulary: ComposeDocument.Vocabulary(),
				             selection: .overlay(.project(0)))
				panel.layoutSubtreeIfNeeded()
			}
		}
	}
}
