import AppKit
import CuttrCompose
import CuttrKit

/// The takes a project draws on.
///
/// The project is the main thing somebody has open, so the material it is made
/// of belongs in front of them rather than in a list of paths inside a file.
/// What it shows beyond the name is the count of clips and, when there is one,
/// what went wrong — a moved take is the commonest fault in a project, and the
/// first anybody should hear of it is here rather than "no clip called intro".
@MainActor
public final class TakesTable: NSView, NSTableViewDataSource, NSTableViewDelegate {

	public var onOpen: ((URL) -> Void)?
	public var onRemove: ((String) -> Void)?
	public var onAdd: (() -> Void)?
	/// The name typed into the Take column: the file is renamed to match.
	public var onRename: ((String, String) -> Void)?
	public var onNew: (() -> Void)?

	private let table = NSTableView()
	private var rows: [ComposeDocument.TakeEntry] = []

	public override init(frame: NSRect) {
		super.init(frame: frame)
		wantsLayer = true
		layer?.backgroundColor = Theme.panel.cgColor

		table.dataSource = self
		table.delegate = self
		table.headerView = NSTableHeaderView()
		table.usesAlternatingRowBackgroundColors = true
		table.style = .plain
		table.rowHeight = 20
		table.backgroundColor = Theme.panel
		table.gridStyleMask = []
		table.target = self
		table.doubleAction = #selector(doubleClicked)

		for (identifier, title, width) in [("take", "Take", CGFloat(150)),
		                                   ("clips", "Clips", 52),
		                                   ("where", "Where", 240)] {
			let column = NSTableColumn(identifier: .init(identifier))
			column.title = title
			column.width = width
			column.minWidth = 44
			table.addTableColumn(column)
		}

		let scroll = TableScroll.make(table)

		let add = button("Add Take…", #selector(addTapped))
		add.toolTip = "Put an existing .cuttr take into this project"
		let new = button("New Take…", #selector(newTapped))
		new.toolTip = "Cut a new take from a video or audio file, and add it"

		let buttons = NSStackView(views: [add, new])
		buttons.orientation = .horizontal
		buttons.spacing = 6

		let stack = NSStackView(views: [scroll, buttons])
		stack.orientation = .vertical
		stack.spacing = 6
		stack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
		stack.translatesAutoresizingMaskIntoConstraints = false
		addSubview(stack)
		NSLayoutConstraint.activate([
			stack.topAnchor.constraint(equalTo: topAnchor),
			stack.bottomAnchor.constraint(equalTo: bottomAnchor),
			stack.leadingAnchor.constraint(equalTo: leadingAnchor),
			stack.trailingAnchor.constraint(equalTo: trailingAnchor),
		])
	}

	@available(*, unavailable) required init?(coder: NSCoder) { nil }

	private func button(_ title: String, _ action: Selector) -> NSButton {
		let button = NSButton()
		button.title = title
		button.bezelStyle = .rounded
		button.controlSize = .small
		button.font = NSFont.systemFont(ofSize: 11)
		button.target = self
		button.action = action
		return button
	}

	public func reload(_ takes: [ComposeDocument.TakeEntry]) {
		rows = takes
		table.reloadData()
	}

	@objc private func addTapped() { onAdd?() }
	@objc private func newTapped() { onNew?() }

	@objc private func nameCommitted(_ sender: NSTextField) {
		let row = table.row(for: sender)
		guard row >= 0, row < rows.count else { return }
		onRename?(rows[row].path, sender.stringValue)
	}

	public func beginRenaming(_ path: String) {
		guard let row = rows.firstIndex(where: { $0.path == path }) else { return }
		table.selectRowIndexes([row], byExtendingSelection: false)
		table.editColumn(0, row: row, with: nil, select: true)
	}

	@objc private func doubleClicked() {
		guard table.clickedRow >= 0, table.clickedRow < rows.count else { return }
		onOpen?(rows[table.clickedRow].url)
	}

	public override func menu(for event: NSEvent) -> NSMenu? {
		let row = table.row(at: table.convert(event.locationInWindow, from: nil))
		guard row >= 0, row < rows.count else { return nil }
		table.selectRowIndexes([row], byExtendingSelection: false)
		let entry = rows[row]
		let menu = NSMenu()
		for (title, action) in [("Open in a Tab", #selector(openSelected)),
		                        ("Rename…", #selector(renameSelected)),
		                        ("Reveal in Finder", #selector(revealSelected)),
		                        ("Remove from Project", #selector(removeSelected))] {
			let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
			item.target = self
			menu.addItem(item)
			if title == "Reveal in Finder" { menu.addItem(.separator()) }
		}
		_ = entry
		return menu
	}

	@objc private func openSelected() {
		guard table.selectedRow >= 0, table.selectedRow < rows.count else { return }
		onOpen?(rows[table.selectedRow].url)
	}

	@objc private func renameSelected() {
		guard table.selectedRow >= 0, table.selectedRow < rows.count else { return }
		beginRenaming(rows[table.selectedRow].path)
	}

	@objc private func revealSelected() {
		guard table.selectedRow >= 0, table.selectedRow < rows.count else { return }
		NSWorkspace.shared.activateFileViewerSelecting([rows[table.selectedRow].url])
	}

	@objc private func removeSelected() {
		guard table.selectedRow >= 0, table.selectedRow < rows.count else { return }
		// The file is not deleted, only the reference: a take belongs to
		// whoever recorded it, not to this project.
		onRemove?(rows[table.selectedRow].path)
	}

	// MARK: - Data source

	public func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

	public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
		guard let tableColumn, row < rows.count else { return nil }
		let entry = rows[row]
		let field = (tableView.makeView(withIdentifier: tableColumn.identifier, owner: self) as? NSTextField)
			?? {
				let field = NSTextField()
				field.identifier = tableColumn.identifier
				field.isBordered = false
				field.drawsBackground = false
				field.lineBreakMode = .byTruncatingHead
				return field
			}()
		field.font = Theme.mono
		// Only the name is typed into; the rest is what the file turned out to
		// be.
		field.isEditable = tableColumn.identifier.rawValue == "take"
		field.target = self
		field.action = #selector(nameCommitted(_:))

		switch tableColumn.identifier.rawValue {
		case "take":
			field.stringValue = entry.name
			field.textColor = entry.problem == nil ? Theme.clipStroke(.green) : Theme.playhead
		case "clips":
			field.stringValue = entry.problem == nil ? String(entry.clips) : "—"
			field.textColor = Theme.dimText
		default:
			field.stringValue = entry.problem ?? entry.path
			field.textColor = entry.problem == nil ? Theme.dimText : Theme.playhead
		}
		return field
	}
}
