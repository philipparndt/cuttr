import AppKit
import CuttrKit

/// The timeline: ruler, clip band, one waveform lane per recording, overview.
///
/// Drawn rather than composed out of subviews. A lane is one path built from
/// the visible columns and nothing else — at any zoom, the work is proportional
/// to the width of the window rather than to the length of the take, which is
/// what lets a forty-minute recording scrub at the frame rate of the screen.
/// Subviews per clip would have been easier to write and would put a hundred
/// layers on the compositor to say what four rectangles say.
@MainActor
public final class TimelineView: NSView {

	// MARK: - What it shows

	public weak var document: TakeDocument?

	public var playhead: Double = 0 { didSet { needsDisplay = true } }

	/// The in/out span that is not a clip yet.
	public var pending: (start: Double, end: Double)? { didSet { needsDisplay = true } }

	public var selectedClip: Clip.ID? { didSet { needsDisplay = true } }

	/// Vertical zoom on the waveform — amplitude, not time.
	///
	/// A separate control from the timeline's zoom because it answers a
	/// different question. Zooming in time asks "when did that happen"; zooming
	/// the amplitude asks "is there anything there at all", which is what you
	/// need on a quiet lavalier or when finding the exact edge of a breath. At
	/// gain 1 a whisper is a flat line, and no amount of scrolling reveals it.
	///
	/// Clipped rather than scaled: an overdriven peak flattens against the top
	/// of its lane instead of drawing over the neighbouring one, which is what
	/// any audio editor does and is the only way the lanes stay readable.
	public private(set) var waveformGain: Double = 1

	public func zoomWaveform(by factor: Double) {
		waveformGain = min(max(waveformGain * factor, 0.25), 64)
		needsDisplay = true
	}

	public func resetWaveformGain() {
		waveformGain = 1
		needsDisplay = true
	}

	/// Leftmost visible time, and how much time a point of width is worth.
	public private(set) var scrollTime: Double = 0
	public private(set) var secondsPerPoint: Double = 0.02

	// MARK: - What it reports

	public var onScrub: ((Double) -> Void)?
	public var onSelectClip: ((Clip.ID?) -> Void)?
	/// A trim or a move, live during the drag and once more at the end. The
	/// `commit` flag is what the document uses to coalesce a drag into one
	/// undo step rather than sixty.
	public var onEditClip: ((Clip.ID, _ start: Double, _ end: Double, _ commit: Bool) -> Void)?
	public var onOffsetChange: ((Double, _ commit: Bool) -> Void)?
	public var onPendingChange: (((start: Double, end: Double)?) -> Void)?
	/// Right-click: the clip under the pointer, if any, and the time there.
	public var contextMenu: ((Clip.ID?, Double) -> NSMenu?)?
	/// A click landed on a lane: make that colour current.
	public var onLanePicked: ((ClipColor) -> Void)?
	/// A name typed straight onto the clip's bar.
	public var onRenameInPlace: ((Clip.ID, String) -> Void)?

	// MARK: - Geometry

	private let rulerHeight: CGFloat = 18
	private let clipRowHeight: CGFloat = 22
	/// How many rows of overlapping clips are shown before they start sharing
	/// again. Four is enough for the cases this is for — a wide clip with a few
	/// inside it — and a band that grows without limit would eat the waveform.
	private let maximumClipRows = 4
	private let overviewHeight: CGFloat = 26
	/// How close to an edge counts as grabbing it.
	private let grabSlop: CGFloat = 5

	public override var isFlipped: Bool { true }
	public override var acceptsFirstResponder: Bool { true }

