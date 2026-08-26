import AppKit
import CuttrCompose
import CuttrKit

/// The scene, drawn at the moment the playhead is at, with handles on whatever
/// is selected.
///
/// The picture is ``OverlayPainter/sceneImage`` — the renderer's own painting
/// of a scene, not a second one made for the editor. It is asked for at the
/// size the stage is showing rather than at the output's, because everything in
/// a scene is a fraction of the frame and the same call therefore draws the
/// same layout at any resolution; asking for 1920×1080 sixty times a second to
/// show it at 700 points would be eight megabytes a frame for nothing.
///
/// Dragging follows the two views this program already has for it — the
/// cutting window's timeline and the programme strip: live while the mouse is
/// down, with `commit` on the way up, so the whole drag is one undo step.
@MainActor
public final class SceneStage: NSView {

	public var scene = Scene() { didSet { needsDisplay = true } }
	public var project = Project() { didSet { needsDisplay = true } }
	public var parameters: [String: String] = [:] { didSet { needsDisplay = true } }
	public var baseURL: URL?
	/// The shape of the output, which is the shape of the stage.
	public var outputSize = CGSize(width: 1920, height: 1080) { didSet { needsDisplay = true } }
	public var time: Double = 0 { didSet { needsDisplay = true } }
	public var selected: Int? { didSet { needsDisplay = true } }

	/// Somebody clicked a part, or clicked away from all of them.
	public var onSelect: ((Int?) -> Void)?
	/// A part was dragged: where its middle is now, in fractions of the frame.
	public var onMove: ((Int, Double, Double, Bool) -> Void)?
	public var onScale: ((Int, Double, Bool) -> Void)?
	/// Degrees, anticlockwise.
	public var onRotate: ((Int, Double, Bool) -> Void)?
	/// A part whose size is its own — a shape, an image, a bar, a sequence —
	/// dragged by a corner: its width and height, in fractions of the frame.
	///
	/// Separate from ``onScale`` because they are different facts. `scale:` is
	/// a multiplier on whatever the part measures, which is the only thing a
	/// title can be given; a rectangle *has* a width and a height, and being
	/// able only to multiply them both at once is what made a shape impossible
	/// to draw with the mouse.
	public var onResize: ((Int, Double, Double, Bool) -> Void)?

	private enum Grab {
		case body(CGPoint)
		/// Which corner, and how far it was from the middle when it was grabbed.
		case scale(start: Double, reach: Double)
		case turn(start: Double, angle: Double)
		/// Which corner is being pulled, for a part that has a size of its own.
		case size(corner: CGPoint)
	}

	private var grab: Grab?
	/// What the drag has come to, drawn beside the part while the mouse is
	/// down.
	///
	/// A drag on this stage writes numbers into the file, and until now the
	/// only way to find out which numbers was to let go and read the inspector.
	/// That is the wrong order: the value is being *chosen* during the drag,
	/// and a snap that fired — or did not — is invisible without it.
	private var saying: String?
	private var placements: [ScenePlacement] = []
	/// How big a handle is, in points on screen.
	private let handleSize: CGFloat = 7
	/// How far above the box the turning handle sits, in points on screen.
	private let turnGap: CGFloat = 22

	public override init(frame: NSRect) {
		super.init(frame: frame)
		wantsLayer = true
		layer?.backgroundColor = NSColor(calibratedWhite: 0.06, alpha: 1).cgColor
	}

	@available(*, unavailable) required init?(coder: NSCoder) { nil }

	public override var acceptsFirstResponder: Bool { true }

	/// Whether this part's size is its own, or something measured from what is
	/// in it.
	///
	/// A shape, an image, a bar and a frame sequence are given a `width:` and a
	/// `height:` on the key, so a corner handle can set them. A title's box is
	/// whatever the words came out at and a spinner says how big it is itself;
	/// for those the corner multiplies instead, which is all `scale:` ever was.
	private func hasItsOwnSize(_ part: Int) -> Bool {
		guard part < scene.parts.count else { return false }
		switch scene.parts[part].content {
		case .shape, .image, .bar, .frames, .component: return true
		case .text, .roll, .spinner, .background: return false
		}
	}

	// MARK: - Where the picture is

	/// The frame's rectangle inside the view: aspect-fitted, so most of the
	/// time there is a border. Everything is measured against this and not
	/// against the view, or a part would be dragged to a different place on the
	/// stage from the one it lands at in the file.
	public var picture: NSRect {
		guard outputSize.width > 0, outputSize.height > 0 else { return bounds }
		let inset = bounds.insetBy(dx: 12, dy: 12)
		guard inset.width > 1, inset.height > 1 else { return bounds }
		let scale = min(inset.width / outputSize.width, inset.height / outputSize.height)
		let size = CGSize(width: outputSize.width * scale, height: outputSize.height * scale)
		return NSRect(x: inset.midX - size.width / 2, y: inset.midY - size.height / 2,
		              width: size.width, height: size.height)
	}

