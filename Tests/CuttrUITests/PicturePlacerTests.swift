import AppKit
import CuttrKit
import Testing
@testable import CuttrCompose
@testable import CuttrUI

/// The picture of where the picture goes.
///
/// `into:` is four fractions, and the first question anybody asked of them was
/// whether the rectangle is where the *text* goes and the recording fills the
/// rest. It is the other way round. This view is the answer, so what it has to
/// get right is which half is which — and then behave like every other draggable
/// thing in the program.
@MainActor @Suite struct PicturePlacerTests {

	private func placed(_ box: Presentation.Rectangle) -> (PicturePlacer, NSWindow) {
		_ = NSApplication.shared
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
		                      styleMask: [.titled], backing: .buffered, defer: false)
		window.isReleasedWhenClosed = false
		let placer = PicturePlacer(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
		window.contentView = placer
		placer.aspect = CGSize(width: 1920, height: 1080)
		placer.picture = box
		placer.sceneName = "bullets"
		placer.display()
		return (placer, window)
	}

	private func event(_ type: NSEvent.EventType, _ at: NSPoint, in window: NSWindow,
	                   _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
		try #require(NSEvent.mouseEvent(
			with: type, location: at, modifierFlags: flags, timestamp: 0,
			windowNumber: window.windowNumber, context: nil,
			eventNumber: 0, clickCount: 1, pressure: 1))
	}

	/// A picture on the left leaves the right free, and the other way round.
	/// This is the whole misreading the view exists to correct.
	@Test func theFreeSideIsTheOtherOne() {
		let left = Presentation.Rectangle(x: 0.04, y: 0.2, width: 0.44, height: 0.6)
		#expect(abs(left.free.x - 0.48) < 1e-9)
		let right = Presentation.Rectangle(x: 0.52, y: 0.2, width: 0.44, height: 0.6)
		#expect(right.free.x == 0)
		#expect(Presentation.Rectangle.whole.free.width == 0)
	}

	/// Dragged by the body, the box moves and keeps its size.
	@Test func theBodyMovesIt() throws {
		let (placer, window) = placed(
			Presentation.Rectangle(x: 0.1, y: 0.2, width: 0.4, height: 0.5))
		defer { window.close() }
		var written: [(Presentation.Rectangle, Bool)] = []
		placer.onChange = { written.append(($0, $1)) }

		// The middle of the box, and a shove to the right.
		let start = placer.pointForTesting(0.3, 0.45)
		placer.mouseDown(with: try event(.leftMouseDown, start, in: window))
		let moved = NSPoint(x: start.x + placer.frameForTesting.width * 0.2, y: start.y)
		placer.mouseDragged(with: try event(.leftMouseDragged, moved, in: window))
		placer.mouseUp(with: try event(.leftMouseUp, moved, in: window))

		let last = try #require(written.last)
		#expect(last.1, "the last word of a drag is the one that commits")
		#expect(last.0.x > 0.1, "it did not move right: \(last.0.x)")
		#expect(abs(last.0.width - 0.4) < 0.02, "the size changed while moving")
		#expect(abs(last.0.height - 0.5) < 0.02)
	}

	/// A box cannot be dragged off the frame: what leaves it cannot be seen,
	/// and what cannot be seen cannot be grabbed back.
	@Test func itStaysInsideTheFrame() throws {
		let (placer, window) = placed(
			Presentation.Rectangle(x: 0.1, y: 0.2, width: 0.4, height: 0.5))
		defer { window.close() }
		var written: [(Presentation.Rectangle, Bool)] = []
		placer.onChange = { written.append(($0, $1)) }

		let start = placer.pointForTesting(0.3, 0.45)
		placer.mouseDown(with: try event(.leftMouseDown, start, in: window))
		let far = NSPoint(x: 5000, y: 5000)
		placer.mouseDragged(with: try event(.leftMouseDragged, far, in: window))
		placer.mouseUp(with: try event(.leftMouseUp, far, in: window))

		let last = try #require(written.last?.0)
		#expect(last.x + last.width <= 1.001, "\(last.x) + \(last.width)")
		#expect(last.y + last.height <= 1.001)
	}

	/// A corner resizes it, and the opposite corner stays where it was — which
	/// is what a corner handle means everywhere anybody has used one.
	@Test func aCornerResizesAboutTheOppositeOne() throws {
		let (placer, window) = placed(
			Presentation.Rectangle(x: 0.2, y: 0.2, width: 0.4, height: 0.4))
		defer { window.close() }
		var written: [(Presentation.Rectangle, Bool)] = []
		placer.onChange = { written.append(($0, $1)) }

		let topRight = placer.pointForTesting(0.6, 0.6)
		placer.mouseDown(with: try event(.leftMouseDown, topRight, in: window))
		let pulled = placer.pointForTesting(0.9, 0.9)
		placer.mouseDragged(with: try event(.leftMouseDragged, pulled, in: window))
		placer.mouseUp(with: try event(.leftMouseUp, pulled, in: window))

		let last = try #require(written.last?.0)
		#expect(abs(last.x - 0.2) < 0.03, "the far corner moved: x is \(last.x)")
		#expect(abs(last.y - 0.2) < 0.03, "the far corner moved: y is \(last.y)")
		#expect(abs(last.width - 0.7) < 0.05, "width is \(last.width)")
		#expect(abs(last.height - 0.7) < 0.05, "height is \(last.height)")
	}

	/// A box dragged shut cannot be dragged open again, so it is never nothing.
	@Test func itIsNeverDraggedToNothing() throws {
		let (placer, window) = placed(
			Presentation.Rectangle(x: 0.2, y: 0.2, width: 0.4, height: 0.4))
		defer { window.close() }
		var written: [(Presentation.Rectangle, Bool)] = []
		placer.onChange = { written.append(($0, $1)) }

		let topRight = placer.pointForTesting(0.6, 0.6)
		placer.mouseDown(with: try event(.leftMouseDown, topRight, in: window))
		// Dragged onto the opposite corner and past it.
		let shut = placer.pointForTesting(0.2, 0.2)
		placer.mouseDragged(with: try event(.leftMouseDragged, shut, in: window))
		placer.mouseUp(with: try event(.leftMouseUp, shut, in: window))

		let last = try #require(written.last?.0)
		#expect(last.width >= 0.05)
		#expect(last.height >= 0.05)
	}

	/// A click outside the box is not a drag. Everything else in this program
	/// treats empty space as "nothing was aimed at", and a preview that grabbed
	/// the picture anyway would move it on a stray click.
	@Test func aClickAwayFromTheBoxDoesNothing() throws {
		let (placer, window) = placed(
			Presentation.Rectangle(x: 0.02, y: 0.02, width: 0.2, height: 0.2))
		defer { window.close() }
		var written = 0
		placer.onChange = { _, _ in written += 1 }

		let away = placer.pointForTesting(0.85, 0.85)
		let then = placer.pointForTesting(0.7, 0.7)
		placer.mouseDown(with: try event(.leftMouseDown, away, in: window))
		placer.mouseDragged(with: try event(.leftMouseDragged, then, in: window))
		placer.mouseUp(with: try event(.leftMouseUp, then, in: window))
		#expect(written == 0)
	}

	/// While the mouse is down the view draws from the drag, so the picture
	/// keeps up with the cursor rather than with the round trip through the
	/// document — which is what lets the form write once, on the way up.
	@Test func itDrawsFromTheDragAndLetsGoAfterwards() throws {
		let (placer, window) = placed(
			Presentation.Rectangle(x: 0.1, y: 0.2, width: 0.4, height: 0.5))
		defer { window.close() }
		let start = placer.pointForTesting(0.3, 0.45)
		let moved = NSPoint(x: start.x + placer.frameForTesting.width * 0.2, y: start.y)
		placer.mouseDown(with: try event(.leftMouseDown, start, in: window))
		placer.mouseDragged(with: try event(.leftMouseDragged, moved, in: window))
		#expect(placer.boxForTesting.x > 0.1, "the picture is not following the drag")
		placer.mouseUp(with: try event(.leftMouseUp, moved, in: window))
		// Back to what it was given, because the form is what holds the value.
		#expect(placer.boxForTesting.x == 0.1)
	}
}