	public override init(frame: NSRect) {
		super.init(frame: frame)
		wantsLayer = true
		layer?.backgroundColor = Theme.background.cgColor
		addGestureRecognizer(NSMagnificationGestureRecognizer(target: self, action: #selector(magnified(_:))))
	}

	@available(*, unavailable) required init?(coder: NSCoder) { nil }

	// MARK: - Time and space

	public func x(for time: Double) -> CGFloat { CGFloat((time - scrollTime) / secondsPerPoint) }
	public func time(forX x: CGFloat) -> Double { scrollTime + Double(x) * secondsPerPoint }

	private var duration: Double { max(document?.duration ?? 0, 1) }

	private var lanesRect: NSRect {
		NSRect(x: 0, y: rulerHeight + clipBandHeight, width: bounds.width,
		       height: max(0, bounds.height - rulerHeight - clipBandHeight - overviewHeight))
	}
	/// Which row each clip is drawn in: **one row per colour in use**.
	///
	/// Not a greedy packing of overlapping intervals, which is what this was and
	/// which put two clips on the same bar whenever they happened not to
	/// overlap — so a lane meant nothing and moving a clip to another lane was
	/// impossible. The colour *is* the lane: pick a swatch and you are cutting
	/// on that bar, recolour a clip from the context menu and it moves to that
	/// bar. Rows appear and disappear as colours come into and out of use, so a
	/// take cut in one colour still has exactly one bar.
	private var clipRows: [Clip.ID: Int] {
		guard let clips = document?.take.clips else { return [:] }
		let lanes = document?.take.lanes ?? []
		var rows: [Clip.ID: Int] = [:]
		for clip in clips {
			rows[clip.id] = lanes.firstIndex(of: clip.color) ?? 0
		}
		return rows
	}

	private var clipRowCount: Int { max(1, document?.take.lanes.count ?? 1) }

	private var clipBandHeight: CGFloat { CGFloat(clipRowCount) * clipRowHeight }

	private var clipBandRect: NSRect {
		NSRect(x: 0, y: rulerHeight, width: bounds.width, height: clipBandHeight)
	}
	private var overviewRect: NSRect {
		NSRect(x: 0, y: bounds.height - overviewHeight, width: bounds.width, height: overviewHeight)
	}
	/// Where each waveform goes.
	///
	/// One lane or two, decided by what has actually finished decoding rather
	/// than by what the take names. A file that is still being read, or one that
	/// has gone missing, gives its half of the space back instead of leaving a
	/// grey band that looks like silence.
	private var laneRects: (camera: NSRect?, external: NSRect?) {
		let rect = lanesRect
		let hasCamera = document?.videoWaveform != nil
		let hasExternal = document?.audioWaveform != nil
		switch (hasCamera, hasExternal) {
		case (true, true):
			let half = (rect.height - 1) / 2
			return (NSRect(x: 0, y: rect.minY, width: rect.width, height: half),
			        NSRect(x: 0, y: rect.minY + half + 1, width: rect.width, height: half))
		case (true, false): return (rect, nil)
		case (false, true): return (nil, rect)
		case (false, false): return (nil, nil)
		}
	}

	// MARK: - Zoom and scroll

	/// Whether somebody has chosen a zoom.
	///
	/// Until they have, the timeline re-fits itself whenever the duration
	/// changes — which it does twice on opening a file, since the probe and the
	/// decode arrive separately. After they have, it never moves under them:
	/// a view that re-frames itself while somebody is working in it is the
	/// worst kind of helpful.
	public private(set) var userHasZoomed = false

	public func zoomToFitIfUntouched() {
		guard !userHasZoomed else { return }
		zoomToFit()
	}

	public func setZoom(_ secondsPerPoint: Double, anchorX: CGFloat? = nil) {
		closeEditorIfOpen()
		let anchor = anchorX ?? bounds.width / 2
		let anchorTime = time(forX: anchor)
		// A point may be worth between a fifth of a millisecond and a minute.
		// The lower bound is well past the resolution of the waveform and is
		// there for the alignment pass, where a millisecond has to be a visible
		// distance rather than a rounding.
		self.secondsPerPoint = min(max(secondsPerPoint, 0.0002), 60)
		scrollTime = anchorTime - Double(anchor) * self.secondsPerPoint
		clampScroll()
		needsDisplay = true
	}

	public func zoom(by factor: Double, anchorX: CGFloat? = nil) {
		userHasZoomed = true
		setZoom(secondsPerPoint * factor, anchorX: anchorX)
	}

	/// Zooming from the keyboard, which anchors on the playhead.
	///
	/// The centre of the view is the wrong anchor for a key press. Zooming in
	/// is something somebody does *at* a point — the cut they are about to
	/// place — and anchoring on the middle of the window walks that point off
	/// the screen after two presses. The pointer anchors ⌘-scroll for the same
	/// reason; the playhead is the keyboard's pointer.
	///
	/// Falls back to the centre when the playhead is off screen, since anchoring
	/// on something invisible would jump the view somewhere unasked for.
	public func zoomAroundPlayhead(by factor: Double) {
		let px = x(for: playhead)
		zoom(by: factor, anchorX: (px >= 0 && px <= bounds.width) ? px : nil)
	}

	public func zoomToFit() {
		guard bounds.width > 0 else { return }
		setZoom(duration / Double(bounds.width))
		scrollTime = 0
		needsDisplay = true
	}

	/// Frames the given span with a margin, for "show me this clip".
	public func reveal(from start: Double, to end: Double) {
		guard bounds.width > 0 else { return }
		userHasZoomed = true
		let span = max(end - start, secondsPerPoint * 20)
		setZoom(span * 1.3 / Double(bounds.width))
		scrollTime = start - span * 0.15
		clampScroll()
		needsDisplay = true
	}

	/// Keeps the playhead on screen while playing, by paging rather than by
	/// following. A timeline that scrolls under a stationary playhead makes the
	/// waveform unreadable — the eye has nothing to hold on to — so it stays
	/// still until the playhead leaves, then jumps a screen.
	public func followPlayhead() {
		let x = x(for: playhead)
		guard x < 0 || x > bounds.width - 40 else { return }
		scrollTime = playhead - Double(bounds.width) * secondsPerPoint * 0.15
		clampScroll()
		needsDisplay = true
	}

	public func scroll(by points: CGFloat) {
		closeEditorIfOpen()
		scrollTime += Double(points) * secondsPerPoint
		clampScroll()
		needsDisplay = true
	}

	/// The editor is positioned in view coordinates, so anything that moves the
	/// timeline under it has to close it first. Committing rather than
	/// cancelling: a scroll is not a change of mind about the name.
	private func closeEditorIfOpen() {
		if editingClip != nil { endRenaming(commit: true) }
	}

	private func clampScroll() {
		let visible = Double(bounds.width) * secondsPerPoint
		// Half a screen of slack at each end: a cut mark at the very start or
		// the very end is otherwise pinned against the frame of the window and
		// cannot be placed accurately.
		scrollTime = min(max(scrollTime, -visible / 2), duration - visible / 2)
	}

	public override func setFrameSize(_ newSize: NSSize) {
		super.setFrameSize(newSize)
		// A window resized before anybody has zoomed keeps showing the whole
		// take rather than a wider slice of the same seconds.
		if !userHasZoomed { zoomToFit() } else { clampScroll() }
		needsDisplay = true
	}

	public override func scrollWheel(with event: NSEvent) {
		// ⌘ and ⌥ both zoom. Editors disagree about which one it is — Resolve
		// and Premiere say ⌥, Final Cut and most Mac apps say ⌘ — and there is
		// nothing else for either of them to do here, so neither has to be
		// learnt.
		if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
			zoom(by: event.scrollingDeltaY > 0 ? 0.9 : 1.1, anchorX: convert(event.locationInWindow, from: nil).x)
			return
		}
		// A trackpad reports a horizontal delta for a two-finger swipe and a
		// vertical one for a mouse wheel. There is only one axis here, so both
		// drive it and whichever the hardware sends is the one that works.
		let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
			? event.scrollingDeltaX : event.scrollingDeltaY
		scroll(by: -delta)
	}

	@objc private func magnified(_ gesture: NSMagnificationGestureRecognizer) {
		let anchor = gesture.location(in: self).x
		zoom(by: 1 - gesture.magnification, anchorX: anchor)
		gesture.magnification = 0
	}

	// MARK: - Drawing

	public override func draw(_ dirtyRect: NSRect) {
		Theme.background.setFill()
		dirtyRect.fill()

		drawClipRegions()
		drawLanes()
		drawRuler()
		drawClipBand()
		drawSpeechEdges()
		drawPending()
		drawPlayhead()
		drawOverview()
	}

	private func drawLanes() {
		let (cameraRect, externalRect) = laneRects
		if let cameraRect, let wave = document?.videoWaveform {
			drawWave(wave, in: cameraRect, color: Theme.cameraWave, timeShift: 0,
			         caption: document?.videoURL?.lastPathComponent ?? "camera")
		}
		if let externalRect, let wave = document?.audioWaveform {
			drawWave(wave, in: externalRect, color: Theme.externalWave,
			         timeShift: document?.take.audio?.offset ?? 0,
			         caption: document?.audioURL?.lastPathComponent ?? "audio")
		}
		// Nothing to draw is still something to say. Each of these is a
		// different situation and the operator is entitled to know which:
		// waiting, a video with no sound in it, a file that would not read, or
		// an empty window.
		if cameraRect == nil && externalRect == nil {
			if let error = document?.mediaError {
				drawCaption(error, in: lanesRect)
			} else if document?.isLoadingMedia == true {
				drawCaption("decoding audio…", in: lanesRect)
			} else if document?.videoInfo != nil {
				drawCaption("this video has no audio track", in: lanesRect)
			} else {
				drawCaption("Drop a video or an audio file here  ·  ⌘O to open", in: lanesRect)
			}
		}
	}

	/// One column of pixels per column of pixels.
	private func drawWave(_ wave: Waveform, in rect: NSRect, color: NSColor, timeShift: Double, caption: String) {
		Theme.panel.setFill()
		rect.fill()

		let middle = rect.midY
		let scale = (rect.height / 2 - 2) * CGFloat(waveformGain)
		let limit = rect.height / 2 - 1
		let path = NSBezierPath()
		path.lineWidth = 1

		var x = rect.minX
		while x < rect.maxX {
			// The column's own span of time, so that zooming out averages
			// rather than samples: a waveform that misses transients between
			// its sample points is a waveform that lies about where a word is.
			let t0 = time(forX: x) - timeShift
			let t1 = time(forX: x + 1) - timeShift
			if let extremes = wave.extremes(from: t0, to: t1) {
				let top = middle - min(CGFloat(extremes.max) * scale, limit)
				let bottom = middle - max(CGFloat(extremes.min) * scale, -limit)
				// Half a point, so a silent passage is a line rather than
				// nothing: "there is audio here and it is quiet" and "there is
				// no audio here" have to look different.
				path.move(to: NSPoint(x: x + 0.5, y: min(top, middle - 0.5)))
				path.line(to: NSPoint(x: x + 0.5, y: max(bottom, middle + 0.5)))
			}
			x += 1
		}
		color.setStroke()
		path.stroke()

		Theme.rule.setStroke()
		let centre = NSBezierPath()
		centre.move(to: NSPoint(x: rect.minX, y: middle))
		centre.line(to: NSPoint(x: rect.maxX, y: middle))
		centre.lineWidth = 0.5
		centre.stroke()

		drawText(caption, at: NSPoint(x: rect.minX + 6, y: rect.minY + 3),
		         font: Theme.monoSmall, color: Theme.dimText)
		// The gain, but only when it is not 1: a number that is always there is
		// a number nobody reads, and one that appears when you changed
		// something is a number that means what it says.
		if waveformGain != 1 {
			let label = String(format: "×%g", waveformGain)
			let width = (label as NSString).size(withAttributes: [.font: Theme.monoSmall]).width
			drawText(label, at: NSPoint(x: rect.maxX - width - 6, y: rect.minY + 3),
			         font: Theme.monoSmall, color: color.withAlphaComponent(0.8))
		}
	}

	private func drawCaption(_ text: String, in rect: NSRect) {
		Theme.panel.setFill()
		rect.fill()
		let attributes: [NSAttributedString.Key: Any] = [.font: Theme.label, .foregroundColor: Theme.dimText]
		let size = (text as NSString).size(withAttributes: attributes)
		(text as NSString).draw(
			at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
			withAttributes: attributes)
	}

	/// The vertical shading behind each clip, across the waveform lanes.
	private func drawClipRegions() {
		guard let clips = document?.take.clips else { return }
		let rect = lanesRect
		for clip in clips {
			let a = x(for: clip.start), b = x(for: clip.end)
			guard b > -1, a < bounds.width + 1 else { continue }
			let region = NSRect(x: a, y: rect.minY, width: max(b - a, 1), height: rect.height)
			Theme.clipWash(clip.color, selected: clip.id == selectedClip).setFill()
			region.fill()
		}
	}

	/// Where a clip's bar is drawn, which is also where its editor opens.
	private func barRect(for clip: Clip) -> NSRect {
		barRect(for: clip, row: clipRows[clip.id] ?? 0)
	}

	private func barRect(for clip: Clip, row: Int) -> NSRect {
		let a = x(for: clip.start), b = x(for: clip.end)
		let top = rulerHeight + CGFloat(row) * clipRowHeight
		return NSRect(x: a, y: top + 2, width: max(b - a, 2), height: clipRowHeight - 4)
	}

	private func drawClipBand() {
		let band = clipBandRect
		Theme.panel.setFill()
		band.fill()

		// A tick of colour down the left edge of each lane. Without it an empty
		// lane is an empty grey strip, and the lane somebody is about to cut on
		// is the one thing they need to be sure of.
		for (row, color) in (document?.take.lanes ?? []).enumerated() {
			let y = rulerHeight + CGFloat(row) * clipRowHeight
			Theme.base(color).withAlphaComponent(0.9).setFill()
			NSRect(x: 0, y: y + 2, width: 3, height: clipRowHeight - 4).fill()
			Theme.rule.setStroke()
			let separator = NSBezierPath()
			separator.move(to: NSPoint(x: 0, y: y + 0.5))
			separator.line(to: NSPoint(x: bounds.width, y: y + 0.5))
			separator.lineWidth = 0.5
			if row > 0 { separator.stroke() }
		}
		guard let clips = document?.take.clips else { return }
		let rows = clipRows
		for clip in clips {
			let a = x(for: clip.start), b = x(for: clip.end)
			guard b > -1, a < bounds.width + 1 else { continue }
			if clip.id == editingClip { continue }   // the editor is drawing it
			let rect = barRect(for: clip, row: rows[clip.id] ?? 0)
			let selected = clip.id == selectedClip
			Theme.clipFill(clip.color, selected: selected).setFill()
			rect.fill()
			Theme.clipStroke(clip.color).setStroke()
			NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()

			// Trim handles, on the selected clip only.
			//
			// Every clip's edge is draggable, and drawing a handle on every one
			// of them would be a row of grab bars with a timeline behind it. On
			// the selected clip alone it says what the whole band can do, and
			// says it about the clip somebody is working on.
			if selected {
				Theme.clipStroke(clip.color).setFill()
				for edge in [rect.minX, rect.maxX - 3] {
					NSRect(x: edge, y: rect.minY, width: 3, height: rect.height).fill()
				}
				// And the same two bars down the lanes, so the edge can be
				// grabbed against the waveform rather than only up here.
				let lanes = lanesRect
				NSColor(calibratedWhite: 1, alpha: 0.5).setFill()
				for edge in [rect.minX, rect.maxX - 1] {
					NSRect(x: edge, y: lanes.minY, width: 1, height: lanes.height).fill()
				}
			}

			// The name once there is one, because that is what somebody just
			// typed and expects to see; the slug when there is not, because a
			// bar with nothing on it is a bar you cannot tell from its
			// neighbour. The slug follows in dim text when there is room —
			// it is the thing the assembly file will reference, and being able
			// to read it off the timeline is most of why it is drawn at all.
			let primary = clip.name.isEmpty ? clip.slug : clip.name
			let primaryAttributes: [NSAttributedString.Key: Any] =
				[.font: clip.name.isEmpty ? Theme.monoSmall : Theme.label, .foregroundColor: Theme.text]
			var pen = rect.minX + 6
			let primarySize = (primary as NSString).size(withAttributes: primaryAttributes)
			if primarySize.width < rect.width - 10 {
				(primary as NSString).draw(at: NSPoint(x: pen, y: rect.midY - primarySize.height / 2),
				                           withAttributes: primaryAttributes)
				pen += primarySize.width + 8
				if !clip.name.isEmpty {
					let slugAttributes: [NSAttributedString.Key: Any] =
						[.font: Theme.monoSmall, .foregroundColor: Theme.dimText]
					let slugSize = (clip.slug as NSString).size(withAttributes: slugAttributes)
					if pen + slugSize.width < rect.maxX - 4 {
						(clip.slug as NSString).draw(at: NSPoint(x: pen, y: rect.midY - slugSize.height / 2),
						                             withAttributes: slugAttributes)
					}
				}
			}
		}
	}

	/// The marks ⌥ is aiming at, while it is being held.
	///
	/// Drawn only during a drag: a timeline permanently ruled with the speech
	/// would be a timeline nobody can read, and these are an answer to a
	/// question somebody is in the middle of asking.
	private func drawSpeechEdges() {
		guard drag != nil, NSEvent.modifierFlags.contains(.option) else { return }
		let edges = document?.transcript.edges ?? []
		guard !edges.isEmpty else { return }
		let band = lanesRect
		for edge in edges {
			let x = x(for: edge)
			guard x >= band.minX - 1, x <= band.maxX + 1 else { continue }
			let hit = snapped.map { abs($0 - edge) < 0.0005 } ?? false
			(hit ? Theme.accent : Theme.dimText.withAlphaComponent(0.35)).setFill()
			NSRect(x: x.rounded(), y: band.minY, width: hit ? 2 : 1, height: band.height).fill()
		}
	}

	private func drawPending() {
		guard let pending else { return }
		let a = x(for: min(pending.start, pending.end))
		let b = x(for: max(pending.start, pending.end))
		let rect = NSRect(x: a, y: rulerHeight, width: max(b - a, 1),
		                  height: bounds.height - rulerHeight - overviewHeight)
		Theme.pendingFill.setFill()
		rect.fill()
		Theme.pendingStroke.setStroke()
		let edges = NSBezierPath()
		edges.move(to: NSPoint(x: a + 0.5, y: rect.minY)); edges.line(to: NSPoint(x: a + 0.5, y: rect.maxY))
		edges.move(to: NSPoint(x: b - 0.5, y: rect.minY)); edges.line(to: NSPoint(x: b - 0.5, y: rect.maxY))
		edges.lineWidth = 1
		edges.stroke()
		drawText(Timecode.string(abs(pending.end - pending.start)),
		         at: NSPoint(x: a + 4, y: rect.minY + 2), font: Theme.monoSmall, color: Theme.pendingStroke)
	}

	private func drawRuler() {
		let rect = NSRect(x: 0, y: 0, width: bounds.width, height: rulerHeight)
		Theme.panel.setFill()
		rect.fill()
		Theme.rule.setStroke()
		let line = NSBezierPath()
		line.move(to: NSPoint(x: 0, y: rulerHeight - 0.5))
		line.line(to: NSPoint(x: bounds.width, y: rulerHeight - 0.5))
		line.stroke()

		let step = tickStep()
		var t = (scrollTime / step).rounded(.down) * step
		let endTime = time(forX: bounds.width)
		while t <= endTime {
			let tx = x(for: t)
			if tx >= -40 {
				Theme.rule.setStroke()
				let tick = NSBezierPath()
				tick.move(to: NSPoint(x: tx.rounded() + 0.5, y: rulerHeight - 5))
				tick.line(to: NSPoint(x: tx.rounded() + 0.5, y: rulerHeight))
				tick.stroke()
				if t >= 0 {
					drawText(Timecode.string(t), at: NSPoint(x: tx + 3, y: 2),
					         font: Theme.monoSmall, color: Theme.dimText)
				}
			}
			t += step
		}
	}

	/// A tick roughly every 90 points, rounded to a number somebody reads as a
	/// time. 0.3 s ticks would be evenly spaced and unreadable.
	private func tickStep() -> Double {
		let target = 90 * secondsPerPoint
		let candidates: [Double] = [0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5,
		                            1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800, 3600]
		return candidates.first { $0 >= target } ?? 3600
	}

	private func drawPlayhead() {
		let px = x(for: playhead).rounded() + 0.5
		guard px > -2, px < bounds.width + 2 else { return }
		Theme.playhead.setStroke()
		let line = NSBezierPath()
		line.move(to: NSPoint(x: px, y: 0))
		line.line(to: NSPoint(x: px, y: bounds.height - overviewHeight))
		line.lineWidth = 1
		line.stroke()

		Theme.playhead.setFill()
		let head = NSBezierPath()
		head.move(to: NSPoint(x: px - 5, y: 0))
		head.line(to: NSPoint(x: px + 5, y: 0))
		head.line(to: NSPoint(x: px, y: 7))
		head.close()
		head.fill()
	}

	/// The whole take in 26 points, so that a window zoomed to a millisecond
	/// still says where in the recording it is. Click to jump.
	private func drawOverview() {
		let rect = overviewRect
		Theme.panel.setFill()
		rect.fill()
		Theme.rule.setStroke()
		let top = NSBezierPath()
		top.move(to: NSPoint(x: 0, y: rect.minY + 0.5))
		top.line(to: NSPoint(x: bounds.width, y: rect.minY + 0.5))
		top.stroke()

		let scale = bounds.width / CGFloat(duration)
		if let clips = document?.take.clips {
			for clip in clips {
				Theme.clipStroke(clip.color).setFill()
				NSRect(x: CGFloat(clip.start) * scale, y: rect.minY + 4,
				       width: max(CGFloat(clip.duration) * scale, 1), height: rect.height - 8).fill()
			}
		}

		// The viewport, so the overview is a scrollbar as well as a map.
		let visible = Double(bounds.width) * secondsPerPoint
		let viewport = NSRect(x: CGFloat(scrollTime) * scale, y: rect.minY + 1,
		                      width: max(CGFloat(visible) * scale, 3), height: rect.height - 2)
		NSColor(calibratedWhite: 1, alpha: 0.12).setFill()
		viewport.fill()
		NSColor(calibratedWhite: 1, alpha: 0.35).setStroke()
		NSBezierPath(rect: viewport.insetBy(dx: 0.5, dy: 0.5)).stroke()

		Theme.playhead.setFill()
		NSRect(x: CGFloat(playhead) * scale, y: rect.minY + 1, width: 1, height: rect.height - 2).fill()
	}

	private func drawText(_ text: String, at point: NSPoint, font: NSFont, color: NSColor) {
		(text as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: color])
	}

