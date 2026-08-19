@preconcurrency import AVFoundation
import AppKit
import CuttrCompose
import CuttrKit

/// Where a placement's ends are decided: the picture, and a timeline under it.
///
/// The first try showed two still frames side by side, which was wrong twice
/// over. Stills stretched to whatever shape the window was — a trim is judged
/// on a face, and a face the wrong width is not the face — and a cut is not
/// really found by looking at two frames anyway. It is found by *watching*: run
/// the last second before the mark with the sound on and it is obvious whether
/// she has finished the word.
///
/// So this is one screen and one timeline, the same arrangement as the cutting
/// window, playing the take's own media — the camera and the separate recorder
/// at its offset — through the same `Transport` that window uses. The clock is
/// the take's, as everywhere else in this program; what the dialog works in is
/// seconds from the head of this placement, and it converts.
///
/// Nothing is written until Done. Hunting for a frame should be one change to
/// the project, not one per drag.
@MainActor
public final class TrimDialog: NSViewController {

	private let clip: String
	private let video: URL?
	private let audio: URL?
	private let audioOffset: Double
	/// The placement on the take's clock, before anything is taken off.
	private let span: (start: Double, end: Double)
	private let step: Double
	private let onDone: ((Double, Double)) -> Void

	private var trim: (head: Double, tail: Double)
	private var length: Double { max(0.001, span.end - span.start) }

	private let transport = Transport()
	private var playerView: PlayerView!
	private let timeline = TrimTimeline()
	private let headField = NSTextField()
	private let tailField = NSTextField()
	private let lengthLabel = NSTextField(labelWithString: "")
	private let playButton = NSButton()
	private var hosted: NSWindow?
	private var keys: Any?

	public init(clip: String, video: URL?, audio: URL?, audioOffset: Double,
	            span: (start: Double, end: Double), trim: (head: Double, tail: Double),
	            step: Double, onDone: @escaping ((Double, Double)) -> Void) {
		self.clip = clip
		self.video = video
		self.audio = audio
		self.audioOffset = audioOffset
		self.span = span
		self.trim = trim
		self.step = step > 0 ? step : 1.0 / 25
		self.onDone = onDone
		super.init(nibName: nil, bundle: nil)
	}

	@available(*, unavailable) required init?(coder: NSCoder) { nil }

	public static func present(
		over view: NSView, clip: String, video: URL?, audio: URL?, audioOffset: Double,
		span: (start: Double, end: Double), trim: (head: Double, tail: Double),
		step: Double, onDone: @escaping ((Double, Double)) -> Void
	) {
		guard let parent = view.window else { return }
		let dialog = TrimDialog(clip: clip, video: video, audio: audio, audioOffset: audioOffset,
		                        span: span, trim: trim, step: step, onDone: onDone)
		parent.beginSheet(dialog.sheet()) { _ in }
	}

