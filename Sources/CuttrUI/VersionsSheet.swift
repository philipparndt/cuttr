import AppKit

/// The versions kept of a project, and the way back to one.
///
/// A ref full of commits nobody can reach is a safety net with no handle. This
/// is the handle: when each version was kept, what changed in it, which files it
/// holds, and a button that writes one back over the disk.
///
/// Two things it says out loud, because they are the reason this is safe to
/// press. Restoring writes *files* — it moves no branch, stages nothing, and
/// leaves `HEAD` where it was. And the state being left is kept as a version
/// first, so going back is not a way to lose the thing you were doing.
@MainActor
public final class VersionsSheet: NSViewController {

	private let versions: [ProjectVersions.Version]
	private let onRestore: (String) -> ProjectVersions.Outcome

	private let table = NSTableView()
	private let files = NSTextView()
	private let note = NSTextField(labelWithString: "")
	private let restoreButton = NSButton()
	private var hosted: NSWindow?

	public init(versions: [ProjectVersions.Version],
	            onRestore: @escaping (String) -> ProjectVersions.Outcome) {
		self.versions = versions
		self.onRestore = onRestore
		super.init(nibName: nil, bundle: nil)
	}

	@available(*, unavailable) required init?(coder: NSCoder) { nil }

	/// Opens it over a window. Nothing at all when there is nothing to show:
	/// a sheet saying "no versions" over a project on a footage volume is a
	/// sheet about this program's plumbing rather than about somebody's work.
	@discardableResult
	public static func present(over view: NSView, versions: [ProjectVersions.Version],
	                           onRestore: @escaping (String) -> ProjectVersions.Outcome) -> Bool {
		guard let window = view.window, !versions.isEmpty else { return false }
		let sheet = VersionsSheet(versions: versions, onRestore: onRestore)
		window.beginSheet(sheet.sheet()) { _ in }
		return true
	}