	// MARK: - Pointing at it

	private enum Drag {
		case scrub
		case pending(anchor: Double)
		case trim(id: Clip.ID, edge: Edge, other: Double)
		case move(id: Clip.ID, grabOffset: Double, length: Double)
		case offset(startOffset: Double, startTime: Double)
		case overview
		enum Edge { case start, end }
	}
	private var drag: Drag?
	/// The speech edge the mark is sitting on, while it is.
	private var snapped: Double?

	public override func mouseDown(with event: NSEvent) {
		let point = convert(event.locationInWindow, from: nil)
		let t = snap(time(forX: point.x))

		// Double-click on the bar: type the name where the clip is. This is the
		// gesture for the clip somebody can see rather than the row it happens
		// to be on in the table, and it is how a pass of `clip-1`, `clip-2`,
		// `clip-3` gets turned into names without leaving the timeline.
		if event.clickCount == 2, let clip = clipBar(at: point) {
			beginRenaming(clip)
			return
		}

		endRenaming(commit: true)
		window?.makeFirstResponder(self)

		if overviewRect.contains(point) {
			drag = .overview
			jumpFromOverview(point.x)
			return
		}

		// ⌥ in the external lane drags the alignment. The gesture is the thing
		// it does: grab the second waveform and slide it until it lines up.
		if event.modifierFlags.contains(.option),
		   let externalRect = laneRects.external, externalRect.contains(point),
		   let offset = document?.take.audio?.offset {
			drag = .offset(startOffset: offset, startTime: time(forX: point.x))
			return
		}

		if let hit = clipEdge(at: point) {
			drag = .trim(id: hit.id, edge: hit.edge, other: hit.other)
			selectedClip = hit.id
			onSelectClip?(hit.id)
			return
		}

		if let color = lane(at: point) { onLanePicked?(color) }

		if let clip = clipBar(at: point) {
			selectedClip = clip.id
			onSelectClip?(clip.id)
			drag = .move(id: clip.id, grabOffset: t - clip.start, length: clip.duration)
			return
		}
		// An empty stretch of a lane: the colour has been chosen and there is
		// nothing to select, so the click scrubs rather than clearing anything.
		if clipBandRect.contains(point) {
			drag = .scrub
			onScrub?(t)
			return
		}

		if event.modifierFlags.contains(.shift) {
			drag = .pending(anchor: t)
			pending = (t, t)
			onPendingChange?(pending)
			return
		}

		if lanesRect.contains(point), let clip = clip(at: t) {
			selectedClip = clip.id
			onSelectClip?(clip.id)
		}
		drag = .scrub
		onScrub?(t)
	}

