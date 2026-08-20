import AppKit

/// The list that drops out of the capsule: what is open, what was open before,
/// and a field to type at.
///
/// One list with two ways in. Clicking a half of the capsule anchors it under
/// that half; `⇧⌘P` opens the same thing from the keyboard, which is why the
/// capsule prints that key rather than a chevron nobody can press.
///
/// A popover rather than a menu, because a menu cannot hold a text field — and
/// typing is the point. With four documents open a menu is fine; with thirty
/// takes in a project, typing three letters is the only thing that stays fast.
@MainActor
public enum DocumentSwitcher {

	/// One row.
	public struct Entry {
		public var name: String
		/// Where it is on disk, shown dim and truncated at the head.
		public var path: String
		public var kind: Theme.Kind
		/// What to do about it. `nil` for a document whose file has gone.
		public var open: (() -> Void)?
		/// Said instead of the path when the file is not where it was.
		public var missing: Bool

		public init(name: String, path: String, kind: Theme.Kind,
		            missing: Bool = false, open: (() -> Void)?) {
			self.name = name
			self.path = path
			self.kind = kind
			self.missing = missing
			self.open = open
		}
	}

	/// A heading and the rows under it.
	public struct Group {
		public var title: String
		public var entries: [Entry]

		public init(_ title: String, _ entries: [Entry]) {
			self.title = title
			self.entries = entries
		}
	}

	private static var showing: NSPopover?
	private static var controller: Switcher?

	/// Puts it under a part of a view — a half of the capsule — with the beak
	/// pointing up at it.
	public static func show(_ groups: [Group], from view: NSView, rect: NSRect,
	                        onClose: (() -> Void)? = nil) {
		if let showing, showing.isShown {
			showing.close()
			DocumentSwitcher.showing = nil
			return
		}
		let switcher = Switcher(groups)
		let popover = NSPopover()
		popover.contentViewController = switcher
		popover.behavior = .transient
		popover.appearance = NSAppearance(named: .darkAqua)
		popover.delegate = switcher
		switcher.onClose = onClose
		showing = popover
		controller = switcher
		popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
		switcher.focus()
	}

	public static func close() {
		showing?.close()
		showing = nil
	}

	/// For the tests: type into the open one and say what is listed.
	static func filterForTesting(_ text: String) -> [String] {
		controller?.setFilter(text)
		return controller?.shownForTesting ?? []
	}

	/// Matched on what somebody would type: the letters in order, not
	/// necessarily together, so `mt1` finds `mia-take-1`.
	static func matches(_ wanted: String, in text: String) -> Bool {
		let lowered = text.lowercased()
		var here = lowered.startIndex
		for character in wanted.lowercased() where character != " " {
			guard let found = lowered[here...].firstIndex(of: character) else { return false }
			here = lowered.index(after: found)
		}
		return true
	}

	// MARK: - The thing itself

	final class Switcher: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
	                      NSSearchFieldDelegate, NSPopoverDelegate {

		/// A row is a heading or a document. Headings are not selectable, which
		/// is what makes the arrow keys walk documents only.
		enum Row {
			case heading(String)
			case entry(Entry)
		}

		var onClose: (() -> Void)?
		private let groups: [Group]
		private var rows: [Row] = []
		private let field = NSSearchField()
		private let table = KeyTable()

		init(_ groups: [Group]) {
			self.groups = groups
			super.init(nibName: nil, bundle: nil)
			rebuild(filter: "")
		}

		@available(*, unavailable) required init?(coder: NSCoder) { nil }

		override func loadView() {
			let ground = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 360))
			ground.wantsLayer = true
			ground.layer?.backgroundColor = Theme.panel.cgColor

			// A visible field, so what is typed is on screen and obviously a
			// filter — rather than an invisible jump-to-match to be guessed at.
			field.placeholderString = "Search a project or a take"
			field.font = NSFont.systemFont(ofSize: 13)
			field.delegate = self
			field.focusRingType = .none
			field.translatesAutoresizingMaskIntoConstraints = false

			table.dataSource = self
			table.delegate = self
			table.rowHeight = 26
			table.backgroundColor = .clear
			table.gridStyleMask = []
			table.headerView = nil
			table.intercellSpacing = NSSize(width: 0, height: 0)
			table.selectionHighlightStyle = .regular
			table.addTableColumn(NSTableColumn(identifier: .init("document")))
			table.target = self
			table.doubleAction = #selector(take)
			let scroll = TableScroll.fitting(table)
			scroll.drawsBackground = false
			scroll.translatesAutoresizingMaskIntoConstraints = false