	private func sheet() -> NSWindow {
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
		                      styleMask: [.titled], backing: .buffered, defer: false)
		window.contentViewController = self
		window.title = "Versions"
		window.isReleasedWhenClosed = false
		hosted = window
		return window
	}

	public override func loadView() {
		let root = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 420))
		root.wantsLayer = true
		root.layer?.backgroundColor = Theme.card.cgColor

		let heading = NSTextField(labelWithString: "Versions kept while you worked")
		heading.font = Theme.bodyStrong
		heading.textColor = Theme.text

		table.dataSource = self
		table.delegate = self
		table.headerView = NSTableHeaderView()
		table.rowHeight = 20
		table.usesAlternatingRowBackgroundColors = false
		table.backgroundColor = Theme.panel
		table.gridStyleMask = []
		table.allowsMultipleSelection = false
		for (key, title, width) in [("when", "When", 130.0), ("what", "What changed", 420.0)] {
			let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key))
			column.title = title
			column.width = width
			table.addTableColumn(column)
		}
		let scroll = NSScrollView()
		scroll.documentView = table
		scroll.hasVerticalScroller = true
		scroll.borderType = .noBorder
		scroll.drawsBackground = false

		files.isEditable = false
		files.font = Theme.monoSmall
		files.textColor = Theme.dimText
		files.backgroundColor = Theme.panel
		files.drawsBackground = true
		let filesScroll = NSScrollView()
		filesScroll.documentView = files
		filesScroll.hasVerticalScroller = true
		filesScroll.borderType = .noBorder
		filesScroll.drawsBackground = false

		note.stringValue = Self.explanation
		note.font = Theme.monoSmall
		note.textColor = Theme.dimText
		note.lineBreakMode = .byWordWrapping
		note.maximumNumberOfLines = 3

		restoreButton.title = "Restore"
		restoreButton.bezelStyle = .rounded
		restoreButton.target = self
		restoreButton.action = #selector(restore)
		restoreButton.isEnabled = false
		let done = NSButton(title: "Done", target: self, action: #selector(close))
		done.bezelStyle = .rounded
		done.keyEquivalent = "\r"

		for view in [heading, scroll, filesScroll, note, restoreButton, done] as [NSView] {
			view.translatesAutoresizingMaskIntoConstraints = false
			root.addSubview(view)
		}
		NSLayoutConstraint.activate([
			heading.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
			heading.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),

			scroll.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 10),
			scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
			scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
			scroll.heightAnchor.constraint(equalTo: root.heightAnchor, multiplier: 0.5),

			filesScroll.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
			filesScroll.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
			filesScroll.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
			filesScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 60),

			note.topAnchor.constraint(equalTo: filesScroll.bottomAnchor, constant: 10),
			note.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
			note.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),

			done.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
			done.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
			restoreButton.trailingAnchor.constraint(equalTo: done.leadingAnchor, constant: -8),
			restoreButton.bottomAnchor.constraint(equalTo: done.bottomAnchor),
			note.bottomAnchor.constraint(lessThanOrEqualTo: done.topAnchor, constant: -10),
		])

		// Both, for the reason in `SettingsSheet`: a window sized from its
		// content view controller takes the view's fitting size, and a view laid
		// out entirely with edge constraints has none worth having.
		preferredContentSize = NSSize(width: 640, height: 420)
		for wish in [root.widthAnchor.constraint(equalToConstant: 640),
		             root.heightAnchor.constraint(equalToConstant: 420)] {
			wish.priority = NSLayoutConstraint.Priority(250)
			wish.isActive = true
		}
		NSLayoutConstraint.activate([
			root.widthAnchor.constraint(greaterThanOrEqualToConstant: 480),
			root.heightAnchor.constraint(greaterThanOrEqualToConstant: 320),
		])
		view = root
		table.reloadData()
	}

	static let explanation = "Restoring writes these files back and nothing else: "
		+ "no branch moves, nothing is staged, HEAD stays where it is. "
		+ "What is on disk now is kept as a version first."

	/// When a version was kept, in the reader's own locale — this is a list
	/// somebody scans for "about an hour ago", and a fixed format would be the
	/// wrong one for half the world.
	static func when(_ date: Date, now: Date = Date()) -> String {
		let formatter = DateFormatter()
		formatter.dateStyle = Calendar.current.isDateInToday(date) ? .none : .short
		formatter.timeStyle = .short
		return formatter.string(from: date)
	}

	// MARK: - Doing it

	@objc private func restore() {
		let row = table.selectedRow
		guard versions.indices.contains(row) else { return }
		switch onRestore(versions[row].commit) {
		case .kept:
			close()
		case .nothingChanged:
			close()
		case .busy(let what):
			say("\(what) is in progress — finish it first.")
		case .noRepository:
			say("this project is not in a repository any more.")
		case .failed(let why):
			say(why)
		}
	}

	private func say(_ text: String) {
		note.stringValue = text
		note.textColor = Theme.base(.rose)
	}

	@objc private func close() {
		guard let window = view.window else { return }
		if let parent = window.sheetParent { parent.endSheet(window) } else { window.close() }
		hosted = nil
	}

	// MARK: - For the tests

	/// Choose a row without a mouse. Nothing here dispatches a key event: an
	/// unhandled one reaches `NSResponder` and beeps on somebody's machine.
	func select(_ row: Int) {
		table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
		show(row)
	}

	func restoreForTesting() { restore() }
	var noteForTesting: String { note.stringValue }
	var canRestore: Bool { restoreButton.isEnabled }
	var rows: Int { versions.count }
	var filesShown: String { files.string }

	private func show(_ row: Int) {
		restoreButton.isEnabled = versions.indices.contains(row)
		guard versions.indices.contains(row) else { files.string = ""; return }
		files.string = versions[row].files.joined(separator: "\n")
	}
}

extension VersionsSheet: NSTableViewDataSource, NSTableViewDelegate {

	public func numberOfRows(in tableView: NSTableView) -> Int { versions.count }

	public func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?,
	                      row: Int) -> NSView? {
		guard versions.indices.contains(row) else { return nil }
		let version = versions[row]
		let label = NSTextField(labelWithString: "")
		label.font = column?.identifier.rawValue == "when" ? Theme.mono : Theme.body
		label.textColor = Theme.text
		label.lineBreakMode = .byTruncatingTail
		label.stringValue = column?.identifier.rawValue == "when"
			? Self.when(version.when) : version.title
		label.toolTip = version.short
		return label
	}

	public func tableViewSelectionDidChange(_ notification: Notification) {
		show(table.selectedRow)
	}
}
