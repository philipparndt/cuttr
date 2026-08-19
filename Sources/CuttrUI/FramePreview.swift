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
	/// What to draw there.
	public var label = ""
	public var kind: Theme.Kind = .text
	/// Said under the picture: what a drag will change.
	public var explanation = ""

	/// Where it was let go. Called once, at the end of the drag — a project
	/// written on every mouse-moved event would be a file rewritten sixty times
	/// a second.
	public var onMove: ((CGPoint) -> Void)?

	private var dragging = false
	private var grab = CGSize.zero

	public override init(frame: NSRect) {
		super.init(frame: frame)
		wantsLayer = true
		layer?.backgroundColor = Theme.background.cgColor
		layer?.cornerRadius = 4
	}

	@available(*, unavailable) required init?(coder: NSCoder) { nil }

	public override var intrinsicContentSize: NSSize {
		NSSize(width: NSView.noIntrinsicMetric, height: 190)
	}

	// MARK: - Geometry

	/// The frame's rectangle inside this view, letterboxed like the render.
	private var picture: NSRect {
		let box = bounds.insetBy(dx: 8, dy: 8)
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

		drawPuck(at: point(spot))

		if !explanation.isEmpty {
			(explanation as NSString).draw(
				at: NSPoint(x: 8, y: 2),
				withAttributes: [.font: Theme.monoSmall, .foregroundColor: Theme.faintText])
		}
	}

	/// The overlay itself, as a chip: it is dragged, so it has to look grabbable
	/// and it has to say which overlay it is.
	private func drawPuck(at centre: NSPoint) {
		let colour = Theme.color(kind)
		let attributes: [NSAttributedString.Key: Any] = [
			.font: Theme.monoSmall, .foregroundColor: NSColor.black,
		]
		let text = label.isEmpty ? "overlay" : String(label.prefix(24))
		let size = (text as NSString).size(withAttributes: attributes)
		let box = NSRect(x: centre.x - (size.width + 16) / 2, y: centre.y - 9,
		                 width: size.width + 16, height: 18)
		colour.withAlphaComponent(dragging ? 1 : 0.85).setFill()
		NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
		(text as NSString).draw(at: NSPoint(x: box.minX + 8, y: box.minY + 3), withAttributes: attributes)

		NSColor.white.withAlphaComponent(0.9).setStroke()
		let dot = NSBezierPath(ovalIn: NSRect(x: centre.x - 1.5, y: centre.y - 1.5, width: 3, height: 3))
		dot.stroke()
	}

	// MARK: - Dragging

	public override func mouseDown(with event: NSEvent) {
		let place = convert(event.locationInWindow, from: nil)
		let centre = point(spot)
		// Grabbed by the chip keeps the pointer where it took hold; a click
		// anywhere else on the frame puts it there, which is what a click on a
		// picture means.
		if abs(place.x - centre.x) < 60, abs(place.y - centre.y) < 14 {
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
