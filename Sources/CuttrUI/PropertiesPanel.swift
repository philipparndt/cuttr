import AppKit
import QuartzCore
import CuttrCompose
import CuttrKit

/// Everything about the one thing that is selected.
///
/// The panel that means somebody never has to open the file. A caption's style,
/// how it arrives, how far above a face it sits, how long a spinner's third
/// word stays — all of it is in the format, so all of it is here, labelled with
/// the key it writes. Nothing is only reachable by typing YAML.
///
/// Laid out as a grid rather than as stacked rows: one column of keys, right
/// aligned, and one column of controls that all start at the same place. A form
/// where every row sets its own margins reads as a pile, and this one has forty
/// rows in it.
///
/// Rebuilt on each change of selection rather than shown and hidden. A form
/// whose rows are all present and mostly invisible is a form that eventually
/// shows the wrong ones, and this way what is on screen is exactly what the
/// selection has.
@MainActor
public final class PropertiesPanel: NSView {

	public var onChange: ((Project) -> Void)?

	/// The programme as it resolved, for the things that can only be known
	/// after resolving: where an anchor actually is at the moment an overlay
	/// appears, and when that moment is.
	public var resolved: ResolvedProject?
	/// A frame of the programme at a time, if one can be had. Asked for
	/// asynchronously; the window has the composition, not this panel.
	public var poster: ((Double, @escaping (NSImage?) -> Void) -> Void)?
	/// Somebody is placing a range at this moment on the programme. The window
	/// takes the preview there, so the picture and the panel agree.
	public var onScrub: ((Double) -> Void)?

	private var project = Project()
	private var vocabulary = ComposeDocument.Vocabulary()
	private var selection: ProjectSelection = .output
	private var built: ProjectSelection?

	/// The rows, stacked. One column of keys and one of controls, and nothing
	/// in either that can push back on the pane it is in.
	private let form = NSStackView()
	private static let keyWidth: CGFloat = 112
	private let title = NSTextField(labelWithString: "")
	/// The closures the controls call. Held because a target is unowned.
	private var sinks: [Sink] = []
	/// Bumped on every rebuild, so a frame that arrives late is dropped rather
	/// than drawn under the wrong overlay.
	private var generation = 0
	/// The picture the range strip scrubs, and when it last asked for a frame.
	private weak var currentPreview: FramePreview?
	private weak var currentStrip: SpanStrip?
	private var lastScrub: CFTimeInterval = 0
	/// Which range is being worked on, and whether the strip had the keyboard.
	///
	/// The form is rebuilt whenever the project comes back — which is after
	/// every edit — and a rebuilt strip would otherwise select its first range
	/// again. Clicking the second one and watching it jump back to the first is
	/// what that looks like from the outside.
	private var selectedSpan = 0
	private var stripHadFocus = false

	final class Sink: NSObject {
		let run: (NSControl) -> Void
		init(_ run: @escaping (NSControl) -> Void) { self.run = run }
		@objc func fire(_ sender: NSControl) { run(sender) }
	}

	public override init(frame: NSRect) {
		super.init(frame: frame)
		wantsLayer = true
		// A ground of its own, a shade up from the lists beside it. The panel is
		// a different kind of thing — one selection, examined — and looking like
		// a different kind of thing is most of how anybody knows that.
		layer?.backgroundColor = Theme.card.cgColor

		title.font = Theme.heading
		title.textColor = Theme.faintText

		form.orientation = .vertical
		form.alignment = .leading
		form.spacing = 7
		form.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 16, right: 14)
		form.setHuggingPriority(.required, for: .vertical)

		// The scroll view decides the width; the form fills it and grows only
		// downwards.
		//
		// This is the whole arrangement, and it is deliberately the plainest one
		// AppKit has. Everything that went wrong here went wrong because two
		// things were each entitled to decide a size: a grid whose columns
		// shared out the width of a picture, a form whose width was tied to its
		// pane, a split view whose panes both had opinions about their height.
		// One direction of travel, and none of that can happen: the pane sizes
		// the scroll view, the scroll view sizes the form, the form stacks rows,
		// and every control inside a row will shrink rather than argue.
		// Off, or the frame it happens to have becomes a pair of constraints —
		// `height == 0` among them — and they win over the ones written here.
		// The form then has no height, the panel's fitting size is a couple of
		// dozen points, and the window shrinks to it and will not be dragged
		// back out.
		form.translatesAutoresizingMaskIntoConstraints = false