	/// How many points on screen one pixel of the output is.
	private var shown: CGFloat {
		outputSize.width > 0 ? picture.width / outputSize.width : 1
	}

	private func onScreen(_ point: CGPoint) -> NSPoint {
		NSPoint(x: picture.minX + point.x * shown, y: picture.minY + point.y * shown)
	}

	private func inFrame(_ point: NSPoint) -> CGPoint {
		CGPoint(x: (point.x - picture.minX) / max(shown, 0.0001),
		        y: (point.y - picture.minY) / max(shown, 0.0001))
	}

	// MARK: - Drawing

	public override func draw(_ dirtyRect: NSRect) {
		NSColor(calibratedWhite: 0.06, alpha: 1).setFill()
		dirtyRect.fill()
		let picture = self.picture

		// A chequerboard behind the frame, because a scene is usually mostly
		// transparent and black on black says nothing about which is which.
		drawChequers(in: picture)

		let pixels = CGSize(width: (picture.width * (window?.backingScaleFactor ?? 2)).rounded(),
		                    height: (picture.height * (window?.backingScaleFactor ?? 2)).rounded())
		if let image = OverlayPainter.sceneImage(
			scene, with: parameters, project: project,
			baseURL: baseURL ?? URL(fileURLWithPath: "."), size: pixels, at: time),
			let context = NSGraphicsContext.current?.cgContext {
			context.saveGState()
			context.interpolationQuality = .high
			context.draw(image, in: picture)
			context.restoreGState()
		}

		NSColor(calibratedWhite: 0.35, alpha: 1).setStroke()
		NSBezierPath(rect: picture.insetBy(dx: -0.5, dy: -0.5)).stroke()

		// The middle of the frame, faintly, because a title card is centred
		// more often than it is anywhere else.
		Theme.rule.withAlphaComponent(0.5).setStroke()
		let middle = NSBezierPath()
		middle.move(to: NSPoint(x: picture.midX, y: picture.minY))
		middle.line(to: NSPoint(x: picture.midX, y: picture.maxY))
		middle.move(to: NSPoint(x: picture.minX, y: picture.midY))
		middle.line(to: NSPoint(x: picture.maxX, y: picture.midY))
		middle.setLineDash([2, 4], count: 2, phase: 0)
		middle.stroke()

		place()

		guard let selected, let placement = placements.first(where: { $0.part == selected })
		else { return }
		drawHandles(for: placement)
		if let saying { draw(saying, beside: placement) }
	}

	/// The number the drag has come to, on a plate under the part.
	///
	/// Under rather than at the cursor: the cursor is already on the handle it
	/// is pulling, and a label that follows it covers the corner somebody is
	/// trying to line up. Kept inside the picture, because a value that has
	/// been dragged off the frame is exactly when it is worth reading.
	private func draw(_ words: String, beside placement: ScenePlacement) {
		let attributes: [NSAttributedString.Key: Any] = [
			.font: Theme.monoSmall, .foregroundColor: Theme.text,
		]
		let size = (words as NSString).size(withAttributes: attributes)
		let bottom = [(-1.0, -1.0), (1.0, -1.0), (1.0, 1.0), (-1.0, 1.0)]
			.map { onScreen(placement.corner($0.0, $0.1)).y }.min() ?? picture.midY
		var plate = NSRect(x: onScreen(placement.centre).x - size.width / 2 - 5,
		                   y: bottom - size.height - 12,
		                   width: size.width + 10, height: size.height + 4)
		plate.origin.x = min(max(plate.minX, picture.minX + 2), picture.maxX - plate.width - 2)
		plate.origin.y = min(max(plate.minY, picture.minY + 2), picture.maxY - plate.height - 2)

		Theme.cardHigh.withAlphaComponent(0.92).setFill()
		NSBezierPath(roundedRect: plate, xRadius: 3, yRadius: 3).fill()
		Theme.accent.withAlphaComponent(0.6).setStroke()
		NSBezierPath(roundedRect: plate.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3).stroke()
		(words as NSString).draw(at: NSPoint(x: plate.minX + 5, y: plate.minY + 2),
		                        withAttributes: attributes)
	}

	private func drawChequers(in rect: NSRect) {
		let square: CGFloat = 8
		NSColor(calibratedWhite: 0.14, alpha: 1).setFill()
		rect.fill()
		NSColor(calibratedWhite: 0.18, alpha: 1).setFill()
		var row = 0
		var y = rect.minY
		while y < rect.maxY {
			var column = row % 2
			var x = rect.minX
			while x < rect.maxX {
				if column % 2 == 0 {
					NSRect(x: x, y: y, width: min(square, rect.maxX - x),
					       height: min(square, rect.maxY - y)).fill()
				}
				column += 1
				x += square
			}
			row += 1
			y += square
		}
	}

