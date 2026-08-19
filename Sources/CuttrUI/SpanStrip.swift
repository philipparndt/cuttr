import AppKit
import CuttrCompose
import CuttrKit

/// When an overlay is on, against the programme it is on over.
///
/// The same argument as the frame preview, for the other half of an overlay:
/// `from: intro to: demo-install` is a fact nobody can picture either. Here the
/// programme is drawn end to end with its clips in it, the overlay's ranges lie
/// over the top, and they are dragged and stretched.
///
/// A range bound to clips **snaps to them**. Dragging does not quietly turn a
/// caption that belongs to `intro` into one that begins at 4.28 seconds — it
/// picks the clip under the pointer and writes that name instead. Bound to
/// times, it moves in seconds, because that is what it asked for. A range hung
/// on a whole section is not dragged at all: the section is on the programme,
/// and that is where its length is decided.
@MainActor
public final class SpanStrip: NSView {

	/// One clip of the programme, as somewhere to drop.
	public struct Block: Sendable {
		public let start: Double
		public let end: Double
		public let name: String

		public init(start: Double, end: Double, name: String) {
			self.start = start
			self.end = end
			self.name = name
		}
	}

	/// One range of the overlay.
	public struct Range: Sendable {
		public var start: Double
		public var end: Double
		/// Ranges hung on a section move when the section does, not when
		/// somebody drags them.
		public var movable: Bool

		public init(start: Double, end: Double, movable: Bool) {
			self.start = start
			self.end = end
			self.movable = movable
		}
	}

	public var duration: Double = 0 { didSet { needsDisplay = true } }
	public var blocks: [Block] = [] { didSet { needsDisplay = true } }
	public var ranges: [Range] = [] { didSet { needsDisplay = true } }
	public var selected = 0 { didSet { needsDisplay = true } }

	public var onSelect: ((Int) -> Void)?
	/// Where a range was let go, in seconds. Written once, at the end of the
	/// drag.
	public var onDrag: ((Int, Double, Double) -> Void)?

	private enum Grip { case body(Double), start, end }
	private var dragging: (index: Int, grip: Grip)?

	public override init(frame: NSRect) {
		super.init(frame: frame)
		wantsLayer = true
		layer?.backgroundColor = Theme.background.cgColor
		layer?.cornerRadius = 4
	}

	@available(*, unavailable) required init?(coder: NSCoder) { nil }

	public override var intrinsicContentSize: NSSize {
		NSSize(width: NSView.noIntrinsicMetric, height: 62)
	}

	// MARK: - Geometry

	private var track: NSRect { bounds.insetBy(dx: 8, dy: 0) }

	private func x(_ time: Double) -> CGFloat {
		guard duration > 0 else { return track.minX }
		return track.minX + CGFloat(time / duration) * track.width
	}

	private func time(_ x: CGFloat) -> Double {
		guard duration > 0, track.width > 0 else { return 0 }
		return min(duration, max(0, Double((x - track.minX) / track.width) * duration))
	}

	// MARK: - Drawing

	public override func draw(_ dirtyRect: NSRect) {
		guard duration > 0 else {
			("nothing on the programme yet" as NSString).draw(
				at: NSPoint(x: 10, y: bounds.midY - 6),
				withAttributes: [.font: Theme.monoSmall, .foregroundColor: Theme.faintText])
			return
		}

		// The programme underneath: the clips, in order, so a range can be read
		// against them.
		let clipRow = NSRect(x: track.minX, y: 8, width: track.width, height: 16)
		for (index, block) in blocks.enumerated() {
			let box = NSRect(x: x(block.start), y: clipRow.minY,
			                 width: max(1, x(block.end) - x(block.start)), height: clipRow.height)
			NSColor(calibratedWhite: index.isMultiple(of: 2) ? 0.24 : 0.20, alpha: 1).setFill()
			box.insetBy(dx: 0.5, dy: 0).fill()
			let attributes: [NSAttributedString.Key: Any] = [
				.font: Theme.monoSmall, .foregroundColor: Theme.dimText,
			]
			let size = (block.name as NSString).size(withAttributes: attributes)
			if size.width < box.width - 6 {
				(block.name as NSString).draw(
					at: NSPoint(x: box.midX - size.width / 2, y: box.minY + 2),
					withAttributes: attributes)
			}
		}

		// The ranges over it.
		for (index, range) in ranges.enumerated() {
			let box = NSRect(x: x(range.start), y: 30,
			                 width: max(3, x(range.end) - x(range.start)), height: 22)
			let colour = range.movable ? Theme.accent : Theme.color(.section)
			colour.withAlphaComponent(index == selected ? 0.85 : 0.4).setFill()
			NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3).fill()
			if index == selected {
				NSColor.white.withAlphaComponent(0.75).setStroke()
				let handles = NSBezierPath()
				for edge in [box.minX + 3, box.maxX - 3] {
					handles.move(to: NSPoint(x: edge, y: box.minY + 5))
					handles.line(to: NSPoint(x: edge, y: box.maxY - 5))
				}
				handles.lineWidth = 1.5
				handles.stroke()
			}
			let label = "\(index + 1)"
			(label as NSString).draw(
				at: NSPoint(x: box.minX + 6, y: box.minY + 5),
				withAttributes: [.font: Theme.monoSmall, .foregroundColor: NSColor.black])
		}

		// The clock, at both ends, so the strip says how long it is.
		let attributes: [NSAttributedString.Key: Any] = [
			.font: Theme.monoSmall, .foregroundColor: Theme.faintText,
		]
		("0:00" as NSString).draw(at: NSPoint(x: track.minX, y: 0), withAttributes: attributes)
		let end = Timecode.string(duration) as NSString
		end.draw(at: NSPoint(x: track.maxX - end.size(withAttributes: attributes).width, y: 0),
		         withAttributes: attributes)
	}

	// MARK: - Dragging

	public override func mouseDown(with event: NSEvent) {
		let place = convert(event.locationInWindow, from: nil)
		guard let index = ranges.indices.reversed().first(where: { index in
			let box = NSRect(x: x(ranges[index].start) - 4, y: 28,
			                 width: max(3, x(ranges[index].end) - x(ranges[index].start)) + 8, height: 26)
			return box.contains(place)
		}) else { return }

		if selected != index {
			selected = index
			onSelect?(index)
		}
		guard ranges[index].movable else { return }

		let left = x(ranges[index].start), right = x(ranges[index].end)
		if abs(place.x - left) < 6 {
			dragging = (index, .start)
		} else if abs(place.x - right) < 6 {
			dragging = (index, .end)
		} else {
			dragging = (index, .body(time(place.x) - ranges[index].start))
		}
	}

	public override func mouseDragged(with event: NSEvent) {
		guard let dragging else { return }
		let at = time(convert(event.locationInWindow, from: nil).x)
		var range = ranges[dragging.index]
		switch dragging.grip {
		case .start: range.start = min(at, range.end - 0.05)
		case .end: range.end = max(at, range.start + 0.05)
		case .body(let grab):
			let length = range.end - range.start
			range.start = min(max(0, at - grab), duration - length)
			range.end = range.start + length
		}
		ranges[dragging.index] = range
	}

	public override func mouseUp(with event: NSEvent) {
		guard let dragging else { return }
		self.dragging = nil
		let range = ranges[dragging.index]
		onDrag?(dragging.index, range.start, range.end)
	}
}
