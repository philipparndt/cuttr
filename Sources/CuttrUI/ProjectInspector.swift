import AppKit
import CuttrCompose
import CuttrKit

/// Editing the project, and learning its file format while you do.
///
/// The panel is a teaching aid as much as an editor, and that decides how it
/// looks. Every field is labelled with the **key it writes** — `fps`, `from`,
/// `match.reference` — rather than with a friendly paraphrase, and the pane at
/// the bottom shows the YAML the current selection produces, live, straight out
/// of the same emitter that writes the file. Nothing here renders a description
/// of the format; it shows the format.
///
/// The intended arc is that somebody uses the panel, reads what it wrote, and
/// after a week stops using the panel. A tool whose UI hides its file is a tool
/// you can never graduate from.
@MainActor
public final class ProjectInspector: NSView, NSTableViewDataSource, NSTableViewDelegate {

	/// A whole project, edited. The window applies and saves it.
	public var onChange: ((Project) -> Void)?

	private var project = Project()
	private var rows: [Project.Row] = []

	private let timelineTable = NSTableView()
	private let overlayTable = NSTableView()
	private let yaml = NSTextView()

	private let width = NSTextField()
	private let height = NSTextField()
	private let fps = NSTextField()
	private let target = NSTextField()
	private let ceiling = NSTextField()
	private let reference = NSTextField()

	public override init(frame: NSRect) {
		super.init(frame: frame)
		wantsLayer = true
		layer?.backgroundColor = Theme.panel.cgColor

		let stack = NSStackView(views: [
			section("output", output()),
			section("timeline", timeline()),
			section("overlays", overlays()),
			section("what this writes", writes()),
		])
		stack.orientation = .vertical
		stack.spacing = 10
		stack.alignment = .leading
		stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
		stack.translatesAutoresizingMaskIntoConstraints = false
		addSubview(stack)
		NSLayoutConstraint.activate([
			stack.topAnchor.constraint(equalTo: topAnchor),
			stack.bottomAnchor.constraint(equalTo: bottomAnchor),
			stack.leadingAnchor.constraint(equalTo: leadingAnchor),
			stack.trailingAnchor.constraint(equalTo: trailingAnchor),
		])
	}

	@available(*, unavailable) required init?(coder: NSCoder) { nil }

	// MARK: - Furniture

	/// A heading in the file's own vocabulary, so the panel and the file read
	/// as one thing.
	private func section(_ title: String, _ body: NSView) -> NSView {
		let label = NSTextField(labelWithString: title)
		label.font = Theme.monoSmall
		label.textColor = Theme.dimText
		let stack = NSStackView(views: [label, body])
		stack.orientation = .vertical
		stack.spacing = 4
		stack.alignment = .leading
		body.translatesAutoresizingMaskIntoConstraints = false
		body.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
		return stack
	}

	private func field(_ control: NSTextField, _ width: CGFloat, _ placeholder: String) -> NSTextField {
		control.font = Theme.mono
		control.placeholderString = placeholder
		control.target = self
		control.action = #selector(outputEdited)
		control.translatesAutoresizingMaskIntoConstraints = false
		control.widthAnchor.constraint(equalToConstant: width).isActive = true
		return control
	}

	private func caption(_ text: String) -> NSTextField {
		let label = NSTextField(labelWithString: text)
		label.font = Theme.monoSmall
		label.textColor = Theme.dimText
		return label
	}

	private func button(_ title: String, _ action: Selector, _ tip: String) -> NSButton {
		let button = NSButton()
		button.title = title
		button.bezelStyle = .rounded
		button.controlSize = .small
		button.font = NSFont.systemFont(ofSize: 11)
		button.target = self
		button.action = action
		button.toolTip = tip
		return button
	}

	// MARK: - output

	private func output() -> NSView {
		let size = NSStackView(views: [
			caption("size"), field(width, 56, "1920"), caption("x"), field(height, 56, "1080"),
			caption("fps"), field(fps, 44, "25"),
		])
		size.orientation = .horizontal
		size.spacing = 4

		let sound = NSStackView(views: [
			caption("audio.target"), field(target, 52, "-16"),
			caption("ceiling"), field(ceiling, 46, "-1"),
		])
		sound.orientation = .horizontal
		sound.spacing = 4

		let match = NSStackView(views: [caption("match.reference"), field(reference, 120, "a clip slug")])
		match.orientation = .horizontal
		match.spacing = 4

		let stack = NSStackView(views: [size, sound, match])
		stack.orientation = .vertical
		stack.spacing = 4
		stack.alignment = .leading
		return stack
	}