	private func drawHandles(for placement: ScenePlacement) {
		let box = NSBezierPath()
		let corners = [(-1.0, -1.0), (1.0, -1.0), (1.0, 1.0), (-1.0, 1.0)]
			.map { onScreen(placement.corner($0.0, $0.1)) }
		box.move(to: corners[0])
		for corner in corners.dropFirst() { box.line(to: corner) }
		box.close()
		Theme.accent.setStroke()
		box.lineWidth = 1
		box.stroke()

		// A background has no handles at all: it is the frame, and a frame that
		// can be dragged off the frame is a bug waiting to be filed.
		guard !placement.isBackground else { return }

		Theme.accent.setFill()
		for corner in corners {
			NSRect(x: corner.x - handleSize / 2, y: corner.y - handleSize / 2,
			       width: handleSize, height: handleSize).fill()
		}

		let turn = onScreen(placement.handle(above: Double(turnGap / max(shown, 0.0001))))
		let stalk = NSBezierPath()
		stalk.move(to: onScreen(CGPoint(
			x: (placement.corner(-1, 1).x + placement.corner(1, 1).x) / 2,
			y: (placement.corner(-1, 1).y + placement.corner(1, 1).y) / 2)))
		stalk.line(to: turn)
		stalk.stroke()
		NSBezierPath(ovalIn: NSRect(x: turn.x - handleSize / 2, y: turn.y - handleSize / 2,
		                            width: handleSize, height: handleSize)).fill()
	}

	// MARK: - Dragging

	/// Where every part is, now. Kept from the last draw and worked out again
	/// on the way into a click — a stage that has been given a new scene and
	/// not yet redrawn would otherwise hit-test against the old one.
	private func place() {
		placements = SceneLayout.placements(
			of: scene, with: parameters, project: project, size: outputSize, at: time)
	}

	public override func mouseDown(with event: NSEvent) {
		window?.makeFirstResponder(self)
		place()
		let point = convert(event.locationInWindow, from: nil)
		let frame = inFrame(point)

		// The selected part's handles come first: they stick out past its box,
		// and something behind them must not steal the click.
		if let selected, let placement = placements.first(where: { $0.part == selected }),
		   !placement.isBackground {
			let turn = onScreen(placement.handle(above: Double(turnGap / max(shown, 0.0001))))
			if hit(point, turn) {
				grab = .turn(start: placement.rotation, angle: angle(of: frame, about: placement))
				return
			}
			for corner in [(-1.0, -1.0), (1.0, -1.0), (1.0, 1.0), (-1.0, 1.0)] {
				guard hit(point, onScreen(placement.corner(corner.0, corner.1))) else { continue }
				if hasItsOwnSize(selected) {
					grab = .size(corner: CGPoint(x: corner.0, y: corner.1))
				} else {
					let reach = distance(frame, placement.centre)
					grab = .scale(start: placement.scale, reach: max(reach, 0.0001))
				}
				return
			}
		}

		// Topmost first, which is the last one drawn.
		guard let placement = placements.reversed().first(where: { $0.contains(frame) }) else {
			onSelect?(nil)
			return
		}
		onSelect?(placement.part)
		guard !placement.isBackground else { return }
		grab = .body(CGPoint(x: frame.x - placement.centre.x, y: frame.y - placement.centre.y))
	}

	public override func mouseDragged(with event: NSEvent) {
		guard grab != nil else { return }
		apply(event, commit: false)
	}

	public override func mouseUp(with event: NSEvent) {
		guard grab != nil else { return }
		apply(event, commit: true)
		grab = nil
		saying = nil
		needsDisplay = true
	}

