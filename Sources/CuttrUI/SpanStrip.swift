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
	/// The stretch of the programme this strip is about, which is not always all
	/// of it.
	///
	/// An overlay written inside a timeline entry can only be on while that
	/// entry is playing, so a strip offering the whole programme offers times
	/// that cannot mean anything — and makes the seconds that *can* mean
	/// something a thumbnail at one end of it. Left `nil`, it is the whole
	/// programme, which is what a top-level overlay is about.
	public var showing: (start: Double, end: Double)? {
		didSet { needsDisplay = true }
	}

	/// What the strip is showing, resolved: the window if there is one, and the
	/// whole programme if there is not.
	private var shown: (start: Double, end: Double) {
		guard let showing, showing.end > showing.start else { return (0, duration) }
		return (max(0, showing.start), min(duration, showing.end))
	}
	public var blocks: [Block] = [] { didSet { needsDisplay = true } }
	public var ranges: [Range] = [] { didSet { needsDisplay = true } }
	public var selected = 0 { didSet { needsDisplay = true } }

	public var onSelect: ((Int) -> Void)?
	/// The selected range, deleted — the key everybody reaches for.
	public var onDelete: ((Int) -> Void)?
	/// Where the pointer is while a range is being placed, so the picture above
	/// can show that moment. Placing a caption against footage nobody can see
	/// is guesswork with extra steps.
	public var onScrub: ((Double) -> Void)?
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
		NSSize(width: NSView.noIntrinsicMetric, height: 68)
	}

	// MARK: - Geometry

	private var track: NSRect { bounds.insetBy(dx: 8, dy: 0) }

	private func x(_ time: Double) -> CGFloat {
		let shown = shown
		let span = shown.end - shown.start
		guard span > 0 else { return track.minX }
		return track.minX + CGFloat((time - shown.start) / span) * track.width
	}

	private func time(_ x: CGFloat) -> Double {
		let shown = shown
		let span = shown.end - shown.start
		guard span > 0, track.width > 0 else { return shown.start }
		let at = shown.start + Double((x - track.minX) / track.width) * span
		return min(shown.end, max(shown.start, at))
	}

	/// For the tests: what time a fraction of the way along the track means.
	func timeForTesting(atFraction fraction: CGFloat) -> Double {
		time(track.minX + fraction * track.width)
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
		// against them. Three bands, stacked and not touching: the clock along the bottom, the
		// programme's clips above it, the overlay's ranges over those.
		let clipRow = NSRect(x: track.minX, y: 16, width: track.width, height: 18)
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
			let box = NSRect(x: x(range.start), y: 40,
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
		// The times at the ends are the ends of what is *shown*, which for an
		// overlay inside an entry is that entry and not the programme.
		let shown = shown
		(Timecode.string(shown.start) as NSString)
			.draw(at: NSPoint(x: track.minX, y: 2), withAttributes: attributes)
		let end = Timecode.string(shown.end) as NSString
		end.draw(at: NSPoint(x: track.maxX - end.size(withAttributes: attributes).width, y: 2),
		         withAttributes: attributes)
	}

	// MARK: - Dragging

	/// Grabbing the picture takes the focus off whatever field had it.
	///
	/// Which matters for more than the ring: a field being typed into stops the
	/// panel reloading — otherwise the file would come back mid-word and take
	/// the cursor with it — so a drag that left the focus where it was wrote a
	/// new value into a form that had been told not to look.
	public override var acceptsFirstResponder: Bool { true }

	public override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
	public override func resignFirstResponder() -> Bool { needsDisplay = true; return true }

	public override func keyDown(with event: NSEvent) {
		// 51 is delete, 117 is forward delete.
		guard event.keyCode == 51 || event.keyCode == 117,
		      ranges.indices.contains(selected) else {
			super.keyDown(with: event)
			return
		}
		onDelete?(selected)
	}

	public override func mouseDown(with event: NSEvent) {
		window?.makeFirstResponder(self)
		let place = convert(event.locationInWindow, from: nil)
		onScrub?(time(place.x))
		guard let index = ranges.indices.reversed().first(where: { index in
			let box = NSRect(x: x(ranges[index].start) - 4, y: 38,
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
		// The frame under the end being moved, not under the pointer's own
		// position: an edge is being placed *at* a moment.
		onScrub?(at)
	}

	public override func mouseUp(with event: NSEvent) {
		guard let dragging else { return }
		self.dragging = nil
		let range = ranges[dragging.index]
		onDrag?(dragging.index, range.start, range.end)
	}
}
