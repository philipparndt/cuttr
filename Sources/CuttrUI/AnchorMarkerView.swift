import AppKit
import CuttrKit

/// Draws where the anchors currently are, over the preview.
///
/// A tracked point is a claim — "this is her left eye, all the way through" —
/// and a claim you cannot see is one you have to take on trust until the export
/// proves it wrong. The ring follows the solved path as the programme plays, so
/// a tracker that wandered onto a lamp is obvious in the second it happens
/// rather than after a render.
///
/// Preview only. Nothing in here is in the Core Animation tree the renderer
/// uses, which is the point: it is scaffolding, not part of the picture.
@MainActor
public final class AnchorMarkerView: NSView {

	/// What to draw: a name and the path it follows, on whatever clock this
	/// view's `playhead` is on. Both windows have anchors and both have a
	/// playhead; neither needs to know about the other's model.
	public var markers: [(name: String, path: AnchorPath)] = [] { didSet { needsDisplay = true } }
	public var playhead: Double = 0 { didSet { needsDisplay = true } }
	/// The video's pixel dimensions, from which the picture's rectangle inside
	/// this view is worked out at draw time.
	///
	/// The rectangle used to be handed in and cached, and it went stale the
	/// moment the window was resized without the playhead moving — the rings
	/// stayed where the picture used to be, a constant offset from the faces
	/// they were marking. A derived value should be derived where it is used.
	public var videoSize: CGSize = .zero { didSet { needsDisplay = true } }

	/// Where the picture actually is: the video is aspect-fitted into this
	/// view, so most of the time there are bars at the sides or the top.
	public var picture: NSRect {
		guard videoSize.width > 0, videoSize.height > 0 else { return .zero }
		let scale = min(bounds.width / videoSize.width, bounds.height / videoSize.height)
		let size = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
		return NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
		              width: size.width, height: size.height)
	}
	/// Set while a click is waiting to become an anchor.
	public var pending: NSPoint? { didSet { needsDisplay = true } }

	public override init(frame: NSRect) {
		super.init(frame: frame)
		wantsLayer = true
		layer?.backgroundColor = .clear
	}

	@available(*, unavailable) required init?(coder: NSCoder) { nil }

	/// Clicks pass through to the player underneath; this view is only ever
	/// looked at.
	public override func hitTest(_ point: NSPoint) -> NSView? { nil }

	public override func setFrameSize(_ newSize: NSSize) {
		super.setFrameSize(newSize)
		needsDisplay = true
	}

	public override func draw(_ dirtyRect: NSRect) {
		let picture = self.picture
		guard picture.width > 0 else { return }

		// A colour each, so two tracked faces in one shot can be told apart at
		// a glance — which is the whole reason more than one is allowed.
		for (index, marker) in markers.enumerated() {
			// Only where the path actually has something to say. Outside the
			// clip it was solved over there is no answer, and a ring sitting
			// still at the first sample reads as a tracker that has come off.
			guard marker.path.covers(playhead), let point = marker.path.point(at: playhead)
			else { continue }
			let palette: [ClipColor] = [.teal, .rose, .violet, .amber, .blue, .green]
			draw(marker.name, at: point, colour: Theme.base(palette[index % palette.count]))
		}

		if let pending {
			_ = picture
			// Where the click landed, before Vision has been asked. Drawn at
			// once so the gesture has an answer even while solving.
			Theme.playhead.setStroke()
			let ring = NSBezierPath(ovalIn: NSRect(x: pending.x - 9, y: pending.y - 9, width: 18, height: 18))
			ring.lineWidth = 2
			ring.stroke()
		}
	}

	private func draw(_ name: String, at normalised: CGPoint, colour: NSColor) {
		let picture = self.picture
		let point = NSPoint(x: picture.minX + normalised.x * picture.width,
		                    y: picture.minY + normalised.y * picture.height)
		// A ring rather than a dot, so what is being pointed at stays visible
		// through it.
		colour.setStroke()
		let ring = NSBezierPath(ovalIn: NSRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16))
		ring.lineWidth = 2
		ring.stroke()
		let cross = NSBezierPath()
		cross.move(to: NSPoint(x: point.x - 3, y: point.y))
		cross.line(to: NSPoint(x: point.x + 3, y: point.y))
		cross.move(to: NSPoint(x: point.x, y: point.y - 3))
		cross.line(to: NSPoint(x: point.x, y: point.y + 3))
		cross.lineWidth = 1
		cross.stroke()

		let attributes: [NSAttributedString.Key: Any] = [
			.font: Theme.monoSmall,
			.foregroundColor: colour,
		]
		let size = (name as NSString).size(withAttributes: attributes)
		// A plate behind it: the picture underneath is whatever it is, and a
		// label that vanishes against a bright shirt is not a label.
		let plate = NSRect(x: point.x + 12, y: point.y - size.height / 2 - 1,
		                   width: size.width + 6, height: size.height + 2)
		NSColor(calibratedWhite: 0, alpha: 0.55).setFill()
		NSBezierPath(roundedRect: plate, xRadius: 3, yRadius: 3).fill()
		(name as NSString).draw(at: NSPoint(x: plate.minX + 3, y: plate.minY + 1), withAttributes: attributes)
	}
}
