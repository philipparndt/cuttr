import AppKit
import CuttrCompose
import CuttrKit

/// Everything a project is made of, in one tree.
///
/// This replaced two panes — a takes table above a library, with a drag handle
/// between them — that between them answered one question and answered half of
/// it each. The shape it draws is ``Material``, which is a function of the
/// vocabulary and the search field and has no view in it at all; this is the
/// window around that.
///
/// On ``MenuOutline`` because that class already carries what a list in this
/// program needs: the right-click that names the row under the pointer, the
/// click that puts the keyboard in the list, the paging keys that move the
/// selection rather than scrolling past it, and ``MarkedRow``'s selection.
@MainActor
public final class MaterialTree: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {

	// MARK: - What the window is asked to do

	/// Put this reference on the programme — double-clicked, or ⏎.
	public var onInsert: ((String) -> Void)?
	/// Where a clip came from: the take it is in, at the moment it starts.
	public var onOpenInTake: ((ComposeDocument.Vocabulary.Item) -> Void)?
	/// Open a take. The flag is "in a window of its own" — ⌥ on the
	/// double-click, or the second item of its menu.
	public var onOpen: ((URL, Bool) -> Void)?
	public var onRemove: ((String) -> Void)?
	public var onRename: ((String, String) -> Void)?
	public var onAdd: (() -> Void)?
	public var onNew: (() -> Void)?
	/// A scene: the one named, or a new one when the name is `nil`.
	public var onScene: ((String?) -> Void)?
	public var onAddScene: (() -> Void)?
	public var onRemoveScene: ((String) -> Void)?
	/// Arranging the takes. `nil` for the folder means out of the one it is in.
	public var onNewFolder: ((String) -> Void)?
	public var onRenameFolder: ((String, String) -> Void)?
	public var onRemoveFolder: ((String) -> Void)?
	public var onMoveTake: ((String, String?) -> Void)?

	// MARK: - What it holds

	private var vocabulary = ComposeDocument.Vocabulary()
	private var takes: [ComposeDocument.TakeEntry] = []
	private var folders: [Project.Folder] = []
	private var nodes: [Material.Node] = []
	/// Boxed, because an outline view holds its items by identity and a
	/// `struct` handed to it twice is two different items.
	private var boxes: [String: Held] = [:]
	/// Which rows somebody has opened, by their key, so the panel comes back
	/// the way it was left. Takes start closed — see ``reload(_:takes:)``.
	private var opened: Set<String> = []

	private let outline = MenuOutline()
	/// The panel a look happens in, made when one is first asked for.
	fileprivate var look: QuickLookPanel?
	/// What keeps it open only while somebody is looking — the same rule the
	/// programme tree's look lives under. See ``LookWatch``.
	fileprivate let lookWatch = LookWatch()
	private let search = NSSearchField()
	private let findMeme = NSButton()
	private var renaming: String?

	/// Which take a drag is carrying, for a drop inside this tree.
	static let takeType = NSPasteboard.PasteboardType("de.rnd7.cuttr.take")

	/// One row, with an identity an outline view can hold on to.
	final class Held: NSObject {
		let key: String
		var node: Material.Node
		var children: [Held] = []
		init(key: String, node: Material.Node) {
			self.key = key
			self.node = node
		}
	}

