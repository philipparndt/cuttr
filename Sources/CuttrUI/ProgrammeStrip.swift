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
	public var onMoveOverlay: ((Origin, Int, Double, Double) -> Void)?
	/// Whether the anchor markers are drawn over the picture. Kept here because
	/// the strip is where the switch lives.
	public var showAnchors = true { didSet { needsDisplay = true } }

	/// Where each overlay's bar is, so a drag can find it again.
	private var bars: [(origin: Origin, appearance: Int, rect: NSRect,
	                    start: Double, end: Double)] = []
	/// Which overlay bar is selected, if any. There was no such thing: a bar
	/// could be dragged but not *chosen*, so a key had nothing to act on.
	private var selected: (origin: Origin, appearance: Int)?

	private enum Grip { case body(Double), start, end }
	private var dragging: (origin: Origin, appearance: Int, grip: Grip,
	                       start: Double, end: Double)?
	/// Where the bar was when it was taken hold of.
	///
	/// So that letting go without having moved writes nothing. A click on a bar
	/// is how it gets *selected*, and it used to also go through
	/// ``onMoveOverlay`` with the two ends it already had — which is not the
	/// nothing it looks like: the range gets re-spelled on the way, so
	/// selecting an overlay written `within:` a clip could rewrite it as
	/// programme times, and one with no range at all could be given one. A
	/// click that edits the file is bad enough; a click that edits the file
	/// while somebody is only trying to look at something is worse.
	private var grabbedAt: (start: Double, end: Double)?

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

	/// The room down the left for the lane names.
	///
	/// Four bands of bars stacked with nothing to say which is which: a caption
	/// and a sting are the same shape, and the only thing that distinguished
	/// them was a hue somebody had to have learned. Named, the strip reads
	/// without being explained — and that is worth sixty points of a strip that
	/// is two hundred wide.
	private let gutter: CGFloat = 62
	private var track: CGFloat { max(bounds.width - gutter, 1) }

	/// Which stretch of the programme is on screen. The arithmetic is
	/// ``TimeWindow``, shared with the properties column's strip, because two
	/// strips zooming a clock the same way should not be two answers.
	private var viewed = TimeWindow()

	/// Somebody zoomed, so whoever rebuilds this can put it back. A fact about
	/// the session, not about the project.
	public var onZoom: (((start: Double, end: Double)?) -> Void)?

	/// The bounds follow the programme's length, and a zoom that outlived a
	/// re-cut slides inside the new length rather than pointing past it.
	private func aimed() -> TimeWindow {
		var out = viewed
		out.limits = (0, duration)
		return out
	}

	/// The refusal, over the top of everything, so it cannot be missed.
	private func drawNotice() {
		guard let notice else { return }
		let attributes: [NSAttributedString.Key: Any] = [
			.font: Theme.label, .foregroundColor: Theme.text,
		]
		let size = (notice as NSString).size(withAttributes: attributes)
		let box = NSRect(x: gutter + 8, y: bounds.height - size.height - 10,
		                 width: size.width + 16, height: size.height + 6)
		Theme.card.withAlphaComponent(0.95).setFill()
		NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
		(notice as NSString).draw(at: NSPoint(x: box.minX + 8, y: box.minY + 3),
		                          withAttributes: attributes)
	}

	private func x(for time: Double) -> CGFloat {
		gutter + aimed().fraction(of: time) * track
	}

	private func time(forX x: CGFloat) -> Double {
		aimed().time(atFraction: (x - gutter) / track)
	}

	// MARK: - Zooming

	/// The three buttons at the right of the ruler: out, in, and the whole
	/// thing.
	///
	/// Drawn rather than left to the keyboard. A zoom that exists only as a key
	/// is a zoom somebody has to be told about, and this one has been reported
	/// as broken three times — twice because the key genuinely never arrived,
	/// and once because the only way to find out was to guess. A control that is
	/// visible cannot be missed and cannot depend on a keyboard layout.
	enum Button: CaseIterable {
		case out, `in`, whole

		var glyph: String {
			switch self {
			case .out: return "−"
			case .in: return "+"
			case .whole: return "⤢"
			}
		}

		var help: String {
			switch self {
			case .out: return "Show more of the programme (−)"
			case .in: return "Show less of it (+)"
			case .whole: return "The whole programme (F)"
			}
		}
	}

	private static let buttonSize: CGFloat = 15

	/// Where each one is, from the right-hand end of the ruler.
	private func buttonRects() -> [(Button, NSRect)] {
		let size = Self.buttonSize
		var x = bounds.maxX - 6 - size
		var out: [(Button, NSRect)] = []
		for button in [Button.whole, .in, .out] {
			out.append((button, NSRect(x: x, y: 1, width: size, height: size)))
			x -= size + 3
		}
		return out
	}

	private func drawButtons() {
		let attributes: [NSAttributedString.Key: Any] = [
			.font: Theme.monoSmall, .foregroundColor: Theme.dimText,
		]
		for (button, rect) in buttonRects() {
			Theme.card.setFill()
			NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
			Theme.rule.setStroke()
			NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
			             xRadius: 3, yRadius: 3).stroke()
			let glyph = button.glyph as NSString
			let size = glyph.size(withAttributes: attributes)
			glyph.draw(at: NSPoint(x: rect.midX - size.width / 2,
			                       y: rect.midY - size.height / 2),
			           withAttributes: attributes)
		}
	}

	/// Pressing one of them. Internal so a test can press one without a mouse.
	func press(_ button: Button) {
		switch button {
		case .out: zoomOut()
		case .in: zoomIn()
		case .whole: fit()
		}
	}

	/// ⌥ or ⌘ with the wheel, and a pinch, both about the pointer. The bare
	/// wheel is left alone: this strip sits under a picture in a window that
	/// scrolls, and a view that swallows the wheel is a trap.
	public override func scrollWheel(with event: NSEvent) {
		let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
		guard flags.contains(.option) || flags.contains(.command) else {
			// Sideways is a pan, but only while there is somewhere to pan to,
			// so the gesture falls through when the whole thing is shown.
			if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY), aimed().isZoomed {
				pan(byPoints: event.scrollingDeltaX)
				return
			}
			super.scrollWheel(with: event)
			return
		}
		guard event.scrollingDeltaY != 0 else { return }
		zoom(by: event.scrollingDeltaY > 0 ? 0.9 : 1.1, at: event.locationInWindow)
	}

	public override func magnify(with event: NSEvent) {
		zoom(by: 1 / (1 + event.magnification), at: event.locationInWindow)
	}

	private func zoom(by factor: Double, at locationInWindow: NSPoint) {
		let point = convert(locationInWindow, from: nil)
		var window = aimed()
		window.zoom(by: factor, aboutFraction: (point.x - gutter) / track)
		viewed = window
		onZoom?(viewed.zoomed)
		needsDisplay = true
	}

	private func pan(byPoints points: CGFloat) {
		var window = aimed()
		window.pan(byPoints: points, trackWidth: track)
		viewed = window
		onZoom?(viewed.zoomed)
		needsDisplay = true
	}

	/// Puts a zoom back after the window has rebuilt this strip.
	public func restoreZoom(_ window: (start: Double, end: Double)?) {
		guard viewed.zoomed?.start != window?.start
			|| viewed.zoomed?.end != window?.end else { return }
		viewed.zoomed = window
		needsDisplay = true
	}

	/// The whole programme again.
	public func fit() {
		var window = aimed()
		window.fit()
		viewed = window
		onZoom?(nil)
		needsDisplay = true
	}

	/// Frames one stretch — used by `Z` on the selected overlay.
	public func reveal(from start: Double, to end: Double) {
		var window = aimed()
		window.reveal(from: start, to: end)
		viewed = window
		onZoom?(viewed.zoomed)
		needsDisplay = true
	}

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
		// Where each band is, gathered as it is drawn, so the names are placed
		// from the same numbers the bars are.
		var lanes: [(String, CGFloat, CGFloat)] = []

		let depths = (resolved.groups.map(\.depth).max() ?? -1) + 1
		if depths > 0 {
			lanes.append(("sections", rulerHeight, CGFloat(depths) * groupRowHeight))
		}
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

		// The clips. Striped with the clip's own colour, so the lane somebody cut
		// it on in the other window is still visible here — which is how you see
		// at a glance that the b-roll query picked up the right things. The same
		// grammar as the cutting timeline: the colour is a stripe on the block,
		// not the block, or a strip of forty shots is forty coloured rectangles
		// and the slugs on them cannot be read.
		let top = rulerHeight + groupsHeight
		lanes.append(("programme", top, clipRowHeight))
		for clip in resolved.clips {
			let a = x(for: clip.start), b = x(for: clip.end)
			let rect = NSRect(x: a, y: top + 2, width: max(b - a - 1, 1), height: clipRowHeight - 4)
			Theme.clipBlock(false).setFill()
			rect.fill()
			Theme.clipStripe(clip.clip.color).setFill()
			NSRect(x: rect.minX, y: rect.minY, width: min(3, rect.width),
			       height: rect.height).fill()
			Theme.rule.setStroke()
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
			let chosen = selected?.origin == overlay.origin
				&& selected?.appearance == overlay.appearance
			let colour: NSColor = overlay.path != nil ? Theme.externalWave : Theme.cameraWave
			colour.withAlphaComponent(dragged ? 0.6 : chosen ? 0.5 : 0.35).setFill()
			rect.fill()
			colour.setStroke()
			NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()
			// A selected bar says so, because `i` and `o` are about it and a key
			// that acts on something invisible is a key nobody presses twice.
			if chosen {
				NSColor.white.withAlphaComponent(0.85).setStroke()
				let ring = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
				ring.lineWidth = 1.5
				ring.stroke()
			}

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
			case .bubble(let bubble): label = bubble.text
			case .frames(let frames): label = "frames \u{00B7} \(frames.folder)"
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
		if !rows.isEmpty {
			lanes.append(("overlays", top + clipRowHeight,
			              CGFloat(rows.count) * overlayRowHeight))
		}

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

		if !soundRows.isEmpty {
			lanes.append(("sound", soundTop, CGFloat(soundRows.count) * overlayRowHeight))
		}
		drawLaneNames(lanes)

		let px = x(for: playhead).rounded() + 0.5
		Theme.playhead.setStroke()
		let line = NSBezierPath()
		line.move(to: NSPoint(x: px, y: 0))
		line.line(to: NSPoint(x: px, y: bounds.height))
		line.stroke()

		drawButtons()
		drawNotice()
	}

	/// For the tests: the time axis, which now starts after the lane names
	/// rather than at the left edge.
	func timeForTesting(at x: CGFloat) -> Double { time(forX: x) }
	func xForTesting(_ time: Double) -> CGFloat { self.x(for: time) }
	var gutterForTesting: CGFloat { gutter }

	private static func colour(_ value: RGBA) -> NSColor {
		NSColor(calibratedRed: value.r, green: value.g, blue: value.b, alpha: value.a)
	}

	/// The lane names, and the rule that keeps them out of the bars.
	///
	/// Drawn last, over everything, so a bar that starts at nought cannot print
	/// itself into the names — and the ground behind them is opaque for the same
	/// reason.
	private func drawLaneNames(_ lanes: [(String, CGFloat, CGFloat)]) {
		Theme.background.setFill()
		NSRect(x: 0, y: rulerHeight, width: gutter, height: bounds.height - rulerHeight).fill()
		Theme.rule.withAlphaComponent(0.6).setFill()
		NSRect(x: gutter - 1, y: 0, width: 1, height: bounds.height).fill()

		for (name, top, height) in lanes where height > 6 {
			let attributes: [NSAttributedString.Key: Any] = [
				.font: Theme.monoSmall, .foregroundColor: Theme.faintText,
			]
			let size = (name as NSString).size(withAttributes: attributes)
			(name as NSString).draw(
				at: NSPoint(x: gutter - 8 - size.width,
				            y: top + max(0, (min(height, 18) - size.height) / 2)),
				withAttributes: attributes)
			// A hairline between the lanes, so a name is plainly about the band
			// beside it rather than about the whole strip.
			if top > rulerHeight + 1 {
				Theme.rule.withAlphaComponent(0.4).setFill()
				NSRect(x: 6, y: top.rounded(), width: bounds.width - 6, height: 1).fill()
			}
		}
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
		let target = duration * Double(90 / track)
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

	/// The keys this strip answers.
	///
	/// `i` and `o` put the selected overlay's ends where the playhead is — the
	/// same two letters that mean in and out in the cutting window and in the
	/// trim dialog. Written through ``onMoveOverlay``, which is the door a drag
	/// on the same bar already uses, so a range written `within:` a clip stays
	/// written that way and a mark still snaps. There is no second path.
	///
	/// A refusal says why rather than doing nothing: a key that silently fails
	/// is the same experience as a key that is not implemented.
	public override func keyDown(with event: NSEvent) {
		if handleKey(event, explaining: true) { return }
		super.keyDown(with: event)
	}

	/// Answers a key, and says whether it did.
	///
	/// Public because the window's key monitor catches every press before any
	/// view sees one, so a strip that only answered its own `keyDown` was only
	/// asked while it happened to hold the focus — and when it did not, the key
	/// fell through the responder chain and *beeped*. That is the second time
	/// this exact trap has shipped, so the window asks this directly and the
	/// focus stops mattering.
	/// `explaining` is true when the strip itself was asked — it has the focus,
	/// so somebody pressing `i` with nothing selected meant this strip and is
	/// owed a sentence. Asked from the window instead, a key with nothing to act
	/// on is declined and carries on to wherever it was going, because the
	/// window asks about every press and a notice on each one would be noise.
	@discardableResult
	public func handleKey(_ event: NSEvent, explaining: Bool = false) -> Bool {
		// Shift, the keypad and the function bit are not decisions anybody made
		// about which key this is. Requiring *no* flags at all is what made the
		// zoom keys beep: on a German keyboard `=` is Shift+0, and the keypad's
		// own plus and minus arrive carrying `.numericPad`.
		let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
			.subtracting([.shift, .numericPad, .function])
		guard flags.isEmpty else { return false }

		// The zoom keys by physical position first and by character second, the
		// way the other strip and the cutting window do it.
		// `charactersIgnoringModifiers` returns what the *layout* produces, and
		// there is no layout on which every one of these characters is reachable
		// without a modifier. A key code is a place on a keyboard and is the
		// same place on all of them.
		switch event.keyCode {
		case 24, 69: zoomIn(); return true          // = / + , and the keypad's
		case 27, 78: zoomOut(); return true         // - , and the keypad's
		default: break
		}
		// And by what was typed, for the layouts where these sit somewhere else
		// — German puts `+` and `-` on their own keys. Both spellings of each,
		// shifted or not, because a person reaching for "bigger" does not check.
		let typed = [event.charactersIgnoringModifiers, event.characters]
			.compactMap { $0?.lowercased() }
		if typed.contains(where: { $0 == "+" || $0 == "=" }) { zoomIn(); return true }
		if typed.contains(where: { $0 == "-" || $0 == "_" }) { zoomOut(); return true }

		guard let character = event.charactersIgnoringModifiers?.lowercased().first
		else { return false }

		switch character {
		case "i", "o":
			guard hasSelectedOverlay || explaining else { return false }
			setEdge(start: character == "i")
			return true
		case "z":
			guard let bar = selectedBar() else {
				guard explaining else { return false }
				say("nothing selected to frame")
				return true
			}
			reveal(from: bar.start, to: bar.end)
			return true
		case "f":
			fit()
			return true
		default:
			return false
		}
	}

	/// Frames the selected overlay, or says there is nothing to frame.
	public func frameSelection() {
		guard let bar = selectedBar() else {
			say("nothing selected to frame")
			return
		}
		reveal(from: bar.start, to: bar.end)
	}

	private func zoomIn() { zoom(by: 1 / 1.6, at: middleOfTrack()) }
	private func zoomOut() { zoom(by: 1.6, at: middleOfTrack()) }

	/// Whether there is an overlay chosen for `i` and `o` to be about.
	public var hasSelectedOverlay: Bool { selectedBar() != nil }

	/// The middle of what is shown, in window coordinates, for a zoom that came
	/// from the keyboard rather than from a pointer.
	private func middleOfTrack() -> NSPoint {
		convert(NSPoint(x: gutter + track / 2, y: bounds.midY), to: nil)
	}

	private func selectedBar() -> (origin: Origin, appearance: Int,
	                               start: Double, end: Double)? {
		guard let selected,
		      let bar = bars.first(where: {
			      $0.origin == selected.origin && $0.appearance == selected.appearance
		      })
		else { return nil }
		return (bar.origin, bar.appearance, bar.start, bar.end)
	}

	/// Puts one end of the selected overlay at the playhead.
	private func setEdge(start wantsStart: Bool) {
		guard let bar = selectedBar() else {
			return say("click an overlay's bar first — i and o are about one of them")
		}
		let at = playhead
		if wantsStart {
			guard at < bar.end - 0.001 else { return say("that is at or past the out") }
			onMoveOverlay?(bar.origin, bar.appearance, at, bar.end)
		} else {
			guard at > bar.start + 0.001 else { return say("that is at or before the in") }
			onMoveOverlay?(bar.origin, bar.appearance, bar.start, at)
		}
	}

	/// A sentence drawn over the strip until the next click. There is no status
	/// bar within reach of this view, and a refusal nobody can read is a
	/// refusal that reads as breakage.
	private var notice: String?

	private func say(_ text: String) {
		notice = text
		needsDisplay = true
	}

	// MARK: - For the tests

	/// Drawing is what records where the bars are, so a test that is about a
	/// bar has to have drawn once — into a scratch image, because `draw` wants
	/// a graphics context and a view that is in no window has none.
	func drawForTesting() {
		let image = NSImage(size: NSSize(width: max(bounds.width, 1),
		                                height: max(bounds.height, 1)))
		image.lockFocus()
		draw(bounds)
		image.unlockFocus()
	}

	func selectFirstBarForTesting() {
		guard let first = bars.first else { return }
		selected = (first.origin, first.appearance)
	}

	var noticeForTesting: String? { notice }

	/// Taking hold of the first bar and letting go, with the pointer moved by
	/// `by` seconds in between — nought for a plain click.
	///
	/// Driven through the same three steps a mouse would, rather than by
	/// sending events: an `NSEvent` needs a window to have a location in, and
	/// what is under test is whether letting go writes anything.
	func clickFirstBarForTesting(movingBy by: Double = 0) {
		guard let first = bars.first else { return }
		let inside = NSPoint(x: first.rect.midX, y: first.rect.midY)
		mouseDown(with: fakeClick(at: inside))
		if by != 0 {
			mouseDragged(with: fakeClick(at: NSPoint(x: x(for: first.start + by) + 
			                                         (inside.x - first.rect.minX),
			                                         y: inside.y)))
		}
		mouseUp(with: fakeClick(at: inside))
	}

	private func fakeClick(at point: NSPoint) -> NSEvent {
		NSEvent.mouseEvent(
			with: .leftMouseDown, location: convert(point, to: nil), modifierFlags: [],
			timestamp: 0, windowNumber: window?.windowNumber ?? 0, context: nil,
			eventNumber: 0, clickCount: 1, pressure: 1)
			?? NSEvent()
	}

	func buttonCentreForTesting(_ button: Button) -> NSPoint {
		let rect = buttonRects().first { $0.0 == button }?.1 ?? .zero
		return NSPoint(x: rect.midX, y: rect.midY)
	}
	var shownForTesting: (start: Double, end: Double) { aimed().shown }
	func timeForTesting(atFraction fraction: CGFloat) -> Double {
		aimed().time(atFraction: fraction)
	}

	func zoomForTesting(by factor: Double, atFraction fraction: CGFloat) {
		var window = aimed()
		window.zoom(by: factor, aboutFraction: fraction)
		viewed = window
		needsDisplay = true
	}

	public override func mouseDown(with event: NSEvent) {
		let point = convert(event.locationInWindow, from: nil)

		// The zoom buttons first: they sit over the ruler, where a click would
		// otherwise move the playhead.
		if let (button, _) = buttonRects().first(where: { $0.1.insetBy(dx: -2, dy: -2).contains(point) }) {
			press(button)
			return
		}

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
			grabbedAt = (bar.start, bar.end)
			selected = (bar.origin, bar.appearance)
			notice = nil
			window?.makeFirstResponder(self)
			needsDisplay = true
			return
		}

		selected = nil
		notice = nil
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
		let began = grabbedAt
		dragging = nil
		grabbedAt = nil
		needsDisplay = true
		// Only if it actually went somewhere. See ``grabbedAt``.
		guard began == nil || moving.start != began!.start || moving.end != began!.end else {
			return
		}
		onMoveOverlay?(moving.origin, moving.appearance, moving.start, moving.end)
	}
}
