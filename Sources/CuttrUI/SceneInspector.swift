import AppKit
import CuttrCompose
import CuttrKit

/// The selected part: what it is, and every key that moves it.
///
/// Two halves, and the second one is the point. A key states some fields and
/// inherits the rest, and the difference between the two is the whole reason
/// the format reads the way it does — so a value somebody wrote is shown as a
/// value they wrote, and a value that came from the key before is shown dim,
/// in brackets, with the button beside it offering to make it real. Filling the
/// blanks in with the inherited numbers, which is what a form usually does,
/// would turn a two-line key into a nine-line one the first time anybody
/// touched it.
@MainActor
public final class SceneInspector: NSView {

	public var onContent: ((Scene.Part.Content) -> Void)?
	public var onChooseImage: (() -> Void)?
	public var onSelectKey: ((Int) -> Void)?
	public var onAddKey: (() -> Void)?
	public var onRemoveKey: ((Int) -> Void)?
	public var onKeyTime: ((Int, Double) -> Void)?
	public var onEase: ((Int, Scene.Ease) -> Void)?
	/// A field on a key, set or given back to the key before it.
	public var onField: ((Int, Scene.Field, Double?) -> Void)?
	public var onColor: ((Int, RGBA?) -> Void)?

	private var project = Project()
	private var scene = Scene()
	private var part: Int?
	private var key: Int?

	private let form = NSStackView()
	private let title = NSTextField(labelWithString: "")
	private static let keyWidth: CGFloat = 76

	final class Sink: NSObject {
		let run: (NSControl) -> Void
		init(_ run: @escaping (NSControl) -> Void) { self.run = run }
		@objc func fire(_ sender: NSControl) { run(sender) }
	}

	/// The closures the controls call. Held because a control's target is
	/// unowned, and a form rebuilt on every edit would otherwise be a form
	/// whose buttons all crash on the second click.
	private var sinks: [Sink] = []

	public override init(frame: NSRect) {
		super.init(frame: frame)
		wantsLayer = true
		layer?.backgroundColor = Theme.card.cgColor

		title.font = Theme.heading
		title.textColor = Theme.faintText

		form.orientation = .vertical
		form.alignment = .leading
		form.spacing = 6
		form.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 16, right: 12)
		form.setHuggingPriority(.required, for: .vertical)
		form.translatesAutoresizingMaskIntoConstraints = false

