import AppKit
import CuttrCompose
import CuttrKit

/// Everything an overlay can be pinned to, in one list.
///
/// A combo box was the wrong shape for this. It offered `clip-4` — which is
/// what the *file* writes, and deliberately so, because a slug that is unique
/// across the takes is written bare and stays diffable — but a project with
/// four takes in it has four clips called `clip-4`, and the box could not say
/// which one was meant. What somebody needs to see is the whole address, take
/// and clip; what the file needs to keep is the short form. So the two are
/// separated here: `path` is shown, `reference` is written.
public struct EndpointCatalogue: Sendable {

	public struct Entry: Sendable, Equatable {
		public enum Kind: Sendable, Equatable { case section, placement, clip }
		public var kind: Kind
		/// What a project writes to mean this — `@name`, or a clip's reference,
		/// bare when the slug is unique and `take/slug` when it is not.
		public var reference: String
		/// Take and clip, always, whatever the reference is short enough to be.
		public var path: String
		/// The clip's own name, or what kind of thing a name is.
		public var detail: String
		/// Which take it belongs to, for the headings.
		public var take: String

		public init(kind: Kind, reference: String, path: String, detail: String, take: String) {
			self.kind = kind
			self.reference = reference
			self.path = path
			self.detail = detail
			self.take = take
		}
	}

	public var entries: [Entry]

	public init(entries: [Entry]) {
		self.entries = entries
	}

	/// The three kinds of thing a `when:` can name, in the order they are worth
	/// reaching for: the sections of the programme, the placements somebody
	/// named with `as:`, and then every clip.
	public init(_ vocabulary: ComposeDocument.Vocabulary) {
		var entries: [Entry] = []
		for name in vocabulary.groups {
			entries.append(Entry(kind: .section, reference: "@\(name)", path: "@\(name)",
			                     detail: "a section of the programme", take: ""))
		}
		for name in vocabulary.labels {
			entries.append(Entry(kind: .placement, reference: "@\(name)", path: "@\(name)",
			                     detail: "one placement, named with as:", take: ""))
		}
		for item in vocabulary.items {
			entries.append(Entry(
				kind: .clip, reference: item.reference, path: "\(item.take)/\(item.slug)",
				detail: item.name, take: item.take))
		}
		self.entries = entries
	}

	/// What to show for what the file says.
	///
	/// A bare `clip-4` is looked up so the panel can show which take it is in.
	/// When it cannot be found — a slug that has been renamed, a take that has
	/// moved — what the file says is shown as it is, because inventing a take
	/// name for a reference that resolves to nothing would hide the fault.
	public func path(for endpoint: Overlay.Span.Endpoint) -> String {
		switch endpoint {
		case .group(let name):
			return "@\(name)"
		case .clip(let reference):
			if let take = reference.take { return "\(take)/\(reference.slug)" }
			if let found = entries.first(where: { $0.kind == .clip && $0.reference == reference.slug }) {
				return found.path
			}
			return reference.description
		}
	}

	/// Whether what the file says is something that is actually there.
	///
	/// Compared as addresses, not as references: `mia-take-1/clip-4` and
	/// `clip-4` are the same clip written two ways, and a project is free to
	/// spell it either. Comparing the written forms said a perfectly good
	/// `when:` was missing.
	public func knows(_ endpoint: Overlay.Span.Endpoint) -> Bool {
		let address = path(for: endpoint)
		return entries.contains { $0.path == address || $0.reference == endpoint.description }
	}

	/// Only the kinds asked for. A timeline entry names a *clip*: a section is
	/// not something `- clip:` can point at, and offering one is offering a
	/// mistake.
	public func only(_ kinds: Set<Entry.Kind>) -> EndpointCatalogue {
		EndpointCatalogue(entries: entries.filter { kinds.contains($0.kind) })
	}

	/// Everything whose address or name contains what was typed, word by word,
	/// so `mia 4` finds `mia-take-1/clip-4`.
	public func matching(_ query: String) -> [Entry] {
		let words = query.lowercased().split(whereSeparator: { $0 == " " || $0 == "/" })
		guard !words.isEmpty else { return entries }
		return entries.filter { entry in
			let haystack = "\(entry.path) \(entry.detail)".lowercased()
			return words.allSatisfy { haystack.contains($0) }
		}
	}
}