	/// ⌥ pressed or let go in the middle of a drag changes what the mark is
	/// aiming at, so it has to change what is drawn as well.
	public override func flagsChanged(with event: NSEvent) {
		if drag != nil { needsDisplay = true }
		super.flagsChanged(with: event)
	}

	public override func mouseDragged(with event: NSEvent) {
		let point = convert(event.locationInWindow, from: nil)
		let t = snap(time(forX: point.x))
		autoscroll(toward: point.x)
		if NSEvent.modifierFlags.contains(.option) { needsDisplay = true }

		switch drag {
		case .scrub:
			onScrub?(t)
		case .pending(let anchor):
			pending = (anchor, t)
			onPendingChange?(pending)
		case .trim(let id, let edge, let other):
			let (start, end) = edge == .start ? (min(t, other - minimumClip), other) : (other, max(t, other + minimumClip))
			onEditClip?(id, start, end, false)
		case .move(let id, let grabOffset, let length):
			let start = max(0, t - grabOffset)
			onEditClip?(id, start, start + length, false)
		case .offset(let startOffset, let startTime):
			// Not snapped: an alignment is finer than a frame, which is the
			// whole reason this control exists.
			let delta = time(forX: point.x) - startTime
			onOffsetChange?(startOffset + delta, false)
		case .overview:
			jumpFromOverview(point.x)
		case nil:
			break
		}
	}

