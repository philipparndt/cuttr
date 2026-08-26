import AppKit
import CuttrKit
import Testing
@testable import CuttrCompose
@testable import CuttrUI

/// Drawing a shape with the mouse, and being told what the drag has come to.
///
/// Both of these are about the same complaint: a drag on the stage writes
/// numbers into the file, and until now the only way to find out which numbers
/// was to let go and read the inspector — while a shape, whose corner handles
/// only ever multiplied a size, could not be given a different shape at all.
///
/// Real events through a real window, because the arithmetic that turns a point
/// on screen into a place in the file is the part that goes wrong, and it
/// involves the picture's rectangle inside the view.
@MainActor @Suite struct SceneDragTests {

	private func staged(_ content: Scene.Part.Content,
	                    _ key: Scene.Key) throws -> (SceneStage, NSWindow) {
		_ = NSApplication.shared
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
		                      styleMask: [.titled], backing: .buffered, defer: false)
		// Closed here and released by the local going out of scope otherwise —
		// which is a crash in a test rather than a bug in the program.
		window.isReleasedWhenClosed = false
		let stage = SceneStage()
		window.contentView = stage
		stage.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
		stage.outputSize = CGSize(width: 1920, height: 1080)
		stage.scene = Scene(parts: [.init(content: content, keys: [key])])
		stage.selected = 0
		stage.display()
		return (stage, window)
	}

	private func event(_ type: NSEvent.EventType, _ at: NSPoint, in window: NSWindow,
	                   _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
		try #require(NSEvent.mouseEvent(
			with: type, location: at, modifierFlags: flags, timestamp: 0,
			windowNumber: window.windowNumber, context: nil,
			eventNumber: 0, clickCount: 1, pressure: 1))
	}

	/// The corner of a shape resizes it, rather than multiplying what it
	/// already was.
	///
	/// This is the whole of why a shape could not be drawn: a new one is a
	/// block, an old one may be a hairline rule, and a handle that can only
	/// scale turns one into the other never.
	@Test func aCornerOfAShapeResizesIt() throws {
		let (stage, window) = try staged(
			.shape(fill: .white, corner: 0),
			.init(t: 0, x: 0.5, y: 0.5, opacity: 1, width: 0.2, height: 0.02))
		defer { window.close() }

		var sizes: [(Double, Double, Bool)] = []
		var scales: [Double] = []
		stage.onResize = { _, width, height, commit in sizes.append((width, height, commit)) }
		stage.onScale = { _, scale, _ in scales.append(scale) }

		// The top-right corner of a box 0.2 by 0.02 about the middle.
		let picture = stage.picture
		let corner = NSPoint(x: picture.midX + picture.width * 0.1,
		                     y: picture.midY + picture.height * 0.01)
		stage.mouseDown(with: try event(.leftMouseDown, corner, in: window))
		// Pulled out to a quarter of the frame each way, which is a block.
		let pulled = NSPoint(x: picture.midX + picture.width * 0.15,
		                     y: picture.midY + picture.height * 0.25)
		stage.mouseDragged(with: try event(.leftMouseDragged, pulled, in: window))
		stage.mouseUp(with: try event(.leftMouseUp, pulled, in: window))

		#expect(scales.isEmpty, "a shape was scaled instead of resized")
		#expect(sizes.count == 2)
		#expect(sizes.first?.2 == false)
		#expect(sizes.last?.2 == true)
		// Twice the distance from the middle, because the middle stays put.
		#expect(abs((sizes.last?.0 ?? 0) - 0.3) < 0.01, "width \(sizes.last?.0 ?? -1)")
		#expect(abs((sizes.last?.1 ?? 0) - 0.5) < 0.01, "height \(sizes.last?.1 ?? -1)")
	}

	/// Shift keeps the shape it already had, for the times when the size is
	/// right and only the scale is wrong.
	@Test func shiftKeepsTheProportions() throws {
		let (stage, window) = try staged(
			.image("logo.png"),
			.init(t: 0, x: 0.5, y: 0.5, opacity: 1, width: 0.2, height: 0.2))
		defer { window.close() }

		var sizes: [(Double, Double)] = []
		stage.onResize = { _, width, height, _ in sizes.append((width, height)) }

		let picture = stage.picture
		let corner = NSPoint(x: picture.midX + picture.width * 0.1,
		                     y: picture.midY + picture.height * 0.1)
		stage.mouseDown(with: try event(.leftMouseDown, corner, in: window))
		// Pulled out much further across than up.
		let pulled = NSPoint(x: picture.midX + picture.width * 0.3,
		                     y: picture.midY + picture.height * 0.12)
		stage.mouseDragged(with: try event(.leftMouseDragged, pulled, in: window, .shift))
		stage.mouseUp(with: try event(.leftMouseUp, pulled, in: window, .shift))

		let last = try #require(sizes.last)
		// A 1920×1080 frame, so a square on screen is 0.5625 as wide in
		// fractions as it is tall. What has to hold is that the ratio did not
		// change, whatever the numbers came out as.
		#expect(abs(last.0 / last.1 - 1) < 0.02, "\(last.0) by \(last.1)")
	}

	/// A title has no width of its own — its box is whatever the words came out
	/// at — so its corner still multiplies, which is all `scale:` ever was.
	@Test func aTitleIsStillScaledRatherThanResized() throws {
		let (stage, window) = try staged(
			.text("hello", style: "title", tracking: 0),
			.init(t: 0, x: 0.5, y: 0.5, opacity: 1, scale: 1))
		defer { window.close() }

		var sizes = 0
		var scales: [Double] = []
		stage.onResize = { _, _, _, _ in sizes += 1 }
		stage.onScale = { _, scale, _ in scales.append(scale) }

		let placement = try #require(SceneLayout.placements(
			of: stage.scene, with: [:], project: stage.project,
			size: stage.outputSize, at: 0).first)
		let picture = stage.picture
		let shown = picture.width / stage.outputSize.width
		let corner = NSPoint(
			x: picture.minX + placement.corner(1, 1).x * shown,
			y: picture.minY + placement.corner(1, 1).y * shown)
		stage.mouseDown(with: try event(.leftMouseDown, corner, in: window))
		let pulled = NSPoint(x: corner.x + 30, y: corner.y + 20)
		stage.mouseDragged(with: try event(.leftMouseDragged, pulled, in: window))
		stage.mouseUp(with: try event(.leftMouseUp, pulled, in: window))

		#expect(sizes == 0, "a title was given a width")
		#expect(scales.count == 2)
		#expect((scales.last ?? 0) > 1)
	}

	/// While the mouse is down the stage says what the drag has come to, and
	/// lets go of it afterwards: the number belongs to the gesture, and one
	/// left on the stage is a label about something that is no longer
	/// happening.
	@Test func theStageSaysWhereTheDragHasGotTo() throws {
		let (stage, window) = try staged(
			.shape(fill: .white, corner: 0),
			.init(t: 0, x: 0.5, y: 0.5, opacity: 1, width: 0.2, height: 0.2))
		defer { window.close() }

		let picture = stage.picture
		let middle = NSPoint(x: picture.midX, y: picture.midY)
		stage.mouseDown(with: try event(.leftMouseDown, middle, in: window))
		#expect(stage.sayingForTesting == nil, "said something before anything moved")

		let moved = NSPoint(x: picture.midX + picture.width * 0.3, y: picture.midY)
		stage.mouseDragged(with: try event(.leftMouseDragged, moved, in: window))
		let said = try #require(stage.sayingForTesting)
		#expect(said.contains("0.8"), "said \(said)")

		stage.mouseUp(with: try event(.leftMouseUp, moved, in: window))
		#expect(stage.sayingForTesting == nil, "the label outlived the drag")
	}

	/// And it says the right *kind* of thing for each handle: a size for a
	/// corner that resizes, degrees for the one that turns.
	@Test func whatItSaysDependsOnWhatIsBeingDragged() throws {
		let (stage, window) = try staged(
			.shape(fill: .white, corner: 0),
			.init(t: 0, x: 0.5, y: 0.5, opacity: 1, width: 0.2, height: 0.2))
		defer { window.close() }

		let picture = stage.picture
		let corner = NSPoint(x: picture.midX + picture.width * 0.1,
		                     y: picture.midY + picture.height * 0.1)
		stage.mouseDown(with: try event(.leftMouseDown, corner, in: window))
		stage.mouseDragged(with: try event(
			.leftMouseDragged,
			NSPoint(x: corner.x + 20, y: corner.y + 20), in: window))
		#expect(stage.sayingForTesting?.contains("×") == true, "\(stage.sayingForTesting ?? "")")
		stage.mouseUp(with: try event(.leftMouseUp, corner, in: window))
	}

	// MARK: - The scrubber

	/// A key dragged along its lane says what time it will land on.
	///
	/// The mark itself does not move until the mouse comes up — keys are kept
	/// in order, and reordering them under the cursor is how a drag comes to be
	/// moving a different key from the one that was grabbed — so without this
	/// the drag showed nothing at all.
	@Test func theScrubberSaysWhereAKeyWillLand() throws {
		_ = NSApplication.shared
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 120),
		                      styleMask: [.titled], backing: .buffered, defer: false)
		window.isReleasedWhenClosed = false
		defer { window.close() }
		let scrubber = SceneScrubber()
		window.contentView = scrubber
		scrubber.frame = NSRect(x: 0, y: 0, width: 640, height: 120)
		scrubber.scene = Scene(parts: [
			.init(content: .shape(fill: .white, corner: 0),
			      keys: [.init(t: 0, x: 0.5, y: 0.5), .init(t: 2)]),
		])
		scrubber.length = 4
		scrubber.selectedPart = 0
		scrubber.display()

		// The scrubber draws flipped and an event carries window coordinates, so
		// the mark has to come back through the view's own conversion.
		let at = scrubber.convert(scrubber.markForTesting(part: 0, key: 1), to: nil)
		func event(_ type: NSEvent.EventType, _ point: NSPoint) throws -> NSEvent {
			try #require(NSEvent.mouseEvent(
				with: type, location: point, modifierFlags: [], timestamp: 0,
				windowNumber: window.windowNumber, context: nil,
				eventNumber: 0, clickCount: 1, pressure: 1))
		}
		scrubber.mouseDown(with: try event(.leftMouseDown, at))
		#expect(scrubber.landingForTesting == nil)
		scrubber.mouseDragged(with: try event(
			.leftMouseDragged, NSPoint(x: at.x + 80, y: at.y)))
		let landing = try #require(scrubber.landingForTesting)
		#expect(landing > 2, "a key dragged forwards landed at \(landing)")
		scrubber.display()

		scrubber.mouseUp(with: try event(.leftMouseUp, NSPoint(x: at.x + 80, y: at.y)))
		#expect(scrubber.landingForTesting == nil, "the label outlived the drag")
	}
}
