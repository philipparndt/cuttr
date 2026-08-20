import AppKit
import CuttrCompose
import CuttrKit

/// What is selected, and therefore what the properties panel is about.
public enum ProjectSelection: Equatable {
	case output
	case entry([Int])
	/// An overlay, wherever it is written: the top-level list, or inside one
	/// timeline entry. The panel edits both through the same form, so it
	/// carries the address rather than an index into one particular list.
	case overlay(Origin)
	/// A sound, on the same terms.
	case sound(Origin)
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
public final class ProgrammePanel: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {

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
		didSet { outline.reloadData() }
	}
	/// Which kinds of thing the tree shows besides the timeline itself.
	///
	/// This is what used to be two more panes. An overlay is already in the
	/// tree — nested under the entry it hangs on, which is where somebody looks
	/// for it — so a second list of the same overlays was the same information
	/// drawn twice and a third of the column to draw it in. Turning `sounds`
	/// off gives the old OVERLAYS pane; turning `overlays` off gives SOUNDS;
	/// turning both off gives the timeline on its own.
	private var showsOverlays = true
	private var showsSounds = true

	/// What to do when there is nothing there yet. An empty list that says
	/// nothing looks like a list that is broken.
	private let programmeHint = ProgrammePanel.hint(
		"Drag a clip or a #tag from the library, or press + Clip")

	/// Dragging an entry means dragging its position, so the position is what
	/// travels: `0.2.1` is the second entry of the third entry of the first.
	private static let entryType = NSPasteboard.PasteboardType("de.rnd7.cuttr.entry")
	/// An overlay or a sound being dragged from one home to another, which is a
	/// different question from where an entry goes and so a different type.
	private static let carriedType = NSPasteboard.PasteboardType("de.rnd7.cuttr.carried")
	/// A scene, dragged. Its own type rather than plain text because plain text
	/// dropped on the programme is read as a clip reference, and a scene is not
	/// one: it is a thing to be *drawn*, and what it needs underneath it is a
	/// card.
	public static let sceneType = NSPasteboard.PasteboardType("de.rnd7.cuttr.scene")

	// MARK: - Tree

	/// What a row that is not a timeline entry holds.
	///
	/// An overlay and a sound are addressed the same way and moved between the
	/// same homes, and the tree files both under whatever they belong to — so
	/// they are one case each of one thing rather than two parallel fields that
	/// have to be checked in the same order everywhere.
	enum Carried: Equatable {
		case overlay(Origin)
		case sound(Origin)

		var selection: ProjectSelection {
			switch self {
			case .overlay(let origin): return .overlay(origin)
			case .sound(let origin): return .sound(origin)
			}
		}

		var home: Project.Home {
			switch self {
			case .overlay(let origin), .sound(let origin): return Project.home(of: origin)
			}
		}
	}