	public override func mouseUp(with event: NSEvent) {
		let point = convert(event.locationInWindow, from: nil)
		let t = snap(time(forX: point.x))
		switch drag {
		case .trim(let id, let edge, let other):
			let (start, end) = edge == .start ? (min(t, other - minimumClip), other) : (other, max(t, other + minimumClip))
			onEditClip?(id, start, end, true)
		case .move(let id, let grabOffset, let length):
			let start = max(0, t - grabOffset)
			onEditClip?(id, start, start + length, true)
		case .offset(let startOffset, let startTime):
			onOffsetChange?(startOffset + (time(forX: point.x) - startTime), true)
		default:
			break
		}
		drag = nil
	}

	/// The nearest moment the talking starts or stops, if one is close enough
	/// to be what was meant.
	func speechEdge(near t: Double) -> Double? {
		let edges = document?.transcript.edges ?? []
		guard !edges.isEmpty else { return nil }
		let tolerance = secondsPerPoint * 12
		let nearest = edges.min { abs($0 - t) < abs($1 - t) }
		guard let nearest, abs(nearest - t) <= tolerance else { return nil }
		return max(0, nearest)
	}

	/// Never zero-length: a clip nobody can see is a clip nobody can grab back.
	private var minimumClip: Double { max(secondsPerPoint * 4, 0.02) }