		let scroll = TableScroll.wrap(form, horizontal: false)
		// A clip view that counts from the top. Without it a form shorter than
		// the pane sits at the *bottom* of it, under a field of empty card —
		// which is what a scroll view does with an unflipped document view, and
		// which looks exactly like a panel that failed to lay out.
		scroll.contentView = FlippedClip()
		scroll.documentView = form
		scroll.translatesAutoresizingMaskIntoConstraints = false
		addSubview(scroll)
		title.translatesAutoresizingMaskIntoConstraints = false
		addSubview(title)
		NSLayoutConstraint.activate([
			title.topAnchor.constraint(equalTo: topAnchor, constant: 10),
			title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
			title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),

			scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
			scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
			scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
			scroll.trailingAnchor.constraint(equalTo: trailingAnchor),

			form.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
			form.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
		])
	}

	@available(*, unavailable) required init?(coder: NSCoder) { nil }

	// MARK: - Loading

	public func reload(_ scene: Scene, project: Project, part: Int?, key: Int?) {
		self.scene = scene
		self.project = project
		self.part = part
		self.key = key
		// Not while somebody is typing into it: every commit writes the file,
		// the file comes back, and a form rebuilt mid-word takes the cursor
		// with it. The same rule the properties panel keeps.
		if isEditing { return }
		rebuild()
	}

	private var isEditing: Bool {
		var view = window?.firstResponder as? NSView
		while let current = view {
			if current === self { return true }
			view = current.superview
		}
		return false
	}

	private func rebuild() {
		sinks.removeAll()
		for row in form.arrangedSubviews {
			form.removeArrangedSubview(row)
			row.removeFromSuperview()
		}

		guard let part, part < scene.parts.count else {
			title.stringValue = "NOTHING SELECTED"
			add(caption("Choose a part on the stage or in the list beside it."))
			return
		}
		let subject = scene.parts[part]
		title.stringValue = "PART \(part + 1) · \(name(of: subject.content))".uppercased()

		content(of: subject, at: part)
		section("keys")
		keys(of: subject)
	}

	private func name(of content: Scene.Part.Content) -> String {
		switch content {
		case .text: return "text"
		case .shape: return "shape"
		case .image: return "image"
		case .background: return "background"
		}
	}

	// MARK: - What the part is

	private func content(of subject: Scene.Part, at index: Int) {
		switch subject.content {
		case .text(let words, let style, let tracking):
			field("text", [text(words, width: 190, placeholder: "{{title}}") { [weak self] value in
				self?.onContent?(.text(value, style: style, tracking: tracking))
			}], note: "`{{name}}` is filled in by the overlay that uses this scene")
			field("style", [combo(style ?? "", values: styleNames, width: 150) { [weak self] value in
				let chosen = value.trimmingCharacters(in: .whitespaces)
				self?.onContent?(.text(words, style: chosen.isEmpty ? nil : chosen,
				                       tracking: tracking))
			}])
			field("tracking", [number(tracking, width: 66) { [weak self] value in
				self?.onContent?(.text(words, style: style, tracking: value))
			}], note: "space between the letters, as a fraction of the type size")

		case .shape(let fill, let corner):
			field("shape", [colour(fill) { [weak self] value in
				self?.onContent?(.shape(fill: value, corner: corner))
			}])
			field("corner", [number(corner, width: 66) { [weak self] value in
				self?.onContent?(.shape(fill: fill, corner: value))
			}], note: "rounding, as a fraction of the frame height")

		case .image(let file):
			field("image", [
				text(file, width: 150, placeholder: "logo.png") { [weak self] value in
					self?.onContent?(.image(value))
				},
				small("Choose…") { [weak self] in self?.onChooseImage?() },
			], note: "a file beside the project")

		case .background(let background):
			field("from", [colour(background.from) { [weak self] value in
				var next = background
				next.from = value
				self?.onContent?(.background(next))
			}])
			field("to", [
				colour(background.to ?? background.from) { [weak self] value in
					var next = background
					next.to = value
					self?.onContent?(.background(next))
				},
				check("ramp", on: background.to != nil) { [weak self] on in
					var next = background
					next.to = on ? (next.to ?? RGBA(r: next.from.r * 0.4, g: next.from.g * 0.4,
					                                b: next.from.b * 0.4, a: next.from.a)) : nil
					self?.onContent?(.background(next))
				},
			], note: "off for one flat colour")
			field("angle", [number(background.angle, width: 66) { [weak self] value in
				var next = background
				next.angle = value
				self?.onContent?(.background(next))
			}], note: "degrees; 90 runs up the frame, 0 across it")
		}
	}

	private var styleNames: [String] {
		Array(Set(TextStyle.offered + project.styles.keys)).sorted()
	}

	// MARK: - The keys

	private func keys(of subject: Scene.Part) {
		let fields = Scene.fields(for: subject.content)
		let filled = Scene.filled(subject.keys)

		for (index, key) in subject.keys.enumerated() {
			let chosen = index == self.key
			let time = number(key.t, width: 56) { [weak self] value in
				self?.onKeyTime?(index, value)
			}
			let ease = choice(Scene.Ease.allCases.map(\.rawValue),
			                  selected: Scene.Ease.allCases.firstIndex(of: key.ease) ?? 3,
			                  width: 86) { [weak self] picked in
				self?.onEase?(index, Scene.Ease.allCases[picked])
			}
			let says = stated(key, fields: fields)
			let summary = label(says.isEmpty ? "inherits everything" : says)
			let pick = small(chosen ? "●" : "○") { [weak self] in self?.onSelectKey?(index) }
			pick.toolTip = "Work on this key"
			let drop = small("−") { [weak self] in self?.onRemoveKey?(index) }
			drop.isEnabled = subject.keys.count > 1

			let row = NSStackView(views: [pick, time, ease, summary, NSView(), drop])
			row.orientation = .horizontal
			row.spacing = 5
			row.alignment = .centerY
			add(row)

			guard chosen else { continue }
			for field in fields {
				add(fieldRow(for: field, of: key, at: index,
				             inherited: filled.indices.contains(index) ? filled[index][field] : nil))
			}
			add(colourRow(key, at: index, inherited: filled.indices.contains(index)
				? filled[index].color : nil))
		}

		let addKey = small("Add a key at the playhead") { [weak self] in self?.onAddKey?() }
		let row = NSStackView(views: [addKey, NSView()])
		row.orientation = .horizontal
		add(row)
		add(caption("A key states only what changes. Everything else is what it was at the key "
			+ "before, which is why a part that only moves says its position twice and its "
			+ "opacity once."))
	}

	private func stated(_ key: Scene.Key, fields: [Scene.Field]) -> String {
		var said = fields.filter { key[$0] != nil }.map(\.rawValue)
		if key.color != nil { said.append("color") }
		return said.joined(separator: " ")
	}

	/// One field of one key: the number, and whether it is this key's or the
	/// one before it's.
	private func fieldRow(for field: Scene.Field, of key: Scene.Key, at index: Int,
	                      inherited: Double?) -> NSView {
		let name = NSTextField(labelWithString: field.rawValue)
		name.font = Theme.mono
		name.textColor = key[field] == nil ? Theme.faintText : Theme.text
		name.translatesAutoresizingMaskIntoConstraints = false
		let wide = name.widthAnchor.constraint(equalToConstant: Self.keyWidth)
		wide.priority = NSLayoutConstraint.Priority(900)
		wide.isActive = true

		let stated = key[field]
		let shown = stated ?? inherited ?? 0
		let box = text(TakeWriter.number(shown, places: 3), width: 66,
		               placeholder: "—") { [weak self] value in
			let cleaned = value.trimmingCharacters(in: .whitespaces)
				.replacingOccurrences(of: ",", with: ".")
			self?.onField?(index, field, cleaned.isEmpty ? nil : Double(cleaned))
		}
		// Dim and in brackets when it came from the key before. The number is
		// still there to be seen and still typeable — typing it is exactly how
		// somebody claims it — but it does not look like something they wrote.
		if stated == nil {
			box.textColor = Theme.faintText
			box.stringValue = "(\(TakeWriter.number(shown, places: 3)))"
		}

		let button = small(stated == nil ? "set" : "inherit") { [weak self] in
			self?.onField?(index, field, stated == nil ? shown : nil)
		}
		button.toolTip = stated == nil
			? "State this here, at what it already is"
			: "Take it back to whatever the key before says"

		let row = NSStackView(views: [name, box, button, NSView()])
		row.orientation = .horizontal
		row.spacing = 5
		row.alignment = .centerY
		row.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 0)
		return row
	}

	private func colourRow(_ key: Scene.Key, at index: Int, inherited: RGBA?) -> NSView {
		let name = NSTextField(labelWithString: "color")
		name.font = Theme.mono
		name.textColor = key.color == nil ? Theme.faintText : Theme.text
		name.translatesAutoresizingMaskIntoConstraints = false
		let wide = name.widthAnchor.constraint(equalToConstant: Self.keyWidth)
		wide.priority = NSLayoutConstraint.Priority(900)
		wide.isActive = true

		let shown = key.color ?? inherited
		let well = colour(shown ?? .white) { [weak self] value in
			self?.onColor?(index, value)
		}
		well.alphaValue = key.color == nil ? 0.45 : 1
		let button = small(key.color == nil ? "set" : "inherit") { [weak self] in
			self?.onColor?(index, key.color == nil ? (shown ?? .white) : nil)
		}
		let row = NSStackView(views: [name, well, button, NSView()])
		row.orientation = .horizontal
		row.spacing = 5
		row.alignment = .centerY
		row.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 0)
		return row
	}

	// MARK: - The furniture

	private func add(_ row: NSView) {
		form.addArrangedSubview(row)
		row.translatesAutoresizingMaskIntoConstraints = false
		row.widthAnchor.constraint(equalTo: form.widthAnchor, constant: -24).isActive = true
	}

	private func section(_ name: String) {
		let label = NSTextField(labelWithString: name.uppercased())
		label.font = Theme.heading
		label.textColor = Theme.faintText
		let row = NSStackView(views: [label, NSView()])
		row.orientation = .horizontal
		row.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 0, right: 0)
		add(row)
	}

	private func field(_ key: String, _ controls: [NSView], note: String? = nil) {
		let name = NSTextField(labelWithString: key)
		name.font = Theme.mono
		name.textColor = Theme.text
		name.lineBreakMode = .byTruncatingTail
		name.translatesAutoresizingMaskIntoConstraints = false
		let wide = name.widthAnchor.constraint(equalToConstant: Self.keyWidth)
		wide.priority = NSLayoutConstraint.Priority(900)
		wide.isActive = true
		name.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1),
		                                             for: .horizontal)

		let slack = NSView()
		slack.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
		slack.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1),
		                                              for: .horizontal)
		let row = NSStackView(views: [name] + controls + [slack])
		row.orientation = .horizontal
		row.spacing = 5
		row.alignment = .centerY
		add(row)
		if let note { add(caption(note)) }
	}

	private func caption(_ message: String) -> NSView {
		let label = WrappingLabel(labelWithString: message)
		label.font = Theme.monoSmall
		label.textColor = Theme.faintText
		label.lineBreakMode = .byWordWrapping
		label.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1),
		                                              for: .horizontal)
		let row = NSStackView(views: [label])
		row.orientation = .horizontal
		row.edgeInsets = NSEdgeInsets(top: 0, left: Self.keyWidth + 5, bottom: 3, right: 0)
		return row
	}

	private final class FlippedClip: NSClipView {
		override var isFlipped: Bool { true }
	}

	private final class WrappingLabel: NSTextField {
		override func layout() {
			if preferredMaxLayoutWidth != bounds.width {
				preferredMaxLayoutWidth = bounds.width
				invalidateIntrinsicContentSize()
			}
			super.layout()
		}
	}

	private func squeezable<T: NSView>(_ view: T) -> T {
		view.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1),
		                                             for: .horizontal)
		return view
	}

	private func label(_ text: String) -> NSTextField {
		let label = NSTextField(labelWithString: text)
		label.font = Theme.monoSmall
		label.textColor = Theme.dimText
		label.lineBreakMode = .byTruncatingTail
		return squeezable(label)
	}

	private func text(_ value: String, width: CGFloat, placeholder: String,
	                  onCommit: @escaping (String) -> Void) -> NSTextField {
		let field = NSTextField(string: value)
		field.font = Theme.mono
		field.placeholderString = placeholder
		field.usesSingleLineMode = true
		field.lineBreakMode = .byClipping
		field.translatesAutoresizingMaskIntoConstraints = false
		field.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1),
		                                              for: .horizontal)
		field.setContentHuggingPriority(NSLayoutConstraint.Priority(200), for: .horizontal)
		let wide = field.widthAnchor.constraint(equalToConstant: width)
		wide.priority = NSLayoutConstraint.Priority(400)
		wide.isActive = true
		field.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
		field.heightAnchor.constraint(equalToConstant: 22).isActive = true
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

	private func combo(_ value: String, values: [String], width: CGFloat,
	                   onCommit: @escaping (String) -> Void) -> NSComboBox {
		let box = NSComboBox()
		box.font = Theme.mono
		box.completes = true
		box.numberOfVisibleItems = 12
		box.addItems(withObjectValues: values)
		box.stringValue = value
		box.translatesAutoresizingMaskIntoConstraints = false
		box.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1),
		                                            for: .horizontal)
		box.setContentHuggingPriority(NSLayoutConstraint.Priority(200), for: .horizontal)
		let wide = box.widthAnchor.constraint(equalToConstant: width)
		wide.priority = NSLayoutConstraint.Priority(400)
		wide.isActive = true
		box.widthAnchor.constraint(greaterThanOrEqualToConstant: 60).isActive = true
		box.heightAnchor.constraint(equalToConstant: 22).isActive = true
		let sink = Sink { control in onCommit(control.stringValue) }
		sinks.append(sink)
		box.target = sink
		box.action = #selector(Sink.fire(_:))
		return box
	}

	private func choice(_ titles: [String], selected: Int, width: CGFloat,
	                    onPick: @escaping (Int) -> Void) -> NSPopUpButton {
		let button = NSPopUpButton()
		button.addItems(withTitles: titles)
		button.selectItem(at: min(max(0, selected), max(titles.count - 1, 0)))
		button.font = Theme.mono
		button.controlSize = .small
		button.translatesAutoresizingMaskIntoConstraints = false
		let wide = button.widthAnchor.constraint(equalToConstant: width)
		wide.priority = NSLayoutConstraint.Priority(400)
		wide.isActive = true
		let sink = Sink { control in
			onPick((control as? NSPopUpButton)?.indexOfSelectedItem ?? 0)
		}
		sinks.append(sink)
		button.target = sink
		button.action = #selector(Sink.fire(_:))
		return squeezable(button)
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
		return squeezable(button)
	}

	private func small(_ title: String, onTap: @escaping () -> Void) -> NSButton {
		let button = NSButton()
		button.title = title
		button.bezelStyle = .rounded
		button.controlSize = .small
		button.font = NSFont.systemFont(ofSize: 11)
		// Wide enough to still be a button. Everything in this form gives up
		// width before the pane does, and a one-character button that does so
		// disappears entirely — which is what happened to the mark saying
		// which key is being worked on.
		button.translatesAutoresizingMaskIntoConstraints = false
		button.widthAnchor.constraint(greaterThanOrEqualToConstant: 26).isActive = true
		let sink = Sink { _ in onTap() }
		sinks.append(sink)
		button.target = sink
		button.action = #selector(Sink.fire(_:))
		return squeezable(button)
	}

	private func colour(_ value: RGBA, onPick: @escaping (RGBA) -> Void) -> NSColorWell {
		let well = NSColorWell()
		well.color = NSColor(calibratedRed: value.r, green: value.g, blue: value.b, alpha: value.a)
		well.translatesAutoresizingMaskIntoConstraints = false
		well.widthAnchor.constraint(equalToConstant: 42).isActive = true
		well.heightAnchor.constraint(equalToConstant: 20).isActive = true
		let sink = Sink { control in
			guard let colour = (control as? NSColorWell)?.color
				.usingColorSpace(.genericRGB) else { return }
			onPick(RGBA(r: Double(colour.redComponent), g: Double(colour.greenComponent),
			            b: Double(colour.blueComponent), a: Double(colour.alphaComponent)))
		}
		sinks.append(sink)
		well.target = sink
		well.action = #selector(Sink.fire(_:))
		return squeezable(well)
	}
}
