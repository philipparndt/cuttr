import AppKit
import CuttrCompose
import CuttrKit
import CuttrRecord

/// Making a screencast: a URL, a size, and a button.
///
/// **What this panel is really for** is the two refusals. Recording the screen
/// needs a permission macOS grants outside the app, and cuttr needs a browser it
/// did not write. Both are ordinary situations rather than faults, both are
/// invisible until somebody presses record, and both are cheap to say in advance
/// — so they are said in advance, on the panel, before the button is pressed.
///
/// The third thing it says is what the recording will give away. With the
/// address bar in the film — which is the default, because a screencast that
/// does not say where it is has to say it in words — the URL is readable in the
/// finished piece, and `localhost:3000` or a staging host with somebody's name
/// in it is exactly the sort of thing nobody notices until it is published.
@MainActor
public final class RecordingPanel: NSView {

	/// What the panel is doing. Not an error and a boolean: the states are
	/// different situations with different sentences and different buttons, and
	/// collapsing them is how "recording failed" comes to be the only thing a
	/// program can say.
	public enum State: Equatable {
		case ready
		/// The permission is missing, or is there and cannot be used yet.
		case needsConsent(Consent)
		/// Nothing installed to record with. The sentence is the sitter's, so it
		/// names what to install rather than saying something is missing.
		case nothing(String)
		/// The browser is opening and the window is being waited for.
		case opening
		case recording
		/// Something was refused. The sentence is the refusal's own.
		case refused(String)
		/// A recording was made and landed here.
		case made(URL)
	}

	public private(set) var state: State = .ready { didSet { show() } }

	/// The recording as the fields have it.
	public var recording = Recording(name: "screencast", url: "") { didSet { fill() } }

	/// Somebody pressed record, or stop.
	public var onRecord: ((Recording) -> Void)?
	public var onStop: (() -> Void)?
	/// Somebody asked to be taken to the settings pane.
	public var onOpenSettings: (() -> Void)?

	/// What the project already says it records.
	///
	/// A recording that was written down is made *again* rather than typed
	/// again — which is the whole reason it is in the file. Listed here, so the
	/// second take of a screencast is one choice and one press.
	public var stated: [Recording] = [] { didSet { listStated() } }

	private let stock = NSPopUpButton()
	/// The row the popup is on, hidden when there is nothing to choose — a menu
	/// with one item in it is a control that looks broken.
	private var stockRow: NSGridRow?
	private var pageRows: [NSGridRow] = []
	private var terminalRows: [NSGridRow] = []
	private let name = NSTextField()
	private let url = NSTextField()
	private let width = NSTextField()
	private let height = NSTextField()
	private let browser = NSPopUpButton()
	private let chrome = NSPopUpButton()
	private let sizes = NSPopUpButton()
	private let directory = NSTextField()
	private let commands = NSTextField()
	private let theme = NSTextField()
	private let record = NSButton()
	private let settings = NSButton()
	private let clock = NSTextField(labelWithString: "")
	private let says = NSTextField(labelWithString: "")

	public override init(frame: NSRect) {
		super.init(frame: frame)
		wantsLayer = true
		layer?.backgroundColor = Theme.panel.cgColor
		build()
		fill()
		show()
	}

	@available(*, unavailable) required init?(coder: NSCoder) { nil }

	// MARK: - The form