	private func autoscroll(toward x: CGFloat) {
		if x < 20 { scroll(by: max(-30, x - 20)) }
		else if x > bounds.width - 20 { scroll(by: min(30, x - (bounds.width - 20))) }
	}

	private func jumpFromOverview(_ x: CGFloat) {
		let t = Double(x / bounds.width) * duration
		onScrub?(t)
		scrollTime = t - Double(bounds.width) * secondsPerPoint / 2
		clampScroll()
		needsDisplay = true
	}

	/// Where the pointer's time actually lands.
	///
	/// Holding ⌥ aims at the speech instead of at the grid: the mark goes to
	/// where the talking starts or stops, which is what somebody trimming
	/// against a waveform is looking for and what they would otherwise find by
	/// zooming in and squinting. Only when there are words to aim at, and only
	/// within a dozen points of the pointer — further away than that and it
	/// would be moving the mark somewhere nobody pointed.
	private func snap(_ t: Double) -> Double {
		if NSEvent.modifierFlags.contains(.option), let edge = speechEdge(near: t) {
			snapped = edge
			return edge
		}
		snapped = nil
		let grid = document?.grid ?? .none
		// Only snap when a frame is wider than a couple of points. Zoomed in
		// past that, the operator is placing a mark against the audio and the
		// grid would be the thing fighting them.
		guard grid.hasGrid, grid.frameDuration / secondsPerPoint > 2 else { return max(0, t) }
		return max(0, grid.snap(t))
	}

