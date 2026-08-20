import AppKit
import CuttrCompose
import CuttrKit

/// What is selected, and therefore what the properties panel is about.
public enum ProjectSelection: Equatable {
	case output
	case entry([Int])
	case overlay(Int)
	case sound(Int)
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
	/// Somebody wants to see where this placement came from: the take, at the
	/// first frame this use of the clip shows. The panel knows which entry was
	/// pointed at; the window knows how to open a take.
	public var onOpenInTake: (([Int]) -> Void)?
	/// Somebody wants to see one section on its own: play from where it starts
	/// to where it ends and stop there.
	public var onPreviewSection: ((String) -> Void)?

	private var project = Project()
	private var roots: [Node] = []
	private var vocabulary = ComposeDocument.Vocabulary()
	private var collapsed: Set<String> = []

	private let outline = MenuOutline()
	/// The programme as it resolved, for deciding which overlays are on over
	/// what is selected. Set by the window; nothing here needs it to draw.
	public var resolved: ResolvedProject? {
		didSet { overlayTable.reloadData() }
	}
	/// Only the overlays that are on over what is selected.
	private var filtering = false
	/// Which overlay each row of the table is, which stops being the identity
	/// the moment the list is filtered. Everything that acts on a row goes
	/// through this — a duplicate or a delete addressed by row number would
	/// otherwise take the wrong overlay off.
	private var overlayRows: [Int] = []

	private let overlayTable = KeyTable()
	private let soundTable = KeyTable()
	/// What to do when there is nothing there yet. An empty list that says
	/// nothing looks like a list that is broken.
	private let programmeHint = ProgrammePanel.hint(
		"Drag a clip or a #tag from the library, or press + Clip")
	private let overlayHint = ProgrammePanel.hint(
		"Select where it should go on the timeline, then pick a kind from +")
	private let soundHint = ProgrammePanel.hint(
		"Music, an atmosphere, a sting — a file, and when it plays")

	/// Dragging an entry means dragging its position, so the position is what
	/// travels: `0.2.1` is the second entry of the third entry of the first.
	private static let entryType = NSPasteboard.PasteboardType("de.rnd7.cuttr.entry")
	/// A scene, dragged. Its own type rather than plain text because plain text
	/// dropped on the programme is read as a clip reference, and a scene is not
	/// one: it is a thing to be *drawn*, and what it needs underneath it is a
	/// card.
	public static let sceneType = NSPasteboard.PasteboardType("de.rnd7.cuttr.scene")

	// MARK: - Tree

