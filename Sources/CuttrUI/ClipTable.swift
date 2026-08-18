import AppKit
import CuttrKit

/// The clip list beside the picture.
///
/// Shown in time order, while the take keeps the order its file had. The two
/// disagree as soon as somebody cuts a clip out of the middle, and both are
/// right: a list read by a person wants to be in the order things happen, and a
/// file somebody arranged by hand should come back the way they left it.
@MainActor
public final class ClipTable: NSView, NSTableViewDataSource, NSTableViewDelegate {

	public var onSelect: ((Clip.ID?) -> Void)?
	public var onRename: ((Clip.ID, String) -> Void)?
	public var onSlugChange: ((Clip.ID, String) -> Void)?
	public var onNoteChange: ((Clip.ID, String) -> Void)?
	/// Tags, typed as a comma-separated list. Text, because a tag is text and
	/// this file is meant to be edited as text — a token field would be a nicer
	/// noun and a worse verb.
	public var onTagsChange: ((Clip.ID, String) -> Void)?
	public var onOrderChange: ((Clip.ID, String) -> Void)?
	/// A start or an end, typed in. The value is text because it is a timecode
	/// and may be nonsense; the controller parses it and ignores what it cannot
	/// read, which is what leaves the old value on screen.
	public var onTimeChange: ((Clip.ID, _ isStart: Bool, String) -> Void)?
	/// Right-click, on a row or on the empty space below them.
	public var contextMenu: ((Clip.ID?) -> NSMenu?)?
	/// Double-click: show me this one.
	public var onActivate: ((Clip.ID) -> Void)?

	private let table = NSTableView()
	private var rows: [Clip] = []

	private enum Column: String, CaseIterable {
		// Tags sit next to the name on purpose: they are the thing a project
		// selects on, and a column somebody has to scroll to find is a feature
		// they do not know exists.
		case slug, name, tags, start, end, duration, order, note
		var title: String {
			switch self {
			case .slug: return "Slug"
			case .name: return "Name"
			case .start: return "Start"
			case .end: return "End"
			case .duration: return "Length"
			case .tags: return "Tags"
			case .order: return "Order"
			case .note: return "Note"
			}
		}
		var width: CGFloat {
			switch self {
			case .slug: return 132
			case .name: return 180
			case .start: return 78
			case .end: return 78
			case .duration: return 66
			case .tags: return 150
			case .order: return 56
			case .note: return 150
			}
		}
		/// Length is the one that is not typed into: it is `end - start`, and a
		/// third editable field for two degrees of freedom is a field that
		/// contradicts the other two.
		var isEditable: Bool { self != .duration }
	}

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
		table.allowsMultipleSelection = false
		table.backgroundColor = Theme.panel
		table.gridStyleMask = []
		table.target = self
		table.doubleAction = #selector(doubleClicked)
		// The table must not eat the keys the timeline lives on. An operator
		// working at speed has the pointer on the waveform and the focus
		// wherever it last was, and `space` reaching a table view means the
		// selection changes instead of the tape rolling.
		table.refusesFirstResponder = false

		for column in Column.allCases {
			let c = NSTableColumn(identifier: .init(column.rawValue))
			c.title = column.title
			c.width = column.width
			c.minWidth = 50
			table.addTableColumn(c)
		}

		// Fixed column widths and a horizontal scroller. Without both, AppKit
		// squeezes every column to fit the pane and the ones on the right —
		// which is where tags and order are — become unreachable slivers.
		table.columnAutoresizingStyle = .noColumnAutoresizing

