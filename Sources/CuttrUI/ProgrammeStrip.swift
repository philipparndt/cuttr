import AppKit
import CuttrCompose
import CuttrKit

/// The finished programme as one bar: every clip, in order, at its real length.
///
/// Not the cutting window's timeline. There is nothing to trim, because a
/// project does not own its clips — the takes do, and trimming here would be
/// editing a file this window is only reading. What it is for is seeing the
/// shape of the programme, seeing which take each part came from, and getting
/// the playhead to a particular clip.
///
/// The one thing it does edit in a take is the level curve, on the lane under
/// the clips. Levelling is a comparison, and the programme is the only place
/// the clips of twenty recordings are heard one after another: a shot that is
/// too loud is too loud *here*, next to the one before it, and the lane draws
/// every clip's sound at the level it will actually be heard at, so the loud
/// one is the one that fills its lane. A point dragged there goes to the take's
/// file, since the curve is the take's — see ``onSetLevels``.
@MainActor
public final class ProgrammeStrip: NSView {

	public var resolved: ResolvedProject? {
		didSet {
			// A curve in hand was written and has come back through the
			// project; from here the project's copy is the one drawn.
			if levelDrag == nil { editing = nil }
			needsDisplay = true
			window?.invalidateCursorRects(for: self)
		}
	}
	/// What to say when there is nothing to draw.
	public var emptyMessage: String? { didSet { needsDisplay = true } }
	public var playhead: Double = 0 {
		didSet {
			// A zoomed strip pages along with the playhead, so playing past the
			// right-hand edge does not leave the strip showing a stretch that
			// is no longer playing. See ``TimeWindow/follow(_:)``.
			//
			// Only for a tick of playback — a small step forward while the tape
			// is rolling. Every other move of the playhead is somebody's own
			// doing or nobody's: a click lands inside the view by definition,
			// and a rebuilt preview reports nought and then where it was while
			// its item is swapped, which paged the view to the top of the
			// programme and back on every curve point let go of.
			// And only from on screen: a playhead that was in view and walked
			// off its edge is playback the view has fallen behind, where one
			// that was already elsewhere — the swapped item's nought — is not.
			let step = playhead - oldValue
			let shown = aimed().shown
			if isPlaying, step > 0, step < 1, oldValue >= shown.start, oldValue <= shown.end {
				var window = aimed()
				if window.follow(playhead) {
					viewed = window
					onZoom?(viewed.zoomed)
				}
			}
			needsDisplay = true
		}
	}
	/// Whether the tape is rolling, which is when the view follows the
	/// playhead. Told by the window, since the strip has no player of its own.
	public var isPlaying = false
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

	/// A take's gain curve was changed through one of its clips: the clip it
	/// was changed through, and the take's whole curve as it should now be, on
	/// the take's clock. Whoever answers writes the take and says whether it
	/// did; the strip keeps showing the new curve until the project comes back
	/// resolved with it, so the point does not jump back while the file is
	/// being written and read again.
	public var onSetLevels: ((ResolvedClip, [LevelPoint]) -> Bool)?

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
	/// Where in the thumb it was taken hold of, while it is being dragged.
	private var sliding: CGFloat?

