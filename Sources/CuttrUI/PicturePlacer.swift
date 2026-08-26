import AppKit
import CuttrCompose
import CuttrKit

/// Where the picture goes while a presentation treatment holds it — drawn, and
/// dragged.
///
/// **Why this exists.** `into:` is four fractions, and four fractions is not how
/// anybody decides which half of the frame a screen recording goes in. Worse,
/// the numbers do not say *what* goes in the box: the first question anybody
/// asked of them was whether the rectangle is where the text goes and the
/// picture fills the rest. It is the other way round — the rectangle is the
/// recording, and the scene lays itself out in whatever is left — and a picture
/// of it says that in one glance where a paragraph does not.
///
/// So: the frame at the shape of the output, the recording drawn where it will
/// be, and the side it leaves free shaded and named for the scene that will
/// fill it. Dragged by the body, resized by the corners, snapped to the edges
/// and the middle.
@MainActor
public final class PicturePlacer: NSView {

	/// The shape of the render, so the box is the shape of the output.
	public var aspect = CGSize(width: 16, height: 9) { didSet { needsDisplay = true } }
	/// Where the picture goes, in fractions of the frame.
	///
	/// Setting it ends whatever a drag was showing. That order matters: the
	/// drag's own value stands until the document says otherwise, so the box
	/// does not flick back to where it was for the frame between letting go and
	/// the form being rebuilt.
	public var picture = Presentation.Rectangle.whole {
		didSet {
			dragged = nil
			needsDisplay = true
		}
	}
	/// A frame of the recording, if one could be had — drawn inside the box, at
	/// the size and shape it will actually be.
	public var poster: NSImage? { didSet { needsDisplay = true } }
	/// What plays in the space the picture leaves, so the shaded half is named
	/// rather than merely empty.
	public var sceneName = "" { didSet { needsDisplay = true } }

	/// Live all the way through the drag, once more with `true` on the way up —
	/// the same contract the stage and the strip use, so one drag is one undo
	/// step.
	public var onChange: ((Presentation.Rectangle, Bool) -> Void)?

	private enum Grab {
		/// Where in the box it was grabbed, in fractions of the frame.
		case body(CGPoint)
		/// Which corner: −1 or 1 in each direction.
		case corner(CGPoint)
	}

	private var grab: Grab?
	/// Drawn from this while a drag is on, so the picture keeps up with the
	/// mouse rather than with the round trip through the document.
	private var dragged: Presentation.Rectangle?
	private let handleSize: CGFloat = 7

	public override init(frame: NSRect) {
		super.init(frame: frame)
		wantsLayer = true
		translatesAutoresizingMaskIntoConstraints = false
		heightAnchor.constraint(equalToConstant: 132).isActive = true
	}

	@available(*, unavailable) required init?(coder: NSCoder) { nil }

	public override var isFlipped: Bool { false }

	/// What is being drawn: the drag if there is one, the value otherwise.
	private var shown: Presentation.Rectangle { dragged ?? picture }

	// MARK: - Where the frame is

	/// The output's rectangle inside the view, aspect-fitted with a margin —
	/// everything is measured against this and not against the view.
	private var frame_: NSRect {
		let inset = bounds.insetBy(dx: 8, dy: 8)
		guard aspect.width > 0, aspect.height > 0, inset.width > 1, inset.height > 1
		else { return bounds }
		let scale = min(inset.width / aspect.width, inset.height / aspect.height)
		let size = CGSize(width: aspect.width * scale, height: aspect.height * scale)
		return NSRect(x: inset.midX - size.width / 2, y: inset.midY - size.height / 2,
		              width: size.width, height: size.height)
	}

	private func onScreen(_ box: Presentation.Rectangle) -> NSRect {
		let frame = frame_
		return NSRect(x: frame.minX + box.x * frame.width,
		              y: frame.minY + box.y * frame.height,
		              width: box.width * frame.width, height: box.height * frame.height)
	}

	private func inFrame(_ point: NSPoint) -> CGPoint {
		let frame = frame_
		return CGPoint(x: (point.x - frame.minX) / max(frame.width, 0.001),
		               y: (point.y - frame.minY) / max(frame.height, 0.001))
	}

	// MARK: - Drawing

