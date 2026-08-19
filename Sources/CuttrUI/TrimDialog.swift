import AppKit
import CuttrCompose
import CuttrKit

/// Where a placement's ends are decided, with the frames big enough to decide
/// them by.
///
/// The strip in the properties panel was right about what a trim is — two
/// frames — and wrong about how much room that needs. A frame the width of a
/// form field shows that somebody is in shot; it does not show whether her
/// mouth has closed. So the work moved into a dialog, where the pictures are
/// the size of pictures and the things a trim actually wants are all present:
/// step a frame at a time, scrub either end, read the length as it changes,
/// and put an end back where it was.
///
/// Nothing is written until Done. A trim that is applied while it is being
/// found makes every intermediate guess a change to the project, and a project
/// that changes forty times while somebody drags is one that cannot be undone
/// in a useful step.
@MainActor
public final class TrimDialog: NSViewController {

	/// Seconds from the untrimmed head of this placement, and a frame back.
	public typealias Poster = (Double, @escaping (NSImage?) -> Void) -> Void

	private let clip: String
	/// The whole placement, before anything is taken off either end.
	private let length: Double
	private let step: Double
	private let poster: Poster?
	private let onDone: ((Double, Double)) -> Void

	private var trim: (head: Double, tail: Double)

	private let strip = TrimStrip()
	private let headField = NSTextField()
	private let tailField = NSTextField()
	private let lengthLabel = NSTextField(labelWithString: "")
	private var hosted: NSWindow?

	public init(clip: String, length: Double, trim: (head: Double, tail: Double),
	            step: Double, poster: Poster?,
	            onDone: @escaping ((Double, Double)) -> Void) {
		self.clip = clip
		self.length = max(length, 0.001)
		self.trim = trim
		self.step = step > 0 ? step : 1.0 / 25
		self.poster = poster
		self.onDone = onDone
		super.init(nibName: nil, bundle: nil)
	}

	@available(*, unavailable) required init?(coder: NSCoder) { nil }

	public static func present(over view: NSView, clip: String, length: Double,
	                           trim: (head: Double, tail: Double), step: Double,
	                           poster: Poster?,
	                           onDone: @escaping ((Double, Double)) -> Void) {
		guard let parent = view.window else { return }
		let dialog = TrimDialog(clip: clip, length: length, trim: trim, step: step,
		                        poster: poster, onDone: onDone)
		parent.beginSheet(dialog.sheet()) { _ in }
	}