		let scroll = TableScroll.wrap(form, horizontal: false)
		scroll.translatesAutoresizingMaskIntoConstraints = false
		addSubview(scroll)

		title.translatesAutoresizingMaskIntoConstraints = false
		addSubview(title)
		NSLayoutConstraint.activate([
			title.topAnchor.constraint(equalTo: topAnchor, constant: 12),
			title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
			title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),

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

	public func reload(_ project: Project, vocabulary: ComposeDocument.Vocabulary,
	                   selection: ProjectSelection) {
		self.project = project
		self.vocabulary = vocabulary
		self.selection = selection
		// Not while something is being typed into: every commit writes the file
		// and the file comes back, and rebuilding the form mid-word would take
		// the cursor with it.
		if built == selection, isEditing, !mine { return }
		rebuild()
	}

	/// Set by every edit this panel makes, so the project coming back is not
	/// mistaken for somebody else's change and skipped.
	///
	/// The panel refuses to reload while one of its fields is being typed into —
	/// otherwise the file arrives mid-word and takes the cursor with it. But an
	/// edit *made here* has to show up here: a range added, an offset dragged, a
	/// size picked from a menu. Anything else looks like a button that does
	/// nothing.
	private var mine = false

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
		// A different thing selected is a different set of ranges.
		if built != selection { selectedSpan = 0; stripHadFocus = false }
		mine = false
		sinks.removeAll()
		generation += 1
		for row in form.arrangedSubviews {
			form.removeArrangedSubview(row)
			row.removeFromSuperview()
		}

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
			// Whoever was placing ranges keeps the keyboard, or the delete key
			// stops working after the first thing it deletes.
			if stripHadFocus, let strip = currentStrip {
				window?.makeFirstResponder(strip)
			}
		}
	}

	// MARK: - output

	private func outputForm() {
		section("size and rate")
		field("size", [
			number(project.output.width, width: 72) { [weak self] value in
				self?.editOutput { $0.width = max(2, Int(value)) }
			},
			label("×"),
			number(project.output.height, width: 72) { [weak self] value in
				self?.editOutput { $0.height = max(2, Int(value)) }
			},
			presets(),
		], note: "the frame everything is fitted into")
		field("fps", [number(project.output.framesPerSecond, width: 72) { [weak self] value in
			self?.editOutput { $0.framesPerSecond = max(1, value) }
		}])
		field("file", [text(project.output.file ?? "", width: 210, placeholder: "programme.mov") {
			[weak self] value in
			self?.editOutput { $0.file = value.isEmpty ? nil : value }
		}], note: "where a render goes, beside the project")

		section("audio")
		field("", [check("level the programme", on: project.output.audio != nil) { [weak self] on in
			self?.editOutput { $0.audio = on ? AudioTarget() : nil }
		}])
		if let audio = project.output.audio {
			field("audio.target", [
				number(audio.target, width: 72) { [weak self] value in
					self?.editOutput { $0.audio?.target = value }
				},
				label("LUFS"),
			], note: "−16 is the web's convention, −23 the broadcaster's")
			field("audio.ceiling", [
				number(audio.ceiling, width: 72) { [weak self] value in
					self?.editOutput { $0.audio?.ceiling = value }
				},
				label("dBTP"),
			])
		}

		section("grade")
		field("match.reference", [combo(project.output.matchReference ?? "",
		                                values: [""] + vocabulary.clips, width: 210) {
			[weak self] value in
			self?.editOutput { $0.matchReference = value.isEmpty ? nil : Slug.make(from: value) }
		}], note: "every other clip is graded to look like this one")
	}

	/// The sizes almost every project is, without typing four digits.
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

	/// Every change this panel makes leaves by this door.
	private func commit(_ project: Project) {
		mine = true
		onChange?(project)
	}

	private func editOutput(_ change: (inout Output) -> Void) {
		var next = project
		change(&next.output)
		commit(next)
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
		section("what plays")
		field("kind", [pop(kinds, selected: current) { [weak self] index in
			self?.changeKind(path, entry, to: index)
		}])

		switch entry.source {
		case .clip(let reference):
			field("clip", [combo(reference.description,
			                     values: vocabulary.items.map(\.reference), width: 210) {
				[weak self] value in
				self?.replace(path, TimelineEntry(clip: ClipReference(value),
				                                  transition: entry.transition))
			}], note: "a slug, or take/slug when two takes share one")

		case .list(let references):
			field("list", [text(references.map(\.description).joined(separator: ", "),
			                    width: 260, placeholder: "intro, demo, outro") {
				[weak self] value in
				let parts = value.split(separator: ",")
					.map { ClipReference($0.trimmingCharacters(in: .whitespaces)) }
					.filter { !$0.slug.isEmpty }
				self?.replace(path, TimelineEntry(list: parts, transition: entry.transition))
			}], note: "in the order written")

		case .query(_, let source):
			field("query", [combo(source, values: vocabulary.tags.map { "#\($0)" } + ["*"],
			                      width: 260) { [weak self] value in
				guard let self else { return }
				guard let replacement = try? TimelineEntry(query: value, transition: entry.transition)
				else {
					self.rebuild()   // unreadable: put it back
					return
				}
				self.replace(path, replacement)
			}], note: "#tag, take/#tag, take/*, with and / or / not between them")

		case .group(let name, let inner):
			field("section", [text(name, width: 210, placeholder: "introduction") {
				[weak self] value in
				self?.replace(path, TimelineEntry(group: Slug.make(from: value), entries: inner,
				                                  transition: entry.transition))
			}], note: "overlays can be hung on @\(name.isEmpty ? "name" : name)"
				+ " — \(inner.count) entr\(inner.count == 1 ? "y" : "ies") inside")
		}

		section("how it arrives")
		field("transition", [
			number(entry.transition, width: 72) { [weak self] value in
				self?.replace(path, TimelineEntry(source: entry.source, transition: max(0, value)))
			},
			label("seconds"),
		], note: "0 cuts; anything else dissolves in from the entry before")
	}

	private func changeKind(_ path: [Int], _ entry: TimelineEntry, to index: Int) {
		let name = entry.source.description
		let replacement: TimelineEntry
		switch index {
		case 0: replacement = TimelineEntry(clip: ClipReference(name), transition: entry.transition)
		case 1: replacement = TimelineEntry(list: [ClipReference(name)], transition: entry.transition)
		case 2: replacement = (try? TimelineEntry(query: "#\(Slug.make(from: name))",
		                                          transition: entry.transition)) ?? entry
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
		commit(next)
	}

	// MARK: - overlay

	private func overlayForm(_ index: Int, _ overlay: Overlay) {
		full(placement(index, overlay))

		section("what it is")
		let isText: Bool
		if case .text = overlay.kind { isText = true } else { isText = false }
		field("kind", [pop(["text", "spinner"], selected: isText ? 0 : 1) { [weak self] pick in
			self?.editOverlay(index) { overlay in
				switch (pick, overlay.kind) {
				case (0, .spinner(let spinner)):
					overlay.kind = .text(spinner.words.first?.text ?? "Caption", style: nil)
				case (1, .text(let text, _)):
					overlay.kind = .spinner(Spinner(words: text.isEmpty ? [] : [SpinnerWord(text)]))
				default: break
				}
			}
		}])

		switch overlay.kind {
		case .text(let content, let style):
			field("text", [text(content, width: 260, placeholder: "what it says") {
				[weak self] value in
				self?.editOverlay(index) { $0.kind = .text(value, style: style) }
			}])
			field("style", [pop(styleNames,
			                    selected: styleNames.firstIndex(of: style ?? "lower-third") ?? 0) {
				[weak self] pick in
				guard let self else { return }
				self.editOverlay(index) { $0.kind = .text(content, style: self.styleNames[pick]) }
			}], note: "defined under `styles:`, or one of the built-in four")

		case .spinner(let spinner):
			field("style", [pop(Spinner.Style.allCases.map(\.rawValue),
			                    selected: Spinner.Style.allCases.firstIndex(of: spinner.style) ?? 0) {
				[weak self] pick in
				self?.editSpinner(index) { $0.style = Spinner.Style.allCases[pick] }
			}])
			field("size", [
				number(spinner.size, width: 72) { [weak self] value in
					self?.editSpinner(index) { $0.size = max(0.01, value) }
				},
				label("of frame height"),
			])
			field("speed", [
				number(spinner.speed, width: 72) { [weak self] value in
					self?.editSpinner(index) { $0.speed = value }
				},
				label("turns a second"),
			])
			field("color", [colour(spinner.color) { [weak self] rgba in
				self?.editSpinner(index) { $0.color = rgba }
			}])

			section("words")
			for (position, word) in spinner.words.enumerated() {
				field(position == 0 ? "words" : "", [
					text(word.text, width: 170, placeholder: "what it says now") {
						[weak self] value in
						self?.editSpinner(index) {
							guard position < $0.words.count else { return }
							$0.words[position].text = value
						}
					},
					text(word.duration.map { TakeWriter.number($0, places: 2) } ?? "",
					     width: 56, placeholder: "auto") { [weak self] value in
						self?.editSpinner(index) {
							guard position < $0.words.count else { return }
							$0.words[position].duration = Double(value)
						}
					},
					label("s"),
					small("−") { [weak self] in
						// Bounds checked, always. A control holds the position it
						// was built with, and the thing it points at can be gone
						// by the time it is clicked — two taps on the same minus
						// before the form has come back is enough.
						self?.editSpinner(index) {
							guard position < $0.words.count else { return }
							$0.words.remove(at: position)
						}
					},
				])
			}
			field("", [small("+ word") { [weak self] in
				self?.editSpinner(index) { $0.words.append(SpinnerWord("")) }
			}], note: spinner.words.isEmpty
				? "a spinner with no words only turns"
				: "they cycle for as long as the overlay is on screen")
		}

		section("when it is on")
		full(strip(index, overlay))
		let endpoints = vocabulary.items.map(\.reference) + vocabulary.groups.map { "@\($0)" }
		for (position, span) in overlay.spans.enumerated() {
			let byMarks: Bool
			if case .marks = span { byMarks = true } else { byMarks = false }
			var controls: [NSView] = [pop(["clips", "times"], selected: byMarks ? 0 : 1) {
				[weak self] pick in
				guard let self else { return }
				switch (pick, span) {
				case (0, .times):
					self.setSpan(index, position,
					             .clips(from: ClipReference("clip"), to: ClipReference("clip")))
				case (1, .marks):
					let extent = self.extent(of: span) ?? (0, 5)
					self.setSpan(index, position, .times(from: extent.0, to: extent.1))
				default: break
				}
			}]

			switch span {
			case .marks(let from, let to):
				controls.append(combo(from.description, values: endpoints, width: 150) {
					[weak self] value in
					self?.setSpan(index, position, .marks(from: .init(value), to: to))
				})
				controls.append(combo(to.description, values: endpoints, width: 150) {
					[weak self] value in
					self?.setSpan(index, position, .marks(from: from, to: .init(value)))
				})
			case .times(let from, let to):
				controls.append(text(Timecode.string(from), width: 96, placeholder: "00:00.000") {
					[weak self] value in
					guard let seconds = Timecode.parse(value) else { return }
					self?.setSpan(index, position, .times(from: seconds, to: to))
				})
				controls.append(text(Timecode.string(to), width: 96, placeholder: "00:05.000") {
					[weak self] value in
					guard let seconds = Timecode.parse(value) else { return }
					self?.setSpan(index, position, .times(from: from, to: seconds))
				})
			}
			if overlay.spans.count > 1 {
				controls.append(small("−") { [weak self] in
					self?.editOverlay(index) {
						guard position < $0.spans.count else { return }
						$0.spans.remove(at: position)
					}
				})
			}
			// Each range says which one it is. Two rows of identical controls
			// with one label between them is a form nobody can point at.
			field(overlay.spans.count == 1 ? "when" : "when[\(position)]", controls,
			      note: position == 0
				? "bound to clips it survives a re-cut; the same mark twice is one clip, or one whole section"
				: nil)
		}
		field("", [small("+ range") { [weak self] in
			self?.editOverlay(index) { overlay in
				// On again later: the last range repeated, moved along by its
				// own length when it is a time, ready to be pointed somewhere
				// else when it is a mark.
				guard let last = overlay.spans.last else { return }
				switch last {
				case .times(let from, let to):
					overlay.spans.append(.times(from: to, to: to + (to - from)))
				case .marks:
					overlay.spans.append(last)
				}
			}
		}], note: "the same overlay, on over another stretch of the programme")

		section("how it arrives and leaves")
		transitionRow("arrival", overlay.arrival) { [weak self] transition in
			self?.editOverlay(index) { $0.arrival = transition }
		}
		transitionRow("departure", overlay.departure) { [weak self] transition in
			self?.editOverlay(index) { $0.departure = transition }
		}

		section("where it sits")
		field("anchor", [combo(overlay.anchor ?? "", values: [""] + vocabulary.anchors, width: 210) {
			[weak self] value in
			let name = value.trimmingCharacters(in: .whitespaces)
			self?.editOverlay(index) { $0.anchor = name.isEmpty ? nil : Slug.make(from: name) }
		}], note: "a tracked face: the overlay follows it, and the style's position is ignored")
		field("offset", [
			number(overlay.offset.x, width: 72) { [weak self] value in
				self?.editOverlay(index) { $0.offset.x = value }
			},
			number(overlay.offset.y, width: 72) { [weak self] value in
				self?.editOverlay(index) { $0.offset.y = value }
			},
		], note: "x and y from the anchor, both in fractions of the frame height")
	}

	private var styleNames: [String] {
		Array(Set(project.styles.keys).union(TextStyle.builtIn.keys)).sorted()
	}

	private func transitionRow(_ name: String, _ transition: Overlay.Transition,
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
		if current != 0 {
			controls.append(number(transition.duration, width: 60) { value in
				switch transition {
				case .fade: set(.fade(over: max(0, value)))
				case .slide(let edge, _): set(.slide(edge, over: max(0, value)))
				case .cut: break
				}
			})
			controls.append(label("seconds"))
		}
		field(name, controls)
	}

	private func editOverlay(_ index: Int, _ change: (inout Overlay) -> Void) {
		var next = project
		guard index < next.overlays.count else { return }
		change(&next.overlays[index])
		commit(next)
	}

	private func editSpinner(_ index: Int, _ change: (inout Spinner) -> Void) {
		editOverlay(index) { overlay in
			guard case .spinner(var spinner) = overlay.kind else { return }
			change(&spinner)
			overlay.kind = .spinner(spinner)
		}
	}

	private func setSpan(_ index: Int, _ position: Int, _ span: Overlay.Span) {
		editOverlay(index) { overlay in
			guard position < overlay.spans.count else { return }
			overlay.spans[position] = span
		}
	}

	// MARK: - When it is on

	/// The programme with this overlay's ranges lying over it, draggable.
	private func strip(_ index: Int, _ overlay: Overlay) -> NSView {
		let strip = SpanStrip()
		currentStrip = strip
		strip.duration = resolved?.duration ?? 0
		strip.blocks = (resolved?.clips ?? []).map {
			SpanStrip.Block(start: $0.start, end: $0.end, name: $0.clip.slug)
		}
		strip.ranges = overlay.spans.map { span in
			let extent = self.extent(of: span) ?? (0, 0)
			return SpanStrip.Range(start: extent.0, end: extent.1, movable: movable(span))
		}
		strip.selected = min(max(0, selectedSpan), max(0, overlay.spans.count - 1))
		strip.onSelect = { [weak self] position in
			self?.selectedSpan = position
			self?.stripHadFocus = true
		}
		strip.onDelete = { [weak self] position in
			self?.editOverlay(index) { overlay in
				// The last one is not deleted: an overlay that is on over
				// nothing is not an overlay, it is a puzzle.
				guard overlay.spans.count > 1, position < overlay.spans.count else { return }
				overlay.spans.remove(at: position)
			}
		}
		strip.onScrub = { [weak self] time in
			self?.stripHadFocus = true
			self?.scrub(to: time)
		}
		strip.onDrag = { [weak self] position, start, end in
			guard let self, position < overlay.spans.count else { return }
			self.selectedSpan = position
			self.setSpan(index, position,
			             self.span(from: overlay.spans[position], start: start, end: end))
		}
		return strip
	}

	/// Show the frame at this moment while a range is being placed, and take the
	/// window's preview there too.
	///
	/// Throttled, because a frame is decoded for each one and a drag asks sixty
	/// times a second.
	private func scrub(to time: Double) {
		onScrub?(time)
		let now = CACurrentMediaTime()
		guard now - lastScrub > 0.12 else { return }
		lastScrub = now
		let generation = self.generation
		poster?(time) { [weak self] image in
			guard let self, self.generation == generation, let image else { return }
			self.currentPreview?.poster = image
		}
	}

	/// Where a range lands on the programme's clock.
	private func extent(of span: Overlay.Span) -> (Double, Double)? {
		switch span {
		case .times(let from, let to):
			return (from, to)
		case .marks(let from, let to):
			func edges(_ endpoint: Overlay.Span.Endpoint) -> (Double, Double)? {
				switch endpoint {
				case .clip(let reference):
					let matching = (resolved?.clips ?? []).filter { $0.reference.slug == reference.slug }
					guard let first = matching.first, let last = matching.last else { return nil }
					return (first.start, last.end)
				case .group(let name):
					guard let group = resolved?.groups.first(where: { $0.name == name }) else { return nil }
					return (group.start, group.end)
				}
			}
			guard let a = edges(from), let b = edges(to) else { return nil }
			return (a.0, max(b.1, a.1))
		}
	}

	/// A section decides its own length on the programme, so a range hung on
	/// one is shown and not dragged.
	private func movable(_ span: Overlay.Span) -> Bool {
		switch span {
		case .times: return true
		case .marks(let from, let to):
			if case .group = from { return false }
			if case .group = to { return false }
			return true
		}
	}

	/// A drag, written back the way the range was written.
	///
	/// Times move in seconds. Clips **snap**: the range takes the name of the
	/// clip under each end, because a caption that belonged to `intro` should
	/// still belong to a clip afterwards rather than to 4.28 seconds.
	private func span(from existing: Overlay.Span, start: Double, end: Double) -> Overlay.Span {
		switch existing {
		case .times:
			return .times(from: start, to: end)
		case .marks:
			let clips = resolved?.clips ?? []
			let first = clips.last { $0.start <= start + 0.001 } ?? clips.first
			let last = clips.last { $0.start < end - 0.001 } ?? first
			guard let first, let last else { return existing }
			return .marks(from: .clip(first.reference), to: .clip(last.reference))
		}
	}

	// MARK: - Placing it on the picture

	/// The frame the overlay appears on, with the overlay on it, draggable.
	private func placement(_ index: Int, _ overlay: Overlay) -> NSView {
		let preview = FramePreview()
		currentPreview = preview
		preview.aspect = project.output.size

		let found = resolved?.overlays.first { $0.overlay == overlay }
		let anchor = found?.path?.point(at: found?.start ?? 0)
		preview.anchorPoint = anchor
		preview.anchorName = overlay.anchor

		switch overlay.kind {
		case .text(let content, let style):
			preview.content = .caption(content, project.style(named: style))
		case .spinner(let spinner):
			// The words beside a spinner have a style of their own, and it is
			// not the caption style: `caption` has no plate behind it, because
			// a spinner over somebody's head should not arrive with a black box.
			preview.content = .spinner(
				spinner,
				words: spinner.wordStyle.map { project.style(named: $0) } ?? TextStyle.caption)
		}

		preview.spot = spot(of: overlay, anchor: anchor)
		preview.explanation = explanation(for: overlay, anchored: anchor != nil)
		preview.onMove = { [weak self] spot in
			self?.place(index, overlay, at: spot, anchor: anchor)
		}

		// The frame at the moment it appears — asked for now, drawn whenever it
		// arrives, and dropped if the selection has moved on by then.
		if let poster, let start = found?.start {
			let generation = self.generation
			poster(start) { [weak self, weak preview] image in
				guard let self, self.generation == generation else { return }
				preview?.poster = image
			}
		}
		return preview
	}

	/// Where the overlay sits, in unit coordinates of the frame.
	///
	/// Three rules, because the format has three: an anchored overlay is the
	/// anchor plus its offset; a spinner with no anchor is the middle plus its
	/// offset; a caption with no anchor is wherever its style says.
	private func spot(of overlay: Overlay, anchor: CGPoint?) -> CGPoint {
		let ratio = project.output.size.height / max(1, project.output.size.width)
		if let anchor {
			return CGPoint(x: anchor.x + overlay.offset.x * ratio, y: anchor.y + overlay.offset.y)
		}
		if case .text(_, let style) = overlay.kind {
			return project.style(named: style).position
		}
		return CGPoint(x: 0.5 + overlay.offset.x, y: 0.5 + overlay.offset.y)
	}

	private func explanation(for overlay: Overlay, anchored: Bool) -> String {
		if anchored { return "drag: offset from the anchor" }
		if case .text(_, let style) = overlay.kind {
			return "drag: position of style `\(style ?? "lower-third")` — every caption drawn in it"
		}
		return "drag: offset from the middle of the frame"
	}

	/// The drag, written back as the file would say it.
	private func place(_ index: Int, _ overlay: Overlay, at spot: CGPoint, anchor: CGPoint?) {
		let ratio = project.output.size.width / max(1, project.output.size.height)
		if let anchor {
			editOverlay(index) {
				$0.offset = CGPoint(x: (spot.x - anchor.x) * ratio, y: spot.y - anchor.y)
			}
			return
		}
		if case .text(let content, let styleName) = overlay.kind {
			// A caption with no anchor sits where its *style* says, so that is
			// what a drag changes — and it says so under the picture. A built-in
			// style is written into the project on the way, because a project
			// cannot move something it never mentioned.
			let name = styleName ?? "lower-third"
			var next = project
			var style = next.styles[name] ?? TextStyle.builtIn[name] ?? .lowerThird
			style.position = spot
			next.styles[name] = style
			next.overlays[index].kind = .text(content, style: name)
			commit(next)
			return
		}
		editOverlay(index) { $0.offset = CGPoint(x: spot.x - 0.5, y: spot.y - 0.5) }
	}

	// MARK: - Rows

	/// Adds a row and makes it as wide as the form. Every row in this panel is
	/// exactly one of these, so there is one place where width is decided.
	private func add(_ row: NSView) {
		form.addArrangedSubview(row)
		row.translatesAutoresizingMaskIntoConstraints = false
		row.widthAnchor.constraint(equalTo: form.widthAnchor, constant: -28).isActive = true
	}

	/// A heading with a hairline running to the far edge.
	private func section(_ name: String) {
		let label = NSTextField(labelWithString: name.uppercased())
		label.font = Theme.heading
		label.textColor = Theme.faintText
		label.setContentHuggingPriority(.required, for: .horizontal)

		let rule = NSBox()
		rule.boxType = .separator
		rule.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
		rule.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)

		let header = NSStackView(views: [label, rule])
		header.orientation = .horizontal
		header.spacing = 8
		header.alignment = .centerY
		header.edgeInsets = NSEdgeInsets(
			top: form.arrangedSubviews.isEmpty ? 0 : 8, left: 0, bottom: 0, right: 0)
		add(header)
	}

	/// Something that takes the whole width — the picture, the range strip.
	private func full(_ view: NSView) {
		add(view)
	}

	/// A labelled line. The label is the **key it writes**, not a paraphrase of
	/// it, so somebody who reads the file afterwards recognises what they set.
	private func field(_ key: String, _ controls: [NSView], note: String? = nil) {
		let name = NSTextField(labelWithString: key)
		name.font = Theme.mono
		name.textColor = Theme.text
		name.alignment = .left
		name.lineBreakMode = .byTruncatingTail
		name.translatesAutoresizingMaskIntoConstraints = false
		let wide = name.widthAnchor.constraint(equalToConstant: Self.keyWidth)
		wide.priority = NSLayoutConstraint.Priority(900)
		wide.isActive = true
		_ = squeezable(name)

		// A spacer that gives before any control does, so a narrow pane takes
		// the empty space away rather than the fields.
		let slack = NSView()
		slack.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
		slack.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)

		let row = NSStackView(views: [name] + controls + [slack])
		row.orientation = .horizontal
		row.spacing = 6
		row.alignment = .centerY
		add(row)

		if let note { add(caption(note)) }
	}

	/// A line of explanation, indented under the controls it explains.
	private func caption(_ message: String) -> NSView {
		let label = WrappingLabel(labelWithString: message)
		label.font = Theme.monoSmall
		label.textColor = Theme.faintText
		label.lineBreakMode = .byWordWrapping
		label.setContentCompressionResistancePriority(
			NSLayoutConstraint.Priority(1), for: .horizontal)

		let row = NSStackView(views: [label])
		row.orientation = .horizontal
		row.edgeInsets = NSEdgeInsets(top: 0, left: Self.keyWidth + 6, bottom: 4, right: 0)
		return row
	}

	/// A label that wraps to whatever width it is given.
	///
	/// `preferredMaxLayoutWidth` is the only way to tell AppKit how tall a
	/// wrapped label is, and it has to be set from the width the label actually
	/// got — which is known at layout, not before. Setting it only when it
	/// changes is what stops that from being a loop.
	private final class WrappingLabel: NSTextField {
		override func layout() {
			if preferredMaxLayoutWidth != bounds.width {
				preferredMaxLayoutWidth = bounds.width
				invalidateIntrinsicContentSize()
			}
			super.layout()
		}
	}

	// MARK: - Controls

	/// Every control in this panel gives up width before the pane does.
	///
	/// One rule, applied to all of them, because a single control that resists
	/// being squeezed makes its whole row wider than the pane — and then the
	/// form needs a horizontal scrollbar, which takes height, which moves
	/// everything else. Truncated is fine; overflowing is not.
	private func squeezable<T: NSView>(_ view: T) -> T {
		view.setContentCompressionResistancePriority(
			NSLayoutConstraint.Priority(1), for: .horizontal)
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
		// Both dimensions stated. A grid row takes its height from what is in it,
		// and a field that only says how wide it is gets whatever is left —
		// which was two thirds of a line, with the descenders cut off.
		// Wide enough to read, willing to be narrower. A pane can be dragged to
		// any width, and a field that insists on 260 points in a 300-point pane
		// is how a form comes to have a horizontal scrollbar.
		field.translatesAutoresizingMaskIntoConstraints = false
		field.setContentCompressionResistancePriority(
			NSLayoutConstraint.Priority(1), for: .horizontal)
		field.setContentHuggingPriority(NSLayoutConstraint.Priority(200), for: .horizontal)
		let wide = field.widthAnchor.constraint(equalToConstant: width)
		wide.priority = NSLayoutConstraint.Priority(400)
		wide.isActive = true
		field.widthAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true
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
		box.setContentCompressionResistancePriority(
			NSLayoutConstraint.Priority(1), for: .horizontal)
		box.setContentHuggingPriority(NSLayoutConstraint.Priority(200), for: .horizontal)
		let wide = box.widthAnchor.constraint(equalToConstant: width)
		wide.priority = NSLayoutConstraint.Priority(400)
		wide.isActive = true
		box.widthAnchor.constraint(greaterThanOrEqualToConstant: 60).isActive = true
		box.heightAnchor.constraint(equalToConstant: 24).isActive = true
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
		button.lineBreakMode = .byTruncatingTail
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
		button.lineBreakMode = .byTruncatingTail
		return squeezable(button)
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
		return squeezable(button)
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
		return squeezable(well)
	}
}