			for view in [field, scroll] as [NSView] { ground.addSubview(view) }
			NSLayoutConstraint.activate([
				field.topAnchor.constraint(equalTo: ground.topAnchor, constant: 10),
				field.leadingAnchor.constraint(equalTo: ground.leadingAnchor, constant: 10),
				field.trailingAnchor.constraint(equalTo: ground.trailingAnchor, constant: -10),

				scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 8),
				scroll.leadingAnchor.constraint(equalTo: ground.leadingAnchor),
				scroll.trailingAnchor.constraint(equalTo: ground.trailingAnchor),
				scroll.bottomAnchor.constraint(equalTo: ground.bottomAnchor, constant: -8),
			])
			view = ground
			resize()
		}

		func focus() {
			view.window?.makeFirstResponder(field)
			selectFirstDocument()
		}

		/// Height follows the content up to a cap, so a short list is a short
		/// popover rather than a tall one mostly full of nothing.
		private func resize() {
			let content = CGFloat(rows.count) * 26 + 58
			preferredContentSize = NSSize(width: 560, height: min(max(content, 120), 460))
		}

		private func rebuild(filter: String) {
			rows = []
			for group in groups {
				let kept = filter.isEmpty ? group.entries : group.entries.filter {
					matches(filter, in: $0.name) || matches(filter, in: $0.path)
				}
				// A heading with nothing under it is a heading about nothing.
				guard !kept.isEmpty else { continue }
				rows.append(.heading(group.title))
				rows += kept.map { Row.entry($0) }
			}
		}

		func setFilter(_ text: String) {
			if field.stringValue != text { field.stringValue = text }
			rebuild(filter: text)
			table.reloadData()
			resize()
			selectFirstDocument()
		}

		var shownForTesting: [String] {
			rows.map {
				switch $0 {
				case .heading(let title): return "# " + title
				case .entry(let entry): return entry.name
				}
			}
		}

		private func isHeading(_ index: Int) -> Bool {
			guard index >= 0, index < rows.count else { return false }
			if case .heading = rows[index] { return true }
			return false
		}

		private func selectFirstDocument() {
			guard let first = rows.indices.first(where: { !isHeading($0) }) else {
				table.deselectAll(nil)
				return
			}
			table.selectRowIndexes([first], byExtendingSelection: false)
			table.scrollRowToVisible(first)
		}

		private func move(by offset: Int) {
			guard !rows.isEmpty else { return }
			var here = table.selectedRow
			repeat {
				here += offset
				if here < 0 || here >= rows.count { return }
			} while isHeading(here)
			table.selectRowIndexes([here], byExtendingSelection: false)
			table.scrollRowToVisible(here)
		}

		@objc private func take() {
			let row = table.selectedRow
			guard row >= 0, row < rows.count, case .entry(let entry) = rows[row],
			      let open = entry.open
			else { return }
			DocumentSwitcher.close()
			open()
		}

		// MARK: - Typing

		func controlTextDidChange(_ notification: Notification) {
			setFilter(field.stringValue)
		}

		func control(_ control: NSControl, textView: NSTextView,
		             doCommandBy selector: Selector) -> Bool {
			switch selector {
			case #selector(NSResponder.moveDown(_:)): move(by: 1); return true
			case #selector(NSResponder.moveUp(_:)): move(by: -1); return true
			case #selector(NSResponder.insertNewline(_:)): take(); return true
			case #selector(NSResponder.cancelOperation(_:)): DocumentSwitcher.close(); return true
			default: return false
			}
		}

		func popoverDidClose(_ notification: Notification) { onClose?() }

		// MARK: - The list

		func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

		func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
			MarkedRow.make(in: tableView)
		}

		func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
			!isHeading(row)
		}

		func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
		               row: Int) -> NSView? {
			guard row < rows.count else { return nil }
			switch rows[row] {
			case .heading(let title):
				let view = (tableView.makeView(withIdentifier: .init("heading"), owner: self)
					as? HeadingCell)
					?? { let made = HeadingCell(); made.identifier = .init("heading"); return made }()
				view.title = title
				view.needsDisplay = true
				return view
			case .entry(let entry):
				let view = (tableView.makeView(withIdentifier: .init("entry"), owner: self)
					as? EntryCell)
					?? { let made = EntryCell(); made.identifier = .init("entry"); return made }()
				view.entry = entry
				view.needsDisplay = true
				return view
			}
		}
	}

	/// A group heading: grey, semibold, small.
	final class HeadingCell: NSTableCellView {
		var title = ""

		override func draw(_ dirtyRect: NSRect) {
			(title as NSString).draw(
				at: NSPoint(x: 13, y: bounds.midY - 6),
				withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .semibold),
				                 .foregroundColor: Theme.faintText])
		}
	}

	/// One document, on one line: a rail of its kind's colour flush against the
	/// leading edge, the name, and its path in the far column.
	///
	/// The rail rather than a lettered square. Initials never say anything the
	/// name beside them does not, and on one line instead of two twice as many
	/// documents fit — while the paths, right-aligned in a fixed face, line up
	/// into a column that can be read down.
	final class EntryCell: NSTableCellView {
		var entry: Entry?

		override func draw(_ dirtyRect: NSRect) {
			guard let entry else { return }
			Theme.color(entry.kind).setFill()
			NSRect(x: 0, y: 0, width: 3, height: bounds.height).fill()

			let name = NSAttributedString(string: entry.name, attributes: [
				.font: NSFont.systemFont(ofSize: 13, weight: .semibold),
				.foregroundColor: entry.open == nil ? Theme.dimText : Theme.text,
			])
			let size = name.size()
			name.draw(at: NSPoint(x: 13, y: bounds.midY - size.height / 2))

			// A fixed face, right-aligned, truncated at the *head*: the tail of
			// a path is what says which one this is, and `/Volumes/500G/…` never
			// is. A file that has moved says so instead — offering a path that
			// opens nothing is worse than saying there is nothing to open.
			let paragraph = NSMutableParagraphStyle()
			paragraph.alignment = .right
			paragraph.lineBreakMode = .byTruncatingHead
			let detail = NSAttributedString(
				string: entry.missing ? "missing" : entry.path,
				attributes: [
					.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
					.foregroundColor: entry.missing ? Theme.playhead : Theme.faintText,
					.paragraphStyle: paragraph,
				])
			let left = 13 + ceil(size.width) + 12
			let available = bounds.maxX - 12 - left
			guard available > 30 else { return }
			detail.draw(in: NSRect(x: left, y: bounds.midY - detail.size().height / 2,
			                       width: available, height: detail.size().height))
		}
	}
}
