import AppKit
import CuttrKit

/// Settings, which at the moment means the two API keys.
///
/// A sheet over whatever is in front, like every other dialog here, and a very
/// thin one: it reads and writes `~/.config/cuttr/config.yaml` and shows the
/// path it is writing, because the whole point of keeping settings in a file is
/// that somebody can go and look at it. There is no second place a key can be,
/// so "I set it and it did not take" has one answer — open that file.
///
/// A plain field rather than a secure one. The key is sitting in a text file in
/// the home directory either way, and a row of dots would only stop the person
/// who pasted it from checking that they pasted it right.
@MainActor
public final class SettingsSheet: NSViewController {

	private var settings = Settings()
	private var problem: String?
	private var fields: [MemeProvider: NSTextField] = [:]
	private let pathLabel = NSTextField(labelWithString: "")
	private let noteLabel = NSTextField(labelWithString: "")
	private var hosted: NSWindow?
	private let onClose: () -> Void

	public init(onClose: @escaping () -> Void = {}) {
		self.onClose = onClose
		super.init(nibName: nil, bundle: nil)
		// Read here rather than in `loadView`, so that a file which cannot be
		// read is a message in the sheet and not an empty form that silently
		// overwrites what is there.
		do { settings = try SettingsFile.read() } catch { problem = error.localizedDescription }
	}

	@available(*, unavailable) required init?(coder: NSCoder) { nil }

	public static func present(over view: NSView, onClose: @escaping () -> Void = {}) {
		guard let window = view.window else { return }
		let sheet = SettingsSheet(onClose: onClose)
		window.beginSheet(sheet.sheet()) { _ in }
	}

	private func sheet() -> NSWindow {
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 260),
		                      styleMask: [.titled], backing: .buffered, defer: false)
		window.contentViewController = self
		window.title = "Settings"
		window.isReleasedWhenClosed = false
		hosted = window
		return window
	}

	public override func loadView() {
		let root = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 260))
		root.wantsLayer = true
		root.layer?.backgroundColor = Theme.card.cgColor

		let heading = NSTextField(labelWithString: "Keys for searching memes")
		heading.font = Theme.bodyStrong
		heading.textColor = Theme.text

		var rows: [NSView] = [heading]
		for provider in MemeProvider.allCases {
			let label = NSTextField(labelWithString: provider.displayName)
			label.font = Theme.body
			label.textColor = Theme.text
			label.alignment = .right
			label.translatesAutoresizingMaskIntoConstraints = false
			label.widthAnchor.constraint(equalToConstant: 60).isActive = true

			let field = NSTextField()
			field.font = Theme.mono
			field.placeholderString = "paste a key, or leave empty"
			field.stringValue = settings.key(for: provider.settingsBlock) ?? ""
			// The environment wins, and a field somebody can type into that
			// changes nothing is a trap. Say which key is actually in use.
			let fromEnvironment = ProcessInfo.processInfo.environment[provider.environmentVariable]
			if let fromEnvironment, !fromEnvironment.isEmpty {
				field.isEnabled = false
				field.placeholderString = "\(provider.environmentVariable) is set; it wins"
			}
			fields[provider] = field

			let get = NSButton(title: "Get a key…", target: self, action: #selector(getKey))
			get.bezelStyle = .rounded
			get.controlSize = .small
			get.identifier = NSUserInterfaceItemIdentifier(provider.rawValue)

			let row = NSStackView(views: [label, field, get])
			row.orientation = .horizontal
			row.spacing = 8
			row.alignment = .centerY
			rows.append(row)
		}

		pathLabel.stringValue = SettingsFile.url().path
		pathLabel.font = Theme.monoSmall
		pathLabel.textColor = Theme.dimText
		pathLabel.lineBreakMode = .byTruncatingMiddle
		pathLabel.toolTip = "Edit this file directly if you would rather. It is read on every search."

		noteLabel.stringValue = problem ?? "Kept as text, so it can be read, edited and copied."
		noteLabel.font = Theme.body
		noteLabel.textColor = problem == nil ? Theme.dimText : Theme.base(.rose)
		noteLabel.lineBreakMode = .byWordWrapping
		noteLabel.maximumNumberOfLines = 2

		let stack = NSStackView(views: rows + [pathLabel, noteLabel])
		stack.orientation = .vertical
		stack.alignment = .leading
		stack.spacing = 10

		let save = NSButton(title: "Save", target: self, action: #selector(save))
		save.bezelStyle = .rounded
		save.keyEquivalent = "\r"
		let cancel = NSButton(title: "Cancel", target: self, action: #selector(close))
		cancel.bezelStyle = .rounded
		cancel.keyEquivalent = "\u{1b}"

		for view in [stack, save, cancel] as [NSView] {
			view.translatesAutoresizingMaskIntoConstraints = false
			root.addSubview(view)
		}
		NSLayoutConstraint.activate([
			stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
			stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
			stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),

			save.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
			save.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
			cancel.trailingAnchor.constraint(equalTo: save.leadingAnchor, constant: -8),
			cancel.bottomAnchor.constraint(equalTo: save.bottomAnchor),
		])
		for row in stack.arrangedSubviews where row is NSStackView {
			row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
		}
		// The size the sheet opens at, said in constraints as well as in the
		// window's frame.
		//
		// A window whose `contentViewController` is set takes its size from the
		// view's own fitting size, and a view laid out entirely with edge
		// constraints has none worth having: the meme panel came up as a column
		// one search field wide, with the grid and the buttons squeezed into a
		// sliver. The preferred size is what it wants, the minimums are what it
		// will not go below, and both are needed.
		preferredContentSize = NSSize(width: 520, height: 260)
		let wide = root.widthAnchor.constraint(equalToConstant: 520)
		let tall = root.heightAnchor.constraint(equalToConstant: 260)
		for wish in [wide, tall] {
			wish.priority = NSLayoutConstraint.Priority(250)
			wish.isActive = true
		}
		NSLayoutConstraint.activate([
			root.widthAnchor.constraint(greaterThanOrEqualToConstant: 420),
			root.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
		])
		view = root
	}

	@objc private func getKey(_ sender: NSButton) {
		guard let provider = sender.identifier.flatMap({ MemeProvider(rawValue: $0.rawValue) }),
		      let url = URL(string: provider.keyPage) else { return }
		NSWorkspace.shared.open(url)
	}

	@objc func save() {
		for (provider, field) in fields where field.isEnabled {
			settings.setKey(field.stringValue, for: provider.settingsBlock)
		}
		do {
			try SettingsFile.save(settings)
		} catch {
			noteLabel.stringValue = error.localizedDescription
			noteLabel.textColor = Theme.base(.rose)
			return
		}
		close()
	}

	@objc private func close() {
		guard let window = view.window else { return }
		// A sheet over a window, or — when every window has been closed — a
		// window of its own, which closes itself.
		if let parent = window.sheetParent { parent.endSheet(window) } else { window.close() }
		hosted = nil
		// So that a panel which said "no key" can go and look again without
		// being reopened.
		onClose()
	}

	/// For the tests: type a key in without a keyboard.
	func set(_ key: String, for provider: MemeProvider) {
		fields[provider]?.stringValue = key
	}
}
