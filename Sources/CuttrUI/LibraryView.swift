import AppKit
import CuttrCompose
import CuttrKit

/// Everything the takes offer, ready to be put on the programme.
///
/// A project's vocabulary is not something to remember. The clips exist, their
/// tags exist, the tracked faces exist — so they are listed, with the take they
/// came from and how long they run, and dragged onto the timeline. Somebody who
/// has never opened the file can assemble a programme from this panel alone,
/// which is the whole point: the text is where you go when you want it, not the
/// only place the names live.
@MainActor
public final class LibraryView: NSView, NSTableViewDataSource, NSTableViewDelegate {

	/// Put this reference on the programme — double-clicked, or the + button.
	public var onInsert: ((String) -> Void)?

	fileprivate enum Row {
		case header(String, Theme.Kind?, collapsed: Bool)
		case clip(ComposeDocument.Vocabulary.Item)
		case tag(String, Int)
		case anchor(String, String)

		/// What a project writes to mean it.
		/// The section this row belongs to, for the keyboard: left arrow on an
		/// item goes to its heading, and collapses it from there.
		var isHeader: Bool {
			if case .header = self { return true }
			return false
		}

		var reference: String? {
			switch self {
			case .header: return nil
			case .clip(let item): return item.reference
			case .tag(let name, _): return "#\(name)"
			case .anchor(let name, _): return name
			}
		}
	}

	private var vocabulary = ComposeDocument.Vocabulary()
	private var rows: [Row] = []
	/// Sections somebody has folded away, by their heading.
	private var collapsed: Set<String> = []
	private let table = KeyTable()
	private let search = NSSearchField()

