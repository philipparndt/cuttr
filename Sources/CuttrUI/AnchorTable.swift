import AppKit
import CuttrKit

/// The take's anchors, listed.
///
/// Rings over the picture say where a tracked point *is*; they cannot say what
/// exists, how far each one reaches, or how well it went — and a name that only
/// appears in a context menu is a name nobody can check against the project that
/// references it. So: a list, with the name editable in place, because the name
/// is the thing a project depends on.
@MainActor
public final class AnchorTable: NSView, NSTableViewDataSource, NSTableViewDelegate {

	public var onSelect: ((String?) -> Void)?
	public var onRename: ((String, String) -> Void)?
	/// Double-click: take me to where this was marked.
	public var onActivate: ((String) -> Void)?
	public var contextMenu: ((String?) -> NSMenu?)?

	private let table = NSTableView()
	private var rows: [(anchor: Anchor, samples: Int)] = []

	private enum Column: String, CaseIterable {
		case name, from, to, samples
		var title: String {
			switch self {
			case .name: return "Anchor"
			case .from: return "From"
			case .to: return "To"
			case .samples: return "Samples"
			}
		}
		var width: CGFloat {
			switch self {
			case .name: return 150
			case .from: return 78
			case .to: return 78
			case .samples: return 64
			}
		}
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

		for column in Column.allCases {
			let c = NSTableColumn(identifier: .init(column.rawValue))
			c.title = column.title
			c.width = column.width
			c.minWidth = 44
			table.addTableColumn(c)
		}

		table.columnAutoresizingStyle = .noColumnAutoresizing

		// Born with a real size, not zero.
		//
		// A scroll view laid out from an empty frame tiles its scrollers before
		// it knows which way round it is, and the horizontal one is drawn
		// briefly as a vertical bar until something — a scroll, a resize —
		// forces a second pass. Giving it plausible bounds up front means the
		// first tile is the right one.
		let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 280))
		table.frame = scroll.bounds
		scroll.documentView = table
		scroll.hasVerticalScroller = true
		scroll.hasHorizontalScroller = true
		scroll.autohidesScrollers = true
		scroll.drawsBackground = false
		scroll.tile()
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

	public func reload(_ anchors: [Anchor], paths: [String: AnchorPath], selected: String?) {
		// Not while a name is being typed: the document changes on every
		// keystroke, and a reload here would end the edit after one character.
		if window?.firstResponder is NSTextView, table.editedRow >= 0 { return }
		rows = anchors.map { ($0, paths[$0.name]?.samples.count ?? 0) }
		table.reloadData()
		if let selected, let index = rows.firstIndex(where: { $0.anchor.name == selected }) {
			table.selectRowIndexes([index], byExtendingSelection: false)
		}
	}

	public func beginRenaming(_ name: String) {
		guard let row = rows.firstIndex(where: { $0.anchor.name == name }) else { return }
		table.scrollRowToVisible(row)
		table.selectRowIndexes([row], byExtendingSelection: false)
		table.editColumn(0, row: row, with: nil, select: true)
	}

	@objc private func doubleClicked() {
		guard table.clickedRow >= 0, table.clickedRow < rows.count else { return }
		onActivate?(rows[table.clickedRow].anchor.name)
	}

	public override func menu(for event: NSEvent) -> NSMenu? {
		let point = table.convert(event.locationInWindow, from: nil)
		let row = table.row(at: point)
		if row >= 0, row < rows.count {
			table.selectRowIndexes([row], byExtendingSelection: false)
			return contextMenu?(rows[row].anchor.name)
		}
		return contextMenu?(nil)
	}

	// MARK: - Data source

	public func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

	public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
		guard let tableColumn, let column = Column(rawValue: tableColumn.identifier.rawValue),
		      row < rows.count else { return nil }
		let (anchor, samples) = rows[row]

		let field: NSTextField
		if let reused = tableView.makeView(withIdentifier: tableColumn.identifier, owner: self) as? NSTextField {
			field = reused
		} else {
			field = NSTextField()
			field.identifier = tableColumn.identifier
			field.isBordered = false
			field.drawsBackground = false
			field.lineBreakMode = .byTruncatingTail
			field.target = self
			field.action = #selector(fieldCommitted(_:))
		}
		field.isEditable = column == .name
		field.isSelectable = true
		field.font = Theme.mono

		switch column {
		case .name:
			field.stringValue = anchor.name
			// The same teal the ring is drawn in, so the list and the picture
			// read as one thing.
			field.textColor = Theme.base(.teal)
		case .from:
			field.stringValue = Timecode.string(anchor.from)
			field.textColor = Theme.dimText
		case .to:
			field.stringValue = Timecode.string(anchor.to)
			field.textColor = Theme.dimText
		case .samples:
			field.stringValue = samples == 0 ? "—" : String(samples)
			// Nothing solved is worth noticing: the anchor exists, the tracking
			// does not, and a project referencing it will draw nothing.
			field.textColor = samples == 0 ? Theme.playhead : Theme.dimText
		}
		return field
	}

	@objc private func fieldCommitted(_ sender: NSTextField) {
		let row = table.row(for: sender)
		guard row >= 0, row < rows.count else { return }
		onRename?(rows[row].anchor.name, sender.stringValue)
	}

	public func tableViewSelectionDidChange(_ notification: Notification) {
		let row = table.selectedRow
		onSelect?(row >= 0 && row < rows.count ? rows[row].anchor.name : nil)
	}
}