	private func sheet() -> NSWindow {
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 620),
		                      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
		window.contentViewController = self
		window.title = "Trim \(clip)"
		window.isReleasedWhenClosed = false
		window.minSize = NSSize(width: 560, height: 420)
		hosted = window
		return window
	}

	// MARK: - Building it

	public override func loadView() {
		let root = NSView(frame: NSRect(x: 0, y: 0, width: 860, height: 620))
		root.wantsLayer = true
		root.layer?.backgroundColor = Theme.card.cgColor

		// The picture keeps its shape whatever the window does. Letterboxed, not
		// stretched — the previous dialog stretched, and a stretched face is not
		// something anybody can cut on.
		playerView = PlayerView(player: transport.player)

		timeline.length = length
		timeline.trim = trim
		timeline.onScrub = { [weak self] at in self?.seek(to: at) }
		timeline.onTrim = { [weak self] head, tail, _ in
			guard let self else { return }
			self.trim = (head, tail)
			self.tell()
		}

		playButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "play")
		playButton.bezelStyle = .rounded
		playButton.target = self
		playButton.action = #selector(togglePlay)
		let playKept = NSButton(title: "Play what is kept", target: self, action: #selector(playAll))
		playKept.bezelStyle = .rounded
		playKept.controlSize = .small

		lengthLabel.font = Theme.mono
		lengthLabel.textColor = Theme.dimText

		let transportRow = NSStackView(views: [playButton, playKept, lengthLabel])
		transportRow.orientation = .horizontal
		transportRow.spacing = 8
		transportRow.alignment = .centerY

		let rows = NSStackView(views: [
			end("head", headField, #selector(headTyped), #selector(headBack), #selector(headOn),
			    #selector(headHere)),
			end("tail", tailField, #selector(tailTyped), #selector(tailBack), #selector(tailOn),
			    #selector(tailHere)),
		])
		rows.orientation = .vertical
		rows.alignment = .leading
		rows.spacing = 6

		let reset = NSButton(title: "Reset trim", target: self, action: #selector(resetTrim))
		reset.bezelStyle = .rounded
		reset.controlSize = .small
		reset.toolTip = "the whole clip again, both ends"
		let done = NSButton(title: "Done", target: self, action: #selector(finish))
		done.bezelStyle = .rounded
		done.keyEquivalent = "\r"
		let cancel = NSButton(title: "Cancel", target: self, action: #selector(close))
		cancel.bezelStyle = .rounded
		cancel.keyEquivalent = "\u{1b}"

		for view in [playerView, timeline, transportRow, rows, reset, done, cancel] as [NSView] {
			view.translatesAutoresizingMaskIntoConstraints = false
			root.addSubview(view)
		}
		NSLayoutConstraint.activate([
			playerView.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
			playerView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
			playerView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
			playerView.bottomAnchor.constraint(equalTo: timeline.topAnchor, constant: -10),
			playerView.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),

			timeline.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
			timeline.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
			timeline.bottomAnchor.constraint(equalTo: transportRow.topAnchor, constant: -10),

			transportRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
			transportRow.bottomAnchor.constraint(equalTo: rows.topAnchor, constant: -10),

			rows.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
			rows.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -12),
			rows.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -52),

			reset.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
			reset.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),

			done.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
			done.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
			cancel.trailingAnchor.constraint(equalTo: done.leadingAnchor, constant: -8),
			cancel.bottomAnchor.constraint(equalTo: done.bottomAnchor),
		])
		view = root

		// While it plays, the playhead follows the picture; while it does not,
		// whatever moved the playhead is the thing that knows where it is.
		transport.onTick = { [weak self] time in
			guard let self, self.transport.isPlaying else { return }
			self.timeline.playhead = min(max(0, time - self.span.start), self.length)
		}
		transport.onRateChange = { [weak self] rate in
			self?.playButton.image = NSImage(
				systemSymbolName: rate == 0 ? "play.fill" : "pause.fill",
				accessibilityDescription: rate == 0 ? "play" : "pause")
		}
		// The take's own media, the camera and the recorder together, so what
		// is heard while trimming is what will be rendered.
		transport.load(video: video, audio: audio, offset: audioOffset) { [weak self] in
			guard let self else { return }
			self.seek(to: self.trim.head)
		}
		tell()
	}

	public override func viewDidAppear() {
		super.viewDidAppear()
		// Space plays, the way it does in the cutting window; I and O put the
		// marks where the playhead is.
		keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
			guard let self, event.window === self.view.window else { return event }
			// Not while somebody is typing a timecode into a field.
			if self.view.window?.firstResponder is NSTextView { return event }
			switch event.charactersIgnoringModifiers?.lowercased() {
			case " ": self.togglePlay(); return nil
			case "i": self.headHere(); return nil
			case "o": self.tailHere(); return nil
			default: return event
			}
		}
	}

	public override func viewWillDisappear() {
		super.viewWillDisappear()
		transport.pause()
		if let keys { NSEvent.removeMonitor(keys) }
		keys = nil
	}

	/// One end: what is taken off it, a frame either way, and a way to put it
	/// where the playhead is.
	private func end(_ name: String, _ field: NSTextField, _ typed: Selector,
	                 _ back: Selector, _ on: Selector, _ here: Selector) -> NSView {
		let label = NSTextField(labelWithString: name)
		label.font = Theme.mono
		label.textColor = Theme.text
		label.translatesAutoresizingMaskIntoConstraints = false
		label.widthAnchor.constraint(equalToConstant: 36).isActive = true

		field.font = Theme.mono
		field.placeholderString = "00:00.000"
		field.target = self
		field.action = typed
		field.translatesAutoresizingMaskIntoConstraints = false
		field.widthAnchor.constraint(equalToConstant: 92).isActive = true

		// A frame at a time, because the difference between a good cut and a bad
		// one is usually one.
		let minus = NSButton(title: "−1", target: self, action: back)
		let plus = NSButton(title: "+1", target: self, action: on)
		let atHead = NSButton(title: name == "head" ? "here (I)" : "here (O)", target: self,
		                      action: here)
		for button in [minus, plus, atHead] {
			button.bezelStyle = .rounded
			button.controlSize = .small
			button.font = NSFont.systemFont(ofSize: 11)
		}

		let row = NSStackView(views: [label, field, minus, plus, atHead])
		row.orientation = .horizontal
		row.spacing = 6
		row.alignment = .centerY
		return row
	}

	// MARK: - Moving about

	/// Seconds from the head of the placement, on the take's clock.
	private func seek(to at: Double) {
		timeline.playhead = min(max(0, at), length)
		transport.pause()
		transport.seek(to: span.start + timeline.playhead)
	}

	@objc func togglePlay() {
		if transport.isPlaying { transport.pause(); return }
		// From where the playhead is to where this placement ends, so playing
		// never runs into the next shot on the take.
		let from = span.start + timeline.playhead
		let to = span.end - trim.tail
		transport.play(from: from < to ? from : span.start + trim.head, to: to)
	}

	@objc func playAll() {
		transport.play(from: span.start + trim.head, to: span.end - trim.tail)
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
		timeline.trim = trim
		tell()
	}

	@objc private func headTyped() {
		guard let seconds = Timecode.parse(headField.stringValue) else { return }
		set(head: seconds, tail: trim.tail)
		seek(to: trim.head)
	}

	@objc private func tailTyped() {
		guard let seconds = Timecode.parse(tailField.stringValue) else { return }
		set(head: trim.head, tail: seconds)
		seek(to: length - trim.tail)
	}

	@objc private func headBack() { stepHead(by: -1) }
	@objc private func headOn() { stepHead(by: 1) }
	@objc private func tailBack() { stepTail(by: -1) }
	@objc private func tailOn() { stepTail(by: 1) }

	func stepHead(by frames: Int) {
		set(head: trim.head + Double(frames) * step, tail: trim.tail)
		seek(to: trim.head)
	}

	func stepTail(by frames: Int) {
		set(head: trim.head, tail: trim.tail + Double(frames) * step)
		seek(to: length - trim.tail)
	}

	/// The mark goes where the picture is. The other way round — find the frame,
	/// then read its time off, then type it — is what a dialog is for avoiding.
	@objc func headHere() { set(head: timeline.playhead, tail: trim.tail) }
	@objc func tailHere() { set(head: trim.head, tail: max(0, length - timeline.playhead)) }

	/// The whole clip again, both ends at once.
	@objc func resetTrim() { set(head: 0, tail: 0) }

	/// What the numbers say now.
	private func tell() {
		headField.stringValue = Timecode.string(trim.head)
		tailField.stringValue = Timecode.string(trim.tail)
		let left = max(0, length - trim.head - trim.tail)
		lengthLabel.stringValue = "\(Timecode.string(left)) of \(Timecode.string(length))"
	}

	@objc private func finish() { done() }

	func done() {
		onDone((trim.head, trim.tail))
		close()
	}

	@objc private func close() {
		transport.pause()
		guard let window = view.window else { return }
		window.sheetParent?.endSheet(window)
		hosted = nil
	}

	/// For the tests: what would be written if Done were pressed now.
	var chosen: (head: Double, tail: Double) { trim }
	var at: Double {
		get { timeline.playhead }
		set { timeline.playhead = newValue }
	}
}