	private func clip(at t: Double) -> Clip? {
		// Last first, so the most recently added of two overlapping clips is
		// the one that answers a click — which is the one somebody just made.
		document?.take.clips.last { $0.contains(t) }
	}

	/// The clip whose *bar* is under the pointer.
	///
	/// Different from ``clip(at:)`` once clips overlap: down in the waveform
	/// lanes several of them cover the same seconds and the newest wins, but in
	/// the band each one has a row of its own and the pointer is unambiguously
	/// on one of them. Using the time-only answer up here would select a clip
	/// somebody can see they did not click.
	private func clipBar(at point: NSPoint) -> Clip? {
		guard clipBandRect.contains(point), let clips = document?.take.clips else { return nil }
		guard let color = lane(at: point) else { return nil }
		let t = time(forX: point.x)
		return clips.last { $0.color == color && $0.contains(t) }
	}

	/// The colour of the bar under the pointer, if the pointer is on the band.
	///
	/// Reported so that clicking an empty stretch of a lane switches to that
	/// colour: the bars are the lanes, and pointing at one should be a way of
	/// choosing it.
	public func lane(at point: NSPoint) -> ClipColor? {
		guard clipBandRect.contains(point) else { return nil }
		let lanes = document?.take.lanes ?? []
		let row = Int((point.y - rulerHeight) / clipRowHeight)
		guard row >= 0, row < lanes.count else { return nil }
		return lanes[row]
	}

	private func clipEdge(at point: NSPoint) -> (id: Clip.ID, edge: Drag.Edge, other: Double)? {
		guard point.y > rulerHeight, point.y < bounds.height - overviewHeight,
		      let clips = document?.take.clips else { return nil }
		for clip in clips.reversed() {
			if abs(x(for: clip.start) - point.x) <= grabSlop { return (clip.id, .start, clip.end) }
			if abs(x(for: clip.end) - point.x) <= grabSlop { return (clip.id, .end, clip.start) }
		}
		return nil
	}