	private let clipRowHeight: CGFloat = 34
	/// The levels lane, under the clips: waveform, curve and points. Tall
	/// enough that a point can be put within a decibel of where it is wanted.
	let levelsRowHeight: CGFloat = 64
	/// Tall enough to be grabbed. A bar somebody is meant to drag has to be
	/// worth aiming at, and sixteen points with two of border was a line.
	private let overlayRowHeight: CGFloat = 22
	/// How far either side of an edge counts as the edge.
	private let grabSlop: CGFloat = 5
	private let groupRowHeight: CGFloat = 15
	private let rulerHeight: CGFloat = 16
	/// The scrollbar's band, along the bottom edge of the strip.
	///
	/// It sat under the ruler, and the two were seven points apart and the
	/// same grey: a click meant to put the playhead somewhere landed a few
	/// points low and moved the view instead, over and over. At the bottom
	/// the two gestures are at opposite ends of the strip, and the top is only
	/// ever about the playhead.
	private let scrollbarHeight: CGFloat = 7
	/// Where the lanes start — under the ruler.
	private var lanesTop: CGFloat { rulerHeight }

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
			//
			// With shift, a plain wheel is sideways too — which is the whole of
			// what a mouse without one can do, and macOS's own answer to the
			// same problem everywhere else.
			let sideways: CGFloat
			if flags.contains(.shift),
			   abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) {
				sideways = event.scrollingDeltaY
			} else if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
				sideways = event.scrollingDeltaX
			} else {
				sideways = 0
			}
			if sideways != 0, aimed().isZoomed {
				// Away from the pointer's travel: a swipe to the right shows
				// what is to the *left*, which is what every scroll view on
				// this machine does and what the properties column's own strip
				// already did. This one had the sign the other way round, so
				// the two strips disagreed about which way a swipe goes.
				pan(byPoints: -sideways)
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
		zoom(by: factor, aboutFraction: (point.x - gutter) / track)
	}

	private func zoom(by factor: Double, aboutFraction fraction: CGFloat) {
		var window = aimed()
		window.zoom(by: factor, aboutFraction: fraction)
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
			lanes.append(("sections", lanesTop, CGFloat(depths) * groupRowHeight))
		}
		for group in resolved.groups {
			let a = x(for: group.start), b = x(for: group.end)
			let y = lanesTop + CGFloat(group.depth) * groupRowHeight
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
		let top = lanesTop + groupsHeight
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

			// The holds: a wash over the block, with a line where the picture
			// stops. A clip with a treatment is longer on the strip than its
			// footage is, and without this the extra seconds are unaccounted
			// for — the bar simply does not match the length anybody measured
			// in the take.
			//
			// Asked of the clip only when there is something to ask about: this
			// is a draw loop, and a programme with no treatments on it should
			// not be building a list per clip per frame to be told so.
			for stretch in clip.presentations.isEmpty ? [] : clip.playing
			where stretch.isHeld {
				let from = x(for: stretch.at), to = x(for: stretch.at + stretch.length)
				let held = NSRect(x: from, y: rect.minY, width: max(to - from, 1),
				                  height: rect.height).intersection(rect)
				guard !held.isEmpty else { continue }
				Theme.accent.withAlphaComponent(0.18).setFill()
				held.fill()
				Theme.accent.withAlphaComponent(0.55).setStroke()
				let edge = NSBezierPath()
				edge.move(to: NSPoint(x: held.minX + 0.5, y: held.minY))
				edge.line(to: NSPoint(x: held.minX + 0.5, y: held.maxY))
				edge.stroke()
			}

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

		// The levels, under the clips: what each one will sound like, and the
		// curve that says so. See the note at the top.
		let lane = NSRect(x: gutter, y: top + clipRowHeight, width: track,
		                  height: levelsRowHeight)
		levelsRect = lane
		lanes.append(("levels", lane.minY, levelsRowHeight))
		drawLevels(in: lane, of: resolved)
		let overlaysTop = lane.maxY

		// The overlays, each on its own row under the levels, so a caption that
		// spans three clips is visibly one thing rather than three.
		var rows: [Double] = []
		bars.removeAll()
		for overlay in resolved.overlays {
			let row = rows.firstIndex { $0 <= overlay.start + 1e-9 } ?? rows.count
			if row < rows.count { rows[row] = overlay.end } else { rows.append(overlay.end) }
			let y = overlaysTop + CGFloat(row) * overlayRowHeight
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
			lanes.append(("overlays", overlaysTop, CGFloat(rows.count) * overlayRowHeight))
		}

		var soundRows: [Double] = []
		let soundTop = overlaysTop + CGFloat(rows.count) * overlayRowHeight + 2
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
		// Over whatever lane reached the bottom, so the band is always there.
		drawScrollbar()

		let px = x(for: playhead).rounded() + 0.5
		Theme.playhead.setStroke()
		let line = NSBezierPath()
		line.move(to: NSPoint(x: px, y: 0))
		line.line(to: NSPoint(x: px, y: bounds.height))
		line.stroke()

		drawButtons()
		drawNotice()
	}

	// MARK: - The levels lane

	/// Where the lane was last drawn. Nothing until the strip has drawn once.
	private var levelsRect: NSRect?

	/// The curve in hand, while a point is being dragged or a dip drawn — and
	/// after, until the file comes back through the project. `began` is the
	/// curve as it was when the pointer went down, so that letting go without
	/// having changed anything writes nothing: the same rule the bars follow.
	private var editing: (take: String, clip: Int, levels: [LevelPoint], began: [LevelPoint])?
	/// Which point is chosen, by the take it belongs to and its index in that
	/// take's curve. ⌫ is about it.
	private var selectedLevel: (take: String, index: Int)?
	private enum LevelGrip { case point(Int), dip(from: Double) }
	private var levelDrag: LevelGrip?

	/// The decoded sound of each recording the programme uses, by file.
	///
	/// Two hundred buckets a second: the strip is at most a few thousand points
	/// wide and a programme is minutes long, so a millisecond a bucket — what
	/// the cutting window needs for aligning — would be five times the memory
	/// for nothing anybody could see. Kept on the strip rather than on the
	/// project, because the strip outlives every re-resolve and a decode is
	/// seconds a file.
	private var waves: [URL: Waveform] = [:]
	private var wavesLoading: Set<URL> = []
	private var wavesFailed: [URL: String] = [:]
	static let waveBucketsPerSecond = 200.0

	/// The waveform of a file, or nothing while it decodes — and the decode is
	/// started by the asking. Drawn again when it lands.
	private func wave(for url: URL) -> Waveform? {
		if let wave = waves[url] { return wave }
		guard !wavesLoading.contains(url), wavesFailed[url] == nil else { return nil }
		wavesLoading.insert(url)
		Task { [weak self] in
			let outcome: Result<Waveform, Error>
			do {
				outcome = .success(try await WaveformExtractor.extract(
					url: url, bucketsPerSecond: Self.waveBucketsPerSecond))
			} catch {
				outcome = .failure(error)
			}
			guard let self else { return }
			self.wavesLoading.remove(url)
			switch outcome {
			case .success(let wave): self.waves[url] = wave
			case .failure(let error): self.wavesFailed[url] = error.localizedDescription
			}
			self.needsDisplay = true
		}
		return nil
	}

	/// The take's curve for a clip, as it stands: the one in hand if this
	/// clip's take is the one being edited, otherwise what the file says.
	private func curve(for clip: ResolvedClip) -> [LevelPoint] {
		if let editing, editing.take == clip.takeName { return editing.levels }
		return resolved?.takeCurves[clip.takeName] ?? []
	}

	/// The lane read as a level scale, in decibels — the same scale the cutting
	/// window's lane uses, so a point sits at the same height in both.
	private func y(forLevel gain: Double, in rect: NSRect) -> CGFloat {
		let range = GainCurve.editable
		let clamped = min(max(gain, range.lowerBound), range.upperBound)
		let fraction = (range.upperBound - clamped) / (range.upperBound - range.lowerBound)
		return rect.minY + 2 + (rect.height - 4) * CGFloat(fraction)
	}

	/// The reverse, to a tenth of a decibel.
	private func level(forY y: CGFloat, in rect: NSRect) -> Double {
		let range = GainCurve.editable
		let fraction = Double((y - rect.minY - 2) / max(1, rect.height - 4))
		let gain = range.upperBound - fraction * (range.upperBound - range.lowerBound)
		return min(max((gain * 10).rounded() / 10, range.lowerBound), range.upperBound)
	}

	/// How many seconds one point of the track is worth, at this zoom.
	private var secondsPerPoint: Double {
		let shown = aimed().shown
		return (shown.end - shown.start) / Double(max(track, 1))
	}

	/// The clip under a moment of the programme, if any.
	private func clipIndex(at time: Double) -> Int? {
		resolved?.clips.lastIndex { time >= $0.start && time < $0.end }
	}

	/// The level a clip is heard at, at a moment of its take: the flat figure
	/// the resolver worked out and the curve — the curve in hand, if there is
	/// one — added.
	private func heard(_ clip: ResolvedClip, atTake time: Double, curve: [LevelPoint]) -> Double {
		clip.gain + GainCurve.gain(at: time, in: curve)
	}

	private func drawLevels(in lane: NSRect, of resolved: ResolvedProject) {
		NSColor(calibratedWhite: 1, alpha: 0.03).setFill()
		lane.fill()
		let middle = lane.midY
		let limit = lane.height / 2 - 1
		let shown = aimed().shown
		let onScreen = resolved.clips.indices.filter {
			resolved.clips[$0].end > shown.start && resolved.clips[$0].start < shown.end
		}

		// The sound, a column at a time, at the level it will be heard: the
		// take's figure, the clip's, the match and the curve, all of it. Not the
		// recording as it was — a lane showing the recordings as recorded would
		// show every take level with every other, which is the one thing the
		// programme is not. Clipped against the lane, so a shot pushed twenty
		// decibels up is a shot that fills its lane, and reads as one.
		for index in onScreen {
			let clip = resolved.clips[index]
			let a = max(x(for: clip.start), gutter).rounded()
			let b = min(x(for: clip.end), bounds.maxX)
			guard b > a else { continue }
			let curve = curve(for: clip)
			guard let media = clip.audioURL ?? clip.videoURL else { continue }
			// The take's clock for the curve, the file's for the samples: a
			// separate recorder's file is offset from the take by the
			// alignment, and the curve is on the take's clock by the one-clock
			// rule.
			let shift = clip.audioURL != nil ? clip.audioOffset : 0
			let colour = clip.audioURL != nil ? Theme.externalWave : Theme.cameraWave
			guard let wave = wave(for: media) else {
				let word = wavesFailed[media] == nil ? "decoding…" : "no sound"
				let attributes: [NSAttributedString.Key: Any] = [
					.font: Theme.monoSmall, .foregroundColor: Theme.faintText,
				]
				if (word as NSString).size(withAttributes: attributes).width < b - a - 6 {
					(word as NSString).draw(at: NSPoint(x: a + 3, y: middle - 6),
					                        withAttributes: attributes)
				}
				continue
			}
			let path = NSBezierPath()
			path.lineWidth = 1
			var px = a
			while px < b {
				let from = clip.takeTime(forProgramme: time(forX: px))
				let to = clip.takeTime(forProgramme: time(forX: px + 1))
				// A held frame has no sound under it, and the take's clock
				// stands still there: nothing to draw.
				if to > from, let extremes = wave.extremes(from: from - shift, to: to - shift) {
					let scale = (lane.height / 2 - 2)
						* CGFloat(Levelling.amplitude(heard(clip, atTake: from, curve: curve)))
					let high = middle - min(CGFloat(extremes.max) * scale, limit)
					let low = middle - max(CGFloat(extremes.min) * scale, -limit)
					path.move(to: NSPoint(x: px + 0.5, y: min(high, middle - 0.5)))
					path.line(to: NSPoint(x: px + 0.5, y: max(low, middle + 0.5)))
				}
				px += 1
			}
			colour.withAlphaComponent(0.7).setStroke()
			path.stroke()
		}

		// The cut between two clips, so the lane can be read against the row
		// above it without looking up.
		Theme.rule.withAlphaComponent(0.6).setFill()
		for index in onScreen {
			let edge = x(for: resolved.clips[index].start).rounded()
			if edge > gutter { NSRect(x: edge, y: lane.minY, width: 1, height: lane.height).fill() }
		}

		// Nought, dashed and dim: the reference the curve is read against, and
		// the line a first click lands on to make a point.
		let zero = y(forLevel: 0, in: lane).rounded() + 0.5
		let guide = NSBezierPath()
		guide.move(to: NSPoint(x: lane.minX, y: zero))
		guide.line(to: NSPoint(x: lane.maxX, y: zero))
		guide.lineWidth = 0.5
		guide.setLineDash([2, 3], count: 2, phase: 0)
		Theme.rule.setStroke()
		guide.stroke()

		// The curve over each clip, a column at a time — the run between two
		// points is linear in amplitude and this axis is decibels, so it is a
		// curve and not a line. Then the points, and the one in hand said out
		// loud with its number: the whole of what a drag is doing is choosing
		// that number.
		for index in onScreen {
			let clip = resolved.clips[index]
			let curve = curve(for: clip)
			guard !curve.isEmpty else { continue }
			let a = max(x(for: clip.start), gutter).rounded()
			let b = min(x(for: clip.end), bounds.maxX)
			guard b > a else { continue }
			let line = NSBezierPath()
			var px = a
			while px <= b {
				let at = NSPoint(x: px, y: y(forLevel: GainCurve.gain(
					at: clip.takeTime(forProgramme: time(forX: px)), in: curve), in: lane))
				if px == a { line.move(to: at) } else { line.line(to: at) }
				px += 1
			}
			line.lineWidth = 1.5
			Theme.text.withAlphaComponent(0.9).setStroke()
			line.stroke()

			for (pointIndex, point) in curve.enumerated()
			where point.at >= clip.clip.start - 1e-9 && point.at <= clip.clip.end + 1e-9 {
				let px = x(for: clip.programmeTime(forTake: point.at))
				guard px >= a - 3, px <= b + 3 else { continue }
				let py = y(forLevel: point.gain, in: lane)
				let held = selectedLevel?.take == clip.takeName && selectedLevel?.index == pointIndex
				let box = NSRect(x: px - 2.5, y: py - 2.5, width: 5, height: 5)
				(held ? Theme.accent : Theme.text).setFill()
				NSBezierPath(ovalIn: box).fill()
				if held {
					Theme.accent.setStroke()
					NSBezierPath(ovalIn: box.insetBy(dx: -2.5, dy: -2.5)).stroke()
					(String(format: "%+.1f dB", point.gain) as NSString).draw(
						at: NSPoint(x: px + 7, y: py - 6),
						withAttributes: [.font: Theme.monoSmall, .foregroundColor: Theme.accent])
				}
			}
		}
	}

	/// The point of a curve under the pointer, if the pointer is on one: which
	/// clip it was found through, and its index in that take's curve.
	private func levelPoint(at point: NSPoint) -> (clip: Int, index: Int)? {
		guard let lane = levelsRect, lane.contains(point), let resolved else { return nil }
		let shown = aimed().shown
		for (clipIndex, clip) in resolved.clips.enumerated()
		where clip.end > shown.start && clip.start < shown.end {
			for (index, held) in curve(for: clip).enumerated()
			where held.at >= clip.clip.start - 1e-9 && held.at <= clip.clip.end + 1e-9 {
				let px = x(for: clip.programmeTime(forTake: held.at))
				let py = y(forLevel: held.gain, in: lane)
				if abs(px - point.x) <= grabSlop && abs(py - point.y) <= grabSlop {
					return (clipIndex, index)
				}
			}
		}
		return nil
	}

	/// Whether the pointer is on a clip's curve — the line, rather than a
	/// point on it. Four points of slop, the way an automation lane has always
	/// worked: clicking the line is how a point is made, and everywhere else in
	/// the lane still scrubs. The nought line counts when the take has no
	/// curve, because a curve nobody can start is a curve nobody will draw.
	private func isOnCurve(_ point: NSPoint, of clip: ResolvedClip, in lane: NSRect) -> Bool {
		let here = GainCurve.gain(at: clip.takeTime(forProgramme: time(forX: point.x)),
		                          in: curve(for: clip))
		return abs(y(forLevel: here, in: lane) - point.y) <= 4
	}

	/// The curve with a point at each end of a clip, at the level it already
	/// has there — so that whatever is then done inside the clip stays inside
	/// it.
	///
	/// A curve is held flat past its last point and runs straight between two,
	/// so one point dragged down inside a clip would take every other clip of
	/// the take down with it: the whole recording at −6 dB, because somebody
	/// tamed one sentence. In the cutting window that is the take's business;
	/// on the programme the clip is what is being edited, and the rest of the
	/// take is other shots that were already right. The two points cost
	/// nothing where the curve was flat — nought stays nought — and are only
	/// written along with a change, never by a click that made none.
	static func pinned(_ curve: [LevelPoint], from start: Double, to end: Double) -> [LevelPoint] {
		var out = curve
		for edge in [start, end] where !out.contains(where: { abs($0.at - edge) < 1e-6 }) {
			let level = GainCurve.gain(at: edge, in: curve)
			out.append(LevelPoint(at: edge, gain: level.isFinite ? (level * 10).rounded() / 10 : 0))
		}
		return GainCurve.tidied(out)
	}

	/// A dip laid over one stretch of a curve: down at its start, back up at
	/// its end, and the stretch between held `depth` decibels under whatever
	/// the curve was doing at either edge. Four points, each of which can then
	/// be dragged like any other — this is only the four clicks done as one
	/// gesture, because taking a shout off a sentence is done forty times a
	/// programme and four clicks each is a hundred and sixty. Points already
	/// inside the stretch go, since the dip is what the stretch is now. Kept
	/// `within` the clip it is drawn in, so its edges cannot reach past a cut.
	static func dip(over curve: [LevelPoint], from: Double, to: Double,
	                depth: Double = 12, edge: Double = 0.06,
	                within: ClosedRange<Double>? = nil) -> [LevelPoint] {
		let start = max(within?.lowerBound ?? 0, from - edge)
		let end = min(within?.upperBound ?? .infinity, to + edge)
		let atStart = GainCurve.gain(at: start, in: curve)
		let atEnd = GainCurve.gain(at: end, in: curve)
		func tenth(_ value: Double) -> Double { (value * 10).rounded() / 10 }
		var out = curve.filter { $0.at < start - 1e-9 || $0.at > end + 1e-9 }
		out += [
			LevelPoint(at: start, gain: tenth(atStart)),
			LevelPoint(at: from, gain: tenth(atStart - depth)),
			LevelPoint(at: to, gain: tenth(atEnd - depth)),
			LevelPoint(at: end, gain: tenth(atEnd)),
		]
		return GainCurve.tidied(out)
	}

	/// The pointer went down in the levels lane. Says whether that was about
	/// the curve; a press anywhere else in the lane is a scrub like the rest.
	private func pressLevels(at point: NSPoint, in lane: NSRect, with event: NSEvent) -> Bool {
		guard let resolved else { return false }
		let t = time(forX: point.x)
		guard let clipIndex = clipIndex(at: t) else { return false }
		let clip = resolved.clips[clipIndex]
		let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
		// Pinned at the clip's edges first, whatever is about to be done — see
		// ``pinned(_:from:to:)``. The edit happens on the pinned curve.
		let base = Self.pinned(curve(for: clip), from: clip.clip.start, to: clip.clip.end)
		let span = clip.clip.start ... clip.clip.end

		// ⌥: a dip, drawn across the stretch that gets dragged over.
		if flags.contains(.option) {
			let from = clip.takeTime(forProgramme: t)
			editing = (clip.takeName, clipIndex,
			           Self.dip(over: base, from: from, to: from, within: span), base)
			levelDrag = .dip(from: from)
			selectedLevel = nil
			return true
		}
		guard flags.isEmpty else { return false }

		// A point: taken hold of. The line: a point made, and taken hold of.
		if let hit = levelPoint(at: point) {
			let through = resolved.clips[hit.clip]
			let held = curve(for: through)[hit.index]
			let pinned = Self.pinned(curve(for: through),
			                         from: through.clip.start, to: through.clip.end)
			guard let index = pinned.firstIndex(of: held) else { return false }
			editing = (through.takeName, hit.clip, pinned, pinned)
			selectedLevel = (through.takeName, index)
			levelDrag = .point(index)
			return true
		}
		if isOnCurve(point, of: clip, in: lane) {
			var scratch = Take(levels: base)
			// Within a couple of points of an existing one is that one: at a
			// wide zoom two clicks a pixel apart are one decision.
			let index = scratch.setLevel(level(forY: point.y, in: lane),
			                             at: clip.takeTime(forProgramme: t),
			                             within: secondsPerPoint * 2)
			editing = (clip.takeName, clipIndex, scratch.levels, base)
			selectedLevel = (clip.takeName, index)
			levelDrag = .point(index)
			return true
		}
		selectedLevel = nil
		return false
	}

	/// The pointer moved with a point or a dip in hand.
	private func dragLevels(to point: NSPoint, in lane: NSRect) {
		guard var editing, let levelDrag, let resolved,
		      resolved.clips.indices.contains(editing.clip) else { return }
		let clip = resolved.clips[editing.clip]
		// Kept inside the clip it is being dragged through: past the cut is a
		// stretch of the take another clip may be playing, or none.
		let at = min(max(clip.takeTime(forProgramme: time(forX: point.x)),
		                 clip.clip.start), clip.clip.end)
		switch levelDrag {
		case .point(let index):
			var scratch = Take(levels: editing.levels)
			scratch.moveLevel(index, to: at, gain: level(forY: point.y, in: lane))
			editing.levels = scratch.levels
		case .dip(let from):
			editing.levels = Self.dip(over: editing.began, from: min(from, at), to: max(from, at),
			                          within: clip.clip.start ... clip.clip.end)
		}
		self.editing = editing
		needsDisplay = true
	}

	/// Let go. Written only if it went somewhere — see ``editing``.
	private func releaseLevels() {
		guard let editing, levelDrag != nil else { return }
		levelDrag = nil
		needsDisplay = true
		guard editing.levels != editing.began, let resolved,
		      resolved.clips.indices.contains(editing.clip)
		else {
			// Nothing changed, so the pins go too — and the chosen point has
			// to be found again in the curve without them, or ⌫ would be
			// about a point that is not there.
			let chosen = selectedLevel.flatMap { selected in
				editing.levels.indices.contains(selected.index) ? editing.levels[selected.index] : nil
			}
			self.editing = nil
			if let chosen, let selectedLevel, let resolved,
			   resolved.clips.indices.contains(editing.clip) {
				let plain = curve(for: resolved.clips[editing.clip])
				self.selectedLevel = plain.firstIndex(of: chosen).map { (selectedLevel.take, $0) }
			}
			return
		}
		if onSetLevels?(resolved.clips[editing.clip], editing.levels) != true {
			self.editing = nil
		}
	}

	/// ⌫ on the chosen point. Says whether there was one.
	@discardableResult
	private func removeSelectedLevel() -> Bool {
		guard let selectedLevel, let resolved,
		      let clipIndex = resolved.clips.firstIndex(where: { $0.takeName == selectedLevel.take })
		else { return false }
		let clip = resolved.clips[clipIndex]
		let shown = curve(for: clip)
		guard shown.indices.contains(selectedLevel.index) else { return false }
		// Pinned first, like every other edit: taking a point out must not
		// re-level the clips either side any more than putting one in may.
		let began = Self.pinned(shown, from: clip.clip.start, to: clip.clip.end)
		var scratch = Take(levels: began)
		guard let index = began.firstIndex(of: shown[selectedLevel.index]) else { return false }
		scratch.removeLevel(at: index)
		self.selectedLevel = nil
		editing = (clip.takeName, clipIndex, scratch.levels, began)
		if onSetLevels?(clip, scratch.levels) != true { editing = nil }
		needsDisplay = true
		return true
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
		NSRect(x: 0, y: lanesTop, width: gutter, height: bounds.height - lanesTop).fill()
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
			if top > lanesTop + 1 {
				Theme.rule.withAlphaComponent(0.4).setFill()
				NSRect(x: 6, y: top.rounded(), width: bounds.width - 6, height: 1).fill()
			}
		}
	}

	// MARK: - Panning

	/// The band the thumb slides in.
	private func scrollbarTrack() -> NSRect {
		NSRect(x: gutter, y: bounds.height - scrollbarHeight, width: track,
		       height: scrollbarHeight)
	}

	/// Where the thumb is, or nothing while the whole programme is shown.
	///
	/// Drawn for the same reason the zoom buttons are drawn. Panning was a
	/// sideways swipe and nothing else: no thumb, no gutter, nothing to say the
	/// programme continued past either edge — so on a mouse with no sideways
	/// wheel, a zoom was a one-way door, and on a trackpad it was a gesture
	/// somebody had to already know. It also answers the question a zoomed
	/// strip always raises, which is *where in the programme am I*.
	private func scrollbarThumb() -> NSRect? {
		let shown = aimed().shown
		let whole = duration
		let span = shown.end - shown.start
		guard aimed().isZoomed, whole > span, span > 0 else { return nil }
		let rail = scrollbarTrack()
		let width = max(28, rail.width * CGFloat(span / whole))
		let travel = max(0, rail.width - width)
		let along = CGFloat((shown.start - 0) / (whole - span))
		return NSRect(x: rail.minX + travel * min(max(0, along), 1),
		              y: rail.minY + 1, width: width, height: rail.height - 3)
	}

	private func drawScrollbar() {
		Theme.panel.setFill()
		NSRect(x: 0, y: bounds.height - scrollbarHeight, width: bounds.width,
		       height: scrollbarHeight).fill()
		guard let thumb = scrollbarThumb() else { return }
		let rail = scrollbarTrack()
		Theme.rule.withAlphaComponent(0.35).setFill()
		NSBezierPath(roundedRect: NSRect(x: rail.minX, y: rail.minY + 1,
		                                 width: rail.width, height: rail.height - 3),
		             xRadius: 2, yRadius: 2).fill()
		(sliding == nil ? Theme.dimText : Theme.text).withAlphaComponent(0.75).setFill()
		NSBezierPath(roundedRect: thumb, xRadius: 2, yRadius: 2).fill()
	}

	/// Puts the thumb's left edge here, and the view with it.
	private func slide(thumbTo x: CGFloat) {
		var window = aimed()
		let shown = window.shown
		let span = shown.end - shown.start
		let whole = duration
		guard let thumb = scrollbarThumb(), whole > span else { return }
		let travel = scrollbarTrack().width - thumb.width
		guard travel > 0 else { return }
		let along = Double(min(max(0, (x - gutter) / travel), 1))
		let start = along * (whole - span)
		window.zoomed = (start, start + span)
		viewed = window
		onZoom?(viewed.zoomed)
		needsDisplay = true
	}

	private func drawRuler() {
		// In the playhead's own colour, faintly: this band and the scrollbar's
		// under it were the same grey, and a click meant to put the playhead
		// somewhere landed a few points low and moved the view instead. The
		// band that places the playhead now looks like the playhead's.
		Theme.panel.setFill()
		NSRect(x: 0, y: 0, width: bounds.width, height: rulerHeight).fill()
		Theme.playhead.withAlphaComponent(0.13).setFill()
		NSRect(x: gutter, y: 0, width: track, height: rulerHeight).fill()
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

		// ⌫ and ⌦, on the chosen point of a curve. By key code: the character a
		// delete key produces is a control character no layout puts anywhere
		// else, but the code is the place on the keyboard.
		if event.keyCode == 51 || event.keyCode == 117 {
			if removeSelectedLevel() { return true }
			guard explaining else { return false }
			say("click a point of the level curve first — ⌫ removes one")
			return true
		}

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

	private func zoomIn() { zoom(by: 1 / 1.6, aboutFraction: fractionOfPlayhead()) }
	private func zoomOut() { zoom(by: 1.6, aboutFraction: fractionOfPlayhead()) }

	/// Where the playhead is on the track, for a zoom that came from a key or a
	/// button rather than from a pointer.
	///
	/// The middle of the view is the wrong anchor for a press: what somebody is
	/// looking at is the frame they are on, and zooming in is how they ask to
	/// see more of *that*. Zooming about the middle instead walks the playhead
	/// off the edge in two presses, and then the strip is showing a part of the
	/// programme nobody asked for. The same reasoning, and the same fallback,
	/// as the properties column's strip and its selected range.
	private func fractionOfPlayhead() -> CGFloat {
		let fraction = aimed().fraction(of: playhead)
		return (fraction >= 0 && fraction <= 1) ? fraction : 0.5
	}

	/// Whether there is an overlay chosen for `i` and `o` to be about.
	public var hasSelectedOverlay: Bool { selectedBar() != nil }

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

	private func fakeClick(at point: NSPoint, flags: NSEvent.ModifierFlags = []) -> NSEvent {
		NSEvent.mouseEvent(
			with: .leftMouseDown, location: convert(point, to: nil), modifierFlags: flags,
			timestamp: 0, windowNumber: window?.windowNumber ?? 0, context: nil,
			eventNumber: 0, clickCount: 1, pressure: 1)
			?? NSEvent()
	}

	/// The levels lane, once drawn, and where a level sits in it.
	var levelsLaneForTesting: NSRect? { levelsRect }
	func levelsPointForTesting(time: Double, gain: Double) -> NSPoint? {
		guard let lane = levelsRect else { return nil }
		return NSPoint(x: x(for: time), y: y(forLevel: gain, in: lane))
	}
	var selectedLevelForTesting: Int? { selectedLevel?.index }

	/// Down at one point, over to another, up — with ⌥ held when asked.
	func dragLevelsForTesting(from: NSPoint, to: NSPoint, option: Bool = false) {
		let flags: NSEvent.ModifierFlags = option ? [.option] : []
		mouseDown(with: fakeClick(at: from, flags: flags))
		if from != to { mouseDragged(with: fakeClick(at: to, flags: flags)) }
		mouseUp(with: fakeClick(at: to, flags: flags))
	}

	func buttonCentreForTesting(_ button: Button) -> NSPoint {
		let rect = buttonRects().first { $0.0 == button }?.1 ?? .zero
		return NSPoint(x: rect.midX, y: rect.midY)
	}
	var shownForTesting: (start: Double, end: Double) { aimed().shown }
	func fractionForTesting(of time: Double) -> CGFloat { aimed().fraction(of: time) }
	func timeForTesting(atFraction fraction: CGFloat) -> Double {
		aimed().time(atFraction: fraction)
	}

	var scrollbarThumbForTesting: NSRect? { scrollbarThumb() }
	var scrollbarTrackForTesting: NSRect { scrollbarTrack() }

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

		// Then the scrollbar, along the bottom, for the same reason: a click
		// there is about where the strip is looking, not about where the
		// playhead should go.
		if let thumb = scrollbarThumb(),
		   scrollbarTrack().insetBy(dx: 0, dy: -2).contains(point) {
			// Anywhere but the thumb takes the thumb there, so the whole rail
			// is a way of getting somewhere rather than a decoration with one
			// small part that works.
			sliding = thumb.contains(point) ? point.x - thumb.minX : thumb.width / 2
			slide(thumbTo: point.x - (sliding ?? 0))
			return
		}

		let t = time(forX: point.x)

		// The levels lane: a point, the curve, or a dip with ⌥. A press there
		// that is about none of them scrubs, the same as the rest of the strip.
		if let lane = levelsRect, lane.contains(point) {
			notice = nil
			selected = nil
			if pressLevels(at: point, in: lane, with: event) {
				window?.makeFirstResponder(self)
				needsDisplay = true
				return
			}
			needsDisplay = true
		}

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
		let point = convert(event.locationInWindow, from: nil)
		if let grab = sliding {
			slide(thumbTo: point.x - grab)
			return
		}
		if levelDrag != nil, let lane = levelsRect {
			dragLevels(to: point, in: lane)
			return
		}
		let at = time(forX: point.x)
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
		if sliding != nil {
			sliding = nil
			needsDisplay = true
			return
		}
		if levelDrag != nil {
			releaseLevels()
			return
		}
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
