import AppKit
import CuttrCompose
import CuttrKit

/// Everything about the one thing that is selected.
///
/// The panel that means somebody never has to open the file. A caption's style,
/// how it arrives, how far above a face it sits, how long a spinner's third
/// word stays — all of it is in the format, so all of it is here, labelled with
/// the key it writes. Nothing is only reachable by typing YAML.
///
/// Rebuilt on each change of selection rather than shown and hidden. A form
/// whose rows are all present and mostly invisible is a form that eventually
/// shows the wrong ones, and this way what is on screen is exactly what the
/// selection has.
@MainActor
public final class PropertiesPanel: NSView {

	public var onChange: ((Project) -> Void)?

	private var project = Project()
	private var vocabulary = ComposeDocument.Vocabulary()
	private var selection: ProjectSelection = .output
	private var built: ProjectSelection?

	private let form = NSStackView()
	private let title = NSTextField(labelWithString: "")
	/// The closures the controls call. Held because a target is unowned.
	private var sinks: [Sink] = []

	final class Sink: NSObject {
		let run: (NSControl) -> Void
		init(_ run: @escaping (NSControl) -> Void) { self.run = run }
		@objc func fire(_ sender: NSControl) { run(sender) }
	}

	public override init(frame: NSRect) {
		super.init(frame: frame)
		wantsLayer = true
		layer?.backgroundColor = Theme.panel.cgColor

		title.font = Theme.heading
		title.textColor = Theme.faintText

		form.orientation = .vertical
		form.spacing = 8
		form.alignment = .leading
		form.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 8, right: 0)