	public override init(frame: NSRect) {
		super.init(frame: frame)
		wantsLayer = true
		layer?.backgroundColor = Theme.panel.cgColor

		search.font = Theme.body
		search.placeholderString = "Filter takes, clips, #tags, anchors"
		search.target = self
		search.action = #selector(filterChanged)
		search.sendsSearchStringImmediately = true
		search.sendsWholeSearchString = false

		// Memes are material, so the way to get one is here with the material.
		// Down the responder chain to whichever project window is in front,
		// which is the route the menu item takes — one implementation, not two.
		findMeme.title = "Find a meme…"
		findMeme.bezelStyle = .rounded
		findMeme.controlSize = .small
		findMeme.font = NSFont.systemFont(ofSize: 11)
		findMeme.target = nil
		findMeme.action = #selector(ComposeWindowController.findMeme(_:))
		findMeme.toolTip = "Search GIPHY or Tenor. What arrives is a take like any other."

		outline.dataSource = self
		outline.delegate = self
		outline.rowHeight = 30
		outline.backgroundColor = Theme.panel
		outline.gridStyleMask = []
		outline.headerView = nil
		outline.indentationPerLevel = 14
		outline.selectionHighlightStyle = .regular
		outline.intercellSpacing = NSSize(width: 0, height: 0)
		// Several clips onto the programme at once, in the order they are
		// listed, which is how a section gets filled.
		outline.allowsMultipleSelection = true
		outline.autosaveExpandedItems = false
		outline.target = self
		outline.doubleAction = #selector(activateClicked)
		outline.onMenu = { [weak self] event in self?.rowMenu(for: event) }
		outline.onKey = { [weak self] event in self?.handle(event) ?? false }
		let column = NSTableColumn(identifier: .init("material"))
		column.width = 240
		outline.addTableColumn(column)
		outline.outlineTableColumn = column
		outline.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
		// Dropped back into itself, and only that: a take onto a folder files
		// it there. Nothing from outside — this is what the takes contain, and
		// a drop from elsewhere would be asking to change a take from the
		// project window.
		outline.registerForDraggedTypes([Self.takeType])

		let top = NSStackView(views: [search, findMeme])
		top.orientation = .horizontal
		top.spacing = 6

		let add = menuButton("Add", [
			("Take…", #selector(addTake), "Put an existing .cuttr take into this project"),
			("Scene…", #selector(addScene), "Copy a scene out of another project"),
		])
		let new = menuButton("New", [
			("Take…", #selector(newTake), "Cut a new take from a video or audio file"),
			("Scene…", #selector(newScene), "Build an intro screen or a title card"),
		])
		let buttons = NSStackView(views: [add, new])
		buttons.orientation = .horizontal
		buttons.spacing = 6

		let scroll = TableScroll.fitting(outline)
		let stack = NSStackView(views: [top, scroll, buttons])
		stack.orientation = .vertical
		stack.spacing = 6
		stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
		stack.translatesAutoresizingMaskIntoConstraints = false
		addSubview(stack)
		NSLayoutConstraint.activate([
			stack.topAnchor.constraint(equalTo: topAnchor),
			stack.leadingAnchor.constraint(equalTo: leadingAnchor),
			stack.trailingAnchor.constraint(equalTo: trailingAnchor),
			stack.bottomAnchor.constraint(equalTo: bottomAnchor),
		])
	}

	@available(*, unavailable) required init?(coder: NSCoder) { nil }

	/// The list leaving the window takes the look with it: a panel hovering
	/// beside a list that is no longer there outlives what it was about.
	public override func viewDidMoveToWindow() {
		super.viewDidMoveToWindow()
		if window == nil { closeLook() }
	}

	/// A heading is shorter than a row of material.
	///
	/// The library gave its headings 22 points against 30 for everything else,
	/// and setting one row height for the whole outline lost that: the rule
	/// under `TAKES` sat eight points below where it belongs, which reads as a
	/// gap rather than as an underline.
	public func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
		if case .root = (item as? Held)?.node.row { return 22 }
		return 30
	}

	private func menuButton(_ title: String,
	                        _ items: [(String, Selector, String)]) -> NSPopUpButton {
		let button = NSPopUpButton(frame: .zero, pullsDown: true)
		button.bezelStyle = .rounded
		button.controlSize = .small
		button.font = NSFont.systemFont(ofSize: 11)
		// The first item of a pull-down is its title and is never chosen.
		button.menu?.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
		for (name, action, hint) in items {
			let item = NSMenuItem(title: name, action: action, keyEquivalent: "")
			item.target = self
			item.toolTip = hint
			button.menu?.addItem(item)
		}
		return button
	}

	// MARK: - Contents

	public func reload(_ vocabulary: ComposeDocument.Vocabulary,
	                   takes: [ComposeDocument.TakeEntry] = [],
	                   folders: [Project.Folder] = []) {
		// A reload puts a look away: the rows are about to move under it, and
		// the take it was playing may not be one of this project's any more.
		closeLook()
		self.vocabulary = vocabulary
		self.takes = takes
		self.folders = folders
		rebuild()
	}

	@objc private func filterChanged() { rebuild() }

	/// Opening and closing rows without letting AppKit animate it.
	///
	/// `expandItem` animates, and an animation is `-[NSAnimation _runBlocking]`
	/// on a dispatch worker thread spinning a nested run loop. This tree opens
	/// every root on every reload, so a window that reloads often — or a test
	/// suite that builds hundreds of trees — fills the 64-thread dispatch pool
	/// with blocked animations and stops. It took the whole suite down for two
	/// hours before `sample` said so in as many words: "too many dispatch
	/// threads blocked in synchronous operations".
	///
	/// Nothing is lost by it. These are rows appearing as a list is built, not
	/// a gesture somebody made.
	private func withoutAnimation(_ work: () -> Void) {
		NSAnimationContext.beginGrouping()
		NSAnimationContext.current.duration = 0
		work()
		NSAnimationContext.endGrouping()
	}

	private func rebuild() {
		let needle = search.stringValue
		nodes = Material.tree(of: vocabulary, takes: takes, folders: folders,
		                      matching: needle)
		boxes = [:]
		let held = nodes.map { box($0, under: "") }
		roots = held
		outline.reloadData()

		// Roots open, takes closed: the first thing shown is the list of takes,
		// which is what the pane this replaced showed. A project with forty
		// takes should not open to a wall of clips.
		//
		// While something is being searched for, everything that survived the
		// filter is opened instead — a match has to be visible to be a match.
		withoutAnimation {
			for root in held {
				outline.expandItem(root)
				guard !needle.trimmingCharacters(in: .whitespaces).isEmpty else {
					for child in root.children where opened.contains(child.key) {
						outline.expandItem(child)
						for grandchild in child.children where opened.contains(grandchild.key) {
							outline.expandItem(grandchild)
						}
					}
					continue
				}
				// A match has to be visible to be a match, and there are two
				// levels to open now that takes can be in folders.
				for child in root.children {
					outline.expandItem(child)
					for grandchild in child.children { outline.expandItem(grandchild) }
				}
			}
		}
	}

	private var roots: [Held] = []

	private func box(_ node: Material.Node, under prefix: String) -> Held {
		let key = prefix + Self.key(of: node.row)
		let held = Held(key: key, node: node)
		held.children = node.children.map { box($0, under: key + "/") }
		boxes[key] = held
		return held
	}

	/// What a row is called, for remembering whether it was open. Stable across
	/// a reload, which the row itself is not.
	static func key(of row: Material.Row) -> String {
		switch row {
		case .root(let root): return "root:\(root.rawValue)"
		case .folder(let name, _): return "folder:\(name)"
		case .take(let name, _, _, _): return "take:\(name)"
		case .memes: return "memes"
		case .clip(let item): return "clip:\(item.take)/\(item.slug)"
		case .scene(let name): return "scene:\(name)"
		case .anchor(let name, _): return "anchor:\(name)"
		case .tag(let name, _): return "tag:\(name)"
		}
	}

	// MARK: - The outline's questions

	public func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
		(item as? Held)?.children.count ?? roots.count
	}

	public func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
		(item as? Held)?.children[index] ?? roots[index]
	}

	public func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
		!((item as? Held)?.children.isEmpty ?? true)
	}

