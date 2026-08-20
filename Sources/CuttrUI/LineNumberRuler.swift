import AppKit

/// Line numbers down the left of the project file, and a mark on the one the
/// cursor is in.
///
/// The parser says `line 34`. Without a gutter that sentence is an instruction
/// to count, and the answer to "where is line 34" should not be arithmetic.
///
/// An `NSRulerView`, which is AppKit's own answer to this: the scroll view keeps
/// it in step with the text without anything here watching for scrolls, and it
/// takes its width out of the scroll view rather than out of the text.
@MainActor
public final class LineNumberRuler: NSRulerView {

	private weak var text: NSTextView?

	public init(for text: NSTextView, in scroll: NSScrollView) {
		self.text = text
		super.init(scrollView: scroll, orientation: .verticalRuler)
		clientView = text
		ruleThickness = 42
	}

	@available(*, unavailable) required init(coder: NSCoder) {
		fatalError("not from a nib")
	}

	public override func drawHashMarksAndLabels(in rect: NSRect) {
		guard let text, let layout = text.layoutManager, let container = text.textContainer
		else { return }

		Theme.background.setFill()
		bounds.fill()
		Theme.rule.withAlphaComponent(0.5).setFill()
		NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()

		let content = text.string as NSString
		let inset = text.textContainerInset.height
		let visible = scrollView?.contentView.bounds ?? .zero
		let caret = text.selectedRange()
		let caretLine = content.lineRange(for: NSRange(location: min(caret.location, content.length),
		                                              length: 0))

		var number = 1
		var start = 0
		while start <= content.length {
			let line = content.lineRange(for: NSRange(location: start, length: 0))
			let glyphs = layout.glyphRange(forCharacterRange: line, actualCharacterRange: nil)
			let box = layout.boundingRect(forGlyphRange: glyphs, in: container)
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
