import AppKit

/// A pane with a heading that folds it away.
///
/// The column beside the picture holds three things — the clips, the anchors,
/// the grade — and only one of them is usually the thing being worked on. A
/// grade is decided once and then left alone; the clip list is where the work
/// is. Dragging dividers to make room is fiddly and forgotten; folding is one
/// click and the pane comes back the size it was.
///
/// The heading is a button and looks like one on hover, because a thing that
/// responds to a click and never says so is a thing nobody clicks.
@MainActor
public final class FoldingPane: NSView {

	public let content: NSView
	/// Folded now?
	public private(set) var folded = false
	/// Changed by a click or by the keyboard. The window uses it to let the
	/// other panes take the room back.
	public var onFold: ((Bool) -> Void)?

	private let chevron = NSImageView()
	private let label = NSTextField(labelWithString: "")
	private let head = NSView()
	public static let headHeight: CGFloat = 24
	private var contentHeight: NSLayoutConstraint?

	public init(_ title: String, content: NSView, accessory: NSView? = nil) {
		self.content = content
		super.init(frame: .zero)
		wantsLayer = true
		layer?.backgroundColor = Theme.panel.cgColor

		label.stringValue = title.uppercased()
		label.font = Theme.heading
		label.textColor = Theme.faintText

		head.wantsLayer = true
		head.layer?.backgroundColor = Theme.background.cgColor

		for view in [chevron, label] as [NSView] {
			view.translatesAutoresizingMaskIntoConstraints = false
			head.addSubview(view)
		}
		NSLayoutConstraint.activate([
			chevron.leadingAnchor.constraint(equalTo: head.leadingAnchor, constant: 8),
			chevron.centerYAnchor.constraint(equalTo: head.centerYAnchor),
			chevron.widthAnchor.constraint(equalToConstant: 12),
			label.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: 6),
			label.centerYAnchor.constraint(equalTo: head.centerYAnchor),
		])
		if let accessory {
			accessory.translatesAutoresizingMaskIntoConstraints = false
			head.addSubview(accessory)
			NSLayoutConstraint.activate([
				accessory.trailingAnchor.constraint(equalTo: head.trailingAnchor, constant: -8),
				accessory.centerYAnchor.constraint(equalTo: head.centerYAnchor),
			])
		}

		for view in [head, content] as [NSView] {
			view.translatesAutoresizingMaskIntoConstraints = false
			addSubview(view)
		}
		NSLayoutConstraint.activate([
			head.topAnchor.constraint(equalTo: topAnchor),
			head.leadingAnchor.constraint(equalTo: leadingAnchor),
			head.trailingAnchor.constraint(equalTo: trailingAnchor),
			head.heightAnchor.constraint(equalToConstant: Self.headHeight),

			content.topAnchor.constraint(equalTo: head.bottomAnchor),
			content.leadingAnchor.constraint(equalTo: leadingAnchor),
			content.trailingAnchor.constraint(equalTo: trailingAnchor),
			content.bottomAnchor.constraint(equalTo: bottomAnchor),
		])
		setChevron()
	}

	@available(*, unavailable) required init?(coder: NSCoder) { nil }

	/// Folded, a pane is its heading and nothing else — a required constraint,
	/// so a split view cannot give it room it does not want.
	public func fold(_ folded: Bool, tell: Bool = true) {
		guard folded != self.folded else { return }
		self.folded = folded
		content.isHidden = folded
		if folded {
			let height = heightAnchor.constraint(equalToConstant: Self.headHeight)
			height.priority = .required
			height.isActive = true
			contentHeight = height
		} else {
			contentHeight?.isActive = false
			contentHeight = nil
		}
		setChevron()
		if tell { onFold?(folded) }
	}

	public func toggle() { fold(!folded) }

	private func setChevron() {
		chevron.image = NSImage(
			systemSymbolName: folded ? "chevron.right" : "chevron.down",
			accessibilityDescription: folded ? "folded" : "open")?
			.withSymbolConfiguration(.init(pointSize: 9, weight: .semibold)
				.applying(.init(paletteColors: [Theme.dimText])))
	}

	// MARK: - Clicking it

	public override func mouseDown(with event: NSEvent) {
		let place = convert(event.locationInWindow, from: nil)
		guard head.frame.contains(place) else {
			super.mouseDown(with: event)
			return
		}
		toggle()
	}

	/// The heading, for the tests and for anything that wants to know how tall
	/// a folded pane is.
	var headingFrame: NSRect { head.frame }
}