/// The dialog that chooses one.
///
/// A sheet rather than a menu because the list is long, has three kinds of
/// thing in it, and is worth searching. It shows the full path of everything,
/// including the `as:` placements, which is the whole reason it exists.
@MainActor
public final class EndpointPicker: NSViewController {

	private enum Row {
		case heading(String)
		case entry(EndpointCatalogue.Entry)
	}

	private let catalogue: EndpointCatalogue
	private let current: String
	private let onChoose: (String) -> Void
	let searchField = NSSearchField()
	private let table = NSTableView()
	private var rows: [Row] = []

	public init(catalogue: EndpointCatalogue, current: String,
	            onChoose: @escaping (String) -> Void) {
		self.catalogue = catalogue
		self.current = current
		self.onChoose = onChoose
		super.init(nibName: nil, bundle: nil)
	}

	@available(*, unavailable) required init?(coder: NSCoder) { nil }

	/// Put it up over whatever is asking.
	public static func present(over view: NSView, catalogue: EndpointCatalogue,
	                           current: String, onChoose: @escaping (String) -> Void) {
		guard let window = view.window else { return }
		let picker = EndpointPicker(catalogue: catalogue, current: current, onChoose: onChoose)
		window.beginSheet(picker.sheet()) { _ in }
	}

	private var hosted: NSWindow?

	private func sheet() -> NSWindow {
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
		                      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
		window.contentViewController = self
		window.title = "Choose what it hangs on"
		// A sheet somebody dismisses is one this object still owns; letting the
		// close release it is how a dialog turns into a crash.
		window.isReleasedWhenClosed = false
		hosted = window
		return window
	}

	public override func loadView() {
		let root = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 420))
		root.wantsLayer = true
		root.layer?.backgroundColor = Theme.card.cgColor

		searchField.placeholderString = "take, clip, section"
		searchField.font = Theme.body
		searchField.target = self
		searchField.action = #selector(searched)
		searchField.sendsWholeSearchString = false
		searchField.sendsSearchStringImmediately = true

		table.headerView = nil
		table.backgroundColor = Theme.background
		table.rowHeight = 30
		table.gridStyleMask = []
		table.style = .plain
		table.selectionHighlightStyle = .regular
		table.intercellSpacing = NSSize(width: 0, height: 0)
		table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("what")))
		table.dataSource = self
		table.delegate = self
		table.target = self
		table.doubleAction = #selector(confirm)

		let scroll = NSScrollView()
		scroll.documentView = table
		scroll.hasVerticalScroller = true
		scroll.drawsBackground = true
		scroll.backgroundColor = Theme.background
		scroll.borderType = .noBorder

		let choose = NSButton(title: "Choose", target: self, action: #selector(confirm))
		choose.bezelStyle = .rounded
		choose.keyEquivalent = "\r"
		let cancel = NSButton(title: "Cancel", target: self, action: #selector(self.cancel))
		cancel.bezelStyle = .rounded
		cancel.keyEquivalent = "\u{1b}"

		for view in [searchField, scroll, choose, cancel] as [NSView] {
			view.translatesAutoresizingMaskIntoConstraints = false
			root.addSubview(view)
		}
		NSLayoutConstraint.activate([
			searchField.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
			searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
			searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),

			scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
			scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
			scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
			scroll.bottomAnchor.constraint(equalTo: choose.topAnchor, constant: -10),

			choose.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
			choose.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
			cancel.trailingAnchor.constraint(equalTo: choose.leadingAnchor, constant: -8),
			cancel.bottomAnchor.constraint(equalTo: choose.bottomAnchor),
		])
		// The size the sheet opens at, said in constraints as well as in the
		// window's frame.
		//
		// A window whose `contentViewController` is set takes its size from the
		// view's own fitting size, and a view laid out entirely with edge
		// constraints has none worth having: the meme panel came up as a column
		// one search field wide, with the grid and the buttons squeezed into a
		// sliver. The preferred size is what it wants, the minimums are what it
		// will not go below, and both are needed.
		preferredContentSize = NSSize(width: 460, height: 420)
		let wide = root.widthAnchor.constraint(equalToConstant: 460)
		let tall = root.heightAnchor.constraint(equalToConstant: 420)
		for wish in [wide, tall] {
			wish.priority = NSLayoutConstraint.Priority(250)
			wish.isActive = true
		}
		NSLayoutConstraint.activate([
			root.widthAnchor.constraint(greaterThanOrEqualToConstant: 360),
			root.heightAnchor.constraint(greaterThanOrEqualToConstant: 300),
		])
		view = root
		rebuild()
	}

	public override func viewDidAppear() {
		super.viewDidAppear()
		view.window?.makeFirstResponder(searchField)
	}

	// MARK: - The list

	/// Grouped under headings, because forty clips in a flat list is a wall and
	/// "which take was that in" is the question this dialog exists to answer.
	func rebuild() {
		let found = catalogue.matching(searchField.stringValue)
		var rows: [Row] = []
		let sections = found.filter { $0.kind == .section }
		let placements = found.filter { $0.kind == .placement }
		if !sections.isEmpty {
			rows.append(.heading("SECTIONS"))
			rows.append(contentsOf: sections.map(Row.entry))
		}
		if !placements.isEmpty {
			rows.append(.heading("NAMED PLACEMENTS"))
			rows.append(contentsOf: placements.map(Row.entry))
		}
		var seen: [String] = []
		for entry in found where entry.kind == .clip {
			if !seen.contains(entry.take) {
				seen.append(entry.take)
				rows.append(.heading(entry.take.uppercased()))
			}
			rows.append(.entry(entry))
		}
		self.rows = rows
		table.reloadData()

		// Whatever is set now, if it is still in the list — so the dialog opens
		// showing where the overlay already hangs rather than at the top.
		let pick = rows.firstIndex {
			if case .entry(let entry) = $0 { return entry.reference == current }
			return false
		} ?? rows.firstIndex { if case .entry = $0 { return true } else { return false } }
		if let pick {
			table.selectRowIndexes([pick], byExtendingSelection: false)
			table.scrollRowToVisible(pick)
		}
	}

	/// What is selected now, if it is something choosable.
	var chosen: EndpointCatalogue.Entry? {
		let row = table.selectedRow
		guard row >= 0, row < rows.count, case .entry(let entry) = rows[row] else { return nil }
		return entry
	}

	@objc private func searched() { rebuild() }

	@objc func confirm() {
		guard let chosen else { return }
		onChoose(chosen.reference)
		close()
	}

	@objc private func cancel() { close() }

	private func close() {
		guard let window = view.window else { return }
		window.sheetParent?.endSheet(window)
		hosted = nil
	}
}

