import AppKit
import CuttrCompose
import CuttrKit

/// Editing the project, and learning its file format while you do.
///
/// Two panels and a pane. The programme on the left is structure — what plays,
/// in what order, inside which section, with what drawn over it. The properties
/// on the right are everything about whatever is selected there, labelled with
/// the **key it writes** rather than a friendly paraphrase. Underneath them, the
/// YAML that selection produces, live, straight out of the emitter that writes
/// the file.
///
/// A normal user never has to open the text. Everything the format can express
/// is reachable from these controls, which is the point: the file is for
/// refactoring, for copying a section between projects, for handing to an
/// editor or to a model — not the only way in. And because the panel shows what
/// it writes as it writes it, somebody who does open the file already knows
/// what they are looking at.
@MainActor
public final class ProjectInspector: NSView {

	/// A whole project, edited. The window applies and saves it.
	public var onChange: ((Project) -> Void)?

	/// The programme as it resolved, and a way to get a frame out of it. Both
	/// belong to the window — this panel only passes them to the properties,
	/// which is where a picture of the overlay is worth having.
	public var resolved: ResolvedProject? {
		didSet { properties.resolved = resolved }
	}
	public var poster: ((Double, @escaping (NSImage?) -> Void) -> Void)? {
		didSet { properties.poster = poster }
	}
	/// Somebody is placing a range at this moment. The window takes the preview
	/// there, so what plays and what is being edited are the same moment.
	public var onScrub: ((Double) -> Void)? {
		didSet { properties.onScrub = onScrub }
	}

	private let programme = ProgrammePanel()
	private let properties = PropertiesPanel()
	private let yaml = NSTextView()
	private let writesTitle = NSTextField(labelWithString: "WHAT THIS WRITES")

	private var project = Project()
	private var selection: ProjectSelection = .output

	public override init(frame: NSRect) {
		super.init(frame: frame)
		wantsLayer = true
		layer?.backgroundColor = Theme.panel.cgColor

		programme.onChange = { [weak self] project in self?.onChange?(project) }
		programme.onSelect = { [weak self] selection in
			guard let self else { return }
			self.selection = selection
			self.properties.reload(self.project, vocabulary: self.vocabulary, selection: selection)
			self.showWhatItWrites()
		}
		properties.onChange = { [weak self] project in self?.onChange?(project) }

		// The properties fill the column and the file fragment sits under them at
		// a fixed height.
		//
		// Not a split view. Two panes that both size themselves from their
		// contents is a negotiation, and this one oscillated: the text pane grew,
		// the form re-laid out, the text pane shrank, and the window flickered
		// while it was resized. A footer of a stated height cannot argue.
		let column = NSView()
		let writes = self.writes()
		for view in [properties, writes] as [NSView] {
			view.translatesAutoresizingMaskIntoConstraints = false
			column.addSubview(view)
		}
		NSLayoutConstraint.activate([
			properties.topAnchor.constraint(equalTo: column.topAnchor),
			properties.leadingAnchor.constraint(equalTo: column.leadingAnchor),
			properties.trailingAnchor.constraint(equalTo: column.trailingAnchor),
			properties.bottomAnchor.constraint(equalTo: writes.topAnchor),

			writes.leadingAnchor.constraint(equalTo: column.leadingAnchor),
			writes.trailingAnchor.constraint(equalTo: column.trailingAnchor),
			writes.bottomAnchor.constraint(equalTo: column.bottomAnchor),
			writes.heightAnchor.constraint(equalToConstant: 168),
		])

		let split = NSSplitView()
		split.isVertical = true
		split.dividerStyle = .thin
		split.addArrangedSubview(programme)
		split.addArrangedSubview(column)
		split.translatesAutoresizingMaskIntoConstraints = false
		addSubview(split)

		let wide = programme.widthAnchor.constraint(equalToConstant: 620)
		wide.priority = NSLayoutConstraint.Priority(250)
		wide.isActive = true
		NSLayoutConstraint.activate([
			split.topAnchor.constraint(equalTo: topAnchor),
			split.bottomAnchor.constraint(equalTo: bottomAnchor),
			split.leadingAnchor.constraint(equalTo: leadingAnchor),
			split.trailingAnchor.constraint(equalTo: trailingAnchor),
			programme.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),
			column.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
		])
	}

	@available(*, unavailable) required init?(coder: NSCoder) { nil }

	private var vocabulary = ComposeDocument.Vocabulary()

	// MARK: - what this writes

	private func writes() -> NSView {
		writesTitle.font = Theme.heading
		writesTitle.textColor = Theme.faintText

		yaml.isEditable = false
		yaml.drawsBackground = true
		yaml.backgroundColor = Theme.background
		yaml.textColor = Theme.text
		yaml.font = Theme.monoSmall
		yaml.textContainerInset = NSSize(width: 8, height: 8)
		yaml.isVerticallyResizable = true
		yaml.isHorizontallyResizable = false
		yaml.autoresizingMask = [.width]
		yaml.textContainer?.widthTracksTextView = true

		let scroll = TableScroll.wrap(yaml, horizontal: false)
		let holder = NSView()
		holder.wantsLayer = true
		holder.layer?.backgroundColor = Theme.panel.cgColor

		for view in [writesTitle, scroll] as [NSView] {
			view.translatesAutoresizingMaskIntoConstraints = false
			holder.addSubview(view)
		}
		NSLayoutConstraint.activate([
			writesTitle.topAnchor.constraint(equalTo: holder.topAnchor, constant: 10),
			writesTitle.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 14),

			scroll.topAnchor.constraint(equalTo: writesTitle.bottomAnchor, constant: 6),
			scroll.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 14),
			scroll.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -14),
			scroll.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -12),
		])
		return holder
	}

	/// Straight out of the emitter that writes the file, so what is shown here
	/// is what will be on disk — not a paraphrase of it.
	private func showWhatItWrites() {
		switch selection {
		case .overlay(let index) where index < project.overlays.count:
			yaml.string = ProjectWriter.fragment(for: project.overlays[index])
		case .entry(let path):
			yaml.string = project.entry(at: path).map { ProjectWriter.fragment(for: $0) } ?? ""
		default:
			yaml.string = ProjectWriter.fragment(for: project.output)
		}
	}

	// MARK: - Loading

	public func reload(_ project: Project, vocabulary: ComposeDocument.Vocabulary) {
		self.project = project
		self.vocabulary = vocabulary
		programme.reload(project, vocabulary: vocabulary)
		properties.reload(project, vocabulary: vocabulary, selection: selection)
		showWhatItWrites()
	}

	/// Puts a reference from the library on the programme.
	public func insert(reference: String) { programme.insert(reference: reference) }
}