	public override func draw(_ dirtyRect: NSRect) {
		Theme.card.setFill()
		dirtyRect.fill()
		let frame = frame_
		let box = shown

		// The ground the frame stands on, which is what is behind a picture
		// that has been moved aside: nothing, and nothing renders black.
		NSColor.black.setFill()
		frame.fill()

		drawFreeColumn(in: frame, beside: box)
		drawPicture(onScreen(box), in: frame)

		Theme.rule.setStroke()
		NSBezierPath(rect: frame.insetBy(dx: -0.5, dy: -0.5)).stroke()
	}

	/// The side the picture leaves free, shaded and named.
	///
	/// Named, because that side is not empty in the render — it is where the
	/// scene lays itself out, and the whole misreading this view exists to
	/// correct is which of the two halves is which.
	private func drawFreeColumn(in frame: NSRect, beside box: Presentation.Rectangle) {
		guard !box.isWhole else { return }
		let free = box.free
		guard free.width > 0.06 else { return }
		let column = NSRect(x: frame.minX + free.x * frame.width, y: frame.minY,
		                    width: free.width * frame.width, height: frame.height)
		Theme.accent.withAlphaComponent(0.12).setFill()
		column.fill()

		let words = sceneName.isEmpty ? "the scene" : sceneName
		let attributes: [NSAttributedString.Key: Any] = [
			.font: Theme.monoSmall, .foregroundColor: Theme.accent,
		]
		let size = (words as NSString).size(withAttributes: attributes)
		guard size.width < column.width - 6 else { return }
		(words as NSString).draw(
			at: NSPoint(x: column.midX - size.width / 2, y: column.midY - size.height / 2),
			withAttributes: attributes)
	}

