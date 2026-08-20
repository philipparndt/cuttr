import AppKit
import CuttrKit

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
		/// The folder it is in, shown dim and truncated at the head.
		///
		/// The single most useful column in the list, and the one ours was
		/// missing: two takes called `take-1` are told apart by where they are
		/// and by nothing else.
		public var path: String
		public var kind: Theme.Kind
		/// A take is drawn under the project it belongs to.
		public var indented: Bool
		/// Whether this is the document the window is already showing.
		public var isCurrent: Bool
		/// What to do about it. `nil` for a document whose file has gone.
		public var open: (() -> Void)?
		/// Said instead of the path when the file is not where it was.
		public var missing: Bool

		public init(name: String, path: String, kind: Theme.Kind,
		            indented: Bool = false, isCurrent: Bool = false,
		            missing: Bool = false, open: (() -> Void)?) {
			self.name = name
			self.path = path
			self.kind = kind
			self.indented = indented
			self.isCurrent = isCurrent
			self.missing = missing
			self.open = open
		}

		/// The hue that stands for this document, derived from its name.
		///
		/// The same derivation speakers use — `Speaker.color(of:)`, which is
		/// FNV-1a written out rather than `hashValue`, because Swift seeds
		/// `Hashable` per process and a project that is violet this morning and
		/// green this afternoon is a colour nobody trusts. Reused rather than
		/// copied: one hash, one palette, two lists that agree.
		public var hue: NSColor { Theme.base(Speaker.color(of: name)) }
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
		popover.show(relativeTo: inside(rect, of: view), of: view, preferredEdge: .maxY)
		switcher.focus()
	}

	/// Keeps the panel inside the window it belongs to.
	///
	/// A popover is centred on the middle of the rectangle it is given and is
	/// clamped to the *screen*, not to the window — so one hung under a capsule
	/// that starts eighty points in went off the window's left edge and sat on
	/// the desktop. The rectangle is nudged right by however much it takes, and
	/// no further: the beak has to stay on the half of the capsule that opened
	/// it, so the nudge stops twelve points short of that half's own edge.
	static func inside(_ rect: NSRect, of view: NSView) -> NSRect {
		guard view.window != nil else { return rect }
		// The window's left edge, in the view's own coordinates.
		let edge = view.convert(NSPoint(x: 0, y: 0), from: nil).x
		let wanted = edge + Switcher.width / 2 + 8
		guard rect.midX < wanted else { return rect }
		var moved = rect
		moved.origin.x = min(rect.maxX - 12, rect.origin.x + (wanted - rect.midX))
		return moved
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
			let ground = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 360))
			ground.wantsLayer = true
			// The darkest ground, so the panel reads as belonging to the window
			// rather than as a sheet laid on top of it.
			ground.layer?.backgroundColor = Theme.background.cgColor

			// A visible field, so what is typed is on screen and obviously a
			// filter — rather than an invisible jump-to-match to be guessed at.
			// Named for what to do with it rather than for what it is. There is
			// no `>` or `:` syntax here to teach — inventing one would be a
			// feature rather than a label — so it teaches the two keys that
			// matter.
			field.placeholderString = "Type to filter  \u{00B7}  \u{21A9} to open"
			field.font = NSFont.systemFont(ofSize: 12)
			field.delegate = self
			field.focusRingType = .none
			field.drawsBackground = false
			field.isBezeled = false
			field.translatesAutoresizingMaskIntoConstraints = false

			table.dataSource = self
			table.delegate = self
			table.rowHeight = Self.rowHeight
			table.backgroundColor = .clear
			table.gridStyleMask = []
			table.headerView = nil
			table.intercellSpacing = NSSize(width: 0, height: 0)
			table.selectionHighlightStyle = .regular
			table.addTableColumn(NSTableColumn(identifier: .init("document")))
			table.target = self
			// A single click, not a double one. This is a switcher, not a file
			// browser: pointing at a row *is* the choice, and a list where
			// clicking a row does nothing is the bug this control shipped with.
			table.action = #selector(take)
			let scroll = TableScroll.fitting(table)
			scroll.drawsBackground = false
			scroll.translatesAutoresizingMaskIntoConstraints = false

			for view in [field, scroll] as [NSView] { ground.addSubview(view) }
			NSLayoutConstraint.activate([
				field.topAnchor.constraint(equalTo: ground.topAnchor, constant: 7),
				field.leadingAnchor.constraint(equalTo: ground.leadingAnchor, constant: 8),
				field.trailingAnchor.constraint(equalTo: ground.trailingAnchor, constant: -8),

				scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 6),
				scroll.leadingAnchor.constraint(equalTo: ground.leadingAnchor),
				scroll.trailingAnchor.constraint(equalTo: ground.trailingAnchor),
				scroll.bottomAnchor.constraint(equalTo: ground.bottomAnchor, constant: -6),
			])
			view = ground
			resize()
		}

		func focus() {
			view.window?.makeFirstResponder(field)
			selectFirstDocument()
		}

		/// One line of text and a little, which is what a row of a list you are
		/// scanning should be.
		static let rowHeight: CGFloat = 26
		/// Narrow enough to sit inside the window it belongs to. It was 560,
		/// which hung off the left edge onto the desktop when anchored under a
		/// capsule that starts eighty points in.
		static let width: CGFloat = 380

		/// Height follows the content up to a cap, so a short list is a short
		/// popover rather than a tall one mostly full of nothing.
		private func resize() {
			let content = CGFloat(rows.count) * Self.rowHeight + 44
			preferredContentSize = NSSize(width: Self.width,
			                              height: min(max(content, 110), 560))
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

		/// For the tests: the list itself, to ask what a click is wired to.
		var tableForTesting: NSTableView? { table }

		/// For the tests: choose a row without an `NSEvent` — a synthesised one
		/// that nothing handles walks up the responder chain and beeps.
		func selectForTesting(_ row: Int) {
			guard row >= 0, row < rows.count else { return }
			table.selectRowIndexes([row], byExtendingSelection: false)
		}

		func chooseForTesting() { take() }

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
			ChosenRow.make(in: tableView)
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
				view.isFirst = row == 0
				view.needsDisplay = true
				return view
			case .entry(let entry):
				let view = (tableView.makeView(withIdentifier: .init("entry"), owner: self)
					as? EntryCell)
					?? { let made = EntryCell(); made.identifier = .init("entry"); return made }()
				view.entry = entry
				view.isChosen = row == tableView.selectedRow
				view.needsDisplay = true
				return view
			}
		}
	}

	/// The selected row, which in a list already carrying a colour per document
	/// is a *lift* rather than a slab.
	///
	/// `MarkedRow` — the rule everywhere else in this program — fills the row
	/// and puts an accent mark down its leading edge. Here the leading edge is
	/// already spoken for by the document's own hue, and a full-width grey bar
	/// over a list of coloured rails is the loudest thing on the panel for the
	/// least information in it. So the ground barely lifts and the rail brightens
	/// instead; the cell does that part, since it is the one holding the colour.
	final class ChosenRow: NSTableRowView {
		override func drawSelection(in dirtyRect: NSRect) {
			guard selectionHighlightStyle != .none else { return }
			NSColor.white.withAlphaComponent(0.07).setFill()
			bounds.fill()
		}

		override var isEmphasized: Bool {
			get { false }
			set { _ = newValue }
		}

		static func make(in table: NSTableView) -> NSTableRowView {
			if let found = table.makeView(withIdentifier: identifier, owner: nil) as? ChosenRow {
				return found
			}
			let made = ChosenRow()
			made.identifier = identifier
			return made
		}

		private static let identifier = NSUserInterfaceItemIdentifier("switcher-row")
	}

	/// A group heading: grey, semibold, and separated from the group above it by
	/// a hairline — except at the very top, where there is nothing to separate
	/// it from.
	final class HeadingCell: NSTableCellView {
		var title = ""
		var isFirst = false

		override var isFlipped: Bool { true }

		override func draw(_ dirtyRect: NSRect) {
			if !isFirst {
				Theme.rule.setFill()
				NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
			}
			let text = NSAttributedString(string: title, attributes: [
				.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
				.foregroundColor: Theme.faintText,
			])
			text.draw(at: NSPoint(x: 12, y: bounds.height - text.size().height - 4))
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
		var isChosen = false

		private static let rail: CGFloat = 3
		private static let leading: CGFloat = 13
		private static let indent: CGFloat = 16
		private static let trailing: CGFloat = 12

		override func draw(_ dirtyRect: NSRect) {
			guard let entry else { return }
			// A hue per document rather than one colour for every row, so the
			// list can be scanned before it is read. Full strength for the one
			// selected, a little back for the rest.
			entry.hue.withAlphaComponent(isChosen ? 1 : 0.7).setFill()
			NSRect(x: 0, y: 0, width: Self.rail, height: bounds.height).fill()

			let x = Self.leading + (entry.indented ? Self.indent : 0)
			let name = NSAttributedString(string: entry.name, attributes: [
				.font: NSFont.systemFont(ofSize: 13,
				                         weight: entry.isCurrent ? .semibold : .regular),
				.foregroundColor: entry.open == nil ? Theme.faintText : Theme.text,
			])
			let size = name.size()
			name.draw(at: NSPoint(x: x, y: bounds.midY - size.height / 2))

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
			let left = x + ceil(size.width) + 12
			let available = bounds.maxX - Self.trailing - left
			guard available > 30 else { return }
			detail.draw(in: NSRect(x: left, y: bounds.midY - detail.size().height / 2,
			                       width: available, height: detail.size().height))
		}
	}
}