extension EndpointPicker: NSTableViewDataSource, NSTableViewDelegate {

	public func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

	public func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
		guard row < rows.count, case .heading = rows[row] else { return false }
		return true
	}

	public func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
		guard row < rows.count, case .entry = rows[row] else { return false }
		return true
	}

	public func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
		guard row < rows.count, case .heading = rows[row] else { return 34 }
		return 22
	}

	public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
	                      row: Int) -> NSView? {
		guard row < rows.count else { return nil }
		switch rows[row] {
		case .heading(let name):
			let label = NSTextField(labelWithString: name)
			label.font = Theme.heading
			label.textColor = Theme.faintText
			let holder = NSView()
			label.translatesAutoresizingMaskIntoConstraints = false
			holder.addSubview(label)
			NSLayoutConstraint.activate([
				label.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 8),
				label.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
			])
			return holder
		case .entry(let entry):
			let kind: Theme.Kind
			switch entry.kind {
			case .section: kind = .section
			case .placement: kind = .list
			case .clip: kind = .clip
			}
			let icon = NSImageView(image: Theme.symbol(kind, size: 12) ?? NSImage())
			// The whole address, which is the point of the dialog.
			let path = NSTextField(labelWithString: entry.path)
			path.font = Theme.mono
			path.textColor = Theme.text
			let detail = NSTextField(labelWithString: entry.detail)
			detail.font = Theme.body
			detail.textColor = Theme.dimText
			detail.lineBreakMode = .byTruncatingTail

			let holder = NSView()
			for view in [icon, path, detail] as [NSView] {
				view.translatesAutoresizingMaskIntoConstraints = false
				holder.addSubview(view)
			}
			NSLayoutConstraint.activate([
				icon.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 10),
				icon.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
				path.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
				path.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
				detail.leadingAnchor.constraint(equalTo: path.trailingAnchor, constant: 10),
				detail.trailingAnchor.constraint(lessThanOrEqualTo: holder.trailingAnchor,
				                                 constant: -10),
				detail.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
			])
			return holder
		}
	}
}
