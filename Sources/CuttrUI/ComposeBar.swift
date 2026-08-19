import AppKit
import CuttrCompose

/// The strip above the preview: what the project is doing, and the two things
/// this window can do to it.
///
/// An `NSView` subclass that builds its own contents in `init`, rather than a
/// bare `NSView` assembled by the window controller. That is not a style
/// preference — the bare version did not draw at all: laid out, in the window,
/// not hidden, alpha 1, correct frames, and invisible. The same arrangement as
/// ``HeaderBar``, which works, so the composing window gets the same shape.
@MainActor
public final class ComposeBar: NSView {

	public var onRender: (() -> Void)?
	public var onReload: (() -> Void)?
	public var onMode: ((Int) -> Void)?

	private let renderButton = NSButton()
	private let reloadButton = NSButton()
	private let modes = NSSegmentedControl()
	private let statusLabel = NSTextField(labelWithString: "")
	private let progress = NSProgressIndicator()

	public override init(frame: NSRect) {
		super.init(frame: frame)
		wantsLayer = true
		layer?.backgroundColor = Theme.panel.cgColor

		configure(renderButton, "Render…", #selector(render))
		configure(reloadButton, "Reload", #selector(reload))
		reloadButton.toolTip = "Re-read the project file. It is also re-read whenever it changes on disk."

		progress.style = .bar
		progress.isIndeterminate = false
		progress.minValue = 0
		progress.maxValue = 1
		progress.isHidden = true
		progress.controlSize = .small

		statusLabel.font = Theme.mono
		statusLabel.textColor = Theme.dimText
		statusLabel.lineBreakMode = .byTruncatingTail

		// Three views, one at a time, each with the whole window.
		//
		// They were three panes side by side and none of them had room: a
		// timeline, a list of overlays and a picture in a third of a window
		// each. What they have in common is only that they are about the same
		// project, which is not a reason to look at them simultaneously.
		for (index, title) in ["Edit", "Text", "Preview"].enumerated() {
			modes.segmentCount = max(modes.segmentCount, index + 1)
			modes.setLabel(title, forSegment: index)
			modes.setWidth(66, forSegment: index)
		}
		modes.trackingMode = .selectOne
		modes.selectedSegment = 0
		modes.target = self
		modes.action = #selector(modeChanged)
		modes.toolTip = "⌘1 the editor · ⌘2 the file · ⌘3 the picture"

		// Three groups, in the three places a toolbar has: where you *are* on
		// the left, what is *happening* in the middle, what you can *do* on the
		// right. Render sitting next to the mode buttons made it look like a
		// fourth place to go.
		statusLabel.alignment = .center

		let navigation = row([modes])
		let middle = row([progress, statusLabel])
		let actions = row([renderButton, reloadButton])
		for stack in [navigation, middle, actions] { addSubview(stack) }

		// The middle group is centred on the window rather than on what is left
		// over, so the clock does not shuffle sideways as the buttons beside it
		// change width.
		let centred = middle.centerXAnchor.constraint(equalTo: centerXAnchor)
		centred.priority = .defaultHigh
		centred.isActive = true

		NSLayoutConstraint.activate([
			navigation.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
			navigation.centerYAnchor.constraint(equalTo: centerYAnchor),

			middle.centerYAnchor.constraint(equalTo: centerYAnchor),
			middle.leadingAnchor.constraint(
				greaterThanOrEqualTo: navigation.trailingAnchor, constant: 10),
			middle.trailingAnchor.constraint(
				lessThanOrEqualTo: actions.leadingAnchor, constant: -10),

			actions.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
			actions.centerYAnchor.constraint(equalTo: centerYAnchor),

			progress.widthAnchor.constraint(equalToConstant: 150),
		])
		statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
	}

	@available(*, unavailable) required init?(coder: NSCoder) { nil }

	private func row(_ views: [NSView]) -> NSStackView {
		let stack = NSStackView(views: views)
		stack.orientation = .horizontal
		stack.spacing = 6
		stack.alignment = .centerY
		stack.translatesAutoresizingMaskIntoConstraints = false
		return stack
	}

	private func configure(_ button: NSButton, _ title: String, _ action: Selector) {
		button.title = title
		button.bezelStyle = .rounded
		button.controlSize = .small
		button.font = NSFont.systemFont(ofSize: 11)
		button.target = self
		button.action = action
	}

	@objc private func render() { onRender?() }
	@objc private func reload() { onReload?() }
	@objc private func modeChanged() { onMode?(modes.selectedSegment) }

	public func setMode(_ index: Int) { modes.selectedSegment = index }

	// MARK: - State in

	public func setStatus(_ text: String) { statusLabel.stringValue = text }

	public func setEnabled(_ enabled: Bool) {
		renderButton.isEnabled = enabled
	}

	public func setProgress(_ fraction: Double?) {
		progress.isHidden = fraction == nil
		if let fraction { progress.doubleValue = fraction }
	}

	public func setRenderEnabled(_ enabled: Bool) { renderButton.isEnabled = enabled }
}