	/// One entry, wrapped so the outline view has an object to hold on to.
	fileprivate final class Node: NSObject {
		let path: [Int]
		let entry: TimelineEntry
		let children: [Node]
		/// Which overlay this row is, when it is an overlay rather than an
		/// entry — the tree shows both, because an overlay hung on a clip is
		/// part of the structure of the programme and looking for it in a
		/// second list is how somebody loses it.
		let overlay: Int?
		/// The heading the overlays that hang on nothing in particular live
		/// under. Closed to begin with: they are the exception.
		let isOverlayRoot: Bool

		init(path: [Int], entry: TimelineEntry, children: [Node],
		     overlay: Int? = nil, isOverlayRoot: Bool = false) {
			self.path = path
			self.entry = entry
			self.children = children
			self.overlay = overlay
			self.isOverlayRoot = isOverlayRoot
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
		let sounds = buildSounds()

		// The cut above, what is laid over it under that, and what is laid
		// under it at the bottom — in the order they happen: a caption is drawn
		// over a clip that has to exist first, and music goes under the lot.
		let split = NSSplitView()
		split.isVertical = false
		split.dividerStyle = .thin
		split.addArrangedSubview(programme)
		split.addArrangedSubview(overlays)
		split.addArrangedSubview(sounds)
		split.translatesAutoresizingMaskIntoConstraints = false
		addSubview(split)
		NSLayoutConstraint.activate([
			split.topAnchor.constraint(equalTo: topAnchor),
			split.bottomAnchor.constraint(equalTo: bottomAnchor),
			split.leadingAnchor.constraint(equalTo: leadingAnchor),
			split.trailingAnchor.constraint(equalTo: trailingAnchor),
			programme.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
			overlays.heightAnchor.constraint(greaterThanOrEqualToConstant: 100),
			sounds.heightAnchor.constraint(greaterThanOrEqualToConstant: 80),
		])
	}

	@available(*, unavailable) required init?(coder: NSCoder) { nil }

	// MARK: - Furniture

	/// A titled pane: heading, list, and the buttons that act on it.
	private func pane(_ title: String, _ list: NSView, _ buttons: [NSView]) -> NSView {
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
	/// Show only the overlays that are on over what is selected.
	///
	/// A programme with twenty overlays on it is a list nobody can read while
	/// working on one shot. The bar down the side of a row says which ones have
	/// something to do with the selection; this hides the rest.
	private lazy var filterButton: NSButton = {
		let button = self.button("line.3.horizontal.decrease.circle", #selector(toggleFilter),
		                         "Only the overlays that are on over what is selected")
		return button
	}()

	@objc private func toggleFilter() {
		filtering.toggle()
		filterButton.image = NSImage(
			systemSymbolName: filtering
				? "line.3.horizontal.decrease.circle.fill"
				: "line.3.horizontal.decrease.circle",
			accessibilityDescription: "filter")?
			.withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
		filterButton.contentTintColor = filtering ? Theme.accent : nil
		overlayTable.reloadData()
	}

	/// The kinds an overlay can be, behind one `+`.
	///
	/// A pull-down, so the face of it stays `+` rather than becoming whatever
	/// was added last: this is a verb, not a choice being remembered.
	/// For the tests: the menu behind the `+`, without a window to click in.
	func addOverlayMenu() -> NSMenu? { addMenu().menu }

	private func addMenu() -> NSPopUpButton {
		let button = NSPopUpButton(frame: .zero, pullsDown: true)
		button.bezelStyle = .rounded
		button.controlSize = .small
		button.toolTip = "Add an overlay, bound to what is selected"
		button.translatesAutoresizingMaskIntoConstraints = false
		button.widthAnchor.constraint(equalToConstant: 44).isActive = true

		// The first item of a pull-down is its face and is never chosen.
		let face = NSMenuItem(title: "", action: nil, keyEquivalent: "")
		face.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "add")?
			.withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
		button.menu?.addItem(face)

		for (title, symbol, kind, action) in [
			("Caption", "textformat", Theme.Kind.text, #selector(addText)),
			("Spinner", "circle.dotted", .spinner, #selector(addSpinner)),
			("Scene", "rectangle.stack", .scene, #selector(addScene)),
			("Effect", "sparkles", .effect, #selector(addEffect)),
			("Film mode", "camera.filters", .film, #selector(addFilm)),
			("Chromatic aberration", "circle.hexagongrid", .aberration, #selector(addAberration)),
			("VHS tape", "tv.badge.wifi", .tape, #selector(addTape)),
		] as [(String, String, Theme.Kind, Selector)] {
			let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
			item.target = self
			item.image = Theme.symbol(kind, size: 12)
				?? NSImage(systemSymbolName: symbol, accessibilityDescription: title)
			button.menu?.addItem(item)
		}
		return button
	}

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
		outline.onMenu = { [weak self] event in self?.outlineMenu(for: event) }
		// Delete takes the selected entry off the programme, which is what the
		// minus button beside it does. A list somebody can select a row in and
		// not delete from is a list that has to be explained.
		outline.onKey = { [weak self] event in
			guard isDelete(event), self?.selectedPath != nil else { return false }
			self?.removeEntry()
			return true
		}
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
		outline.registerForDraggedTypes([.string, Self.entryType, Self.sceneType])
		// Several at once: a programme is re-ordered in handfuls more often
		// than one at a time, and delete on four selected rows should take four
		// off rather than the last one clicked.
		outline.allowsMultipleSelection = true
		outline.setDraggingSourceOperationMask(.move, forLocal: true)

		let scroll = TableScroll.fitting(outline)
		over(scroll, programmeHint)
		// "Timeline", not "programme".
		//
		// The programme is the finished film — what the clock belongs to, what
		// a card takes time on, what an overlay is drawn over — and this pane
		// is not that. It is the tree of entries the file calls `timeline:`,
		// and calling it by the key it writes is the same rule every label in
		// the properties panel follows.
		return pane("timeline", scroll, [
			button("plus", #selector(addClip), "Add a clip by slug, or a #tag query"),
			button("folder.badge.plus", #selector(addGroup),
			       "Add a named section overlays can be hung on"),
			button("rectangle.fill", #selector(addCard),
			       "Add a card: time on the timeline with nothing behind it"),
			button("plus.square.on.square", #selector(duplicateEntry), "Another one just like it"),
			button("arrow.up", #selector(moveEntryUp), "Earlier"),
			button("arrow.down", #selector(moveEntryDown), "Later"),
			button("minus", #selector(removeEntry), "Take it off the timeline"),
		])
	}

	/// The `as:` name of a placement and whatever hangs on it.
	///
	/// An overlay hangs on a *name*, so this is the only place the two halves
	/// meet: the timeline knows what it named, the overlays know what they are
	/// pinned to, and a row that shows neither leaves somebody counting cards
	/// to work out which one their intro is on.
	func carried(by entry: TimelineEntry) -> String {
		guard let label = entry.label else { return "" }
		var out = "@\(label)"
		let names = project.overlays.compactMap { overlay -> String? in
			guard Self.hangs(overlay.span, on: label) else { return nil }
			switch overlay.kind {
			case .scene(let name, _): return "scene \(name)"
			case .text: return "caption"
			case .spinner: return "spinner"
			case .effect(let effect): return effect.style.rawValue
			case .film: return "film"
			case .aberration: return "aberration"
			case .tape: return "tape"
			}
		}
		if !names.isEmpty { out += " · " + names.joined(separator: ", ") }
		return out
	}

	/// Whether a span is pinned to this name, at either end.
	static func hangs(_ span: Overlay.Span, on label: String) -> Bool {
		func names(_ endpoint: Overlay.Span.Endpoint) -> Bool {
			if case .group(let name) = endpoint { return name == label }
			return false
		}
		switch span {
		case .marks(let from, let to): return names(from) || names(to)
		case .within(let mark, _, _): return names(mark)
		case .times: return false
		}
	}

	/// Which overlay a row of the table is.
	///
	/// The identity until the list is filtered, and never again after that.
	/// Everything that acts on the selected row asks this rather than using the
	/// row number, because a duplicate or a delete addressed by row would take
	/// the wrong overlay off a filtered list.
	private func overlay(at row: Int) -> Int? {
		guard row >= 0, row < overlayRows.count else { return nil }
		let index = overlayRows[row]
		return index < project.overlays.count ? index : nil
	}

	/// Which overlays are on over what is selected on the programme.
	///
	/// Measured on the clock rather than guessed from the names: an overlay
	/// written as `times:` has no name in it at all, and one hung on a section
	/// covers every clip in that section. What somebody means by "does this
	/// overlay play a role here" is "is it on while this is on screen", and the
	/// resolved programme is the only thing that knows.
	func overlaysOver(_ selection: ProjectSelection) -> Set<Int> {
		guard let resolved, case .entry(let path) = selection else { return [] }
		guard let span = span(of: path, in: resolved) else { return [] }
		var found: Set<Int> = []
		for shown in resolved.overlays
		where shown.start < span.end - 1e-6 && shown.end > span.start + 1e-6 {
			found.insert(shown.source)
		}
		return found
	}

	/// Where an entry sits on the programme's clock — a clip, a card, or a
	/// section with everything inside it.
	private func span(of path: [Int], in resolved: ResolvedProject) -> (start: Double, end: Double)? {
		if let clip = resolved.clips.first(where: { $0.entry == path }) {
			return (clip.start, clip.end)
		}
		if let card = resolved.cards.first(where: { $0.entry == path }) {
			return (card.start, card.end)
		}
		// A section: from the first thing inside it to the last, whatever those
		// are and however deeply they nest.
		let inside = resolved.clips.filter { $0.entry.starts(with: path) }.map { ($0.start, $0.end) }
			+ resolved.cards.filter { $0.entry.starts(with: path) }.map { ($0.start, $0.end) }
		guard let first = inside.map(\.0).min(), let last = inside.map(\.1).max() else { return nil }
		return (first, last)
	}

	/// For the tests: what the tree holds, as text.
	var treeRowsForTesting: [String] {
		var out: [String] = []
		func name(_ node: Node) -> String {
			if node.isOverlayRoot { return "loose" }
			if let label = node.entry.label { return "entry \(label)" }
			if case .group(let group, _) = node.entry.source { return "entry \(group)" }
			return "entry \(node.entry.source.description)"
		}
		func walk(_ nodes: [Node], under parent: String?) {
			for node in nodes {
				if let index = node.overlay {
					out.append("\(parent ?? "?") → overlay \(index)")
				} else {
					walk(node.children, under: name(node))
				}
			}
		}
		walk(roots, under: nil)
		return out
	}

	var looseHeadingIsOpenForTesting: Bool {
		guard let root = roots.first(where: { $0.isOverlayRoot }) else { return false }
		return outline.isItemExpanded(root)
	}

	/// For the tests: click a row without a mouse.
	func selectRow(_ row: Int) {
		guard row >= 0, row < outline.numberOfRows else { return }
		outline.selectRowIndexes([row], byExtendingSelection: false)
	}

	private var selectedPath: [Int]? {
		let node = outline.item(atRow: outline.selectedRow) as? Node
		guard node?.overlay == nil, node?.isOverlayRoot == false else { return nil }
		return node?.path
	}

	/// The overlay selected in the tree, if that is what is selected.
	private var selectedTreeOverlay: Int? {
		(outline.item(atRow: outline.selectedRow) as? Node)?.overlay
	}

	/// Every entry selected, in the order they appear.
	private var selectedPaths: [[Int]] {
		outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? Node)?.path }
	}

	@objc private func addClip() { insert(TimelineEntry(clip: ClipReference("clip"))) }
	@objc private func addGroup() { insert(TimelineEntry(group: "section", entries: [])) }
	/// Four seconds of black, named — because a card is nearly always there to
	/// have something drawn on it, and `@intro` is how the title finds it.
	@objc private func addCard() {
		insert(TimelineEntry(card: Card(duration: 4), label: "card"))
	}

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

	/// What Delete does, wherever the keyboard happens to be in this panel.
	///
	/// Exposed because a key press is not the only way to ask: a menu item will
	/// want the same thing, and the tests want it without a window.
	public func deleteSelected() {
		if selectedPath != nil { removeEntry() }
		else if overlayTable.selectedRow >= 0 { removeOverlay() }
		else if soundTable.selectedRow >= 0 { removeSound() }
	}

	@objc private func removeEntry() {
		// All of them, deepest and last first so each removal leaves the paths
		// of the rest where they were.
		let paths = selectedPaths
		if paths.count > 1 {
			var next = project
			for path in paths.sorted(by: { a, b in
				for (x, y) in zip(a, b) where x != y { return x > y }
				return a.count > b.count
			}) {
				next.removeEntry(at: path)
			}
			pending = .output
			onChange?(next)
			return
		}
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
		overlayTable.allowsMultipleSelection = true
		overlayTable.onKey = { [weak self] event in
			guard let self, isDelete(event), self.overlayTable.selectedRow >= 0 else { return false }
			self.removeOverlay()
			return true
		}
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
			// One menu rather than a button per kind. There were three of them
			// and seven kinds — a caption, a spinner and an effect had buttons
			// while a scene, film mode, the aberration and the tape could only
			// be reached by adding something else and changing what it was.
			// Another four buttons was not the answer to that.
			addMenu(),
			button("plus.square.on.square", #selector(duplicateOverlay), "Another one just like it"),
			filterButton,
			button("arrow.up", #selector(moveOverlayUp), "Draw it earlier — under the one above"),
			button("arrow.down", #selector(moveOverlayDown), "Draw it later — over the one below"),
			button("minus", #selector(removeOverlay), "Take it off"),
		])
	}

	private func buildSounds() -> NSView {
		soundTable.dataSource = self
		soundTable.delegate = self
		soundTable.allowsMultipleSelection = true
		soundTable.onKey = { [weak self] event in
			guard let self, isDelete(event), self.soundTable.selectedRow >= 0 else { return false }
			self.removeSound()
			return true
		}
		soundTable.rowHeight = 34
		soundTable.backgroundColor = Theme.panel
		soundTable.gridStyleMask = []
		soundTable.headerView = nil
		soundTable.intercellSpacing = NSSize(width: 0, height: 2)
		let column = NSTableColumn(identifier: .init("sound"))
		column.width = 420
		soundTable.addTableColumn(column)

		let scroll = TableScroll.fitting(soundTable)
		over(scroll, soundHint)
		return pane("sounds", scroll, [
			button("waveform", #selector(addSound),
			       "Add a sound under the programme: music, an atmosphere, a sting"),
			button("plus.square.on.square", #selector(duplicateSound), "Another one just like it"),
			button("minus", #selector(removeSound), "Take it off"),
		])
	}

	@objc private func addSound() {
		var next = project
		// Under speech more often than not, so it arrives at a level that will
		// not drown anybody and fades rather than starting flat out.
		next.sounds.append(Sound(
			file: "music.wav", span: spanForNewOverlay, gain: -6,
			arrival: .fade(over: 0.5), departure: .fade(over: 1.5)))
		pending = .sound(next.sounds.count - 1)
		onChange?(next)
	}

	@objc private func duplicateSound() {
		let row = soundTable.selectedRow
		guard row >= 0, row < project.sounds.count else { return }
		var next = project
		next.sounds.insert(project.sounds[row], at: row + 1)
		pending = .sound(row + 1)
		onChange?(next)
	}

	@objc private func removeSound() {
		let chosen = soundTable.selectedRowIndexes.filter { $0 < project.sounds.count }
		if chosen.count > 1 {
			var next = project
			for row in chosen.sorted(by: >) { next.sounds.remove(at: row) }
			pending = .output
			onChange?(next)
			return
		}
		let row = soundTable.selectedRow
		guard row >= 0, row < project.sounds.count else { return }
		var next = project
		next.sounds.remove(at: row)
		pending = .output
		onChange?(next)
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
		// Moved in the *project*, not in the list: with a filter on, the row
		// below may be five overlays further down, and what "under the one
		// above" means is the order they are drawn in.
		guard let index = overlay(at: overlayTable.selectedRow) else { return }
		let landing = index + offset
		guard landing >= 0, landing < project.overlays.count else { return }
		var next = project
		next.overlays.swapAt(index, landing)
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

	/// The kinds that had no way in until the menu existed.
	///
	/// A scene needs one to point at, and a project with none is told so rather
	/// than given an overlay that names nothing.
	@objc private func addScene() {
		guard let name = project.scenes.keys.sorted().first else {
			let alert = NSAlert()
			alert.messageText = "No scenes yet"
			alert.informativeText = "Make one with New ▸ Scene… beside the takes, "
				+ "then add it here."
			alert.runModal()
			return
		}
		add(.scene(name, with: [:]), arrival: .fade(over: 0.4), departure: .fade(over: 0.4))
	}

	@objc private func addFilm() {
		// The shape the bars close to is chosen against this programme: a shape
		// it already is would show nothing happening.
		let output = project.output.size
		let ratio = output.height > 0 && output.width / output.height >= 16.0 / 9
			? Film.Ratio(2.39, 1) : Film.Ratio(16, 9)
		add(.film(Film(ratio: ratio)), arrival: .fade(over: 1), departure: .fade(over: 1))
	}

	@objc private func addAberration() {
		add(.aberration(Aberration()), arrival: .fade(over: 0.4), departure: .fade(over: 0.4))
	}

	@objc private func addTape() {
		add(.tape(Tape()), arrival: .fade(over: 0.4), departure: .fade(over: 0.4))
	}

	/// One overlay, over whatever is selected, and selected itself afterwards.
	private func add(_ kind: Overlay.Kind, arrival: Overlay.Transition = .slide(.left, over: 0.4),
	                 departure: Overlay.Transition = .slide(.right, over: 0.4)) {
		var next = project
		next.overlays.append(Overlay(kind: kind, span: spanForNewOverlay,
		                             arrival: arrival, departure: departure))
		pending = .overlay(next.overlays.count - 1)
		onChange?(next)
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
		guard let index = overlay(at: overlayTable.selectedRow) else { return }
		var next = project
		next.overlays.insert(project.overlays[index], at: index + 1)
		pending = .overlay(index + 1)
		onChange?(next)
	}

	@objc private func removeOverlay() {
		let chosen = overlayTable.selectedRowIndexes.compactMap { overlay(at: $0) }
		if chosen.count > 1 {
			var next = project
			for index in chosen.sorted(by: >) { next.overlays.remove(at: index) }
			pending = .output
			onChange?(next)
			return
		}
		guard let index = overlay(at: overlayTable.selectedRow) else { return }
		var next = project
		next.overlays.remove(at: index)
		pending = .output
		onChange?(next)
	}

	// MARK: - Loading

	public func reload(_ project: Project, vocabulary: ComposeDocument.Vocabulary) {
		self.project = project
		self.vocabulary = vocabulary
		roots = tree(project.timeline, at: [])
		// And the ones that hang on nothing in particular, under a heading of
		// their own at the end, closed unless somebody opened it.
		let loose = looseOverlays()
		if !loose.isEmpty {
			roots.append(Node(
				path: [], entry: TimelineEntry(clip: ClipReference("")),
				children: loose.map {
					Node(path: [], entry: TimelineEntry(clip: ClipReference("")),
					     children: [], overlay: $0)
				},
				isOverlayRoot: true))
		}

		let keep = pending ?? selection
		pending = nil
		outline.reloadData()
		overlayTable.reloadData()
		soundTable.reloadData()
		programmeHint.isHidden = !project.timeline.isEmpty
		overlayHint.isHidden = !project.overlays.isEmpty
		soundHint.isHidden = !project.sounds.isEmpty
		expandAll()

		switch keep {
		case .entry(let path):
			if let row = row(for: path) {
				outline.selectRowIndexes([row], byExtendingSelection: false)
			} else {
				outline.deselectAll(nil)
			}
			overlayTable.deselectAll(nil)
			soundTable.deselectAll(nil)
		case .overlay(let index) where index < project.overlays.count:
			overlayTable.selectRowIndexes([index], byExtendingSelection: false)
			outline.deselectAll(nil)
			soundTable.deselectAll(nil)
		case .sound(let index) where index < project.sounds.count:
			soundTable.selectRowIndexes([index], byExtendingSelection: false)
			outline.deselectAll(nil)
			overlayTable.deselectAll(nil)
		default:
			outline.deselectAll(nil)
			overlayTable.deselectAll(nil)
			soundTable.deselectAll(nil)
		}
		selection = keep
		onSelect?(selection)
	}

	private var selection: ProjectSelection = .output

	private func tree(_ entries: [TimelineEntry], at prefix: [Int]) -> [Node] {
		entries.enumerated().map { index, entry in
			let path = prefix + [index]
			var children: [Node] = []
			if case .group(_, let inner) = entry.source {
				children = tree(inner, at: path)
			}
			// The overlays hung on this entry, under it. Structural rather than
			// by the clock: an overlay that names this clip or this section
			// *belongs* to it, while one that merely happens to be on while it
			// plays belongs to whatever it does name.
			children += overlaysNaming(entry).map {
				Node(path: path, entry: entry, children: [], overlay: $0)
			}
			return Node(path: path, entry: entry, children: children)
		}
	}

	/// The overlays that name an entry — by its `as:` label, by the section it
	/// is, or by the clip it plays.
	private func overlaysNaming(_ entry: TimelineEntry) -> [Int] {
		var names: Set<String> = []
		if let label = entry.label { names.insert("@" + label) }
		if case .group(let name, _) = entry.source { names.insert("@" + name) }
		if case .clip(let reference) = entry.source {
			names.insert(reference.description)
			names.insert(reference.slug)
		}
		return project.overlays.indices.filter { index in
			Self.endpoints(of: project.overlays[index]).contains { names.contains($0) }
		}
	}

	/// Every name an overlay's spans point at.
	static func endpoints(of overlay: Overlay) -> Set<String> {
		var found: Set<String> = []
		for appearance in overlay.appearances {
			switch appearance.span {
			case .marks(let from, let to):
				found.insert(from.description)
				found.insert(to.description)
			case .within(let mark, _, _):
				found.insert(mark.description)
			case .times:
				break
			}
		}
		return found
	}

	/// The overlays that hang on nothing the timeline names: written in
	/// programme times, or pointing at something that is not there.
	private func looseOverlays() -> [Int] {
		var named: Set<Int> = []
		func walk(_ entries: [TimelineEntry]) {
			for entry in entries {
				named.formUnion(overlaysNaming(entry))
				if case .group(_, let inner) = entry.source { walk(inner) }
			}
		}
		walk(project.timeline)
		return project.overlays.indices.filter { !named.contains($0) }
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
				// The loose overlays are the exception: they hang on the
				// programme's own clock rather than on anything in the tree, so
				// they are filed at the end and closed until asked for.
				if node.isOverlayRoot, !collapsed.contains("") {
					outline.collapseItem(node)
				} else if let name = node.groupName, collapsed.contains(name) {
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
		guard let node = item as? Node else { return false }
		return !node.children.isEmpty && node.overlay == nil
	}

	public func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
		guard let node = item as? Node else { return nil }
		// An overlay under the entry it hangs on, drawn as the overlay list
		// draws it, so the two agree about what a caption looks like.
		if let index = node.overlay, index < project.overlays.count {
			let row = (outlineView.makeView(withIdentifier: .init("treeOverlay"), owner: self)
				as? OverlayRow)
				?? { let made = OverlayRow(); made.identifier = .init("treeOverlay"); return made }()
			row.overlay = project.overlays[index]
			row.stack = ""
			row.plays = false
			row.needsDisplay = true
			return row
		}
		if node.isOverlayRoot {
			let label = NSTextField(labelWithString: "OVERLAYS ON THE PROGRAMME'S OWN CLOCK")
			label.font = Theme.heading
			label.textColor = Theme.faintText
			return label
		}
		let view = (outlineView.makeView(withIdentifier: .init("entry"), owner: self) as? EntryRow)
			?? { let view = EntryRow(); view.identifier = .init("entry"); return view }()
		view.entry = node.entry
		view.count = node.children.count
		view.carries = carried(by: node.entry)
		view.needsDisplay = true
		return view
	}

	public func outlineViewItemDidCollapse(_ notification: Notification) {
		if let node = notification.userInfo?["NSObject"] as? Node, node.isOverlayRoot {
			collapsed.remove("")
		}
		if let name = (notification.userInfo?["NSObject"] as? Node)?.groupName { collapsed.insert(name) }
	}

	public func outlineViewItemDidExpand(_ notification: Notification) {
		if let node = notification.userInfo?["NSObject"] as? Node, node.isOverlayRoot {
			// Opened by hand: it stays open until it is closed again.
			collapsed.insert("")
		}
		if let name = (notification.userInfo?["NSObject"] as? Node)?.groupName { collapsed.remove(name) }
	}

	// MARK: - Dragging

	public func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
		// An overlay is shown here but not moved here: where it goes is what it
		// hangs on, which is the `when:` field, not a position in a list.
		guard let node = item as? Node, node.overlay == nil, !node.isOverlayRoot else { return nil }
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
		dropItems(from: info.draggingPasteboard, into: (item as? Node)?.path ?? [], at: index)
	}

	/// What a drop does, without an `NSDraggingInfo` to make one.
	@discardableResult
	func dropItems(from board: NSPasteboard, into parent: [Int], at index: Int) -> Bool {
		var next = project

		// Every entry on the pasteboard, because a drag of four rows writes four
		// items. The arithmetic lives with the timeline, where it is tested: a
		// drop is a parent and an index, and everything that shifts underneath
		// it — including the other entries coming out — is that method's
		// business.
		let dragged = (board.pasteboardItems ?? []).compactMap { item in
			item.string(forType: Self.entryType)?
				.split(separator: ".").compactMap { Int($0) }
		}
		if !dragged.isEmpty {
			let landed = next.moveEntries(at: dragged, toParent: parent, index: index)
			pending = landed.last.map { ProjectSelection.entry($0) } ?? .output
			onChange?(next)
			return true
		}

		if let scene = board.string(forType: Self.sceneType) {
			return drop(scene: scene, into: parent, at: index, of: &next)
		}

		// Several clips dragged from the library arrive as several items, and
		// they go on in the order they were listed rather than all on top of
		// each other.
		let references = (board.pasteboardItems ?? []).compactMap { $0.string(forType: .string) }
		let entries = references.compactMap { try? TimelineEntry(text: $0) }
		guard !entries.isEmpty else { return false }
		var landed: [Int] = []
		for (offset, entry) in entries.enumerated() {
			landed = next.insertEntry(entry, into: parent,
			                          at: index < 0 ? Int.max : index + offset)
		}
		pending = .entry(landed)
		onChange?(next)
		return true
	}

	/// A scene dropped on the programme becomes an intro screen: a card with
	/// nothing behind it, and the scene drawn on that card.
	///
	/// Both, because a scene on its own has nowhere to be — an overlay hangs on
	/// a stretch of programme, and until the card exists there is no stretch.
	/// The card is named with `as:` and the overlay hangs on that name, so
	/// moving the card later takes the scene with it.
	///
	/// How long: the scene's own last keyframe, rounded up, because that is
	/// when it has finished happening. A scene with no keys gets four seconds,
	/// which is a title card.
	@discardableResult
	func dropScene(_ name: String, into parent: [Int], at index: Int) -> Bool {
		var next = project
		return drop(scene: name, into: parent, at: index, of: &next)
	}

	private func drop(scene name: String, into parent: [Int], at index: Int,
	                  of next: inout Project) -> Bool {
		guard let scene = project.scenes[name] else { return false }
		let last = scene.parts.flatMap { $0.keys }.map(\.t).max() ?? 0
		let seconds = last > 0.05 ? (last * 10).rounded(.up) / 10 : 4

		// The label has to be one nothing else answers to, or an overlay that
		// hangs on it would follow whichever came first.
		var label = name
		var suffix = 2
		let taken = Set(next.timeline.flatMap { entry -> [String] in
			entry.label.map { [$0] } ?? []
		})
		while taken.contains(label) {
			label = "\(name)-\(suffix)"
			suffix += 1
		}

		let card = TimelineEntry(source: .card(Card(duration: seconds)), label: label)
		let where_ = next.insertEntry(card, into: parent, at: index < 0 ? Int.max : index)
		next.overlays.append(Overlay(
			kind: .scene(name, with: [:]),
			span: .marks(from: .group(label), to: .group(label)),
			arrival: .fade(over: 0.4), departure: .fade(over: 0.4)))
		pending = .entry(where_)
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

	public func numberOfRows(in tableView: NSTableView) -> Int {
		if tableView === soundTable { return project.sounds.count }
		overlayRows = shownOverlays()
		return overlayRows.count
	}

	/// The overlays to list: all of them, or only the ones on over what is
	/// selected when the filter is on.
	private func shownOverlays() -> [Int] {
		let all = Array(project.overlays.indices)
		guard filtering else { return all }
		let playing = overlaysOver(selection)
		// Nothing selected, or a selection nothing is over: show everything
		// rather than an empty list, which reads as "there are no overlays".
		return playing.isEmpty ? all : all.filter { playing.contains($0) }
	}

	public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
		if tableView === soundTable {
			guard row < project.sounds.count else { return nil }
			let view = (tableView.makeView(withIdentifier: .init("sound"), owner: self) as? SoundRow)
				?? { let view = SoundRow(); view.identifier = .init("sound"); return view }()
			view.sound = project.sounds[row]
			view.needsDisplay = true
			return view
		}
		guard row < overlayRows.count else { return nil }
		let index = overlayRows[row]
		guard index < project.overlays.count else { return nil }
		let view = (tableView.makeView(withIdentifier: .init("overlay"), owner: self) as? OverlayRow)
			?? { let view = OverlayRow(); view.identifier = .init("overlay"); return view }()
		view.overlay = project.overlays[index]
		view.stack = OverlayRow.standsOn(index, in: project.overlays)
		// A bar down the left edge for the ones that are on over what is
		// selected: with twenty overlays on a programme, which of them this
		// clip has to do with is the question being asked.
		view.plays = overlaysOver(selection).contains(index)
		view.needsDisplay = true
		return view
	}

	// MARK: - Selection

	public func outlineViewSelectionDidChange(_ notification: Notification) {
		if let index = selectedTreeOverlay, index < project.overlays.count {
			if overlayTable.selectedRow >= 0 { overlayTable.deselectAll(nil) }
			if soundTable.selectedRow >= 0 { soundTable.deselectAll(nil) }
			selection = .overlay(index)
			onSelect?(selection)
			return
		}
		guard let path = selectedPath else { return }
		if overlayTable.selectedRow >= 0 { overlayTable.deselectAll(nil) }
		if soundTable.selectedRow >= 0 { soundTable.deselectAll(nil) }
		selection = .entry(path)
		// The bars down the side are about what is selected, so they change
		// when it does — and so does the list itself when the filter is on.
		overlayTable.reloadData()
		onSelect?(selection)
	}

	public func tableViewSelectionDidChange(_ notification: Notification) {
		guard let table = notification.object as? NSTableView else { return }
		let row = table.selectedRow
		if table === soundTable {
			guard row >= 0, row < project.sounds.count else { return }
			if outline.selectedRow >= 0 { outline.deselectAll(nil) }
			if overlayTable.selectedRow >= 0 { overlayTable.deselectAll(nil) }
			selection = .sound(row)
		} else {
			guard let index = overlay(at: row) else { return }
			if outline.selectedRow >= 0 { outline.deselectAll(nil) }
			if soundTable.selectedRow >= 0 { soundTable.deselectAll(nil) }
			selection = .overlay(index)
		}
		onSelect?(selection)
	}

	/// Clears the selection back to the project itself, which is what the
	/// output properties are about.
	public func selectOutput() {
		outline.deselectAll(nil)
		overlayTable.deselectAll(nil)
		soundTable.deselectAll(nil)
		selection = .output
		onSelect?(selection)
	}

	/// Right-click a row: what can be done to the entry under the pointer.
	///
	/// The row is selected first, because a menu that acts on the selection
	/// rather than on what was clicked is how somebody opens the wrong take.
	public func outlineMenu(for event: NSEvent) -> NSMenu? {
		let place = outline.convert(event.locationInWindow, from: nil)
		let row = outline.row(at: place)
		return rowMenu(row)
	}

	/// The menu for a row, whatever pointed at it.
	///
	/// Split out from the event because a right-click in a test is a coordinate
	/// nobody can predict — the rows are laid out by the outline, and a panel
	/// with no window has not necessarily laid them out at all.
	func rowMenu(_ row: Int) -> NSMenu? {
		guard row >= 0, let node = outline.item(atRow: row) as? Node else { return nil }
		outline.selectRowIndexes([row], byExtendingSelection: false)
		let menu = NSMenu()

		// A section: play it on its own. What somebody wants when they have
		// built one is to watch that and not the four minutes before it.
		if let name = node.groupName {
			let play = NSMenuItem(title: "Preview “\(name)” on its own",
			                      action: #selector(previewSection(_:)), keyEquivalent: "")
			play.target = self
			play.representedObject = name
			menu.addItem(play)
			return menu
		}

		guard case .clip(let reference) = node.entry.source else { return nil }
		let open = NSMenuItem(title: "Open “\(reference.slug)” in its take",
		                      action: #selector(openInTake(_:)), keyEquivalent: "")
		open.target = self
		open.representedObject = node.path
		menu.addItem(open)
		return menu
	}

	@objc private func previewSection(_ sender: NSMenuItem) {
		guard let name = sender.representedObject as? String else { return }
		onPreviewSection?(name)
	}

	@objc private func openInTake(_ sender: NSMenuItem) {
		guard let path = sender.representedObject as? [Int] else { return }
		onOpenInTake?(path)
	}

	// MARK: - Rows

	/// One entry, drawn: what kind of thing it is, what it names, and how it
	/// arrives.
	final class EntryRow: NSTableCellView {
		var entry = TimelineEntry(clip: ClipReference(""))
		var count = 0
		/// The name this placement was given with `as:`, and what hangs on it.
		/// Worked out by the panel, which is the only thing that can see the
		/// overlays as well as the timeline.
		var carries = ""

		override func draw(_ dirtyRect: NSRect) {
			let kind: Theme.Kind
			switch entry.source {
			case .clip: kind = .clip
			case .list: kind = .list
			case .query: kind = .query
			case .card: kind = .card
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
			// A card's own colour, drawn. The row says `card 00:04.000`, which
			// is how long it is and nothing about what anybody will see.
			if case .card(let card) = entry.source {
				let swatch = NSRect(x: x, y: bounds.height / 2 - 6, width: 18, height: 12)
				switch card.fill {
				case .solid(let colour):
					Self.colour(colour).setFill()
					swatch.fill()
				case .gradient(let top, let bottom):
					NSGradient(starting: Self.colour(bottom), ending: Self.colour(top))?
						.draw(in: swatch, angle: 90)
				}
				Theme.rule.setStroke()
				NSBezierPath(rect: swatch.insetBy(dx: 0.5, dy: 0.5)).stroke()
				x += 26
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
				x = note(arrival, at: x, colour: Theme.color(.section)) + 10
			}
			// What is *on* this stretch. A card is a hole in the programme —
			// black, one and a tenth seconds long — and the only interesting
			// thing about one is the scene somebody put on it, which was the
			// one thing the row did not say.
			if !carries.isEmpty {
				_ = note(carries, at: x, colour: Theme.color(.scene))
			}
		}

		static func colour(_ value: RGBA) -> NSColor {
			NSColor(calibratedRed: value.r, green: value.g, blue: value.b, alpha: value.a)
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

	/// One sound, drawn: the file, when it plays, and what it does to the
	/// programme underneath it.
	fileprivate final class SoundRow: NSTableCellView {
		var sound = Sound(file: "", span: .times(from: 0, to: 0))

		override func draw(_ dirtyRect: NSRect) {
			if let image = Theme.symbol(.sound, size: 13) {
				Theme.draw(image, in: NSRect(x: 3, y: bounds.height / 2 - 8, width: 20, height: 16))
			}
			// The file's own name, not the path: a column of `music/` says
			// nothing, and the folder is in the properties beside it.
			let name = (sound.file as NSString).lastPathComponent
			(name as NSString).draw(
				at: NSPoint(x: 26, y: bounds.midY + 1),
				withAttributes: [.font: Theme.bodyStrong, .foregroundColor: Theme.text])

			var where_ = ""
			switch sound.span {
			case .within(let mark, let from, let to):
				where_ = "\(mark.description) + \(Timecode.string(from)) → \(Timecode.string(to))"
			case .marks(let from, let to):
				where_ = from == to ? "under \(from.description)"
					: "\(from.description) → \(to.description)"
			case .times(let from, let to):
				where_ = "\(Timecode.string(from)) → \(Timecode.string(to))"
			}
			if sound.gain != 0 { where_ += "   \(TakeWriter.number(sound.gain, places: 1)) dB" }
			if sound.ducks != 0 { where_ += "   ducks \(TakeWriter.number(sound.ducks, places: 1))" }
			(where_ as NSString).draw(
				at: NSPoint(x: 26, y: bounds.midY - 14),
				withAttributes: [.font: Theme.monoSmall, .foregroundColor: Theme.dimText])
		}
	}

	/// One overlay, drawn: what it says, when it is on, what it follows, and
	/// what it is drawn on top of.
	fileprivate final class OverlayRow: NSTableCellView {
		var overlay = Overlay(kind: .text("", style: nil), span: .times(from: 0, to: 0))
		/// Where this one comes in the stack, in words. Worked out by the panel,
		/// which is the only thing that can see the rest of the list.
		var stack = ""
		/// On over whatever is selected on the programme.
		var plays = false

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
			// The bar first, so everything else is drawn over it: it is the
			// edge of the row rather than a thing in it.
			if plays {
				Theme.accent.setFill()
				NSRect(x: 0, y: 1, width: 3, height: bounds.height - 2).fill()
			}
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