	public func outlineView(_ outlineView: NSOutlineView,
	                        rowViewForItem item: Any) -> NSTableRowView? {
		MarkedRow.make(in: outlineView)
	}

	public func outlineViewItemDidExpand(_ notification: Notification) {
		guard let held = notification.userInfo?["NSObject"] as? Held else { return }
		opened.insert(held.key)
	}

	public func outlineViewItemDidCollapse(_ notification: Notification) {
		guard let held = notification.userInfo?["NSObject"] as? Held else { return }
		opened.remove(held.key)
	}

	public func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?,
	                        item: Any) -> NSView? {
		guard let held = item as? Held else { return nil }
		let identifier = NSUserInterfaceItemIdentifier("material-row")
		let view = (outlineView.makeView(withIdentifier: identifier, owner: self) as? MaterialRow)
			?? MaterialRow()
		view.identifier = identifier
		view.row = held.node.row
		// A row draws its own words, so it has to be told what it is sitting on.
		view.isChosen = outline.selectedRowIndexes.contains(outline.row(forItem: held))
		view.isLit = outline.window?.firstResponder === outline
		view.isRenaming = renaming == held.key
		view.onRenamed = { [weak self] name in self?.finishRenaming(held, to: name) }
		view.needsDisplay = true
		return view
	}

	/// Dragged as plain text: the reference a project writes. A take carries
	/// every clip it holds, one to a line, and the programme's drop splits
	/// them — see ``ProgrammePanel``.
	public func outlineView(_ outlineView: NSOutlineView,
	                        pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
		guard let held = item as? Held else { return nil }
		// A scene is dragged as itself rather than as a reference: dropped on
		// the programme it becomes a card with the scene drawn on it.
		if case .scene(let name) = held.node.row {
			let written = NSPasteboardItem()
			written.setString(name, forType: ProgrammePanel.sceneType)
			return written
		}
		let references = held.node.references
		let written = NSPasteboardItem()
		// A take also says which take it is, on a type only this tree reads, so
		// that dropping one on a folder can file it. The plain text stays what
		// it was, so dropping the same drag on the programme still lays down
		// its clips.
		if case .take(let name, let path, _, _) = held.node.row {
			written.setString(path.isEmpty ? name : path, forType: Self.takeType)
		}
		guard !references.isEmpty || written.types.contains(Self.takeType) else { return nil }
		if !references.isEmpty {
			written.setString(references.joined(separator: "\n"), forType: .string)
		}
		return written
	}
}

