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
		case header(String)
		case clip(ComposeDocument.Vocabulary.Item)
		case tag(String, Int)
		case anchor(String, String)

		/// What a project writes to mean it.
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
	private let table = NSTableView()
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
		table.target = self
		table.intercellSpacing = NSSize(width: 0, height: 0)
		let column = NSTableColumn(identifier: .init("item"))
		column.width = 240
		table.addTableColumn(column)
		// Dragged out, never into: the library is what the takes contain, and
		// dropping something here would be asking to change a take from the
		// project window.
		table.setDraggingSourceOperationMask(.copy, forLocal: true)

		let scroll = TableScroll.make(table)
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
		for take in vocabulary.takeNames {
			let clips = vocabulary.items.filter {
				$0.take == take && matches($0.slug, $0.name, $0.tags.joined(separator: " "), take)
			}
			guard !clips.isEmpty else { continue }
			out.append(.header(take))
			out.append(contentsOf: clips.map { Row.clip($0) })
		}

		let tags = vocabulary.tags.filter { matches($0) }
		if !tags.isEmpty {
			out.append(.header("tags"))
			out += tags.map { tag in
				.tag(tag, vocabulary.items.filter { $0.tags.contains(tag) }.count)
			}
		}

		let anchors = vocabulary.anchors.filter { matches($0) }
		if !anchors.isEmpty {
			out.append(.header("anchors"))
			out += anchors.map { .anchor($0, vocabulary.anchorTakes[$0] ?? "") }
		}

		rows = out
		table.reloadData()
	}

	@objc private func insertSelected() {
		let row = table.selectedRow
		guard row >= 0, row < rows.count, let reference = rows[row].reference else { return }
		onInsert?(reference)
	}

	// MARK: - Table

	public func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

	public func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
		if case .header = rows[row] { return 22 }
		return 30
	}

	public func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
		rows[row].reference != nil
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
		var row: Row = .header("")

		override func draw(_ dirtyRect: NSRect) {
			let bounds = self.bounds
			switch row {
			case .header(let title):
				let attributes: [NSAttributedString.Key: Any] = [
					.font: Theme.heading, .foregroundColor: Theme.faintText,
				]
				let text = title.uppercased() as NSString
				text.draw(at: NSPoint(x: 4, y: bounds.height - 15), withAttributes: attributes)
				Theme.rule.setFill()
				NSRect(x: 4, y: 3, width: bounds.width - 8, height: 1).fill()

			case .clip(let item):
				dot(Theme.color(.clip), at: 8)
				primary(item.reference, x: 20, y: bounds.height - 16)
				var offset = secondary(
					item.length > 0 ? Timecode.string(item.length) : "", x: 20,
					y: bounds.height - 28, colour: Theme.dimText)
				offset += 20
				for tag in item.tags.prefix(3) {
					offset += chip(tag, at: offset, y: bounds.height - 29) + 4
					if offset > bounds.width - 30 { break }
				}

			case .tag(let name, let count):
				dot(Theme.color(.tag), at: 8)
				primary("#\(name)", x: 20, y: bounds.height - 16)
				_ = secondary("\(count) clip\(count == 1 ? "" : "s")", x: 20,
				              y: bounds.height - 28, colour: Theme.dimText)

			case .anchor(let name, let take):
				dot(Theme.color(.anchor), at: 8)
				primary(name, x: 20, y: bounds.height - 16)
				_ = secondary(take, x: 20, y: bounds.height - 28, colour: Theme.dimText)
			}
		}

		private func dot(_ colour: NSColor, at x: CGFloat) {
			colour.setFill()
			NSBezierPath(ovalIn: NSRect(x: x, y: bounds.height / 2 - 3, width: 6, height: 6)).fill()
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
