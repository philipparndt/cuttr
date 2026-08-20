import AppKit
import CuttrKit

/// The strip along the top of both windows.
///
/// One bar, learned once. Three things in it and nothing else: **which
/// document** on the left, **the clock** in the middle, **what just happened**
/// on the right, with the progress of whatever is happening underneath it.
///
/// The test for anything else that wanted to live up here is whether it is true
/// in every mode. Choosing the video file is not — it is done once, at the
/// start, and belongs behind the take's name. A checkbox for markers over the
/// picture is not — there is no picture in two of the three modes. Both used to
/// be in a bar; neither is now.
///
/// The clock is the reason this view exists at all. Somebody watching wants to
/// know where they are, always, in both windows, in the same place — and the
/// two bars this replaces each had their own answer, one of which was to let a
/// status message overwrite it.
@MainActor
public final class DocumentBar: NSView {

	/// The height both windows give it.
	public static let height: CGFloat = 38

	/// The setting-up controls, shown in a popover from the document's name.
	///
	/// Behind the name rather than in the bar because that is what they are
	/// about: which files this take is made of, and how they line up. Set once,
	/// checked occasionally, and in the way for the rest of the session.
	public var setUp: NSView? {
		didSet {
			name.isEnabled = setUp != nil
			setName(documentName)
		}
	}

	private var documentName = ""
	private let name = NSButton()
	private let clock = NSTextField(labelWithString: "00:00.000")
	private let statusLabel = NSTextField(labelWithString: "")
	private let progress = NSProgressIndicator()
	/// One slot on the far right for a verb that belongs to the whole document
	/// rather than to a mode. The composing window's `Render…` is the only
	/// tenant; everything else that was in a bar found a home nearer the thing
	/// it acts on.
	private let trailing = NSStackView()
	/// The same, on the near side of the clock, for a switch that says which of
	/// the document's modes is showing until the rail takes it over.
	private let leading = NSStackView()
	private var popover: NSPopover?

	public override init(frame: NSRect) {
		super.init(frame: frame)
		wantsLayer = true
		layer?.backgroundColor = Theme.panel.cgColor

		name.isBordered = false
		name.isEnabled = false
		name.bezelStyle = .inline
		name.imagePosition = .noImage
		name.target = self
		name.action = #selector(showSetUp)
		name.setContentCompressionResistancePriority(
			NSLayoutConstraint.Priority(1), for: .horizontal)

		// Tabular figures, and a width that never changes.
		//
		// Proportional digits shift under the eye at every frame, and a label
		// that sizes itself to its text moves the whole group sideways between
		// `09.900` and `10.000`. So: monospaced digits in a box wide enough for
		// the longest time this program can show, and the text centred in it.
		clock.font = NSFont.monospacedDigitSystemFont(ofSize: 17, weight: .medium)
		clock.textColor = Theme.text
		clock.alignment = .center
		clock.translatesAutoresizingMaskIntoConstraints = false
		let widest = ("0:00:00.000" as NSString)
			.size(withAttributes: [.font: clock.font as Any]).width
		clock.widthAnchor.constraint(equalToConstant: ceil(widest) + 2).isActive = true

		statusLabel.font = Theme.monoSmall
		statusLabel.textColor = Theme.dimText
		statusLabel.alignment = .right
		statusLabel.lineBreakMode = .byTruncatingTail
		statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

		progress.style = .bar
		progress.isIndeterminate = false
		progress.minValue = 0
		progress.maxValue = 1
		progress.controlSize = .small
		progress.isHidden = true

		for stack in [leading, trailing] {
			stack.orientation = .horizontal
			stack.spacing = 6
			stack.alignment = .centerY
		}

		for view in [name, leading, clock, statusLabel, progress, trailing] as [NSView] {
			view.translatesAutoresizingMaskIntoConstraints = false
			addSubview(view)
		}

		// The clock is centred on the *window* rather than on what is left over,
		// so it does not shuffle sideways as the name beside it changes length.
		let centred = clock.centerXAnchor.constraint(equalTo: centerXAnchor)
		centred.priority = .defaultHigh
		centred.isActive = true

		// The status sits above the middle and its progress directly under it,
		// so the bar looks the same whether or not something is being counted.
		// A progress indicator that appears *beside* a label pushes the label,
		// and then every message that arrives with one arrives in a different
		// place.
		NSLayoutConstraint.activate([
			name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
			name.centerYAnchor.constraint(equalTo: centerYAnchor),

			leading.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 14),
			leading.centerYAnchor.constraint(equalTo: centerYAnchor),

			clock.centerYAnchor.constraint(equalTo: centerYAnchor),
			clock.leadingAnchor.constraint(greaterThanOrEqualTo: leading.trailingAnchor, constant: 12),

			trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
			trailing.centerYAnchor.constraint(equalTo: centerYAnchor),

			statusLabel.trailingAnchor.constraint(equalTo: trailing.leadingAnchor, constant: -10),
			statusLabel.leadingAnchor.constraint(
				greaterThanOrEqualTo: clock.trailingAnchor, constant: 12),
			statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -4),
			statusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 420),

			progress.trailingAnchor.constraint(equalTo: statusLabel.trailingAnchor),
			progress.widthAnchor.constraint(equalToConstant: 110),
			progress.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 2),
			progress.heightAnchor.constraint(equalToConstant: 4),
		])
		setName("")
	}

	@available(*, unavailable) required init?(coder: NSCoder) { nil }

	// MARK: - State in

	/// Which document this window is about.
	public func setName(_ text: String) {
		documentName = text
		let chevron = setUp == nil ? "" : "  ⌄"
		name.attributedTitle = NSAttributedString(
			string: text + chevron,
			attributes: [.font: Theme.bodyStrong,
			             .foregroundColor: setUp == nil ? Theme.dimText : Theme.text])
		name.toolTip = setUp == nil ? nil : "What this take is made of, and how the two line up"
	}

	/// Where the playhead is. Always, in every mode — that is the point.
	public func setClock(_ seconds: Double) {
		clock.stringValue = Timecode.string(seconds)
	}

	public func setStatus(_ text: String) { statusLabel.stringValue = text }

	/// `nil` puts the bar away.
	public func setProgress(_ fraction: Double?) {
		progress.isHidden = fraction == nil
		if let fraction { progress.doubleValue = fraction }
	}

	/// Adds a document-level verb to the far right.
	public func addTrailing(_ view: NSView) { trailing.addView(view, in: .trailing) }

	/// Adds a control just after the document's name.
	public func addLeading(_ view: NSView) { leading.addView(view, in: .trailing) }

	// MARK: - The popover behind the name

	@objc private func showSetUp() {
		guard let content = setUp else { return }
		if let popover, popover.isShown { popover.close(); return }
		let holder = NSViewController()
		holder.view = content
		let showing = NSPopover()
		showing.contentViewController = holder
		showing.behavior = .transient
		showing.appearance = NSAppearance(named: .darkAqua)
		popover = showing
		showing.show(relativeTo: name.bounds, of: name, preferredEdge: .maxY)
	}

	/// For the tests: the clock's own label, so its width can be measured
	/// without going through the view tree looking for a font.
	var clockForTesting: NSTextField { clock }
	var nameForTesting: NSButton { name }
	var statusForTesting: NSTextField { statusLabel }
	var progressForTesting: NSProgressIndicator { progress }
}
