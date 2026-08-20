import AppKit

/// Every document open, on `⇧⌘P`, filtered by typing.
///
/// The menu behind the document's name answers "which am I in, and what else is
/// there" for a hand already on the mouse. This is the same question for a hand
/// on the keyboard: press, type three letters, press return. With a dozen takes
/// open that is faster than any list somebody has to look at, which is most of
/// the argument for a palette over a tab bar.
///
/// A panel over the window rather than a sheet. A sheet is a question the window
/// is asking and it blocks the window until it is answered; this is a way of
/// leaving, and escape should put everything back exactly as it was.
@MainActor
public final class DocumentPalette: NSPanel, NSTableViewDataSource, NSTableViewDelegate,
                                    NSTextFieldDelegate {

	/// One row: what to show, and where it goes.
	public struct Entry {
		public var name: String
		public var detail: String
		public var kind: Theme.Kind
		public var window: NSWindow?

		public init(name: String, detail: String, kind: Theme.Kind, window: NSWindow?) {
			self.name = name
			self.detail = detail
			self.kind = kind
			self.window = window
		}
	}

	private let field = NSTextField()
	private let table = KeyTable()
	private var all: [Entry] = []
	private var shown: [Entry] = []
	private var chose: ((Entry) -> Void)?

	public override var canBecomeKey: Bool { true }

	public init(_ entries: [Entry], onChoose: @escaping (Entry) -> Void) {
		all = entries
		shown = entries
		chose = onChoose
		super.init(contentRect: NSRect(x: 0, y: 0, width: 560, height: 320),
		           styleMask: [.borderless, .nonactivatingPanel],
		           backing: .buffered, defer: false)
		isFloatingPanel = true
		appearance = NSAppearance(named: .darkAqua)
		backgroundColor = .clear
		isOpaque = false
		hasShadow = true

		let ground = NSView(frame: .roomToLayOutIn)
		ground.wantsLayer = true
		// The paper, one step in from the panel — the rule at `Theme.background`.
		ground.layer?.backgroundColor = Theme.card.cgColor
		ground.layer?.cornerRadius = 10
		ground.layer?.borderWidth = 1
		ground.layer?.borderColor = Theme.rule.cgColor
		ground.layer?.masksToBounds = true

		field.font = NSFont.systemFont(ofSize: 15, weight: .regular)
		field.textColor = Theme.text
		field.placeholderString = "Go to a take, a project, a scene"
		field.isBordered = false
		field.drawsBackground = false
		field.focusRingType = .none
		field.delegate = self
		field.translatesAutoresizingMaskIntoConstraints = false

		let rule = NSView()
		rule.wantsLayer = true
		rule.layer?.backgroundColor = Theme.rule.cgColor
		rule.translatesAutoresizingMaskIntoConstraints = false

		table.dataSource = self
		table.delegate = self
		table.rowHeight = 34
		table.backgroundColor = .clear
		table.gridStyleMask = []
		table.headerView = nil
		table.intercellSpacing = NSSize(width: 0, height: 2)
		table.selectionHighlightStyle = .regular
		table.addTableColumn(NSTableColumn(identifier: .init("document")))
		table.target = self
		table.doubleAction = #selector(take)
		let scroll = TableScroll.fitting(table)
		scroll.drawsBackground = false
		scroll.translatesAutoresizingMaskIntoConstraints = false

		for view in [field, rule, scroll] as [NSView] { ground.addSubview(view) }
		NSLayoutConstraint.activate([
			field.topAnchor.constraint(equalTo: ground.topAnchor, constant: 14),
			field.leadingAnchor.constraint(equalTo: ground.leadingAnchor, constant: 16),
			field.trailingAnchor.constraint(equalTo: ground.trailingAnchor, constant: -16),

			rule.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 12),
			rule.leadingAnchor.constraint(equalTo: ground.leadingAnchor),
			rule.trailingAnchor.constraint(equalTo: ground.trailingAnchor),
			rule.heightAnchor.constraint(equalToConstant: 1),

			scroll.topAnchor.constraint(equalTo: rule.bottomAnchor),
			scroll.leadingAnchor.constraint(equalTo: ground.leadingAnchor, constant: 6),
			scroll.trailingAnchor.constraint(equalTo: ground.trailingAnchor, constant: -6),
			scroll.bottomAnchor.constraint(equalTo: ground.bottomAnchor, constant: -6),
		])
		contentView = ground
		if !shown.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
	}

	/// Puts it over a window, near the top: where somebody's eye already is
	/// after pressing a key, and not so far down that it covers the thing they
	/// are trying to leave.
	public func show(over host: NSWindow) {
		let frame = host.frame
		let height = min(340, CGFloat(shown.count * 36) + 74)
		let size = NSSize(width: 560, height: height)
		setContentSize(size)
		setFrameOrigin(NSPoint(x: frame.midX - size.width / 2,
		                       y: frame.maxY - size.height - 120))
		host.addChildWindow(self, ordered: .above)
		makeKeyAndOrderFront(nil)
		makeFirstResponder(field)
	}

	private func leave() {
		parent?.removeChildWindow(self)
		orderOut(nil)
	}

	@objc private func take() {
		let row = table.selectedRow
		guard row >= 0, row < shown.count else { return }
		let entry = shown[row]
		leave()
		chose?(entry)
	}

	private func move(by offset: Int) {
		guard !shown.isEmpty else { return }
		let here = table.selectedRow < 0 ? 0 : table.selectedRow
		let landing = min(max(0, here + offset), shown.count - 1)
		table.selectRowIndexes([landing], byExtendingSelection: false)
		table.scrollRowToVisible(landing)
	}

	// MARK: - Typing

	public func controlTextDidChange(_ notification: Notification) {
		filter(field.stringValue)
	}

	/// Matched on what somebody would type: the letters in order, not
	/// necessarily together. `mt1` finds `mia-take-1`, which is the thing a
	/// palette is for.
	func filter(_ text: String) {
		let wanted = text.lowercased()
		shown = wanted.isEmpty ? all : all.filter {
			Self.matches(wanted, in: ($0.name + " " + $0.detail).lowercased())
		}
		table.reloadData()
		if !shown.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
	}

	static func matches(_ wanted: String, in text: String) -> Bool {
		var here = text.startIndex
		for character in wanted where character != " " {
			guard let found = text[here...].firstIndex(of: character) else { return false }
			here = text.index(after: found)
		}
		return true
	}

	public func control(_ control: NSControl, textView: NSTextView,
	                    doCommandBy selector: Selector) -> Bool {
		switch selector {
		case #selector(NSResponder.moveDown(_:)): move(by: 1); return true
		case #selector(NSResponder.moveUp(_:)): move(by: -1); return true
		case #selector(NSResponder.insertNewline(_:)): take(); return true
		case #selector(NSResponder.cancelOperation(_:)): leave(); return true
		default: return false
		}
	}

	public override func resignKey() {
		super.resignKey()
		leave()
	}

	// MARK: - The list

	public func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

	public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
		MarkedRow.make(in: tableView)
	}

	public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
	                      row: Int) -> NSView? {
		guard row < shown.count else { return nil }
		let view = (tableView.makeView(withIdentifier: .init("document"), owner: self) as? Row)
			?? { let made = Row(); made.identifier = .init("document"); return made }()
		view.entry = shown[row]
		view.needsDisplay = true
		return view
	}

	/// One row, drawn: a mark in the kind's own hue, the name, and where it
	/// belongs in grey after it.
	final class Row: NSTableCellView {
		var entry: Entry?

		override func draw(_ dirtyRect: NSRect) {
			guard let entry else { return }
			if let image = Theme.symbol(entry.kind, size: 13) {
				Theme.draw(image, in: NSRect(x: 8, y: bounds.midY - 8, width: 20, height: 16))
			}
			let name = entry.name as NSString
			let attributes: [NSAttributedString.Key: Any] = [
				.font: Theme.bodyStrong, .foregroundColor: Theme.text,
			]
			name.draw(at: NSPoint(x: 34, y: bounds.midY - 8), withAttributes: attributes)
			guard !entry.detail.isEmpty else { return }
			let after = 34 + name.size(withAttributes: attributes).width + 10
			(entry.detail as NSString).draw(
				at: NSPoint(x: after, y: bounds.midY - 7),
				withAttributes: [.font: Theme.monoSmall, .foregroundColor: Theme.dimText])
		}
	}

	/// For the tests: what the list holds now.
	var shownForTesting: [Entry] { shown }
}
