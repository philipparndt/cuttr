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
	/// Somebody wants to see where a clip came from: the take it is in, at the
	/// moment it starts. The window knows how to open a take; this list only
	/// knows which clip was pointed at.
	public var onOpenInTake: ((ComposeDocument.Vocabulary.Item) -> Void)?
	/// Open a scene in the scene editor. A scene is the one thing in this list
	/// that is not material to be placed but a thing to be made, so double
	/// clicking it opens it rather than putting it on the programme.
	public var onEditScene: ((String) -> Void)?

	fileprivate enum Row {
		case header(String, Theme.Kind?, collapsed: Bool)
		case clip(ComposeDocument.Vocabulary.Item)
		case tag(String, Int)
		case anchor(String, String)
		case scene(String)

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
			case .scene(let name): return name
			}
		}
	}

	private var vocabulary = ComposeDocument.Vocabulary()
	private var rows: [Row] = []
	/// Sections somebody has folded away, by their heading.
	private var collapsed: Set<String> = []
	private let table = KeyTable()
	private let search = NSSearchField()
	private let findMeme = NSButton()
	private var memeObserver: NSObjectProtocol?

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
		// Several clips dragged onto the programme at once, in the order they
		// are listed — which is how a section gets filled.
		table.allowsMultipleSelection = true
		table.onMenu = { [weak self] event in self?.rowMenu(for: event) }
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

		// Memes are material, so the way to get one is here with the material
		// rather than in a menu somewhere. It goes down the responder chain to
		// whichever project window is in front, which is the same route the
		// menu item takes — so there is one implementation of it and not two.
		findMeme.title = "Find a meme…"
		findMeme.bezelStyle = .rounded
		findMeme.controlSize = .small
		findMeme.font = NSFont.systemFont(ofSize: 11)
		findMeme.target = nil
		findMeme.action = #selector(ComposeWindowController.findMeme(_:))
		findMeme.toolTip = "Search GIPHY or Tenor. What arrives is a take like any other."

		let top = NSStackView(views: [search, findMeme])
		top.orientation = .horizontal
		top.spacing = 6

		let scroll = TableScroll.fitting(table)
		let stack = NSStackView(views: [top, scroll])
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
			top.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16),
			scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16),
		])

		// A meme that has just been downloaded is selected, not merely present.
		// The project window reloads this panel by itself when its takes
		// change; what this adds is knowing *which* row is the new one, and it
		// is the one thing the reload cannot know.
		memeObserver = NotificationCenter.default.addObserver(
			forName: .cuttrMemeAdded, object: nil, queue: .main
		) { [weak self] note in
			MainActor.assumeIsolated {
				guard let self, let reference = note.object as? String else { return }
				self.reveal(reference)
			}
		}
	}

	deinit {
		if let memeObserver { NotificationCenter.default.removeObserver(memeObserver) }
	}

	@available(*, unavailable) required init?(coder: NSCoder) { nil }

	/// Puts a reference on screen and selects it, opening its section and
	/// clearing whatever was being filtered for — because a row that is real
	/// but filtered out looks exactly like a download that did not work.
	public func reveal(_ reference: String) {
		if !rows.contains(where: { $0.reference == reference }) {
			search.stringValue = ""
			collapsed.remove("memes")
			rebuild()
		}
		guard let row = rows.firstIndex(where: { $0.reference == reference }) else { return }
		table.selectRowIndexes([row], byExtendingSelection: false)
		table.scrollRowToVisible(row)
	}

	// MARK: - Contents

	public func reload(_ vocabulary: ComposeDocument.Vocabulary) {
		// A reload puts a look away: the rows are about to move under it, and
		// the take it was playing may not be one of this project's any more.
		closeLook()
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

		for take in vocabulary.takeNames where !vocabulary.memeTakes.contains(take) {
			let clips = vocabulary.items.filter {
				$0.take == take && matches($0.slug, $0.name, $0.tags.joined(separator: " "), take)
			}
			section(take, .take, clips.map { Row.clip($0) })
		}

		// Memes together, under one heading, rather than one heading each.
		//
		// A downloaded meme is a take with a single clip in it, so listing them
		// take by take would be a page of headings with one line under each.
		// They are material of a kind — short, borrowed, interchangeable — and
		// what somebody wants is to see the ones they have and drag one out.
		// Which takes those are comes from each take's own `source:` block, not
		// from the folder the file is in.
		section("memes", .take, vocabulary.items.filter {
			vocabulary.memeTakes.contains($0.take)
				&& matches($0.slug, $0.name, $0.tags.joined(separator: " "), $0.take)
		}.map { Row.clip($0) })

		section("tags", nil, vocabulary.tags.filter { matches($0) }.map { tag in
			.tag(tag, vocabulary.items.filter { $0.tags.contains(tag) }.count)
		})
		section("anchors", nil, vocabulary.anchors.filter { matches($0) }.map {
			.anchor($0, vocabulary.anchorTakes[$0] ?? "")
		})
		section("scenes", nil, vocabulary.scenes.filter { matches($0) }.map { Row.scene($0) })

		rows = out
		table.reloadData()
	}

	@objc private func insertSelected() {
		let row = table.selectedRow
		guard row >= 0, row < rows.count else { return }
		if case .header(let title, _, _) = rows[row] { return toggle(title) }
		if case .scene(let name) = rows[row] { onEditScene?(name); return }
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
		// Space is a look at the clip that is selected, and the same key again
		// puts it away; escape does too, and only while one is open. Both
		// questions are asked of ``QuickLook`` rather than answered here, for
		// the same reason the programme tree asks them: space belongs to several
		// things in this program — the preview, the transcript, a text field —
		// and the only safe way to take it is to be able to say, without a
		// keyboard, where it is *not* taken.
		//
		// It used to mean "put this on the programme", which `return` already
		// means and still does. A second key for the same thing is worth less
		// than a look at the material before you place it.
		//
		// Nothing is being typed when this is asked: the key arrives through the
		// table's own `keyDown`, and a table with a field editor up is not the
		// first responder.
		if QuickLook.dismisses(event), isLooking {
			closeLook()
			return true
		}
		if QuickLook.claims(event, editing: false, hasSpan: lookSpan() != nil) {
			if isLooking { closeLook() } else { showLook() }
			return true
		}
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
		case 36:   // return
			insertSelected()
			return true
		default:
			return false
		}
	}

	// MARK: - A look

	/// The panel a look happens in, made when one is first asked for.
	private var look: QuickLookPanel?
	/// What keeps it open only while somebody is looking — the same rule the
	/// programme tree's look lives under. See ``LookWatch``.
	private let lookWatch = LookWatch()

	/// Whether a look is open. For the window, and for the tests.
	public var isLooking: Bool { look?.isShowing == true }

	/// Which clip a look would be at, and which row it is on: the first one
	/// selected.
	///
	/// The list selects in handfuls, because several clips dragged out at once
	/// is how a section gets filled — but two clips are two takes' worth of
	/// media and there is no single thing to play. A look is at one thing, so it
	/// is at the first of them.
	func lookClip() -> (row: Int, clip: ComposeDocument.Vocabulary.Item)? {
		for row in table.selectedRowIndexes.sorted() where row < rows.count {
			if case .clip(let item) = rows[row] { return (row, item) }
		}
		return nil
	}

	/// What a look would play, and therefore whether space means anything here
	/// at all. `nil` is the list declining the key — which is what a tag, an
	/// anchor, a scene or a heading is: a name, with no stretch of anything
	/// behind it.
	///
	/// On the take's clock, which is the clock the take's own media is on and
	/// the only clock a clip has. Nothing here is a time on the programme: the
	/// clip may not be on the programme.
	func lookSpan() -> QuickLook.Span? {
		guard let item = lookClip()?.clip, item.length > 0 else { return nil }
		// A clip shorter than a look is played for as long as a look, forwards —
		// see ``QuickLook/shortest``. Forwards and not backwards because how
		// long the take runs is not something this list knows; the player stops
		// at the end of the media, which is the honest end of the answer.
		return QuickLook.Span(start: item.start,
		                      end: item.start + max(item.length, QuickLook.shortest))
	}

	/// The take's media, or `nil` if none of it is where the take says it is.
	///
	/// Asked of the disk rather than assumed, because a path that has moved is
	/// the commonest thing to go wrong with a project — and a look that plays
	/// black tells nobody which of the two it was.
	private func lookMedia(_ item: ComposeDocument.Vocabulary.Item) -> QuickLookPanel.Media? {
		guard let media = vocabulary.media[item.take] else { return nil }
		func onDisk(_ url: URL?) -> URL? {
			guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
			return url
		}
		let video = onDisk(media.video), audio = onDisk(media.audio)
		guard video != nil || audio != nil else { return nil }
		return QuickLookPanel.Media(video: video, audio: audio, offset: media.offset)
	}

	/// A look at the selected clip, beside the row it was chosen from.
	///
	/// Playing the take's own media rather than a stretch of the programme,
	/// because a clip in the library may never have been placed on one. The
	/// composition of a video and a separate recorder at its offset is
	/// ``Transport``'s, which the panel plays through anyway — so this builds no
	/// assembly of its own, and the alignment it plays is the take's.
	///
	/// Nothing is drawn over it. Overlays belong to a project, and this is a
	/// look at what a take holds.
	public func showLook() {
		guard let window, let chosen = lookClip(), let span = lookSpan()
		else { closeLook(); return }
		let item = chosen.clip
		let panel = look ?? QuickLookPanel()
		look = panel
		let media = lookMedia(item)
		let where_ = QuickLook.frames(of: table.rect(ofRow: chosen.row), in: table,
		                              column: self, window: window)
		panel.show(
			span, titled: item.name.isEmpty ? item.slug : item.name,
			saying: media == nil
				? item.take
				: "\(item.take)   \(Timecode.string(span.start)) → \(Timecode.string(span.end))",
			playing: media, over: window, beside: where_.column, row: where_.row,
			// The shape of the footage is not something a project's vocabulary
			// knows, and probing for it is a read this key press should not wait
			// on. The picture is drawn aspect-fitted whatever the panel's shape,
			// so a guess costs at worst a band of card either side of it.
			output: NSSize(width: 16, height: 9))
		lookWatch.begin(in: self, look: panel) { [weak self] in self?.closeLook() }
	}

	/// Puts it away, and takes the watch off with it.
	public func closeLook() {
		look?.hide()
		lookWatch.end()
	}

	/// An open look follows the selection, so arrowing down the list is somebody
	/// comparing two clips. A panel pinned beside a row that is showing
	/// something else is a panel lying about what it is pointing at.
	public func tableViewSelectionDidChange(_ notification: Notification) {
		if isLooking { showLook() }
	}

	/// The list leaving the window takes the look with it: a panel hovering
	/// beside a list that is no longer there outlives what it was about.
	public override func viewDidMoveToWindow() {
		super.viewDidMoveToWindow()
		if window == nil { closeLook() }
	}

	/// For the tests: where the look landed, and what it is playing.
	var lookFrameForTesting: NSRect? { look?.frame }
	var lookPanelForTesting: QuickLookPanel? { look }
	/// For the tests: the list itself, which is what has to have the keyboard
	/// for the key to arrive here at all — the window's own key monitor hands
	/// the press on when the first responder is a table, and eats it when it is
	/// not.
	var tableForTesting: KeyTable { table }

	/// For the tests: a key press as the *table* hands it over.
	///
	/// Through `table.onKey`, which is the wiring rather than a copy of it, and
	/// not by dispatching an event at the view: an unclaimed key event walks up
	/// to `NSResponder`, which answers it with a beep on the machine the tests
	/// are running on. What a test then asks is whether a look opened.
	func keyForTesting(_ event: NSEvent) -> Bool { table.onKey?(event) ?? false }

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

	/// One rule for every list in this program: a selected row is a mark and a
	/// lighter ground, not a bar of saturated blue across it.
	public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
		MarkedRow.make(in: tableView)
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
		// A scene is dragged as itself rather than as a reference: dropped on
		// the programme it becomes a card with the scene drawn on it, which is
		// what an intro screen is, and that is the drop's business to arrange.
		if case .scene(let name) = rows[row] {
			let item = NSPasteboardItem()
			item.setString(name, forType: ProgrammePanel.sceneType)
			return item
		}
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
	/// The row under the pointer, whatever is selected.
	///
	/// A right-click that quietly acts on the selection rather than on what was
	/// clicked is the way to delete the wrong thing, so the menu names the row
	/// it is over and selects it first.
	func rowMenu(for event: NSEvent) -> NSMenu? {
		let place = table.convert(event.locationInWindow, from: nil)
		let row = table.row(at: place)
		guard row >= 0, row < rows.count, case .clip(let item) = rows[row] else { return nil }
		table.selectRowIndexes([row], byExtendingSelection: false)
		let menu = NSMenu()
		let open = NSMenuItem(title: "Open “\(item.slug)” in \(item.take)",
		                      action: #selector(openInTake(_:)), keyEquivalent: "")
		open.target = self
		open.representedObject = item.reference
		menu.addItem(open)
		return menu
	}

	@objc private func openInTake(_ sender: NSMenuItem) {
		guard let reference = sender.representedObject as? String else { return }
		for row in rows {
			if case .clip(let item) = row, item.reference == reference {
				onOpenInTake?(item)
				return
			}
		}
	}

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
				// The lane it was cut on, as a stripe against the words rather
				// than against the edge of the row. It is the *clip* that was
				// cut on that lane, and the clip is its name — a stripe out at
				// the margin reads as belonging to the list.
				//
				// It also keeps the rows aligned: every row's mark and name are
				// in the same place whether or not there is a colour to show.
				mark(.clip)
				Theme.clipStripe(item.color).setFill()
				NSRect(x: 23, y: 3, width: 3, height: bounds.height - 6).fill()
				primary(item.reference, x: 30, y: bounds.height - 16)
				var offset = secondary(
					item.length > 0 ? Timecode.string(item.length) : "", x: 30,
					y: bounds.height - 28, colour: Theme.dimText)
				offset += 20
				for tag in item.tags.prefix(3) {
					offset += chip(tag, at: offset, y: bounds.height - 29) + 4
					if offset > bounds.width - 30 { break }
				}

			case .tag(let name, let count):
				mark(.tag)
				primary("#\(name)", x: 30, y: bounds.height - 16)
				_ = secondary("\(count) clip\(count == 1 ? "" : "s")", x: 30,
				              y: bounds.height - 28, colour: Theme.dimText)

			case .anchor(let name, let take):
				mark(.anchor)
				primary(name, x: 30, y: bounds.height - 16)
				_ = secondary(take, x: 30, y: bounds.height - 28, colour: Theme.dimText)

			case .scene(let name):
				mark(.scene)
				primary(name, x: 30, y: bounds.height - 16)
				_ = secondary("double-click to edit", x: 30, y: bounds.height - 28,
				              colour: Theme.dimText)
			}
		}

		private func mark(_ kind: Theme.Kind) {
			guard let image = Theme.symbol(kind) else { return }
			Theme.draw(image, in: NSRect(x: 3, y: bounds.height / 2 - 8, width: 19, height: 16))
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
