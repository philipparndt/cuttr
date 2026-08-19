import AppKit
import CuttrCompose
import CuttrKit

/// One frame of the programme, with the overlay on it, dragged into place.
///
/// Numbers do not place things. `offset: {x: 0.02, y: -0.11}` is a fact about a
/// spinner nobody can picture, and the way anybody actually finds the right
/// value is by rendering, looking, and changing it — three times. So the frame
/// is here, at the moment the overlay appears, with the overlay drawn on it and
/// draggable.
///
/// What is dragged is still what the file says. The drag ends by writing an
/// offset or a position, in the same units the format uses, and the field next
/// to the picture shows it change. Nothing is stored that the text cannot say.
@MainActor
public final class FramePreview: NSView {

	/// The shape of the render, so the box is the shape of the output.
	public var aspect = CGSize(width: 16, height: 9) { didSet { needsDisplay = true } }
	/// The picture at that moment, if one could be had.
	public var poster: NSImage? { didSet { needsDisplay = true } }
	/// What the overlay follows, in unit coordinates, origin bottom-left.
	public var anchorPoint: CGPoint? { didSet { needsDisplay = true } }
	public var anchorName: String?
	/// Where the overlay sits, in unit coordinates, origin bottom-left.
	public var spot = CGPoint(x: 0.5, y: 0.5) { didSet { needsDisplay = true } }
	/// What to draw there — the overlay itself, as it will be drawn.
	///
	/// Not a chip with a name on it. Placing a spinner means knowing how big the
	/// spinner is: `size: 0.09` is a ninth of the frame height, and whether that
	/// clears somebody's head is a question about the picture, not about a
	/// number. So the ring is the size the ring will be, the caption is set in
	/// the type the caption is set in, and the plate behind it is the plate.
	public enum Content {
		case caption(String, TextStyle)
		case spinner(Spinner, words: TextStyle)
	}

	public var content: Content = .caption("", TextStyle.lowerThird) {
		didSet { needsDisplay = true }
	}
	/// Said under the picture: what a drag will change.
	public var explanation = ""

	/// Where it was let go. Called once, at the end of the drag — a project
	/// written on every mouse-moved event would be a file rewritten sixty times
	/// a second.
	public var onMove: ((CGPoint) -> Void)?

	private var dragging = false
	private var grab = CGSize.zero
	/// Where the overlay was last drawn, so it can be grabbed by itself rather
	/// than by a rectangle guessed from its name.
	private var grabBox = NSRect.zero

	public override init(frame: NSRect) {
		super.init(frame: frame)
		wantsLayer = true
		layer?.backgroundColor = Theme.background.cgColor
		layer?.cornerRadius = 4
	}

	@available(*, unavailable) required init?(coder: NSCoder) { nil }

	public override var intrinsicContentSize: NSSize {
		NSSize(width: NSView.noIntrinsicMetric, height: 206)
	}

	// MARK: - Geometry

