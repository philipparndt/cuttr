import AppKit
import CuttrCompose
import CuttrKit

/// The finished programme as one bar: every clip, in order, at its real length.
///
/// Not the cutting window's timeline. There is no waveform and nothing to trim,
/// because a project does not own its clips — the takes do, and trimming here
/// would be editing a file this window is only reading. What it is for is
/// seeing the shape of the programme, seeing which take each part came from, and
/// getting the playhead to a particular clip.
@MainActor
public final class ProgrammeStrip: NSView {

	public var resolved: ResolvedProject? { didSet { needsDisplay = true } }
	/// What to say when there is nothing to draw.
	public var emptyMessage: String? { didSet { needsDisplay = true } }
	public var playhead: Double = 0 { didSet { needsDisplay = true } }
	public var onScrub: ((Double) -> Void)?
	public var onSelect: ((ResolvedClip) -> Void)?

	private let clipRowHeight: CGFloat = 34
	private let overlayRowHeight: CGFloat = 16
	private let groupRowHeight: CGFloat = 15
	private let rulerHeight: CGFloat = 16

	public override var isFlipped: Bool { true }
	public override var acceptsFirstResponder: Bool { true }

	public override init(frame: NSRect) {
		super.init(frame: frame)
		wantsLayer = true
		layer?.backgroundColor = Theme.background.cgColor
	}

	@available(*, unavailable) required init?(coder: NSCoder) { nil }

	private var duration: Double { max(resolved?.duration ?? 0, 0.001) }

	private func x(for time: Double) -> CGFloat { CGFloat(time / duration) * bounds.width }
	private func time(forX x: CGFloat) -> Double { Double(x / max(bounds.width, 1)) * duration }

