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
		/// The same, into a window of its own, for ⌥ held while choosing.
		/// `nil` falls back to ``open``.
		public var openAside: (() -> Void)?
		/// Said instead of the path when the file is not where it was.
		public var missing: Bool

		public init(name: String, path: String, kind: Theme.Kind,
		            indented: Bool = false, isCurrent: Bool = false,
		            missing: Bool = false, open: (() -> Void)?,
		            openAside: (() -> Void)? = nil) {
			self.name = name
			self.path = path
			self.kind = kind
			self.indented = indented
			self.isCurrent = isCurrent
			self.missing = missing
			self.open = open
			self.openAside = openAside
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

	/// Whether one is up right now.
	public static var isShowing: Bool { showing?.isShown == true }

	/// Puts it under a part of a view — a half of the capsule — with the beak
	/// pointing up at it. Says whether it managed to.
	///
	/// **Asking for the list gets the list.** This is not a toggle, and that is
	/// the fix rather than an omission.
	///
	/// It was one, and a toggle has to remember whether it is on. This one's
	/// memory was two static variables — and a `.transient` popover dismissed
	/// by a click outside it is closed by AppKit without ever coming through
	/// `close()`, so the memory went stale on its own. Every way of getting it
	/// wrong looks the same from the outside: the panel appears on every *other*
	/// press. Measured on a real project, `⇧⌘P` opened it, closed it, and then
	/// did nothing at all. There is nothing to remember now: anything already up
	/// is closed and a fresh one takes its place. Escape and a click anywhere
	/// outside put it away, which is what a popover does anyway.
	///
	/// The answer still matters, because the caller lights the half it is
	/// opening under *before* asking, and a light nobody puts out stays on.
	/// Every path out of here either shows a popover that will report its own
	/// closing, or runs `onClose` on the way out.
	@discardableResult
	public static func show(_ groups: [Group], from view: NSView, rect: NSRect,
	                        onClose: (() -> Void)? = nil) -> Bool {
		// Whatever is up goes, including one AppKit has already taken down and
		// not told anybody about.
		close()
		showing = nil
		controller = nil

		let switcher = Switcher(groups)
		let popover = NSPopover()
		popover.contentViewController = switcher
		popover.behavior = .transient
		popover.appearance = NSAppearance(named: .darkAqua)
		popover.delegate = switcher
		// Not animated, so `close()` is over by the time it returns and the
		// document chosen can be brought forward immediately afterwards.
		popover.animates = false
		switcher.onClose = onClose
		showing = popover
		controller = switcher
		popover.show(relativeTo: inside(rect, of: view), of: view, preferredEdge: .maxY)
		// `show(relativeTo:)` declines silently — an empty anchor rectangle is
		// enough to do it — and a popover that never appeared never reports a
		// closing either.
		guard popover.isShown else {
			showing = nil
			controller = nil
			onClose?()
			return false
		}
		switcher.focus()
		return true
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
		guard let popover = showing else { return }
		// Forgotten first, so the `popoverDidClose` this provokes does not come
		// back round through here.
		showing = nil
		controller = nil
		popover.close()
	}

	/// Called by a switcher that has closed, however it was closed.
	static func forget(_ switcher: Switcher) {
		guard controller === switcher else { return }
		showing = nil
		controller = nil
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
			// The bezel stays, and it is not decoration.
			//
			// It was turned off to make the field sit flat on the panel, and
			// that took the magnifier's room away with it. A search field
			// reserves the room by *insetting its bezel*: with the bezel on,
			// `searchTextRect` is (22, 5, 336, 16) and the field editor is put
			// exactly there. With it off, the cell still reports 22 — but the
			// editor is installed over the whole bounds, at x = 0, and the
			// placeholder is drawn from x = 2 straight through a glyph that
			// occupies 6 to 18. Twelve points of the magnifier had text over
			// it, and always: this field is given the cursor the moment the
			// popover opens, so the unfocused case that looked right was never
			// on screen.
			//
			// It also fixes the height. Unbezelled the field laid out 15 points
			// tall for a 12-point font, with no room above or below the text.
			field.isBezeled = true
			field.bezelStyle = .roundedBezel
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

		/// Never less than this, so a project with one take is not a sliver
		/// hanging off the capsule.
		static let floorHeight: CGFloat = 240

		/// And never more than a good fraction of the screen it is on.
		///
		/// Of the *screen*, because that is what the number is about: a panel may
		/// take most of the height somebody has and must not take all of it. 560
		/// was the old cap, chosen for no screen in particular, and it is a
		/// third of a 27-inch display.
		static func ceilingHeight(on screen: NSScreen?) -> CGFloat {
			let visible = (screen ?? NSScreen.main)?.visibleFrame.height ?? 900
			return max(floorHeight, min(visible * 0.72, 1000))
		}

		/// The room the field and the margins take, measured rather than
		/// guessed.
		///
		/// It was the constant 44 and the field is 41 points of chrome on its
		/// own at a rounded bezel — so every list was three points short, the
		/// last row was clipped through the middle of its text, and a scroller
		/// appeared over a list that fitted. That is the "too short" in the
		/// report: not only the cap but a panel that could never show a whole
		/// number of rows.
		private var chrome: CGFloat {
			// 7 above the field, 6 between it and the list, 6 below the list.
			7 + ceil(field.fittingSize.height) + 6 + 6
		}

		/// For the tests: the room that is not list, so an assertion can be made
		/// about whole rows fitting in what is left.
		var chromeForTesting: CGFloat { chrome }

		/// Height follows the content between a floor and a ceiling, so a short
		/// list is a short popover and a long one scrolls rather than growing off
		/// the screen.
		///
		/// And always a whole number of rows. That is the other half of "the
		/// second row clipped mid-line with a scroller": a panel whose list is
		/// two thirds of a row taller than it needs shows two thirds of a row,
		/// and a row cut through its own text reads as a rendering fault whether
		/// the list scrolls or not.
		private func resize() {
			let ceiling = Self.ceilingHeight(on: view.window?.screen)
			let content = CGFloat(rows.count) * Self.rowHeight + chrome
			let wanted = min(max(content, Self.floorHeight), ceiling)
			preferredContentSize = NSSize(width: Self.width, height: wholeRows(wanted))
		}

		/// The nearest height at or below `wanted` that holds a whole number of
		/// rows — and never less than one row's worth of list.
		private func wholeRows(_ wanted: CGFloat) -> CGFloat {
			let room = max(wanted - chrome, Self.rowHeight)
			return chrome + (room / Self.rowHeight).rounded(.down) * Self.rowHeight
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

		func chooseForTesting(aside: Bool = false) { chose(aside: aside) }

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

		/// What choosing the selected row will do, once the panel is out of the
		/// way. See ``take()``.
		private var pending: (() -> Void)?

		@objc private func take() {
			chose(aside: NSEvent.modifierFlags
				.intersection(.deviceIndependentFlagsMask).contains(.option))
		}

		private func chose(aside: Bool) {
			let row = table.selectedRow
			guard row >= 0, row < rows.count, case .entry(let entry) = rows[row],
			      let open = aside ? (entry.openAside ?? entry.open) : entry.open
			else { return }
			// The panel goes first and the document comes forward after it,
			// never the other way round.
			//
			// A transient popover with a text field in it *is* the key window
			// while it is up, and AppKit hands key status back to the window
			// the popover hung from as it closes. That happens after this
			// method returns — so a switcher that ordered another document's
			// window front from here had it taken away again a moment later,
			// and the window somebody had just left came back to the front.
			// That is the whole of "choosing a document from the dropdown does
			// nothing": the handler ran, every time, and its effect was undone.
			pending = open
			DocumentSwitcher.close()
			// If there was no popover to close — a switcher driven directly,
			// which is how the tests drive it — nothing ran it, so run it here.
			// Whichever arrives first clears it, so it happens exactly once.
			runPending()
		}

		private func runPending() {
			let open = pending
			pending = nil
			open?()
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

		/// Closed, by `close()` or by AppKit because somebody clicked away.
		///
		/// Both go through here, which is what makes the light on the capsule
		/// and the panel on screen say the same thing.
		func popoverDidClose(_ notification: Notification) {
			DocumentSwitcher.forget(self)
			onClose?()
			runPending()
		}

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
