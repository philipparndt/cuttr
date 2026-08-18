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

	private let renderButton = NSButton()
	private let reloadButton = NSButton()
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

		let stack = NSStackView(views: [renderButton, reloadButton, progress, statusLabel])
		stack.orientation = .horizontal
		stack.spacing = 6
		stack.alignment = .centerY
		stack.translatesAutoresizingMaskIntoConstraints = false
		addSubview(stack)
		NSLayoutConstraint.activate([
			stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
			stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
			stack.centerYAnchor.constraint(equalTo: centerYAnchor),
			progress.widthAnchor.constraint(equalToConstant: 150),
		])
		statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
	}

	@available(*, unavailable) required init?(coder: NSCoder) { nil }

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
