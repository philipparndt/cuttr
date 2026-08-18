import AppKit
import CuttrCompose

/// The project file itself, edited in the window.
///
/// The point of the whole program is that a project is text somebody can read
/// and change, so it would be strange for the one place you cannot read it to be
/// the program that wrote it. This is the same file an external editor would
/// open — the panel next door is a way of writing it, and this is the thing
/// being written.
///
/// It checks as you type. An invalid file says why on the line you are on rather
/// than when you try to save, which is the difference between learning a format
/// and guessing at it.
@MainActor
public final class ProjectTextEditor: NSView {

	/// Valid text somebody asked to keep.
	public var onApply: ((String) -> Void)?

	private let text = NSTextView()
	private let status = NSTextField(labelWithString: "")
	private let apply = NSButton()
	private var loaded = ""

	public override init(frame: NSRect) {
		super.init(frame: frame)
		wantsLayer = true
		layer?.backgroundColor = Theme.background.cgColor

		text.isEditable = true
		text.isRichText = false
		text.allowsUndo = true
		text.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
		text.backgroundColor = Theme.background
		text.textColor = Theme.text
		text.insertionPointColor = Theme.playhead
		text.textContainerInset = NSSize(width: 8, height: 8)
		text.isVerticallyResizable = true
		text.isHorizontallyResizable = false
		text.autoresizingMask = [.width]
		text.textContainer?.widthTracksTextView = true
		// Off, all of it. Smart quotes turn `"` into `"` and the file stops
		// parsing; autocorrect rewrites slugs. This is source, not prose.
		text.isAutomaticQuoteSubstitutionEnabled = false
		text.isAutomaticDashSubstitutionEnabled = false
		text.isAutomaticTextReplacementEnabled = false
		text.isAutomaticSpellingCorrectionEnabled = false
		text.delegate = self

		let scroll = NSScrollView()
		scroll.hasVerticalScroller = true
		scroll.drawsBackground = false
		scroll.documentView = text
		scroll.translatesAutoresizingMaskIntoConstraints = false

		status.font = Theme.monoSmall
		status.lineBreakMode = .byTruncatingTail

		apply.title = "Apply"
		apply.bezelStyle = .rounded
		apply.controlSize = .small
		apply.font = NSFont.systemFont(ofSize: 11)
		apply.target = self
		apply.action = #selector(applyTapped)
		apply.isEnabled = false

		let revert = NSButton()
		revert.title = "Revert"
		revert.bezelStyle = .rounded
		revert.controlSize = .small
		revert.font = NSFont.systemFont(ofSize: 11)
		revert.target = self
		revert.action = #selector(revertTapped)

		let bar = NSStackView(views: [apply, revert, status])
		bar.orientation = .horizontal
		bar.spacing = 6
		bar.alignment = .centerY
		bar.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
		bar.translatesAutoresizingMaskIntoConstraints = false
		status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

		addSubview(scroll)
		addSubview(bar)
		NSLayoutConstraint.activate([
			bar.topAnchor.constraint(equalTo: topAnchor),
			bar.leadingAnchor.constraint(equalTo: leadingAnchor),
			bar.trailingAnchor.constraint(equalTo: trailingAnchor),
			bar.heightAnchor.constraint(equalToConstant: 30),
			scroll.topAnchor.constraint(equalTo: bar.bottomAnchor),
			scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
			scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
			scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
		])
	}

	@available(*, unavailable) required init?(coder: NSCoder) { nil }

	/// Puts the file in front of somebody.
	///
	/// Refuses while they are part-way through an edit: the project is re-read
	/// whenever anything writes it, and replacing the text under a cursor would
	/// lose whatever was being typed.
	public func show(_ source: String) {
		guard text.string == loaded || text.string.isEmpty else { return }
		loaded = source
		text.string = source
		check()
	}

	public var hasUnappliedEdits: Bool { text.string != loaded }

	@objc private func applyTapped() {
		guard (try? ProjectReader.read(text.string)) != nil else { return }
		loaded = text.string
		onApply?(text.string)
	}

	@objc private func revertTapped() {
		text.string = loaded
		check()
	}

	/// Parses on every keystroke and says what is wrong.
	private func check() {
		let edited = hasUnappliedEdits
		do {
			_ = try ProjectReader.read(text.string)
			apply.isEnabled = edited
			status.textColor = edited ? Theme.base(.amber) : Theme.dimText
			status.stringValue = edited ? "valid — not applied yet" : "saved"
		} catch {
			apply.isEnabled = false
			status.textColor = Theme.playhead
			status.stringValue = error.localizedDescription
		}
	}
}

extension ProjectTextEditor: NSTextViewDelegate {
	public func textDidChange(_ notification: Notification) { check() }
}
