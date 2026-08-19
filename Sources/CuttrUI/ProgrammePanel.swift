import AppKit
import CuttrCompose
import CuttrKit

/// What is selected, and therefore what the properties panel is about.
public enum ProjectSelection: Equatable {
	case output
	case entry([Int])
	case overlay(Int)
}

/// The programme: what plays, in order, with what is drawn over it.
///
/// An outline rather than a table, because a project nests — a section holds
/// clips and a section may hold a section — and a list with two spaces of
/// indent is a tree that has been flattened and hopes nobody notices. Sections
/// open and close, entries are dragged into them, and the shape on screen is
/// the shape in the file.
///
/// Nothing is typed into here. Structure is what this panel is for — order,
/// nesting, what is on and what is off — and the properties of whatever is
/// selected are edited beside it, where there is room for them to be labelled.
@MainActor
public final class ProgrammePanel: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate,
                                   NSTableViewDataSource, NSTableViewDelegate {

	/// A whole project, edited.
	public var onChange: ((Project) -> Void)?
	/// What is selected now.
	public var onSelect: ((ProjectSelection) -> Void)?

	private var project = Project()
	private var roots: [Node] = []
	private var vocabulary = ComposeDocument.Vocabulary()
	private var collapsed: Set<String> = []

	private let outline = NSOutlineView()
	private let overlayTable = NSTableView()
	/// What to do when there is nothing there yet. An empty list that says
	/// nothing looks like a list that is broken.
	private let programmeHint = ProgrammePanel.hint(
		"Drag a clip or a #tag from the library, or press + Clip")
	private let overlayHint = ProgrammePanel.hint(
		"Select where it should go, then + Text or + Spinner")

	/// Dragging an entry means dragging its position, so the position is what
	/// travels: `0.2.1` is the second entry of the third entry of the first.
	private static let entryType = NSPasteboard.PasteboardType("de.rnd7.cuttr.entry")

	// MARK: - Tree

	/// One entry, wrapped so the outline view has an object to hold on to.
	fileprivate final class Node: NSObject {
		let path: [Int]
		let entry: TimelineEntry
		let children: [Node]

		init(path: [Int], entry: TimelineEntry, children: [Node]) {
			self.path = path
			self.entry = entry
			self.children = children
		}

		var groupName: String? {
			if case .group(let name, _) = entry.source { return name }
			return nil
		}
	}

	public override init(frame: NSRect) {
		super.init(frame: frame)
		wantsLayer = true
		layer?.backgroundColor = Theme.panel.cgColor

		let programme = buildOutline()
		let overlays = buildOverlays()

		// The cut above, what is laid over it below, in that order because that
		// is the order they happen in: a caption is drawn over a clip that has
		// to exist first.
		let split = NSSplitView()
		split.isVertical = false
		split.dividerStyle = .thin
		split.addArrangedSubview(programme)
		split.addArrangedSubview(overlays)
		split.translatesAutoresizingMaskIntoConstraints = false
		addSubview(split)
		NSLayoutConstraint.activate([
			split.topAnchor.constraint(equalTo: topAnchor),
			split.bottomAnchor.constraint(equalTo: bottomAnchor),
			split.leadingAnchor.constraint(equalTo: leadingAnchor),
			split.trailingAnchor.constraint(equalTo: trailingAnchor),
			programme.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
			overlays.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
		])
	}

	@available(*, unavailable) required init?(coder: NSCoder) { nil }

	// MARK: - Furniture

	/// A titled pane: heading, list, and the buttons that act on it.
	private func pane(_ title: String, _ list: NSView, _ buttons: [NSButton]) -> NSView {
		let heading = NSTextField(labelWithString: title.uppercased())
		heading.font = Theme.heading
		heading.textColor = Theme.faintText

		let row = NSStackView(views: [heading] + buttons)
		row.orientation = .horizontal
		row.spacing = 6
		row.setContentCompressionResistancePriority(
			NSLayoutConstraint.Priority(1), for: .horizontal)
		row.setHuggingPriority(.defaultHigh, for: .horizontal)

		let stack = NSStackView(views: [row, list])
		stack.orientation = .vertical
		stack.spacing = 6
		stack.alignment = .leading
		stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)

		let holder = NSView()
		stack.translatesAutoresizingMaskIntoConstraints = false
		list.translatesAutoresizingMaskIntoConstraints = false
		holder.addSubview(stack)
		NSLayoutConstraint.activate([
			stack.topAnchor.constraint(equalTo: holder.topAnchor),
			stack.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
			stack.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
			stack.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
			list.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16),
			row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16),
		])
		return holder
	}

	private static func hint(_ text: String) -> NSTextField {
		let label = NSTextField(labelWithString: text)
		label.font = Theme.monoSmall
		label.textColor = Theme.faintText
		label.alignment = .center
		return label
	}

	private func over(_ scroll: NSScrollView, _ label: NSTextField) {
		label.translatesAutoresizingMaskIntoConstraints = false
		scroll.addSubview(label)
		NSLayoutConstraint.activate([
			label.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
			label.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 24),
		])
	}

	/// A button with a symbol on it and its words in the tooltip.
	///
	/// Six titled buttons over a list is a row of words wider than the thing it
	/// acts on — and when the pane narrows they truncate, so the row ends up
	/// saying "..." and "+ Spinner". A symbol is the same instruction in a
	/// quarter of the room, and the words are still there on hover.
	private func button(_ symbol: String, _ action: Selector, _ tip: String) -> NSButton {
		let button = NSButton()
		button.bezelStyle = .rounded
		button.controlSize = .small
		button.target = self
		button.action = action
		button.toolTip = tip
		button.imagePosition = .imageOnly
		button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
			.withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
		button.imageScaling = .scaleProportionallyDown
		button.translatesAutoresizingMaskIntoConstraints = false
		button.widthAnchor.constraint(equalToConstant: 26).isActive = true
		button.setContentCompressionResistancePriority(
			NSLayoutConstraint.Priority(1), for: .horizontal)
		return button
	}

	// MARK: - The cut

	private func buildOutline() -> NSView {
		outline.dataSource = self
		outline.delegate = self
		outline.rowHeight = 26
		outline.backgroundColor = Theme.panel
		outline.gridStyleMask = []
		outline.headerView = nil
		outline.indentationPerLevel = 16
		outline.autosaveExpandedItems = false
		outline.floatsGroupRows = false
		outline.intercellSpacing = NSSize(width: 0, height: 2)
		outline.selectionHighlightStyle = .regular
		let column = NSTableColumn(identifier: .init("entry"))
		// The column is the width of the view, not a number picked once.
		//
		// It was 420 and fixed, so anything a row drew against its right edge —
		// which is where the transition badge was — sat outside the part of the
		// column anybody could see, and the only way to find it was to scroll
		// sideways in a list that has nothing to scroll sideways for.
		column.width = 420
		column.resizingMask = .autoresizingMask
		outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
		outline.addTableColumn(column)
		outline.outlineTableColumn = column

		// Dropped on from the library, and dragged about within itself.
		outline.registerForDraggedTypes([.string, Self.entryType])
		outline.setDraggingSourceOperationMask(.move, forLocal: true)

		let scroll = TableScroll.fitting(outline)
		over(scroll, programmeHint)
		return pane("programme", scroll, [
			button("plus", #selector(addClip), "Add a clip by slug, or a #tag query"),
			button("folder.badge.plus", #selector(addGroup),
			       "Add a named section overlays can be hung on"),
			button("plus.square.on.square", #selector(duplicateEntry), "Another one just like it"),
			button("arrow.up", #selector(moveEntryUp), "Earlier"),
			button("arrow.down", #selector(moveEntryDown), "Later"),
			button("minus", #selector(removeEntry), "Take it off the programme"),
		])
	}

	private var selectedPath: [Int]? {
		(outline.item(atRow: outline.selectedRow) as? Node)?.path
	}

	@objc private func addClip() { insert(TimelineEntry(clip: ClipReference("clip"))) }
	@objc private func addGroup() { insert(TimelineEntry(group: "section", entries: [])) }

	private func insert(_ entry: TimelineEntry) {
		var next = project
		next.insertEntry(entry, after: selectedPath)
		onChange?(next)
	}

	/// Puts a reference on the programme — dropped, or double-clicked in the
	/// library. Read by the same rule the file uses, so `#tag` arrives as a
	/// query and `@name` as a section.
	public func insert(reference: String) {
		guard let entry = try? TimelineEntry(text: reference) else { return }
		insert(entry)
	}

	@objc private func duplicateEntry() {
		guard let path = selectedPath, let entry = project.entry(at: path) else { return }
		var next = project
		next.insertEntry(entry, after: path)
		onChange?(next)
	}

	@objc private func removeEntry() {
		guard let path = selectedPath else { return }
		var next = project
		next.removeEntry(at: path)
		onChange?(next)
	}

	@objc private func moveEntryUp() { move(by: -1) }
	@objc private func moveEntryDown() { move(by: 1) }

	private func move(by offset: Int) {
		guard let path = selectedPath else { return }
		var next = project
		let landed = next.moveEntry(at: path, by: offset)
		pending = .entry(landed)
		onChange?(next)
	}

	/// Where the selection should land once the project comes back through
	/// ``reload(_:vocabulary:)`` — an edit changes the paths under it.
	private var pending: ProjectSelection?

	// MARK: - What is drawn over it

	private func buildOverlays() -> NSView {
		overlayTable.dataSource = self
		overlayTable.delegate = self
		overlayTable.rowHeight = 34
		overlayTable.backgroundColor = Theme.panel
		overlayTable.gridStyleMask = []
		overlayTable.headerView = nil
		overlayTable.intercellSpacing = NSSize(width: 0, height: 2)
		let column = NSTableColumn(identifier: .init("overlay"))
		column.width = 420
		overlayTable.addTableColumn(column)

		let scroll = TableScroll.fitting(overlayTable)
		over(scroll, overlayHint)
		return pane("overlays", scroll, [
			button("textformat", #selector(addText), "Add a caption, bound to what is selected"),
			button("circle.dotted", #selector(addSpinner),
			       "Add a spinner; give it an anchor to pin it to a face"),
			button("sparkles", #selector(addEffect), "Add confetti, sparks, snow or rain"),
			button("plus.square.on.square", #selector(duplicateOverlay), "Another one just like it"),
			button("arrow.up", #selector(moveOverlayUp), "Draw it earlier — under the one above"),
			button("arrow.down", #selector(moveOverlayDown), "Draw it later — over the one below"),
			button("minus", #selector(removeOverlay), "Take it off"),
		])
	}

	/// Up and down the list, which is up and down the stack.
	///
	/// The order of `overlays:` is the order they are drawn in, so moving a row
	/// is the only control there is over what is on top of what: an aberration
	/// above a film overlay bends the bars, the same one below it leaves them
	/// clean. Captions are the exception, and the row says so.
	@objc private func moveOverlayUp() { moveOverlay(by: -1) }
	@objc private func moveOverlayDown() { moveOverlay(by: 1) }

	private func moveOverlay(by offset: Int) {
		let row = overlayTable.selectedRow
		let landing = row + offset
		guard row >= 0, row < project.overlays.count,
		      landing >= 0, landing < project.overlays.count else { return }
		var next = project
		next.overlays.swapAt(row, landing)
		pending = .overlay(landing)
		onChange?(next)
	}

	/// The clip or section a new overlay should cover: whatever is selected on
	/// the programme, or the first thing on it.
	private var spanForNewOverlay: Overlay.Span {
		let source = selectedPath.flatMap { project.entry(at: $0)?.source } ?? project.timeline.first?.source
		switch source {
		case .group(let name, _):
			return .marks(from: .group(name), to: .group(name))
		case .clip(let reference):
			return .clips(from: reference, to: reference)
		default:
			return .clips(from: ClipReference("clip"), to: ClipReference("clip"))
		}
	}

	@objc private func addText() {
		var next = project
		next.overlays.append(Overlay(kind: .text("Caption", style: nil), span: spanForNewOverlay))
		pending = .overlay(next.overlays.count - 1)
		onChange?(next)
	}

	@objc private func addSpinner() {
		var next = project
		next.overlays.append(Overlay(
			kind: .spinner(Spinner(words: [SpinnerWord("Working")])), span: spanForNewOverlay,
			arrival: .fade(over: 0.3), departure: .fade(over: 0.3)))
		pending = .overlay(next.overlays.count - 1)
		onChange?(next)
	}

	@objc private func addEffect() {
		var next = project
		next.overlays.append(Overlay(
			kind: .effect(Effect()), span: spanForNewOverlay,
			arrival: .cut, departure: .fall(over: 1.5)))
		pending = .overlay(next.overlays.count - 1)
		onChange?(next)
	}

	@objc private func duplicateOverlay() {
		let row = overlayTable.selectedRow
		guard row >= 0, row < project.overlays.count else { return }
		var next = project
		next.overlays.insert(project.overlays[row], at: row + 1)
		pending = .overlay(row + 1)
		onChange?(next)
	}

	@objc private func removeOverlay() {
		let row = overlayTable.selectedRow
		guard row >= 0, row < project.overlays.count else { return }
		var next = project
		next.overlays.remove(at: row)
		pending = .output
		onChange?(next)
	}

	// MARK: - Loading

	public func reload(_ project: Project, vocabulary: ComposeDocument.Vocabulary) {
		self.project = project
		self.vocabulary = vocabulary
		roots = tree(project.timeline, at: [])

		let keep = pending ?? selection
		pending = nil
		outline.reloadData()
		overlayTable.reloadData()
		programmeHint.isHidden = !project.timeline.isEmpty
		overlayHint.isHidden = !project.overlays.isEmpty
		expandAll()

		switch keep {
		case .entry(let path):
			if let row = row(for: path) {
				outline.selectRowIndexes([row], byExtendingSelection: false)
			} else {
				outline.deselectAll(nil)
			}
			overlayTable.deselectAll(nil)
		case .overlay(let index) where index < project.overlays.count:
			overlayTable.selectRowIndexes([index], byExtendingSelection: false)
			outline.deselectAll(nil)
		default:
			outline.deselectAll(nil)
			overlayTable.deselectAll(nil)
		}
		selection = keep
		onSelect?(selection)
	}

	private var selection: ProjectSelection = .output

	private func tree(_ entries: [TimelineEntry], at prefix: [Int]) -> [Node] {
		entries.enumerated().map { index, entry in
			let path = prefix + [index]
			if case .group(_, let inner) = entry.source {
				return Node(path: path, entry: entry, children: tree(inner, at: path))
			}
			return Node(path: path, entry: entry, children: [])
		}
	}

	private func row(for path: [Int]) -> Int? {
		for row in 0..<outline.numberOfRows where (outline.item(atRow: row) as? Node)?.path == path {
			return row
		}
		return nil
	}

	/// Sections stand open unless somebody closed them. A collapsed section
	/// hides work, and the commonest reason a project looks empty is that it is
	/// not.
	private func expandAll() {
		func walk(_ nodes: [Node]) {
			for node in nodes where !node.children.isEmpty {
				if let name = node.groupName, collapsed.contains(name) {
					outline.collapseItem(node)
				} else {
					outline.expandItem(node)
				}
				walk(node.children)
			}
		}
		walk(roots)
	}

	// MARK: - Outline

	public func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
		((item as? Node)?.children ?? roots).count
	}

	public func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
		((item as? Node)?.children ?? roots)[index]
	}

	public func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
		(item as? Node)?.groupName != nil
	}

	public func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
		guard let node = item as? Node else { return nil }
		let view = (outlineView.makeView(withIdentifier: .init("entry"), owner: self) as? EntryRow)
			?? { let view = EntryRow(); view.identifier = .init("entry"); return view }()
		view.entry = node.entry
		view.count = node.children.count
		view.needsDisplay = true
		return view
	}

	public func outlineViewItemDidCollapse(_ notification: Notification) {
		if let name = (notification.userInfo?["NSObject"] as? Node)?.groupName { collapsed.insert(name) }
	}

	public func outlineViewItemDidExpand(_ notification: Notification) {
		if let name = (notification.userInfo?["NSObject"] as? Node)?.groupName { collapsed.remove(name) }
	}

	// MARK: - Dragging

	public func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
		guard let node = item as? Node else { return nil }
		let pasteboardItem = NSPasteboardItem()
		pasteboardItem.setString(node.path.map(String.init).joined(separator: "."), forType: Self.entryType)
		pasteboardItem.setString(node.entry.source.description, forType: .string)
		return pasteboardItem
	}

	public func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
	                        proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
		// Onto a clip means nothing — a clip holds nothing — so a drop there is
		// retargeted to the gap after it, which is what the pointer is over.
		if let node = item as? Node, node.groupName == nil {
			let parent = self.node(at: Array(node.path.dropLast()))
			outlineView.setDropItem(parent, dropChildIndex: (node.path.last ?? 0) + 1)
		}
		return info.draggingSource as? NSOutlineView === outlineView ? .move : .copy
	}

	public func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo,
	                        item: Any?, childIndex index: Int) -> Bool {
		let parent = (item as? Node)?.path ?? []
		let board = info.draggingPasteboard
		var next = project

		if let moved = board.string(forType: Self.entryType) {
			let from = moved.split(separator: ".").compactMap { Int($0) }
			// The arithmetic lives with the timeline, where it is tested. A drop
			// is a parent and an index; everything that shifts underneath it is
			// that method's business.
			pending = .entry(next.moveEntry(at: from, toParent: parent, index: index))
			onChange?(next)
			return true
		}

		guard let text = board.string(forType: .string),
		      let entry = try? TimelineEntry(text: text) else { return false }
		pending = .entry(next.insertEntry(entry, into: parent, at: index < 0 ? Int.max : index))
		onChange?(next)
		return true
	}

	private func node(at path: [Int]) -> Node? {
		guard !path.isEmpty else { return nil }
		var list = roots
		var found: Node?
		for index in path {
			guard index < list.count else { return nil }
			found = list[index]
			list = list[index].children
		}
		return found
	}


	// MARK: - Overlay list

	public func numberOfRows(in tableView: NSTableView) -> Int { project.overlays.count }

	public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
		guard row < project.overlays.count else { return nil }
		let view = (tableView.makeView(withIdentifier: .init("overlay"), owner: self) as? OverlayRow)
			?? { let view = OverlayRow(); view.identifier = .init("overlay"); return view }()
		view.overlay = project.overlays[row]
		view.stack = OverlayRow.standsOn(row, in: project.overlays)
		view.needsDisplay = true
		return view
	}

	// MARK: - Selection

	public func outlineViewSelectionDidChange(_ notification: Notification) {
		guard let path = selectedPath else { return }
		if overlayTable.selectedRow >= 0 { overlayTable.deselectAll(nil) }
		selection = .entry(path)
		onSelect?(selection)
	}

	public func tableViewSelectionDidChange(_ notification: Notification) {
		let row = overlayTable.selectedRow
		guard row >= 0, row < project.overlays.count else { return }
		if outline.selectedRow >= 0 { outline.deselectAll(nil) }
		selection = .overlay(row)
		onSelect?(selection)
	}

	/// Clears the selection back to the project itself, which is what the
	/// output properties are about.
	public func selectOutput() {
		outline.deselectAll(nil)
		overlayTable.deselectAll(nil)
		selection = .output
		onSelect?(selection)
	}

	// MARK: - Rows

	/// One entry, drawn: what kind of thing it is, what it names, and how it
	/// arrives.
	final class EntryRow: NSTableCellView {
		var entry = TimelineEntry(clip: ClipReference(""))
		var count = 0

		override func draw(_ dirtyRect: NSRect) {
			let kind: Theme.Kind
			switch entry.source {
			case .clip: kind = .clip
			case .list: kind = .list
			case .query: kind = .query
			case .group: kind = .section
			}
			var x: CGFloat = 4
			if let image = Theme.symbol(kind, size: 13) {
				Theme.draw(image, in: NSRect(x: x, y: bounds.height / 2 - 8, width: 20, height: 16))
			}
			x += 22

			(entry.source.description as NSString).draw(
				at: NSPoint(x: x, y: bounds.height / 2 - 7),
				withAttributes: [.font: Theme.bodyStrong, .foregroundColor: Theme.text])
			x += (entry.source.description as NSString)
				.size(withAttributes: [.font: Theme.bodyStrong]).width + 10

			if case .group = entry.source {
				x = note("\(count) entr\(count == 1 ? "y" : "ies")", at: x) + 10
			}
			// A trimmed placement looks exactly like an untrimmed one otherwise,
			// and the same clip appearing twice in a section is usually two
			// different lengths of it. Said here so the list is the truth about
			// what is on the programme rather than about what was referenced.
			if let trimmed = Self.trimmed(entry) {
				x = note(trimmed, at: x) + 10
			}
			// How it arrives, in the accent the transition controls use, so a
			// programme with three dissolves in it can be found by eye.
			if let arrival = Self.arrival(entry) {
				_ = note(arrival, at: x, colour: Theme.color(.section))
			}
		}

		/// How this entry arrives from the one before, or nothing for a cut —
		/// which is what most of them are, and a list that says `cut` forty
		/// times says nothing at all.
		static func arrival(_ entry: TimelineEntry) -> String? {
			guard entry.transition.duration > 0 else { return nil }
			return "⤫ \(entry.transition.kind.title) "
				+ "\(TakeWriter.number(entry.transition.seconds, places: 2))s"
		}

		/// What is taken off this placement, or nothing when it is whole. Only
		/// the ends that are actually trimmed, because `tail 00:00.000` is a
		/// column of noughts that says nothing.
		static func trimmed(_ entry: TimelineEntry) -> String? {
			var parts: [String] = []
			if entry.trim.head > 0 { parts.append("head −\(Timecode.string(entry.trim.head))") }
			if entry.trim.tail > 0 { parts.append("tail −\(Timecode.string(entry.trim.tail))") }
			return parts.isEmpty ? nil : parts.joined(separator: "  ")
		}

		@discardableResult
		private func note(_ text: String, at x: CGFloat,
		                  colour: NSColor = Theme.dimText) -> CGFloat {
			let attributes: [NSAttributedString.Key: Any] = [
				.font: Theme.monoSmall, .foregroundColor: colour,
			]
			(text as NSString).draw(at: NSPoint(x: x, y: bounds.height / 2 - 6), withAttributes: attributes)
			return x + (text as NSString).size(withAttributes: attributes).width
		}
	}

	/// One overlay, drawn: what it says, when it is on, what it follows, and
	/// what it is drawn on top of.
	fileprivate final class OverlayRow: NSTableCellView {
		var overlay = Overlay(kind: .text("", style: nil), span: .times(from: 0, to: 0))
		/// Where this one comes in the stack, in words. Worked out by the panel,
		/// which is the only thing that can see the rest of the list.
		var stack = ""

		/// What an overlay is drawn on top of.
		///
		/// The order of `overlays:` is the order they are drawn in, so the row
		/// above is what a row sits on. With one exception, and it is worth
		/// saying rather than hiding: a caption, a spinner and a scene are not
		/// drawn into the frame at all — the export lays them over the finished
		/// picture in a second Core Animation pass, which cannot interleave with
		/// pixels. So one of those is over every film mode and every effect in
		/// the project however the list is arranged, and moving it only decides
		/// which caption is over which.
		static func standsOn(_ index: Int, in overlays: [Overlay]) -> String {
			guard index < overlays.count else { return "" }
			let layered = OverlayLayers.isLayered(overlays[index])
			let below = overlays[..<index].lastIndex { OverlayLayers.isLayered($0) == layered }
			let over = below.map { "over \(name(overlays[$0]))" }
			if layered { return over.map { "layer · \($0)" } ?? "layer · over all of it" }
			return over ?? "on the picture"
		}

		/// The shortest true name for one, for the row above's benefit.
		static func name(_ overlay: Overlay) -> String {
			switch overlay.kind {
			case .effect(let effect): return effect.style.rawValue
			case .film: return "film"
			case .aberration: return "aberration"
			case .tape: return "tape"
			case .scene(let scene, _): return scene
			case .text(let text, _): return "“\(text)”"
			case .spinner: return "spinner"
			}
		}

		override func draw(_ dirtyRect: NSRect) {
			let kind: Theme.Kind
			let title: String
			switch overlay.kind {
			case .effect(let effect):
				kind = .effect
				title = "\(effect.style.rawValue) ×\(effect.count)"
			case .film(let film):
				kind = .film
				title = "\(film.tint.rawValue) · \(film.ratio.written)"
			case .aberration(let aberration):
				kind = .aberration
				title = "\(aberration.kind.rawValue) · \(TakeWriter.number(aberration.amount, places: 2))"
			case .tape(let tape):
				kind = .tape
				title = "tape · \(tape.condition.rawValue)"
			case .scene(let name, let parameters):
				kind = .scene
				title = parameters.isEmpty ? name
					: "\(name) — \(parameters.values.sorted().joined(separator: ", "))"
			case .text(let text, _):
				kind = .text
				title = "“\(text)”"
			case .spinner(let spinner):
				kind = .spinner
				title = spinner.words.isEmpty
					? "spinner (\(spinner.style.rawValue))"
					: spinner.words.map(\.text).joined(separator: " · ")
			}

			if let image = Theme.symbol(kind, size: 13) {
				Theme.draw(image, in: NSRect(x: 3, y: bounds.height / 2 - 8, width: 20, height: 16))
			}

			// Measured from the middle outwards, so the two lines keep clear of
			// each other whatever the row height turns out to be.
			(title as NSString).draw(
				at: NSPoint(x: 26, y: bounds.midY + 1),
				withAttributes: [.font: Theme.bodyStrong, .foregroundColor: Theme.text])

			var where_ = ""
			switch overlay.span {
			case .within(let mark, let from, let to):
				where_ = "\(mark.description) + \(Timecode.string(from)) → \(Timecode.string(to))"
			case .marks(let from, let to):
				where_ = from == to ? "over \(from.description)"
					: "\(from.description) → \(to.description)"
			case .times(let from, let to):
				where_ = "\(Timecode.string(from)) → \(Timecode.string(to))"
			}
			if let anchor = overlay.anchor { where_ += "   ⌖ \(anchor)" }
			// What it is drawn on top of, which is the one thing about an
			// overlay that cannot be seen from the overlay itself.
			if !stack.isEmpty { where_ += "   ↑ \(stack)" }
			(where_ as NSString).draw(
				at: NSPoint(x: 26, y: bounds.midY - 14),
				withAttributes: [.font: Theme.monoSmall, .foregroundColor: Theme.dimText])
		}
	}
}