	@objc private func outputEdited() {
		var next = project
		next.output.width = Int(width.stringValue) ?? next.output.width
		next.output.height = Int(height.stringValue) ?? next.output.height
		next.output.framesPerSecond = Double(fps.stringValue) ?? next.output.framesPerSecond
		// Blank means "say nothing about it", which is different from zero: a
		// project with no `audio:` leaves the levels exactly as recorded.
		if target.stringValue.isEmpty, ceiling.stringValue.isEmpty {
			next.output.audio = nil
		} else {
			var audio = next.output.audio ?? AudioTarget()
			if let value = Double(target.stringValue) { audio.target = value }
			if let value = Double(ceiling.stringValue) { audio.ceiling = value }
			next.output.audio = audio
		}
		let slug = reference.stringValue.trimmingCharacters(in: .whitespaces)
		next.output.matchReference = slug.isEmpty ? nil : Slug.make(from: slug)
		onChange?(next)
	}

	// MARK: - timeline

	private func timeline() -> NSView {
		timelineTable.dataSource = self
		timelineTable.delegate = self
		timelineTable.headerView = nil
		timelineTable.rowHeight = 20
		timelineTable.backgroundColor = Theme.panel
		timelineTable.gridStyleMask = []
		timelineTable.usesAlternatingRowBackgroundColors = true
		let entry = NSTableColumn(identifier: .init("entry"))
		entry.width = 200
		timelineTable.addTableColumn(entry)
		let transition = NSTableColumn(identifier: .init("transition"))
		transition.width = 52
		timelineTable.addTableColumn(transition)

		let scroll = TableScroll.make(timelineTable)
		scroll.translatesAutoresizingMaskIntoConstraints = false
		scroll.heightAnchor.constraint(equalToConstant: 150).isActive = true

		let buttons = NSStackView(views: [
			button("+ clip", #selector(addClip), "A clip by slug. Type `#tag` for a query."),
			button("+ group", #selector(addGroup), "A named section: overlays can be hung on it."),
			button("−", #selector(removeEntry), "Take it off the timeline"),
			button("↑", #selector(moveEntryUp), "Earlier"),
			button("↓", #selector(moveEntryDown), "Later"),
		])
		buttons.orientation = .horizontal
		buttons.spacing = 4

		let stack = NSStackView(views: [scroll, buttons])
		stack.orientation = .vertical
		stack.spacing = 4
		stack.alignment = .leading
		scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
		return stack
	}

	private var selectedPath: [Int]? {
		let row = timelineTable.selectedRow
		guard row >= 0, row < rows.count else { return nil }
		return rows[row].path
	}

	@objc private func addClip() {
		var next = project
		let slug = next.timeline.isEmpty ? "intro" : "clip"
		next.insertEntry(TimelineEntry(clip: ClipReference(slug)), after: selectedPath)
		onChange?(next)
	}

	@objc private func addGroup() {
		var next = project
		next.insertEntry(TimelineEntry(group: "section", entries: []), after: selectedPath)
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
		next.moveEntry(at: path, by: offset)
		onChange?(next)
	}

	@objc private func entryEdited(_ sender: NSTextField) {
		let row = timelineTable.row(for: sender)
		guard row >= 0, row < rows.count else { return }
		let path = rows[row].path
		let existing = rows[row].entry
		var next = project

		if timelineTable.column(for: sender) == 1 {
			next.replaceEntry(at: path, with: TimelineEntry(
				source: existing.source, transition: Double(sender.stringValue) ?? 0))
			onChange?(next)
			return
		}

		// A group keeps its contents when it is renamed; anything else is
		// re-read from what was typed, by the same rule the file uses.
		if case .group(_, let inner) = existing.source, sender.stringValue.hasPrefix("@") {
			next.replaceEntry(at: path, with: TimelineEntry(
				group: Slug.make(from: String(sender.stringValue.dropFirst())),
				entries: inner, transition: existing.transition))
		} else if let replacement = try? TimelineEntry(
			text: sender.stringValue, transition: existing.transition) {
			next.replaceEntry(at: path, with: replacement)
		} else {
			reload(project)   // unreadable: put it back
			return
		}
		onChange?(next)
	}

	// MARK: - overlays

	private func overlays() -> NSView {
		overlayTable.dataSource = self
		overlayTable.delegate = self
		overlayTable.rowHeight = 20
		overlayTable.backgroundColor = Theme.panel
		overlayTable.gridStyleMask = []
		overlayTable.usesAlternatingRowBackgroundColors = true
		for (identifier, title, width) in [("what", "text / spinner", CGFloat(150)),
		                                   ("from", "from", 90), ("to", "to", 90)] {
			let column = NSTableColumn(identifier: .init(identifier))
			column.title = title
			column.width = width
			overlayTable.addTableColumn(column)
		}

		let scroll = TableScroll.make(overlayTable)
		scroll.translatesAutoresizingMaskIntoConstraints = false
		scroll.heightAnchor.constraint(equalToConstant: 120).isActive = true

		let buttons = NSStackView(views: [
			button("+ text", #selector(addText), "A caption. It slides in and out by default."),
			button("+ spinner", #selector(addSpinner), "A spinner. Give it an `anchor:` to pin it to a face."),
			button("−", #selector(removeOverlay), "Remove it"),
		])
		buttons.orientation = .horizontal
		buttons.spacing = 4

		let stack = NSStackView(views: [scroll, buttons])
		stack.orientation = .vertical
		stack.spacing = 4
		stack.alignment = .leading
		scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
		return stack
	}

	/// The clip or section a new overlay should cover: whatever is selected on
	/// the timeline, or the first thing on it.
	private var spanForNewOverlay: Overlay.Span {
		let source = selectedPath.flatMap { project.entry(at: $0)?.source } ?? project.timeline.first?.source
		switch source {
		case .group(let name, _):
			return .marks(from: .group(name), to: .group(name))
		case .clip(let reference):
			return .clips(from: reference, to: reference)
		default:
			return .clips(from: ClipReference("intro"), to: ClipReference("intro"))
		}
	}

	@objc private func addText() {
		var next = project
		next.overlays.append(Overlay(kind: .text("Caption", style: nil), span: spanForNewOverlay))
		onChange?(next)
	}

	@objc private func addSpinner() {
		var next = project
		next.overlays.append(Overlay(
			kind: .spinner(Spinner()), span: spanForNewOverlay,
			arrival: .fade(over: 0.3), departure: .fade(over: 0.3)))
		onChange?(next)
	}

	@objc private func removeOverlay() {
		let row = overlayTable.selectedRow
		guard row >= 0, row < project.overlays.count else { return }
		var next = project
		next.overlays.remove(at: row)
		onChange?(next)
	}

	@objc private func overlayEdited(_ sender: NSTextField) {
		let row = overlayTable.row(for: sender)
		let column = overlayTable.column(for: sender)
		guard row >= 0, row < project.overlays.count, column >= 0 else { return }
		var next = project
		var overlay = next.overlays[row]

		switch overlayTable.tableColumns[column].identifier.rawValue {
		case "what":
			switch overlay.kind {
			case .text(_, let style):
				overlay.kind = .text(sender.stringValue, style: style)
			case .spinner(var spinner):
				// A spinner's words, comma separated — the same shape the file
				// takes for the simple case.
				spinner.words = sender.stringValue
					.split(separator: ",")
					.map { SpinnerWord($0.trimmingCharacters(in: .whitespaces)) }
					.filter { !$0.text.isEmpty }
				overlay.kind = .spinner(spinner)
			}
		case "from", "to":
			let endpoint = Overlay.Span.Endpoint(sender.stringValue.trimmingCharacters(in: .whitespaces))
			if case .marks(let from, let to) = overlay.span {
				overlay.span = overlayTable.tableColumns[column].identifier.rawValue == "from"
					? .marks(from: endpoint, to: to)
					: .marks(from: from, to: endpoint)
			} else {
				overlay.span = .marks(from: endpoint, to: endpoint)
			}
		default:
			return
		}
		next.overlays[row] = overlay
		onChange?(next)
	}

	// MARK: - what this writes

	private func writes() -> NSView {
		let scroll = NSScrollView()
		scroll.hasVerticalScroller = true
		scroll.drawsBackground = false
		yaml.isEditable = false
		yaml.drawsBackground = true
		yaml.backgroundColor = Theme.background
		yaml.textColor = Theme.text
		yaml.font = Theme.monoSmall
		yaml.textContainerInset = NSSize(width: 6, height: 6)
		yaml.isVerticallyResizable = true
		yaml.autoresizingMask = [.width]
		scroll.documentView = yaml
		scroll.translatesAutoresizingMaskIntoConstraints = false
		scroll.heightAnchor.constraint(equalToConstant: 150).isActive = true
		return scroll
	}

	/// Straight out of the emitter that writes the file, so what is shown here
	/// is what will be on disk — not a paraphrase of it.
	private func showWhatItWrites() {
		if overlayTable.selectedRow >= 0, overlayTable.selectedRow < project.overlays.count {
			yaml.string = ProjectWriter.fragment(for: project.overlays[overlayTable.selectedRow])
		} else if let path = selectedPath, let entry = project.entry(at: path) {
			yaml.string = ProjectWriter.fragment(for: entry)
		} else {
			yaml.string = ProjectWriter.fragment(for: project.output)
		}
	}

	// MARK: - Loading

	public func reload(_ project: Project) {
		// Not while something is being typed into: the document changes on every
		// commit and a reload mid-edit ends it.
		if window?.firstResponder is NSTextView, window?.firstResponder !== yaml,
		   timelineTable.editedRow >= 0 || overlayTable.editedRow >= 0 { return }

		self.project = project
		rows = project.rows

		width.stringValue = String(project.output.width)
		height.stringValue = String(project.output.height)
		fps.stringValue = TakeWriter.number(project.output.framesPerSecond, places: 3)
		target.stringValue = project.output.audio.map { TakeWriter.number($0.target, places: 1) } ?? ""
		ceiling.stringValue = project.output.audio.map { TakeWriter.number($0.ceiling, places: 1) } ?? ""
		reference.stringValue = project.output.matchReference ?? ""

		let timelineSelection = timelineTable.selectedRow
		let overlaySelection = overlayTable.selectedRow
		timelineTable.reloadData()
		overlayTable.reloadData()
		if timelineSelection >= 0, timelineSelection < rows.count {
			timelineTable.selectRowIndexes([timelineSelection], byExtendingSelection: false)
		}
		if overlaySelection >= 0, overlaySelection < project.overlays.count {
			overlayTable.selectRowIndexes([overlaySelection], byExtendingSelection: false)
		}
		showWhatItWrites()
	}

	// MARK: - Tables

	public func numberOfRows(in tableView: NSTableView) -> Int {
		tableView === timelineTable ? rows.count : project.overlays.count
	}

	public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
		guard let tableColumn else { return nil }
		let field = (tableView.makeView(withIdentifier: tableColumn.identifier, owner: self) as? NSTextField)
			?? {
				let field = NSTextField()
				field.identifier = tableColumn.identifier
				field.isBordered = false
				field.drawsBackground = false
				field.lineBreakMode = .byTruncatingTail
				field.font = Theme.mono
				return field
			}()
		field.target = self
		field.isEditable = true

		if tableView === timelineTable {
			guard row < rows.count else { return nil }
			let entry = rows[row]
			field.action = #selector(entryEdited(_:))
			if tableColumn.identifier.rawValue == "transition" {
				field.stringValue = entry.entry.transition == 0
					? "" : TakeWriter.number(entry.entry.transition, places: 2)
				field.placeholderString = "cut"
				field.textColor = Theme.dimText
				return field
			}
			// Indented by depth, so a section and its contents read as a tree
			// the way they do in the file.
			field.stringValue = String(repeating: "  ", count: entry.depth)
				+ entry.entry.source.description
			switch entry.entry.source {
			case .group: field.textColor = Theme.base(.violet)
			case .query: field.textColor = Theme.base(.amber)
			default: field.textColor = Theme.clipStroke(.green)
			}
			return field
		}

		guard row < project.overlays.count else { return nil }
		let overlay = project.overlays[row]
		field.action = #selector(overlayEdited(_:))
		switch tableColumn.identifier.rawValue {
		case "what":
			switch overlay.kind {
			case .text(let text, _):
				field.stringValue = text
				field.textColor = Theme.text
			case .spinner(let spinner):
				field.stringValue = spinner.words.map(\.text).joined(separator: ", ")
				field.placeholderString = "spinner — words, comma separated"
				field.textColor = Theme.base(.amber)
			}
		case "from", "to":
			field.textColor = Theme.dimText
			switch overlay.span {
			case .marks(let from, let to):
				field.stringValue = (tableColumn.identifier.rawValue == "from" ? from : to).description
			case .times(let from, let to):
				field.stringValue = Timecode.string(tableColumn.identifier.rawValue == "from" ? from : to)
			}
		default:
			break
		}
		return field
	}

	public func tableViewSelectionDidChange(_ notification: Notification) {
		guard let table = notification.object as? NSTableView else { return }
		// Selecting in one list clears the other, so "what this writes" has one
		// thing to be about.
		if table === timelineTable, overlayTable.selectedRow >= 0 { overlayTable.deselectAll(nil) }
		if table === overlayTable, timelineTable.selectedRow >= 0 { timelineTable.deselectAll(nil) }
		showWhatItWrites()
	}
}
