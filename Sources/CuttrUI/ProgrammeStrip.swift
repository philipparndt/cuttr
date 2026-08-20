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

	public var resolved: ResolvedProject? {
		didSet {
			needsDisplay = true
			window?.invalidateCursorRects(for: self)
		}
	}
	/// What to say when there is nothing to draw.
	public var emptyMessage: String? { didSet { needsDisplay = true } }
	public var playhead: Double = 0 { didSet { needsDisplay = true } }
	public var onScrub: ((Double) -> Void)?
	public var onSelect: ((ResolvedClip) -> Void)?
	/// Somebody asked to see where this clip came from, at this moment.
	public var onOpenClip: ((ResolvedClip, Double) -> Void)?
	/// An overlay's bar was dragged: which overlay it came from, and where its
	/// ends are now, on the programme's clock. The window writes it back the
	/// way the file says it — snapped to a clip, or relative to one.
	public var onMoveOverlay: ((OverlayOrigin, Int, Double, Double) -> Void)?
	/// Whether the anchor markers are drawn over the picture. Kept here because
	/// the strip is where the switch lives.
	public var showAnchors = true { didSet { needsDisplay = true } }

	/// Where each overlay's bar is, so a drag can find it again.
	private var bars: [(origin: OverlayOrigin, appearance: Int, rect: NSRect,
	                    start: Double, end: Double)] = []
	private enum Grip { case body(Double), start, end }
	private var dragging: (origin: OverlayOrigin, appearance: Int, grip: Grip,
	                       start: Double, end: Double)?

	private let clipRowHeight: CGFloat = 34
	/// Tall enough to be grabbed. A bar somebody is meant to drag has to be
	/// worth aiming at, and sixteen points with two of border was a line.
	private let overlayRowHeight: CGFloat = 22
	/// How far either side of an edge counts as the edge.
	private let grabSlop: CGFloat = 5
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

		// The cards, on the same row as the clips because that is where they
		// are: a stretch of programme like any other, in its own colour, with
		// nothing behind it. Drawn in the fill it will actually be, which is
		// the only thing there is to say about one.
		for card in resolved.cards {
			let a = x(for: card.start), b = x(for: card.end)
			let rect = NSRect(x: a, y: top + 2, width: max(b - a - 1, 1), height: clipRowHeight - 4)
			switch card.card.fill {
			case .solid(let colour):
				Self.colour(colour).setFill()
				rect.fill()
			case .gradient(let upper, let lower):
				NSGradient(starting: Self.colour(lower), ending: Self.colour(upper))?
					.draw(in: rect, angle: 90)
			}
			// A black card on a dark strip is nothing at all without an outline.
			Theme.color(.card).setStroke()
			NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()
			let attributes: [NSAttributedString.Key: Any] = [
				.font: Theme.monoSmall, .foregroundColor: Theme.color(.card),
			]
			if ("card" as NSString).size(withAttributes: attributes).width < rect.width - 8 {
				("card" as NSString).draw(at: NSPoint(x: rect.minX + 4, y: rect.minY + 3),
				                          withAttributes: attributes)
			}
		}

		// The overlays, each on its own row under the clips, so a caption that
		// spans three clips is visibly one thing rather than three.
		var rows: [Double] = []
		bars.removeAll()
		for overlay in resolved.overlays {
			let row = rows.firstIndex { $0 <= overlay.start + 1e-9 } ?? rows.count
			if row < rows.count { rows[row] = overlay.end } else { rows.append(overlay.end) }
			let y = top + clipRowHeight + CGFloat(row) * overlayRowHeight
			let moved = dragging?.origin == overlay.origin
				&& dragging?.appearance == overlay.appearance ? dragging : nil
			let a = x(for: moved?.start ?? overlay.start), b = x(for: moved?.end ?? overlay.end)
			let rect = NSRect(x: a, y: y + 1, width: max(b - a - 1, 2), height: overlayRowHeight - 3)
			bars.append((overlay.origin, overlay.appearance, rect, overlay.start, overlay.end))
			let dragged = dragging?.origin == overlay.origin
				&& dragging?.appearance == overlay.appearance
			let colour: NSColor = overlay.path != nil ? Theme.externalWave : Theme.cameraWave
			colour.withAlphaComponent(dragged ? 0.6 : 0.35).setFill()
			rect.fill()
			colour.setStroke()
			NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()

			// Handles at both ends, always. On the cutting timeline these are
			// drawn on the selected clip only, because every clip there has
			// them and a row of grab bars would *be* the timeline; here there
			// are a handful of bars and no other way to know they can be
			// dragged at all.
			if rect.width > 10 {
				colour.setFill()
				for edge in [rect.minX, rect.maxX - 3] {
					NSRect(x: edge, y: rect.minY, width: 3, height: rect.height).fill()
				}
			}

			let label: String
			switch overlay.overlay.kind {
			case .text(let text, _): label = text
			case .spinner(let spinner): label = spinner.words.first?.text ?? "spinner"
			case .effect(let effect): label = effect.style.rawValue
			case .film(let film): label = "film · \(film.tint.rawValue) \(film.ratio.written)"
			case .aberration(let aberration): label = "aberration · \(aberration.kind.rawValue)"
			case .tape(let tape): label = "tape · \(tape.condition.rawValue)"
			case .scene(let name, _): label = name
			}
			let attributes: [NSAttributedString.Key: Any] = [.font: Theme.monoSmall, .foregroundColor: Theme.text]
			if (label as NSString).size(withAttributes: attributes).width < rect.width - 6 {
				(label as NSString).draw(at: NSPoint(x: rect.minX + 3, y: rect.minY + 1), withAttributes: attributes)
			}
		}

		// The sounds, under the overlays, because that is where they are: laid
		// beneath the programme rather than over it. Shown and not dragged —
		// a sound is bound to a clip or a section like an overlay is, but there
		// is no picture to place it against, so it is edited in the panel.
		var soundRows: [Double] = []
		let soundTop = top + clipRowHeight + CGFloat(rows.count) * overlayRowHeight + 2
		for sound in resolved.sounds {
			let row = soundRows.firstIndex { $0 <= sound.start + 1e-9 } ?? soundRows.count
			if row < soundRows.count { soundRows[row] = sound.end } else { soundRows.append(sound.end) }
			let a = x(for: sound.start), b = x(for: sound.end)
			let y = soundTop + CGFloat(row) * overlayRowHeight
			let rect = NSRect(x: a, y: y + 1, width: max(b - a - 1, 2), height: overlayRowHeight - 3)
			let colour = Theme.color(.sound)
			colour.withAlphaComponent(0.28).setFill()
			rect.fill()
			colour.setStroke()
			NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()
			var label = (sound.sound.file as NSString).lastPathComponent
			if sound.sound.ducks != 0 { label += " ▼" }
			let attributes: [NSAttributedString.Key: Any] = [
				.font: Theme.monoSmall, .foregroundColor: Theme.text,
			]
			if (label as NSString).size(withAttributes: attributes).width < rect.width - 6 {
				(label as NSString).draw(at: NSPoint(x: rect.minX + 3, y: rect.minY + 1),
				                         withAttributes: attributes)
			}
		}

		let px = x(for: playhead).rounded() + 0.5
		Theme.playhead.setStroke()
		let line = NSBezierPath()
		line.move(to: NSPoint(x: px, y: 0))
		line.line(to: NSPoint(x: px, y: bounds.height))
		line.stroke()
	}

	private static func colour(_ value: RGBA) -> NSColor {
		NSColor(calibratedRed: value.r, green: value.g, blue: value.b, alpha: value.a)
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

	public override func resetCursorRects() {
		super.resetCursorRects()
		for bar in bars {
			// The ends resize, the middle moves. Saying which with the pointer
			// is most of how anybody finds out that either is possible.
			for edge in [bar.rect.minX, bar.rect.maxX] {
				addCursorRect(NSRect(x: edge - grabSlop, y: bar.rect.minY,
				                     width: grabSlop * 2, height: bar.rect.height),
				              cursor: .resizeLeftRight)
			}
			let middle = bar.rect.insetBy(dx: grabSlop, dy: 0)
			if middle.width > 2 { addCursorRect(middle, cursor: .openHand) }
		}
	}

	public override func mouseDown(with event: NSEvent) {
		let point = convert(event.locationInWindow, from: nil)
		let t = time(forX: point.x)

		// A bar under the pointer is a thing to move; anywhere else is the
		// playhead, which is what a click on a timeline usually means.
		if let bar = bars.last(where: { $0.rect.insetBy(dx: -3, dy: -2).contains(point) }) {
			let grip: Grip
			if abs(point.x - bar.rect.minX) < grabSlop {
				grip = .start
			} else if abs(point.x - bar.rect.maxX) < grabSlop {
				grip = .end
			} else {
				grip = .body(t - bar.start)
			}
			dragging = (bar.origin, bar.appearance, grip, bar.start, bar.end)
			needsDisplay = true
			return
		}

		onScrub?(t)
		if let clip = resolved?.clips.last(where: { t >= $0.start && t < $0.end }) {
			onSelect?(clip)
			// Twice for "show me where this came from". Once selects, which is
			// what a single click on a timeline means everywhere.
			if event.clickCount == 2 { onOpenClip?(clip, t) }
		}
	}

	public override func mouseDragged(with event: NSEvent) {
		let at = time(forX: convert(event.locationInWindow, from: nil).x)
		guard var moving = dragging else {
			onScrub?(at)
			return
		}
		switch moving.grip {
		case .start: moving.start = min(at, moving.end - 0.05)
		case .end: moving.end = max(at, moving.start + 0.05)
		case .body(let grab):
			let length = moving.end - moving.start
			moving.start = max(0, at - grab)
			moving.end = moving.start + length
		}
		dragging = moving
		window?.invalidateCursorRects(for: self)
		// Shown while it is being dragged rather than only when it is let go,
		// so the bar follows the pointer.
		if let index = bars.firstIndex(where: {
			$0.origin == moving.origin && $0.appearance == moving.appearance
		}) {
			bars[index].start = moving.start
			bars[index].end = moving.end
			bars[index].rect.origin.x = x(for: moving.start)
			bars[index].rect.size.width = max(x(for: moving.end) - x(for: moving.start) - 1, 2)
		}
		onScrub?(moving.start)
		needsDisplay = true
	}

	public override func mouseUp(with event: NSEvent) {
		guard let moving = dragging else { return }
		dragging = nil
		needsDisplay = true
		onMoveOverlay?(moving.origin, moving.appearance, moving.start, moving.end)
	}
}
