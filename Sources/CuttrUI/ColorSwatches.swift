import AppKit
import CuttrKit

/// The six lane colours, in a row.
///
/// In the window's bar, because that is the scope of the thing: which lane the
/// next cut goes on is true of the whole window. The timeline draws every lane,
/// the words pane cuts on to one, and the mark key marks on one — so on the
/// clips pane's heading, where this used to be, it was a window-level choice
/// living in one of four panes and gone from the screen whenever that pane was
/// folded away.
///
/// A row of swatches rather than only a menu item on a clip that already
/// exists, because a colour is chosen *before* the cut as often as after it:
/// somebody working through alternate takes picks rose, marks four of them,
/// picks green, marks the keepers.
@MainActor
public final class ColorSwatches: NSView {

	/// A swatch was clicked: this colour is the one the next cut gets.
	public var onChoose: ((ClipColor) -> Void)?

	private var buttons: [NSButton] = []

	public override init(frame: NSRect) {
		super.init(frame: frame)

		for color in ClipColor.allCases {
			let button = NSButton(frame: .zero)
			button.title = ""
			button.isBordered = false
			button.wantsLayer = true
			button.layer?.backgroundColor = Theme.base(color).cgColor
			button.layer?.cornerRadius = 3
			button.layer?.borderColor = NSColor.white.cgColor
			button.toolTip = "\(color.title) — the lane the next clip you cut goes on"
			button.target = self
			button.action = #selector(clicked(_:))
			button.tag = ClipColor.allCases.firstIndex(of: color) ?? 0
			button.translatesAutoresizingMaskIntoConstraints = false
			button.widthAnchor.constraint(equalToConstant: 12).isActive = true
			button.heightAnchor.constraint(equalToConstant: 12).isActive = true
			buttons.append(button)
		}

		let row = NSStackView(views: buttons)
		row.orientation = .horizontal
		row.spacing = 4
		row.translatesAutoresizingMaskIntoConstraints = false
		addSubview(row)
		NSLayoutConstraint.activate([
			row.topAnchor.constraint(equalTo: topAnchor),
			row.bottomAnchor.constraint(equalTo: bottomAnchor),
			row.leadingAnchor.constraint(equalTo: leadingAnchor),
			row.trailingAnchor.constraint(equalTo: trailingAnchor),
		])
	}

	@available(*, unavailable) required init?(coder: NSCoder) { nil }

	/// Which swatch is ringed: the current colour, which is the selected clip's
	/// when there is one and the pending choice when there is not.
	public func setColor(_ color: ClipColor) {
		for (index, button) in buttons.enumerated() {
			button.layer?.borderWidth = ClipColor.allCases[index] == color ? 2 : 0
		}
	}

	@objc private func clicked(_ sender: NSButton) {
		guard sender.tag < ClipColor.allCases.count else { return }
		onChoose?(ClipColor.allCases[sender.tag])
	}
}