		// Scrollers declared before the document view, and nothing forced
		// afterwards.
		//
		// The previous attempt at this gave the scroll view a frame, forced the
		// table's frame to match it and then called `tile()`. All three fight
		// what the table is trying to do: with `noColumnAutoresizing` the table
		// sizes itself to the sum of its columns, and overriding that leaves the
		// scrollers tiled against a width that is about to change — which is
		// what drew the horizontal scroller as a stub in the corner.
		let scroll = NSScrollView()
		scroll.hasVerticalScroller = true
		scroll.hasHorizontalScroller = true
		scroll.autohidesScrollers = true
		scroll.drawsBackground = false
		scroll.documentView = table
		scroll.translatesAutoresizingMaskIntoConstraints = false
		addSubview(scroll)
		NSLayoutConstraint.activate([
			scroll.topAnchor.constraint(equalTo: topAnchor),
			scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
			scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
			scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
		])
	}

	@available(*, unavailable) required init?(coder: NSCoder) { nil }

	public func reload(_ clips: [Clip], selected: Clip.ID?) {
		// The row being typed into is not reloaded out from under the cursor.
		// The document changes on every keystroke of a rename — that is what
		// makes undo work — and a reload here would end the edit after one
		// character.
		if let editor = window?.firstResponder as? NSTextView, editor.delegate is NSTextField,
		   table.editedRow >= 0 {
			return
		}
		rows = clips.sorted { $0.start < $1.start }
		table.reloadData()
		if let selected, let index = rows.firstIndex(where: { $0.id == selected }) {
			table.selectRowIndexes([index], byExtendingSelection: false)
			table.scrollRowToVisible(index)
		} else if selected == nil {
			table.deselectAll(nil)
		}
	}

	/// Puts the cursor in a clip's name, which is what happens the moment one
	/// is created: cut, type the name, carry on.
	public func beginRenaming(_ id: Clip.ID) {
		guard let row = rows.firstIndex(where: { $0.id == id }),
		      let column = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == Column.name.rawValue })
		else { return }
		table.scrollRowToVisible(row)
		table.selectRowIndexes([row], byExtendingSelection: false)
		table.editColumn(column, row: row, with: nil, select: true)
	}

	/// The slug, for the menu item that edits it. A slug is a reference, so it
	/// is worth being able to set one deliberately rather than only by renaming.
	/// Puts the cursor in a clip's tags, for the menu item that does the same.
	public func beginEditingTags(_ id: Clip.ID) {
		edit(id, column: .tags)
	}

	public func beginEditingSlug(_ id: Clip.ID) {
		edit(id, column: .slug)
	}

	private func edit(_ id: Clip.ID, column: Column) {
		guard let row = rows.firstIndex(where: { $0.id == id }),
		      let index = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == column.rawValue })
		else { return }
		table.scrollRowToVisible(row)
		table.scrollColumnToVisible(index)
		table.selectRowIndexes([row], byExtendingSelection: false)
		table.editColumn(index, row: row, with: nil, select: true)
	}

	@objc private func doubleClicked() {
		guard table.clickedRow >= 0, table.clickedRow < rows.count else { return }
		onActivate?(rows[table.clickedRow].id)
	}

	// MARK: - Data source

	public func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

	public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
		guard let tableColumn, let column = Column(rawValue: tableColumn.identifier.rawValue),
		      row < rows.count else { return nil }
		let clip = rows[row]

		let identifier = tableColumn.identifier
		let field: NSTextField
		if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField {
			field = reused
		} else {
			field = NSTextField()
			field.identifier = identifier
			field.isBordered = false
			field.drawsBackground = false
			field.lineBreakMode = .byTruncatingTail
			field.target = self
			field.action = #selector(fieldCommitted(_:))
		}
		field.isEditable = column.isEditable
		field.isSelectable = true
		field.textColor = Theme.text
		field.font = column == .name || column == .note ? NSFont.systemFont(ofSize: 11) : Theme.mono

		switch column {
		case .slug:
			field.stringValue = clip.slug
			// The slug in the clip's own colour, so the list and the timeline
			// can be read against each other at a glance.
			field.textColor = Theme.base(clip.color)
		case .name:
			field.stringValue = clip.name
		case .start:
			field.stringValue = Timecode.string(clip.start)
			field.textColor = Theme.text
		case .end:
			field.stringValue = Timecode.string(clip.end)
			field.textColor = Theme.text
		case .duration:
			field.stringValue = Timecode.string(clip.duration)
			field.textColor = Theme.dimText
		case .tags:
			field.stringValue = clip.tags.joined(separator: ", ")
			// Placeholder rather than an empty cell, because "how do I tag
			// this" was not answerable from looking at it.
			field.placeholderString = "b-roll, keep"
			field.textColor = Theme.base(.amber)
		case .order:
			field.stringValue = String(clip.order)
			field.textColor = clip.order == Clip.defaultOrder ? Theme.dimText : Theme.text
		case .note:
			field.stringValue = clip.note ?? ""
			field.textColor = Theme.dimText
		}
		return field
	}

	@objc private func fieldCommitted(_ sender: NSTextField) {
		let row = table.row(for: sender)
		let columnIndex = table.column(for: sender)
		guard row >= 0, row < rows.count, columnIndex >= 0,
		      let column = Column(rawValue: table.tableColumns[columnIndex].identifier.rawValue)
		else { return }
		let id = rows[row].id
		switch column {
		case .name: onRename?(id, sender.stringValue)
		case .slug: onSlugChange?(id, sender.stringValue)
		case .note: onNoteChange?(id, sender.stringValue)
		case .start: onTimeChange?(id, true, sender.stringValue)
		case .end: onTimeChange?(id, false, sender.stringValue)
		case .tags: onTagsChange?(id, sender.stringValue)
		case .order: onOrderChange?(id, sender.stringValue)
		case .duration: break
		}
	}

	/// The row under the pointer, selected before the menu opens.
	///
	/// Right-clicking a row somebody has not selected and then choosing Delete
	/// should delete *that* row, and the only way to make that unambiguous is to
	/// select it first — so what the menu will act on is the thing that is
	/// highlighted while the menu is up.
	public override func menu(for event: NSEvent) -> NSMenu? {
		let point = table.convert(event.locationInWindow, from: nil)
		let row = table.row(at: point)
		if row >= 0, row < rows.count {
			table.selectRowIndexes([row], byExtendingSelection: false)
			return contextMenu?(rows[row].id)
		}
		return contextMenu?(nil)
	}

	public func tableViewSelectionDidChange(_ notification: Notification) {
		let row = table.selectedRow
		onSelect?(row >= 0 && row < rows.count ? rows[row].id : nil)
	}
}
