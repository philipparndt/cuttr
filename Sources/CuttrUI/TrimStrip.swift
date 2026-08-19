import AppKit
import CuttrKit

/// The two frames a trim decides: the first one this placement shows, and the
/// last.
///
/// Trimming by typing seconds into a field is guessing. What somebody means is
/// "start after she stops fidgeting" and "end before the door", and both of
/// those are frames — so they are shown, and dragging either one moves that end
/// of the clip. The numbers stay under them, because the numbers are what the
/// file says.
@MainActor
public final class TrimStrip: NSView {

	/// The frames, when they arrive.
	public var head: NSImage? { didSet { needsDisplay = true } }
	public var tail: NSImage? { didSet { needsDisplay = true } }
	/// What is trimmed off each end now, in seconds.
	public var trim: (head: Double, tail: Double) = (0, 0) { didSet { needsDisplay = true } }
	/// How long the untrimmed clip is, so a drag cannot trim past its far end.
	public var length: Double = 0

	/// A drag is happening: the ends as they stand, for the frames to follow.
	public var onScrub: ((Double, Double) -> Void)?
	/// A drag finished: what to write down.
	public var onTrim: ((Double, Double) -> Void)?

	private enum Side { case head, tail }
	private var dragging: (side: Side, from: CGFloat, was: Double)?
	/// Seconds per point, so a slow drag is frames and a long one is seconds.
	private let rate = 0.02

	public override init(frame: NSRect) {
		super.init(frame: frame)
		wantsLayer = true
		layer?.backgroundColor = Theme.background.cgColor
		layer?.cornerRadius = 4
	}

	@available(*, unavailable) required init?(coder: NSCoder) { nil }

	/// How tall it wants to be. Small in a form, large in the dialog, where
	/// the frames are what somebody is actually looking at.
	public var preferredHeight: CGFloat = 116 {
		didSet { invalidateIntrinsicContentSize() }
	}

	public override var intrinsicContentSize: NSSize {
		NSSize(width: NSView.noIntrinsicMetric, height: preferredHeight)
	}

	private var frames: (head: NSRect, tail: NSRect) {
		let box = bounds.insetBy(dx: 6, dy: 6)
		let width = (box.width - 6) / 2
		return (NSRect(x: box.minX, y: box.minY + 16, width: width, height: box.height - 16),
		        NSRect(x: box.minX + width + 6, y: box.minY + 16, width: width, height: box.height - 16))
	}

	public override func draw(_ dirtyRect: NSRect) {
		let frames = self.frames
		for (side, rect, picture, seconds) in [
			(Side.head, frames.head, head, trim.head),
			(Side.tail, frames.tail, tail, trim.tail),
		] {
			NSColor(calibratedWhite: 0.07, alpha: 1).setFill()
			rect.fill()
			picture?.draw(in: rect, from: .zero, operation: .copy, fraction: 1)

			(dragging?.side == side ? Theme.accent : Theme.rule).setStroke()
			NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()

			// The edge being trimmed, marked on the side it is cut from.
			Theme.accent.setFill()
			let edge = side == .head ? rect.minX : rect.maxX - 3
			NSRect(x: edge, y: rect.minY, width: 3, height: rect.height).fill()

			let label = (side == .head ? "head " : "tail ")
				+ (seconds > 0 ? "−\(Timecode.string(seconds))" : "whole")
			(label as NSString).draw(
				at: NSPoint(x: rect.minX + 2, y: bounds.minY + 4),
				withAttributes: [.font: Theme.monoSmall,
				                 .foregroundColor: seconds > 0 ? Theme.text : Theme.faintText])
		}

		if head == nil, tail == nil {
			let message = "drag either frame to trim"
			(message as NSString).draw(
				at: NSPoint(x: bounds.midX - 60, y: bounds.midY),
				withAttributes: [.font: Theme.monoSmall, .foregroundColor: Theme.faintText])
		}
	}

	// MARK: - Dragging

	public override func resetCursorRects() {
		super.resetCursorRects()
		addCursorRect(frames.head, cursor: .resizeLeftRight)
		addCursorRect(frames.tail, cursor: .resizeLeftRight)
	}

	public override func mouseDown(with event: NSEvent) {
		let place = convert(event.locationInWindow, from: nil)
		let frames = self.frames
		if frames.head.contains(place) {
			dragging = (.head, place.x, trim.head)
		} else if frames.tail.contains(place) {
			dragging = (.tail, place.x, trim.tail)
		}
		needsDisplay = true
	}

	public override func mouseDragged(with event: NSEvent) {
		guard let dragging else { return }
		let place = convert(event.locationInWindow, from: nil)
		// Right takes more off the head; left takes more off the tail. Both
		// directions are "into the clip", which is what the picture shows.
		let moved = Double(place.x - dragging.from) * rate
		let room = max(0, length - 0.05)
		switch dragging.side {
		case .head: trim.head = min(max(0, dragging.was + moved), room - trim.tail)
		case .tail: trim.tail = min(max(0, dragging.was - moved), room - trim.head)
		}
		onScrub?(trim.head, trim.tail)
	}

	public override func mouseUp(with event: NSEvent) {
		guard dragging != nil else { return }
		dragging = nil
		needsDisplay = true
		onTrim?(trim.head, trim.tail)
	}
}