	public override func draw(_ dirtyRect: NSRect) {
		Theme.background.setFill()
		dirtyRect.fill()
		guard let resolved else {
			// The empty-project case is not an error and should not read like
			// one: a project is made before it has anything in it.
			let message = emptyMessage ?? "Nothing to show — open a project, or check the error above."
			let attributes: [NSAttributedString.Key: Any] = [.font: Theme.label, .foregroundColor: Theme.dimText]
			let size = (message as NSString).size(withAttributes: attributes)
			(message as NSString).draw(
				at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
				withAttributes: attributes)
			return
		}

		drawRuler()

		// The sections, above the clips, one row per depth. This is the shape
		// of the programme — the thing an overlay is hung on — and seeing it is
		// most of why a project bothers with groups at all.
		let depths = (resolved.groups.map(\.depth).max() ?? -1) + 1
		for group in resolved.groups {
			let a = x(for: group.start), b = x(for: group.end)
			let y = rulerHeight + CGFloat(group.depth) * groupRowHeight
			let rect = NSRect(x: a, y: y + 1, width: max(b - a - 1, 2), height: groupRowHeight - 2)
			NSColor(calibratedWhite: 1, alpha: 0.07).setFill()
			rect.fill()
			Theme.rule.setStroke()
			NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()
			let label = "@" + group.name
			let attributes: [NSAttributedString.Key: Any] = [.font: Theme.monoSmall, .foregroundColor: Theme.dimText]
			if (label as NSString).size(withAttributes: attributes).width < rect.width - 6 {
				(label as NSString).draw(at: NSPoint(x: rect.minX + 3, y: rect.minY), withAttributes: attributes)
			}
		}
		let groupsHeight = CGFloat(depths) * groupRowHeight

		// The clips. Coloured by the clip's own colour, so the lane somebody cut
		// it on in the other window is still visible here — which is how you see
		// at a glance that the b-roll query picked up the right things.
		let top = rulerHeight + groupsHeight
		for clip in resolved.clips {
			let a = x(for: clip.start), b = x(for: clip.end)
			let rect = NSRect(x: a, y: top + 2, width: max(b - a - 1, 1), height: clipRowHeight - 4)
			Theme.clipFill(clip.clip.color, selected: false).setFill()
			rect.fill()
			Theme.clipStroke(clip.clip.color).setStroke()
			NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()

			// Slug on top, take underneath, and only what fits — a truncated
			// identifier is worse than none.
			let slug = clip.reference.slug
			let attributes: [NSAttributedString.Key: Any] = [.font: Theme.monoSmall, .foregroundColor: Theme.text]
			if (slug as NSString).size(withAttributes: attributes).width < rect.width - 8 {
				(slug as NSString).draw(at: NSPoint(x: rect.minX + 4, y: rect.minY + 3), withAttributes: attributes)
				let take = clip.takeName
				let dim: [NSAttributedString.Key: Any] = [.font: Theme.monoSmall, .foregroundColor: Theme.dimText]
				if (take as NSString).size(withAttributes: dim).width < rect.width - 8 {
					(take as NSString).draw(at: NSPoint(x: rect.minX + 4, y: rect.minY + 16), withAttributes: dim)
				}
			}
		}

		// The overlays, each on its own row under the clips, so a caption that
		// spans three clips is visibly one thing rather than three.
		var rows: [Double] = []
		for overlay in resolved.overlays {
			let row = rows.firstIndex { $0 <= overlay.start + 1e-9 } ?? rows.count
			if row < rows.count { rows[row] = overlay.end } else { rows.append(overlay.end) }
			let y = top + clipRowHeight + CGFloat(row) * overlayRowHeight
			let a = x(for: overlay.start), b = x(for: overlay.end)
			let rect = NSRect(x: a, y: y + 1, width: max(b - a - 1, 2), height: overlayRowHeight - 3)
			let colour: NSColor = overlay.path != nil ? Theme.externalWave : Theme.cameraWave
			colour.withAlphaComponent(0.35).setFill()
			rect.fill()
			colour.setStroke()
			NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()

			let label: String
			switch overlay.overlay.kind {
			case .text(let text, _): label = text
			case .spinner(let spinner): label = spinner.words.first?.text ?? "spinner"
			}
			let attributes: [NSAttributedString.Key: Any] = [.font: Theme.monoSmall, .foregroundColor: Theme.text]
			if (label as NSString).size(withAttributes: attributes).width < rect.width - 6 {
				(label as NSString).draw(at: NSPoint(x: rect.minX + 3, y: rect.minY + 1), withAttributes: attributes)
			}
		}

		let px = x(for: playhead).rounded() + 0.5
		Theme.playhead.setStroke()
		let line = NSBezierPath()
		line.move(to: NSPoint(x: px, y: 0))
		line.line(to: NSPoint(x: px, y: bounds.height))
		line.stroke()
	}

	private func drawRuler() {
		Theme.panel.setFill()
		NSRect(x: 0, y: 0, width: bounds.width, height: rulerHeight).fill()
		let step = tickStep()
		var t = 0.0
		while t <= duration {
			let tx = x(for: t)
			Theme.rule.setStroke()
			let tick = NSBezierPath()
			tick.move(to: NSPoint(x: tx.rounded() + 0.5, y: rulerHeight - 4))
			tick.line(to: NSPoint(x: tx.rounded() + 0.5, y: rulerHeight))
			tick.stroke()
			(Timecode.string(t) as NSString).draw(
				at: NSPoint(x: tx + 3, y: 1),
				withAttributes: [.font: Theme.monoSmall, .foregroundColor: Theme.dimText])
			t += step
		}
	}

	private func tickStep() -> Double {
		let target = duration * Double(90 / max(bounds.width, 1))
		let candidates: [Double] = [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
		return candidates.first { $0 >= target } ?? 600
	}

	public override func mouseDown(with event: NSEvent) {
		let point = convert(event.locationInWindow, from: nil)
		let t = time(forX: point.x)
		onScrub?(t)
		if let clip = resolved?.clips.last(where: { t >= $0.start && t < $0.end }) { onSelect?(clip) }
	}

	public override func mouseDragged(with event: NSEvent) {
		onScrub?(time(forX: convert(event.locationInWindow, from: nil).x))
	}
}