	private func sheet() -> NSWindow {
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 440),
		                      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
		window.contentViewController = self
		window.title = "Trim \(clip)"
		window.isReleasedWhenClosed = false
		hosted = window
		return window
	}

	public override func loadView() {
		let root = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 440))
		root.wantsLayer = true
		root.layer?.backgroundColor = Theme.card.cgColor

		strip.trim = trim
		strip.length = length
		strip.preferredHeight = 260
		strip.onScrub = { [weak self] head, tail in
			guard let self else { return }
			self.trim = (head, tail)
			self.show()
			self.tell()
		}
		strip.onTrim = { [weak self] head, tail in
			guard let self else { return }
			self.trim = (head, tail)
			self.show()
			self.tell()
		}

		let rows = NSStackView(views: [
			end("head", headField, #selector(headTyped), #selector(headBack), #selector(headOn),
			    #selector(headReset)),
			end("tail", tailField, #selector(tailTyped), #selector(tailBack), #selector(tailOn),
			    #selector(tailReset)),
		])
		rows.orientation = .vertical
		rows.alignment = .leading
		rows.spacing = 8

		lengthLabel.font = Theme.mono
		lengthLabel.textColor = Theme.dimText

		let done = NSButton(title: "Done", target: self, action: #selector(finish))
		done.bezelStyle = .rounded
		done.keyEquivalent = "\r"
		let cancel = NSButton(title: "Cancel", target: self, action: #selector(close))
		cancel.bezelStyle = .rounded
		cancel.keyEquivalent = "\u{1b}"

		for view in [strip, rows, lengthLabel, done, cancel] as [NSView] {
			view.translatesAutoresizingMaskIntoConstraints = false
			root.addSubview(view)
		}
		NSLayoutConstraint.activate([
			strip.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
			strip.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
			strip.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),

			rows.topAnchor.constraint(equalTo: strip.bottomAnchor, constant: 12),
			rows.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
			rows.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -12),

			lengthLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
			lengthLabel.bottomAnchor.constraint(equalTo: done.bottomAnchor),

			done.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
			done.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
			done.topAnchor.constraint(greaterThanOrEqualTo: rows.bottomAnchor, constant: 12),
			cancel.trailingAnchor.constraint(equalTo: done.leadingAnchor, constant: -8),
			cancel.bottomAnchor.constraint(equalTo: done.bottomAnchor),
		])
		view = root
		tell()
		show()
	}

	/// One end: what is taken off it, a frame either way, and a way back.
	private func end(_ name: String, _ field: NSTextField, _ typed: Selector,
	                 _ back: Selector, _ on: Selector, _ reset: Selector) -> NSView {
		let label = NSTextField(labelWithString: name)
		label.font = Theme.mono
		label.textColor = Theme.text
		label.translatesAutoresizingMaskIntoConstraints = false
		label.widthAnchor.constraint(equalToConstant: 40).isActive = true

		field.font = Theme.mono
		field.placeholderString = "00:00.000"
		field.target = self
		field.action = typed
		field.translatesAutoresizingMaskIntoConstraints = false
		field.widthAnchor.constraint(equalToConstant: 96).isActive = true

		// A frame at a time, because the difference between a good cut and a
		// bad one is usually one.
		let minus = NSButton(title: "− frame", target: self, action: back)
		let plus = NSButton(title: "+ frame", target: self, action: on)
		let whole = NSButton(title: "whole", target: self, action: reset)
		for button in [minus, plus, whole] {
			button.bezelStyle = .rounded
			button.controlSize = .small
			button.font = NSFont.systemFont(ofSize: 11)
		}

		let row = NSStackView(views: [label, field, minus, plus, whole])
		row.orientation = .horizontal
		row.spacing = 6
		row.alignment = .centerY
		return row
	}

	// MARK: - Changing it

	/// Neither end may eat the other, and something has to be left.
	func set(head: Double, tail: Double) {
		let room = max(0, length - 0.05)
		var head = max(0, head)
		var tail = max(0, tail)
		if head + tail > room {
			if head > tail { head = max(0, room - tail) } else { tail = max(0, room - head) }
		}
		trim = (head, tail)
		strip.trim = trim
		tell()
		show()
	}

	@objc private func headTyped() {
		guard let seconds = Timecode.parse(headField.stringValue) else { return }
		set(head: seconds, tail: trim.tail)
	}

	@objc private func tailTyped() {
		guard let seconds = Timecode.parse(tailField.stringValue) else { return }
		set(head: trim.head, tail: seconds)
	}

	@objc private func headBack() { stepHead(by: -1) }
	@objc private func headOn() { stepHead(by: 1) }
	@objc private func tailBack() { stepTail(by: -1) }
	@objc private func tailOn() { stepTail(by: 1) }

	func stepHead(by frames: Int) {
		set(head: trim.head + Double(frames) * step, tail: trim.tail)
	}

	func stepTail(by frames: Int) {
		set(head: trim.head, tail: trim.tail + Double(frames) * step)
	}
	@objc private func headReset() { set(head: 0, tail: trim.tail) }
	@objc private func tailReset() { set(head: trim.head, tail: 0) }

	/// What the numbers say now.
	private func tell() {
		headField.stringValue = Timecode.string(trim.head)
		tailField.stringValue = Timecode.string(trim.tail)
		let left = max(0, length - trim.head - trim.tail)
		lengthLabel.stringValue = "\(Timecode.string(left)) of \(Timecode.string(length))"
	}

	/// The two frames the ends are on. A hair inside each, because a frame
	/// exactly on a cut is the one nobody can tell from its neighbour.
	private func show() {
		guard let poster else { return }
		poster(min(length, trim.head + 0.04)) { [weak self] image in self?.strip.head = image }
		poster(max(0, length - trim.tail - 0.04)) { [weak self] image in self?.strip.tail = image }
	}

	@objc private func finish() { done() }

	func done() {
		onDone((trim.head, trim.tail))
		close()
	}

	@objc private func close() {
		guard let window = view.window else { return }
		window.sheetParent?.endSheet(window)
		hosted = nil
	}

	/// For the tests: what would be written if Done were pressed now.
	var chosen: (head: Double, tail: Double) { trim }
}
