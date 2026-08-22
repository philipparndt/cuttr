import AppKit
import Testing
@testable import CuttrUI

/// The way back out of a take or a scene.
///
/// Between the traffic lights and the capsule, which is where a back chevron
/// lives in everything else on this machine. What is worth holding down is that
/// it moves the capsule when it appears — a button drawn on top of the name
/// would be the obvious way to get this wrong — and that a project, which has
/// nowhere further out to go, does not get one.
@Suite @MainActor struct BackChevronTests {

	private func bar() -> DocumentBar {
		_ = NSApplication.shared
		let bar = DocumentBar(frame: NSRect(x: 0, y: 0, width: 900, height: DocumentBar.height))
		bar.layoutSubtreeIfNeeded()
		return bar
	}

	/// The capsule where a project has it: hard against the room kept for the
	/// traffic lights.
	private func capsuleLeading(_ bar: DocumentBar) -> CGFloat {
		let capsule = bar.subviews.compactMap { $0 as? DocumentCapsule }.first
		return capsule?.frame.minX ?? -1
	}

	private func chevron(_ bar: DocumentBar) -> NSButton? {
		bar.subviews.compactMap { $0 as? NSButton }
			.first { $0.image?.accessibilityDescription == "back to the project" }
	}

	@Test func thereIsNoChevronUntilOneIsAskedFor() {
		let bar = bar()
		#expect(chevron(bar)?.isHidden == true, "a project was given a way out of itself")
	}

	@Test func askingForItShowsIt() {
		let bar = bar()
		bar.setBack(true)
		#expect(chevron(bar)?.isHidden == false)
	}

	/// The capsule moves over to make room. Without this the chevron would be
	/// drawn under the name.
	@Test func theCapsuleMovesOverToMakeRoom() {
		let bar = bar()
		bar.layoutSubtreeIfNeeded()
		let without = capsuleLeading(bar)

		bar.setBack(true)
		bar.layoutSubtreeIfNeeded()
		let with = capsuleLeading(bar)

		#expect(with > without, "the capsule did not move: the chevron is under the name")
		#expect(abs((with - without) - (DocumentBar.backWidth + DocumentBar.backGap)) < 1)
	}

	@Test func andMovesBackWhenItGoes() {
		let bar = bar()
		bar.layoutSubtreeIfNeeded()
		let without = capsuleLeading(bar)

		bar.setBack(true)
		bar.layoutSubtreeIfNeeded()
		bar.setBack(false)
		bar.layoutSubtreeIfNeeded()

		#expect(abs(capsuleLeading(bar) - without) < 1, "the gap stayed behind")
	}

	/// The chevron sits clear of the traffic lights, which is the whole reason
	/// there is a measurement rather than a number.
	@Test func theChevronClearsTheTrafficLights() {
		let bar = bar()
		bar.setBack(true)
		bar.layoutSubtreeIfNeeded()
		guard let chevron = chevron(bar) else { Issue.record("no chevron"); return }
		#expect(chevron.frame.minX >= DocumentBar.edgeOfTheScreen - 1)
		#expect(chevron.frame.maxX <= capsuleLeading(bar) + 1, "the chevron overlaps the name")
	}

	/// Pressed through its own target and action rather than by sending a key
	/// or a click: an unhandled event reaches `NSResponder` and beeps on the
	/// machine the test is running on.
	@Test func pressingItAsksToGoBack() {
		let bar = bar()
		bar.setBack(true)
		var asked = false
		bar.onBack = { asked = true }

		guard let chevron = chevron(bar) else { Issue.record("no chevron"); return }
		_ = chevron.target?.perform(chevron.action, with: chevron)
		#expect(asked, "the chevron did nothing")
	}
}