	private func build() {
		for (field, placeholder) in [(name, "install-demo"),
		                             (url, "https://example.com/download"),
		                             (directory, "~/dev/cuttr"),
		                             (commands, "make build, make test"),
		                             (theme, "the palette to record in")] {
			field.placeholderString = placeholder
			field.font = Theme.body
			field.target = self
			field.action = #selector(typed)
		}
		for field in [width, height] {
			field.font = Theme.mono
			field.target = self
			field.action = #selector(typed)
			field.widthAnchor.constraint(equalToConstant: 72).isActive = true
		}
		browser.addItem(withTitle: "a page, in whichever browser is installed")
		for kind in Recording.Browser.allCases {
			browser.addItem(withTitle: "a page, in \(kind.described)")
		}
		for kind in Recording.Terminal.allCases {
			browser.addItem(withTitle: "a terminal, in \(kind.described)")
		}
		browser.target = self
		browser.action = #selector(typed)

		chrome.addItem(withTitle: "address bar")
		chrome.addItem(withTitle: "no chrome — just the page")
		chrome.target = self
		chrome.action = #selector(typed)

		record.bezelStyle = .rounded
		record.target = self
		record.action = #selector(pressed)
		settings.bezelStyle = .rounded
		settings.title = "Open Settings"
		settings.target = self
		settings.action = #selector(openSettings)

		clock.font = Theme.monoSmall
		clock.textColor = Theme.dimText
		says.font = Theme.body
		says.textColor = Theme.dimText
		says.lineBreakMode = .byWordWrapping
		says.maximumNumberOfLines = 4
		says.preferredMaxLayoutWidth = 360

		stock.target = self
		stock.action = #selector(chose)

		// The sizes anybody actually picks, by the name they call them. Typing
		// 1280 and 720 into two boxes is what somebody does when nothing has
		// offered them 720p, and it is also how a recording comes to be 1208
		// wide because a digit went missing.
		for size in RecordingPanel.stock { sizes.addItem(withTitle: size.described) }
		sizes.addItem(withTitle: "custom")
		sizes.target = self
		sizes.action = #selector(sized)

		let form = NSGridView(views: [
			[label("record"), stock],
			[label("as"), name],
			[label("what"), browser],
			[label("url"), url],
			[label("in"), directory],
			[label("run"), commands],
			[label("theme"), theme],
			[label("size"), row([sizes, width, label("×"), height])],
			[label("shows"), chrome],
		])
		form.rowSpacing = 8
		form.columnSpacing = 10
		form.column(at: 0).xPlacement = .trailing
		stockRow = form.row(at: 0)
		// The rows that belong to one kind of recording and not the other. A
		// `chrome:` on a terminal is a control for a thing that is not there.
		pageRows = [form.row(at: 3), form.row(at: 8)]
		terminalRows = [form.row(at: 4), form.row(at: 5), form.row(at: 6)]
		listStated()
		showWhat()

		let buttons = row([record, settings, clock])
		let stack = NSStackView(views: [form, says, buttons])
		stack.orientation = .vertical
		stack.alignment = .leading
		stack.spacing = 14
		stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
		stack.translatesAutoresizingMaskIntoConstraints = false
		addSubview(stack)
		NSLayoutConstraint.activate([
			stack.topAnchor.constraint(equalTo: topAnchor),
			stack.leadingAnchor.constraint(equalTo: leadingAnchor),
			stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
			stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
		])
	}

	private func label(_ text: String) -> NSTextField {
		let made = NSTextField(labelWithString: text)
		made.font = Theme.mono
		made.textColor = Theme.dimText
		return made
	}

	private func row(_ views: [NSView]) -> NSStackView {
		let made = NSStackView(views: views)
		made.orientation = .horizontal
		made.spacing = 8
		return made
	}

	// MARK: - What it says

	private func fill() {
		name.stringValue = recording.name
		url.stringValue = recording.url
		directory.stringValue = recording.directory ?? ""
		commands.stringValue = recording.run.joined(separator: ", ")
		theme.stringValue = recording.theme ?? ""
		width.stringValue = String(recording.width)
		height.stringValue = String(recording.height)
		showSize()
		browser.selectItem(at: whichOne)
		chrome.selectItem(at: recording.chrome == .bar ? 0 : 1)
		showWhat()
	}

	/// Which row of the `what` popup this recording is: the browsers first,
	/// then the terminals.
	private var whichOne: Int {
		if let terminal = recording.terminal,
		   let at = Recording.Terminal.allCases.firstIndex(of: terminal) {
			return 1 + Recording.Browser.allCases.count + at
		}
		return recording.browser
			.flatMap { Recording.Browser.allCases.firstIndex(of: $0).map { $0 + 1 } } ?? 0
	}

