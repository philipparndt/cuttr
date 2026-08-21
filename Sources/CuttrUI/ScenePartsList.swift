import AppKit
import CuttrCompose

/// The parts of a scene, in the order they are drawn.
///
/// Back to front, which is the order they are in the file. A layers palette
/// usually puts the topmost at the top and this one deliberately does not: the
/// list is meant to be readable against `parts:` in the project file, and a
/// list that reverses it silently makes "the second part" mean two things.
@MainActor
public final class ScenePartsList: NSView, NSTableViewDataSource, NSTableViewDelegate {

	public var onSelect: ((Int?) -> Void)?
	public var onAdd: ((Scene.Part.Content) -> Void)?
	public var onRemove: ((Int) -> Void)?
	/// Which part, and how far to move it: −1 is one step towards the back.
	public var onReorder: ((Int, Int) -> Void)?

	private var scene = Scene()
	private let table = NSTableView()
	private let add = NSPopUpButton()
	private let remove = NSButton()
	private let back = NSButton()
	private let front = NSButton()

	private final class Target: NSObject {
		let run: () -> Void
		init(_ run: @escaping () -> Void) { self.run = run }
		@objc func fire(_ sender: Any?) { run() }
	}

	private var targets: [Target] = []

	public override init(frame: NSRect) {
		super.init(frame: frame)
		wantsLayer = true
		layer?.backgroundColor = Theme.panel.cgColor

		table.dataSource = self
		table.delegate = self
		table.rowHeight = 26
		table.backgroundColor = Theme.panel
		table.gridStyleMask = []
		table.headerView = nil
		table.selectionHighlightStyle = .regular
		table.intercellSpacing = NSSize(width: 0, height: 0)
		let column = NSTableColumn(identifier: .init("part"))
		column.width = 200
		table.addTableColumn(column)

		// A pull-down rather than a plus that guesses: the four kinds are the
		// whole vocabulary of a scene, and offering them by name is how
		// somebody finds out a background exists.
		add.pullsDown = true
		add.bezelStyle = .rounded
		add.controlSize = .small
		add.font = NSFont.systemFont(ofSize: 11)
		add.addItem(withTitle: "+")
		for (title, content) in [
			("Text", Scene.Part.Content.text("{{title}}", style: "title", tracking: 0)),
			("Shape", .shape(fill: .white, corner: 0, kind: .rectangle)),
			("Progress Bar", .bar(Scene.Bar(corner: 0.006))),
			("Credit Roll", .roll(Credits.emptyRoll)),
			("Spinner", .spinner(Spinner())),
			("Image…", .image("")),
			("Background", .background(Scene.Background(from: RGBA(hex: "#101418")!))),
		] as [(String, Scene.Part.Content)] {
			let item = NSMenuItem(title: title, action: #selector(Target.fire(_:)), keyEquivalent: "")
			let target = Target { [weak self] in self?.onAdd?(content) }
			targets.append(target)
			item.target = target
			add.menu?.addItem(item)
		}

		for (button, title, action) in [
			(remove, "−", { [weak self] in self?.act { $0.onRemove?($1) } }),
			(back, "↓", { [weak self] in self?.act { $0.onReorder?($1, -1) } }),
			(front, "↑", { [weak self] in self?.act { $0.onReorder?($1, 1) } }),
		] as [(NSButton, String, () -> Void)] {
			button.title = title
			button.bezelStyle = .rounded
			button.controlSize = .small
			button.font = NSFont.systemFont(ofSize: 11)
			let target = Target(action)
			targets.append(target)
			button.target = target
			button.action = #selector(Target.fire(_:))
		}
		back.toolTip = "Draw this one earlier — further back"
		front.toolTip = "Draw this one later — further forward"

		let buttons = NSStackView(views: [add, remove, back, front])
		buttons.orientation = .horizontal
		buttons.spacing = 4

		let scroll = TableScroll.fitting(table)
		let stack = NSStackView(views: [scroll, buttons])
		stack.orientation = .vertical
		stack.spacing = 6
		stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
		stack.translatesAutoresizingMaskIntoConstraints = false
		addSubview(stack)
		scroll.translatesAutoresizingMaskIntoConstraints = false
		NSLayoutConstraint.activate([
			stack.topAnchor.constraint(equalTo: topAnchor),
			stack.bottomAnchor.constraint(equalTo: bottomAnchor),
			stack.leadingAnchor.constraint(equalTo: leadingAnchor),
			stack.trailingAnchor.constraint(equalTo: trailingAnchor),
			scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16),
		])
	}

