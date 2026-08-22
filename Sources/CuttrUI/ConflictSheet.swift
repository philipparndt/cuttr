import AppKit
import CuttrKit

/// What to keep, when two people changed the same thing.
///
/// **One row a disagreement, and only disagreements.** Everything that merged
/// went in without anybody being asked; what reaches this sheet is the short
/// list of clips two people both cut. A list of every file that changed would
/// bury the four rows that need a decision under forty that do not.
///
/// **Said in the program's own words.** A clip is named by its name, its times
/// are timecode, and the two columns are "yours" and "theirs". No hunks, no line
/// numbers, no `ours`/`theirs` — somebody who reads a diff for a living is using
/// a git client, and this is for everybody else.
///
/// **Nothing is written until every row is answered.** The merge that produced
/// these was worked out and then abandoned, so the work tree is exactly as it
/// was; closing this sheet without answering leaves it that way.
@MainActor
public final class ConflictSheet: NSViewController {

	/// One thing to decide, flattened out of whichever file it came from.
	public struct Row {
		public var id: String
		public var title: String
		public var mine: String
		public var theirs: String
		/// The file it is in, for the second line of the row.
		public var file: String

		public init(id: String, title: String, mine: String, theirs: String, file: String) {
			self.id = id
			self.title = title
			self.mine = mine
			self.theirs = theirs
			self.file = file
		}
	}

	private let rows: [Row]
	private let onChoose: ([String: TakeMerge.Side]) -> Void
	private var chosen: [String: TakeMerge.Side] = [:]

	private let table = NSTableView()
	private let keepButton = NSButton()
	private var hosted: NSWindow?

	public init(rows: [Row], onChoose: @escaping ([String: TakeMerge.Side]) -> Void) {
		self.rows = rows
		self.onChoose = onChoose
		super.init(nibName: nil, bundle: nil)
	}

	@available(*, unavailable) required init?(coder: NSCoder) { nil }

	@discardableResult
	public static func present(over view: NSView, rows: [Row],
	                           onChoose: @escaping ([String: TakeMerge.Side]) -> Void) -> Bool {
		guard let window = view.window, !rows.isEmpty else { return false }
		let sheet = ConflictSheet(rows: rows, onChoose: onChoose)
		window.beginSheet(sheet.sheet()) { _ in }
		return true
	}

	private func sheet() -> NSWindow {
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 420),
		                      styleMask: [.titled], backing: .buffered, defer: false)
		window.contentViewController = self
		window.title = "Somebody else changed this too"
		window.isReleasedWhenClosed = false
		hosted = window
		return window
	}

	// MARK: - The look of it

	public override func loadView() {
		let root = NSView(frame: NSRect(x: 0, y: 0, width: 680, height: 420))
		root.wantsLayer = true
		root.layer?.backgroundColor = Theme.card.cgColor

		let heading = NSTextField(labelWithString: rows.count == 1
			? "One thing was changed on both sides"
			: "\(rows.count) things were changed on both sides")
		heading.font = Theme.bodyStrong
		heading.textColor = Theme.text

		table.dataSource = self
		table.delegate = self
		table.headerView = NSTableHeaderView()
		table.rowHeight = 34
		table.usesAlternatingRowBackgroundColors = false
		table.backgroundColor = Theme.panel
		table.gridStyleMask = []
		table.allowsMultipleSelection = false
		for (key, title, width) in [("what", "What", 240.0), ("mine", "Yours", 180.0),
		                            ("theirs", "Theirs", 180.0)] {
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

		let note = NSTextField(labelWithString: Self.explanation)
		note.font = Theme.monoSmall
		note.textColor = Theme.dimText
		note.lineBreakMode = .byWordWrapping
		note.maximumNumberOfLines = 3

		let mine = NSButton(title: "Keep Yours", target: self, action: #selector(keepMine))
		mine.bezelStyle = .rounded
		let theirs = NSButton(title: "Keep Theirs", target: self, action: #selector(keepTheirs))
		theirs.bezelStyle = .rounded

		keepButton.title = "Finish"
		keepButton.bezelStyle = .rounded
		keepButton.target = self
		keepButton.action = #selector(finish)
		keepButton.keyEquivalent = "\r"
		keepButton.isEnabled = false

		let cancel = NSButton(title: "Cancel", target: self, action: #selector(close))
		cancel.bezelStyle = .rounded
		cancel.keyEquivalent = "\u{1b}"

		for view in [heading, scroll, note, mine, theirs, keepButton, cancel] as [NSView] {
			view.translatesAutoresizingMaskIntoConstraints = false
			root.addSubview(view)
		}
		NSLayoutConstraint.activate([
			heading.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
			heading.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),

			scroll.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 10),
			scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
			scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),

			mine.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
			mine.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
			theirs.leadingAnchor.constraint(equalTo: mine.trailingAnchor, constant: 8),
			theirs.topAnchor.constraint(equalTo: mine.topAnchor),

			note.topAnchor.constraint(equalTo: mine.bottomAnchor, constant: 10),
			note.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
			note.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),

			keepButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
			keepButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
			cancel.trailingAnchor.constraint(equalTo: keepButton.leadingAnchor, constant: -8),
			cancel.bottomAnchor.constraint(equalTo: keepButton.bottomAnchor),
			note.bottomAnchor.constraint(lessThanOrEqualTo: keepButton.topAnchor, constant: -10),
		])

		preferredContentSize = NSSize(width: 680, height: 420)
		for wish in [root.widthAnchor.constraint(equalToConstant: 680),
		             root.heightAnchor.constraint(equalToConstant: 420)] {
			wish.priority = NSLayoutConstraint.Priority(250)
			wish.isActive = true
		}
		view = root
		table.reloadData()
	}

	static let explanation = "Nothing has been written yet. Cancel leaves everything "
		+ "exactly as it is now, and your own cut is what is on the disk."

	// MARK: - Choosing

	/// Every row answered, which is when there is something to write.
	var isAnswered: Bool { rows.allSatisfy { chosen[$0.id] != nil } }

	func choice(for id: String) -> TakeMerge.Side? { chosen[id] }

	/// For the tests, and for a sheet driven rather than clicked.
	func choose(_ side: TakeMerge.Side, forRow row: Int) {
		guard rows.indices.contains(row) else { return }
		chosen[rows[row].id] = side
		keepButton.isEnabled = isAnswered
		table.reloadData(forRowIndexes: IndexSet(integer: row),
		                 columnIndexes: IndexSet(integersIn: 0 ..< table.numberOfColumns))
	}

	@objc private func keepMine() { choose(.mine, forRow: table.selectedRow) }
	@objc private func keepTheirs() { choose(.theirs, forRow: table.selectedRow) }

	@objc private func finish() {
		guard isAnswered else { return }
		let answers = chosen
		close()
		onChoose(answers)
	}

	@objc private func close() {
		guard let hosted, let parent = hosted.sheetParent else { return }
		parent.endSheet(hosted)
	}
}