	/// Only the fields that belong to what is being recorded. A `chrome:` on a
	/// terminal is a control for a thing that is not there, and a URL on one is
	/// a question with no answer.
	private func showWhat() {
		let terminal = recording.recordsATerminal
		for row in pageRows { row.isHidden = terminal }
		for row in terminalRows { row.isHidden = !terminal }
	}

	/// The project's own, and a way to start from nothing.
	private func listStated() {
		stock.removeAllItems()
		stock.addItem(withTitle: "something new")
		for recording in stated { stock.addItem(withTitle: recording.name) }
		stockRow?.isHidden = stated.isEmpty
		stock.selectItem(at: 0)
	}

	@objc private func chose() {
		let picked = stock.indexOfSelectedItem - 1
		guard picked >= 0, picked < stated.count else { return }
		recording = stated[picked]
		show()
	}

	@objc private func typed() {
		var next = Recording(
			name: Slug.make(from: name.stringValue.isEmpty ? "screencast" : name.stringValue),
			width: Int(width.stringValue) ?? recording.width,
			height: Int(height.stringValue) ?? recording.height,
			chrome: chrome.indexOfSelectedItem == 0 ? .bar : Recording.Chrome.none)
		// One list, browsers then terminals, because "what am I recording" is
		// one question and answering it in two controls means answering it
		// twice.
		let picked = browser.indexOfSelectedItem - 1
		let browsers = Recording.Browser.allCases.count
		if picked >= browsers {
			let at = picked - browsers
			next.terminal = at < Recording.Terminal.allCases.count
				? Recording.Terminal.allCases[at] : .ghostty
			next.directory = nonEmpty(directory.stringValue)
			next.run = commands.stringValue
				.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
				.filter { !$0.isEmpty }
		} else {
			next.url = url.stringValue.trimmingCharacters(in: .whitespaces)
			next.browser = picked >= 0 ? Recording.Browser.allCases[picked] : nil
		}
		next.theme = nonEmpty(theme.stringValue)
		recording = next
		show()
	}

	/// The frames a screencast is nearly always made at.
	///
	/// Named rather than numbered, because "1080p" is what somebody has in mind
	/// and `1920 × 1080` is what they then have to type twice without a
	/// mistake. The list is short on purpose: these are the sizes a film gets
	/// rendered at, and anything else is `custom`.
	struct Stock {
		let described: String
		let width: Int
		let height: Int
	}

	static let stock: [Stock] = [
		Stock(described: "720p — 1280 × 720", width: 1280, height: 720),
		Stock(described: "1080p — 1920 × 1080", width: 1920, height: 1080),
		Stock(described: "1440p — 2560 × 1440", width: 2560, height: 1440),
		Stock(described: "4K — 3840 × 2160", width: 3840, height: 2160),
		// Not a broadcast size, and here because it is the one somebody wants
		// for a treatment: a picture that is going to be held in a corner of a
		// 1080p frame does not need to be recorded at 1080p.
		Stock(described: "half 1080p — 960 × 540", width: 960, height: 540),
	]

	@objc private func sized() {
		let picked = sizes.indexOfSelectedItem
		guard picked >= 0, picked < RecordingPanel.stock.count else { return }
		let chosen = RecordingPanel.stock[picked]
		width.stringValue = String(chosen.width)
		height.stringValue = String(chosen.height)
		typed()
	}

	/// Which of the stock sizes this is, or `custom`.
	private func showSize() {
		let at = RecordingPanel.stock.firstIndex {
			$0.width == recording.width && $0.height == recording.height
		}
		sizes.selectItem(at: at ?? RecordingPanel.stock.count)
	}

	private func nonEmpty(_ text: String) -> String? {
		let trimmed = text.trimmingCharacters(in: .whitespaces)
		return trimmed.isEmpty ? nil : trimmed
	}