	/// The frame's rectangle inside this view, letterboxed like the render.
	private var picture: NSRect {
		// The line underneath gets its own strip; the picture keeps off it.
		let box = NSRect(x: 8, y: 20, width: max(0, bounds.width - 16),
		                 height: max(0, bounds.height - 30))
		guard aspect.width > 0, aspect.height > 0, box.width > 0, box.height > 0 else { return box }
		let scale = min(box.width / aspect.width, box.height / aspect.height)
		let size = NSSize(width: aspect.width * scale, height: aspect.height * scale)
		return NSRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2,
		              width: size.width, height: size.height)
	}

	private func point(_ unit: CGPoint) -> NSPoint {
		let picture = self.picture
		return NSPoint(x: picture.minX + unit.x * picture.width,
		               y: picture.minY + unit.y * picture.height)
	}

	private func unit(_ point: NSPoint) -> CGPoint {
		let picture = self.picture
		guard picture.width > 0, picture.height > 0 else { return .zero }
		return CGPoint(x: min(1, max(0, (point.x - picture.minX) / picture.width)),
		               y: min(1, max(0, (point.y - picture.minY) / picture.height)))
	}

	// MARK: - Drawing

	public override func draw(_ dirtyRect: NSRect) {
		let picture = self.picture

		if let poster {
			poster.draw(in: picture, from: .zero, operation: .copy, fraction: 1)
		} else {
			NSColor(calibratedWhite: 0.07, alpha: 1).setFill()
			picture.fill()
			let message = "no frame here yet"
			let attributes: [NSAttributedString.Key: Any] = [
				.font: Theme.monoSmall, .foregroundColor: Theme.faintText,
			]
			let size = (message as NSString).size(withAttributes: attributes)
			(message as NSString).draw(
				at: NSPoint(x: picture.midX - size.width / 2, y: picture.midY - size.height / 2),
				withAttributes: attributes)
		}

		// Thirds, faintly. Somebody placing a caption is placing it against
		// these whether they are drawn or not.
		NSColor(calibratedWhite: 1, alpha: 0.10).setStroke()
		let guides = NSBezierPath()
		for step in 1...2 {
			let fraction = CGFloat(step) / 3
			guides.move(to: NSPoint(x: picture.minX + picture.width * fraction, y: picture.minY))
			guides.line(to: NSPoint(x: picture.minX + picture.width * fraction, y: picture.maxY))
			guides.move(to: NSPoint(x: picture.minX, y: picture.minY + picture.height * fraction))
			guides.line(to: NSPoint(x: picture.maxX, y: picture.minY + picture.height * fraction))
		}
		guides.lineWidth = 1
		guides.stroke()

		Theme.rule.setStroke()
		NSBezierPath(rect: picture).stroke()

		// What it follows, and the line from there to where it sits: the offset,
		// drawn as the thing it is.
		if let anchorPoint {
			let centre = point(anchorPoint)
			let colour = Theme.color(.anchor)
			colour.setStroke()
			let ring = NSBezierPath(ovalIn: NSRect(x: centre.x - 6, y: centre.y - 6, width: 12, height: 12))
			ring.lineWidth = 1.5
			ring.stroke()
			let cross = NSBezierPath()
			cross.move(to: NSPoint(x: centre.x - 10, y: centre.y))
			cross.line(to: NSPoint(x: centre.x + 10, y: centre.y))
			cross.move(to: NSPoint(x: centre.x, y: centre.y - 10))
			cross.line(to: NSPoint(x: centre.x, y: centre.y + 10))
			cross.stroke()

			let leash = NSBezierPath()
			leash.move(to: centre)
			leash.line(to: point(spot))
			leash.setLineDash([3, 3], count: 2, phase: 0)
			colour.withAlphaComponent(0.6).setStroke()
			leash.stroke()

			if let anchorName {
				(anchorName as NSString).draw(
					at: NSPoint(x: centre.x + 12, y: centre.y + 2),
					withAttributes: [.font: Theme.monoSmall, .foregroundColor: colour])
			}
		}

		drawContent(at: point(spot))

		if !explanation.isEmpty {
			(explanation as NSString).draw(
				at: NSPoint(x: 8, y: 4),
				withAttributes: [.font: Theme.monoSmall, .foregroundColor: Theme.faintText])
		}
	}

	/// The overlay, drawn the way the renderer draws it.
	private func drawContent(at centre: NSPoint) {
		switch content {
		case .caption(let text, let style):
			drawCaption(text, style: style, at: centre)
		case .spinner(let spinner, let wordStyle):
			drawSpinner(spinner, words: wordStyle, at: centre)
		}
		if dragging {
			// While it is being moved, say where it has got to.
			Theme.accent.setStroke()
			let ring = NSBezierPath(ovalIn: NSRect(x: centre.x - 3, y: centre.y - 3, width: 6, height: 6))
			ring.lineWidth = 1.5
			ring.stroke()
		}
	}

	/// The plate and the type, at the sizes the file asks for: point size and
	/// padding are fractions of the frame height, so they are worked out
	/// against the picture on screen rather than against this view.
	private func drawCaption(_ text: String, style: TextStyle, at centre: NSPoint) {
		let height = picture.height
		let font = NSFont(name: style.font, size: max(4, style.size * height))
			?? NSFont.systemFont(ofSize: max(4, style.size * height))
		let attributes: [NSAttributedString.Key: Any] = [
			.font: font, .foregroundColor: colour(style.color),
		]
		let shown = text.isEmpty ? "caption" : text
		let size = (shown as NSString).size(withAttributes: attributes)
		let padding = style.padding * height
		let plate = NSSize(width: size.width + padding * 2, height: size.height + padding * 2)

		// Which point of the caption sits on the position is what `alignment`
		// decides — the same rule the renderer uses.
		let anchorX: CGFloat
		switch style.alignment {
		case .left: anchorX = 0
		case .right: anchorX = 1
		case .centre: anchorX = 0.5
		}
		let box = NSRect(x: centre.x - anchorX * plate.width, y: centre.y - plate.height / 2,
		                 width: plate.width, height: plate.height)
		grabBox = box.insetBy(dx: -4, dy: -4)

		if style.background.a > 0 {
			colour(style.background).setFill()
			let radius = min(style.cornerRadius * height, plate.height / 2)
			NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius).fill()
		}
		(shown as NSString).draw(at: NSPoint(x: box.minX + padding, y: box.minY + padding),
		                         withAttributes: attributes)
	}

	/// The ring, the dots or the arc, at the diameter the file asks for, with
	/// the first of its words beside it.
	private func drawSpinner(_ spinner: Spinner, words style: TextStyle, at centre: NSPoint) {
		let height = picture.height
		let diameter = max(6, spinner.size * height)
		let ink = colour(spinner.color)
		let box = NSRect(x: centre.x - diameter / 2, y: centre.y - diameter / 2,
		                 width: diameter, height: diameter)
		grabBox = box.insetBy(dx: -4, dy: -4)

		switch spinner.style {
		case .bars:
			// Lines round a circle: the classic spinner, and the one that reads
			// best over busy footage because the spokes reach the rim.
			let count = 12
			let width = diameter * 0.09
			let length = diameter * 0.28
			for step in 0..<count {
				let angle = Double(step) / Double(count) * 2 * .pi
				ink.withAlphaComponent(max(0.1, 1 - Double(step) / Double(count))).setFill()
				let path = NSBezierPath(roundedRect: NSRect(
					x: -width / 2, y: diameter / 2 - length - diameter * 0.04,
					width: width, height: length), xRadius: width / 2, yRadius: width / 2)
				let move = AffineTransform(translationByX: centre.x, byY: centre.y)
				var turn = AffineTransform(rotationByRadians: CGFloat(-angle))
				turn.append(move)
				let spoke = path.copy() as! NSBezierPath
				spoke.transform(using: turn)
				spoke.fill()
			}

		case .orbit:
			let inset = diameter * 0.12
			ink.withAlphaComponent(0.25).setStroke()
			let track = NSBezierPath(ovalIn: NSRect(
				x: centre.x - diameter / 2 + inset, y: centre.y - diameter / 2 + inset,
				width: diameter - inset * 2, height: diameter - inset * 2))
			track.lineWidth = diameter * 0.07
			track.stroke()
			let dot = diameter * 0.2
			ink.setFill()
			NSBezierPath(ovalIn: NSRect(
				x: centre.x - dot / 2, y: centre.y + diameter / 2 - inset - dot / 2 - diameter * 0.035,
				width: dot, height: dot)).fill()

		case .pulse:
			let inset = diameter * 0.14
			let box = NSRect(x: centre.x - diameter / 2 + inset, y: centre.y - diameter / 2 + inset,
			                 width: diameter - inset * 2, height: diameter - inset * 2)
			ink.withAlphaComponent(0.18).setFill()
			NSBezierPath(ovalIn: box).fill()
			ink.setStroke()
			let ring = NSBezierPath(ovalIn: box)
			ring.lineWidth = diameter * 0.08
			ring.stroke()

		case .bounce:
			let dots = 3
			let dot = diameter * 0.26
			let gap = (diameter - dot * CGFloat(dots)) / CGFloat(dots - 1)
			for step in 0..<dots {
				ink.withAlphaComponent(step == 1 ? 1 : 0.7).setFill()
				let rise = step == 1 ? diameter * 0.18 : 0
				NSBezierPath(ovalIn: NSRect(
					x: centre.x - diameter / 2 + CGFloat(step) * (dot + gap),
					y: centre.y - dot / 2 + rise, width: dot, height: dot)).fill()
			}

		case .dots:
			// Twelve dots round the circle, each further through the same fade.
			let count = 12
			let dot = diameter * 0.16
			let radius = (diameter - dot) / 2
			for step in 0..<count {
				let angle = Double(step) / Double(count) * 2 * .pi
				let at = NSPoint(x: centre.x + CGFloat(sin(angle)) * radius,
				                 y: centre.y + CGFloat(cos(angle)) * radius)
				ink.withAlphaComponent(max(0.12, 1 - Double(step) / Double(count))).setFill()
				NSBezierPath(ovalIn: NSRect(x: at.x - dot / 2, y: at.y - dot / 2,
				                            width: dot, height: dot)).fill()
			}

		case .ring, .arc:
			let inset = diameter * 0.12
			let path = NSBezierPath()
			let sweep = spinner.style == .ring ? 270.0 : 100.0
			path.appendArc(withCenter: centre, radius: (diameter - inset * 2) / 2,
			               startAngle: 90, endAngle: 90 - sweep, clockwise: true)
			path.lineWidth = diameter * 0.10
			path.lineCapStyle = .round
			ink.setStroke()
			path.stroke()
		}

		guard let word = spinner.words.first else { return }
		let font = NSFont(name: style.font, size: max(4, style.size * height))
			?? NSFont.systemFont(ofSize: max(4, style.size * height))
		let attributes: [NSAttributedString.Key: Any] = [
			.font: font, .foregroundColor: colour(style.color),
		]
		let size = (word.text as NSString).size(withAttributes: attributes)
		let gap = diameter * 0.45
		(word.text as NSString).draw(
			at: NSPoint(x: box.maxX + gap, y: centre.y - size.height / 2),
			withAttributes: attributes)
	}

	private func colour(_ rgba: RGBA) -> NSColor {
		NSColor(calibratedRed: rgba.r, green: rgba.g, blue: rgba.b, alpha: rgba.a)
	}

	// MARK: - Dragging

	/// Grabbing the picture takes the focus off whatever field had it.
	///
	/// Which matters for more than the ring: a field being typed into stops the
	/// panel reloading — otherwise the file would come back mid-word and take
	/// the cursor with it — so a drag that left the focus where it was wrote a
	/// new value into a form that had been told not to look.
	public override var acceptsFirstResponder: Bool { true }

	public override func mouseDown(with event: NSEvent) {
		window?.makeFirstResponder(self)
		let place = convert(event.locationInWindow, from: nil)
		let centre = point(spot)
		// Grabbed by the overlay keeps the pointer where it took hold; a click
		// anywhere else on the frame puts it there, which is what a click on a
		// picture means.
		if grabBox.contains(place) {
			grab = CGSize(width: centre.x - place.x, height: centre.y - place.y)
		} else {
			grab = .zero
			spot = unit(place)
		}
		dragging = true
		needsDisplay = true
	}

	public override func mouseDragged(with event: NSEvent) {
		guard dragging else { return }
		let place = convert(event.locationInWindow, from: nil)
		spot = unit(NSPoint(x: place.x + grab.width, y: place.y + grab.height))
	}

	public override func mouseUp(with event: NSEvent) {
		guard dragging else { return }
		dragging = false
		needsDisplay = true
		onMove?(spot)
	}
}
