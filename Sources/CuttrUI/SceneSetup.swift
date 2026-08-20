import AppKit

/// Which scene is being worked on, and how long it runs while somebody works.
///
/// Behind the scene's name in the bar, on the same terms as a take's video and
/// audio: choosing which scene, making another one, and setting the length the
/// stage plays are all setting-up. None of them is true of a moment — the clock
/// and the play button are — and the third is not even written to the file: a
/// scene plays for as long as the overlay using it says, and this is only the
/// length of the rehearsal.
@MainActor
public final class SceneSetup: NSView {

	public var onScene: ((String) -> Void)?
	public var onNewScene: (() -> Void)?
	public var onLength: ((Double) -> Void)?

	private let scenes = NSPopUpButton()
	private let create = NSButton()
	private let length = NSTextField(string: "4")
	private var names: [String] = []

	public override init(frame: NSRect) {
		super.init(frame: frame)

		scenes.target = self
		scenes.action = #selector(pickScene)
		scenes.controlSize = .small
		scenes.font = Theme.mono
		scenes.translatesAutoresizingMaskIntoConstraints = false
		scenes.widthAnchor.constraint(greaterThanOrEqualToConstant: 190).isActive = true

		create.title = "New Scene…"
		create.bezelStyle = .rounded
		create.controlSize = .small
		create.font = NSFont.systemFont(ofSize: 11)
		create.target = self
		create.action = #selector(makeScene)

		length.font = Theme.mono
		length.target = self
		length.action = #selector(setLength)
		length.translatesAutoresizingMaskIntoConstraints = false
		length.widthAnchor.constraint(equalToConstant: 52).isActive = true
		length.toolTip = "How long the scene runs while you work on it. "
			+ "Not written to the file — a scene plays for as long as the overlay using it."

		let rows = NSStackView(views: [
			row("scene", scenes),
			row("", create),
			row("runs for", length, unit("seconds")),
		])
		rows.orientation = .vertical
		rows.alignment = .leading
		rows.spacing = 8
		rows.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
		rows.translatesAutoresizingMaskIntoConstraints = false
		addSubview(rows)
		NSLayoutConstraint.activate([
			rows.topAnchor.constraint(equalTo: topAnchor),
			rows.bottomAnchor.constraint(equalTo: bottomAnchor),
			rows.leadingAnchor.constraint(equalTo: leadingAnchor),
			rows.trailingAnchor.constraint(equalTo: trailingAnchor),
		])
	}

	@available(*, unavailable) required init?(coder: NSCoder) { nil }

	private func row(_ key: String, _ controls: NSView...) -> NSStackView {
		let label = NSTextField(labelWithString: key)
		label.font = Theme.monoSmall
		label.textColor = Theme.dimText
		label.alignment = .right
		label.translatesAutoresizingMaskIntoConstraints = false
		label.widthAnchor.constraint(equalToConstant: 56).isActive = true

		let stack = NSStackView(views: [label] + controls)
		stack.orientation = .horizontal
		stack.spacing = 8
		stack.alignment = .centerY
		return stack
	}

	private func unit(_ text: String) -> NSTextField {
		let label = NSTextField(labelWithString: text)
		label.font = Theme.monoSmall
		label.textColor = Theme.faintText
		return label
	}

	// MARK: - State in

	public func show(names: [String], current: String, length: Double) {
		if names != self.names {
			self.names = names
			scenes.removeAllItems()
			scenes.addItems(withTitles: names)
		}
		if let index = names.firstIndex(of: current) { scenes.selectItem(at: index) }
		if window?.firstResponder !== self.length.currentEditor() {
			self.length.stringValue = String(format: "%g", length)
		}
	}

	// MARK: - Actions

	@objc private func pickScene() {
		guard let title = scenes.titleOfSelectedItem else { return }
		onScene?(title)
	}

	@objc private func makeScene() { onNewScene?() }

	@objc private func setLength() {
		guard let value = Double(length.stringValue), value > 0 else { return }
		onLength?(value)
	}
}
