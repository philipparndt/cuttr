import AppKit
import CuttrCompose
import CuttrKit

/// The head of the properties panel: **the thing, and what it depends on.**
///
/// It used to say `TIMELINE ENTRY` — the name of a type, which is the one fact
/// about a selection that nobody needs. What somebody wants from the top of
/// this panel is what the whole window is for: *this* clip, out of *that* take,
/// inside *that* section, carrying *that* caption. The resolver knows all four,
/// and every one of them is a place to go, so every one of them is a button.
///
/// A line for the thing and a line for each relationship, rather than one line
/// of them separated by dots. The dots were the nicer sentence and they do not
/// survive a 380-point column: something has to truncate, and a reference
/// somebody cannot read is a reference they cannot click.
@MainActor
public final class SubjectLine: NSView {

	/// One thing this selection depends on, or that depends on it.
	public struct Relation {
		/// `from`, `in`, `carries`, `over`, `follows` — the preposition, which
		/// is what says *which way* the dependency runs.
		public var lead: String
		public var name: String
		public var kind: Theme.Kind?
		/// Where clicking goes. `nil` for a fact that is not a place.
		public var action: (() -> Void)?

		public init(_ lead: String, _ name: String, kind: Theme.Kind? = nil,
		            action: (() -> Void)? = nil) {
			self.lead = lead
			self.name = name
			self.kind = kind
			self.action = action
		}
	}

	private let symbol = NSImageView()
	private let subject = NSTextField(labelWithString: "")
	private let rows = NSStackView()
	/// A target is unowned, so the closures are held here.
	private var sinks: [Sink] = []

	private final class Sink: NSObject {
		let run: () -> Void
		init(_ run: @escaping () -> Void) { self.run = run }
		@objc func fire() { run() }
	}

	public override init(frame: NSRect) {
		super.init(frame: frame)

		subject.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
		subject.textColor = Theme.text
		subject.lineBreakMode = .byTruncatingTail
		subject.setContentCompressionResistancePriority(
			NSLayoutConstraint.Priority(1), for: .horizontal)

		symbol.translatesAutoresizingMaskIntoConstraints = false
		symbol.imageScaling = .scaleNone
		NSLayoutConstraint.activate([
			symbol.widthAnchor.constraint(equalToConstant: 15),
			symbol.heightAnchor.constraint(equalToConstant: 15),
		])

		let head = NSStackView(views: [symbol, subject])
		head.orientation = .horizontal
		head.spacing = 5
		head.alignment = .centerY

		rows.orientation = .vertical
		rows.alignment = .leading
		rows.spacing = 1
		rows.setHuggingPriority(.required, for: .vertical)

		let column = NSStackView(views: [head, rows])
		column.orientation = .vertical
		column.alignment = .leading
		column.spacing = 3
		column.translatesAutoresizingMaskIntoConstraints = false
		addSubview(column)
		// Pinned at the top and given the width; the panel decides the height,
		// so nothing in here can argue with it.
		NSLayoutConstraint.activate([
			column.topAnchor.constraint(equalTo: topAnchor),
			column.leadingAnchor.constraint(equalTo: leadingAnchor),
			column.trailingAnchor.constraint(equalTo: trailingAnchor),
			column.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
			head.widthAnchor.constraint(equalTo: column.widthAnchor),
		])
	}

	@available(*, unavailable) required init?(coder: NSCoder) { nil }

	/// What is selected, and what it hangs off.
	public func show(_ name: String, kind: Theme.Kind?, relations: [Relation]) {
		subject.stringValue = name
		symbol.image = kind.flatMap { Theme.symbol($0, size: 12) }
		symbol.isHidden = symbol.image == nil

		sinks.removeAll()
		for row in rows.arrangedSubviews {
			rows.removeArrangedSubview(row)
			row.removeFromSuperview()
		}
		for relation in relations.prefix(3) { rows.addArrangedSubview(view(for: relation)) }
	}

	/// `in  @question1` — the preposition dim, the reference in the accent
	/// because a reference is a reference everywhere in this program, and
	/// underlined on hover because it goes somewhere.
	private func view(for relation: Relation) -> NSView {
		let text = NSMutableAttributedString(
			string: relation.lead + " ",
			attributes: [.font: Theme.monoSmall, .foregroundColor: Theme.faintText])
		text.append(NSAttributedString(
			string: relation.name,
			attributes: [.font: Theme.monoSmall,
			             .foregroundColor: relation.action == nil
				? Theme.dimText
				: (relation.kind.map { Theme.color($0) } ?? Theme.accent)]))

		let button = NSButton()
		button.isBordered = false
		button.bezelStyle = .inline
		button.attributedTitle = text
		button.alignment = .left
		button.lineBreakMode = .byTruncatingTail
		button.setContentCompressionResistancePriority(
			NSLayoutConstraint.Priority(1), for: .horizontal)
		if let action = relation.action {
			let sink = Sink(action)
			sinks.append(sink)
			button.target = sink
			button.action = #selector(Sink.fire)
			button.toolTip = "Go to \(relation.name)"
		} else {
			button.isEnabled = false
		}
		return button
	}

	/// For the tests: what the head says, line by line.
	var linesForTesting: [String] {
		[subject.stringValue] + rows.arrangedSubviews.compactMap {
			($0 as? NSButton)?.attributedTitle.string
		}
	}

	/// For the tests: the relationship buttons, to click without a window.
	var relationButtonsForTesting: [NSButton] {
		rows.arrangedSubviews.compactMap { $0 as? NSButton }
	}
}
