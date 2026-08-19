import AppKit
import CuttrKit

/// The controls that come back when somebody moves the mouse.
///
/// Full screen is for watching, so everything goes away — and then there is no
/// way to pause, or to see where you are, without leaving. Every player ever
/// made solves this the same way: the furniture returns when the pointer moves
/// and leaves again when it stops, because the gesture that means "I want the
/// controls" is reaching for them.
///
/// Drawn rather than assembled out of buttons: it is one bar with a scrubber in
/// it, over a picture, and a row of `NSButton`s over video acquires a grey
/// rectangle on every one of them.
@MainActor
public final class PlaybackControls: NSView {

	/// Where the programme is and how long it is.
	public var playhead: Double = 0 { didSet { needsDisplay = true } }
	public var duration: Double = 0 { didSet { needsDisplay = true } }
	public var isPlaying = false { didSet { needsDisplay = true } }

	public var onPlayPause: (() -> Void)?
	public var onScrub: ((Double) -> Void)?
	/// The way out, for somebody who took the mouse rather than the keyboard.
	public var onLeave: (() -> Void)?

	private let barHeight: CGFloat = 76
	private var dragging = false
	/// When the pointer last moved. The bar hides itself a few seconds after.
	private var idle: Timer?

	public override init(frame: NSRect) {
		super.init(frame: frame)
		wantsLayer = true
		alphaValue = 0
	}

	@available(*, unavailable) required init?(coder: NSCoder) { nil }

	public override var intrinsicContentSize: NSSize {
		NSSize(width: NSView.noIntrinsicMetric, height: barHeight)
	}

	// MARK: - Coming and going

	/// Shown, and hidden again when nothing has happened for a while.
	///
	/// While a drag is in progress it stays: somebody holding the scrubber is
	/// not idle, whatever the mouse has been doing.
	public func wake(for seconds: TimeInterval = 2.5) {
		idle?.invalidate()
		NSAnimationContext.runAnimationGroup { context in
			context.duration = 0.12
			animator().alphaValue = 1
		}
		NSCursor.unhide()
		idle = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
			MainActor.assumeIsolated { self?.rest() }
		}
	}

	private func rest() {
		guard !dragging else { wake(); return }
		NSAnimationContext.runAnimationGroup { context in
			context.duration = 0.4
			animator().alphaValue = 0
		}
	}

	public func sleep() {
		idle?.invalidate()
		idle = nil
		alphaValue = 0
	}

	// MARK: - Drawing

	private var track: NSRect {
		NSRect(x: 92, y: bounds.height / 2 - 3, width: max(1, bounds.width - 92 - 150), height: 6)
	}

	public override func draw(_ dirtyRect: NSRect) {
		// A ground under it, because a white scrubber over a white frame is
		// nothing at all.
		NSColor(calibratedWhite: 0, alpha: 0.55).setFill()
		bounds.fill()

		// Play or pause, drawn as the shape rather than as a button.
		let mark = NSRect(x: 34, y: bounds.height / 2 - 11, width: 22, height: 22)
		NSColor.white.setFill()
		if isPlaying {
			NSRect(x: mark.minX + 2, y: mark.minY, width: 6, height: mark.height).fill()
			NSRect(x: mark.minX + 13, y: mark.minY, width: 6, height: mark.height).fill()
		} else {
			let triangle = NSBezierPath()
			triangle.move(to: NSPoint(x: mark.minX + 3, y: mark.minY))
			triangle.line(to: NSPoint(x: mark.minX + 3, y: mark.maxY))
			triangle.line(to: NSPoint(x: mark.maxX, y: mark.midY))
			triangle.close()
			triangle.fill()
		}

		let track = self.track
		NSColor(calibratedWhite: 1, alpha: 0.25).setFill()
		NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3).fill()
		let done = duration > 0 ? CGFloat(min(1, max(0, playhead / duration))) : 0
		Theme.accent.setFill()
		NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY,
		                                 width: max(1, track.width * done), height: track.height),
		             xRadius: 3, yRadius: 3).fill()
		// The knob, big enough to hit.
		NSColor.white.setFill()
		NSBezierPath(ovalIn: NSRect(x: track.minX + track.width * done - 7,
		                            y: track.midY - 7, width: 14, height: 14)).fill()

		let clock = "\(Timecode.string(playhead))   \(Timecode.string(duration))"
		(clock as NSString).draw(
			at: NSPoint(x: track.maxX + 18, y: bounds.height / 2 - 7),
			withAttributes: [.font: Theme.mono, .foregroundColor: NSColor.white])
	}

	// MARK: - Pointing at it

	public override func mouseDown(with event: NSEvent) {
		let place = convert(event.locationInWindow, from: nil)
		wake()
		if place.x < 76 {
			onPlayPause?()
			return
		}
		dragging = true
		onScrub?(time(at: place.x))
	}

	public override func mouseDragged(with event: NSEvent) {
		guard dragging else { return }
		wake()
		onScrub?(time(at: convert(event.locationInWindow, from: nil).x))
	}

	public override func mouseUp(with event: NSEvent) {
		dragging = false
		wake()
	}

	private func time(at x: CGFloat) -> Double {
		let track = self.track
		guard track.width > 0, duration > 0 else { return 0 }
		return min(duration, max(0, Double((x - track.minX) / track.width) * duration))
	}

	/// For the tests: what a click at this point would ask for.
	func timeForTesting(at x: CGFloat) -> Double { time(at: x) }
}