// MARK: - The verbs

extension MaterialTree {

	private var chosen: [Held] {
		outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? Held }
	}

	/// A double-click: open what was pointed at, or fold a heading.
	///
	/// Not called `activate` — `NSApplication` has one, and a selector that
	/// resolves to two things resolves to neither.
	@objc func activateClicked() {
		let row = outline.clickedRow
		guard row >= 0, let held = outline.item(atRow: row) as? Held else { return }
		activate(held)
	}

	func activate(_ held: Held) {
		switch held.node.row {
		case .root, .memes, .folder:
			// A heading opens and closes, which is what a triangle means.
			if outline.isItemExpanded(held) { outline.collapseItem(held) }
			else { outline.expandItem(held) }
		case .take(let name, _, _, let problem):
			guard problem == nil, let url = url(ofTake: name) else { return }
			onOpen?(url, NSEvent.modifierFlags
				.intersection(.deviceIndependentFlagsMask).contains(.option))
		case .scene(let name):
			// A scene is the one thing here that is not material to be placed
			// but a thing to be made, so it opens rather than being put down.
			onScene?(name)
		case .clip, .anchor, .tag:
			guard let reference = held.node.row.reference else { return }
			onInsert?(reference)
		}
	}

	private func url(ofTake name: String) -> URL? {
		takes.first { $0.name == name }?.url
	}

	/// ⏎ puts the selection on the programme; ⌫ takes a take or a scene out;
	/// space is a look at the clip before you place it.
	func handle(_ event: NSEvent) -> Bool {
		// Space, and escape while one is open. Both asked of ``QuickLook``
		// rather than answered here, for the reason the library asked them
		// there: space belongs to several things in this program — the
		// preview, the transcript, a text field — and the only safe way to
		// take it is to be able to say, without a keyboard, where it is *not*
		// taken.
		if QuickLook.dismisses(event), isLooking {
			closeLook()
			return true
		}
		if QuickLook.claims(event, editing: false, hasSpan: lookSpan() != nil) {
			if isLooking { closeLook() } else { showLook() }
			return true
		}
		// The arrows fold, which is what they mean in a tree.
		if let held = chosen.first, event.keyCode == 124 || event.keyCode == 123 {
			let open = outline.isItemExpanded(held)
			if event.keyCode == 124, !open, outline.isExpandable(held) {
				outline.expandItem(held)
				return true
			}
			if event.keyCode == 123 {
				if open { outline.collapseItem(held); return true }
				// Already shut, or nothing to shut: up to the parent, which is
				// where left goes in every outline.
				let row = outline.row(forItem: held)
				if row > 0, let up = outline.parent(forItem: held) {
					let at = outline.row(forItem: up)
					guard at >= 0 else { return true }
					outline.selectRowIndexes([at], byExtendingSelection: false)
					outline.scrollRowToVisible(at)
				}
				return true
			}
			return false
		}
		switch event.keyCode {
		case 36, 76:                                            // ⏎ and the keypad's
			guard let first = chosen.first else { return false }
			activate(first)
			return true
		case 51, 117:                                           // ⌫ and ⌦
			guard let first = chosen.first else { return false }
			switch first.node.row {
			case .take(let name, let path, _, _):
				onRemove?(path.isEmpty ? name : path)
				return true
			case .scene(let name):
				onRemoveScene?(name)
				return true
			default:
				return false
			}
		default:
			return false
		}
	}

	/// The row under the pointer, named, and selected first.
	///
	/// A right-click that quietly acts on the selection rather than on what was
	/// clicked is the way to delete the wrong thing.
	func rowMenu(for event: NSEvent) -> NSMenu? {
		let place = outline.convert(event.locationInWindow, from: nil)
		let row = outline.row(at: place)
		guard row >= 0, let held = outline.item(atRow: row) as? Held else { return nil }
		outline.selectRowIndexes([row], byExtendingSelection: false)
		return menu(for: held)
	}

	/// The menu for a row, split from the event that found it so a test can
	/// ask what a row offers without making a mouse.
	func menu(for held: Held) -> NSMenu? {
		let menu = NSMenu()
		switch held.node.row {
		case .root(.takes), .memes:
			add(to: menu, "Add Take…", #selector(addTake))
			add(to: menu, "New Take…", #selector(newTake))
			menu.addItem(.separator())
			add(to: menu, "New Folder…", #selector(newFolder))

		case .folder(let name, _):
			add(to: menu, "Rename “\(name)”…", #selector(renameChosenFolder))
			// The takes stay in the project: an arrangement is not the
			// material, and the menu should not read as though it were.
			add(to: menu, "Remove Folder", #selector(removeChosenFolder))
			menu.addItem(.separator())
			add(to: menu, "New Folder…", #selector(newFolder))
		case .root(.scenes):
			add(to: menu, "Add Scene…", #selector(addScene))
			add(to: menu, "New Scene…", #selector(newScene))
		case .root:
			return nil

		case .take(let name, let path, _, _):
			add(to: menu, "Open “\(name)”", #selector(openChosen))
			add(to: menu, "Open Beside the Project", #selector(openChosenAside))
			menu.addItem(.separator())
			add(to: menu, "Rename…", #selector(renameChosen))
			add(to: menu, "Reveal in Finder", #selector(revealChosenInFinder))
			// Where this take is filed, if anywhere.
			let move = NSMenuItem(title: "Move to Folder", action: nil, keyEquivalent: "")
			move.submenu = foldersMenu(for: path.isEmpty ? name : path)
			menu.addItem(move)
			add(to: menu, "Remove from Project", #selector(removeChosen))
			menu.addItem(.separator())
			// The `Where` column of the pane this replaced. There is no room
			// for a path on a tree row, and this is where the switcher puts one.
			let where_ = NSMenuItem(title: path.isEmpty ? "Not saved" : path,
			                        action: nil, keyEquivalent: "")
			where_.isEnabled = false
			menu.addItem(where_)

		case .clip(let item):
			add(to: menu, "Put “\(item.reference)” on the Programme", #selector(insertChosen))
			add(to: menu, "Open “\(item.slug)” in \(item.take)", #selector(openClipInTake))

		case .scene(let name):
			add(to: menu, "Edit “\(name)”", #selector(editChosenScene))
			add(to: menu, "Remove from Project", #selector(removeChosenScene))

		case .anchor, .tag:
			add(to: menu, "Put on the Programme", #selector(insertChosen))
		}
		return menu.items.isEmpty ? nil : menu
	}

	private func add(to menu: NSMenu, _ title: String, _ action: Selector) {
		let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
		item.target = self
		menu.addItem(item)
	}

	// MARK: - What the menu items do

	@objc private func addTake() { onAdd?() }
	@objc private func newTake() { onNew?() }
	@objc private func addScene() { onAddScene?() }
	@objc private func newScene() { onScene?(nil) }

	@objc private func insertChosen() {
		for held in chosen {
			for reference in held.node.references { onInsert?(reference) }
		}
	}

	@objc private func openChosen() {
		guard case .take(let name, _, _, _) = chosen.first?.node.row,
		      let url = url(ofTake: name) else { return }
		onOpen?(url, false)
	}

	@objc private func openChosenAside() {
		guard case .take(let name, _, _, _) = chosen.first?.node.row,
		      let url = url(ofTake: name) else { return }
		onOpen?(url, true)
	}

	/// The take's file, in the Finder.
	///
	/// The one thing somebody wants a *path* for that a path in a menu cannot
	/// give them — and the `Where` column that used to carry the path is gone,
	/// so this is now the way to get at the file itself.
	@objc private func revealChosenInFinder() {
		guard case .take(let name, _, _, _) = chosen.first?.node.row,
		      let url = url(ofTake: name) else { return }
		NSWorkspace.shared.activateFileViewerSelecting([url])
	}

	@objc private func removeChosen() {
		guard case .take(let name, let path, _, _) = chosen.first?.node.row else { return }
		onRemove?(path.isEmpty ? name : path)
	}

	@objc private func openClipInTake() {
		guard case .clip(let item) = chosen.first?.node.row else { return }
		onOpenInTake?(item)
	}

	@objc private func editChosenScene() {
		guard case .scene(let name) = chosen.first?.node.row else { return }
		onScene?(name)
	}

	@objc private func removeChosenScene() {
		guard case .scene(let name) = chosen.first?.node.row else { return }
		onRemoveScene?(name)
	}

	// MARK: - Renaming a take in place

	@objc func renameChosen() {
		guard let held = chosen.first, case .take = held.node.row else { return }
		renaming = held.key
		// Told to the row that is on screen rather than left to `reloadItem`,
		// which reloads an item's *data* and hands back the cell view it
		// already had — so the field never arrived and the row went on being
		// drawn.
		cell(for: held)?.isRenaming = true
	}

	private func cell(for held: Held) -> MaterialRow? {
		let row = outline.row(forItem: held)
		guard row >= 0 else { return nil }
		return outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? MaterialRow
	}

	func finishRenaming(_ held: Held, to name: String) {
		defer {
			renaming = nil
			cell(for: held)?.isRenaming = false
		}
		guard case .take(let was, let path, _, _) = held.node.row else { return }
		let wanted = name.trimmingCharacters(in: .whitespaces)
		guard !wanted.isEmpty, wanted != was else { return }
		onRename?(path.isEmpty ? was : path, wanted)
	}

	/// Selects a reference and shows it, opening whatever it is inside.
	///
	/// What a newly downloaded meme calls to say "here it is". A search in the
	/// field, or a folded take, would otherwise hide the thing that has just
	/// arrived — so both are undone before looking.
	public func reveal(_ reference: String) {
		if find(reference) == nil {
			search.stringValue = ""
			rebuild()
		}
		guard let held = find(reference) else { return }
		// Open every parent, or the row is in the tree and not on screen.
		var parents: [Held] = []
		var walk = parent(of: held)
		while let some = walk {
			parents.append(some)
			walk = parent(of: some)
		}
		withoutAnimation { for some in parents.reversed() { outline.expandItem(some) } }
		let row = outline.row(forItem: held)
		guard row >= 0 else { return }
		outline.selectRowIndexes([row], byExtendingSelection: false)
		outline.scrollRowToVisible(row)
	}

	private func find(_ reference: String) -> Held? {
		func walk(_ held: [Held]) -> Held? {
			for one in held {
				if one.node.row.reference == reference { return one }
				if let found = walk(one.children) { return found }
			}
			return nil
		}
		return walk(roots)
	}

	private func parent(of wanted: Held) -> Held? {
		func walk(_ held: [Held]) -> Held? {
			for one in held {
				if one.children.contains(where: { $0 === wanted }) { return one }
				if let found = walk(one.children) { return found }
			}
			return nil
		}
		return walk(roots)
	}

	/// Folds a root away, or opens it. For the tests and for the keyboard.
	public func fold(_ root: Material.Root) {
		guard let held = roots.first(where: { $0.node.row == .root(root) }) else { return }
		flip(held)
	}

	/// And the same for anything under a root that has children of its own: a
	/// folder, a take, the memes.
	public func fold(take name: String) {
		for root in roots {
			for child in root.children {
				switch child.node.row {
				case .folder(let found, _) where found == name:
					flip(child)
					return
				case .take(let found, _, _, _) where found == name:
					flip(child)
					return
				// The memes row is one of these too: it is a take-shaped thing
				// holding clips, and folds like one.
				case .memes where name == "memes":
					flip(child)
					return
				default:
					continue
				}
			}
		}
	}

	private func flip(_ held: Held) {
		withoutAnimation {
			if outline.isItemExpanded(held) { outline.collapseItem(held) }
			else { outline.expandItem(held) }
		}
	}

	// MARK: - For the tests

	var outlineForTesting: NSOutlineView { outline }
	var rootsForTesting: [Held] { roots }
	/// A key press as the *outline* hands it over, which is the wiring rather
	/// than a copy of it. Dispatching an event at the view instead sends an
	/// unclaimed key up to `NSResponder`, which answers with a beep on the
	/// machine the tests are running on.
	func keyForTesting(_ event: NSEvent) -> Bool { outline.onKey?(event) ?? false }
	var lookFrameForTesting: NSRect? { look?.frame }
	var lookPanelForTesting: QuickLookPanel? { look }
	/// The list itself, which is what has to have the keyboard for a key to
	/// arrive here at all.
	var tableForTesting: MenuOutline { outline }

	/// Choosing a row the way a double-click does.
	func chooseRowForTesting(_ row: Int, aside: Bool = false) {
		guard let held = outline.item(atRow: row) as? Held else { return }
		if aside, case .take(let name, _, _, _) = held.node.row {
			guard let url = takes.first(where: { $0.name == name })?.url else { return }
			onOpen?(url, true)
			return
		}
		activate(held)
	}

	/// Starts a rename on whatever take is selected, the way its menu does.
	func beginRenamingForTesting() { renameChosen() }

	/// The menu a row would show, without a mouse event to make one from.
	func menuForTesting(_ held: Held) -> NSMenu? {
		outline.selectRowIndexes([outline.row(forItem: held)], byExtendingSelection: false)
		return menu(for: held)
	}

	/// A drop, without a dragging session to carry it.
	@discardableResult
	func dropForTesting(_ take: String, on held: Held) -> Bool {
		guard let wanted = target(of: held) else { return false }
		onMoveTake?(take, wanted.folder)
		return true
	}

	func searchForTesting(_ text: String) {
		search.stringValue = text
		filterChanged()
	}
}

// MARK: - Looking at a clip before you place it

extension MaterialTree {

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
		for row in outline.selectedRowIndexes.sorted() {
			guard let held = outline.item(atRow: row) as? Held else { continue }
			if case .clip(let item) = held.node.row { return (row, item) }
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
		let where_ = QuickLook.frames(of: outline.rect(ofRow: chosen.row), in: outline,
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
	public func outlineViewSelectionDidChange(_ notification: Notification) {
		// The rows draw their own words against the ground they sit on, so the
		// two that changed have to be asked again.
		outline.enumerateAvailableRowViews { view, _ in
			for cell in view.subviews { cell.needsDisplay = true }
		}
		if isLooking { showLook() }
	}


	/// For the tests: where the look landed, and what it is playing.
}

// MARK: - Arranging the takes

extension MaterialTree {

	/// Which folders a take could go in, and the two other things it can do.
	///
	/// Every folder that exists, a way out of the one it is in, and a new one
	/// at the end — so the whole arrangement can be done from the row without
	/// going anywhere else first.
	func foldersMenu(for take: String) -> NSMenu {
		let menu = NSMenu()
		let inside = folders.first { $0.takes.contains(take) }?.name
		for folder in folders {
			let item = NSMenuItem(title: folder.name, action: #selector(moveChosen(_:)),
			                      keyEquivalent: "")
			item.target = self
			item.representedObject = folder.name
			item.state = folder.name == inside ? .on : .off
			menu.addItem(item)
		}
		if inside != nil {
			if !folders.isEmpty { menu.addItem(.separator()) }
			let out = NSMenuItem(title: "Out of the Folder",
			                     action: #selector(moveChosen(_:)), keyEquivalent: "")
			out.target = self
			menu.addItem(out)
		}
		if !menu.items.isEmpty { menu.addItem(.separator()) }
		let made = NSMenuItem(title: "New Folder…", action: #selector(moveToNewFolder),
		                      keyEquivalent: "")
		made.target = self
		menu.addItem(made)
		return menu
	}

	/// The path a take row means, which is what a folder holds.
	private func path(of held: Held) -> String? {
		guard case .take(let name, let path, _, _) = held.node.row else { return nil }
		return path.isEmpty ? name : path
	}

	@objc private func moveChosen(_ sender: NSMenuItem) {
		guard let held = chosen.first, let take = path(of: held) else { return }
		onMoveTake?(take, sender.representedObject as? String)
	}

	@objc private func moveToNewFolder() {
		guard let held = chosen.first, let take = path(of: held) else { return }
		ask("New Folder", "What is it called?") { [weak self] name in
			self?.onNewFolder?(name)
			self?.onMoveTake?(take, name)
		}
	}

	@objc private func newFolder() {
		ask("New Folder", "What is it called?") { [weak self] name in
			self?.onNewFolder?(name)
		}
	}

	@objc private func renameChosenFolder() {
		guard case .folder(let name, _) = chosen.first?.node.row else { return }
		ask("Rename Folder", "What should it be called?", filled: name) { [weak self] wanted in
			self?.onRenameFolder?(name, wanted)
		}
	}

	@objc private func removeChosenFolder() {
		guard case .folder(let name, _) = chosen.first?.node.row else { return }
		onRemoveFolder?(name)
	}

	/// A name, asked for.
	///
	/// An alert rather than a field in the row: a folder made from a menu has
	/// no row yet to type into, and inventing one to be typed into and then
	/// throwing it away is more moving parts than the question deserves.
	private func ask(_ title: String, _ question: String, filled: String = "",
	                 then use: @escaping (String) -> Void) {
		let alert = NSAlert()
		alert.messageText = title
		alert.informativeText = question
		alert.addButton(withTitle: "OK")
		alert.addButton(withTitle: "Cancel")
		let field = NSTextField(string: filled)
		field.frame = NSRect(x: 0, y: 0, width: 220, height: 22)
		alert.accessoryView = field
		alert.window.initialFirstResponder = field
		guard alert.runModal() == .alertFirstButtonReturn else { return }
		let wanted = field.stringValue.trimmingCharacters(in: .whitespaces)
		guard !wanted.isEmpty else { return }
		use(wanted)
	}
}

// MARK: - Dropping a take into a folder

extension MaterialTree {

	/// Where a take may be dropped: on a folder, or on the `Takes` root, which
	/// is how it comes back out of one.
	///
	/// On the row itself and never between rows. The order of the takes is the
	/// project's and is not something this tree rearranges — what a drop here
	/// means is "file this there", and an insertion point would promise a
	/// reordering that does not happen.
	public func outlineView(_ outlineView: NSOutlineView,
	                        validateDrop info: NSDraggingInfo,
	                        proposedItem item: Any?,
	                        proposedChildIndex index: Int) -> NSDragOperation {
		guard let take = draggedTake(info) else { return [] }
		guard index == NSOutlineViewDropOnItemIndex else {
			// Between two rows: retarget onto whatever they are inside, so the
			// drop still means something rather than being refused.
			guard let held = item as? Held, target(of: held) != nil else { return [] }
			outlineView.setDropItem(held, dropChildIndex: NSOutlineViewDropOnItemIndex)
			return .move
		}
		guard let held = item as? Held, let wanted = target(of: held) else { return [] }
		// Already there is not a move.
		return folders.first(where: { $0.takes.contains(take) })?.name == wanted.name
			? [] : .move
	}

	public func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo,
	                        item: Any?, childIndex index: Int) -> Bool {
		guard let take = draggedTake(info), let held = item as? Held,
		      let wanted = target(of: held) else { return false }
		onMoveTake?(take, wanted.folder)
		return true
	}

	/// What a row means as a place to put a take.
	///
	/// A folder is itself. The `Takes` root is "out of any folder". A take is
	/// wherever *it* is, so dropping one take on another files it beside its
	/// neighbour, which is what the gesture looks like it should do.
	func target(of held: Held) -> (name: String?, folder: String?)? {
		switch held.node.row {
		case .folder(let name, _):
			return (name, name)
		case .root(.takes):
			return (nil, nil)
		case .take(let name, let path, _, _):
			let mine = folders.first { $0.takes.contains(path.isEmpty ? name : path) }?.name
			return (mine, mine)
		default:
			return nil
		}
	}

	private func draggedTake(_ info: NSDraggingInfo) -> String? {
		info.draggingPasteboard.string(forType: Self.takeType)
	}
}
