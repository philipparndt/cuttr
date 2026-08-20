import AppKit

/// What a pane says when there is nothing in it yet.
///
/// A block in the middle of the empty area rather than a caption near the top:
/// an icon, the name of what is missing, one sentence about it, and — only when
/// it earns its place — something to press.
///
/// The shape matters because of what an empty pane *is*. It is not a list that
/// happens to have no rows; it is a state, and the commonest reason a program
/// looks broken is that it is empty and says so in the same grey as everything
/// else. One line of faint text twenty-four points below the top reads as a
/// caption about a list. Three sizes stacked in the middle of the room read as
/// the answer to "what am I looking at".
///
/// So: a tinted mark at 32, the subject in near-full text at 15 semibold, and
/// the sentence in grey at 12, wrapped to a narrow measure — it breaks long
/// before the pane does, because a sentence set to the full width of a pane is
/// a sentence nobody's eye can return from.
///
/// No panel behind it. The ground is the ground; a rounded rectangle here would
/// be a box drawn around nothing.
@MainActor
public final class EmptyState: NSView {

	/// Something to press. Kept optional, and kept rare: a button earns its
	/// place here by being the thing somebody would otherwise hunt for. One that
	/// repeats a control already on screen — the `＋` directly above this pane,
	/// an item in the rail — teaches somebody that the program says everything
	/// twice.
	public struct Action {
		public var title: String
		public var symbol: String
		public var run: () -> Void

		public init(_ title: String, _ symbol: String, run: @escaping () -> Void) {
			self.title = title
			self.symbol = symbol
			self.run = run
		}
	}

	private let mark = NSImageView()
	private let subject = NSTextField(labelWithString: "")
	private let sentence = NSTextField(labelWithString: "")
	private let buttons = NSStackView()
	private var sinks: [Sink] = []

	private final class Sink: NSObject {
		let run: () -> Void
		init(_ run: @escaping () -> Void) { self.run = run }
		@objc func fire() { run() }
	}

	/// How wide the sentence may run before it wraps: about forty-five
	/// characters at this size, which is a line the eye can come back from.
	private static let measure: CGFloat = 300

	public init(_ kind: Theme.Kind, _ subject: String, _ sentence: String,
	            actions: [Action] = []) {
		super.init(frame: .roomToLayOutIn)
		translatesAutoresizingMaskIntoConstraints = false

		mark.image = Theme.symbol(kind, size: 32)
		mark.imageScaling = .scaleNone

		self.subject.stringValue = subject
		self.subject.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
		self.subject.textColor = Theme.text
		self.subject.alignment = .center

		self.sentence.stringValue = sentence
		self.sentence.font = NSFont.systemFont(ofSize: 12, weight: .regular)
		self.sentence.textColor = Theme.dimText
		self.sentence.alignment = .center
		self.sentence.lineBreakMode = .byWordWrapping
		self.sentence.maximumNumberOfLines = 0
		self.sentence.preferredMaxLayoutWidth = Self.measure

		buttons.orientation = .horizontal
		buttons.spacing = 8
		buttons.alignment = .centerY
		for action in actions { buttons.addArrangedSubview(button(for: action)) }
		buttons.isHidden = actions.isEmpty

		let column = NSStackView(views: [mark, self.subject, self.sentence, buttons])
		column.orientation = .vertical
		column.alignment = .centerX
		column.spacing = 10
		column.setCustomSpacing(14, after: mark)
		column.setCustomSpacing(6, after: self.subject)
		column.setCustomSpacing(16, after: self.sentence)
		column.translatesAutoresizingMaskIntoConstraints = false
		addSubview(column)
		NSLayoutConstraint.activate([
			// The middle of the room, both ways.
			column.centerXAnchor.constraint(equalTo: centerXAnchor),
			column.centerYAnchor.constraint(equalTo: centerYAnchor),
			column.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
			column.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
			self.sentence.widthAnchor.constraint(lessThanOrEqualToConstant: Self.measure),
		])
	}

	@available(*, unavailable) required init?(coder: NSCoder) { nil }

	/// A rounded rectangle with a hairline and a fill barely off the ground, a
	/// small mark before its words.
	private func button(for action: Action) -> NSButton {
		let button = NSButton()
		button.bezelStyle = .rounded
		button.controlSize = .regular
		button.image = NSImage(systemSymbolName: action.symbol,
		                       accessibilityDescription: action.title)?
			.withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
		button.imagePosition = .imageLeading
		button.title = action.title
		button.font = NSFont.systemFont(ofSize: 12)
		let sink = Sink(action.run)
		sinks.append(sink)
		button.target = sink
		button.action = #selector(Sink.fire)
		return button
	}

	/// For the tests: what it says, top to bottom.
	var linesForTesting: [String] { [subject.stringValue, sentence.stringValue] }
	var markForTesting: NSImageView { mark }
	var buttonsForTesting: [NSButton] { buttons.arrangedSubviews.compactMap { $0 as? NSButton } }
}
