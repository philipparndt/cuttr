import AppKit
import CuttrCompose
import Testing
@testable import CuttrUI

/// End credits, from the one place they can be made: the timeline's own `+`.
///
/// The menu rather than the window, and the project that comes back out of it
/// rather than the picture — what is being tested is that the gesture writes the
/// three things an outro is made of, in the file, where somebody can read them.
@Suite @MainActor struct CreditsMenuTests {

	private func panel(_ cast: [String] = ["Wren Halloway", "Mira Vance"])
		-> (ProgrammePanel, () -> Project?) {
		_ = NSApplication.shared
		let panel = ProgrammePanel(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
		var vocabulary = ComposeDocument.Vocabulary()
		vocabulary.cast = cast
		panel.reload(Project(timeline: [
			TimelineEntry(clip: ClipReference("one")),
			TimelineEntry(clip: ClipReference("two")),
		]), vocabulary: vocabulary)
		panel.layoutSubtreeIfNeeded()
		var written: Project?
		panel.onChange = { written = $0; panel.reload($0, vocabulary: vocabulary) }
		return (panel, { written })
	}

	private func credits(of panel: ProgrammePanel) -> NSMenu? {
		panel.addEntryMenu()?.items.first { $0.title == "End credits" }?.submenu
	}

	/// Three presets and the update, and none of it on the overlays' `+` —
	/// where it would make no sense, because an outro is a card and a card is
	/// not an overlay.
	@Test func thePresetsAreOfferedOnTheTimelineAndNotOnTheOverlays() {
		let (panel, _) = self.panel()
		guard let menu = credits(of: panel) else {
			Issue.record("no End credits on the timeline menu")
			return
		}
		let titles = menu.items.map(\.title)
		for preset in Credits.Preset.allCases {
			#expect(titles.contains(preset.described))
		}
		#expect(titles.contains { $0.contains("cast") })
		#expect(panel.addOverlayMenu()?.items.map(\.title).contains("End credits") != true)
	}

	/// A card on the end, a scene, and the overlay that joins them.
	@Test func makingAnOutroWritesTheCardTheSceneAndTheOverlay() throws {
		let (panel, written) = self.panel()
		guard let menu = credits(of: panel),
		      let index = menu.items.firstIndex(where: {
		      	$0.title == Credits.Preset.broadcast.described
		      })
		else {
			Issue.record("no broadcast preset")
			return
		}
		menu.performActionForItem(at: index)
		let project = try #require(written())
		#expect(project.timeline.count == 3)
		#expect(project.scenes.count == 1)
		#expect(project.overlays.count == 1)
		let name = try #require(project.scenes.keys.first)
		#expect(project.timeline.last?.label == name)
		// And the names came from the cast the takes gave, not from a
		// placeholder somebody then has to find and replace.
		guard case .roll(let roll) = project.scenes[name]?.parts.first?.content else {
			Issue.record("the scene is not a roll")
			return
		}
		#expect(roll.entries.first?.names == ["Wren Halloway", "Mira Vance"])
		#expect(roll.entries.first?.source == .cast)
	}

	/// The one place in this panel that ignores the selection. Credits go last:
	/// that is what the word means.
	@Test func creditsGoOnTheEndWhateverIsSelected() throws {
		let (panel, written) = self.panel()
		panel.selectRow(0)
		guard let menu = credits(of: panel),
		      let index = menu.items.firstIndex(where: {
		      	$0.title == Credits.Preset.family.described
		      })
		else {
			Issue.record("no family preset")
			return
		}
		menu.performActionForItem(at: index)
		let project = try #require(written())
		#expect(project.timeline.count == 3)
		if case .card = project.timeline[2].source {} else {
			Issue.record("the card is not on the end")
		}
		#expect(project.timeline[0].source.description == "one")
	}

	/// The second time: three more takes, and the derived block catches up
	/// without touching the line somebody typed.
	@Test func updatingRefillsTheDerivedBlockAndLeavesTheRest() throws {
		let (panel, written) = self.panel()
		guard let menu = credits(of: panel),
		      let make = menu.items.firstIndex(where: {
		      	$0.title == Credits.Preset.broadcast.described
		      })
		else {
			Issue.record("no broadcast preset")
			return
		}
		menu.performActionForItem(at: make)
		var project = try #require(written())
		let name = try #require(project.scenes.keys.first)

		// Somebody types a line of their own, and renames the derived block's
		// role while they are there.
		var scene = try #require(project.scenes[name])
		guard case .roll(var roll) = scene.parts[0].content else {
			Issue.record("the scene is not a roll")
			return
		}
		roll.entries[0].role = "Mit dabei"
		roll.entries.append(Scene.Roll.Entry(role: "Music", names: ["Ines Calloway"]))
		scene.parts[0].content = .roll(roll)
		project.scenes[name] = scene

		var vocabulary = ComposeDocument.Vocabulary()
		vocabulary.cast = ["Wren Halloway", "Mira Vance", "Otto Kestrel"]
		panel.reload(project, vocabulary: vocabulary)
		guard let again = credits(of: panel),
		      let update = again.items.firstIndex(where: { $0.title.contains("cast") })
		else {
			Issue.record("no update item")
			return
		}
		again.performActionForItem(at: update)

		let updated = try #require(written())
		guard case .roll(let after) = updated.scenes[name]?.parts.first?.content else {
			Issue.record("the scene is not a roll")
			return
		}
		#expect(after.entries.count == 2)
		#expect(after.entries[0].names.count == 3)
		#expect(after.entries[0].role == "Mit dabei")
		#expect(after.entries[1] == Scene.Roll.Entry(role: "Music", names: ["Ines Calloway"]))
	}
}