		let stack = NSStackView(views: [title, form])
		stack.orientation = .vertical
		stack.spacing = 8
		stack.alignment = .leading
		stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)

		let scroll = TableScroll.wrap(stack, horizontal: false)
		scroll.translatesAutoresizingMaskIntoConstraints = false
		addSubview(scroll)
		NSLayoutConstraint.activate([
			scroll.topAnchor.constraint(equalTo: topAnchor),
			scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
			scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
			scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
			stack.widthAnchor.constraint(equalTo: scroll.widthAnchor),
		])
	}

	@available(*, unavailable) required init?(coder: NSCoder) { nil }

	// MARK: - Loading

	public func reload(_ project: Project, vocabulary: ComposeDocument.Vocabulary,
	                   selection: ProjectSelection) {
		self.project = project
		self.vocabulary = vocabulary
		self.selection = selection
		// Not while something is being typed into: every commit writes the file
		// and the file comes back, and rebuilding the form mid-word would take
		// the cursor with it.
		if built == selection, isEditing { return }
		rebuild()
	}

	private var isEditing: Bool {
		guard let responder = window?.firstResponder as? NSView else { return false }
		var view: NSView? = responder
		while let current = view {
			if current === self { return true }
			view = current.superview
		}
		return false
	}

	private func rebuild() {
		sinks.removeAll()
		for view in form.arrangedSubviews { form.removeArrangedSubview(view); view.removeFromSuperview() }
		built = selection

		switch selection {
		case .output:
			title.stringValue = "OUTPUT"
			outputForm()
		case .entry(let path):
			guard let entry = project.entry(at: path) else {
				title.stringValue = "PROJECT"
				return
			}
			title.stringValue = "TIMELINE ENTRY"
			entryForm(path, entry)
		case .overlay(let index):
			guard index < project.overlays.count else {
				title.stringValue = "PROJECT"
				return
			}
			title.stringValue = "OVERLAY"
			overlayForm(index, project.overlays[index])
		}
	}

	// MARK: - output

	private func outputForm() {
		let width = number(project.output.width, width: 70) { [weak self] value in
			self?.editOutput { $0.width = max(2, Int(value)) }
		}
		let height = number(project.output.height, width: 70) { [weak self] value in
			self?.editOutput { $0.height = max(2, Int(value)) }
		}
		add(row("size", [width, label("×"), height, presets()]),
		    note: "the frame everything is fitted into")
		add(row("fps", [number(project.output.framesPerSecond, width: 70) { [weak self] value in
			self?.editOutput { $0.framesPerSecond = max(1, value) }
		}]))
		add(row("file", [text(project.output.file ?? "", width: 220, placeholder: "programme.mov") {
			[weak self] value in
			self?.editOutput { $0.file = value.isEmpty ? nil : value }
		}]), note: "where a render goes, beside the project")

		add(heading("audio"))
		let levelled = check("level the programme", on: project.output.audio != nil) {
			[weak self] on in
			self?.editOutput { $0.audio = on ? AudioTarget() : nil }
		}
		add(row("", [levelled]))
		if let audio = project.output.audio {
			add(row("audio.target", [
				number(audio.target, width: 70) { [weak self] value in
					self?.editOutput { $0.audio?.target = value }
				}, label("LUFS"),
				label("ceiling"),
				number(audio.ceiling, width: 70) { [weak self] value in
					self?.editOutput { $0.audio?.ceiling = value }
				}, label("dBTP"),
			]), note: "−16 is the web's convention, −23 the broadcaster's")
		}

		add(heading("grade"))
		add(row("match.reference", [combo(project.output.matchReference ?? "",
		                                  values: [""] + vocabulary.clips, width: 200) {
			[weak self] value in
			self?.editOutput { $0.matchReference = value.isEmpty ? nil : Slug.make(from: value) }
		}]), note: "every other clip is graded to look like this one")
	}

	/// The three sizes almost every project is, without typing four digits.
	private func presets() -> NSPopUpButton {
		let sizes = [("1080p", 1920, 1080), ("4K", 3840, 2160), ("720p", 1280, 720),
		             ("vertical", 1080, 1920), ("square", 1080, 1080)]
		let button = pop(["preset"] + sizes.map(\.0), selected: 0) { [weak self] index in
			guard index > 0 else { return }
			let size = sizes[index - 1]
			self?.editOutput { $0.width = size.1; $0.height = size.2 }
		}
		button.toolTip = "A size to start from"
		return button
	}

	private func editOutput(_ change: (inout Output) -> Void) {
		var next = project
		change(&next.output)
		onChange?(next)
	}

	// MARK: - timeline entry

	private func entryForm(_ path: [Int], _ entry: TimelineEntry) {
		let kinds = ["clip", "list", "query", "section"]
		let current: Int
		switch entry.source {
		case .clip: current = 0
		case .list: current = 1
		case .query: current = 2
		case .group: current = 3
		}
		add(row("kind", [pop(kinds, selected: current) { [weak self] index in
			self?.changeKind(path, entry, to: index)
		}]))

		switch entry.source {
		case .clip(let reference):
			add(row("clip", [combo(reference.description,
			                       values: vocabulary.items.map(\.reference), width: 220) {
				[weak self] value in
				self?.replace(path, TimelineEntry(clip: ClipReference(value),
				                                  transition: entry.transition))
			}]), note: "a slug, or take/slug when two takes share one")

		case .list(let references):
			add(row("list", [text(references.map(\.description).joined(separator: ", "),
			                      width: 260, placeholder: "intro, demo, outro") {
				[weak self] value in
				let parts = value.split(separator: ",")
					.map { ClipReference($0.trimmingCharacters(in: .whitespaces)) }
					.filter { !$0.slug.isEmpty }
				self?.replace(path, TimelineEntry(list: parts, transition: entry.transition))
			}]), note: "in the order written")

		case .query(_, let source):
			let field = combo(source, values: vocabulary.tags.map { "#\($0)" } + ["*"], width: 260) {
				[weak self] value in
				guard let self else { return }
				guard let replacement = try? TimelineEntry(query: value, transition: entry.transition)
				else {
					self.rebuild()   // unreadable: put it back
					return
				}
				self.replace(path, replacement)
			}
			add(row("query", [field]),
			    note: "#tag, take/#tag, take/*, and `and` `or` `not` between them")
			let count = (try? QueryParser.parse(source)).map { _ in
				vocabulary.items.filter { item in
					source.split(separator: " ").contains { part in
						part.hasPrefix("#") && item.tags.contains(String(part.dropFirst()))
					}
				}.count
			}
			if let count, count > 0 { add(caption("\(count) clip\(count == 1 ? "" : "s") carry those tags")) }

		case .group(let name, let inner):
			add(row("section", [text(name, width: 220, placeholder: "introduction") {
				[weak self] value in
				self?.replace(path, TimelineEntry(group: Slug.make(from: value), entries: inner,
				                                  transition: entry.transition))
			}]), note: "overlays can be hung on @\(name.isEmpty ? "name" : name)")
			add(caption("\(inner.count) entr\(inner.count == 1 ? "y" : "ies") inside"))
		}

		add(heading("transition"))
		add(row("transition", [number(entry.transition, width: 70) { [weak self] value in
			self?.replace(path, TimelineEntry(source: entry.source, transition: max(0, value)))
		}, label("seconds")]), note: "0 cuts; anything else dissolves in from the entry before")
	}

	private func changeKind(_ path: [Int], _ entry: TimelineEntry, to index: Int) {
		let name = entry.source.description
		let replacement: TimelineEntry
		switch index {
		case 0: replacement = TimelineEntry(clip: ClipReference(name), transition: entry.transition)
		case 1: replacement = TimelineEntry(list: [ClipReference(name)], transition: entry.transition)
		case 2: replacement = (try? TimelineEntry(query: "#\(Slug.make(from: name))",
		                                          transition: entry.transition))
			?? entry
		default:
			if case .group = entry.source { return }
			replacement = TimelineEntry(group: Slug.make(from: name), entries: [],
			                            transition: entry.transition)
		}
		replace(path, replacement)
	}

	private func replace(_ path: [Int], _ entry: TimelineEntry) {
		var next = project
		next.replaceEntry(at: path, with: entry)
		onChange?(next)
	}

	// MARK: - overlay

	private func overlayForm(_ index: Int, _ overlay: Overlay) {
		let isText: Bool
		if case .text = overlay.kind { isText = true } else { isText = false }
		add(row("kind", [pop(["text", "spinner"], selected: isText ? 0 : 1) { [weak self] pick in
			self?.editOverlay(index) { overlay in
				switch (pick, overlay.kind) {
				case (0, .spinner(let spinner)):
					overlay.kind = .text(spinner.words.first?.text ?? "Caption", style: nil)
				case (1, .text(let text, _)):
					overlay.kind = .spinner(Spinner(words: text.isEmpty ? [] : [SpinnerWord(text)]))
				default: break
				}
			}
		}]))

		switch overlay.kind {
		case .text(let content, let style):
			add(row("text", [text(content, width: 260, placeholder: "what it says") {
				[weak self] value in
				self?.editOverlay(index) { $0.kind = .text(value, style: style) }
			}]))
			add(row("style", [pop(styleNames, selected: styleNames.firstIndex(of: style ?? "lower-third") ?? 0) {
				[weak self] pick in
				guard let self else { return }
				self.editOverlay(index) { $0.kind = .text(content, style: self.styleNames[pick]) }
			}]), note: "defined under `styles:`, or one of the built-in four")

		case .spinner(let spinner):
			add(row("style", [pop(Spinner.Style.allCases.map(\.rawValue),
			                      selected: Spinner.Style.allCases.firstIndex(of: spinner.style) ?? 0) {
				[weak self] pick in
				self?.editSpinner(index) { $0.style = Spinner.Style.allCases[pick] }
			}]))
			add(row("size", [number(spinner.size, width: 70) { [weak self] value in
				self?.editSpinner(index) { $0.size = max(0.01, value) }
			}, label("of frame height"),
			label("speed"),
			number(spinner.speed, width: 70) { [weak self] value in
				self?.editSpinner(index) { $0.speed = value }
			}, label("turns/s")]))
			add(row("color", [colour(spinner.color) { [weak self] rgba in
				self?.editSpinner(index) { $0.color = rgba }
			}]))

			add(heading("words"))
			for (position, word) in spinner.words.enumerated() {
				add(row("", [
					text(word.text, width: 180, placeholder: "what it says now") { [weak self] value in
						self?.editSpinner(index) { $0.words[position].text = value }
					},
					text(word.duration.map { TakeWriter.number($0, places: 2) } ?? "",
					     width: 60, placeholder: "auto") { [weak self] value in
						self?.editSpinner(index) { $0.words[position].duration = Double(value) }
					},
					label("s"),
					small("−") { [weak self] in
						self?.editSpinner(index) { $0.words.remove(at: position) }
					},
				]))
			}
			add(row("", [small("+ word") { [weak self] in
				self?.editSpinner(index) { $0.words.append(SpinnerWord("")) }
			}]), note: "they cycle for as long as the overlay is on screen")
		}

		add(heading("when"))
		let byMarks: Bool
		if case .marks = overlay.span { byMarks = true } else { byMarks = false }
		add(row("span", [pop(["clips and sections", "times"], selected: byMarks ? 0 : 1) {
			[weak self] pick in
			self?.editOverlay(index) { overlay in
				switch (pick, overlay.span) {
				case (0, .times):
					overlay.span = .clips(from: ClipReference("clip"), to: ClipReference("clip"))
				case (1, .marks):
					overlay.span = .times(from: 0, to: 5)
				default: break
				}
			}
		}]), note: "bound to clips it survives a re-cut; bound to times it does not")

		switch overlay.span {
		case .marks(let from, let to):
			let endpoints = vocabulary.items.map(\.reference) + vocabulary.groups.map { "@\($0)" }
			add(row("from", [combo(from.description, values: endpoints, width: 220) {
				[weak self] value in
				self?.editOverlay(index) { $0.span = .marks(from: .init(value), to: to) }
			}]))
			add(row("to", [combo(to.description, values: endpoints, width: 220) {
				[weak self] value in
				self?.editOverlay(index) { $0.span = .marks(from: from, to: .init(value)) }
			}]), note: "the same mark twice is one clip, or one whole section")
		case .times(let from, let to):
			add(row("from", [text(Timecode.string(from), width: 110, placeholder: "00:00.000") {
				[weak self] value in
				guard let seconds = Timecode.parse(value) else { return }
				self?.editOverlay(index) { $0.span = .times(from: seconds, to: to) }
			}]))
			add(row("to", [text(Timecode.string(to), width: 110, placeholder: "00:05.000") {
				[weak self] value in
				guard let seconds = Timecode.parse(value) else { return }
				self?.editOverlay(index) { $0.span = .times(from: from, to: seconds) }
			}]))
		}

		add(heading("how it arrives and leaves"))
		transitionRows("arrival", overlay.arrival) { [weak self] transition in
			self?.editOverlay(index) { $0.arrival = transition }
		}
		transitionRows("departure", overlay.departure) { [weak self] transition in
			self?.editOverlay(index) { $0.departure = transition }
		}

		add(heading("where it sits"))
		add(row("anchor", [combo(overlay.anchor ?? "", values: [""] + vocabulary.anchors, width: 200) {
			[weak self] value in
			let name = value.trimmingCharacters(in: .whitespaces)
			self?.editOverlay(index) { $0.anchor = name.isEmpty ? nil : Slug.make(from: name) }
		}]), note: "a tracked face: the overlay follows it, and the style's position is ignored")
		add(row("offset", [
			number(overlay.offset.x, width: 70) { [weak self] value in
				self?.editOverlay(index) { $0.offset.x = value }
			},
			number(overlay.offset.y, width: 70) { [weak self] value in
				self?.editOverlay(index) { $0.offset.y = value }
			},
		]), note: "x and y from the anchor, both in fractions of the frame height")
	}

	private var styleNames: [String] {
		Array(Set(project.styles.keys).union(TextStyle.builtIn.keys)).sorted()
	}

	private func transitionRows(_ name: String, _ transition: Overlay.Transition,
	                            _ set: @escaping (Overlay.Transition) -> Void) {
		let kinds = ["cut", "fade", "slide"]
		let current: Int
		switch transition {
		case .cut: current = 0
		case .fade: current = 1
		case .slide: current = 2
		}
		var controls: [NSView] = [pop(kinds, selected: current) { pick in
			switch pick {
			case 0: set(.cut)
			case 1: set(.fade(over: max(0.1, transition.duration)))
			default: set(.slide(.left, over: max(0.1, transition.duration)))
			}
		}]
		if case .slide(let edge, let over) = transition {
			controls.append(pop(Overlay.Transition.Edge.allCases.map(\.rawValue),
			                    selected: Overlay.Transition.Edge.allCases.firstIndex(of: edge) ?? 0) {
				pick in set(.slide(Overlay.Transition.Edge.allCases[pick], over: over))
			})
		}
		if transition.duration > 0 || current != 0 {
			controls.append(number(transition.duration, width: 60) { value in
				switch transition {
				case .fade: set(.fade(over: max(0, value)))
				case .slide(let edge, _): set(.slide(edge, over: max(0, value)))
				case .cut: break
				}
			})
			controls.append(label("seconds"))
		}
		add(row(name, controls))
	}

	private func editOverlay(_ index: Int, _ change: (inout Overlay) -> Void) {
		var next = project
		guard index < next.overlays.count else { return }
		change(&next.overlays[index])
		onChange?(next)
	}

	private func editSpinner(_ index: Int, _ change: (inout Spinner) -> Void) {
		editOverlay(index) { overlay in
			guard case .spinner(var spinner) = overlay.kind else { return }
			change(&spinner)
			overlay.kind = .spinner(spinner)
		}
	}

	// MARK: - Controls

	private func add(_ view: NSView, note: String? = nil) {
		form.addArrangedSubview(view)
		if let note { form.addArrangedSubview(caption(note)) }
	}

	private func heading(_ text: String) -> NSView {
		let label = NSTextField(labelWithString: text.uppercased())
		label.font = Theme.heading
		label.textColor = Theme.faintText
		let stack = NSStackView(views: [label])
		stack.orientation = .vertical
		stack.edgeInsets = NSEdgeInsets(top: 10, left: 0, bottom: 0, right: 0)
		return stack
	}

	/// A labelled line. The label is the **key it writes**, not a paraphrase of
	/// it, so somebody who reads the file afterwards recognises what they set.
	private func row(_ key: String, _ controls: [NSView]) -> NSView {
		let name = NSTextField(labelWithString: key)
		name.font = Theme.mono
		name.textColor = key.isEmpty ? Theme.dimText : Theme.text
		name.alignment = .right
		name.translatesAutoresizingMaskIntoConstraints = false
		name.widthAnchor.constraint(equalToConstant: 96).isActive = true
		name.setContentCompressionResistancePriority(.required, for: .horizontal)

		let stack = NSStackView(views: [name] + controls)
		stack.orientation = .horizontal
		stack.spacing = 6
		stack.alignment = .firstBaseline
		return stack
	}

	private func caption(_ message: String) -> NSTextField {
		let label = NSTextField(labelWithString: message)
		label.font = Theme.monoSmall
		label.textColor = Theme.faintText
		label.lineBreakMode = .byWordWrapping
		label.preferredMaxLayoutWidth = 320
		return label
	}

	private func label(_ text: String) -> NSTextField {
		let label = NSTextField(labelWithString: text)
		label.font = Theme.monoSmall
		label.textColor = Theme.dimText
		return label
	}

	private func text(_ value: String, width: CGFloat, placeholder: String,
	                  onCommit: @escaping (String) -> Void) -> NSTextField {
		let field = NSTextField(string: value)
		field.font = Theme.mono
		field.placeholderString = placeholder
		field.translatesAutoresizingMaskIntoConstraints = false
		field.widthAnchor.constraint(equalToConstant: width).isActive = true
		let sink = Sink { control in onCommit(control.stringValue) }
		sinks.append(sink)
		field.target = sink
		field.action = #selector(Sink.fire(_:))
		return field
	}

	private func number(_ value: Double, width: CGFloat,
	                    onCommit: @escaping (Double) -> Void) -> NSTextField {
		text(TakeWriter.number(value, places: 3), width: width, placeholder: "0") { string in
			guard let parsed = Double(string.replacingOccurrences(of: ",", with: ".")) else { return }
			onCommit(parsed)
		}
	}

	private func number(_ value: Int, width: CGFloat,
	                    onCommit: @escaping (Double) -> Void) -> NSTextField {
		text(String(value), width: width, placeholder: "0") { string in
			guard let parsed = Double(string) else { return }
			onCommit(parsed)
		}
	}

	/// A field that offers the names that exist and still takes anything.
	///
	/// Both halves are needed: `from:` wants one of the clips that are actually
	/// there, and a query wants `#b-roll and not #reject`, which no menu can
	/// hold. Picking is for the common case, typing is for the rest.
	private func combo(_ value: String, values: [String], width: CGFloat,
	                   onCommit: @escaping (String) -> Void) -> NSComboBox {
		let box = NSComboBox()
		box.font = Theme.mono
		box.completes = true
		box.numberOfVisibleItems = 14
		box.addItems(withObjectValues: values)
		box.stringValue = value
		box.translatesAutoresizingMaskIntoConstraints = false
		box.widthAnchor.constraint(equalToConstant: width).isActive = true
		let sink = Sink { control in onCommit(control.stringValue) }
		sinks.append(sink)
		box.target = sink
		box.action = #selector(Sink.fire(_:))
		return box
	}

	private func pop(_ titles: [String], selected: Int,
	                 onPick: @escaping (Int) -> Void) -> NSPopUpButton {
		let button = NSPopUpButton()
		button.addItems(withTitles: titles)
		button.selectItem(at: min(max(0, selected), titles.count - 1))
		button.font = Theme.body
		button.controlSize = .small
		let sink = Sink { control in
			onPick((control as? NSPopUpButton)?.indexOfSelectedItem ?? 0)
		}
		sinks.append(sink)
		button.target = sink
		button.action = #selector(Sink.fire(_:))
		return button
	}

	private func check(_ title: String, on: Bool,
	                   onToggle: @escaping (Bool) -> Void) -> NSButton {
		let button = NSButton(checkboxWithTitle: title, target: nil, action: nil)
		button.state = on ? .on : .off
		button.font = Theme.body
		let sink = Sink { control in onToggle((control as? NSButton)?.state == .on) }
		sinks.append(sink)
		button.target = sink
		button.action = #selector(Sink.fire(_:))
		return button
	}

	private func small(_ title: String, onTap: @escaping () -> Void) -> NSButton {
		let button = NSButton()
		button.title = title
		button.bezelStyle = .rounded
		button.controlSize = .small
		button.font = NSFont.systemFont(ofSize: 11)
		let sink = Sink { _ in onTap() }
		sinks.append(sink)
		button.target = sink
		button.action = #selector(Sink.fire(_:))
		return button
	}

	/// A colour well, because a hex code is a thing to look up and a colour is a
	/// thing to see. What it writes is still `#rrggbb`.
	private func colour(_ value: RGBA, onPick: @escaping (RGBA) -> Void) -> NSColorWell {
		let well = NSColorWell()
		well.color = NSColor(calibratedRed: value.r, green: value.g, blue: value.b, alpha: value.a)
		well.translatesAutoresizingMaskIntoConstraints = false
		well.widthAnchor.constraint(equalToConstant: 44).isActive = true
		well.heightAnchor.constraint(equalToConstant: 22).isActive = true
		let sink = Sink { control in
			guard let colour = (control as? NSColorWell)?.color
				.usingColorSpace(.genericRGB) else { return }
			onPick(RGBA(r: Double(colour.redComponent), g: Double(colour.greenComponent),
			            b: Double(colour.blueComponent), a: Double(colour.alphaComponent)))
		}
		sinks.append(sink)
		well.target = sink
		well.action = #selector(Sink.fire(_:))
		return well
	}
}
