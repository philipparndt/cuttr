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
///
/// It **zooms**, because on an hour of programme a pixel is worth seconds and
/// nothing can be placed in one. ⌥- or ⌘-scroll and a pinch zoom about the
/// pointer, `+` and `−` about the selected range, `z` frames it and `f` puts
/// the whole thing back — the same gestures and the same letters as the
/// timeline in the cutting window, so neither has to be learnt twice. A plain
/// scroll is passed on untouched: this strip lives in a form that scrolls, and
/// a view that swallows the wheel is a trap.
///
/// Zooming changes what is shown and nothing that is written. Every number in
/// the file is the same afterwards; ``showing`` stays the bounds, and no zoom
/// can point at a second the overlay could not have been on anyway.
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

	/// Which end of a range a key is about. `i` and `o` mean in and out
	/// everywhere else in this program, and they mean it here.
	public enum Edge: Sendable { case start, end }

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

	/// The bounds a zoom cannot escape: the window if there is one, and the
	/// whole programme if there is not.
	private var limits: (start: Double, end: Double) {
		guard let showing, showing.end > showing.start else { return (0, duration) }
		return (max(0, showing.start), min(duration, showing.end))
	}

	/// Which part of ``limits`` is being looked at, or `nil` for all of it.
	///
	/// Public because the form this strip sits in is thrown away and built
	/// again after every edit, so a zoom held only here would last until the
	/// next letter typed into a field. It is a fact about the session and not
	/// about the take — like which range is selected, and unlike either of the
	/// two numbers a range is made of.
	public var zoomed: (start: Double, end: Double)? {
		didSet { needsDisplay = true }
	}

	/// Somebody zoomed or panned, so whoever rebuilds this strip can put it
	/// back where they left it.
	public var onZoom: (((start: Double, end: Double)?) -> Void)?

	/// The least the strip will show.
	///
	/// A quarter of a second across a panel's width is a millisecond or two to
	/// the pixel, which is finer than anything in this program is placed to.
	/// Past that the two clocks at the ends stop differing and the strip has
	/// stopped being a picture of anything.
	private static let leastShown = TimeWindow.leastShown

	/// What the strip is showing, resolved: the zoom, held inside the bounds.
	///
	/// Clamped on the way out rather than on the way in, so a zoom that
	/// outlived a rebuild — or a change of which clip the strip is about —
	/// keeps its magnification and slides inside the new bounds rather than
	/// being thrown away or pointing outside them.
	/// What the strip is showing, resolved — see ``TimeWindow/shown``, which is
	/// where this arithmetic lives now that two strips do it.
	private var shown: (start: Double, end: Double) { viewed.shown }

	/// Not `window` — `NSView` has one of those, and the two have collided in
	/// this class before.
	private var viewed: TimeWindow {
		get { TimeWindow(limits: limits, zoomed: zoomed) }
		set { zoomed = newValue.zoomed }
	}
	public var blocks: [Block] = [] { didSet { needsDisplay = true } }
	public var ranges: [Range] = [] { didSet { needsDisplay = true } }
	public var selected = 0 { didSet { needsDisplay = true } }

	/// Why the last key press did nothing, while it is still worth saying.
	///
	/// A key that quietly does nothing is indistinguishable from a key that was
	/// never wired up, and the two things `i` and `o` cannot do here — a range
	/// hung on a section, an in on top of its own out — are both worth a
	/// sentence. Said on the strip because the strip is what has the keyboard;
	/// cleared by the next thing anybody does.
	private var notice: String? { didSet { needsDisplay = true } }

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
	/// `i` and `o`: one end of the selected range, set from the playhead.
	///
	/// The strip has no clock of its own and no business writing to the file,
	/// so it says which range and which end and lets the panel — which has the
	/// playhead, and the one door every written range goes through — do it.
	/// Answers with why not, when it cannot be done.
	public var onSetEdge: ((Int, Edge) -> String?)?

	private enum Grip { case body(Double), start, end }
	private var dragging: (index: Int, grip: Grip)?

	public override init(frame: NSRect) {
		super.init(frame: frame)
		wantsLayer = true
		layer?.backgroundColor = Theme.background.cgColor
		layer?.cornerRadius = 4
		addGestureRecognizer(
			NSMagnificationGestureRecognizer(target: self, action: #selector(pinched)))
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

	/// For the tests: the stretch on screen, which is what the clocks at the
	/// ends are drawn from.
	var shownForTesting: (start: Double, end: Double) { shown }

	/// For the tests: what the strip last refused to do, and why.
	var noticeForTesting: String? { notice }

	// MARK: - Zoom

	/// Zooms about a point, keeping the moment under it where it is.
	///
	/// A factor below one shows less. The moment under the pointer staying put
	/// is the whole of the interaction: zooming in on a strip that keeps its
	/// centre instead walks the thing being aimed at off the edge in two turns
	/// of the wheel.
	public func zoom(by factor: Double, aboutFraction fraction: CGFloat) {
		var viewed = viewed
		viewed.zoom(by: factor, aboutFraction: fraction)
		self.viewed = viewed
		onZoom?(zoomed)
	}

	/// The whole of what this strip is about, again.
	public func fit() {
		zoomed = nil
		onZoom?(nil)
	}

	/// Frames one stretch, with a margin — "show me this range".
	public func reveal(from start: Double, to end: Double) {
		var viewed = viewed
		viewed.reveal(from: start, to: end)
		self.viewed = viewed
		onZoom?(zoomed)
	}

	/// Slides what is shown along, in points of the track. Does nothing while
	/// the whole of it is on screen, so the gesture falls through to the form
	/// rather than being eaten by a strip that has nowhere to go.
	public func pan(byPoints points: CGFloat) {
		var viewed = viewed
		viewed.pan(byPoints: points, trackWidth: track.width)
		self.viewed = viewed
		onZoom?(zoomed)
	}

	/// Where the selected range is on the track, for a zoom that came from the
	/// keyboard.
	///
	/// The middle of the view is the wrong anchor for a key press: the range
	/// being worked on is what somebody is zooming *at*, and it is the
	/// keyboard's pointer. Falls back to the middle when that range is not on
	/// screen, since anchoring on something invisible jumps the strip somewhere
	/// nobody asked to be.
	private var fractionOfSelection: CGFloat {
		guard ranges.indices.contains(selected) else { return 0.5 }
		let shown = shown
		let span = shown.end - shown.start
		guard span > 0 else { return 0.5 }
		let middle = (ranges[selected].start + ranges[selected].end) / 2
		let fraction = CGFloat((middle - shown.start) / span)
		return (fraction >= 0 && fraction <= 1) ? fraction : 0.5
	}

	public override func scrollWheel(with event: NSEvent) {
		// ⌘ and ⌥ both zoom, as they both do on the cutting window's timeline:
		// editors disagree about which one it is and neither has anything else
		// to do here.
		if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
			let place = convert(event.locationInWindow, from: nil)
			let fraction = track.width > 0 ? (place.x - track.minX) / track.width : 0.5
			zoom(by: event.scrollingDeltaY > 0 ? 0.9 : 1.1, aboutFraction: fraction)
			return
		}
		// A sideways swipe pans, because there is one axis here and nothing
		// else wants that delta. Everything else — a wheel, two fingers up the
		// panel — is somebody scrolling the form this strip is in, and goes on
		// to it untouched.
		guard zoomed != nil, abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else {
			super.scrollWheel(with: event)
			return
		}
		pan(byPoints: -event.scrollingDeltaX)
	}

	@objc private func pinched(_ gesture: NSMagnificationGestureRecognizer) {
		let place = gesture.location(in: self)
		let fraction = track.width > 0 ? (place.x - track.minX) / track.width : 0.5
		zoom(by: 1 - gesture.magnification, aboutFraction: fraction)
		gesture.magnification = 0
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

		// What a key would not do, over the clips, where it cannot be missed.
		if let notice {
			let attributes: [NSAttributedString.Key: Any] = [
				.font: Theme.monoSmall, .foregroundColor: Theme.text,
			]
			let line = notice as NSString
			let size = line.size(withAttributes: attributes)
			let box = NSRect(x: max(track.minX, track.midX - size.width / 2 - 5), y: 15,
			                 width: min(track.width, size.width + 10), height: 20)
			Theme.card.withAlphaComponent(0.94).setFill()
			NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3).fill()
			line.draw(at: NSPoint(x: box.minX + 5, y: box.minY + 4), withAttributes: attributes)
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
		// ⌘ belongs to the menu, which has had its chance at this key already.
		guard !event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
		else { return super.keyDown(with: event) }

		// 51 is delete, 117 is forward delete.
		if event.keyCode == 51 || event.keyCode == 117 {
			guard ranges.indices.contains(selected) else { return super.keyDown(with: event) }
			onDelete?(selected)
			return
		}

		// The zoom keys by physical position first and by character second, the
		// way the cutting window does it: `charactersIgnoringModifiers` returns
		// what the layout produces, and on a German keyboard `=` is Shift+0 and
		// came back as "0". A key code is a place on a keyboard and is the same
		// place on every one.
		switch event.keyCode {
		case 24: zoom(by: 1 / 1.6, aboutFraction: fractionOfSelection); return   // = / +
		case 27: zoom(by: 1.6, aboutFraction: fractionOfSelection); return       // -
		default: break
		}

		switch event.charactersIgnoringModifiers?.lowercased() {
		case "i": setEdge(.start)
		case "o": setEdge(.end)
		case "f": fit()
		case "z":
			guard ranges.indices.contains(selected) else { return fit() }
			reveal(from: ranges[selected].start, to: ranges[selected].end)
		case "=", "+": zoom(by: 1 / 1.6, aboutFraction: fractionOfSelection)
		case "-", "_": zoom(by: 1.6, aboutFraction: fractionOfSelection)
		default: super.keyDown(with: event)
		}
	}

	/// `i` and `o`. What the strip can answer itself it answers itself: that
	/// there is no range, or that the range is hung on a section — and one hung
	/// on a section is no more typed into than it is dragged, because the
	/// section's length is decided on the programme.
	private func setEdge(_ edge: Edge) {
		guard ranges.indices.contains(selected) else {
			notice = "no range to put an in or an out on"
			return
		}
		guard ranges[selected].movable else {
			notice = "hung on a section — the programme decides when that is"
			return
		}
		notice = onSetEdge?(selected, edge)
	}

	public override func mouseDown(with event: NSEvent) {
		window?.makeFirstResponder(self)
		notice = nil
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
