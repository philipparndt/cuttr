import AppKit

/// The left edge of both windows: **what you are doing.**
///
/// One grammar, learned once. In the cutting window it is the clips, the
/// anchors, the words and the grade; in the composing window it is the editor,
/// the file and the picture. Same shape, same width, same place, and in both
/// cases exactly one of them has the room at a time.
///
/// That is not a saving of space so much as an admission of what was already
/// true. The cutting window's own comment said it: "only one of them is usually
/// the thing being worked on — a grade is decided once and left alone". Four
/// panes stacked down a column, each with a heading, each negotiating a height
/// with the other three, to show four things nobody looks at together.
///
/// Drawn rather than built out of `NSButton`s. A column of bordered buttons is a
/// column of grey rectangles, and the selected one has to be a *ground* behind
/// the icon rather than a ring around a control.
///
/// Monochrome on purpose. Hue in this program says what kind of thing something
/// is, and a rail is not a thing — it is the furniture that says where you are.
/// Colouring it would be spending the one signal that has a job on the one
/// element that does not need it.
@MainActor
public final class Rail: NSView {

	public struct Item {
		public var title: String
		public var symbol: String
		public var tip: String

		public init(_ title: String, _ symbol: String, _ tip: String) {
			self.title = title
			self.symbol = symbol
			self.tip = tip
		}
	}

	/// A different pane was asked for.
	public var onSelect: ((Int) -> Void)?

	/// The width both windows give it. Stated here because the rail is the only
	/// thing that has an opinion about how wide a rail is.
	public static let width: CGFloat = 54
	private static let itemHeight: CGFloat = 46

	private let items: [Item]
	private var images: [NSImage?] = []
	public private(set) var selected = 0
	/// Which one the pointer is over, so a thing that responds to a click says so.
	private var hovered: Int?

	public init(_ items: [Item]) {
		self.items = items
		super.init(frame: .roomToLayOutIn)
		// Off from the start. A view built at 0×0 whose autoresizing mask is
		// still on turns that zero frame into `width == 0` and `height == 0` at
		// required priority the moment it is laid out, and then anything with an
		// opinion about its size is half of an unsolvable system.
		translatesAutoresizingMaskIntoConstraints = false
		wantsLayer = true
		layer?.backgroundColor = Theme.background.cgColor

		// How wide a rail is, said once, by the rail.
		//
		// Not by either window: both of them would have to say it, and two
		// objects stating one dimension is how they come to disagree. A floor
		// rather than a law — see `asFloor` — because a window has no size until
		// it is given one, and a required width against a container of zero is
		// half of a system with no solution.
		widthAnchor.constraint(equalToConstant: Self.width).asFloor.isActive = true
		images = items.map { item in
			NSImage(systemSymbolName: item.symbol, accessibilityDescription: item.title)?
				.withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
		}
		for (index, item) in items.enumerated() {
			addToolTip(rect(for: index), owner: item.tip as NSString, userData: nil)
		}
	}

	@available(*, unavailable) required init?(coder: NSCoder) { nil }

	public override var isFlipped: Bool { true }

	// MARK: - Where each one is

	private func rect(for index: Int) -> NSRect {
		NSRect(x: 0, y: 6 + CGFloat(index) * Self.itemHeight,
		       width: Self.width, height: Self.itemHeight)
	}

	private func index(at point: NSPoint) -> Int? {
		items.indices.first { rect(for: $0).contains(point) }
	}

	// MARK: - Drawing

	public override func draw(_ dirtyRect: NSRect) {
		Theme.background.setFill()
		bounds.fill()

		for index in items.indices {
			let slot = rect(for: index)
			let isSelected = index == selected

			// The selected one is a ground, not a ring: this is a place you are,
			// and a place is somewhere lit rather than something outlined.
			if isSelected {
				Theme.card.setFill()
				NSBezierPath(roundedRect: slot.insetBy(dx: 4, dy: 3),
				             xRadius: 6, yRadius: 6).fill()
				// And a mark down the near edge, which is the one part of this
				// that reads at a glance from across the desk.
				Theme.accent.setFill()
				NSBezierPath(roundedRect: NSRect(x: 0, y: slot.minY + 8, width: 2,
				                                height: slot.height - 16),
				             xRadius: 1, yRadius: 1).fill()
			} else if index == hovered {
				NSColor(calibratedWhite: 1, alpha: 0.05).setFill()
				NSBezierPath(roundedRect: slot.insetBy(dx: 4, dy: 3),
				             xRadius: 6, yRadius: 6).fill()
			}

			let colour = isSelected ? Theme.text : Theme.dimText
			if let image = images[index]?.withSymbolConfiguration(
				.init(pointSize: 15, weight: .regular).applying(.init(paletteColors: [colour]))) {
				Theme.draw(image, in: NSRect(x: slot.minX, y: slot.minY + 6,
				                             width: slot.width, height: 18))
			}

			let title = items[index].title as NSString
			let attributes: [NSAttributedString.Key: Any] = [
				.font: NSFont.systemFont(ofSize: 9, weight: isSelected ? .semibold : .regular),
				.foregroundColor: colour,
			]
			let size = title.size(withAttributes: attributes)
			title.draw(at: NSPoint(x: slot.midX - size.width / 2, y: slot.minY + 27),
			           withAttributes: attributes)
		}
	}

	// MARK: - Clicking it

	public override func mouseDown(with event: NSEvent) {
		guard let index = index(at: convert(event.locationInWindow, from: nil)) else { return }
		select(index)
		onSelect?(index)
	}

	public override func updateTrackingAreas() {
		super.updateTrackingAreas()
		for area in trackingAreas { removeTrackingArea(area) }
		addTrackingArea(NSTrackingArea(
			rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow],
			owner: self, userInfo: nil))
	}

	public override func mouseMoved(with event: NSEvent) {
		let was = hovered
		hovered = index(at: convert(event.locationInWindow, from: nil))
		if hovered != was { needsDisplay = true }
	}

	public override func mouseExited(with event: NSEvent) {
		if hovered != nil { hovered = nil; needsDisplay = true }
	}

	/// Moves the mark without telling anybody — for the menu bar and the
	/// keyboard, which ask the window directly.
	public func select(_ index: Int) {
		guard index >= 0, index < items.count, index != selected else { return }
		selected = index
		needsDisplay = true
	}

	/// For the tests: what a click on the nth one does, without an `NSEvent`.
	///
	/// A synthesised event that nothing handles walks up the responder chain and
	/// makes the machine beep, on somebody's desk, in the middle of their day.
	func clickForTesting(_ index: Int) {
		select(index)
		onSelect?(index)
	}

	var countForTesting: Int { items.count }
}