	/// The recording, where it will be — fitted inside the box and keeping its
	/// shape, which is what the render does, so a box of the wrong aspect shows
	/// its letterboxing here rather than in the export.
	private func drawPicture(_ box: NSRect, in frame: NSRect) {
		let inside: NSRect
		if let poster, poster.size.width > 0, poster.size.height > 0 {
			let fit = min(box.width / poster.size.width, box.height / poster.size.height)
			let size = CGSize(width: poster.size.width * fit, height: poster.size.height * fit)
			inside = NSRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2,
			                width: size.width, height: size.height)
			poster.draw(in: inside)
		} else {
			// No frame to be had — the window has not built one yet, or there
			// is nothing at this moment to build it from. A filled box says
			// where the picture goes without pretending to be it.
			let fit = min(box.width / aspect.width, box.height / aspect.height)
			let size = CGSize(width: aspect.width * fit, height: aspect.height * fit)
			inside = NSRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2,
			                width: size.width, height: size.height)
			Theme.cardHigh.setFill()
			inside.fill()
			let words = "the recording"
			let attributes: [NSAttributedString.Key: Any] = [
				.font: Theme.monoSmall, .foregroundColor: Theme.dimText,
			]
			let said = (words as NSString).size(withAttributes: attributes)
			if said.width < inside.width - 6 {
				(words as NSString).draw(
					at: NSPoint(x: inside.midX - said.width / 2,
					            y: inside.midY - said.height / 2),
					withAttributes: attributes)
			}
		}

		// The handles are on the *box*, not on the picture inside it: the box
		// is what `into:` says and what a drag writes. Where the two differ is
		// the letterboxing, and seeing that gap is the point.
		Theme.accent.setStroke()
		let outline = NSBezierPath(rect: box.insetBy(dx: 0.5, dy: 0.5))
		outline.lineWidth = 1
		outline.stroke()
		Theme.accent.setFill()
		for corner in corners(of: box) {
			NSRect(x: corner.x - handleSize / 2, y: corner.y - handleSize / 2,
			       width: handleSize, height: handleSize).fill()
		}
	}

	private func corners(of box: NSRect) -> [NSPoint] {
		[NSPoint(x: box.minX, y: box.minY), NSPoint(x: box.maxX, y: box.minY),
		 NSPoint(x: box.maxX, y: box.maxY), NSPoint(x: box.minX, y: box.maxY)]
	}

	// MARK: - Dragging

	public override func mouseDown(with event: NSEvent) {
		let point = convert(event.locationInWindow, from: nil)
		let box = onScreen(picture)
		for (index, corner) in corners(of: box).enumerated()
		where abs(point.x - corner.x) <= handleSize && abs(point.y - corner.y) <= handleSize {
			let sx: Double = index == 0 || index == 3 ? -1 : 1
			let sy: Double = index < 2 ? -1 : 1
			grab = .corner(CGPoint(x: sx, y: sy))
			return
		}
		guard box.contains(point) else { return }
		let at = inFrame(point)
		grab = .body(CGPoint(x: at.x - picture.x, y: at.y - picture.y))
	}

	public override func mouseDragged(with event: NSEvent) {
		guard grab != nil else { return }
		apply(event, commit: false)
	}

	public override func mouseUp(with event: NSEvent) {
		guard grab != nil else { return }
		apply(event, commit: true)
		grab = nil
		// `dragged` is deliberately left standing. It is let go of when the
		// document hands back a new ``picture``, which is a turn of the run
		// loop later — and clearing it here drew the old box for exactly that
		// turn, which is a picture that jumps back and then forward again
		// under somebody's hand.
		needsDisplay = true
	}

	private func apply(_ event: NSEvent, commit: Bool) {
		guard let grab else { return }
		let at = inFrame(convert(event.locationInWindow, from: nil))
		let free = event.modifierFlags.contains(.option)
		var box = picture

		switch grab {
		case .body(let held):
			box.x = at.x - held.x
			box.y = at.y - held.y
			// Kept inside the frame: a picture dragged off the edge is a
			// picture nobody can see and a box nobody can grab back.
			box.x = min(max(box.x, 0), max(0, 1 - box.width))
			box.y = min(max(box.y, 0), max(0, 1 - box.height))
			if !free {
				box.x = snapped(box.x, box.width)
				box.y = snapped(box.y, box.height)
			}

		case .corner(let which):
			// The opposite corner stays where it is, which is what a corner
			// handle means everywhere else somebody has used one.
			let anchor = CGPoint(x: which.x < 0 ? box.x + box.width : box.x,
			                     y: which.y < 0 ? box.y + box.height : box.y)
			let held = CGPoint(x: min(max(at.x, 0), 1), y: min(max(at.y, 0), 1))
			box.x = min(anchor.x, held.x)
			box.y = min(anchor.y, held.y)
			box.width = abs(held.x - anchor.x)
			box.height = abs(held.y - anchor.y)
			// Never nothing: a box dragged shut cannot be dragged open again.
			box.width = max(0.05, box.width)
			box.height = max(0.05, box.height)
		}

		if !free {
			box.x = (box.x * 100).rounded() / 100
			box.y = (box.y * 100).rounded() / 100
			box.width = (box.width * 100).rounded() / 100
			box.height = (box.height * 100).rounded() / 100
		}
		dragged = box
		needsDisplay = true
		onChange?(box, commit)
	}

	/// Snapped to the frame's edges and to the middle, unless somebody says
	/// otherwise with ⌥. A picture put against the left edge is meant to be
	/// against it, not at 0.0137.
	private func snapped(_ value: Double, _ extent: Double) -> Double {
		let slop = 0.02
		for landmark in [0.0, (1 - extent) / 2, 1 - extent] where abs(value - landmark) < slop {
			return max(0, landmark)
		}
		return value
	}

	public override func resetCursorRects() {
		super.resetCursorRects()
		let box = onScreen(picture)
		for corner in corners(of: box) {
			addCursorRect(NSRect(x: corner.x - handleSize, y: corner.y - handleSize,
			                     width: handleSize * 2, height: handleSize * 2),
			              cursor: .crosshair)
		}
		addCursorRect(box.insetBy(dx: handleSize, dy: handleSize), cursor: .openHand)
	}

	/// For the tests: what a drag would be aiming at, and where the frame is —
	/// the arithmetic that turns a point on screen into a fraction of the frame
	/// is the part that goes wrong, and it is measured against this rectangle
	/// rather than against the view.
	var boxForTesting: Presentation.Rectangle { shown }
	var frameForTesting: NSRect { frame_ }

	/// For the tests: a point at these fractions of the frame, in the view's
	/// own coordinates.
	func pointForTesting(_ x: Double, _ y: Double) -> NSPoint {
		let frame = frame_
		return NSPoint(x: frame.minX + x * frame.width, y: frame.minY + y * frame.height)
	}
}