	/// One entry, wrapped so the outline view has an object to hold on to.
	fileprivate final class Node: NSObject {
		let path: [Int]
		let entry: TimelineEntry
		let children: [Node]
		/// What this row is, when it is not an entry — the tree shows the
		/// overlays and the sounds too, because something hung on a clip is
		/// part of the structure of the programme and looking for it in a
		/// second list is how somebody loses it.
		let carried: Carried?

		/// The overlay this row is, for the places that are only about those.
		var overlay: Origin? {
			if case .overlay(let origin) = carried { return origin }
			return nil
		}
		/// The heading the overlays that hang on nothing in particular live
		/// under. Closed to begin with: they are the exception.
		let isOverlayRoot: Bool
		/// Filed under that heading rather than under an entry: this one hangs
		/// on the programme's own clock, so whether it has anything to do with
		/// what is selected is a real question rather than an obvious one.
		let isLoose: Bool

		init(path: [Int], entry: TimelineEntry, children: [Node],
		     carried: Carried? = nil, isOverlayRoot: Bool = false, isLoose: Bool = false) {
			self.path = path
			self.entry = entry
			self.children = children
			self.carried = carried
			self.isOverlayRoot = isOverlayRoot
			self.isLoose = isLoose
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

		// One tree, the whole column.
		//
		// It was three panes stacked: the timeline, then a list of every overlay
		// in the project, then a list of every sound. Fifteen buttons in three
		// rows, and the middle pane listing things the top pane was already
		// showing — `spinner (bars)` drawn twice on one screen. The tree files
		// each of them under whatever it belongs to, which is the question
		// somebody is asking, and it gets the height back.
		let programme = buildOutline()
		programme.translatesAutoresizingMaskIntoConstraints = false
		addSubview(programme)
		NSLayoutConstraint.activate([
			programme.topAnchor.constraint(equalTo: topAnchor),
			programme.bottomAnchor.constraint(equalTo: bottomAnchor),
			programme.leadingAnchor.constraint(equalTo: leadingAnchor),
			programme.trailingAnchor.constraint(equalTo: trailingAnchor),
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
	/// What the tree shows, behind one control.
	///
	/// The two panes this replaces are these two menu items. A programme with
	/// twenty overlays on it is a tree nobody can read while working on one
	/// shot, and the answer is to stop drawing the kind that is not being worked
	/// on — not to draw all of them again somewhere else.
	private lazy var showsButton: NSPopUpButton = {
		let button = NSPopUpButton(frame: .zero, pullsDown: true)
		button.bezelStyle = .rounded
		button.controlSize = .small
		button.toolTip = "What the tree shows besides the timeline itself"
		button.translatesAutoresizingMaskIntoConstraints = false
		button.widthAnchor.constraint(equalToConstant: 40).isActive = true

		let face = NSMenuItem(title: "", action: nil, keyEquivalent: "")
		face.image = NSImage(systemSymbolName: "line.3.horizontal.decrease.circle",
		                     accessibilityDescription: "what the tree shows")?
			.withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
		button.menu?.addItem(face)
		for (title, kind, action) in [
			("Overlays", Theme.Kind.text, #selector(toggleOverlays)),
			("Sounds", Theme.Kind.sound, #selector(toggleSounds)),
		] {
			let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
			item.target = self
			item.image = Theme.symbol(kind, size: 12)
			item.state = .on
			button.menu?.addItem(item)
		}
		return button
	}()

	@objc private func toggleOverlays() {
		showsOverlays.toggle()
		showsButton.menu?.item(at: 1)?.state = showsOverlays ? .on : .off
		markFilter()
		reload(project, vocabulary: vocabulary)
	}

	@objc private func toggleSounds() {
		showsSounds.toggle()
		showsButton.menu?.item(at: 2)?.state = showsSounds ? .on : .off
		markFilter()
		reload(project, vocabulary: vocabulary)
	}

	/// The control says whether it is doing anything.
	private func markFilter() {
		let filtering = !(showsOverlays && showsSounds)
		showsButton.menu?.item(at: 0)?.image = NSImage(
			systemSymbolName: filtering
				? "line.3.horizontal.decrease.circle.fill"
				: "line.3.horizontal.decrease.circle",
			accessibilityDescription: "what the tree shows")?
			.withSymbolConfiguration(.init(pointSize: 11, weight: .medium)
				.applying(.init(paletteColors: [filtering ? Theme.accent : Theme.text])))
	}

	/// The kinds an overlay can be, behind one `+`.
	///
	/// A pull-down, so the face of it stays `+` rather than becoming whatever
	/// was added last: this is a verb, not a choice being remembered.
	/// For the tests: the menu behind the `+`, without a window to click in.
	func addOverlayMenu() -> NSMenu? { addMenu(includingEntries: false).menu }

	/// For the tests: the menu behind the timeline's own `+`.
	func addEntryMenu() -> NSMenu? { addMenu(includingEntries: true).menu }

	/// Everything the `+` menus and the `Add ▸` submenu can make.
	///
	/// One list, called from three places, because three lists of the same
	/// things is three lists that come apart. `nil` is a separator.
	private func additions(includingEntries: Bool) -> [(String, String, Theme.Kind, Selector)?] {
		var out: [(String, String, Theme.Kind, Selector)?] = []
		if includingEntries {
			out += [
				("Clip", "film", Theme.Kind.clip, #selector(addClip)),
				("Section", "folder", .section, #selector(addGroup)),
				("Card", "rectangle.fill", .card, #selector(addCard)),
				nil,
			]
		}
		out += [
			("Caption", "textformat", Theme.Kind.text, #selector(addText)),
			("Spinner", "circle.dotted", .spinner, #selector(addSpinner)),
			("Scene", "rectangle.stack", .scene, #selector(addScene)),
			("Effect", "sparkles", .effect, #selector(addEffect)),
			("Film mode", "camera.filters", .film, #selector(addFilm)),
			("Chromatic aberration", "circle.hexagongrid", .aberration, #selector(addAberration)),
			("VHS tape", "tv.badge.wifi", .tape, #selector(addTape)),
		]
		if includingEntries {
			out += [nil, ("Sound", "speaker.wave.2", Theme.Kind.sound, #selector(addSound))]
		}
		return out
	}

	private func additionItems(includingEntries: Bool) -> [NSMenuItem] {
		additions(includingEntries: includingEntries).map { entry in
			guard let (title, symbol, kind, action) = entry else { return .separator() }
			let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
			item.target = self
			item.image = Theme.symbol(kind, size: 12)
				?? NSImage(systemSymbolName: symbol, accessibilityDescription: title)
			return item
		}
	}

	private func addMenu(includingEntries: Bool) -> NSPopUpButton {
		let button = NSPopUpButton(frame: .zero, pullsDown: true)
		button.bezelStyle = .rounded
		button.controlSize = .small
		button.toolTip = includingEntries
			? "Add something, inside or after what is selected"
			: "Add an overlay, bound to what is selected"
		button.translatesAutoresizingMaskIntoConstraints = false
		button.widthAnchor.constraint(equalToConstant: 44).isActive = true

		// The first item of a pull-down is its face and is never chosen.
		let face = NSMenuItem(title: "", action: nil, keyEquivalent: "")
		face.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "add")?
			.withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
		button.menu?.addItem(face)
		for item in additionItems(includingEntries: includingEntries) { button.menu?.addItem(item) }
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
			guard let self, isDelete(event) else { return false }
			// A row in this tree is an entry, or something carried by one, and
			// Delete has to take either off — now that the tree is where they
			// are made and moved, it is also where they are removed from.
			if let carried = self.selectedTreeCarried {
				self.removeCarried(carried)
				return true
			}
			guard self.selectedPath != nil else { return false }
			self.removeEntry()
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
		outline.registerForDraggedTypes([.string, Self.entryType, Self.carriedType, Self.sceneType])
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
			// One `+` for everything that can go on a timeline, including the
			// overlays and the sounds — because where they go is *here*, inside
			// whatever is selected, and a caption added from a pane somewhere
			// else is a caption that then has to be told which shot it is about.
			addMenu(includingEntries: true),
			button("plus.square.on.square", #selector(duplicateSelected),
			       "Another one just like it"),
			// One pair of arrows, meaning what it means for whatever is
			// selected: earlier and later for an entry, under and over for an
			// overlay, because the order of `overlays:` is the order they are
			// drawn in.
			button("arrow.up", #selector(moveSelectedUp), "Earlier, or under the one above"),
			button("arrow.down", #selector(moveSelectedDown), "Later, or over the one below"),
			button("minus", #selector(removeSelected), "Take it off"),
			showsButton,
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

	/// Which overlays are on over what is selected on the programme.
	///
	/// Measured on the clock rather than guessed from the names: an overlay
	/// written as `times:` has no name in it at all, and one hung on a section
	/// covers every clip in that section. What somebody means by "does this
	/// overlay play a role here" is "is it on while this is on screen", and the
	/// resolved programme is the only thing that knows.
	func overlaysOver(_ selection: ProjectSelection) -> Set<Int> {
		guard let resolved, case .entry(let path) = selection else { return [] }
		guard let span = Project.extent(of: path, in: resolved) else { return [] }
		var found: Set<Int> = []
		for shown in resolved.overlays
		where shown.start < span.end - 1e-6 && shown.end > span.start + 1e-6 {
			// Only the ones in the top-level list: this answers the overlay
			// table, which lists that and nothing else. The nested ones are
			// already shown under the entry they belong to.
			if let index = shown.origin.projectIndex { found.insert(index) }
		}
		return found
	}


	/// For the tests: what the tree holds, as text.
	var treeRowsForTesting: [String] {
		var out: [String] = []
		func named(_ origin: Origin) -> String {
			switch origin {
			case .project(let index): return "\(index)"
			case .entry(let path, let index):
				return path.map(String.init).joined(separator: ".") + "#\(index)"
			}
		}
		func name(_ node: Node) -> String {
			if node.isOverlayRoot { return "loose" }
			if let label = node.entry.label { return "entry \(label)" }
			if case .group(let group, _) = node.entry.source { return "entry \(group)" }
			return "entry \(node.entry.source.description)"
		}
		func walk(_ nodes: [Node], under parent: String?) {
			for node in nodes {
				if case .overlay(let origin) = node.carried {
					out.append("\(parent ?? "?") → overlay \(named(origin))")
				} else if case .sound(let origin) = node.carried {
					out.append("\(parent ?? "?") → sound \(named(origin))")
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

	/// For the tests: how many rows the tree is showing.
	var rowCountForTesting: Int { outline.numberOfRows }

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

	/// What the tree has selected, when it is not a timeline entry.
	private var selectedTreeCarried: Carried? {
		(outline.item(atRow: outline.selectedRow) as? Node)?.carried
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
		// Inside a selected section rather than after it. A section is a place
		// to put things, and the commonest reason to have one selected is that
		// the next thing belongs in it.
		if let path = selectedPath, case .group = project.entry(at: path)?.source {
			pending = .entry(next.insertEntry(entry, into: path, at: Int.max))
		} else {
			next.insertEntry(entry, after: selectedPath)
		}
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

	// The buttons over the tree act on whatever the tree has selected, because
	// the tree holds three kinds of row now. A second set of buttons for the
	// other two kinds is what was just taken away.
	@objc private func duplicateSelected() {
		if let carried = selectedTreeCarried { duplicateCarried(carried) }
		else { duplicateEntry() }
	}

	@objc private func moveSelectedUp() {
		if let carried = selectedTreeCarried { moveCarried(carried, by: -1) }
		else { moveEntryUp() }
	}

	@objc private func moveSelectedDown() {
		if let carried = selectedTreeCarried { moveCarried(carried, by: 1) }
		else { moveEntryDown() }
	}

	@objc private func removeSelected() { deleteSelected() }

	/// What Delete does, wherever the keyboard happens to be in this panel.
	///
	/// Exposed because a key press is not the only way to ask: a menu item will
	/// want the same thing, and the tests want it without a window.
	public func deleteSelected() {
		if let carried = selectedTreeCarried { removeCarried(carried) }
		else if selectedPath != nil { removeEntry() }
	}

	/// Takes an overlay or a sound off, wherever in the file it is written.
	func removeCarried(_ carried: Carried) {
		var next = project
		switch carried {
		case .overlay(let origin): next.removeOverlay(at: origin)
		case .sound(let origin): next.removeSound(at: origin)
		}
		pending = .output
		onChange?(next)
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

	@objc private func addSound() {
		let home = homeForAdding
		// Under speech more often than not, so it arrives at a level that will
		// not drown anybody and fades rather than starting flat out. Written
		// inside the selected entry it plays for exactly that placement, and
		// says so by saying nothing about when.
		var next = project
		let landed = next.addSound(Sound(
			file: "music.wav", span: home == nil ? spanForNewOverlay : nil, gain: -6,
			arrival: .fade(over: 0.5), departure: .fade(over: 1.5)), into: home)
		pending = landed.map { ProjectSelection.sound($0) } ?? .output
		onChange?(next)
	}

	/// Up and down the stack, wherever the thing is written.
	///
	/// The order of `overlays:` is the order they are drawn in, so moving a row
	/// is the only control there is over what is on top of what: an aberration
	/// above a film overlay bends the bars, the same one below it leaves them
	/// clean. Captions are the exception, and the row says so.
	///
	/// One pair of arrows for the whole tree, because the tree holds both kinds
	/// of thing now and "the row above" is what somebody means either way.
	private func moveCarried(_ carried: Carried, by offset: Int) {
		var next = project
		switch carried {
		case .overlay(.project(let index)):
			let landing = index + offset
			guard landing >= 0, landing < project.overlays.count else { return }
			next.overlays.swapAt(index, landing)
			pending = .overlay(.project(landing))
		case .overlay(.entry(let path, let index)):
			let landing = index + offset
			guard let entry = project.entry(at: path),
			      landing >= 0, landing < entry.overlays.count else { return }
			next.editEntry(at: path) { $0.overlays.swapAt(index, landing) }
			pending = .overlay(.entry(path: path, index: landing))
		case .sound(.project(let index)):
			let landing = index + offset
			guard landing >= 0, landing < project.sounds.count else { return }
			next.sounds.swapAt(index, landing)
			pending = .sound(.project(landing))
		case .sound(.entry(let path, let index)):
			let landing = index + offset
			guard let entry = project.entry(at: path),
			      landing >= 0, landing < entry.sounds.count else { return }
			next.editEntry(at: path) { $0.sounds.swapAt(index, landing) }
			pending = .sound(.entry(path: path, index: landing))
		}
		onChange?(next)
	}

	/// Another one just like it, beside itself.
	private func duplicateCarried(_ carried: Carried) {
		var next = project
		switch carried {
		case .overlay(.project(let index)):
			guard index < project.overlays.count else { return }
			next.overlays.insert(project.overlays[index], at: index + 1)
			pending = .overlay(.project(index + 1))
		case .overlay(.entry(let path, let index)):
			guard let entry = project.entry(at: path), index < entry.overlays.count else { return }
			let copy = entry.overlays[index]
			next.editEntry(at: path) { $0.overlays.insert(copy, at: index + 1) }
			pending = .overlay(.entry(path: path, index: index + 1))
		case .sound(.project(let index)):
			guard index < project.sounds.count else { return }
			next.sounds.insert(project.sounds[index], at: index + 1)
			pending = .sound(.project(index + 1))
		case .sound(.entry(let path, let index)):
			guard let entry = project.entry(at: path), index < entry.sounds.count else { return }
			let copy = entry.sounds[index]
			next.editEntry(at: path) { $0.sounds.insert(copy, at: index + 1) }
			pending = .sound(.entry(path: path, index: index + 1))
		}
		onChange?(next)
	}

	/// Where a new overlay or sound is written: inside whatever is selected.
	///
	/// The point of the whole arrangement. Adding a caption while a shot is
	/// selected writes it inside that shot, where it covers that placement and
	/// needs no name to be found by — rather than at the end of a list, hung on
	/// a name somebody then has to invent.
	///
	/// The heading for the loose ones is the way to ask for the top-level list
	/// on purpose, and nothing selected means the same.
	private var homeForAdding: Project.Home {
		guard let node = outline.item(atRow: outline.selectedRow) as? Node,
		      !node.isOverlayRoot
		else { return nil }
		// A selected overlay adds a sibling beside itself, wherever it lives.
		if let origin = node.overlay { return Project.home(of: origin) }
		return node.path
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

	/// One overlay, where it will live, and selected afterwards.
	///
	/// Written inside the selected entry when there is one, with no range of
	/// its own — which is how the file says "all of this placement". At the top
	/// level it needs a range, so it gets one covering whatever is selected,
	/// which is what it has always got.
	private func add(_ kind: Overlay.Kind, arrival: Overlay.Transition = .slide(.left, over: 0.4),
	                 departure: Overlay.Transition = .slide(.right, over: 0.4)) {
		let home = homeForAdding
		let overlay = home == nil
			? Overlay(kind: kind, span: spanForNewOverlay, arrival: arrival, departure: departure)
			: Overlay(kind: kind, appearances: [], arrival: arrival, departure: departure)
		var next = project
		let landed = next.addOverlay(overlay, into: home)
		pending = landed.map { ProjectSelection.overlay($0) } ?? .output
		onChange?(next)
	}

	@objc private func addText() {
		add(.text("Caption", style: nil))
	}

	@objc private func addSpinner() {
		add(.spinner(Spinner(words: [SpinnerWord("Working")])),
		    arrival: .fade(over: 0.3), departure: .fade(over: 0.3))
	}

	@objc private func addEffect() {
		add(.effect(Effect()), arrival: .cut, departure: .fall(over: 1.5))
	}


	// MARK: - Loading

	public func reload(_ project: Project, vocabulary: ComposeDocument.Vocabulary) {
		self.project = project
		self.vocabulary = vocabulary
		roots = tree(project.timeline, at: [])
		// And the ones that hang on nothing in particular, under a heading of
		// their own at the end, closed unless somebody opened it.
		//
		// Always there, even with nothing under it, because it is a *place*:
		// dropping an overlay on it is how one is made global, and a target
		// that only exists once something is already in it cannot be the way
		// the first thing gets there.
		var loose: [Carried] = []
		if showsOverlays { loose += looseOverlays().map { Carried.overlay(.project($0)) } }
		if showsSounds { loose += looseSounds().map { Carried.sound(.project($0)) } }
		if showsOverlays || showsSounds {
			roots.append(Node(
				path: [], entry: TimelineEntry(clip: ClipReference("")),
				children: loose.map {
					Node(path: [], entry: TimelineEntry(clip: ClipReference("")),
					     children: [], carried: $0, isLoose: true)
				},
				isOverlayRoot: true))
		}

		let keep = pending ?? selection
		pending = nil
		outline.reloadData()
		programmeHint.isHidden = !project.timeline.isEmpty
		expandAll()

		switch keep {
		case .entry(let path):
			if let row = row(for: path) {
				outline.selectRowIndexes([row], byExtendingSelection: false)
			} else {
				outline.deselectAll(nil)
			}
		case .overlay(let origin) where project.overlay(at: origin) != nil,
		     .sound(let origin) where project.sound(at: origin) != nil:
			// The tree is the only place it is shown, wherever it is written.
			// Kept selected across a reload the same way an entry is.
			var carried = Carried.overlay(origin)
			if case .sound = keep { carried = .sound(origin) }
			if let row = row(for: carried) {
				outline.selectRowIndexes([row], byExtendingSelection: false)
			} else {
				outline.deselectAll(nil)
			}
		default:
			outline.deselectAll(nil)
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
			// What this entry carries, under it — the ones written inside it
			// first, because those *are* part of the entry.
			if showsOverlays {
				children += entry.overlays.indices.map {
					Node(path: path, entry: entry, children: [],
					     carried: .overlay(.entry(path: path, index: $0)))
				}
			}
			if showsSounds {
				children += entry.sounds.indices.map {
					Node(path: path, entry: entry, children: [],
					     carried: .sound(.entry(path: path, index: $0)))
				}
			}
			// And the ones from the top-level lists that name it. Structural
			// rather than by the clock: an overlay that names this clip or this
			// section *belongs* to it, while one that merely happens to be on
			// while it plays belongs to whatever it does name.
			if showsOverlays {
				children += overlaysNaming(entry).map {
					Node(path: path, entry: entry, children: [], carried: .overlay(.project($0)))
				}
			}
			if showsSounds {
				children += soundsNaming(entry).map {
					Node(path: path, entry: entry, children: [], carried: .sound(.project($0)))
				}
			}
			return Node(path: path, entry: entry, children: children)
		}
	}

	/// Every name an entry answers to — its `as:` label, the section it is, or
	/// the clip it plays.
	static func names(of entry: TimelineEntry) -> Set<String> {
		var names: Set<String> = []
		if let label = entry.label { names.insert("@" + label) }
		if case .group(let name, _) = entry.source { names.insert("@" + name) }
		if case .clip(let reference) = entry.source {
			names.insert(reference.description)
			names.insert(reference.slug)
		}
		return names
	}

	/// The overlays from the top-level list that name an entry.
	private func overlaysNaming(_ entry: TimelineEntry) -> [Int] {
		let names = Self.names(of: entry)
		return project.overlays.indices.filter { index in
			Self.endpoints(of: project.overlays[index]).contains { names.contains($0) }
		}
	}

	/// The sounds from the top-level list that name one, by the same rule.
	private func soundsNaming(_ entry: TimelineEntry) -> [Int] {
		let names = Self.names(of: entry)
		return project.sounds.indices.filter { index in
			guard let span = project.sounds[index].span else { return false }
			return Self.endpoints(of: span).contains { names.contains($0) }
		}
	}

	/// Every name an overlay's spans point at.
	static func endpoints(of overlay: Overlay) -> Set<String> {
		overlay.appearances.reduce(into: Set<String>()) {
			$0.formUnion(endpoints(of: $1.span))
		}
	}

	/// And the names one span points at.
	static func endpoints(of span: Overlay.Span) -> Set<String> {
		switch span {
		case .marks(let from, let to): return [from.description, to.description]
		case .within(let mark, _, _): return [mark.description]
		case .times: return []
		}
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

	/// The sounds that name nothing the timeline names.
	private func looseSounds() -> [Int] {
		var named: Set<Int> = []
		func walk(_ entries: [TimelineEntry]) {
			for entry in entries {
				named.formUnion(soundsNaming(entry))
				if case .group(_, let inner) = entry.source { walk(inner) }
			}
		}
		walk(project.timeline)
		return project.sounds.indices.filter { !named.contains($0) }
	}

	private func row(for path: [Int]) -> Int? {
		for row in 0..<outline.numberOfRows
		where (outline.item(atRow: row) as? Node).map({ $0.overlay == nil && $0.path == path }) == true {
			return row
		}
		return nil
	}

	private func row(for carried: Carried) -> Int? {
		for row in 0..<outline.numberOfRows
		where (outline.item(atRow: row) as? Node)?.carried == carried {
			return row
		}
		return nil
	}

	/// Whether what a row points at is still in the project.
	private func exists(_ carried: Carried) -> Bool {
		switch carried {
		case .overlay(let origin): return project.overlay(at: origin) != nil
		case .sound(let origin): return project.sound(at: origin) != nil
		}
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
		if case .overlay(let origin) = node.carried, let overlay = project.overlay(at: origin) {
			let row = (outlineView.makeView(withIdentifier: .init("treeOverlay"), owner: self)
				as? OverlayRow)
				?? { let made = OverlayRow(); made.identifier = .init("treeOverlay"); return made }()
			row.overlay = overlay
			row.stack = origin.projectIndex
				.map { OverlayRow.standsOn($0, in: project.overlays) } ?? ""
			// A mark on the ones that are on over what is selected, and only
			// where it says something: an overlay nested under the entry it
			// hangs on is obviously to do with it, but one filed at the end on
			// the programme's own clock may happen to cover it too, and that is
			// the question the old filter existed to answer.
			row.plays = node.isLoose && origin.projectIndex
				.map { overlaysOver(selection).contains($0) } == true
			row.needsDisplay = true
			return row
		}
		if case .sound(let origin) = node.carried, let sound = project.sound(at: origin) {
			let row = (outlineView.makeView(withIdentifier: .init("treeSound"), owner: self)
				as? SoundRow)
				?? { let made = SoundRow(); made.identifier = .init("treeSound"); return made }()
			row.sound = sound
			row.needsDisplay = true
			return row
		}
		if node.isOverlayRoot {
			let label = NSTextField(labelWithString: "ON THE PROGRAMME'S OWN CLOCK")
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

	/// A mark and a lighter ground, not a bar of saturated blue across the row.
	public func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
		MarkedRow.make(in: outlineView)
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
		guard let node = item as? Node, !node.isOverlayRoot else { return nil }
		let pasteboardItem = NSPasteboardItem()
		// An overlay or a sound carries where it is *written* rather than where
		// it is shown. Dropping it somewhere else is a move between homes,
		// which is a different thing from re-ordering the timeline and says so.
		switch node.carried {
		case .overlay(let origin):
			pasteboardItem.setString(Self.written(node.carried!), forType: Self.carriedType)
			pasteboardItem.setString(project.overlay(at: origin)?.described ?? "", forType: .string)
			return pasteboardItem
		case .sound(let origin):
			pasteboardItem.setString(Self.written(node.carried!), forType: Self.carriedType)
			pasteboardItem.setString(project.sound(at: origin)?.file ?? "", forType: .string)
			return pasteboardItem
		case nil:
			pasteboardItem.setString(node.path.map(String.init).joined(separator: "."),
			                         forType: Self.entryType)
			pasteboardItem.setString(node.entry.source.description, forType: .string)
			return pasteboardItem
		}
	}

	public func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
	                        proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
		// One of these lands *on* a row rather than in the gap between two: what
		// is being asked is "belong to this", and a gap belongs to nothing.
		if info.draggingPasteboard.string(forType: Self.carriedType) != nil {
			guard let node = item as? Node else {
				// The empty space below everything is not the top-level list;
				// the heading at the end is, and it is one row away.
				return []
			}
			if let carried = node.carried {
				// Dropped on another one: it means the entry that one is in,
				// which is the row somebody was aiming just past.
				outlineView.setDropItem(self.node(at: carried.home ?? []),
				                        dropChildIndex: NSOutlineViewDropOnItemIndex)
			} else {
				outlineView.setDropItem(node, dropChildIndex: NSOutlineViewDropOnItemIndex)
			}
			return .move
		}
		// Onto a clip means nothing — a clip holds nothing — so a drop there is
		// retargeted to the gap after it, which is what the pointer is over.
		if let node = item as? Node, node.groupName == nil, !node.isOverlayRoot {
			let parent = self.node(at: Array(node.path.dropLast()))
			outlineView.setDropItem(parent, dropChildIndex: (node.path.last ?? 0) + 1)
		}
		return info.draggingSource as? NSOutlineView === outlineView ? .move : .copy
	}

	public func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo,
	                        item: Any?, childIndex index: Int) -> Bool {
		if let written = info.draggingPasteboard.string(forType: Self.carriedType),
		   let carried = Self.carried(written) {
			let node = item as? Node
			return rehome(carried, onto: node?.isOverlayRoot == true ? nil : node?.path)
		}
		return dropItems(from: info.draggingPasteboard, into: (item as? Node)?.path ?? [], at: index)
	}

	/// An overlay or a sound dropped on a row: it belongs to that row now.
	///
	/// `nil` is the heading at the end, which is the top-level list — the one
	/// place where these are on the programme's own clock rather than on
	/// anything in particular. The arithmetic is the model's, because what a
	/// move has to preserve is when the thing is on and that is not something a
	/// table view can be asked about.
	@discardableResult
	func rehome(_ carried: Carried, onto path: [Int]?) -> Bool {
		var next = project
		switch carried {
		case .overlay(let origin):
			guard let landed = next.moveOverlay(at: origin, into: path, in: resolved) else {
				return false
			}
			pending = .overlay(landed)
		case .sound(let origin):
			guard let landed = next.moveSound(at: origin, into: path, in: resolved) else {
				return false
			}
			pending = .sound(landed)
		}
		onChange?(next)
		return true
	}

	/// A row's address on the pasteboard. Not a spelling the file uses —
	/// nothing reads this but the drop it came from, half a second later.
	private static func written(_ carried: Carried) -> String {
		let kind: String
		let origin: Origin
		switch carried {
		case .overlay(let where_): kind = "o"; origin = where_
		case .sound(let where_): kind = "s"; origin = where_
		}
		switch origin {
		case .project(let index): return "\(kind) p \(index)"
		case .entry(let path, let index):
			return "\(kind) e \(index) \(path.map(String.init).joined(separator: "."))"
		}
	}

	private static func carried(_ written: String) -> Carried? {
		let parts = written.split(separator: " ")
		guard parts.count >= 3, let index = Int(parts[2]) else { return nil }
		let origin: Origin
		if parts[1] == "p" {
			origin = .project(index)
		} else {
			guard parts.count == 4 else { return nil }
			origin = .entry(path: parts[3].split(separator: ".").compactMap { Int($0) }, index: index)
		}
		return parts[0] == "o" ? .overlay(origin) : .sound(origin)
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


	// MARK: - Selection

	public func outlineViewSelectionDidChange(_ notification: Notification) {
		if let carried = selectedTreeCarried, exists(carried) {
			selection = carried.selection
			onSelect?(selection)
			return
		}
		guard let path = selectedPath else { return }
		selection = .entry(path)
		remarkLooseOverlays()
		onSelect?(selection)
	}

	/// The bar down the side of a loose overlay says whether it is on over what
	/// is selected, so it is redrawn when the selection moves.
	///
	/// The rows, not the tree. `reloadData` from inside a selection notification
	/// selects a row again, which posts the notification again, which reloads —
	/// and the process dies on a stack overflow rather than on anything that
	/// looks like a mistake.
	private func remarkLooseOverlays() {
		let on = overlaysOver(selection)
		for row in 0..<outline.numberOfRows {
			guard let node = outline.item(atRow: row) as? Node, node.isLoose,
			      case .overlay(let origin) = node.carried,
			      let view = outline.view(atColumn: 0, row: row, makeIfNecessary: false)
					as? OverlayRow
			else { continue }
			view.plays = origin.projectIndex.map { on.contains($0) } == true
			view.needsDisplay = true
		}
	}

	/// Selects whatever this names, and scrolls to it.
	///
	/// The tree owns the selection, so this is how anything else asks for one —
	/// the links in the head of the properties panel, which say what the
	/// selection depends on and are therefore places to go. Two objects each
	/// deciding what is selected is how a panel comes to show one thing while
	/// the tree highlights another.
	public func select(_ wanted: ProjectSelection) {
		let row: Int?
		switch wanted {
		case .output: selectOutput(); return
		case .entry(let path): row = self.row(for: path)
		case .overlay(let origin): row = self.row(for: .overlay(origin))
		case .sound(let origin): row = self.row(for: .sound(origin))
		}
		guard let row else { return }
		outline.selectRowIndexes([row], byExtendingSelection: false)
		outline.scrollRowToVisible(row)
	}

	/// Clears the selection back to the project itself, which is what the
	/// output properties are about.
	public func selectOutput() {
		outline.deselectAll(nil)
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
		// Selected first, because everything on this menu acts on the selection
		// — including `Add ▸`, which is how a caption comes to be written
		// inside the row somebody pointed at.
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
		}
		if case .clip(let reference) = node.entry.source, node.overlay == nil, !node.isOverlayRoot {
			let open = NSMenuItem(title: "Open “\(reference.slug)” in its take",
			                      action: #selector(openInTake(_:)), keyEquivalent: "")
			open.target = self
			open.representedObject = node.path
			menu.addItem(open)
		}

		// And the same list the `+` offers, put where the pointer already is.
		// Adding a caption to a shot should not mean adding it somewhere else
		// and then telling it which shot.
		if !menu.items.isEmpty { menu.addItem(.separator()) }
		let add = NSMenuItem(title: node.isOverlayRoot
			? "Add to the programme's own clock" : "Add", action: nil, keyEquivalent: "")
		let submenu = NSMenu()
		// Entries go on the timeline, and the heading for the loose overlays is
		// not on the timeline — nothing can be put *in* it but an overlay.
		for item in additionItems(includingEntries: !node.isOverlayRoot) { submenu.addItem(item) }
		add.submenu = submenu
		menu.addItem(add)
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
			case nil:
				where_ = "as long as this entry is on"
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
	final class OverlayRow: NSTableCellView {
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