	// MARK: - Renaming on the bar

	private var editor: NSTextField?
	private(set) var editingClip: Clip.ID?

	/// Opens a field over the clip's bar, holding its name.
	///
	/// The *name*, not the slug — the slug is derived from it and updates the
	/// moment the name is committed, so typing "Intro" here leaves `intro` in
	/// the file without anybody having to know that. A slug somebody wants to
	/// choose by hand is edited in the table, where it is a column of its own.
	/// `proposing` puts a suggested name in the field instead of the clip's own,
	/// selected, so that it is one keystroke to keep and one to type over.
	/// Nothing is written until somebody presses Return: a proposal that
	/// committed itself would be a rename nobody asked for, and this is the
	/// only place a name from a model ever reaches a take.
	public func beginRenaming(_ clip: Clip, proposing: String? = nil) {
		endRenaming(commit: true)
		let field = NSTextField(frame: barRect(for: clip).insetBy(dx: -1, dy: -2))
		field.stringValue = proposing ?? clip.name
		field.placeholderString = clip.slug
		field.font = NSFont.systemFont(ofSize: 11)
		field.textColor = Theme.text
		field.backgroundColor = Theme.background
		field.drawsBackground = true
		field.isBordered = true
		field.bezelStyle = .squareBezel
		field.focusRingType = .none
		field.delegate = self
		addSubview(field)
		editor = field
		editingClip = clip.id
		selectedClip = clip.id
		onSelectClip?(clip.id)
		window?.makeFirstResponder(field)
		field.currentEditor()?.selectAll(nil)
	}

	/// Puts a better proposal in the open rename editor — **only** if it is open
	/// on this clip and still says exactly what was put there.
	///
	/// The guard is the whole method. Something worked out half a second after
	/// the field opened may improve what is in it, and may not put itself in
	/// front of what somebody has begun to type. Returns whether it did.
	@discardableResult
	public func repropose(_ proposal: String, for clip: Clip.ID, replacing untouched: String) -> Bool {
		guard editingClip == clip, let editor, editor.stringValue == untouched,
		      proposal != untouched else { return false }
		editor.stringValue = proposal
		editor.currentEditor()?.selectAll(nil)
		return true
	}

	/// For the tests: what the rename editor is showing, and typing into it —
	/// which is a keystroke a test may not dispatch, since an unclaimed one
	/// reaches `NSResponder` and beeps on somebody's machine.
	var renamingText: String? { editor?.stringValue }

	func setRenamingTextForTest(_ typed: String) { editor?.stringValue = typed }

	/// Closes the editor. `commit` false is escape, which leaves the name alone.
	@discardableResult
	public func endRenaming(commit: Bool) -> Bool {
		guard let editor, let id = editingClip else { return false }
		let text = editor.stringValue
		self.editor = nil
		self.editingClip = nil
		editor.delegate = nil
		editor.removeFromSuperview()
		window?.makeFirstResponder(self)
		if commit { onRenameInPlace?(id, text) }
		needsDisplay = true
		return true
	}

	public override func menu(for event: NSEvent) -> NSMenu? {
		let point = convert(event.locationInWindow, from: nil)
		let t = time(forX: point.x)
		guard point.y > rulerHeight, point.y < bounds.height - overviewHeight else { return nil }
		let hit = clipBar(at: point) ?? clip(at: t) ?? clipEdge(at: point).flatMap { edge in
			document?.take.clips.first { $0.id == edge.id }
		}
		if let hit {
			selectedClip = hit.id
			onSelectClip?(hit.id)
		}
		return contextMenu?(hit?.id, max(0, t))
	}

	public override func resetCursorRects() {
		super.resetCursorRects()
		guard let clips = document?.take.clips else { return }
		let rect = NSRect(x: 0, y: rulerHeight, width: bounds.width,
		                  height: bounds.height - rulerHeight - overviewHeight)
		for clip in clips {
			for edge in [clip.start, clip.end] {
				let ex = x(for: edge)
				guard ex > -grabSlop, ex < bounds.width + grabSlop else { continue }
				addCursorRect(NSRect(x: ex - grabSlop, y: rect.minY, width: grabSlop * 2, height: rect.height),
				              cursor: .resizeLeftRight)
			}
		}
	}
}


extension TimelineView: NSTextFieldDelegate {
	/// Return commits, escape abandons. Both are handled here rather than
	/// through the field's action, because escape never reaches an action.
	public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
		switch selector {
		case #selector(NSResponder.insertNewline(_:)):
			return endRenaming(commit: true)
		case #selector(NSResponder.cancelOperation(_:)):
			return endRenaming(commit: false)
		default:
			return false
		}
	}

	/// Clicking elsewhere keeps what was typed. Losing a rename because the
	/// pointer moved is the kind of thing that makes people stop trusting an
	/// editor.
	public func controlTextDidEndEditing(_ notification: Notification) {
		endRenaming(commit: true)
	}
}
