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
		/// A bubble, drawn by the code that renders it, with a handle on the
		/// paper and a handle on the tail's tip.
		///
		/// The whole resolved appearance rather than the ``Bubble`` alone,
		/// because none of the three things that decide where a bubble goes is
		/// on the bubble: `offset:` is on the overlay, what it stands off from
		/// is the anchor's path, and which drawing is up depends on when it
		/// came on. Handed the appearance, this view can ask ``BubblePlacing``
		/// the same questions the renderer asks, which is the whole point.
		case bubble(ResolvedOverlay, of: Project)
	}

	public var content: Content = .caption("", TextStyle.lowerThird) {
		didSet { needsDisplay = true }
	}
	/// Said under the picture: what a drag will change. A bubble says its own,
	/// because only this view knows which of its two handles is live at this
	/// moment.
	public var explanation = ""

	/// The moment of the programme the picture is of.
	///
	/// It matters for a bubble and for nothing else: the anchor travels, so
	/// where the handles are and what a drag writes are both questions about
	/// the frame being looked at. See ``BubblePlacing/Origins``.
	public var moment: Double = 0 { didSet { needsDisplay = true } }

	/// Where it was let go. Called once, at the end of the drag — a project
	/// written on every mouse-moved event would be a file rewritten sixty times
	/// a second.
	public var onMove: ((CGPoint) -> Void)?

	/// A bubble's paper was let go: the `offset:` that puts it there.
	public var onOffset: ((CGPoint) -> Void)?
	/// A bubble's tail tip was let go: the `tail:` that puts it there.
	public var onTail: ((CGPoint) -> Void)?

	private var dragging = false
	/// How far the thing being dragged is from the pointer, so that it keeps the
	/// hold it was picked up by.
	///
	/// In view points for a caption or a spinner and in the frame's own
	/// coordinates for a bubble, because those two drags are worked out in
	/// different spaces — a caption's position is a unit point of the picture and
	/// a bubble's is a distance in frame heights. One drag is on at a time, so it
	/// is one field.
	private var grab = CGSize.zero
	/// Where the overlay was last drawn, so it can be grabbed by itself rather
	/// than by a rectangle guessed from its name.
	private var grabBox = NSRect.zero

	/// Which of a bubble's two handles a drag has hold of.
	private enum Grip { case paper, tip }
	private var grip: Grip?
	/// What the file would say if the mouse were let go now.
	///
	/// The picture is drawn from these while a drag is on, so what somebody is
	/// looking at *is* the number that will be written — rounding and the
	/// frame's edge included. A preview drawn from the raw pointer and written
	/// from something else is the class of bug this whole view exists to end.
	private var liveOffset: CGPoint?
	private var liveTail: CGPoint?
	/// What the numbers were when the drag began, and whether the mouse has
	/// actually gone anywhere. A drag that lands where it started writes
	/// nothing at all: no key, no diff, no version kept.
	private var began: (offset: CGPoint, tail: CGPoint)?
	private var went = false
	/// Where the tip was last drawn, in view points, for grabbing it.
	private var tipHandle: NSPoint?
	/// The paper as it was last drawn, so it can be picked up anywhere on itself
	/// rather than only by the ring in the middle of it. Empty for a bubble with
	/// nothing to be relative to, which is one that cannot be dragged at all.
	private var paperGrab = NSRect.zero
	/// What the last drawing worked out about the bubble, in the frame's own
	/// coordinates: where `offset:` put the paper before the edge of the frame
	/// pushed it back in, and the two points the numbers hang off.
	private var grabbed: (home: CGPoint, origins: BubblePlacing.Origins)?

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
	///
	/// Not private, because the tests measure against it: the claim a drag makes
	/// is that a point in *this* rectangle becomes the fraction of the frame it
	/// is a fraction of, at any window size, and that claim cannot be checked
	/// without knowing where the picture ended up.
	var picture: NSRect {
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

	// MARK: - The frame's own coordinates

	/// How many pixels to a point in the picture.
	///
	/// The bubble is drawn at the screen's resolution rather than at the
	/// picture's point size — every number in a bubble is a fraction of the
	/// frame, so it is the same drawing at any size, and drawing it small and
	/// scaling it up would be the one part of this window that looked like a
	/// preview.
	private var scale: CGFloat { window?.backingScaleFactor ?? 2 }

	/// The frame, in the units the bubble is drawn in.
	private var frameSize: CGSize {
		CGSize(width: picture.width * scale, height: picture.height * scale)
	}

	/// A place in this view, in the frame's own coordinates.
	///
	/// Clamped to the picture, because a bubble aimed outside the frame is aimed
	/// at nothing: the render masks the tree to the frame and the tail would lie
	/// along the edge it left by.
	private func framePoint(_ place: NSPoint) -> CGPoint {
		let unit = self.unit(place)
		let size = frameSize
		return CGPoint(x: unit.x * size.width, y: unit.y * size.height)
	}

	/// And back: where a point of the frame is on screen.
	private func viewPoint(_ point: CGPoint) -> NSPoint {
		let picture = self.picture
		return NSPoint(x: picture.minX + point.x / scale, y: picture.minY + point.y / scale)
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

		var note = explanation
		if case .bubble(let resolved, let project) = content {
			// A bubble carries its own picture and its own two handles, and it
			// is the only content that knows at this moment which of them can be
			// dragged — so it says so itself.
			note = drawBubble(resolved, of: project)
		} else {
			// What it follows, and the line from there to where it sits: the
			// offset, drawn as the thing it is.
			if let anchorPoint {
				drawAnchor(at: point(anchorPoint), leadingTo: point(spot))
			}
			drawContent(at: point(spot))
		}

		if !note.isEmpty {
			(note as NSString).draw(
				at: NSPoint(x: 8, y: 4),
				withAttributes: [.font: Theme.monoSmall, .foregroundColor: Theme.faintText])
		}
	}

	/// The thing an overlay is measured from: a ring with a cross through it,
	/// and a dashed line to wherever that put the overlay.
	///
	/// `named` is off for a bubble. There are already four marks in that picture
	/// — the crosshair, the ring on the paper, the diamond on the tip and the
	/// line between them — and a bubble's tail commonly lands within a few points
	/// of the face, where the name would be printed straight across the diamond.
	/// The panel says which anchor it is two rows further down, in a row that is
	/// about exactly that.
	private func drawAnchor(at centre: NSPoint, leadingTo spot: NSPoint?,
	                        named: Bool = true) {
		let colour = Theme.color(.anchor)
		colour.setStroke()
		let ring = NSBezierPath(ovalIn: NSRect(x: centre.x - 6, y: centre.y - 6,
		                                       width: 12, height: 12))
		ring.lineWidth = 1.5
		ring.stroke()
		let cross = NSBezierPath()
		cross.move(to: NSPoint(x: centre.x - 10, y: centre.y))
		cross.line(to: NSPoint(x: centre.x + 10, y: centre.y))
		cross.move(to: NSPoint(x: centre.x, y: centre.y - 10))
		cross.line(to: NSPoint(x: centre.x, y: centre.y + 10))
		cross.stroke()

		if let spot {
			let leash = NSBezierPath()
			leash.move(to: centre)
			leash.line(to: spot)
			leash.setLineDash([3, 3], count: 2, phase: 0)
			colour.withAlphaComponent(0.6).setStroke()
			leash.stroke()
		}

		if let anchorName, named {
			(anchorName as NSString).draw(
				at: NSPoint(x: centre.x + 12, y: centre.y + 2),
				withAttributes: [.font: Theme.monoSmall, .foregroundColor: colour])
		}
	}

	// MARK: - A bubble

	/// The appearance with whatever is being dragged put into it.
	///
	/// So the picture is drawn from the numbers the drag will write rather than
	/// from the pointer: rounding, the frame's edge and the smoothing all have
	/// their say before anything is on screen, and what somebody lets go of is
	/// what comes out of the render.
	private func live(_ resolved: ResolvedOverlay) -> ResolvedOverlay {
		guard case .bubble(var bubble) = resolved.overlay.kind else { return resolved }
		var overlay = resolved.overlay
		if let liveOffset { overlay.offset = liveOffset }
		if let liveTail { bubble.tail = liveTail }
		overlay.kind = .bubble(bubble)
		return resolved.showing(overlay)
	}

	/// Where the bubble's handles are, worked out and remembered.
	///
	/// Called from the drawing, and called again from a mouse down that arrives
	/// before there has been one: a view that could only be dragged after it had
	/// been on screen would be a view whose behaviour depended on the window
	/// having been shown, which is neither testable nor true of anything else
	/// here.
	@discardableResult
	private func measureBubble() -> BubblePlacing.Placement? {
		guard case .bubble(let resolved, let project) = content else { return nil }
		let live = self.live(resolved)
		guard case .bubble(let bubble) = live.overlay.kind else { return nil }
		let size = frameSize
		guard size.width >= 1, size.height >= 1 else { return nil }
		let placed = BubblePlacing.placement(bubble, resolved: live, project: project,
		                                     size: size, at: moment)
		remember(placed)
		return placed
	}

	/// What the mouse needs from the last measurement.
	private func remember(_ placed: BubblePlacing.Placement) {
		grabbed = (placed.home, placed.origins)
		if placed.origins.paper != nil {
			let corner = viewPoint(CGPoint(x: placed.box.minX, y: placed.box.minY))
			paperGrab = NSRect(x: corner.x, y: corner.y,
			                   width: placed.box.width / scale,
			                   height: placed.box.height / scale)
		} else {
			paperGrab = .zero
		}
		tipHandle = placed.origins.tip == nil ? nil : placed.tip.map(viewPoint)
	}

	/// The bubble as it will be drawn, with a handle on the paper and one on the
	/// tail's tip. Answers with what to say under the picture.
	private func drawBubble(_ resolved: ResolvedOverlay, of project: Project) -> String {
		tipHandle = nil
		paperGrab = .zero
		grabbed = nil
		let live = self.live(resolved)
		guard case .bubble(let bubble) = live.overlay.kind else { return "" }
		let picture = self.picture
		let size = frameSize
		guard size.width >= 1, size.height >= 1 else { return "" }

		let drawn = BubblePlacing.drawing(bubble, resolved: live, project: project,
		                                  size: size, at: moment)
		if let image = drawn.image, let context = NSGraphicsContext.current?.cgContext {
			context.saveGState()
			context.clip(to: picture)
			context.draw(image, in: picture)
			context.restoreGState()
		}
		let placed = drawn.at
		remember(placed)

		// What the numbers are measured from, drawn as the thing it is: for an
		// anchored bubble the face, for one with `at:` the spot it is about.
		if let origin = placed.origins.paper {
			drawAnchor(at: viewPoint(origin), leadingTo: nil, named: false)
		}

		let colour = Theme.color(.bubble)
		let paper = viewPoint(placed.paper)
		if placed.origins.paper != nil {
			// A ring for the paper and a solid diamond for the tip: two shapes
			// rather than two shades, so which is which needs no legend and
			// survives being drawn over a busy frame.
			//
			// The ring is hollow because it lands in the middle of the words,
			// and a disc there covers a letter of the sentence somebody is
			// placing. It is only a marker in any case: the whole of the paper
			// can be picked up, and the ring says which point `offset:` names.
			let box = NSRect(x: paper.x - 4.5, y: paper.y - 4.5, width: 9, height: 9)
			NSColor.black.withAlphaComponent(0.55).setStroke()
			let rim = NSBezierPath(ovalIn: box.insetBy(dx: -1, dy: -1))
			rim.lineWidth = 1
			rim.stroke()
			colour.setStroke()
			let ring = NSBezierPath(ovalIn: box)
			ring.lineWidth = 2
			ring.stroke()
		}

		if let at = tipHandle {
			let diamond = NSBezierPath()
			diamond.move(to: NSPoint(x: at.x, y: at.y + 6))
			diamond.line(to: NSPoint(x: at.x + 6, y: at.y))
			diamond.line(to: NSPoint(x: at.x, y: at.y - 6))
			diamond.line(to: NSPoint(x: at.x - 6, y: at.y))
			diamond.close()
			colour.setFill()
			diamond.fill()
			NSColor.black.withAlphaComponent(0.55).setStroke()
			diamond.lineWidth = 1
			diamond.stroke()
			// A hairline between the two, so the pair reads as one bubble's two
			// positions rather than as two things that happen to be near.
			if placed.origins.paper != nil {
				let pair = NSBezierPath()
				pair.move(to: paper)
				pair.line(to: at)
				pair.setLineDash([2, 3], count: 2, phase: 0)
				colour.withAlphaComponent(0.5).setStroke()
				pair.stroke()
			}
		}

		if placed.origins.paper == nil {
			return "no anchor and no `at:` — it sits where style `"
				+ (bubble.style ?? "bubble") + "` says, and `offset:` is not read"
		}
		if placed.origins.tip == nil {
			return "drag the disc: `offset:` — no tracking at this moment, so no tip to aim"
		}
		return "drag the disc: `offset:`  ·  the diamond: `tail:`"
	}

	/// The overlay, drawn the way the renderer draws it.
	private func drawContent(at centre: NSPoint) {
		switch content {
		case .caption(let text, let style):
			drawCaption(text, style: style, at: centre)
		case .spinner(let spinner, let wordStyle):
			drawSpinner(spinner, words: wordStyle, at: centre)
		case .bubble:
			// Never reached: a bubble is drawn by ``drawBubble(_:of:)``, which
			// has two positions to draw and a picture of its own to draw them
			// on. It does not sit on one `spot`.
			break
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
		begin(at: convert(event.locationInWindow, from: nil))
	}

	public override func mouseDragged(with event: NSEvent) {
		drag(to: convert(event.locationInWindow, from: nil))
	}

	public override func mouseUp(with event: NSEvent) { end() }

	/// The three of them again, in this view's own coordinates.
	///
	/// Separated from the events so the tests can drive a drag without making
	/// one: an `NSEvent` needs a window to have a location in, and what is
	/// actually under test is the arithmetic between a point in this view and a
	/// number in the file.
	func begin(at place: NSPoint) {
		went = false
		if case .bubble(let resolved, _) = content {
			if grabbed == nil { measureBubble() }
			guard case .bubble(let bubble) = resolved.overlay.kind, let grabbed else { return }
			began = (resolved.overlay.offset, bubble.tail)
			let from = framePoint(place)
			// The tip is asked first, and given room, because it is the one that
			// can end up under the paper — a tail aimed at a mouth beside a
			// bubble that covers the mouth. Losing the tip to the thing it
			// points out from would leave it unreachable.
			if let tipHandle, hypot(tipHandle.x - place.x, tipHandle.y - place.y) <= 10 {
				grip = .tip
				let tip = framePoint(tipHandle)
				grab = CGSize(width: tip.x - from.x, height: tip.y - from.y)
			} else if paperGrab.contains(place) {
				// Grabbed by the paper keeps the pointer where it took hold. The
				// paper is drawn where the frame's edge allows and the number is
				// read off its home, which are the same point everywhere but up
				// against an edge — and this is what bridges the two, so a
				// bubble resting on a margin does not jump when it is picked up.
				grip = .paper
				grab = CGSize(width: grabbed.home.x - from.x, height: grabbed.home.y - from.y)
			} else {
				// A click on the picture away from either handle moves the paper
				// there, which is what a click on a picture has always meant
				// here. The tip stays where it was: it is measured from the face
				// and not from the paper, so it does not travel with it.
				grip = .paper
				grab = .zero
				dragging = true
				drag(to: place)
				return
			}
			dragging = true
			needsDisplay = true
			return
		}

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

	func drag(to place: NSPoint) {
		guard dragging || grip != nil else { return }
		went = true
		if let grip, let grabbed {
			let from = framePoint(place)
			let point = CGPoint(x: from.x + grab.width, y: from.y + grab.height)
			switch grip {
			case .paper:
				liveOffset = BubblePlacing.offset(forPaper: point, origins: grabbed.origins,
				                                  size: frameSize)
			case .tip:
				liveTail = BubblePlacing.tail(forTip: point, origins: grabbed.origins,
				                              size: frameSize)
			}
			needsDisplay = true
			return
		}
		guard dragging else { return }
		spot = unit(NSPoint(x: place.x + grab.width, y: place.y + grab.height))
	}

	func end() {
		guard dragging else { return }
		dragging = false
		needsDisplay = true
		if let grip {
			// Written only where it moved. A drag that lands where it started is
			// a look, not an edit: no key written, no diff, and no version kept
			// of a file that is the same file.
			let started = began
			self.grip = nil
			began = nil
			let offset = liveOffset
			let tail = liveTail
			liveOffset = nil
			liveTail = nil
			guard went else { return }
			switch grip {
			case .paper:
				guard let offset, offset != started?.offset else { return }
				onOffset?(offset)
			case .tip:
				guard let tail, tail != started?.tail else { return }
				onTail?(tail)
			}
			return
		}
		onMove?(spot)
	}
}