	@available(*, unavailable) required init?(coder: NSCoder) { nil }

	private func act(_ body: (ScenePartsList, Int) -> Void) {
		let row = table.selectedRow
		guard row >= 0, row < scene.parts.count else { return }
		body(self, row)
	}

	public func reload(_ scene: Scene, selected: Int?) {
		self.scene = scene
		table.reloadData()
		if let selected, selected < scene.parts.count {
			table.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
		} else {
			table.deselectAll(nil)
		}
	}

	// MARK: - The table

	public func numberOfRows(in tableView: NSTableView) -> Int { scene.parts.count }

	/// One rule for every list in this program: a selected row is a mark and a
	/// lighter ground, not a bar of saturated blue across it.
	public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
		MarkedRow.make(in: tableView)
	}

	public func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?,
	                      row: Int) -> NSView? {
		guard row < scene.parts.count else { return nil }
		let part = scene.parts[row]
		let kind: Theme.Kind
		let title: String
		switch part.content {
		case .text(let text, let style, _):
			kind = .text
			title = text.isEmpty ? "(no words)" : text + (style.map { "  ·  \($0)" } ?? "")
		case .shape(let fill, _, let shape):
			kind = .effect
			title = "\(shape.rawValue)  \(fill.hex)"
		case .bar(let bar):
			kind = .query
			title = "bar  \(bar.fill.hex)  \(bar.direction.rawValue)"
		case .spinner(let spinner):
			kind = .spinner
			title = "spinner  \(spinner.style.rawValue)"
		case .roll(let roll):
			kind = .text
			let names = roll.entries.reduce(0) { $0 + $1.names.count }
			title = "roll  \(roll.entries.count) blocks  ·  \(names) names"
		case .image(let file):
			kind = .clip
			title = file.isEmpty ? "image  (none chosen)" : "image  \((file as NSString).lastPathComponent)"
		case .frames(let sequence):
			kind = .clip
			title = "frames  \((sequence.pattern as NSString).lastPathComponent)"
				+ "  ·  \(Int(sequence.fps)) fps"
		case .component(let component):
			kind = .scene
			title = "component  \((component.file as NSString).lastPathComponent)"
		case .background(let background):
			kind = .scene
			title = background.to == nil
				? "background  \(background.from.hex)"
				: "background  \(background.from.hex) → \(background.to!.hex)"
		}

		let icon = NSImageView()
		icon.image = Theme.symbol(kind, size: 11)
		icon.imageScaling = .scaleProportionallyDown
		icon.translatesAutoresizingMaskIntoConstraints = false
		icon.widthAnchor.constraint(equalToConstant: 16).isActive = true

		let label = NSTextField(labelWithString: title)
		label.font = Theme.mono
		label.textColor = Theme.text
		label.lineBreakMode = .byTruncatingTail
		label.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1),
		                                              for: .horizontal)

		let keys = NSTextField(labelWithString: "\(part.keys.count)")
		keys.font = Theme.monoSmall
		keys.textColor = Theme.faintText
		keys.setContentHuggingPriority(.required, for: .horizontal)
		keys.toolTip = "keys"

		let row = NSStackView(views: [icon, label, keys])
		row.orientation = .horizontal
		row.spacing = 6
		row.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
		return row
	}

	public func tableViewSelectionDidChange(_ notification: Notification) {
		let row = table.selectedRow
		onSelect?(row >= 0 && row < scene.parts.count ? row : nil)
	}
}
