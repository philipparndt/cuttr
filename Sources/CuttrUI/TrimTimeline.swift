import AppKit
import CuttrKit

/// The whole of a placement's clip, with the kept part lit and the trimmed ends
/// dark, and the playhead on it.
///
/// The same shape as the timeline in the cutting window, because it answers the
/// same question — where in this shot am I, and where do the marks go — and
/// somebody who has learnt one should not have to learn the other. Drawn rather
/// than assembled: three rectangles, two handles and a line.
///
/// Times here are seconds from the untrimmed head of the placement. What the
/// take's clock calls that moment is the dialog's business, not this view's.
@MainActor
public final class TrimTimeline: NSView {

	/// The whole placement before anything is taken off.
	public var length: Double = 1 { didSet { needsDisplay = true } }
	public var trim: (head: Double, tail: Double) = (0, 0) { didSet { needsDisplay = true } }
	public var playhead: Double = 0 { didSet { needsDisplay = true } }

	/// A handle moved: live during the drag, and once more with `commit` when
	/// it is let go.
	public var onTrim: ((_ head: Double, _ tail: Double, _ commit: Bool) -> Void)?
	/// Somebody pointed at a moment.
	public var onScrub: ((Double) -> Void)?

	private enum Grab { case head, tail, playhead }
	private var dragging: Grab?
	/// How close to a handle counts as grabbing it.
	private let slop: CGFloat = 6
	private let rulerHeight: CGFloat = 16

	public override init(frame: NSRect) {
		super.init(frame: frame)
		wantsLayer = true
		layer?.backgroundColor = Theme.background.cgColor
		layer?.cornerRadius = 4
	}

	@available(*, unavailable) required init?(coder: NSCoder) { nil }

	public override var intrinsicContentSize: NSSize {
		NSSize(width: NSView.noIntrinsicMetric, height: 56)
	}

	// MARK: - Where things are

	private var band: NSRect {
		NSRect(x: 8, y: rulerHeight + 4, width: max(1, bounds.width - 16),
		       height: max(1, bounds.height - rulerHeight - 12))
	}

	private func x(_ time: Double) -> CGFloat {
		let band = self.band
		return band.minX + band.width * CGFloat(min(max(0, time / max(length, 0.001)), 1))
	}

	private func time(_ x: CGFloat) -> Double {
		let band = self.band
		return min(max(0, Double((x - band.minX) / band.width) * length), length)
	}

	public override func draw(_ dirtyRect: NSRect) {
		let band = self.band
		let keptFrom = x(trim.head), keptTo = x(length - trim.tail)

		// Everything, dark.
		NSColor(calibratedWhite: 0.16, alpha: 1).setFill()
		NSBezierPath(roundedRect: band, xRadius: 3, yRadius: 3).fill()

		// What is kept, lit.
		let kept = NSRect(x: keptFrom, y: band.minY, width: max(1, keptTo - keptFrom),
		                  height: band.height)
		Theme.clipFill(.green, selected: true).setFill()
		NSBezierPath(roundedRect: kept, xRadius: 3, yRadius: 3).fill()
		Theme.clipStroke(.green).setStroke()
		NSBezierPath(roundedRect: kept.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3).stroke()

		// The two handles, which is what a trim is.
		Theme.accent.setFill()
		for edge in [keptFrom, keptTo - 3] {
			NSRect(x: edge, y: band.minY, width: 3, height: band.height).fill()
		}

		// The playhead, over everything.
		Theme.playhead.setFill()
		NSRect(x: x(playhead) - 0.5, y: band.minY - 3, width: 1, height: band.height + 6).fill()

		// The clock underneath: where the kept part starts and ends, and where
		// the playhead is, all on the placement's own clock.
		let marks: [(CGFloat, String, NSColor)] = [
			(band.minX, Timecode.string(0), Theme.faintText),
			(x(playhead), Timecode.string(playhead), Theme.playhead),
			(band.maxX - 52, Timecode.string(length), Theme.faintText),
		]
		for (at, text, colour) in marks {
			(text as NSString).draw(
				at: NSPoint(x: min(max(band.minX, at - 26), band.maxX - 52), y: 1),
				withAttributes: [.font: Theme.monoSmall, .foregroundColor: colour])
		}
	}

	// MARK: - Dragging

	public override func resetCursorRects() {
		super.resetCursorRects()
		let band = self.band
		for edge in [x(trim.head), x(length - trim.tail)] {
			addCursorRect(NSRect(x: edge - slop, y: band.minY, width: slop * 2, height: band.height),
			              cursor: .resizeLeftRight)
		}
	}

	public override func mouseDown(with event: NSEvent) {
		let place = convert(event.locationInWindow, from: nil)
		let head = x(trim.head), tail = x(length - trim.tail)
		if abs(place.x - head) <= slop { dragging = .head }
		else if abs(place.x - tail) <= slop { dragging = .tail }
		else {
			dragging = .playhead
			playhead = time(place.x)
			onScrub?(playhead)
		}
	}

	public override func mouseDragged(with event: NSEvent) {
		let at = time(convert(event.locationInWindow, from: nil).x)
		switch dragging {
		case .head:
			// The playhead follows the handle, because what somebody is looking
			// for is the frame this end lands on.
			trim.head = min(at, length - trim.tail - 0.05)
			playhead = trim.head
			onTrim?(trim.head, trim.tail, false)
			onScrub?(playhead)
		case .tail:
			trim.tail = min(length - at, length - trim.head - 0.05)
			playhead = max(0, length - trim.tail)
			onTrim?(trim.head, trim.tail, false)
			onScrub?(playhead)
		case .playhead:
			playhead = at
			onScrub?(at)
		case nil:
			break
		}
	}

	public override func mouseUp(with event: NSEvent) {
		if dragging == .head || dragging == .tail {
			onTrim?(trim.head, trim.tail, true)
		}
		dragging = nil
		window?.invalidateCursorRects(for: self)
	}
}
