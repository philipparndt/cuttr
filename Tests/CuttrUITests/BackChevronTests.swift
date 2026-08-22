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

/// Where the lane colours sit, which is a question about the clock.
///
/// The clock is the one thing in this bar that must not move — it is centred on
/// the window so it does not shuffle as the name beside it changes length — and
/// a row of swatches pressed up against it reads as part of it.
@Suite @MainActor struct BarFarEndTests {

	private func bar() -> DocumentBar {
		_ = NSApplication.shared
		let bar = DocumentBar(frame: NSRect(x: 0, y: 0, width: 1200, height: DocumentBar.height))
		let swatches = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 16))
		swatches.translatesAutoresizingMaskIntoConstraints = false
		swatches.widthAnchor.constraint(equalToConstant: 120).isActive = true
		swatches.heightAnchor.constraint(equalToConstant: 16).isActive = true
		bar.addAfterClock(swatches)
		bar.layoutSubtreeIfNeeded()
		return bar
	}

	private func added(_ bar: DocumentBar) -> NSView? {
		bar.subviews.compactMap { $0 as? NSStackView }
			.compactMap { $0.arrangedSubviews.first { $0.frame.width == 120 } }.first
	}

	@Test func whatIsAddedGoesToTheFarEnd() {
		let bar = bar()
		guard let swatches = added(bar) else { Issue.record("nothing was added"); return }
		let onBar = swatches.convert(swatches.bounds, to: bar)
		#expect(bar.bounds.maxX - onBar.maxX < 40,
		        "the colours are \(bar.bounds.maxX - onBar.maxX) from the edge, not against it")
	}

	/// And well clear of the clock, which is the point of moving them.
	@Test func theyLeaveTheClockAlone() {
		let bar = bar()
		guard let swatches = added(bar) else { Issue.record("nothing was added"); return }
		let onBar = swatches.convert(swatches.bounds, to: bar)
		// The clock is centred on the window, so the middle is where it is.
		#expect(onBar.minX > bar.bounds.midX + 40,
		        "the colours are crowding the clock at \(onBar.minX)")
	}
}

/// What the bar keeps between documents, and what it must not.
///
/// The bar belongs to the *place*, not the document, so a document leaving has
/// to take its furniture with it. The lane colours did not: a project window
/// showed the last take's, and a second take furnishing the bar put a second
/// set beside the first.
@Suite @MainActor struct BarResetTests {

	private func bar() -> DocumentBar {
		_ = NSApplication.shared
		let bar = DocumentBar(frame: NSRect(x: 0, y: 0, width: 1200, height: DocumentBar.height))
		bar.layoutSubtreeIfNeeded()
		return bar
	}

	private func swatch() -> NSView {
		let view = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 16))
		view.translatesAutoresizingMaskIntoConstraints = false
		view.widthAnchor.constraint(equalToConstant: 120).isActive = true
		view.heightAnchor.constraint(equalToConstant: 16).isActive = true
		return view
	}

	private func atTheEnd(_ bar: DocumentBar) -> Int {
		bar.subviews.compactMap { $0 as? NSStackView }
			.reduce(0) { $0 + $1.arrangedSubviews.filter { $0.frame.width == 120 }.count }
	}

	@Test func whatWasAddedAtTheEndGoesOnReset() {
		let bar = bar()
		bar.addAfterClock(swatch())
		bar.layoutSubtreeIfNeeded()
		#expect(atTheEnd(bar) == 1)

		bar.reset()
		bar.layoutSubtreeIfNeeded()
		#expect(atTheEnd(bar) == 0, "the last document's controls stayed in the bar")
	}

	/// Two documents furnishing the bar in turn leave one set, not two.
	@Test func aSecondDocumentDoesNotAddASecondSet() {
		let bar = bar()
		bar.addAfterClock(swatch())
		bar.reset()
		bar.addAfterClock(swatch())
		bar.layoutSubtreeIfNeeded()
		#expect(atTheEnd(bar) == 1, "the colours are shown twice")
	}
}