	@objc private func pressed() {
		switch state {
		case .recording: onStop?()
		default: onRecord?(recording)
		}
	}

	@objc private func openSettings() { onOpenSettings?() }

	/// Whatever cuttr can say before the button is pressed rather than after.
	private func show() {
		settings.isHidden = true
		clock.stringValue = ""
		switch state {
		case .ready:
			record.title = "Record"
			record.isEnabled = recording.recordsATerminal || !recording.url.isEmpty
			says.stringValue = advice
			says.textColor = Theme.dimText
		case .needsConsent(let consent):
			record.title = "Record"
			record.isEnabled = false
			settings.isHidden = false
			says.stringValue = consent.explanation ?? ""
			says.textColor = Theme.playhead
		case .nothing(let said):
			record.title = "Record"
			record.isEnabled = false
			says.stringValue = said
			says.textColor = Theme.playhead
		case .opening:
			record.title = "Stop"
			record.isEnabled = false
			says.stringValue = "Opening the browser…"
			says.textColor = Theme.dimText
		case .recording:
			record.title = "Stop"
			record.isEnabled = true
			says.stringValue = "Recording. Leave the window on screen — what is captured is "
				+ "the window, so it can be moved but not hidden."
			says.textColor = Theme.dimText
		case .refused(let why):
			record.title = "Record"
			record.isEnabled = recording.recordsATerminal || !recording.url.isEmpty
			says.stringValue = why
			says.textColor = Theme.playhead
		case .made(let at):
			record.title = "Record"
			record.isEnabled = true
			says.stringValue = "Recorded \(at.lastPathComponent). It is in the material "
				+ "tree as a take."
			says.textColor = Theme.dimText
		}
	}

	/// The two things worth knowing before the first recording, and only where
	/// they apply.
	private var advice: String {
		// Worked out rather than a number typed here, so the panel and the
		// encoder cannot come to disagree. It is a ceiling: the seconds where
		// nothing moves cost nothing, and most of them do not move.
		let pixels = Double(recording.width * recording.height) * 4   // at 2×
		let megabytes = pixels * 30 / 12 * 60 / 8 / 1_000_000
		var out = "Under \(Int(megabytes.rounded())) MB a minute at this size, and "
			+ "usually far less — recordings land beside the project like any other "
			+ "footage."
		if recording.chrome == .bar, !recording.url.isEmpty {
			out += " The address bar is in the film, so this URL will be readable in it."
		}
		// **What cuttr cannot clean**, said before the recording rather than
		// found in it. Only the thing being recorded knows: a browser with a
		// fresh profile answers nothing, and a terminal answers that the
		// person's own startup files still run.
		if let theirs = Sitters.find(for: recording)?.whatIsStillTheirs {
			out += " " + theirs
		}
		return out
	}

	/// The clock while it runs, set by whatever is doing the recording.
	public func tick(_ seconds: Double) {
		guard state == .recording else { return }
		clock.stringValue = Timecode.string(seconds)
	}

	/// Moves the panel to a state and redraws it.
	public func show(_ state: State) { self.state = state }

	// MARK: - For the tests

	var saysForTesting: String { says.stringValue }
	var recordTitleForTesting: String { record.title }
	var canRecordForTesting: Bool { record.isEnabled }
	var offersSettingsForTesting: Bool { !settings.isHidden }
	var sizeNameForTesting: String { sizes.titleOfSelectedItem ?? "" }

	func chooseSizeForTesting(_ index: Int) {
		sizes.selectItem(at: index)
		sized()
	}

	var statedNamesForTesting: [String] {
		stockRow?.isHidden == false ? stock.itemTitles : []
	}

	func chooseForTesting(_ index: Int) {
		stock.selectItem(at: index)
		chose()
	}

	func typeForTesting(url: String) {
		self.url.stringValue = url
		typed()
	}
}
