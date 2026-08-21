import AppKit
import Foundation
import Testing
@testable import CuttrKit
@testable import CuttrUI

/// A look at the clip that is selected, from the list it was chosen in.
///
/// The clip list deliberately did not claim space — the comment on the table
/// says so — because space belonged to the transport and a table view spends it
/// on scrolling. With a clip selected, neither is what anybody means.
@MainActor @Suite struct ClipLookTests {

	private func take() -> Take {
		Take(video: "a.mov", clips: [
			Clip(slug: "one", name: "One", start: 0, end: 2),
			Clip(slug: "two", name: "Two", start: 4, end: 7),
		])
	}

	private func space() -> NSEvent {
		NSEvent.keyEvent(
			with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
			windowNumber: 0, context: nil, characters: " ",
			charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!
	}

	/// Space is claimed once there is a clip to look at, and not before. Asked
	/// of `QuickLook` rather than dispatched into a view: an unhandled key event
	/// reaches `NSResponder` and beeps.
	@Test func spaceIsClaimedOnlyWithSomethingToLookAt() {
		#expect(QuickLook.claims(space(), editing: false, hasSpan: true))
		#expect(!QuickLook.claims(space(), editing: false, hasSpan: false))
		// And never while a field is being typed into, or the level column
		// could not hold a space.
		#expect(!QuickLook.claims(space(), editing: true, hasSpan: true))
	}

	/// The span is the clip's own, on the take's clock — which is the clock the
	/// transport's composition is on, so the look needs no arithmetic of its
	/// own to find the moment.
	@Test func theSpanIsTheSelectedClipsOwn() {
		_ = NSApplication.shared
		let document = TakeDocument(take: take())
		let controller = MainWindowController(document: document)
		defer { controller.window?.close() }
		let window = controller.windowForTesting
		window.setContentSize(NSSize(width: 1400, height: 900))
		window.layoutIfNeeded()

		#expect(controller.clipLookSpanForTesting == nil)
		controller.selectForTesting(clip: document.take.clips[1].id)
		let span = controller.clipLookSpanForTesting
		#expect(span?.start == 4)
		#expect(span?.end == 7)
	}

	/// A clip of no length has nothing to play, so there is nothing to claim
	/// space for.
	@Test func aClipOfNoLengthIsNotALook() {
		_ = NSApplication.shared
		var take = self.take()
		take.clips[0].end = take.clips[0].start
		let document = TakeDocument(take: take)
		let controller = MainWindowController(document: document)
		defer { controller.window?.close() }
		_ = controller.windowForTesting
		controller.selectForTesting(clip: document.take.clips[0].id)
		#expect(controller.clipLookSpanForTesting == nil)
	}
}
