import AppKit

/// The list of keys, in a window that can hold it.
///
/// It was an `NSAlert` with the list in `informativeText`, and that was three
/// wrong things at once. The list is **aligned with spaces** — a key, then a
/// column, then what it does — so a proportional font tears every column apart.
/// An alert does not scroll, so two thirds of it were off the bottom of the
/// screen with no way to reach them. And an alert is modal, which is the wrong
/// shape for a reference: the whole point of looking up a key is to use it, and
/// a sheet you must dismiss first means reading it, closing it, and hoping you
/// remembered.
///
/// So: a panel, in the fixed-width face the list was written for, scrolling,
/// resizable, and not modal. One instance, because ⌘/ twice is somebody looking
/// for the window they already have open.
@MainActor
public final class ShortcutsPanel: NSPanel {

	private static var shared: ShortcutsPanel?

	/// Shows it, or brings the one that is already open to the front.
	public static func present(_ text: String) {
		let panel = shared ?? ShortcutsPanel(text: text)
		shared = panel
		panel.center()
		panel.makeKeyAndOrderFront(nil)
	}

	private init(text: String) {
		super.init(contentRect: NSRect(x: 0, y: 0, width: 660, height: 680),
		           styleMask: [.titled, .closable, .resizable, .utilityWindow],
		           backing: .buffered, defer: false)
		title = "Keys"
		isFloatingPanel = true
		hidesOnDeactivate = false
		isReleasedWhenClosed = false

		let view = NSTextView()
		view.isEditable = false
		// Selectable, because the reason somebody has this open may be to copy
		// a key into a note about their own project.
		view.isSelectable = true
		view.drawsBackground = false
		view.textContainerInset = NSSize(width: 16, height: 14)
		view.textStorage?.setAttributedString(Self.laidOut(text))

		let scroll = NSScrollView()
		scroll.documentView = view
		scroll.hasVerticalScroller = true
		scroll.autohidesScrollers = true
		scroll.drawsBackground = true
		scroll.backgroundColor = Theme.panel
		scroll.translatesAutoresizingMaskIntoConstraints = false

		let root = NSView()
		root.addSubview(scroll)
		NSLayoutConstraint.activate([
			scroll.topAnchor.constraint(equalTo: root.topAnchor),
			scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
			scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
			scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
		])
		contentView = root
	}

	@available(*, unavailable) required init?(coder: NSCoder) { nil }

	/// Escape puts it away, which is what escape means everywhere else.
	public override func cancelOperation(_ sender: Any?) { close() }

	/// The list, in the face it was written for, with its headings picked out.
	///
	/// A heading is a line that starts at the margin; every key is indented, so
	/// the file's own shape says which is which and nothing has to be marked up.
	/// The keys stay monospaced — that is what makes the columns line up — and
	/// only the headings change, so nothing moves sideways.
	static func laidOut(_ text: String) -> NSAttributedString {
		let out = NSMutableAttributedString()
		for line in text.components(separatedBy: "\n") {
			let heading = !line.isEmpty && !line.hasPrefix(" ")
			out.append(NSAttributedString(string: line + "\n", attributes: [
				.font: heading ? Theme.bodyStrong : Theme.mono,
				.foregroundColor: heading ? Theme.accent : Theme.text,
			]))
		}
		return out
	}
}