	private func apply(_ event: NSEvent, commit: Bool) {
		guard let selected, let grab,
		      let placement = placements.first(where: { $0.part == selected }) else { return }
		let frame = inFrame(convert(event.locationInWindow, from: nil))
		let free = event.modifierFlags.contains(.option)

		switch grab {
		case .body(let held):
			var x = (frame.x - held.x) / max(outputSize.width, 1)
			var y = (frame.y - held.y) / max(outputSize.height, 1)
			// Snapped to the middle of the frame, and to the thirds, unless
			// somebody says otherwise with the option key. A title card is
			// centred far more often than it is at 0.4987.
			if !free {
				x = snapped(x)
				y = snapped(y)
			}
			say("\(number(x)), \(number(y))", commit)
			onMove?(selected, x, y, commit)

		case .size(let corner):
			// The corner is pulled and the middle stays put, so the box grows
			// and shrinks about where it is. A part is *placed* by its middle
			// here — that is what `x:` and `y:` mean — so anchoring the
			// opposite corner instead would move the part as a side effect of
			// resizing it, and write two more numbers nobody asked to change.
			let local = turnedBack(frame, about: placement)
			let scale = max(placement.scale, 0.0001)
			var width = abs(local.x) * 2 / scale / max(outputSize.width, 1)
			var height = abs(local.y) * 2 / scale / max(outputSize.height, 1)
			// Shift keeps the shape it already had, which is what somebody
			// wants when they are only making a logo bigger.
			if event.modifierFlags.contains(.shift) {
				let was = CGSize(width: max(placement.size.width, 1),
				                 height: max(placement.size.height, 1))
				let by = max(width * outputSize.width / was.width,
				             height * outputSize.height / was.height)
				width = was.width * by / max(outputSize.width, 1)
				height = was.height * by / max(outputSize.height, 1)
			}
			if !free {
				width = (width * 1000).rounded() / 1000
				height = (height * 1000).rounded() / 1000
			}
			// Never nothing: a part dragged to no size at all vanishes, and
			// what vanishes cannot be grabbed to bring it back.
			width = max(0.002, width)
			height = max(0.002, height)
			say("\(number(width)) × \(number(height))", commit)
			onResize?(selected, width, height, commit)

		case .scale(let start, let reach):
			let now = distance(frame, placement.centre)
			var scale = start * now / reach
			if !free { scale = (scale * 100).rounded() / 100 }
			say("×\(number(max(0.01, scale)))", commit)
			onScale?(selected, max(0.01, scale), commit)

		case .turn(let start, let held):
			var rotation = start + (angle(of: frame, about: placement) - held) * 180 / .pi
			// Whole degrees, and multiples of fifteen when it is near one:
			// nobody means 43.7°, and a title a degree off level is a mistake
			// that survives to the render.
			rotation = rotation.rounded()
			if !free, abs(rotation.truncatingRemainder(dividingBy: 15)) < 3 {
				rotation = (rotation / 15).rounded() * 15
			}
			say("\(Int(rotation))°", commit)
			onRotate?(selected, rotation, commit)
		}
	}

	/// A point in the frame's pixels, in the part's own unturned coordinates
	/// with the middle at nought.
	private func turnedBack(_ point: CGPoint, about placement: ScenePlacement) -> CGPoint {
		let radians = -placement.rotation * .pi / 180
		let dx = point.x - placement.centre.x, dy = point.y - placement.centre.y
		return CGPoint(x: dx * cos(radians) - dy * sin(radians),
		               y: dx * sin(radians) + dy * cos(radians))
	}

	/// What the drag has come to. Cleared on the way up: the number belongs to
	/// the gesture, and one left on the stage afterwards is a label about
	/// something that is no longer happening.
	private func say(_ words: String, _ commit: Bool) {
		saying = commit ? nil : words
		needsDisplay = true
	}

	/// Three places, and no more: a scene is written in fractions of the frame,
	/// and the fourth digit of one is below what a pixel can show.
	private func number(_ value: Double) -> String {
		TakeWriter.number(value, places: 3)
	}

	/// Within three points of a landmark, in the frame's own units.
	private func snapped(_ value: Double) -> Double {
		let slop = Double(3 / max(shown, 0.0001)) / Double(max(outputSize.width, 1))
		for landmark in [0.0, 1.0 / 3, 0.5, 2.0 / 3, 1.0] where abs(value - landmark) < slop {
			return landmark
		}
		return value
	}

	private func hit(_ point: NSPoint, _ handle: NSPoint) -> Bool {
		abs(point.x - handle.x) <= handleSize && abs(point.y - handle.y) <= handleSize
	}

	private func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
		Double(((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot())
	}

	private func angle(of point: CGPoint, about placement: ScenePlacement) -> Double {
		Double(atan2(point.y - placement.centre.y, point.x - placement.centre.x))
	}

	/// For the tests: what the stage is saying about the drag in progress.
	var sayingForTesting: String? { saying }

	public override func resetCursorRects() {
		super.resetCursorRects()
		guard let selected, let placement = placements.first(where: { $0.part == selected }),
		      !placement.isBackground else { return }
		for corner in [(-1.0, -1.0), (1.0, -1.0), (1.0, 1.0), (-1.0, 1.0)] {
			let at = onScreen(placement.corner(corner.0, corner.1))
			addCursorRect(NSRect(x: at.x - handleSize, y: at.y - handleSize,
			                     width: handleSize * 2, height: handleSize * 2),
			              cursor: .crosshair)
		}
	}
}
