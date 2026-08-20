import AppKit

/// Line numbers down the left of the project file, and a mark on the line the
/// cursor is in.
///
/// The parser says `line 34`. Without a gutter that sentence is an instruction
/// to count, and the answer to "where is line 34" should not be arithmetic.
///
/// A plain view beside the scroll view rather than an `NSRulerView` inside it.
/// The ruler is AppKit's own answer to this and it is the one that was tried
/// first, but `NSScrollView` did not reserve its width when it tiled: measured,
/// the clip view came out `(0, 0, 1346, 814)` and the ruler `(0, 0, 42, 814)` —
/// the same origin, so the first forty-two points of every line were printed
/// underneath the numbers. Beside it, nothing can overlap: this view's width and
/// the scroll view's leading edge are one measurement, stated once, here.
@MainActor
public final class LineNumbers: NSView {

	public static let width: CGFloat = 42

	private weak var text: NSTextView?
	private weak var scroll: NSScrollView?
	private var watching: Any?

	public init(for text: NSTextView, in scroll: NSScrollView) {
		self.text = text
		self.scroll = scroll
		super.init(frame: .roomToLayOutIn)
		translatesAutoresizingMaskIntoConstraints = false
		wantsLayer = true
		layer?.backgroundColor = Theme.background.cgColor

		// The numbers have to move with the text, and a scroll is not a layout:
		// nothing else in this view tree is told about one.
		scroll.contentView.postsBoundsChangedNotifications = true
		watching = NotificationCenter.default.addObserver(
			forName: NSView.boundsDidChangeNotification,
			object: scroll.contentView, queue: .main
		) { [weak self] _ in
			MainActor.assumeIsolated { self?.needsDisplay = true }
		}
	}

	deinit {
		if let watching { NotificationCenter.default.removeObserver(watching) }
	}

	@available(*, unavailable) required init(coder: NSCoder) { fatalError("not from a nib") }

	public override var isFlipped: Bool { true }

	/// Redrawn when the caret moves, which the text view has to say.
	public func caretMoved() { needsDisplay = true }

	public override func draw(_ dirtyRect: NSRect) {
		Theme.background.setFill()
		bounds.fill()
		Theme.rule.withAlphaComponent(0.5).setFill()
		NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()

		guard let text, let layout = text.layoutManager, let container = text.textContainer,
		      let scroll
		else { return }

		let content = text.string as NSString
		let inset = text.textContainerInset.height
		let visible = scroll.contentView.bounds
		let caret = text.selectedRange()
		let caretLine = content.lineRange(
			for: NSRange(location: min(caret.location, content.length), length: 0))

		var number = 1
		var start = 0
		while start <= content.length {
			let line = content.lineRange(for: NSRange(location: start, length: 0))
			let glyphs = layout.glyphRange(forCharacterRange: line, actualCharacterRange: nil)
			let box = layout.boundingRect(forGlyphRange: glyphs, in: container)
			// This view is flipped and so is the text view, so a line's y is the
			// same measurement in both once the scroll offset is taken off.
			let y = box.minY + inset - visible.minY

			if y + box.height > 0, y < bounds.height {
				let here = line.location == caretLine.location
				let label = "\(number)" as NSString
				let attributes: [NSAttributedString.Key: Any] = [
					.font: Theme.monoSmall,
					.foregroundColor: here ? Theme.text : Theme.faintText,
				]
				let size = label.size(withAttributes: attributes)
				// Right-aligned, so the digits line up whatever the count is.
				label.draw(at: NSPoint(x: bounds.maxX - 8 - size.width,
				                       y: y + (box.height - size.height) / 2),
				           withAttributes: attributes)
				if here {
					Theme.accent.setFill()
					NSRect(x: bounds.maxX - 3, y: y + 1, width: 2,
					       height: max(1, box.height - 2)).fill()
				}
			}

			if NSMaxRange(line) == start { break }
			start = NSMaxRange(line)
			number += 1
			if line.length == 0 { break }
		}
	}
}