	public override init(frame: NSRect) {
		super.init(frame: frame)
		wantsLayer = true
		layer?.backgroundColor = Theme.panel.cgColor

		search.font = Theme.body
		search.placeholderString = "Filter clips, #tags, anchors"
		search.target = self
		search.action = #selector(filterChanged)
		search.sendsSearchStringImmediately = true
		search.sendsWholeSearchString = false

		table.dataSource = self
		table.delegate = self
		table.rowHeight = 30
		table.backgroundColor = Theme.panel
		table.gridStyleMask = []
		table.headerView = nil
		table.selectionHighlightStyle = .regular
		table.doubleAction = #selector(insertSelected)
		table.action = #selector(clicked)
		table.target = self
		table.onKey = { [weak self] event in self?.handle(event) ?? false }
		table.intercellSpacing = NSSize(width: 0, height: 0)
		let column = NSTableColumn(identifier: .init("item"))
		column.width = 240
		table.addTableColumn(column)
		// Dragged out, never into: the library is what the takes contain, and
		// dropping something here would be asking to change a take from the
		// project window.
		table.setDraggingSourceOperationMask(.copy, forLocal: true)

		let scroll = TableScroll.fitting(table)
		let stack = NSStackView(views: [search, scroll])
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
			search.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16),
			scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16),
		])
	}

	@available(*, unavailable) required init?(coder: NSCoder) { nil }

	// MARK: - Contents

	public func reload(_ vocabulary: ComposeDocument.Vocabulary) {
		self.vocabulary = vocabulary
		rebuild()
	}

	@objc private func filterChanged() { rebuild() }

	private func rebuild() {
		let needle = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
		func matches(_ text: String...) -> Bool {
			needle.isEmpty || text.contains { $0.lowercased().contains(needle) }
		}

		var out: [Row] = []
		func section(_ title: String, _ kind: Theme.Kind?, _ items: [Row]) {
			guard !items.isEmpty else { return }
			let folded = collapsed.contains(title)
			out.append(.header(title, kind, collapsed: folded))
			if !folded { out += items }
		}

		for take in vocabulary.takeNames {
			let clips = vocabulary.items.filter {
				$0.take == take && matches($0.slug, $0.name, $0.tags.joined(separator: " "), take)
			}
			section(take, .take, clips.map { Row.clip($0) })
		}

		section("tags", nil, vocabulary.tags.filter { matches($0) }.map { tag in
			.tag(tag, vocabulary.items.filter { $0.tags.contains(tag) }.count)
		})
		section("anchors", nil, vocabulary.anchors.filter { matches($0) }.map {
			.anchor($0, vocabulary.anchorTakes[$0] ?? "")
		})

		rows = out
		table.reloadData()
	}

	@objc private func insertSelected() {
		let row = table.selectedRow
		guard row >= 0, row < rows.count else { return }
		if case .header(let title, _, _) = rows[row] { return toggle(title) }
		guard let reference = rows[row].reference else { return }
		onInsert?(reference)
	}

	/// One click on a heading folds it, because a heading with a chevron on it
	/// is a thing people click.
	@objc private func clicked() {
		let row = table.clickedRow
		guard row >= 0, row < rows.count, case .header(let title, _, _) = rows[row] else { return }
		toggle(title)
	}

	/// The arrows, on a list of sections: right opens, left closes — and left on
	/// something inside a section goes to its heading first, the way a source
	/// list behaves everywhere else on the machine.
	fileprivate func handle(_ event: NSEvent) -> Bool {
		let row = table.selectedRow
		guard row >= 0, row < rows.count else { return false }
		switch event.keyCode {
		case 124:   // right
			if case .header(let title, _, true) = rows[row] { toggle(title); return true }
			return false
		case 123:   // left
			if case .header(let title, _, false) = rows[row] { toggle(title); return true }
			if case .header = rows[row] { return true }
			// Inside a section: go up to its heading.
			if let heading = (0..<row).reversed().first(where: { rows[$0].isHeader }) {
				table.selectRowIndexes([heading], byExtendingSelection: false)
				table.scrollRowToVisible(heading)
				return true
			}
			return false
		case 36, 49:   // return, space
			insertSelected()
			return true
		default:
			return false
		}
	}

	// MARK: - Table

	public func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

	public func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
		if case .header = rows[row] { return 22 }
		return 30
	}

	public func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
		// Headings are selectable too, or there is no way to fold one from the
		// keyboard.
		true
	}

	/// Folds a section away, or opens it, by name — the same thing the chevron
	/// does. Public for the test that says it does.
	public func fold(_ title: String) { toggle(title) }

	/// Folds a section away, or opens it. The row stays put: what somebody
	/// clicked is still under the pointer afterwards.
	private func toggle(_ title: String) {
		if collapsed.contains(title) { collapsed.remove(title) } else { collapsed.insert(title) }
		let row = table.selectedRow
		rebuild()
		if row >= 0, row < rows.count {
			table.selectRowIndexes([row], byExtendingSelection: false)
		}
	}

	public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
		let view = (tableView.makeView(withIdentifier: .init("row"), owner: self) as? LibraryRow)
			?? { let view = LibraryRow(); view.identifier = .init("row"); return view }()
		view.row = rows[row]
		view.needsDisplay = true
		return view
	}

	/// Dragged as plain text, which is exactly what it means: the reference a
	/// project writes. The same string works dropped into the timeline, into
	/// the text editor, or into somebody's notes.
	public func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
		guard row < rows.count, let reference = rows[row].reference else { return nil }
		let item = NSPasteboardItem()
		item.setString(reference, forType: .string)
		return item
	}

	/// One row, drawn rather than assembled.
	///
	/// Four things have to fit in a narrow column — a kind, a name, what it is
	/// called, and its tags — and stacked text fields would spend most of the
	/// width on the gaps between them.
	fileprivate final class LibraryRow: NSTableCellView {
		var row: Row = .header("", nil, collapsed: false)

		/// Redrawn when it changes width.
		///
		/// A cell view is resized by the table as the column changes, and a
		/// layer-backed one keeps whatever it drew at its old width until
		/// something else marks it dirty — which is why the rule under a
		/// heading stopped short until the window was resized.
		override func setFrameSize(_ newSize: NSSize) {
			super.setFrameSize(newSize)
			needsDisplay = true
		}

		override func draw(_ dirtyRect: NSRect) {
			let bounds = self.bounds
			switch row {
			case .header(let title, let kind, let folded):
				let attributes: [NSAttributedString.Key: Any] = [
					.font: Theme.heading, .foregroundColor: Theme.faintText,
				]
				var x: CGFloat = 4
				// The chevron says the section can be folded, and which way it
				// is now. Without it nothing on screen says either.
				if let chevron = NSImage(
					systemSymbolName: folded ? "chevron.right" : "chevron.down",
					accessibilityDescription: folded ? "folded" : "open") {
					let configuration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
						.applying(NSImage.SymbolConfiguration(paletteColors: [Theme.dimText]))
					if let drawn = chevron.withSymbolConfiguration(configuration) {
						Theme.draw(drawn, in: NSRect(x: x, y: bounds.height - 16, width: 11, height: 12))
					}
				}
				x += 14
				if let kind, let image = Theme.symbol(kind, size: 10, colour: Theme.faintText) {
					Theme.draw(image, in: NSRect(x: x, y: bounds.height - 17, width: 13, height: 14))
					x += 17
				}
				let text = title.uppercased() as NSString
				text.draw(at: NSPoint(x: x, y: bounds.height - 15), withAttributes: attributes)
				Theme.rule.setFill()
				NSRect(x: 4, y: 3, width: bounds.width - 8, height: 1).fill()

			case .clip(let item):
				mark(.clip)
				primary(item.reference, x: 24, y: bounds.height - 16)
				var offset = secondary(
					item.length > 0 ? Timecode.string(item.length) : "", x: 24,
					y: bounds.height - 28, colour: Theme.dimText)
				offset += 20
				for tag in item.tags.prefix(3) {
					offset += chip(tag, at: offset, y: bounds.height - 29) + 4
					if offset > bounds.width - 30 { break }
				}

			case .tag(let name, let count):
				mark(.tag)
				primary("#\(name)", x: 24, y: bounds.height - 16)
				_ = secondary("\(count) clip\(count == 1 ? "" : "s")", x: 24,
				              y: bounds.height - 28, colour: Theme.dimText)

			case .anchor(let name, let take):
				mark(.anchor)
				primary(name, x: 24, y: bounds.height - 16)
				_ = secondary(take, x: 24, y: bounds.height - 28, colour: Theme.dimText)
			}
		}

		private func mark(_ kind: Theme.Kind) {
			guard let image = Theme.symbol(kind) else { return }
			Theme.draw(image, in: NSRect(x: 5, y: bounds.height / 2 - 8, width: 15, height: 16))
		}

		private func primary(_ text: String, x: CGFloat, y: CGFloat) {
			(text as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [
				.font: Theme.mono, .foregroundColor: Theme.text,
			])
		}

		@discardableResult
		private func secondary(_ text: String, x: CGFloat, y: CGFloat, colour: NSColor) -> CGFloat {
			guard !text.isEmpty else { return x }
			let attributes: [NSAttributedString.Key: Any] = [
				.font: Theme.monoSmall, .foregroundColor: colour,
			]
			(text as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attributes)
			return x + (text as NSString).size(withAttributes: attributes).width
		}

		/// A tag, as a filled pill. The same shape the clip table uses, so a tag
		/// looks like a tag wherever it appears.
		private func chip(_ text: String, at x: CGFloat, y: CGFloat) -> CGFloat {
			let attributes: [NSAttributedString.Key: Any] = [
				.font: Theme.monoSmall, .foregroundColor: Theme.color(.tag),
			]
			let size = (text as NSString).size(withAttributes: attributes)
			let box = NSRect(x: x, y: y, width: size.width + 8, height: 13)
			Theme.color(.tag).withAlphaComponent(0.16).setFill()
			NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3).fill()
			(text as NSString).draw(at: NSPoint(x: x + 4, y: y + 1), withAttributes: attributes)
			return box.width
		}
	}
}