extension ConflictSheet: NSTableViewDataSource, NSTableViewDelegate {

	public func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

	public func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?,
	                      row: Int) -> NSView? {
		guard rows.indices.contains(row), let column else { return nil }
		let entry = rows[row]
		let side = chosen[entry.id]

		let field = NSTextField(labelWithString: "")
		field.font = Theme.monoSmall
		field.lineBreakMode = .byTruncatingTail

		switch column.identifier.rawValue {
		case "what":
			// The file underneath, because two takes can each have an `intro`
			// and a row that does not say which is a row nobody can answer.
			let text = NSMutableAttributedString(
				string: entry.title + "\n",
				attributes: [.font: Theme.bodyStrong, .foregroundColor: Theme.text])
			text.append(NSAttributedString(
				string: entry.file,
				attributes: [.font: Theme.monoSmall, .foregroundColor: Theme.dimText]))
			field.attributedStringValue = text
			field.maximumNumberOfLines = 2
		case "mine":
			field.stringValue = entry.mine
			field.textColor = side == .mine ? Theme.text : Theme.dimText
			// A tick rather than a colour alone: the difference between the two
			// columns has to survive somebody who cannot tell them apart.
			if side == .mine { field.stringValue = "✓ " + entry.mine }
		case "theirs":
			field.stringValue = entry.theirs
			field.textColor = side == .theirs ? Theme.text : Theme.dimText
			if side == .theirs { field.stringValue = "✓ " + entry.theirs }
		default:
			return nil
		}
		return field
	}
}

// MARK: - Turning a merge into rows

public extension ConflictSheet {

	/// The sheet's rows for everything a share could not settle.
	static func rows(for choose: ProjectSharing.MustChoose) -> [Row] {
		var out: [Row] = []
		for (path, merged) in choose.takes {
			let file = (path as NSString).lastPathComponent
			for conflict in merged.conflicts {
				out.append(Row(id: conflict.id, title: conflict.title,
				               mine: said(conflict.subject, .mine),
				               theirs: said(conflict.subject, .theirs), file: file))
			}
		}
		for (path, merged) in choose.projects {
			let file = (path as NSString).lastPathComponent
			for conflict in merged.conflicts {
				out.append(Row(id: conflict.id, title: conflict.title,
				               mine: "yours", theirs: "theirs", file: file))
			}
		}
		return out
	}

	/// What one side of a disagreement says, in timecode rather than in
	/// seconds — the row has to be readable by somebody looking at a timeline.
	private static func said(_ subject: TakeMerge.Conflict.Subject,
	                         _ side: TakeMerge.Side) -> String {
		switch subject {
		case .clip(_, let mine, let theirs):
			guard let clip = side == .mine ? mine : theirs else { return "removed" }
			return "\(Timecode.string(clip.start)) → \(Timecode.string(clip.end))"
		case .video(let mine, let theirs):
			return (side == .mine ? mine : theirs) ?? "none"
		case .audio(let mine, let theirs):
			guard let track = side == .mine ? mine : theirs else { return "none" }
			let sign = track.offset < 0 ? "−" : "+"
			return "\(track.file) \(sign)\(Timecode.string(abs(track.offset)))"
		case .words(let mine, let theirs):
			return (side == .mine ? mine : theirs)?.path ?? "none"
		}
	}
}
