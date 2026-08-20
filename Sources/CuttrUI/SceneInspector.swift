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
	/// A key names a shape kind, or gives it back to the key before.
	public var onShape: ((Int, Scene.ShapeKind?) -> Void)?
	/// A key states the far stop of a background's ramp, or gives it back to
	/// the key before.
	public var onSecondStop: ((Int, RGBA?) -> Void)?

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
		helps.removeAll()
		help = nil
		explaining = nil
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

		section("the part")
		content(of: subject, at: part)
		section("keys")
		// Printed, where every other word of explanation in here is behind the
		// `?`. This is not an explanation of a field — it is what the two groups
		// above and below are *to each other*, and somebody who has to infer
		// that reads the values at the top as global settings the keys ought to
		// obey. A background's `from` and `to` looked exactly like that.
		remark("A key states only what changes at it. Everything it does not say "
			+ "is what it was at the key before — and before the first key, what "
			+ "the part says above.")
		keys(of: subject)
	}

	private func name(of content: Scene.Part.Content) -> String {
		switch content {
		case .text: return "text"
		case .shape(_, _, let kind): return kind.rawValue
		case .image: return "image"
		case .bar: return "bar"
		case .spinner: return "spinner"
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

		case .shape(let fill, let corner, let kind):
			field("shape", [colour(fill) { [weak self] value in
				self?.onContent?(.shape(fill: value, corner: corner, kind: kind))
			}])
			let kinds = Scene.ShapeKind.allCases
			field("kind", [choice(kinds.map(\.rawValue),
			                      selected: kinds.firstIndex(of: kind) ?? 0,
			                      width: 118) { [weak self] picked in
				self?.onContent?(.shape(fill: fill, corner: corner, kind: kinds[picked]))
			}], note: "what it is the shape of. Say a different one on a key and it "
				+ "morphs into that one over the interval ending there.")
			field("corner", [number(corner, width: 66) { [weak self] value in
				self?.onContent?(.shape(fill: fill, corner: value, kind: kind))
			}], note: "rounding, as a fraction of the frame height")

		case .bar(let bar):
			field("fill", [colour(bar.fill) { [weak self] value in
				var next = bar
				next.fill = value
				self?.onContent?(.bar(next))
			}])
			field("track", [
				colour(bar.track) { [weak self] value in
					var next = bar
					next.track = value
					self?.onContent?(.bar(next))
				},
				check("groove", on: bar.track.a > 0) { [weak self] on in
					var next = bar
					next.track.a = on ? max(next.track.a, 0.2) : 0
					self?.onContent?(.bar(next))
				},
			], note: "off for a line that grows with nothing behind it")
			field("corner", [number(bar.corner, width: 66) { [weak self] value in
				var next = bar
				next.corner = value
				self?.onContent?(.bar(next))
			}], note: "half the bar's own thickness makes the usual pill")
			let ways = Scene.Bar.Direction.allCases
			field("direction", [choice(ways.map(\.rawValue),
			                           selected: ways.firstIndex(of: bar.direction) ?? 0,
			                           width: 100) { [weak self] picked in
				var next = bar
				next.direction = ways[picked]
				self?.onContent?(.bar(next))
			}], note: "how full it is is `progress` on a key, below")

		case .spinner(let spinner):
			let styles = Spinner.Style.allCases
			field("spinner", [choice(styles.map(\.rawValue),
			                         selected: styles.firstIndex(of: spinner.style) ?? 0,
			                         width: 118) { [weak self] picked in
				var next = spinner
				next.style = styles[picked]
				self?.onContent?(.spinner(next))
			}], note: "with `progress` on a key it stops going round and fills up instead")
			field("size", [number(spinner.size, width: 66) { [weak self] value in
				var next = spinner
				next.size = value
				self?.onContent?(.spinner(next))
			}], note: "diameter, as a fraction of the frame height")
			field("speed", [number(spinner.speed, width: 66) { [weak self] value in
				var next = spinner
				next.speed = value
				self?.onContent?(.spinner(next))
			}], note: "turns a second")
			field("color", [colour(spinner.color) { [weak self] value in
				var next = spinner
				next.color = value
				self?.onContent?(.spinner(next))
			}])

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
			}], note: "the near stop of the ramp, before any key says otherwise. A key "
				+ "states this one as `color`.")
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
			], note: "the far stop. Off for one flat colour — which is a ramp whose two "
				+ "stops are the same, and is why a key can ramp a flat background into "
				+ "a gradient.")
			field("angle", [number(background.angle, width: 66) { [weak self] value in
				var next = background
				next.angle = value
				self?.onContent?(.background(next))
			}], note: "degrees; 90 runs up the frame, 0 across it. A key can state this "
				+ "too, and between two keys it turns the short way round.")
		}
	}

	private var styleNames: [String] {
		Array(Set(TextStyle.offered + project.styles.keys)).sorted()
	}

	// MARK: - The keys

	private func keys(of subject: Scene.Part) {
		let fields = Scene.fields(for: subject.content)
		let filled = Scene.filled(subject.keys)
		explainTheKeyRows(of: subject.content, fields: fields)

		for (index, key) in subject.keys.enumerated() {
			let chosen = index == self.key
			let time = number(key.t, width: 56) { [weak self] value in
				self?.onKeyTime?(index, value)
			}
			time.toolTip = note("t")
			let ease = choice(Scene.Ease.allCases.map(\.rawValue),
			                  selected: Scene.Ease.allCases.firstIndex(of: key.ease) ?? 3,
			                  width: 86) { [weak self] picked in
				self?.onEase?(index, Scene.Ease.allCases[picked])
			}
			ease.toolTip = note("ease")
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
			// The angle is held back to the end so that the three words a
			// background's gradient is made of come out in the order the part
			// declares them and the file writes them: `color`, `to`, `angle`.
			for field in fields where field != .angle {
				add(fieldRow(for: field, of: key, at: index,
				             inherited: filled.indices.contains(index) ? filled[index][field] : nil))
			}
			if Scene.morphs(subject.content) {
				add(shapeRow(key, of: subject, at: index,
				             inherited: filled.indices.contains(index)
				             	? filled[index].shape : nil))
			}
			add(colourRow(key, at: index, inherited: filled.indices.contains(index)
				? filled[index].color : nil))
			if case .background = subject.content {
				add(secondStopRow(key, at: index, inherited: filled.indices.contains(index)
					? filled[index].to : nil))
			}
			if fields.contains(.angle) {
				add(fieldRow(for: .angle, of: key, at: index,
				             inherited: filled.indices.contains(index)
				             	? filled[index].angle : nil))
			}
		}

		let addKey = small("Add a key at the playhead") { [weak self] in self?.onAddKey?() }
		let row = NSStackView(views: [addKey, NSView()])
		row.orientation = .horizontal
		add(row)
	}

	/// What the rows under a key mean, filed under the `keys` heading.
	///
	/// The rows themselves are built by hand rather than by ``field(_:_:note:)``
	/// — a key's row is a value, a `set`/`inherit` button and a bracket around
	/// whichever of the two it is — so the words they would have carried are
	/// registered here instead, and come out of the same `?`.
	private func explainTheKeyRows(of content: Scene.Part.Content, fields: [Scene.Field]) {
		explains("t", "when this key is, in seconds from the start of the scene")
		explains("ease", "how it gets here from the key before")
		for field in fields {
			switch field {
			case .x, .y:
				explains(field.rawValue, "where the middle of the part sits, as a fraction "
					+ "of the frame from the bottom left")
			case .opacity: explains("opacity", "nought to one")
			case .scale: explains("scale", "1 is the size the part is drawn at")
			case .rotation: explains("rotation", "degrees, anticlockwise")
			case .width, .height:
				explains(field.rawValue, "as a fraction of the frame")
			case .progress: explains("progress", "how far it has got, nought to one")
			case .angle:
				explains("angle", "which way the ramp runs here. Between two keys it turns "
					+ "the short way round, so 350 and 10 are twenty degrees apart — which "
					+ "means a whole turn is written as the keys it turns through, not as 0 "
					+ "and 360.")
			}
		}
		if Scene.morphs(content) {
			explains("shape", "what it is the shape of here. A different one from the key "
				+ "before morphs into it over the interval ending here.")
		}
		switch content {
		case .background:
			explains("color", "the near stop of the ramp here: the part's `from`, moved.")
			explains("to", "the far stop here. State it equal to `color` for a flat colour, "
				+ "and a background ramps out of one gradient and into another.")
		default:
			explains("color", "the part's colour here, if it is not the one the part was "
				+ "declared with")
		}
	}

	/// What was said about a row this form builds by hand, so the row can carry
	/// it as its tooltip as well. Said twice and printed neither time, which is
	/// the rule the whole panel keeps.
	private func note(_ key: String) -> String? {
		help?.lines.first { $0.key == key }?.note
	}

	/// What this key states, in the order the writer puts it on the line — so
	/// the summary beside a key and the line in the file read the same way
	/// round.
	private func stated(_ key: Scene.Key, fields: [Scene.Field]) -> String {
		var said = fields.filter { $0 != .angle && key[$0] != nil }.map(\.rawValue)
		if key.shape != nil { said.append("shape") }
		if key.color != nil { said.append("color") }
		if key.to != nil { said.append("to") }
		if key.angle != nil, fields.contains(.angle) { said.append("angle") }
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
		row.toolTip = note(field.rawValue)
		name.toolTip = row.toolTip
		box.toolTip = row.toolTip
		return row
	}

	/// The one row that is not a number: which shape this key names.
	///
	/// Shown as inherited exactly as the numbers are — dim, with the kind it
	/// already is in brackets — because the meaning is the same. A key that
	/// names a different kind is the whole of how a morph is written down.
	private func shapeRow(_ key: Scene.Key, of subject: Scene.Part, at index: Int,
	                      inherited: Scene.ShapeKind?) -> NSView {
		let declared: Scene.ShapeKind
		if case .shape(_, _, let kind) = subject.content { declared = kind } else { declared = .rectangle }
		let shown = key.shape ?? inherited ?? declared

		let name = NSTextField(labelWithString: "shape")
		name.font = Theme.mono
		name.textColor = key.shape == nil ? Theme.faintText : Theme.text
		name.translatesAutoresizingMaskIntoConstraints = false
		let wide = name.widthAnchor.constraint(equalToConstant: Self.keyWidth)
		wide.priority = NSLayoutConstraint.Priority(900)
		wide.isActive = true

		let kinds = Scene.ShapeKind.allCases
		let picker = choice(kinds.map { key.shape == nil ? "(\($0.rawValue))" : $0.rawValue },
		                    selected: kinds.firstIndex(of: shown) ?? 0,
		                    width: 118) { [weak self] picked in
			self?.onShape?(index, kinds[picked])
		}
		let button = small(key.shape == nil ? "set" : "inherit") { [weak self] in
			self?.onShape?(index, key.shape == nil ? shown : nil)
		}
		button.toolTip = key.shape == nil
			? "Name the shape here, at what it already is"
			: "Take it back to whatever the key before says"
		let row = NSStackView(views: [name, picker, button, NSView()])
		row.orientation = .horizontal
		row.spacing = 5
		row.alignment = .centerY
		row.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 0)
		row.toolTip = note("shape")
		name.toolTip = row.toolTip
		picker.toolTip = row.toolTip
		return row
	}

	private func colourRow(_ key: Scene.Key, at index: Int, inherited: RGBA?) -> NSView {
		stopRow("color", stated: key.color, inherited: inherited) { [weak self] value in
			self?.onColor?(index, value)
		}
	}

	/// The far stop of a background's ramp on this key.
	///
	/// Shown exactly as `color` is, beside it, because the two are the two ends
	/// of the same thing — which is the whole reason a background can now be
	/// animated in what it actually is rather than only in a flat tint.
	private func secondStopRow(_ key: Scene.Key, at index: Int, inherited: RGBA?) -> NSView {
		stopRow("to", stated: key.to, inherited: inherited) { [weak self] value in
			self?.onSecondStop?(index, value)
		}
	}

	/// A colour on a key: this key's, or the one before it's, with the button
	/// beside it offering to swap which.
	private func stopRow(_ label: String, stated: RGBA?, inherited: RGBA?,
	                     set: @escaping (RGBA?) -> Void) -> NSView {
		let name = NSTextField(labelWithString: label)
		name.font = Theme.mono
		name.textColor = stated == nil ? Theme.faintText : Theme.text
		name.translatesAutoresizingMaskIntoConstraints = false
		let wide = name.widthAnchor.constraint(equalToConstant: Self.keyWidth)
		wide.priority = NSLayoutConstraint.Priority(900)
		wide.isActive = true

		let shown = stated ?? inherited
		let well = colour(shown ?? .white) { value in set(value) }
		well.alphaValue = stated == nil ? 0.45 : 1
		let button = small(stated == nil ? "set" : "inherit") {
			set(stated == nil ? (shown ?? .white) : nil)
		}
		button.toolTip = stated == nil
			? "State this here, at what it already is"
			: "Take it back to whatever the key before says"
		let row = NSStackView(views: [name, well, button, NSView()])
		row.orientation = .horizontal
		row.spacing = 5
		row.alignment = .centerY
		row.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 0)
		row.toolTip = note(label)
		name.toolTip = row.toolTip
		well.toolTip = row.toolTip
		return row
	}

	// MARK: - The furniture

	private func add(_ row: NSView) {
		form.addArrangedSubview(row)
		row.translatesAutoresizingMaskIntoConstraints = false
		row.widthAnchor.constraint(equalTo: form.widthAnchor, constant: -24).isActive = true
	}

	/// A heading, a `?`, and a hairline running to the far edge.
	///
	/// The same arrangement — and the same reasoning — as the properties
	/// panel's. Every field in this form used to carry its explanation printed
	/// under it in grey, permanently, which is most of a screenful of prose for
	/// a part with six fields and four keys. Not a word of it is gone: it is the
	/// field's tooltip, and it is all here behind this button, keyed by the
	/// field it explains. Printed once when somebody asks, rather than always
	/// because somebody might.
	private func section(_ name: String) {
		let label = NSTextField(labelWithString: name.uppercased())
		label.font = Theme.heading
		label.textColor = Theme.faintText
		label.setContentHuggingPriority(.required, for: .horizontal)

		let help = Help(section: name)
		self.help = help
		helps.append(help)

		let ask = NSButton()
		ask.isBordered = false
		ask.bezelStyle = .inline
		ask.image = NSImage(systemSymbolName: "questionmark.circle",
		                    accessibilityDescription: "what these mean")?
			.withSymbolConfiguration(.init(pointSize: 10, weight: .medium)
				.applying(.init(paletteColors: [Theme.faintText])))
		ask.imagePosition = .imageOnly
		ask.toolTip = "What the keys in \(name) mean"
		ask.translatesAutoresizingMaskIntoConstraints = false
		ask.widthAnchor.constraint(equalToConstant: 16).isActive = true
		// Hidden until something is said under this heading. A `?` that opens an
		// empty popover is worse than no `?`.
		ask.isHidden = true
		let sink = Sink { [weak self, weak ask] _ in
			guard let ask else { return }
			self?.explain(help, from: ask)
		}
		sinks.append(sink)
		ask.target = sink
		ask.action = #selector(Sink.fire(_:))
		help.button = ask

		let rule = NSBox()
		rule.boxType = .separator
		rule.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
		rule.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1),
		                                             for: .horizontal)

		let row = NSStackView(views: [label, ask, rule])
		row.orientation = .horizontal
		row.spacing = 6
		row.alignment = .centerY
		row.edgeInsets = NSEdgeInsets(
			top: form.arrangedSubviews.isEmpty ? 0 : 8, left: 0, bottom: 0, right: 0)
		add(row)
	}

	/// Everything said about the fields under one heading.
	private final class Help {
		let section: String
		var lines: [(key: String, note: String)] = []
		weak var button: NSButton?
		init(section: String) { self.section = section }
	}

	/// The heading being filled now, and all of them, kept because a `Sink`
	/// holds only a closure.
	private var help: Help?
	private var helps: [Help] = []
	private var explaining: NSPopover?

	/// For the tests: every word of explanation this form carries, and which
	/// heading it is filed under.
	var explanationsForTesting: [(section: String, key: String, note: String)] {
		helps.flatMap { help in help.lines.map { (help.section, $0.key, $0.note) } }
	}

	/// For the tests: the headings that offer a `?`.
	var askableSectionsForTesting: [String] {
		helps.filter { $0.button?.isHidden == false }.map(\.section)
	}

	/// For the tests: every row of the form in order, as the words on it — so
	/// that "the note is near the thing it explains" is a thing a test can
	/// check rather than a thing somebody remembers.
	var rowsForTesting: [String] {
		func words(in view: NSView) -> [String] {
			view.subviews.flatMap { sub -> [String] in
				((sub as? NSTextField).map { [$0.stringValue] } ?? []) + words(in: sub)
			}
		}
		return form.arrangedSubviews.map { words(in: $0).joined(separator: " ") }
	}

	/// A word of explanation for a row this form builds by hand, so it reaches
	/// the `?` even though no ``field(_:_:note:)`` put it there.
	private func explains(_ key: String, _ note: String) {
		help?.lines.append((key, note))
		help?.button?.isHidden = false
	}

	private func explain(_ help: Help, from button: NSButton) {
		if let explaining, explaining.isShown { explaining.close(); return }
		let text = NSTextView()
		text.isEditable = false
		text.drawsBackground = false
		text.textContainerInset = NSSize(width: 14, height: 12)
		let body = NSMutableAttributedString()
		for (key, note) in help.lines {
			if !body.string.isEmpty { body.append(NSAttributedString(string: "\n\n")) }
			if !key.isEmpty {
				body.append(NSAttributedString(
					string: key + "\n",
					attributes: [.font: Theme.mono, .foregroundColor: Theme.text]))
			}
			body.append(NSAttributedString(
				string: note,
				attributes: [.font: Theme.body, .foregroundColor: Theme.dimText]))
		}
		text.textStorage?.setAttributedString(body)
		text.textContainer?.containerSize = NSSize(width: 340,
		                                           height: CGFloat.greatestFiniteMagnitude)
		text.textContainer?.widthTracksTextView = true
		text.frame = NSRect(x: 0, y: 0, width: 368, height: 100)
		text.layoutManager?.ensureLayout(for: text.textContainer!)
		let used = text.layoutManager?.usedRect(for: text.textContainer!).height ?? 100
		text.frame = NSRect(x: 0, y: 0, width: 368, height: min(520, used + 24))

		let holder = NSViewController()
		holder.view = text
		holder.preferredContentSize = text.frame.size
		let popover = NSPopover()
		popover.contentViewController = holder
		popover.behavior = .transient
		popover.appearance = NSAppearance(named: .darkAqua)
		explaining = popover
		popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
	}

	/// A remark that is not about one field, so there is nothing to rest on and
	/// it stays printed.
	private func remark(_ message: String) { add(caption(message)) }

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

		// Said twice and printed neither time: on the row, so resting on it says
		// it, and under the heading's `?`, so all of them can be read at once.
		guard let note else { return }
		row.toolTip = note
		name.toolTip = note
		for control in controls where control.toolTip == nil { control.toolTip = note }
		explains(key, note)
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
