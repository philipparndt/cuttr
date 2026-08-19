import AppKit
import CuttrCompose
import CuttrKit

/// The scene's own clock: a lane per part, a mark per key, and the playhead.
///
/// The programme strip shows a project on the programme's clock; this is the
/// same idea one level down. A scene has no length in the file — it plays for
/// as long as the overlay using it — so the length here comes from the editing
/// session, and the ruler says so by being labelled in seconds from the scene's
/// own start rather than from anything in the programme.
@MainActor
public final class SceneScrubber: NSView {

	public var scene = Scene() { didSet { needsDisplay = true } }
	public var length: Double = 4 { didSet { needsDisplay = true } }
	public var playhead: Double = 0 { didSet { needsDisplay = true } }
	public var selectedPart: Int? { didSet { needsDisplay = true } }
	public var selectedKey: Int? { didSet { needsDisplay = true } }

	public var onScrub: ((Double) -> Void)?
	public var onSelectPart: ((Int) -> Void)?
	public var onSelectKey: ((Int) -> Void)?
	/// A key was dragged along its lane: live, then once more on the way up.
	public var onMoveKey: ((Int, Int, Double, Bool) -> Void)?
	/// Somebody double-clicked an empty stretch of a lane.
	public var onAddKey: ((Int, Double) -> Void)?

	private let rulerHeight: CGFloat = 16
	private let laneHeight: CGFloat = 20
	private let markSize: CGFloat = 9

	private var dragging: (part: Int, key: Int)?

	public override var isFlipped: Bool { true }

	public override init(frame: NSRect) {
		super.init(frame: frame)
		wantsLayer = true
		layer?.backgroundColor = Theme.background.cgColor
	}

	@available(*, unavailable) required init?(coder: NSCoder) { nil }

	public override var intrinsicContentSize: NSSize {
		NSSize(width: NSView.noIntrinsicMetric,
		       height: rulerHeight + laneHeight * CGFloat(max(scene.parts.count, 1)) + 6)
	}

	private var span: Double { max(length, 0.2) }
	private func x(_ time: Double) -> CGFloat {
		8 + CGFloat(time / span) * max(bounds.width - 16, 1)
	}

	private func time(_ x: CGFloat) -> Double {
		min(max(0, Double((x - 8) / max(bounds.width - 16, 1)) * span), span)
	}

	private func lane(_ part: Int) -> CGFloat { rulerHeight + CGFloat(part) * laneHeight }

	// MARK: - Drawing

	public override func draw(_ dirtyRect: NSRect) {
		Theme.background.setFill()
		dirtyRect.fill()

		Theme.panel.setFill()
		NSRect(x: 0, y: 0, width: bounds.width, height: rulerHeight).fill()
		let step = tickStep()
		var t = 0.0
		while t <= span + 1e-9 {
			let at = x(t).rounded() + 0.5
			Theme.rule.setStroke()
			let tick = NSBezierPath()
			tick.move(to: NSPoint(x: at, y: rulerHeight - 4))
			tick.line(to: NSPoint(x: at, y: rulerHeight))
			tick.stroke()
			(String(format: "%.1fs", t) as NSString).draw(
				at: NSPoint(x: at + 3, y: 2),
				withAttributes: [.font: Theme.monoSmall, .foregroundColor: Theme.dimText])
			t += step
		}

		for (index, part) in scene.parts.enumerated() {
			let top = lane(index)
			let row = NSRect(x: 0, y: top, width: bounds.width, height: laneHeight - 1)
			if index == selectedPart {
				Theme.cardHigh.setFill()
				row.fill()
			}
			Theme.rule.withAlphaComponent(0.5).setStroke()
			let line = NSBezierPath()
			line.move(to: NSPoint(x: 8, y: top + laneHeight / 2))
			line.line(to: NSPoint(x: bounds.width - 8, y: top + laneHeight / 2))
			line.stroke()

			// The stretch a part is doing something over, so a lane reads as a
			// range and not only as two dots.
			if let first = part.keys.map(\.t).min(), let last = part.keys.map(\.t).max(),
			   last > first {
				colour(of: part).withAlphaComponent(0.25).setFill()
				NSRect(x: x(first), y: top + laneHeight / 2 - 2,
				       width: x(last) - x(first), height: 4).fill()
			}

			for (number, key) in part.keys.enumerated() {
				let at = NSPoint(x: x(key.t), y: top + laneHeight / 2)
				let mark = NSBezierPath()
				mark.move(to: NSPoint(x: at.x, y: at.y - markSize / 2))
				mark.line(to: NSPoint(x: at.x + markSize / 2, y: at.y))
				mark.line(to: NSPoint(x: at.x, y: at.y + markSize / 2))
				mark.line(to: NSPoint(x: at.x - markSize / 2, y: at.y))
				mark.close()
				let chosen = index == selectedPart && number == selectedKey
				colour(of: part).withAlphaComponent(chosen ? 1 : 0.6).setFill()
				mark.fill()
				if chosen {
					NSColor.white.setStroke()
					mark.lineWidth = 1
					mark.stroke()
				}
			}
		}

		let at = x(playhead).rounded() + 0.5
		Theme.playhead.setStroke()
		let line = NSBezierPath()
		line.move(to: NSPoint(x: at, y: 0))
		line.line(to: NSPoint(x: at, y: bounds.height))
		line.stroke()
	}

	private func colour(of part: Scene.Part) -> NSColor {
		switch part.content {
		case .text: return Theme.color(.text)
		case .shape: return Theme.base(.teal)
		case .image: return Theme.base(.violet)
		case .background: return Theme.base(.blue)
		}
	}

	private func tickStep() -> Double {
		let target = span * Double(70 / max(bounds.width, 1))
		return [0.1, 0.25, 0.5, 1, 2, 5, 10, 30, 60].first { $0 >= target } ?? 60
	}

	// MARK: - Pointing at it

	public override func mouseDown(with event: NSEvent) {
		let point = convert(event.locationInWindow, from: nil)
		guard point.y > rulerHeight else {
			onScrub?(time(point.x))
			return
		}
		let index = Int((point.y - rulerHeight) / laneHeight)
		guard index >= 0, index < scene.parts.count else {
			onScrub?(time(point.x))
			return
		}
		onSelectPart?(index)

		let at = time(point.x)
		let keys = scene.parts[index].keys
		if let key = keys.indices.min(by: {
			abs(x(keys[$0].t) - point.x) < abs(x(keys[$1].t) - point.x)
		}), abs(x(keys[key].t) - point.x) <= markSize {
			onSelectKey?(key)
			dragging = (index, key)
			return
		}
		if event.clickCount == 2 {
			onAddKey?(index, at)
			return
		}
		onScrub?(at)
	}

	public override func mouseDragged(with event: NSEvent) {
		let at = time(convert(event.locationInWindow, from: nil).x)
		guard let dragging else {
			onScrub?(at)
			return
		}
		onMoveKey?(dragging.part, dragging.key, at, false)
	}

	public override func mouseUp(with event: NSEvent) {
		guard let dragging else { return }
		let at = time(convert(event.locationInWindow, from: nil).x)
		onMoveKey?(dragging.part, dragging.key, at, true)
		self.dragging = nil
	}
}
