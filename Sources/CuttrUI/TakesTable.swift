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

	/// Somebody wants to work on a scene: the one named, or a new one when the
	/// name is `nil`.
	public var onScene: ((String?) -> Void)?
	/// Bring a scene in from another project.
	public var onAddScene: (() -> Void)?
	public var onRemoveScene: ((String) -> Void)?

	/// What a project is made of.
	///
	/// Takes and scenes in one list because they are the same kind of thing to
	/// somebody assembling a programme: material it draws on. A scene is not a
	/// file of its own — it lives in the project — but that is a fact about
	/// where it is stored, and putting it in a different corner of the window
	/// for that reason would be filing by implementation.
	private enum Row {
		case take(ComposeDocument.TakeEntry)
		case scene(String, parts: Int)
	}

	private let table = KeyTable()
	private var rows: [Row] = []
	/// The take whose name is being typed into, if any.
	///
	/// Renaming is asked for; it does not happen because somebody clicked
	/// twice. A permanently editable name column swallows the double-click —
	/// which here means "open this take" — and the field starts editing
	/// instead, so the gesture appears to do nothing.
	private var renaming: String?

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
		// A scene can be dragged from here onto the programme, the same as from
		// the library — this is a list of what the project is made of, and
		// dragging from it is how material gets used.
		table.setDraggingSourceOperationMask(.copy, forLocal: true)
		// Delete takes the selected row out of the *project* — the take file
		// itself is left alone, which is what the menu item beside it says and
		// why this is not a frightening key to press here.
		table.onKey = { [weak self] event in
			guard let self, isDelete(event), self.table.selectedRow >= 0 else { return false }
			self.removeSelected()
			return true
		}

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

		// Two verbs, two kinds of material, four items — rather than four
		// buttons, which is what it would have been by the time a project could
		// hold anything else. *Add* brings something that already exists into
		// this project; *New* makes one that does not exist yet.
		let add = menuButton("Add", [
			("Take…", #selector(addTapped), "Put an existing .cuttr take into this project"),
			("Scene…", #selector(addSceneTapped), "Copy a scene out of another project"),
		])
		let new = menuButton("New", [
			("Take…", #selector(newTapped), "Cut a new take from a video or audio file"),
			("Scene…", #selector(newSceneTapped), "Build an intro screen or a title card"),
		])

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

	/// A button that is a menu: the verb on the face of it, the kinds inside.
	///
	/// A pull-down rather than a pop-up, so the title stays the verb instead of
	/// becoming whatever was chosen last — nothing is being *selected* here,
	/// something is being done.
	private func menuButton(_ title: String, _ items: [(String, Selector, String)]) -> NSPopUpButton {
		let button = NSPopUpButton(frame: .zero, pullsDown: true)
		button.bezelStyle = .rounded
		button.controlSize = .small
		button.font = NSFont.systemFont(ofSize: 11)
		// The first item of a pull-down is its title and is never chosen.
		button.menu?.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
		for (name, action, hint) in items {
			let item = NSMenuItem(title: name, action: action, keyEquivalent: "")
			item.target = self
			item.toolTip = hint
			button.menu?.addItem(item)
		}
		return button
	}

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

	public func reload(_ takes: [ComposeDocument.TakeEntry], scenes: [String: Scene] = [:]) {
		rows = takes.map(Row.take)
			+ scenes.keys.sorted().map { Row.scene($0, parts: scenes[$0]?.parts.count ?? 0) }
		table.reloadData()
	}

	/// The take on a row, when that is what it is.
	private func take(_ row: Int) -> ComposeDocument.TakeEntry? {
		guard row >= 0, row < rows.count, case .take(let entry) = rows[row] else { return nil }
		return entry
	}

	private func sceneName(_ row: Int) -> String? {
		guard row >= 0, row < rows.count, case .scene(let name, _) = rows[row] else { return nil }
		return name
	}

	@objc private func addTapped() { onAdd?() }
	@objc private func newTapped() { onNew?() }
	@objc private func addSceneTapped() { onAddScene?() }
	@objc private func newSceneTapped() { onScene?(nil) }

	@objc private func nameCommitted(_ sender: NSTextField) {
		let row = table.row(for: sender)
		renaming = nil
		guard row >= 0, row < rows.count else { return }
		guard let entry = take(row) else { return }
		onRename?(entry.path, sender.stringValue)
	}

	public func beginRenaming(_ path: String) {
		guard let row = rows.firstIndex(where: {
			if case .take(let entry) = $0 { return entry.path == path } else { return false }
		}) else { return }
		renaming = path
		table.selectRowIndexes([row], byExtendingSelection: false)
		// Reloaded so the cell comes back editable, then handed the cursor.
		table.reloadData(forRowIndexes: [row], columnIndexes: [0])
		table.editColumn(0, row: row, with: nil, select: true)
	}

	@objc private func doubleClicked() {
		if let entry = take(table.clickedRow) { onOpen?(entry.url) }
		else if let name = sceneName(table.clickedRow) { onScene?(name) }
	}

	public override func menu(for event: NSEvent) -> NSMenu? {
		let row = table.row(at: table.convert(event.locationInWindow, from: nil))
		guard row >= 0, row < rows.count else { return nil }
		table.selectRowIndexes([row], byExtendingSelection: false)

		// A scene is not a file, so most of what can be done to a take makes no
		// sense for one: there is nothing to reveal in the Finder and nothing to
		// rename on disk.
		if sceneName(row) != nil {
			let menu = NSMenu()
			for (title, action) in [("Edit Scene…", #selector(openSelected)),
			                        ("Remove from Project", #selector(removeSelected))] {
				let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
				item.target = self
				menu.addItem(item)
			}
			return menu
		}

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
		return menu
	}

	@objc private func openSelected() {
		if let entry = take(table.selectedRow) { onOpen?(entry.url) }
		else if let name = sceneName(table.selectedRow) { onScene?(name) }
	}

	@objc private func renameSelected() {
		guard let entry = take(table.selectedRow) else { return }
		beginRenaming(entry.path)
	}

	@objc private func revealSelected() {
		guard let entry = take(table.selectedRow) else { return }
		NSWorkspace.shared.activateFileViewerSelecting([entry.url])
	}

	@objc private func removeSelected() {
		if let entry = take(table.selectedRow) {
			// The file is not deleted, only the reference: a take belongs to
			// whoever recorded it, not to this project.
			onRemove?(entry.path)
		} else if let name = sceneName(table.selectedRow) {
			// A scene *is* the project, so this one really does remove it.
			onRemoveScene?(name)
		}
	}

	public func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
		// Only scenes. A take is not something the programme can hold: what
		// goes on a timeline is a clip out of one, and those are in the library
		// below.
		guard let name = sceneName(row) else { return nil }
		let item = NSPasteboardItem()
		item.setString(name, forType: ProgrammePanel.sceneType)
		return item
	}

	// MARK: - Data source

	public func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

	public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
		guard let tableColumn, row < rows.count else { return nil }
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
		field.target = self
		field.action = #selector(nameCommitted(_:))

		switch rows[row] {
		case .take(let entry):
			// Editable only while a rename is actually in progress, so
			// double-click stays "open".
			field.isEditable = tableColumn.identifier.rawValue == "take" && entry.path == renaming
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
		case .scene(let name, let parts):
			field.isEditable = false
			switch tableColumn.identifier.rawValue {
			case "take":
				field.stringValue = name
				field.textColor = Theme.color(.scene)
			case "clips":
				field.stringValue = String(parts)
				field.textColor = Theme.dimText
			default:
				// Where it lives, which for a scene is the answer "here".
				field.stringValue = parts == 1 ? "scene · 1 part" : "scene · \(parts) parts"
				field.textColor = Theme.dimText
			}
		}
		return field
	}
}
