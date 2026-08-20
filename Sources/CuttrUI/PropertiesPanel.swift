@preconcurrency import AVFoundation
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
	/// The programme as the preview plays it, for the dialogs that set a moment
	/// against it. Built by the window; this panel only borrows it.
	public var programme: (() -> (composition: AVComposition,
	                              videoComposition: AVVideoComposition?,
	                              audioMix: AVAudioMix?,
	                              duration: Double)?)?
	/// Somebody is placing a range at this moment on the programme. The window
	/// takes the preview there, so the picture and the panel agree.
	public var onScrub: ((Double) -> Void)?
	/// Somebody clicked one of the things in the subject line: select it.
	///
	/// The head of this panel says what the selection depends on, and every one
	/// of those is a place — so it is a link. The panel cannot select anything
	/// itself: the tree owns the selection, and two objects deciding what is
	/// selected is how a panel comes to show one thing while a tree highlights
	/// another.
	public var onGoTo: ((ProjectSelection) -> Void)?
	/// And the one relationship that leads out of this window altogether: the
	/// take a clip was cut from.
	public var onOpenInTake: (([Int]) -> Void)?
	/// What the document is called, for the head of the panel when the thing
	/// selected *is* the document. `output` is the key it writes; it is not what
	/// anybody calls the project.
	public var documentName = ""


	private var project = Project()
	private var vocabulary = ComposeDocument.Vocabulary()
	private var selection: ProjectSelection = .output
	private var built: ProjectSelection?

	/// The rows, stacked. One column of keys and one of controls, and nothing
	/// in either that can push back on the pane it is in.
	private let form = NSStackView()
	private static let keyWidth: CGFloat = 112
	/// The thing, and what it depends on. Where `TIMELINE ENTRY` used to be.
	private let subject = SubjectLine()
	/// A frame of it, in the space above the fields that was empty.
	private let thumbnail = NSImageView()
	/// How tall the head is, decided here and nowhere else.
	///
	/// A fixed number rather than something the subject line and the picture
	/// negotiate. Two views that each size themselves from their contents is
	/// the arrangement this panel has already been burnt by twice: the form
	/// grew, the pane re-laid out, the form shrank, and the window flickered
	/// while it was dragged.
	private static let headHeight: CGFloat = 80
	private static let thumbnailWidth: CGFloat = 120
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
	/// Which key of the selected overlay is being worked on. Held for the same
	/// reason `selectedSpan` is: the form is rebuilt after every edit, and a
	/// rebuilt key list would otherwise go back to the first one every time
	/// somebody typed a number into the third.
	private var selectedKey = 0

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

		thumbnail.imageScaling = .scaleProportionallyUpOrDown
		thumbnail.wantsLayer = true
		thumbnail.layer?.backgroundColor = Theme.background.cgColor
		thumbnail.layer?.cornerRadius = 4
		thumbnail.layer?.masksToBounds = true

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

		for view in [thumbnail, subject] as [NSView] {
			view.translatesAutoresizingMaskIntoConstraints = false
			addSubview(view)
		}
		NSLayoutConstraint.activate([
			thumbnail.topAnchor.constraint(equalTo: topAnchor, constant: 10),
			thumbnail.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
			thumbnail.widthAnchor.constraint(equalToConstant: Self.thumbnailWidth),
			thumbnail.heightAnchor.constraint(equalToConstant: Self.thumbnailWidth * 9 / 16),

			subject.topAnchor.constraint(equalTo: topAnchor, constant: 10),
			subject.leadingAnchor.constraint(equalTo: thumbnail.trailingAnchor, constant: 10),
			subject.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
			subject.heightAnchor.constraint(equalToConstant: Self.headHeight - 12),

			scroll.topAnchor.constraint(equalTo: topAnchor, constant: Self.headHeight),
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

	/// For the tests: every word of explanation this form carries, and which
	/// heading it is filed under.
	var explanationsForTesting: [(section: String, key: String, note: String)] {
		helps.flatMap { help in help.lines.map { (help.section, $0.key, $0.note) } }
	}

	/// For the tests: the headings that offer a `?`.
	var askableSectionsForTesting: [String] {
		helps.filter { $0.button?.isHidden == false }.map(\.section)
	}

	/// For the tests: the head, without going through the view tree looking for
	/// a font.
	var subjectForTesting: SubjectLine { subject }

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
		if built != selection { selectedSpan = 0; stripHadFocus = false; selectedKey = 0 }
		mine = false
		sinks.removeAll()
		helps.removeAll()
		help = nil
		generation += 1
		for row in form.arrangedSubviews {
			form.removeArrangedSubview(row)
			row.removeFromSuperview()
		}

		built = selection
		showSubject()
		switch selection {
		case .output:
			outputForm()
		case .entry(let path):
			guard let entry = project.entry(at: path) else { return }
			entryForm(path, entry)
		case .sound(let origin):
			guard let sound = project.sound(at: origin) else { return }
			soundForm(origin, sound)
		case .overlay(let origin):
			guard let overlay = project.overlay(at: origin) else { return }
			overlayForm(origin, overlay)
			// Whoever was placing ranges keeps the keyboard, or the delete key
			// stops working after the first thing it deletes.
			if stripHadFocus, let strip = currentStrip {
				window?.makeFirstResponder(strip)
			}
		}
	}

	// MARK: - The thing, and what it depends on

	/// Heads the panel with the selection and its relationships.
	///
	/// Everything here comes out of the resolver, which is the only thing that
	/// knows: which take a slug came from, where a placement lands on the
	/// programme's clock, which overlays are on while it plays. The panel used
	/// to print the name of a Swift type instead.
	private func showSubject() {
		let (name, kind, relations) = describe()
		subject.show(name, kind: kind, relations: relations)
		showThumbnail(at: momentOfSelection)
	}

	/// Where on the programme the selection is, for the picture and for the
	/// `at` link. `nil` when the thing does not occupy time.
	private var momentOfSelection: Double? { selection.moment(in: resolved) }

	private func showThumbnail(at time: Double?) {
		thumbnail.image = nil
		guard let poster, let time else { return }
		let asked = generation
		poster(time) { [weak self] image in
			guard let self, self.generation == asked else { return }
			self.thumbnail.image = image
		}
	}

	private func describe() -> (String, Theme.Kind?, [SubjectLine.Relation]) {
		switch selection {
		case .output:
			return (documentName.isEmpty ? "output" : documentName, nil, [
				SubjectLine.Relation("frame",
				                     "\(project.output.width)×\(project.output.height)"),
				SubjectLine.Relation("rate", String(format: "%g fps",
				                                    project.output.framesPerSecond)),
				SubjectLine.Relation("holds", "\(resolved?.clips.count ?? project.timeline.count) clips"),
			])
		case .entry(let path):
			guard let entry = project.entry(at: path) else { return ("project", nil, []) }
			return (entryName(entry), entryKind(entry), entryRelations(path, entry))
		case .overlay(let origin):
			guard let overlay = project.overlay(at: origin) else { return ("project", nil, []) }
			return (ProgrammePanel.OverlayRow.name(overlay), overlayKind(overlay),
			        carriedRelations(origin, anchor: overlay.anchor,
			                         appearances: overlay.appearances.count))
		case .sound(let origin):
			guard let sound = project.sound(at: origin) else { return ("project", nil, []) }
			return (sound.file, .sound, carriedRelations(origin, anchor: nil, appearances: 1))
		}
	}

	private func entryName(_ entry: TimelineEntry) -> String {
		switch entry.source {
		case .group(let name, _): return "@" + name
		case .card: return "card"
		default: return entry.source.description
		}
	}

	private func entryKind(_ entry: TimelineEntry) -> Theme.Kind {
		switch entry.source {
		case .clip: return .clip
		case .list: return .list
		case .query: return .query
		case .card: return .card
		case .group: return .section
		}
	}

	private func overlayKind(_ overlay: Overlay) -> Theme.Kind {
		switch overlay.kind {
		case .text: return .text
		case .spinner: return .spinner
		case .effect: return .effect
		case .scene: return .scene
		case .film: return .film
		case .aberration: return .aberration
		case .tape: return .tape
		case .bubble: return .bubble
		}
	}

	private func entryRelations(_ path: [Int], _ entry: TimelineEntry) -> [SubjectLine.Relation] {
		var out: [SubjectLine.Relation] = []

		// Which take it came out of, and a way to go and look at the footage.
		if let placed = resolved?.clips.first(where: { $0.entry == path }) {
			out.append(SubjectLine.Relation("from", placed.takeName, kind: .take) {
				[weak self] in self?.onOpenInTake?(path)
			})
		}

		// Which section it is inside. Structural, so it is the one relationship
		// that says where this row *is* rather than what it points at.
		if path.count > 1, let parent = project.entry(at: Array(path.dropLast())),
		   case .group(let name, _) = parent.source {
			let up = Array(path.dropLast())
			out.append(SubjectLine.Relation("in", "@" + name, kind: .section) {
				[weak self] in self?.onGoTo?(.entry(up))
			})
		}

		// What is drawn over it, and a way to the first of them. Anything hung
		// on this entry's own name counts, wherever it is written.
		let carried = overlaysOn(path, entry)
		if let first = carried.first {
			let what = carried.count == 1
				? project.overlay(at: first).map { ProgrammePanel.OverlayRow.name($0) } ?? "1 overlay"
				: "\(carried.count) overlays"
			out.append(SubjectLine.Relation("carries", what, kind: .text) {
				[weak self] in self?.onGoTo?(.overlay(first))
			})
		}

		if let moment = momentOfSelection {
			out.append(SubjectLine.Relation("at", Timecode.string(moment)) {
				[weak self] in self?.onScrub?(moment)
			})
		}
		return out
	}

	/// Every overlay hung on an entry: the ones written inside it, and the ones
	/// in the top-level list that name it.
	private func overlaysOn(_ path: [Int], _ entry: TimelineEntry) -> [Origin] {
		var out: [Origin] = entry.overlays.indices.map { .entry(path: path, index: $0) }
		let names = ProgrammePanel.names(of: entry)
		out += project.overlays.indices
			.filter { index in
				ProgrammePanel.endpoints(of: project.overlays[index]).contains { names.contains($0) }
			}
			.map { Origin.project($0) }
		return out
	}

	/// The relationships an overlay or a sound has: what it is written inside,
	/// what it follows, when it is on.
	private func carriedRelations(_ origin: Origin, anchor: String?,
	                              appearances: Int) -> [SubjectLine.Relation] {
		var out: [SubjectLine.Relation] = []
		if case .entry(let path, _) = origin, let entry = project.entry(at: path) {
			out.append(SubjectLine.Relation("in", entryName(entry), kind: entryKind(entry)) {
				[weak self] in self?.onGoTo?(.entry(path))
			})
		} else {
			// Written in the top-level list, so what it is about is whatever its
			// span names — and that name is a row in the tree.
			let named = ProgrammePanel.endpoints(of: currentSpan).sorted().first { !$0.isEmpty }
			if let named, let path = pathNamed(named) {
				out.append(SubjectLine.Relation("over", named, kind: .section) {
					[weak self] in self?.onGoTo?(.entry(path))
				})
			} else if let named {
				out.append(SubjectLine.Relation("over", named))
			} else {
				out.append(SubjectLine.Relation("over", "the programme's own clock"))
			}
		}
		if let anchor {
			out.append(SubjectLine.Relation("follows", anchor, kind: .anchor))
		}
		if appearances > 1 {
			out.append(SubjectLine.Relation("on", "\(appearances) times"))
		}
		if let moment = momentOfSelection {
			out.append(SubjectLine.Relation("at", Timecode.string(moment)) {
				[weak self] in self?.onScrub?(moment)
			})
		}
		return out
	}

	/// The span of whatever is selected, for working out what it is over.
	private var currentSpan: Overlay.Span {
		switch selection {
		case .overlay(let origin):
			return project.overlay(at: origin)?.span ?? .times(from: 0, to: 0)
		case .sound(let origin):
			return project.sound(at: origin)?.span ?? .times(from: 0, to: 0)
		default:
			return .times(from: 0, to: 0)
		}
	}

	/// Which timeline entry answers to a name, so that `over @question1` can be
	/// somewhere to go rather than a word.
	private func pathNamed(_ name: String) -> [Int]? {
		var found: [Int]?
		func walk(_ entries: [TimelineEntry], _ prefix: [Int]) {
			for (index, entry) in entries.enumerated() {
				let path = prefix + [index]
				if found == nil, ProgrammePanel.names(of: entry).contains(name) { found = path }
				if case .group(_, let inner) = entry.source { walk(inner, path) }
			}
		}
		walk(project.timeline, [])
		return found
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
		let kinds = ["clip", "list", "query", "card", "section"]
		let current: Int
		switch entry.source {
		case .clip: current = 0
		case .list: current = 1
		case .query: current = 2
		case .card: current = 3
		case .group: current = 4
		}
		section("what plays")
		field("kind", [pop(kinds, selected: current) { [weak self] index in
			self?.changeKind(path, entry, to: index)
		}])

		switch entry.source {
		case .clip(let reference):
			// The same dialog the `when:` fields use, and for the same reason:
			// a combo box offers `clip-4`, which is what the file writes, and
			// with four takes open that names four different clips.
			field("clip", [endpoint(.clip(reference), only: [.clip]) { [weak self] value in
				self?.replace(path, TimelineEntry(
					clip: ClipReference(value), transition: entry.transition,
					label: entry.label, trim: entry.trim))
			}], note: "a slug, or take/slug when two takes share one — "
				+ "the dialog shows every clip under its take")
			field("as", [text(entry.label ?? "", width: 210, placeholder: "a name for this use") {
				[weak self] value in
				let name = value.trimmingCharacters(in: .whitespaces)
				self?.replace(path, TimelineEntry(
					clip: reference, transition: entry.transition,
					label: name.isEmpty ? nil : Slug.make(from: name), trim: entry.trim))
			}], note: "the same clip used twice is two places; a name tells them apart, "
				+ "and an overlay hangs on `@name`")
			field("trim", [
				text(Timecode.string(entry.trim.head), width: 96, placeholder: "00:00.000") {
					[weak self] value in
					guard let seconds = Timecode.parse(value) else { return }
					self?.replace(path, TimelineEntry(
						clip: reference, transition: entry.transition, label: entry.label,
						trim: (max(0, seconds), entry.trim.tail)))
				},
				text(Timecode.string(entry.trim.tail), width: 96, placeholder: "00:00.000") {
					[weak self] value in
					guard let seconds = Timecode.parse(value) else { return }
					self?.replace(path, TimelineEntry(
						clip: reference, transition: entry.transition, label: entry.label,
						trim: (entry.trim.head, max(0, seconds))))
				},
				ellipsis("trim") { [weak self] button in
					self?.openTrim(path, reference, entry, from: button)
				},
			], note: "off the head and off the tail, here only — the take keeps its own marks; "
				+ "`…` plays the clip and puts the marks on it")

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

		case .card(let card):
			// Everything a card has is here, because a card is a length and a
			// colour and there is nothing else to know about it.
			func change(_ edit: @escaping (inout Card) -> Void) {
				var next = card
				edit(&next)
				self.replace(path, TimelineEntry(
					card: next, transition: entry.transition, label: entry.label))
			}
			field("card", [text(Timecode.string(card.duration), width: 96,
			                    placeholder: "00:04.000") { value in
				guard let seconds = Timecode.parse(value) else { return }
				change { $0.duration = max(0, seconds) }
			}], note: "how long the programme sits on this — there is no take behind it")

			let top: RGBA, bottom: RGBA, isGradient: Bool
			switch card.fill {
			case .solid(let colour): top = colour; bottom = colour; isGradient = false
			case .gradient(let a, let b): top = a; bottom = b; isGradient = true
			}
			var fill: [NSView] = [
				pop(["solid", "gradient"], selected: isGradient ? 1 : 0) { pick in
					change { $0.fill = pick == 0 ? .solid(top) : .gradient(top: top, bottom: bottom) }
				},
				colour(top) { picked in
					change { $0.fill = isGradient ? .gradient(top: picked, bottom: bottom) : .solid(picked) }
				},
			]
			if isGradient {
				fill.append(colour(bottom) { picked in
					change { $0.fill = .gradient(top: top, bottom: picked) }
				})
				fill.append(label("top, bottom"))
			}
			field("fill", fill, note: isGradient
				? "two stops down the frame — a flat colour reads as a fault, two stops read as a made thing"
				: "black is the default, and the one fill the file leaves out")

			field("as", [text(entry.label ?? "", width: 210, placeholder: "intro") { value in
				let name = value.trimmingCharacters(in: .whitespaces)
				self.replace(path, TimelineEntry(
					card: card, transition: entry.transition,
					label: name.isEmpty ? nil : Slug.make(from: name)))
			}], note: "a card is usually there to be drawn on, and `@name` is how "
				+ "an overlay finds it")

		case .group(let name, let inner):
			field("section", [text(name, width: 210, placeholder: "introduction") {
				[weak self] value in
				self?.replace(path, TimelineEntry(group: Slug.make(from: value), entries: inner,
				                                  transition: entry.transition))
			}], note: "overlays can be hung on @\(name.isEmpty ? "name" : name)"
				+ " — \(inner.count) entr\(inner.count == 1 ? "y" : "ies") inside")
		}

		section("how it arrives")
		// Every kind but a cut is the same arrangement — the two shots overlap
		// and the programme is that much shorter — so they are one popup, a
		// length, and a direction for the ones that travel.
		let ways = Transition.Kind.allCases
		let how = entry.transition
		var arrival: [NSView] = [
			pop(ways.map { $0.title }, selected: ways.firstIndex(of: how.kind) ?? 0) {
				[weak self] pick in
				let kind = ways[pick]
				self?.replace(path, TimelineEntry(
					source: entry.source, transition: Transition(
						kind, seconds: how.seconds > 0 ? how.seconds : 0.5, edge: how.edge),
					label: entry.label, trim: entry.trim))
			},
		]
		if how.kind != .cut {
			arrival.append(number(how.seconds > 0 ? how.seconds : 0.5, width: 68) {
				[weak self] value in
				self?.replace(path, TimelineEntry(
					source: entry.source,
					transition: Transition(how.kind, seconds: max(0, value), edge: how.edge),
					label: entry.label, trim: entry.trim))
			})
			arrival.append(label("seconds"))
		}
		if how.kind.directional {
			let edges = Transition.Edge.allCases
			arrival.append(pop(edges.map { $0.rawValue },
			                   selected: edges.firstIndex(of: how.edge) ?? 0) { [weak self] pick in
				self?.replace(path, TimelineEntry(
					source: entry.source,
					transition: Transition(how.kind, seconds: how.seconds, edge: edges[pick]),
					label: entry.label, trim: entry.trim))
			})
			arrival.append(label("from"))
		}
		field("transition", arrival, note: advice(how))
	}

	/// What each kind is for, said once, where it is chosen.
	private func advice(_ how: Transition) -> String {
		switch how.kind {
		case .cut:
			return "an overlap of any kind takes the entry before this one with it — "
				+ "a section overlaps on its first clip"
		case .dissolve:
			return "the shot before stays up while this one comes in, "
				+ "and the programme is that much shorter"
		case .dipToBlack: return "out through black and back — black between two shots reads as time passing"
		case .dipToWhite: return "the same through white, which reads as a jump rather than a rest"
		case .wipe: return "a hard edge crossing the frame, this shot behind it"
		case .push: return "both shots move, as though the frame slid along to this one"
		case .slide: return "this shot slides in over the one before, which stays where it is"
		case .blur: return "both go soft, mix while they are soft, and come back sharp"
		case .flash: return "a dissolve with the frame blown out in the middle of it"
		case .iris: return "a circle opening from the middle — the oldest one there is"
		}
	}

	private func changeKind(_ path: [Int], _ entry: TimelineEntry, to index: Int) {
		// A card's description is a length rather than a name, and a length
		// makes a nonsense slug — so leaving one asks for a clip to be named.
		var name = entry.source.description
		if case .card = entry.source { name = "clip" }
		let replacement: TimelineEntry
		switch index {
		case 0: replacement = TimelineEntry(clip: ClipReference(name), transition: entry.transition)
		case 1: replacement = TimelineEntry(list: [ClipReference(name)], transition: entry.transition)
		case 2: replacement = (try? TimelineEntry(query: "#\(Slug.make(from: name))",
		                                          transition: entry.transition)) ?? entry
		case 3:
			if case .card = entry.source { return }
			// Four seconds of black, which is what somebody who has just asked
			// for a card is about to put a title on.
			replacement = TimelineEntry(card: Card(duration: 4), transition: entry.transition,
			                            label: entry.label)
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

	// MARK: - sound

	/// Everything a sound has: which file, when it plays, how loud, how it
	/// arrives and goes, and what it does to the programme underneath it.
	private func soundForm(_ origin: Origin, _ sound: Sound) {
		func change(_ edit: @escaping (inout Sound) -> Void) {
			var next = project
			next.editSound(at: origin) { edit(&$0) }
			commit(next)
		}

		section("what it is")
		field("file", [
			text(sound.file, width: 210, placeholder: "music/opening.wav") { value in
				change { $0.file = value.trimmingCharacters(in: .whitespaces) }
			},
			ellipsis("choose a sound file") { [weak self] _ in self?.chooseSound(origin) },
		], note: "relative to the project file, the same as the takes")

		section("when it plays")
		// The same three ways an overlay says when, in the same order and with
		// the same words, because it is the same question and the file spells
		// it the same way — and, for one written inside a timeline entry, the
		// fourth: nothing at all, which means that entry and no other use of it.
		let nested = Project.home(of: origin) != nil
		let spelt = ["whole clip", "inside a clip", "programme times"]
		let modes = nested ? ["this placement"] + spelt : spelt
		let offset = nested ? 1 : 0
		var mode = 0
		switch sound.span {
		case nil: mode = 0
		case .marks: mode = offset
		case .within: mode = offset + 1
		case .times: mode = offset + 2
		}
		var controls: [NSView] = [pop(modes, selected: mode) { [weak self] pick in
			guard let self, pick != mode else { return }
			guard pick >= offset else {
				change { $0.span = nil }
				return
			}
			// Converting from "this placement" needs something to convert, and
			// the programme is what knows where the placement is.
			let existing = sound.span
				?? self.resolved.flatMap { Project.extent(of: Project.home(of: origin) ?? [], in: $0) }
					.map { Overlay.Span.times(from: $0.start, to: $0.end) }
				?? .times(from: 0, to: 5)
			let converted = self.convert(existing, to: pick - offset)
			change { $0.span = converted }
		}]
		switch sound.span {
		case nil:
			controls.append(label("as long as this entry is on"))
		case .marks(let from, let to):
			controls.append(endpoint(from) { value in
				change { $0.span = .marks(from: .init(value), to: to) }
			})
			controls.append(endpoint(to) { value in
				change { $0.span = .marks(from: from, to: .init(value)) }
			})
		case .within(let mark, let from, let to):
			controls.append(endpoint(mark) { value in
				change { $0.span = .within(.init(value), from: from, to: to) }
			})
			controls.append(text(Timecode.string(from), width: 90, placeholder: "00:00.000") { value in
				guard let seconds = Timecode.parse(value) else { return }
				change { $0.span = .within(mark, from: seconds, to: to) }
			})
			controls.append(text(Timecode.string(to), width: 90, placeholder: "00:05.000") { value in
				guard let seconds = Timecode.parse(value) else { return }
				change { $0.span = .within(mark, from: from, to: seconds) }
			})
		case .times(let from, let to):
			controls.append(text(Timecode.string(from), width: 96, placeholder: "00:00.000") { value in
				guard let seconds = Timecode.parse(value) else { return }
				change { $0.span = .times(from: seconds, to: to) }
			})
			controls.append(text(Timecode.string(to), width: 96, placeholder: "00:30.000") { value in
				guard let seconds = Timecode.parse(value) else { return }
				change { $0.span = .times(from: from, to: seconds) }
			})
		}
		let advice: String
		switch sound.span {
		case nil: advice = "exactly this placement — the same shot used twice is two of them"
		case .marks: advice = "the whole of it, however long it turns out to be"
		case .within: advice = "so many seconds into that clip — it travels with the clip"
		case .times: advice = "the programme's own clock: moving anything leaves this behind"
		}
		field("when", controls, note: advice)
		if let extent = sound.span.flatMap({ extent(of: $0) })
			?? resolved.flatMap({ Project.extent(of: Project.home(of: origin) ?? [], in: $0) }) {
			field("", [label("\(Timecode.string(extent.0)) → \(Timecode.string(extent.1))"
				+ "  ·  \(TakeWriter.number(extent.1 - extent.0, places: 2))s")],
				note: "a sound shorter than that stops rather than starting again")
		}

		section("how it sounds")
		field("gain", [number(sound.gain, width: 72) { value in
			change { $0.gain = value }
		}, label("dB")], note: "applied to the file as it is — nought leaves it alone")
		fadeRow("in", sound.arrival) { transition in change { $0.arrival = transition } }
		fadeRow("out", sound.departure) { transition in change { $0.departure = transition } }
		field("ducks", [number(sound.ducks, width: 72) { value in
			change { $0.ducks = max(0, value) }
		}, label("dB")], note: sound.ducks > 0
			? "the programme's own sound goes under this one by that much, and comes "
				+ "back as it fades"
			: "nought for not at all — a sting under a cut wants none, music over "
				+ "somebody talking wants six or eight")
	}

	/// How a sound starts or stops. Only a fade means anything to a sound: it
	/// cannot slide in from the left.
	private func fadeRow(_ name: String, _ transition: Overlay.Transition,
	                     _ set: @escaping (Overlay.Transition) -> Void) {
		let fading: Bool
		if case .fade = transition { fading = true } else { fading = false }
		var controls: [NSView] = [pop(["straight in", "fade"], selected: fading ? 1 : 0) { pick in
			set(pick == 0 ? .cut : .fade(over: max(0.1, transition.duration)))
		}]
		if fading {
			controls.append(number(transition.duration, width: 60) { value in
				set(value > 0 ? .fade(over: value) : .cut)
			})
			controls.append(label("seconds"))
		}
		field(name, controls)
	}

	/// A sound file, chosen rather than typed, and written down the way the
	/// file wants it: relative to the project, because that is what lets a
	/// project and its music travel as one folder.
	private func chooseSound(_ origin: Origin) {
		let panel = NSOpenPanel()
		panel.canChooseFiles = true
		panel.canChooseDirectories = false
		panel.allowsMultipleSelection = false
		panel.message = "The sound to lay under the programme"
		guard panel.runModal() == .OK, let url = panel.url else { return }
		let base = resolved?.baseURL.standardizedFileURL.path
		var path = url.standardizedFileURL.path
		if let base, path.hasPrefix(base + "/") {
			path = String(path.dropFirst(base.count + 1))
		}
		var next = project
		next.editSound(at: origin) { $0.file = path }
		commit(next)
	}

	// MARK: - overlay

	private func overlayForm(_ origin: Origin, _ overlay: Overlay) {
		// An effect and a scene have no position of their own, so there is
		// nothing to drag them to: their parts carry their own.
		switch overlay.kind {
		case .effect, .scene, .film, .aberration, .tape: break
		default: full(placement(origin, overlay))
		}

		section("what it is")
		let kinds = ["text", "spinner", "bubble", "effect", "scene", "film", "aberration", "tape"]
		let current: Int
		switch overlay.kind {
		case .text: current = 0
		case .spinner: current = 1
		case .bubble: current = 2
		case .effect: current = 3
		case .scene: current = 4
		case .film: current = 5
		case .aberration: current = 6
		case .tape: current = 7
		}
		let firstScene = project.scenes.keys.sorted().first ?? "intro"
		// The shape a new film overlay closes to.
		//
		// Bars only appear where the programme is taller than what is asked
		// for, so offering 16:9 to a programme that already is 16:9 would be
		// offering nothing happening. A programme wider than that gets the
		// cinema shape; a taller one — anything cut for a phone — gets 16:9,
		// which is what "it goes to film" looks like there.
		let output = project.output.size
		let firstRatio = output.height > 0 && output.width / output.height >= 16.0 / 9
			? Film.Ratio(2.39, 1) : Film.Ratio(16, 9)
		field("kind", [pop(kinds, selected: current) { [weak self] pick in
			self?.editOverlay(origin) { overlay in
				switch (pick, overlay.kind) {
				case (0, .spinner(let spinner)):
					overlay.kind = .text(spinner.words.first?.text ?? "Caption", style: nil)
				case (0, .bubble(let bubble)):
					overlay.kind = .text(bubble.text, style: nil)
				case (0, .effect):
					overlay.kind = .text("Caption", style: nil)
				case (1, .text(let text, _)):
					overlay.kind = .spinner(Spinner(words: text.isEmpty ? [] : [SpinnerWord(text)]))
				case (1, .bubble(let bubble)):
					overlay.kind = .spinner(
						Spinner(words: bubble.text.isEmpty ? [] : [SpinnerWord(bubble.text)]))
				case (1, .effect):
					overlay.kind = .spinner(Spinner())
				case (2, .text(let text, let style)):
					// The words carry over, which is the whole of what somebody
					// means by turning a caption into a bubble.
					overlay.kind = .bubble(Bubble(text: text, style: style))
					overlay.arrival = .fade(over: 0.2)
					overlay.departure = .fade(over: 0.2)
					overlay.offset = Bubble.standoff
				case (2, .spinner(let spinner)):
					overlay.kind = .bubble(Bubble(text: spinner.words.first?.text ?? ""))
					overlay.arrival = .fade(over: 0.2)
					overlay.departure = .fade(over: 0.2)
					overlay.offset = Bubble.standoff
				case (2, _):
					overlay.kind = .bubble(Bubble(text: "still thinks glitter is a colour"))
					overlay.arrival = .fade(over: 0.2)
					overlay.departure = .fade(over: 0.2)
					overlay.offset = Bubble.standoff
				case (3, .text), (3, .spinner), (3, .scene), (3, .bubble):
					overlay.kind = .effect(Effect())
					// It arrives by falling into the frame, not by fading up.
					overlay.arrival = .cut
					overlay.departure = .fall(over: 1.5)
				case (4, _):
					overlay.kind = .scene(firstScene, with: [:])
				case (5, _):
					// The bars have to close on something narrower than the
					// programme or nothing happens, so the first choice is made
					// against what this programme actually is.
					overlay.kind = .film(Film(ratio: firstRatio))
					// It goes *to* film and comes back, which is a fade at each
					// end and is the whole point of the effect.
					overlay.arrival = .fade(over: 1)
					overlay.departure = .fade(over: 1)
				case (6, _):
					overlay.kind = .aberration(Aberration())
					overlay.arrival = .fade(over: 0.5)
					overlay.departure = .fade(over: 0.5)
				case (7, _):
					overlay.kind = .tape(Tape())
					overlay.arrival = .fade(over: 0.5)
					overlay.departure = .fade(over: 0.5)
				default: break
				}
			}
		}])

		switch overlay.kind {
		case .film(let film):
			func change(_ edit: @escaping (inout Film) -> Void) {
				self.editOverlay(origin) { overlay in
					guard case .film(var film) = overlay.kind else { return }
					edit(&film)
					overlay.kind = .film(film)
				}
			}
			let ratios = Film.Ratio.offered
			let known = ratios.firstIndex { $0 == film.ratio }
			field("ratio", [combo(film.ratio.written, values: ratios.map { $0.written }, width: 120) {
				[weak self] value in
				guard let ratio = Film.Ratio(value.trimmingCharacters(in: .whitespaces)) else {
					self?.rebuild()   // unreadable: put it back
					return
				}
				change { $0.ratio = ratio }
			}], note: known == nil
				? "w:h — the bars close in to this shape"
				: "the bars close in to this shape, and open again on the way out")
			field("film", [pop(Film.Tint.allCases.map { $0.rawValue },
			                   selected: Film.Tint.allCases.firstIndex(of: film.tint) ?? 0) { pick in
				change { $0.tint = Film.Tint.allCases[pick] }
			}], note: "the stock: what the colour goes to")
			field("strength", [number(film.strength, width: 72) { value in
				change { $0.strength = max(0, min(1, value)) }
			}], note: "how much of it, 0 to 1 — the grade is mixed in, not switched on")
			field("grain", [number(film.grain, width: 72) { value in
				change { $0.grain = max(0, min(1, value)) }
			}], note: "0 to 1, and it moves — grain that sits still is dirt on the lens")
			field("vignette", [number(film.vignette, width: 72) { value in
				change { $0.vignette = max(0, min(1, value)) }
			}], note: "how far the corners go down")

		case .aberration(let aberration):
			func change(_ edit: @escaping (inout Aberration) -> Void) {
				self.editOverlay(origin) { overlay in
					guard case .aberration(var aberration) = overlay.kind else { return }
					edit(&aberration)
					overlay.kind = .aberration(aberration)
				}
			}
			field("aberration", [pop(Aberration.Kind.allCases.map(\.rawValue),
			                         selected: Aberration.Kind.allCases.firstIndex(of: aberration.kind) ?? 0) {
				pick in change { $0.kind = Aberration.Kind.allCases[pick] }
			}], note: aberration.kind == .radial
				? "out from the middle, growing towards the edges — what a lens does"
				: "the same offset everywhere, along `angle`")
			field("amount", [number(aberration.amount, width: 72) { value in
				change { $0.amount = max(0, value) }
			}], note: "1 is about one per cent of the frame between red and blue, "
				+ "which is a great deal; a tenth of that reads as glass")
			if aberration.kind == .linear {
				field("angle", [number(aberration.angle, width: 72) { value in
					change { $0.angle = value }
				}, label("degrees")], note: "0 pulls red to the right and blue to the left")
			}

		case .tape(let tape):
			func change(_ edit: @escaping (inout Tape) -> Void) {
				self.editOverlay(origin) { overlay in
					guard case .tape(var tape) = overlay.kind else { return }
					edit(&tape)
					overlay.kind = .tape(tape)
				}
			}
			field("tape", [pop(Tape.Condition.allCases.map(\.rawValue),
			                   selected: Tape.Condition.allCases.firstIndex(of: tape.condition) ?? 0) {
				pick in
				// The condition fills all five knobs in, which is what makes it
				// a choice rather than a label: picking `chewed` after nudging
				// the jitter gives what chewed means, not what was left over.
				change { $0 = Tape(Tape.Condition.allCases[pick], seed: $0.seed) }
			}], note: "how the tape has been treated — it sets the five below")
			field("jitter", [number(tape.jitter, width: 72) { value in
				change { $0.jitter = max(0, min(1, value)) }
			}], note: "the tracking wobble: rows pushed sideways, by different amounts")
			field("band", [number(tape.band, width: 72) { value in
				change { $0.band = max(0, min(1, value)) }
			}], note: "the band of brighter noise crawling up the frame")
			field("chroma", [number(tape.chroma, width: 72) { value in
				change { $0.chroma = max(0, min(1, value)) }
			}], note: "colour arriving late, and so running off the edges sideways")
			field("scanlines", [number(tape.scanlines, width: 72) { value in
				change { $0.scanlines = max(0, min(1, value)) }
			}], note: "every other line, into shadow")
			field("dropouts", [number(tape.dropouts, width: 72) { value in
				change { $0.dropouts = max(0, min(1, value)) }
			}], note: "white streaks where the tape has lost its coating, a field at a time")
			field("seed", [number(Double(tape.seed), width: 72) { value in
				change { $0.seed = Int(value) }
			}], note: "the same number gives the same wobble, every render")

		case .scene(let name, let parameters):
			let names = project.scenes.keys.sorted()
			field("scene", [combo(name, values: names, width: 210) { [weak self] value in
				self?.editOverlay(origin) { $0.kind = .scene(Slug.make(from: value), with: parameters) }
			}], note: names.isEmpty
				? "no scenes yet — write one under `scenes:` in the text editor"
				: "parts moved by keyframes, defined once and used with different words")
			// The parameters this use fills in. One row each, and a blank one to
			// add another, so a scene's `{{title}}` is filled in without leaving
			// the panel.
			for name in parameters.keys.sorted() {
				field(name, [text(parameters[name] ?? "", width: 210, placeholder: "") {
					[weak self] value in
					self?.editOverlay(origin) { overlay in
						guard case .scene(let scene, var given) = overlay.kind else { return }
						given[name] = value
						overlay.kind = .scene(scene, with: given)
					}
				}])
			}
			let newName = NSTextField(string: "")
			field("with", [text("", width: 120, placeholder: "name") { [weak self] value in
				let key = value.trimmingCharacters(in: .whitespaces)
				guard !key.isEmpty else { return }
				self?.editOverlay(origin) { overlay in
					guard case .scene(let scene, var given) = overlay.kind else { return }
					given[key] = ""
					overlay.kind = .scene(scene, with: given)
				}
			}], note: "a parameter the scene asks for: `{{name}}` in one of its parts")
			_ = newName

		case .effect(let effect):
			field("effect", [pop(Effect.Style.allCases.map(\.rawValue),
			                     selected: Effect.Style.allCases.firstIndex(of: effect.style) ?? 0) {
				[weak self] pick in
				self?.editEffect(origin) { $0.style = Effect.Style.allCases[pick] }
			}], note: "thrown over the whole frame; it has no position and says nothing")
			field("finish", [pop(Effect.Finish.allCases.map(\.rawValue),
			                     selected: Effect.Finish.allCases.firstIndex(of: effect.finish) ?? 0) {
				[weak self] pick in
				self?.editEffect(origin) { $0.finish = Effect.Finish.allCases[pick] }
			}], note: "matte is printed card; metallic is foil; glitter is foil cut small")
			field("density", [number(effect.density, width: 72) { [weak self] value in
				self?.editEffect(origin) { $0.density = max(0.05, value) }
			}, label("× \(effect.count) pieces")])
			field("speed", [number(effect.speed, width: 72) { [weak self] value in
				self?.editEffect(origin) { $0.speed = max(0.05, value) }
			}], note: "2 falls twice as fast; 0.5 drifts")
			field("size", [number(effect.size, width: 72) { [weak self] value in
				self?.editEffect(origin) { $0.size = max(0.05, value) }
			}], note: "the size of each piece, not how many there are")
			if effect.style == .rain || effect.style == .snow {
				field("wind", [number(effect.wind, width: 72) { [weak self] value in
					self?.editEffect(origin) { $0.wind = max(-4, min(4, value)) }
				}], note: effect.style == .rain
					? "positive blows to the right, and the streaks lean into it"
					: "positive blows to the right; 1 is a good wind rather than a gale")
			}
			field("seed", [number(Double(effect.seed), width: 72) { [weak self] value in
				self?.editEffect(origin) { $0.seed = Int(value) }
			}], note: "the same number gives the same cloud, every render")
			var swatches: [NSView] = effect.palette.enumerated().map { position, colour in
				self.colour(colour) { [weak self] picked in
					self?.editEffect(origin) {
						guard position < $0.palette.count else { return }
						$0.palette[position] = picked
					}
				}
			}
			swatches.append(small("+") { [weak self] in
				self?.editEffect(origin) { $0.palette = $0.colours + [.white] }
			})
			if !effect.palette.isEmpty {
				swatches.append(small("−") { [weak self] in
					self?.editEffect(origin) { if !$0.palette.isEmpty { $0.palette.removeLast() } }
				})
			}
			field("palette", swatches,
			      note: effect.palette.isEmpty ? "the style's own colours" : nil)

		case .text(let content, let style):
			field("text", [text(content, width: 260, placeholder: "what it says") {
				[weak self] value in
				self?.editOverlay(origin) { $0.kind = .text(value, style: style) }
			}])
			field("style", [pop(styleNames,
			                    selected: styleNames.firstIndex(of: style ?? "lower-third") ?? 0) {
				[weak self] pick in
				guard let self else { return }
				self.editOverlay(origin) { $0.kind = .text(content, style: self.styleNames[pick]) }
			}], note: "defined under `styles:`, or one of the built-in four")

		case .bubble(let bubble):
			field("bubble", [text(bubble.text, width: 260, placeholder: "what they say") {
				[weak self] value in
				self?.editBubble(origin) { $0.text = value }
			}], note: "it wraps to `width` and the bubble grows to fit — no measuring by hand")
			field("shape", [pop(Bubble.Shape.allCases.map(\.rawValue),
			                    selected: Bubble.Shape.allCases.firstIndex(of: bubble.shape) ?? 0) {
				[weak self] pick in
				self?.editBubble(origin) { $0.shape = Bubble.Shape.allCases[pick] }
			}], note: "speech has a tail, thought has a trail of puffs, box has an arrow")
			field("style", [pop(styleNames,
			                    selected: styleNames.firstIndex(of: bubble.style ?? "bubble") ?? 0) {
				[weak self] pick in
				guard let self else { return }
				self.editBubble(origin) { $0.style = self.styleNames[pick] }
			}], note: "`bubble` is dark ink on nothing — a caption's white would be invisible")
			field("fill", [colour(bubble.fill) { [weak self] rgba in
				self?.editBubble(origin) { $0.fill = rgba }
			}, label("the paper")])
			field("line", [colour(bubble.line) { [weak self] rgba in
				self?.editBubble(origin) { $0.line = rgba }
			}, label("the drawn line")])
			field("width", [number(bubble.width, width: 72) { [weak self] value in
				self?.editBubble(origin) { $0.width = max(0.05, min(1, value)) }
			}, label("of frame width, at most")])
			field("seed", [number(Double(bubble.seed), width: 72) { [weak self] value in
				self?.editBubble(origin) { $0.seed = Int(value) }
			}], note: "the same number gives the same wobble, every render, on every machine")
			field("points at", [label(overlay.anchor.map { "the anchor `\($0)`" }
				?? (bubble.at.map { "the spot [\(Self.trimmed($0.x)), \(Self.trimmed($0.y))]" }
					?? "nothing — it keeps its words and loses its tail"))],
			      note: "an anchor is a face and follows it; `at:` is a fixed spot in the frame")

		case .spinner(let spinner):
			field("style", [pop(Spinner.Style.allCases.map(\.rawValue),
			                    selected: Spinner.Style.allCases.firstIndex(of: spinner.style) ?? 0) {
				[weak self] pick in
				self?.editSpinner(origin) { $0.style = Spinner.Style.allCases[pick] }
			}])
			field("size", [
				number(spinner.size, width: 72) { [weak self] value in
					self?.editSpinner(origin) { $0.size = max(0.01, value) }
				},
				label("of frame height"),
			])
			field("speed", [
				number(spinner.speed, width: 72) { [weak self] value in
					self?.editSpinner(origin) { $0.speed = value }
				},
				label("turns a second"),
			])
			field("color", [colour(spinner.color) { [weak self] rgba in
				self?.editSpinner(origin) { $0.color = rgba }
			}])

			section("words")
			for (position, word) in spinner.words.enumerated() {
				field(position == 0 ? "words" : "", [
					text(word.text, width: 170, placeholder: "what it says now") {
						[weak self] value in
						self?.editSpinner(origin) {
							guard position < $0.words.count else { return }
							$0.words[position].text = value
						}
					},
					text(word.duration.map { TakeWriter.number($0, places: 2) } ?? "",
					     width: 56, placeholder: "auto") { [weak self] value in
						self?.editSpinner(origin) {
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
						self?.editSpinner(origin) {
							guard position < $0.words.count else { return }
							$0.words.remove(at: position)
						}
					},
				])
			}
			field("", [small("+ word") { [weak self] in
				self?.editSpinner(origin) { $0.words.append(SpinnerWord("")) }
			}], note: spinner.words.isEmpty
				? "a spinner with no words only turns"
				: "they cycle for as long as the overlay is on screen")
		}

		keyframes(origin, overlay)

		section("when it is on")
		full(strip(origin, overlay))

		// One range at a time: the strip above is the list, and what is under it
		// is whichever range is selected there. Every range laid out at once was
		// four identical rows of controls with no way to tell which of them the
		// picture was about.
		if !overlay.appearances.isEmpty {
			let position = min(max(0, selectedSpan), overlay.appearances.count - 1)
			let appearance = overlay.appearances[position]
			let span = appearance.span
			let count = overlay.appearances.count
			// Three ways of saying when, in the order they should be reached
			// for: the whole of something, a stretch of something, and — last,
			// because it does not survive anything moving — the programme's own
			// clock.
			let modes = ["whole clip", "inside a clip", "programme times"]
			let mode: Int
			switch span {
			case .marks: mode = 0
			case .within: mode = 1
			case .times: mode = 2
			}

			var controls: [NSView] = [pop(modes, selected: mode) { [weak self] pick in
				guard let self, pick != mode else { return }
				self.setSpan(origin, position, self.convert(span, to: pick))
			}]

			switch span {
			case .within(let mark, let from, let to):
				controls.append(endpoint(mark) { [weak self] value in
					self?.setSpan(origin, position, .within(.init(value), from: from, to: to))
				})
				controls.append(text(Timecode.string(from), width: 90, placeholder: "00:00.000") {
					[weak self] value in
					guard let seconds = Timecode.parse(value) else { return }
					self?.setSpan(origin, position, .within(mark, from: seconds, to: to))
				})
				controls.append(text(Timecode.string(to), width: 90, placeholder: "00:05.000") {
					[weak self] value in
					guard let seconds = Timecode.parse(value) else { return }
					self?.setSpan(origin, position, .within(mark, from: from, to: seconds))
				})
				controls.append(ellipsis("when it is on") { [weak self] button in
					self?.openWithin(origin, position, mark, from: from, to: to, from: button)
				})
				controls.append(revert("the whole of that clip") { [weak self] in
					guard let self,
					      let where_ = self.extent(of: .marks(from: mark, to: mark)) else { return }
					self.setSpan(origin, position,
					             .within(mark, from: 0, to: max(0, where_.1 - where_.0)))
				})
			case .marks(let from, let to):
				controls.append(endpoint(from) { [weak self] value in
					self?.setSpan(origin, position, .marks(from: .init(value), to: to))
				})
				controls.append(endpoint(to) { [weak self] value in
					self?.setSpan(origin, position, .marks(from: from, to: .init(value)))
				})
			case .times(let from, let to):
				controls.append(text(Timecode.string(from), width: 96, placeholder: "00:00.000") {
					[weak self] value in
					guard let seconds = Timecode.parse(value) else { return }
					self?.setSpan(origin, position, .times(from: seconds, to: to))
				})
				controls.append(text(Timecode.string(to), width: 96, placeholder: "00:05.000") {
					[weak self] value in
					guard let seconds = Timecode.parse(value) else { return }
					self?.setSpan(origin, position, .times(from: from, to: seconds))
				})
				// The same dialog, over the whole programme, because the
				// programme's clock is what these two numbers are on.
				controls.append(ellipsis("when it is on") { [weak self] button in
					guard let self, let programme = self.programme?() else { return }
					TrimDialog.present(
						over: button, clip: "the programme",
						source: .programme(programme.composition, programme.videoComposition,
						                   programme.audioMix, duration: programme.duration),
						marks: .range, span: (start: 0, end: programme.duration),
						trim: (head: max(0, from), tail: max(0, programme.duration - to)),
						step: 1.0 / max(1, self.project.output.framesPerSecond),
						onDone: { [weak self] head, tail in
							self?.setSpan(origin, position, .times(
								from: head, to: max(head, programme.duration - tail)))
						})
				})
			}
			let advice: String
			switch span {
			case .marks: advice = "the whole of it, however long it turns out to be"
			case .within: advice = "so many seconds into that clip — it travels with the clip"
			case .times: advice = "the programme's own clock: moving anything leaves this behind"
			}
			field(count == 1 ? "when" : "when[\(position)]", controls, note: advice)

			var saysControls: [NSView] = []
			switch overlay.kind {
			case .effect:
				saysControls.append(label("an effect says nothing"))
			case .film:
				saysControls.append(label("film mode says nothing"))
			case .aberration:
				saysControls.append(label("an aberration says nothing"))
			case .tape:
				saysControls.append(label("a tape says nothing"))
			case .scene:
				saysControls.append(label("a scene says what its parameters say"))
			case .text(let content, _):
				saysControls.append(text(appearance.text ?? "", width: 220,
				                         placeholder: content.isEmpty ? "text" : content) {
					[weak self] value in
					self?.editOverlay(origin) {
						guard position < $0.appearances.count else { return }
						$0.appearances[position].text = value.isEmpty ? nil : value
					}
				})
			case .bubble(let bubble):
				saysControls.append(text(appearance.text ?? "", width: 220,
				                         placeholder: bubble.text.isEmpty ? "text" : bubble.text) {
					[weak self] value in
					self?.editOverlay(origin) {
						guard position < $0.appearances.count else { return }
						$0.appearances[position].text = value.isEmpty ? nil : value
					}
				})
			case .spinner(let spinner):
				let mine = appearance.words ?? []
				saysControls.append(text(mine.map(\.text).joined(separator: ", "), width: 220,
				                         placeholder: spinner.words.isEmpty
					                         ? "words"
					                         : spinner.words.map(\.text).joined(separator: ", ")) {
					[weak self] value in
					let said = value.split(separator: ",")
						.map { SpinnerWord($0.trimmingCharacters(in: .whitespaces)) }
						.filter { !$0.text.isEmpty }
					self?.editOverlay(origin) {
						guard position < $0.appearances.count else { return }
						$0.appearances[position].words = said.isEmpty ? nil : said
					}
				})
			}
			field(count == 1 ? "says" : "says[\(position)]", saysControls,
			      note: "blank says what the overlay says; a spinner that comes back usually says something else")

			var buttons: [NSView] = [small("+ range") { [weak self] in
				guard let self else { return }
				self.selectedSpan = count
				self.editOverlay(origin) { overlay in
					// The last range repeated, moved along by its own length
					// when it is a time, ready to be pointed somewhere else when
					// it is a mark. What it says is not copied — a second
					// appearance usually says something else.
					guard let last = overlay.appearances.last else { return }
					switch last.span {
					case .times(let from, let to):
						overlay.appearances.append(.init(.times(from: to, to: to + (to - from))))
					case .within(let mark, let from, let to):
						overlay.appearances.append(
							.init(.within(mark, from: to, to: to + (to - from))))
					case .marks:
						overlay.appearances.append(.init(last.span))
					}
				}
			}]
			if count > 1 {
				buttons.append(small("− range") { [weak self] in
					guard let self else { return }
					self.selectedSpan = max(0, position - 1)
					self.editOverlay(origin) {
						guard position < $0.appearances.count else { return }
						$0.appearances.remove(at: position)
					}
				})
			}
			field("", buttons, note: count == 1
				? "the same overlay, on over another stretch of the programme"
				: "\(count) ranges — the strip above chooses which one this is about")
		}

		section("how it arrives and leaves")
		let isEffect: Bool
		if case .effect = overlay.kind { isEffect = true } else { isEffect = false }
		transitionRow("arrival", overlay.arrival, at: overlay.arrivalPlacement,
		              usually: .after, { [weak self] transition in
			self?.editOverlay(origin) { $0.arrival = transition }
		}, sits: { [weak self] placement in
			self?.editOverlay(origin) { $0.arrivalPlacement = placement }
		}, canFall: false)
		transitionRow("departure", overlay.departure, at: overlay.departurePlacement,
		              usually: .before, { [weak self] transition in
			self?.editOverlay(origin) { $0.departure = transition }
		}, sits: { [weak self] placement in
			self?.editOverlay(origin) { $0.departurePlacement = placement }
		}, canFall: isEffect)

		section("where it sits")
		field("behind", [pop(Overlay.Occlusion.allCases.map(\.rawValue),
		                     selected: Overlay.Occlusion.allCases.firstIndex(of: overlay.behind) ?? 0) {
			[weak self] pick in
			self?.editOverlay(origin) { $0.behind = Overlay.Occlusion.allCases[pick] }
		}], note: "`people` puts it behind whoever is in the frame — found on this machine, "
			+ "and it costs a pass per frame")
		field("anchor", [combo(overlay.anchor ?? "", values: [""] + vocabulary.anchors, width: 210) {
			[weak self] value in
			let name = value.trimmingCharacters(in: .whitespaces)
			self?.editOverlay(origin) { $0.anchor = name.isEmpty ? nil : Slug.make(from: name) }
		}], note: "a tracked face: the overlay follows it, and the style's position is ignored")
		field("offset", [
			number(overlay.offset.x, width: 72) { [weak self] value in
				self?.editOverlay(origin) { $0.offset.x = value }
			},
			number(overlay.offset.y, width: 72) { [weak self] value in
				self?.editOverlay(origin) { $0.offset.y = value }
			},
		], note: "x and y from the anchor, both in fractions of the frame height")
	}

	private var styleNames: [String] {
		// What the project defines, and the built-ins under the one spelling
		// each — `builtIn` answers to more than it offers.
		Array(Set(project.styles.keys).union(TextStyle.offered)).sorted()
	}

	/// One end of an overlay: how it moves, for how long, and where that
	/// movement sits against the mark.
	///
	/// The placement popup is offered beside the length and only where there is
	/// a length — a cut is an instant and has nothing to place, which is the
	/// same reason the file leaves `at:` off one.
	///
	/// `usually` is where this end's movement sits when nobody says, and it is a
	/// different word at the two ends — `after` the first mark, `before` the
	/// last. The note is written from it rather than from the row's name,
	/// because that asymmetry is the one thing somebody will meet and not
	/// believe, and it deserves saying where the choice is made rather than
	/// being measured out of a render.
	private func transitionRow(_ name: String, _ transition: Overlay.Transition,
	                           at placement: Overlay.Transition.Placement,
	                           usually: Overlay.Transition.Placement,
	                           _ set: @escaping (Overlay.Transition) -> Void,
	                           sits: @escaping (Overlay.Transition.Placement) -> Void,
	                           canFall: Bool = false) {
		// "Fall" is offered for effects only: a caption cannot run out, and a
		// spinner has nothing to run out of.
		let kinds = canFall ? ["cut", "fade", "slide", "fall"] : ["cut", "fade", "slide"]
		let current: Int
		switch transition {
		case .cut: current = 0
		case .fade: current = 1
		case .slide: current = 2
		case .fall: current = 3
		}
		var controls: [NSView] = [pop(kinds, selected: min(current, kinds.count - 1)) { pick in
			switch pick {
			case 0: set(.cut)
			case 1: set(.fade(over: max(0.1, transition.duration)))
			case 2: set(.slide(.left, over: max(0.1, transition.duration)))
			default: set(.fall(over: max(0.4, transition.duration)))
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
				case .fall: set(.fall(over: max(0, value)))
				case .cut: break
				}
			})
			controls.append(label(
				{ if case .fall = transition { return "seconds to empty" } else { return "seconds" } }()))
			let places = Overlay.Transition.Placement.allCases
			controls.append(pop(places.map(\.title),
			                    selected: places.firstIndex(of: placement) ?? 0) { pick in
				sits(places[pick])
			})
		}
		field(name, controls, note: transition.duration > 0
			? (usually == .after
				? "`\(usually.title)` by default: it starts moving when the clip does. "
					+ "`before` finishes it there, so the overlay is already fully on for "
					+ "the clip's first frame"
				: "`\(usually.title)` by default: it has finished leaving by the time the "
					+ "clip ends. `after` starts it there, so the overlay is still going "
					+ "when the next one is up")
			: "an instant, so there is nothing to place either side of the mark")
	}

	// MARK: - what moves

	/// The keys the overlay's parameters move on.
	///
	/// The scene inspector's idiom, deliberately: a list of keys with the time
	/// and the easing on each, what that key *states* summarised beside it, and
	/// the selected one opened up into a row per parameter. A value that came
	/// from the key before is shown dim and in brackets — still there to read
	/// and still typeable, because typing it is exactly how somebody claims it —
	/// rather than as a number they wrote.
	///
	/// Only for the kinds that have anything to move. What each of them can and
	/// cannot move, and why, is `Overlay.Kind.animatable`; the note at the
	/// bottom of this section says the awkward half of it out loud, because the
	/// panel is where somebody will look for `seed` and not find it.
	private func keyframes(_ origin: Origin, _ overlay: Overlay) {
		let parameters = overlay.kind.animatable
		guard !parameters.isEmpty else { return }
		section("what moves")

		guard !overlay.keys.isEmpty else {
			field("keys", [small("Make it move") { [weak self] in
				guard let self else { return }
				let length = self.span(of: origin)
				// Chosen before the edit, not after: committing rebuilds the
				// form, and a selection set afterwards would not be seen until
				// the next thing somebody did.
				self.selectedKey = 1
				self.editKeys(origin) { keys in
					// Two, because one key is a value and two are a movement.
					// The first states nothing, so it is whatever the overlay
					// above already says; the second states the one knob
					// somebody most likely came here to change, at what it
					// currently is, so there is a number to type over.
					keys = [Overlay.Key(t: 0), Overlay.Key(t: length)]
					if let principal = overlay.kind.principal {
						keys[1][principal] = overlay.kind.declared(principal)
					}
				}
			}], note: "the numbers above are what it is for the whole of its span. "
				+ "Keys make them move: `t` in seconds from the start of each "
				+ "appearance, and a key states only what changes.")
			cannotMove(overlay)
			return
		}

		let chosen = min(max(0, selectedKey), overlay.keys.count - 1)
		for (position, key) in overlay.keys.enumerated() {
			let pick = small(position == chosen ? "●" : "○") { [weak self] in
				self?.selectedKey = position
				self?.rebuild()
			}
			pick.toolTip = "Work on this key"
			let time = number(key.t, width: 56) { [weak self] value in
				self?.editKeys(origin) { keys in
					guard position < keys.count else { return }
					keys[position].t = max(0, value)
				}
			}
			let ease = pop(Scene.Ease.allCases.map(\.rawValue),
			               selected: Scene.Ease.allCases.firstIndex(of: key.ease) ?? 3) {
				[weak self] picked in
				self?.editKeys(origin) { keys in
					guard position < keys.count else { return }
					keys[position].ease = Scene.Ease.allCases[picked]
				}
			}
			let said = parameters.filter { key[$0] != nil }.map(\.rawValue).joined(separator: " ")
			let drop = small("−") { [weak self] in
				self?.editKeys(origin) { keys in
					guard position < keys.count else { return }
					keys.remove(at: position)
				}
			}
			drop.toolTip = "Take this key out"

			let row = NSStackView(views: [
				pick, time, ease, label(said.isEmpty ? "inherits everything" : said),
				NSView(), drop,
			])
			row.orientation = .horizontal
			row.spacing = 5
			row.alignment = .centerY
			add(row)

			guard position == chosen else { continue }
			let filled = overlay.inherited(_:)
			for parameter in parameters {
				add(keyRow(parameter, of: key, at: position, in: origin,
				           inherited: filled(parameter)[position]))
			}
		}

		field("", [small("+ key") { [weak self] in
			guard let self else { return }
			let length = self.span(of: origin)
			self.selectedKey = overlay.keys.count
			self.editKeys(origin) { keys in
				let last = keys.map(\.t).max() ?? 0
				// Half way to the end of the span if there is any left, and a
				// second past the last one if there is not.
				keys.append(Overlay.Key(t: last < length ? (last + length) / 2 : last + 1))
			}
		}], note: "a key states only what changes. Everything else is what it was "
			+ "at the key before, which is why an effect that only speeds up says "
			+ "its speed twice and nothing else at all.")
		cannotMove(overlay)
	}

	/// One parameter of one key: the number, and whether it is this key's or
	/// the one before it's.
	private func keyRow(_ parameter: Overlay.Parameter, of key: Overlay.Key,
	                    at position: Int, in origin: Origin, inherited: Double) -> NSView {
		let stated = key[parameter]
		let name = NSTextField(labelWithString: parameter.rawValue)
		name.font = Theme.mono
		name.textColor = stated == nil ? Theme.faintText : Theme.text
		name.translatesAutoresizingMaskIntoConstraints = false
		let wide = name.widthAnchor.constraint(equalToConstant: 78)
		wide.priority = NSLayoutConstraint.Priority(900)
		wide.isActive = true
		_ = squeezable(name)

		let shown = stated ?? inherited
		let box = text(TakeWriter.number(shown, places: 3), width: 66, placeholder: "—") {
			[weak self] value in
			let cleaned = value.trimmingCharacters(in: .whitespaces)
				.replacingOccurrences(of: ",", with: ".")
			self?.setKey(origin, position, parameter, cleaned.isEmpty ? nil : Double(cleaned))
		}
		if stated == nil {
			box.textColor = Theme.faintText
			box.stringValue = "(\(TakeWriter.number(shown, places: 3)))"
		}

		let button = small(stated == nil ? "set" : "inherit") { [weak self] in
			self?.setKey(origin, position, parameter, stated == nil ? shown : nil)
		}
		button.toolTip = stated == nil
			? "State this here, at what it already is"
			: "Take it back to whatever the key before says"

		let row = NSStackView(views: [name, box, button, NSView()])
		row.orientation = .horizontal
		row.spacing = 5
		row.alignment = .centerY
		row.edgeInsets = NSEdgeInsets(top: 0, left: 22, bottom: 0, right: 0)
		return row
	}

	/// What is not in the list above, said where somebody will look for it.
	private func cannotMove(_ overlay: Overlay) {
		let message: String
		switch overlay.kind {
		case .effect:
			message = "`seed` is not here and cannot be: the same number gives the "
				+ "same cloud on every render, which is the whole of what it is for. "
				+ "Nor is the style, the finish or the palette — there is nothing "
				+ "half way between two names."
		case .tape:
			message = "`seed` is not here and cannot be: the same number gives the "
				+ "same wobble on every render. Nor is the condition, which is a "
				+ "name rather than a number — it sets the five knobs, and those move."
		case .film:
			message = "The stock is not here: there is nothing half way between "
				+ "`warm` and `noir`. Cross-fade a second film overlay over this one."
		case .aberration:
			message = "Which kind it is is not here: `radial` and `linear` are two "
				+ "different things rather than two ends of one."
		case .text, .spinner, .scene, .bubble:
			return
		}
		remark(message)
	}

	/// How long this overlay is on, for the range a new key is placed in.
	/// Two seconds when the programme has not resolved and there is nothing to
	/// ask — a number to type over rather than a refusal.
	private func span(of origin: Origin) -> Double {
		let found = resolved?.overlays.first {
			$0.origin == origin && $0.appearance == selectedSpan
		}?.duration
		return max(0.5, found ?? 2)
	}

	private func editKeys(_ origin: Origin, _ change: (inout [Overlay.Key]) -> Void) {
		editOverlay(origin) { overlay in
			change(&overlay.keys)
			// Kept in time order here rather than at read time: the file keeps
			// whatever order somebody wrote, and this is the one place that
			// makes a new order.
			overlay.keys.sort { $0.t < $1.t }
		}
	}

	private func setKey(_ origin: Origin, _ position: Int,
	                    _ parameter: Overlay.Parameter, _ value: Double?) {
		editKeys(origin) { keys in
			guard position < keys.count else { return }
			keys[position][parameter] = value
		}
	}

	private func editOverlay(_ origin: Origin, _ change: (inout Overlay) -> Void) {
		var next = project
		next.editOverlay(at: origin, change)
		commit(next)
	}

	private func editEffect(_ origin: Origin, _ change: (inout Effect) -> Void) {
		editOverlay(origin) { overlay in
			guard case .effect(var effect) = overlay.kind else { return }
			change(&effect)
			overlay.kind = .effect(effect)
		}
	}

	private func editBubble(_ origin: Origin, _ change: (inout Bubble) -> Void) {
		editOverlay(origin) { overlay in
			guard case .bubble(var bubble) = overlay.kind else { return }
			change(&bubble)
			overlay.kind = .bubble(bubble)
		}
	}

	/// A number as somebody would write it, for the one-line answers above.
	static func trimmed(_ value: CGFloat) -> String {
		value == value.rounded() ? String(Int(value)) : String(format: "%g", Double(value))
	}

	private func editSpinner(_ origin: Origin, _ change: (inout Spinner) -> Void) {
		editOverlay(origin) { overlay in
			guard case .spinner(var spinner) = overlay.kind else { return }
			change(&spinner)
			overlay.kind = .spinner(spinner)
		}
	}

	/// The same range, said a different way.
	///
	/// Kept as close to what it was as the new form allows: a stretch of a clip
	/// becomes the whole of that clip, the whole of a clip becomes a stretch
	/// covering it, and either becomes the programme times it currently
	/// occupies. Nobody has to type the numbers again to change their mind.
	private func convert(_ span: Overlay.Span, to mode: Int) -> Overlay.Span {
		let extent = self.extent(of: span) ?? (0, 5)
		let mark: Overlay.Span.Endpoint
		switch span {
		case .marks(let from, _): mark = from
		case .within(let within, _, _): mark = within
		case .times:
			// Whichever clip the range starts in — the honest guess when the
			// file said nothing about material at all.
			let clip = (resolved?.clips ?? []).last { $0.start <= extent.0 + 0.001 }
				?? resolved?.clips.first
			mark = .clip(clip?.reference ?? ClipReference("clip"))
		}

		switch mode {
		case 0:
			return .marks(from: mark, to: mark)
		case 1:
			let start = self.extent(of: .marks(from: mark, to: mark))?.0 ?? 0
			return .within(mark, from: max(0, extent.0 - start), to: max(0, extent.1 - start))
		default:
			return .times(from: extent.0, to: extent.1)
		}
	}

	/// The trim dialog, on the placement this row is about.
	///
	/// The frames used to be in the form, under the two fields. Wrong twice:
	/// at that size a frame says somebody is in shot and nothing finer, and a
	/// cut is not found by looking at stills anyway — it is found by watching
	/// the second before the mark with the sound on. So the dialog gets the
	/// take's own media and plays it.
	private func openTrim(
		_ path: [Int], _ reference: ClipReference, _ entry: TimelineEntry, from view: NSView
	) {
		// Which placement this is: the same clip used twice is two of them, and
		// the media and the marks must be the ones this use shows.
		guard let placed = resolved?.clips.first(where: { $0.entry == path }) else { return }
		// The clip as the take has it, before this placement's trim — which is
		// what the dialog lets somebody move about inside.
		let span = (start: placed.clip.start - entry.trim.head,
		            end: placed.clip.end + entry.trim.tail)

		TrimDialog.present(
			over: view, clip: reference.description,
			source: .media(video: placed.videoURL, audio: placed.audioURL,
			               offset: placed.audioOffset),
			span: span, trim: entry.trim,
			step: 1.0 / max(1, project.output.framesPerSecond),
			onDone: { [weak self] head, tail in
				self?.replace(path, TimelineEntry(
					clip: reference, transition: entry.transition, label: entry.label,
					trim: (head, tail)))
			})
	}

	/// The same dialog as a trim, over the programme rather than over a take.
	///
	/// A `when:` written as `within` is two marks inside one stretch of the
	/// programme, which is exactly what the trim dialog sets — so it is the
	/// same dialog, told that the marks are called `from` and `to` and that the
	/// picture comes from the cut programme. Set against the programme on
	/// purpose: an overlay's moment is a moment with the other overlays and the
	/// dissolves in it, and against the bare take it would be guesswork again.
	private func openWithin(
		_ origin: Origin, _ position: Int, _ mark: Overlay.Span.Endpoint,
		from: Double, to: Double, from view: NSView
	) {
		guard let where_ = extent(of: .marks(from: mark, to: mark)),
		      let programme = self.programme?() else { return }
		let length = max(0.001, where_.1 - where_.0)

		TrimDialog.present(
			over: view, clip: mark.description,
			source: .programme(programme.composition, programme.videoComposition,
			                   programme.audioMix, duration: programme.duration),
			marks: .range, span: (start: where_.0, end: where_.1),
			// Held as offcuts by the dialog: how far in from each end.
			trim: (head: max(0, from), tail: max(0, length - to)),
			step: 1.0 / max(1, project.output.framesPerSecond),
			onDone: { [weak self] head, tail in
				self?.setSpan(origin, position,
				              .within(mark, from: head, to: max(head, length - tail)))
			})
	}

	private func setSpan(_ origin: Origin, _ position: Int, _ span: Overlay.Span) {
		editOverlay(origin) { overlay in
			guard position < overlay.appearances.count else { return }
			overlay.appearances[position].span = span
		}
	}

	// MARK: - When it is on

	/// The programme with this overlay's ranges lying over it, draggable.
	private func strip(_ origin: Origin, _ overlay: Overlay) -> NSView {
		let strip = SpanStrip()
		currentStrip = strip
		strip.duration = resolved?.duration ?? 0
		strip.blocks = (resolved?.clips ?? []).map {
			SpanStrip.Block(start: $0.start, end: $0.end, name: $0.clip.slug)
		}
		strip.ranges = overlay.appearances.map { appearance in
			let extent = self.extent(of: appearance.span) ?? (0, 0)
			return SpanStrip.Range(start: extent.0, end: extent.1,
			                       movable: movable(appearance.span))
		}
		strip.selected = min(max(0, selectedSpan), max(0, overlay.spans.count - 1))
		strip.onSelect = { [weak self] position in
			self?.selectedSpan = position
			self?.stripHadFocus = true
		}
		strip.onDelete = { [weak self] position in
			self?.editOverlay(origin) { overlay in
				// The last one is not deleted: an overlay that is on over
				// nothing is not an overlay, it is a puzzle.
				guard overlay.appearances.count > 1,
				      position < overlay.appearances.count else { return }
				overlay.appearances.remove(at: position)
			}
		}
		strip.onScrub = { [weak self] time in
			self?.stripHadFocus = true
			self?.scrub(to: time)
		}
		strip.onDrag = { [weak self] position, start, end in
			guard let self, position < overlay.spans.count else { return }
			self.selectedSpan = position
			self.setSpan(origin, position,
			             self.span(from: overlay.appearances[position].span, start: start, end: end))
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
		case .within(let mark, let from, let to):
			guard let where_ = self.extent(of: .marks(from: mark, to: mark)) else { return nil }
			return (where_.0 + from, where_.0 + to)
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
		case .times, .within: return true
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
		case .within(let mark, _, _):
			// Dragged on the programme, written down against the clip: the
			// numbers that go in the file are still "so many seconds into that
			// shot".
			guard let where_ = self.extent(of: .marks(from: mark, to: mark)) else { return existing }
			return .within(mark, from: max(0, start - where_.0), to: max(0, end - where_.0))
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
	private func placement(_ origin: Origin, _ overlay: Overlay) -> NSView {
		let preview = FramePreview()
		currentPreview = preview
		preview.aspect = project.output.size

		let found = resolved?.overlays.first { $0.origin == origin }
		let anchor = found?.path?.point(at: found?.start ?? 0)
		preview.anchorPoint = anchor
		preview.anchorName = overlay.anchor

		switch overlay.kind {
		case .effect, .scene, .film, .aberration, .tape:
			// Never reached: none of them has a placement picture at all.
			preview.content = .caption("", TextStyle.caption)
		case .text(let content, let style):
			preview.content = .caption(content, project.style(named: style))
		case .bubble(let bubble):
			// The words, in the bubble's own style. The paper is not drawn here:
			// what the picture is for is where the thing sits, and a bubble sits
			// where its words do.
			preview.content = .caption(bubble.text, project.style(named: bubble.style ?? "bubble"))
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
			self?.place(origin, overlay, at: spot, anchor: anchor)
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
		// A bubble with a fixed spot to point at stands off from *that*, the
		// same way an anchored one stands off from the face.
		if case .bubble(let bubble) = overlay.kind, let at = bubble.at {
			return CGPoint(x: at.x + overlay.offset.x * ratio, y: at.y + overlay.offset.y)
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
	private func place(_ origin: Origin, _ overlay: Overlay, at spot: CGPoint, anchor: CGPoint?) {
		let ratio = project.output.size.width / max(1, project.output.size.height)
		if let anchor {
			editOverlay(origin) {
				$0.offset = CGPoint(x: (spot.x - anchor.x) * ratio, y: spot.y - anchor.y)
			}
			return
		}
		if case .bubble(let bubble) = overlay.kind, let at = bubble.at {
			editOverlay(origin) {
				$0.offset = CGPoint(x: (spot.x - at.x) * ratio, y: spot.y - at.y)
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
			next.editOverlay(at: origin) { $0.kind = .text(content, style: name) }
			commit(next)
			return
		}
		editOverlay(origin) { $0.offset = CGPoint(x: spot.x - 0.5, y: spot.y - 0.5) }
	}

	// MARK: - Rows

	/// Adds a row and makes it as wide as the form. Every row in this panel is
	/// exactly one of these, so there is one place where width is decided.
	private func add(_ row: NSView) {
		form.addArrangedSubview(row)
		row.translatesAutoresizingMaskIntoConstraints = false
		row.widthAnchor.constraint(equalTo: form.widthAnchor, constant: -28).isActive = true
	}

	/// A heading, a `?`, and a hairline running to the far edge.
	///
	/// The `?` is where the explanations went. Every field in this panel carried
	/// three lines of grey prose under it, permanently — good writing, printed
	/// for ever, and most of the reason the column felt space-demanding. Not one
	/// word of it is gone: it is the field's tooltip, and it is all here behind
	/// this button, keyed by the field it explains. Printed once when somebody
	/// asks, rather than always because somebody might.
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
		rule.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)

		let header = NSStackView(views: [label, ask, rule])
		header.orientation = .horizontal
		header.spacing = 6
		header.alignment = .centerY
		header.edgeInsets = NSEdgeInsets(
			top: form.arrangedSubviews.isEmpty ? 0 : 8, left: 0, bottom: 0, right: 0)
		add(header)
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
		text.textContainer?.containerSize = NSSize(width: 340, height: CGFloat.greatestFiniteMagnitude)
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

		// The explanation, said twice and printed neither time: on the row, so
		// resting on it says it, and under the heading's `?`, so all of them can
		// be read at once.
		guard let note else { return }
		row.toolTip = note
		name.toolTip = note
		for control in controls where control.toolTip == nil { control.toolTip = note }
		help?.lines.append((key, note))
		help?.button?.isHidden = false
	}

	/// A remark that is not about one key.
	///
	/// The few places that say "the thing you are looking for is not here, and
	/// this is why". That is not an explanation of a field somebody can rest on
	/// — there is no field — so it stays printed.
	private func remark(_ message: String) { add(caption(message)) }

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

	/// What an overlay hangs on, shown whole and changed in a dialog.
	///
	/// It was a combo box, which had two faults that came from the same place:
	/// it showed `clip-4` — the short form the file writes — so with several
	/// takes open there was no telling which `clip-4` it meant, and its menu
	/// listed the clips and the sections but not the placements somebody had
	/// named with `as:`, which are exactly the things a second use of one shot
	/// needs to point at. Both are the picker's problem now; this is the button
	/// that opens it, showing take and clip whatever the file says.
	private func endpoint(_ mark: Overlay.Span.Endpoint,
	                      only kinds: Set<EndpointCatalogue.Entry.Kind>? = nil,
	                      onPick: @escaping (String) -> Void) -> NSButton {
		let catalogue = kinds.map { EndpointCatalogue(vocabulary).only($0) }
			?? EndpointCatalogue(vocabulary)
		let button = NSButton()
		// The ellipsis is a picture on the trailing edge rather than three dots
		// on the end of the name — which is what a truncated name looks like,
		// and a control whose value might be cut off is one nobody trusts.
		button.image = NSImage(systemSymbolName: "ellipsis",
		                       accessibilityDescription: "choose")?
			.withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
		button.imagePosition = .imageTrailing
		button.bezelStyle = .rounded
		button.controlSize = .small
		button.attributedTitle = NSAttributedString(
			string: catalogue.path(for: mark) + " ",
			attributes: [
				.font: Theme.mono,
				// A name that is not in the project is said so in red rather
				// than shown as if it were fine: a renamed slug is the
				// commonest thing to go wrong with a `when:`.
				.foregroundColor: catalogue.knows(mark) ? Theme.text : Theme.playhead,
			])
		button.lineBreakMode = .byTruncatingHead
		let sink = Sink { [weak button] _ in
			guard let button else { return }
			EndpointPicker.present(over: button, catalogue: catalogue,
			                       current: mark.description, onChoose: onPick)
		}
		sinks.append(sink)
		button.target = sink
		button.action = #selector(Sink.fire(_:))
		return squeezable(button)
	}

	/// Put it back the way it was. Marked with the system's own undo arrow, so
	/// it is not read as a button that deletes something.
	private func revert(_ what: String, onTap: @escaping () -> Void) -> NSButton {
		let button = NSButton()
		button.image = NSImage(systemSymbolName: "arrow.uturn.backward",
		                       accessibilityDescription: "reset")?
			.withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
		button.imagePosition = .imageOnly
		button.bezelStyle = .rounded
		button.controlSize = .small
		button.toolTip = what
		let sink = Sink { _ in onTap() }
		sinks.append(sink)
		button.target = sink
		button.action = #selector(Sink.fire(_:))
		return squeezable(button)
	}

	/// The button that opens a dialog. One shape for all of them, so `…` means
	/// the same thing everywhere in this panel.
	private func ellipsis(_ what: String, onTap: @escaping (NSView) -> Void) -> NSButton {
		let button = NSButton()
		button.image = NSImage(systemSymbolName: "ellipsis",
		                       accessibilityDescription: "choose")?
			.withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
		button.imagePosition = .imageOnly
		button.bezelStyle = .rounded
		button.controlSize = .small
		button.toolTip = what
		let sink = Sink { [weak button] _ in
			guard let button else { return }
			onTap(button)
		}
		sinks.append(sink)
		button.target = sink
		button.action = #selector(Sink.fire(_:))
		return squeezable(button)
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
