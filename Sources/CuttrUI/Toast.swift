import AppKit

/// Something the program has to say that nobody asked about.
///
/// **Why not the status line.** Everything this program said, it said in one
/// line at the top of the window — small, grey, and replaced by the next thing.
/// A share that refused because a take window was open said so there, and the
/// report that came back was that the button did nothing. A message somebody
/// has to be looking at to see is a message that was not delivered.
///
/// **Why not an alert.** A modal takes the keyboard, stops everything, and
/// demands to be dismissed before the sentence in it can be acted on. For "sent
/// your changes" that is absurd, and for "close the take window first" it is in
/// the way of doing exactly that.
///
/// So: the corner of the window, for a few seconds, stacked newest at the
/// bottom, gone by itself. The idea and its shape are abydos's; the colours and
/// the wording rules are this program's.
public struct Toast: Sendable {

	public enum Kind: Sendable {
		/// It did not happen and somebody has to do something.
		case refusal
		/// It happened.
		case done
		/// Worth knowing, worth nothing else.
		case news

		var symbol: String {
			switch self {
			case .refusal: return "exclamationmark.triangle.fill"
			case .done: return "checkmark.circle.fill"
			case .news: return "info.circle.fill"
			}
		}

		var tint: NSColor {
			switch self {
			case .refusal: return Theme.playhead
			case .done: return Theme.color(.clip)
			case .news: return Theme.accent
			}
		}

		/// How long it stays.
		///
		/// A refusal names something to be done and outlives a glance; the rest
		/// are read at the edge of the eye or not at all. Neither waits for a
		/// gesture: a message that has to be dismissed is a modal wearing a
		/// different coat.
		var lifetime: TimeInterval {
			switch self {
			case .refusal: return 10
			case .done, .news: return 4
			}
		}
	}

	public var kind: Kind
	/// One line, read at a glance from the corner of the eye.
	public var title: String

	public init(_ kind: Kind, _ title: String) {
		self.kind = kind
		self.title = title
	}
}

/// Shows toasts in the corner of a window, newest at the bottom.
@MainActor
public final class ToastPresenter {

	private weak var window: NSWindow?
	private var host: NSStackView?
	private var shown: [ToastView] = []

	/// Four. Past that the oldest goes, because a column of them up the side of
	/// the window is a wall rather than a message.
	private static let mostAtOnce = 4

	/// What has been said in this window, oldest first.
	///
	/// **A toast is drawn for a few seconds and is gone**, so a test that looks
	/// a moment later cannot tell "nothing was said" from "it was said and
	/// faded" — and those are the two answers that matter when the complaint is
	/// that a button did nothing. abydos keeps this list for the same reason.
	public private(set) var saidForTesting: [String] = []

	public init(window: NSWindow?) {
		self.window = window
	}

	/// Whether this is the presenter for that window.
	///
	/// A document moves between places — that is the whole model — so a
	/// presenter made when it was in one window would go on putting its toasts
	/// on that one after it had moved.
	func isFor(_ other: NSWindow?) -> Bool { other != nil && window === other }

	public func show(_ toast: Toast) {
		saidForTesting.append(toast.title)
		guard let content = window?.contentView else { return }

		let host = self.host ?? {
			let made = NSStackView()
			made.orientation = .vertical
			made.alignment = .trailing
			made.spacing = 8
			made.translatesAutoresizingMaskIntoConstraints = false
			content.addSubview(made, positioned: .above, relativeTo: nil)
			NSLayoutConstraint.activate([
				made.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
				made.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
				made.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
			])
			self.host = made
			return made
		}()

		let view = ToastView(toast)
		view.onDismiss = { [weak self, weak view] in
			guard let view else { return }
			self?.take(away: view)
		}
		host.addArrangedSubview(view)
		shown.append(view)
		// The host is added once and everything since sits above it, so it is
		// raised each time rather than only when it was made.
		host.superview?.addSubview(host, positioned: .above, relativeTo: nil)

		while shown.count > Self.mostAtOnce, let oldest = shown.first {
			take(away: oldest)
		}

		let lifetime = toast.kind.lifetime
		Timer.scheduledTimer(withTimeInterval: lifetime, repeats: false) { [weak self, weak view] _ in
			MainActor.assumeIsolated {
				guard let view else { return }
				self?.take(away: view)
			}
		}
	}

	private func take(away view: ToastView) {
		shown.removeAll { $0 === view }
		view.removeFromSuperview()
		if shown.isEmpty {
			host?.removeFromSuperview()
			host = nil
		}
	}

	/// For a window going away: a toast hanging over a window that has closed
	/// outlives what it was about.
	public func clear() {
		for view in shown { view.removeFromSuperview() }
		shown = []
		host?.removeFromSuperview()
		host = nil
	}
}

/// One toast, drawn.
@MainActor
final class ToastView: NSView {

	var onDismiss: (() -> Void)?

	/// What it says, kept so it can be copied. A message somebody has to
	/// retype into a report is a message that reaches the report from memory.
	private let said: String

	init(_ toast: Toast) {
		said = toast.title
		super.init(frame: .zero)
		wantsLayer = true
		layer?.backgroundColor = Theme.cardHigh.cgColor
		layer?.cornerRadius = 7
		layer?.borderWidth = 1
		layer?.borderColor = toast.kind.tint.withAlphaComponent(0.5).cgColor

		let mark = NSImageView()
		mark.image = NSImage(systemSymbolName: toast.kind.symbol, accessibilityDescription: nil)?
			.withSymbolConfiguration(.init(pointSize: 12, weight: .semibold)
				.applying(.init(paletteColors: [toast.kind.tint])))
		mark.translatesAutoresizingMaskIntoConstraints = false

		let words = NSTextField(labelWithString: toast.title)
		words.font = Theme.body
		words.textColor = Theme.text
		words.lineBreakMode = .byWordWrapping
		words.maximumNumberOfLines = 3
		words.preferredMaxLayoutWidth = 280
		words.translatesAutoresizingMaskIntoConstraints = false

		for view in [mark, words] as [NSView] { addSubview(view) }
		NSLayoutConstraint.activate([
			mark.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
			mark.topAnchor.constraint(equalTo: topAnchor, constant: 11),
			mark.widthAnchor.constraint(equalToConstant: 14),

			words.leadingAnchor.constraint(equalTo: mark.trailingAnchor, constant: 8),
			words.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
			words.topAnchor.constraint(equalTo: topAnchor, constant: 9),
			words.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
		])
	}

	@available(*, unavailable) required init?(coder: NSCoder) { nil }

	/// Clicking it puts it away. The only gesture it answers: a toast that
	/// needed reading has been read by the time somebody reaches for it.
	override func mouseDown(with event: NSEvent) { onDismiss?() }

	/// Except this one. A refusal is on screen for ten seconds and is often the
	/// exact sentence a report should quote, so it can be taken rather than
	/// remembered — and taking it does not put the toast away, because reading
	/// the words again is the next thing anybody does.
	override func menu(for event: NSEvent) -> NSMenu? {
		let menu = NSMenu()
		let item = NSMenuItem(title: "Copy", action: #selector(copySaid), keyEquivalent: "")
		item.target = self
		menu.addItem(item)
		return menu
	}

	@objc private func copySaid() {
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(said, forType: .string)
	}
}
