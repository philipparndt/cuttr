import AppKit
import CuttrChat

/// The assistant, down the side of the window.
///
/// A panel of the *window* rather than of a document. The conversation is about
/// the cut — which is several takes and a project — and switching from one of
/// them to another is the middle of a sentence, not the end of one. So it stays
/// where it is while the document beside it changes, and what it is told about
/// with each message is whichever of them is on screen then.
///
/// It draws what ``ChatEngine`` holds and nothing of its own: every state it
/// can show — nobody connected, an answer being written, a call waiting to be
/// allowed — is a fact there, which is what lets a second window show the same
/// conversation and a test read it without a window at all.
@MainActor
final class ChatPanel: NSView, NSTextViewDelegate {

	static let width: CGFloat = 380

	let engine: ChatEngine
	var onClose: (() -> Void)?

	/// The line to paste into a terminal when no AI is set up. Asked for only
	/// when it is about to be shown, because answering writes the script.
	private let setupCommand: () -> String
	/// Whether to look at the network and keep asking. Off for the tests: a
	/// panel built to be measured should not browse the LAN.
	private let live: Bool

	private let models = NSPopUpButton(frame: .zero, pullsDown: false)
	private let scroll = NSScrollView()
	private let page = Flipped()
	private let stack = NSStackView()
	private var rows: [ChatEntryView] = []
	private let confirm = NSStackView()
	private let activity = NSStackView()
	private let activityLabel = ChatPanel.label("", color: Theme.dimText)
	private let spinner = NSProgressIndicator()
	private let setup = NSStackView()
	private var setupShown = ""
	private let waiting = ChatPanel.label("", color: Theme.dimText)
	private let input = ComposerView()
	private let hint = ChatPanel.label("Ask, or say what to change", color: Theme.faintText)
	private let send = NSButton(title: "Send", target: nil, action: nil)
	private let stop = NSButton(title: "Stop", target: nil, action: nil)

	private var observer: NSObjectProtocol?
	private var timer: Timer?
	private var browser: ServerBrowser?
	private var servers: [ServerBrowser.Found] = []

	private final class Flipped: NSView {
		override var isFlipped: Bool { true }
	}

	init(engine: ChatEngine, setupCommand: @escaping () -> String, live: Bool = true) {
		self.engine = engine
		self.setupCommand = setupCommand
		self.live = live
		super.init(frame: .roomToLayOutIn)
		translatesAutoresizingMaskIntoConstraints = false
		wantsLayer = true
		layer?.backgroundColor = Theme.panel.cgColor
		build()
		observer = NotificationCenter.default.addObserver(
			forName: ChatEngine.changed, object: engine, queue: .main
		) { [weak self] _ in
			MainActor.assumeIsolated { self?.render() }
		}
		render()
	}

	@available(*, unavailable) required init?(coder: NSCoder) { nil }

	deinit {
		if let observer { NotificationCenter.default.removeObserver(observer) }
	}

	// MARK: - Coming and going

	override func viewDidMoveToWindow() {
		super.viewDidMoveToWindow()
		timer?.invalidate()
		timer = nil
		guard live, window != nil else {
			browser?.stop()
			browser = nil
			return
		}
		look()
		// Every four seconds while nobody answers, so a connector started in a
		// terminal is found without anybody pressing anything; once a minute
		// after that, which is enough to notice one going away.
		var ticks = 0
		timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
			MainActor.assumeIsolated {
				guard let self else { return }
				ticks += 1
				if self.engine.link != .connected || ticks % 15 == 0 { self.look() }
			}
		}
	}

	private func look() {
		Task { [engine] in await engine.refresh() }
	}

	/// Looks for servers on the network, and only once it is known that there
	/// is no AI on this computer: asking the network is a permission dialogue,
	/// and somebody whose connector is running should never see it.
	private func browse() {
		guard live, browser == nil, window != nil else { return }
		let browser = ServerBrowser { [weak self] found in
			MainActor.assumeIsolated {
				self?.servers = found
				self?.render()
			}
		}
		self.browser = browser
		browser.start()
	}

	func focus() { window?.makeFirstResponder(input) }

	// MARK: - Building

	static func label(_ text: String, color: NSColor, font: NSFont = Theme.body) -> NSTextField {
		let label = NSTextField(wrappingLabelWithString: text)
		label.font = font
		label.textColor = color
		label.isSelectable = true
		label.allowsEditingTextAttributes = true
		label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
		return label
	}

	private static func symbol(_ name: String, _ tip: String, _ target: AnyObject, _ action: Selector) -> NSButton {
		let image = NSImage(systemSymbolName: name, accessibilityDescription: tip)?
			.withSymbolConfiguration(.init(pointSize: 12, weight: .medium)
				.applying(.init(paletteColors: [Theme.dimText]))) ?? NSImage()
		let button = NSButton(image: image, target: target, action: action)
		button.isBordered = false
		button.toolTip = tip
		button.setAccessibilityLabel(tip)
		return button
	}

	private static func card(_ stack: NSStackView) {
		stack.orientation = .vertical
		stack.alignment = .leading
		stack.spacing = 8
		stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
		stack.wantsLayer = true
		stack.layer?.backgroundColor = Theme.card.cgColor
		stack.layer?.cornerRadius = 8
	}

	private func build() {
		let title = NSTextField(labelWithString: "ASSISTANT")
		title.font = Theme.heading
		title.textColor = Theme.faintText

		models.isBordered = false
		models.font = Theme.label
		models.target = self
		models.action = #selector(modelChosen)
		models.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

		let clear = Self.symbol("trash", "Clear the conversation", self, #selector(clearTapped))
		let close = Self.symbol("sidebar.right", "Hide the assistant", self, #selector(closeTapped))
		let head = NSStackView(views: [title, models, NSView(), clear, close])
		head.orientation = .horizontal
		head.spacing = 8
		head.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 10)

		let edge = NSView()
		edge.wantsLayer = true
		edge.layer?.backgroundColor = Theme.rule.cgColor
		let under = NSView()
		under.wantsLayer = true
		under.layer?.backgroundColor = Theme.rule.withAlphaComponent(0.6).cgColor

		stack.orientation = .vertical
		stack.alignment = .leading
		stack.spacing = 12
		stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
		stack.translatesAutoresizingMaskIntoConstraints = false
		page.translatesAutoresizingMaskIntoConstraints = false
		page.addSubview(stack)
		scroll.documentView = page
		scroll.drawsBackground = false
		scroll.hasVerticalScroller = true
		scroll.scrollerStyle = .overlay

		Self.card(confirm)
		Self.card(setup)
		spinner.style = .spinning
		spinner.controlSize = .small
		spinner.isDisplayedWhenStopped = false
		activity.orientation = .horizontal
		activity.spacing = 6
		activity.addArrangedSubview(spinner)
		activity.addArrangedSubview(activityLabel)
		for view in [confirm, activity, setup] as [NSView] {
			stack.addArrangedSubview(view)
			view.isHidden = true
		}
		pin(confirm)
		pin(setup)

		input.delegate = self
		input.onSend = { [weak self] in self?.sendTapped() }
		let field = NSScrollView()
		field.documentView = input
		field.hasVerticalScroller = false
		field.drawsBackground = true
		field.backgroundColor = Theme.card
		field.wantsLayer = true
		field.layer?.cornerRadius = 8
		field.layer?.masksToBounds = true
		hint.isSelectable = false

		send.target = self
		send.action = #selector(sendTapped)
		send.bezelStyle = .rounded
		send.controlSize = .small
		send.toolTip = "Send (⏎). While an answer is being written, it waits its turn."
		stop.target = self
		stop.action = #selector(stopTapped)
		stop.bezelStyle = .rounded
		stop.controlSize = .small
		waiting.isSelectable = false
		waiting.font = Theme.label
		waiting.lineBreakMode = .byTruncatingTail
		waiting.maximumNumberOfLines = 1
		let foot = NSStackView(views: [waiting, NSView(), stop, send])
		foot.orientation = .horizontal
		foot.spacing = 8

		// Over the field rather than in it: a scroll view lays its own subviews
		// out, and a label put inside one is moved to where it thinks a
		// subview goes.
		for view in [head, under, scroll, field, hint, foot, edge] as [NSView] {
			view.translatesAutoresizingMaskIntoConstraints = false
			addSubview(view)
		}
		NSLayoutConstraint.activate([
			edge.leadingAnchor.constraint(equalTo: leadingAnchor),
			edge.topAnchor.constraint(equalTo: topAnchor),
			edge.bottomAnchor.constraint(equalTo: bottomAnchor),
			edge.widthAnchor.constraint(equalToConstant: 1),

			head.topAnchor.constraint(equalTo: topAnchor),
			head.leadingAnchor.constraint(equalTo: leadingAnchor),
			head.trailingAnchor.constraint(equalTo: trailingAnchor),
			head.heightAnchor.constraint(equalToConstant: 32),
			under.topAnchor.constraint(equalTo: head.bottomAnchor),
			under.leadingAnchor.constraint(equalTo: leadingAnchor),
			under.trailingAnchor.constraint(equalTo: trailingAnchor),
			under.heightAnchor.constraint(equalToConstant: 1),

			scroll.topAnchor.constraint(equalTo: under.bottomAnchor),
			scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
			scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
			scroll.bottomAnchor.constraint(equalTo: field.topAnchor, constant: -8),

			page.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
			page.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
			page.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
			stack.topAnchor.constraint(equalTo: page.topAnchor),
			stack.leadingAnchor.constraint(equalTo: page.leadingAnchor),
			stack.trailingAnchor.constraint(equalTo: page.trailingAnchor),
			stack.bottomAnchor.constraint(equalTo: page.bottomAnchor),

			field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
			field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
			field.heightAnchor.constraint(equalToConstant: 72),
			field.bottomAnchor.constraint(equalTo: foot.topAnchor, constant: -8),
			hint.leadingAnchor.constraint(equalTo: field.leadingAnchor, constant: 10),
			hint.topAnchor.constraint(equalTo: field.topAnchor, constant: 8),

			foot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
			foot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
			foot.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
		])
	}

	/// As wide as the column, less its margins. A stack that aligns to the
	/// leading edge leaves each row as wide as its text, and a card should be a
	/// card's width whatever is written on it.
	private func pin(_ view: NSView) {
		view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
	}

	/// Puts a line on a card, kept inside the card's margins: a label wraps at
	/// the width it is given, and given none it wraps at the card's edge
	/// instead of at its inset.
	private func add(_ view: NSView, to card: NSStackView) {
		card.addArrangedSubview(view)
		view.widthAnchor.constraint(lessThanOrEqualTo: card.widthAnchor, constant: -20).isActive = true
	}

	// MARK: - Showing

	private var atBottom: Bool {
		scroll.contentView.bounds.maxY >= page.bounds.height - 40
	}

	func render() {
		let follow = atBottom

		// Who answers.
		let wanted = engine.choices.map(\.key)
		if models.itemArray.map({ $0.representedObject as? String ?? "" }) != wanted {
			models.removeAllItems()
			for choice in engine.choices {
				models.addItem(withTitle: choice.model.label)
				models.lastItem?.representedObject = choice.key
				models.lastItem?.toolTip = choice.provider.name
			}
		}
		if let chosen = engine.chosen,
		   let index = engine.choices.firstIndex(where: { $0.key == chosen.key }) {
			models.selectItem(at: index)
		}
		models.isHidden = engine.choices.isEmpty

		// What was said.
		let entries = engine.conversation.entries
		if entries.count < rows.count {
			rows.forEach { $0.removeFromSuperview() }
			rows = []
		}
		for (index, entry) in entries.enumerated() {
			if index == rows.count {
				let row = ChatEntryView()
				stack.insertArrangedSubview(row, at: index)
				pin(row)
				rows.append(row)
			}
			rows[index].update(entry)
		}

		// A call waiting on somebody.
		if let question = engine.confirmation {
			let key = question.question + question.detail
			if confirm.identifier?.rawValue != key {
				confirm.identifier = NSUserInterfaceItemIdentifier(key)
				confirm.arrangedSubviews.forEach { $0.removeFromSuperview() }
				add(Self.label(question.question, color: Theme.text, font: Theme.bodyStrong), to: confirm)
				let detail = Self.label(question.detail, color: Theme.dimText, font: ChatMarkdown.code)
				detail.maximumNumberOfLines = 12
				add(detail, to: confirm)
				let allow = NSButton(title: "Allow", target: self, action: #selector(allowTapped))
				// No key for it. Return is how a message is sent, and somebody
				// typing one while this card is up must not allow a call by
				// finishing their sentence.
				let decline = NSButton(title: "Decline", target: self, action: #selector(declineTapped))
				for button in [allow, decline] { button.bezelStyle = .rounded; button.controlSize = .small }
				let buttons = NSStackView(views: [allow, decline])
				buttons.spacing = 8
				confirm.addArrangedSubview(buttons)
			}
		} else {
			confirm.identifier = nil
		}
		confirm.isHidden = engine.confirmation == nil

		let working = engine.isWorking && engine.confirmation == nil
		activity.isHidden = !working
		activityLabel.stringValue = engine.activity ?? "Working…"
		if working { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }

		renderSetup()

		let connected = engine.chosen != nil
		send.isEnabled = connected
		stop.isHidden = !engine.isWorking
		waiting.stringValue = engine.queue.isEmpty ? ""
			: "\(engine.queue.count) waiting — sent when this answer is done"
		hint.isHidden = !input.string.isEmpty

		if follow {
			layoutSubtreeIfNeeded()
			let bottom = max(0, page.bounds.height - scroll.contentView.bounds.height)
			scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom))
			scroll.reflectScrolledClipView(scroll.contentView)
		}
	}

	/// The card that stands where the conversation would be while there is
	/// nobody to have it with.
	private func renderSetup() {
		guard engine.link != .connected else {
			setup.isHidden = true
			setupShown = ""
			return
		}
		setup.isHidden = false
		if engine.link == .missing { browse() }
		let linking = engine.linking
		let state = "\(engine.link)|\(engine.problem ?? "")|\(servers)|\(String(describing: linking))"
		// Rebuilt only when what it says has changed: it is asked about every
		// four seconds, and a card rebuilt under a selection loses the selection
		// somebody was about to copy.
		guard state != setupShown else { return }
		setupShown = state
		setup.arrangedSubviews.forEach { $0.removeFromSuperview() }
		func say(_ text: String, _ color: NSColor = Theme.dimText, _ font: NSFont = Theme.body) {
			add(Self.label(text, color: color, font: font), to: setup)
		}
		guard engine.link == .missing else {
			say("Looking for an AI…")
			return
		}
		say("No AI connected", Theme.text, Theme.bodyStrong)
		if let problem = engine.problem { say(problem, Theme.base(.amber)) }
		say("The assistant talks to your own AI through ai-connector, which runs Claude Code and local models on this Mac. Run this in Terminal: it downloads ai-connector, checks it, and starts it now and at every login.")
		let command = Self.label(setupCommand(), color: Theme.text, font: ChatMarkdown.code)
		command.identifier = NSUserInterfaceItemIdentifier("chat-setup-command")
		command.drawsBackground = true
		command.backgroundColor = Theme.background
		add(command, to: setup)
		let copy = NSButton(title: "Copy Command", target: self, action: #selector(copyCommand))
		let again = NSButton(title: "Check Again", target: self, action: #selector(checkAgain))
		for button in [copy, again] { button.bezelStyle = .rounded; button.controlSize = .small }
		let buttons = NSStackView(views: [copy, again])
		buttons.spacing = 8
		setup.addArrangedSubview(buttons)
		say("cuttr finds it by itself once it runs — nothing to enter here.", Theme.faintText, Theme.label)

		if let linking {
			say("Linking \(linking.server)", Theme.text, Theme.bodyStrong)
			if let pin = linking.pin {
				say(pin, Theme.text, .monospacedSystemFont(ofSize: 22, weight: .semibold))
				say("Approve this PIN on the server. It stays valid for ten minutes.")
				let open = NSButton(title: "Open the Server's Page", target: self, action: #selector(openApproval))
				let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelLinking))
				for button in [open, cancel] { button.bezelStyle = .rounded; button.controlSize = .small }
				let row = NSStackView(views: [open, cancel])
				row.spacing = 8
				setup.addArrangedSubview(row)
			} else if let problem = linking.problem {
				say(problem, Theme.base(.amber))
			} else {
				say("Asking it for a PIN…")
			}
		} else if !servers.isEmpty {
			say("On your network", Theme.text, Theme.bodyStrong)
			for (index, server) in servers.enumerated() {
				let name = Self.label("\(server.name)\n\(server.url)", color: Theme.dimText, font: Theme.label)
				let link = NSButton(title: "Link…", target: self, action: #selector(linkTapped(_:)))
				link.tag = index
				link.bezelStyle = .rounded
				link.controlSize = .small
				let row = NSStackView(views: [name, link])
				row.spacing = 8
				setup.addArrangedSubview(row)
			}
			say("Models on another computer can be used; Claude Code only on this one.", Theme.faintText, Theme.label)
		}
		say("Or name any OpenAI-compatible address in Settings (⌘,): an `ai:` block with `url:` and `key:`.",
		    Theme.faintText, Theme.label)
	}

	// MARK: - Doing

	@objc private func sendTapped() {
		let text = input.string
		guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, engine.chosen != nil else { return }
		input.string = ""
		engine.send(text)
		// What was just sent should be seen, wherever the page was scrolled to.
		layoutSubtreeIfNeeded()
		scroll.contentView.scroll(to: NSPoint(
			x: 0, y: max(0, page.bounds.height - scroll.contentView.bounds.height)))
		render()
	}

	@objc private func stopTapped() { engine.stop() }
	@objc private func allowTapped() { engine.decide(true) }
	@objc private func declineTapped() { engine.decide(false) }
	@objc private func closeTapped() { onClose?() }
	@objc private func checkAgain() { look() }
	@objc private func cancelLinking() { engine.cancelLinking() }

	@objc private func modelChosen() {
		guard let key = models.selectedItem?.representedObject as? String else { return }
		engine.choose(key)
	}

	/// Clearing asks first when there is something to lose: there is no list of
	/// old conversations to get one back from.
	@objc private func clearTapped() {
		guard !engine.conversation.entries.isEmpty else { return }
		let alert = NSAlert()
		alert.messageText = "Clear the conversation?"
		alert.informativeText = "What the assistant changed stays changed. What was said is gone."
		alert.addButton(withTitle: "Clear")
		alert.addButton(withTitle: "Cancel")
		guard let window else { engine.clear(); return }
		alert.beginSheetModal(for: window) { [weak self] answer in
			if answer == .alertFirstButtonReturn { self?.engine.clear() }
		}
	}

	@objc private func copyCommand() {
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(setupCommand(), forType: .string)
	}

	@objc private func linkTapped(_ sender: NSButton) {
		guard servers.indices.contains(sender.tag) else { return }
		engine.link(to: servers[sender.tag].url)
	}

	@objc private func openApproval() {
		guard let page = engine.linking?.approveAt, let url = URL(string: page) else { return }
		NSWorkspace.shared.open(url)
	}

	func textDidChange(_ notification: Notification) {
		hint.isHidden = !input.string.isEmpty
	}

	// MARK: - For the tests

	var rowsForTesting: [ChatEntryView] { rows }
	var setupForTesting: NSStackView { setup }
	var confirmForTesting: NSStackView { confirm }
	var inputForTesting: NSTextView { input }
	func sendForTesting() { sendTapped() }
}

/// Where a message is typed. Return sends; ⇧Return is a new line.
@MainActor
final class ComposerView: NSTextView {
	var onSend: (() -> Void)?

	convenience init() {
		self.init(frame: NSRect(x: 0, y: 0, width: 300, height: 72))
		isRichText = false
		font = ChatMarkdown.body
		textColor = Theme.text
		insertionPointColor = Theme.text
		drawsBackground = false
		textContainerInset = NSSize(width: 5, height: 8)
		isVerticallyResizable = true
		autoresizingMask = [.width]
		textContainer?.widthTracksTextView = true
		isAutomaticQuoteSubstitutionEnabled = false
		isAutomaticDashSubstitutionEnabled = false
		// The window hands every text view the *document's* undo manager, and a
		// letter typed here is not an edit to a take: ⌘Z after asking a question
		// would un-type the question out of the cut's own history.
		allowsUndo = false
	}

	override func keyDown(with event: NSEvent) {
		let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
		if event.keyCode == 36 || event.keyCode == 76, !flags.contains(.shift), !flags.contains(.option),
		   !hasMarkedText() {
			onSend?()
			return
		}
		super.keyDown(with: event)
	}
}

/// One turn: what somebody said, or what the assistant did and answered.
@MainActor
final class ChatEntryView: NSView {

	private var shown: ChatEntry?
	private let stack = NSStackView()
	private let tools = NSStackView()
	private let text = ChatPanel.label("", color: Theme.text)
	private let problem = ChatPanel.label("", color: Theme.playhead)

	init() {
		super.init(frame: .roomToLayOutIn)
		translatesAutoresizingMaskIntoConstraints = false
		wantsLayer = true
		layer?.cornerRadius = 8
		tools.orientation = .vertical
		tools.alignment = .leading
		tools.spacing = 3
		stack.orientation = .vertical
		stack.alignment = .leading
		stack.spacing = 6
		stack.translatesAutoresizingMaskIntoConstraints = false
		for view in [tools, text, problem] as [NSView] { stack.addArrangedSubview(view) }
		addSubview(stack)
		NSLayoutConstraint.activate([
			stack.topAnchor.constraint(equalTo: topAnchor),
			stack.bottomAnchor.constraint(equalTo: bottomAnchor),
			stack.leadingAnchor.constraint(equalTo: leadingAnchor),
			stack.trailingAnchor.constraint(equalTo: trailingAnchor),
		])
	}

	@available(*, unavailable) required init?(coder: NSCoder) { nil }

	func update(_ entry: ChatEntry) {
		guard entry != shown else { return }
		let user = entry.role == .user
		layer?.backgroundColor = user ? Theme.cardHigh.cgColor : NSColor.clear.cgColor
		let inset: CGFloat = user ? 8 : 0
		stack.edgeInsets = NSEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)

		if entry.text != shown?.text || shown == nil {
			text.attributedStringValue = user
				? NSAttributedString(string: entry.text, attributes: [
					.font: ChatMarkdown.body, .foregroundColor: Theme.text])
				: ChatMarkdown.render(entry.text)
		}
		text.isHidden = entry.text.isEmpty

		if entry.tools != shown?.tools {
			while tools.arrangedSubviews.count > entry.tools.count {
				tools.arrangedSubviews.last?.removeFromSuperview()
			}
			for (index, tool) in entry.tools.enumerated() {
				if index == tools.arrangedSubviews.count {
					let row = ChatPanel.label("", color: Theme.dimText, font: Theme.label)
					row.maximumNumberOfLines = 2
					row.lineBreakMode = .byTruncatingTail
					tools.addArrangedSubview(row)
				}
				guard let row = tools.arrangedSubviews[index] as? NSTextField else { continue }
				row.stringValue = Self.line(tool)
				row.textColor = [.failed, .declined].contains(tool.state) ? Theme.base(.amber) : Theme.dimText
				row.toolTip = "\(tool.name) \(tool.arguments)"
					+ (tool.result.isEmpty ? "" : "\n\n\(tool.result.prefix(1200))")
			}
		}
		tools.isHidden = entry.tools.isEmpty

		switch entry.status {
		case .failed: problem.stringValue = entry.problem ?? "It failed."
		case .stopped: problem.stringValue = "Stopped."
		default: problem.stringValue = ""
		}
		problem.textColor = entry.status == .failed ? Theme.playhead : Theme.faintText
		problem.isHidden = problem.stringValue.isEmpty
		shown = entry
	}

	/// A tool call in a line: what it did once it has, and what it is until then.
	static func line(_ tool: ChatEntry.Tool) -> String {
		let said = tool.summary.isEmpty ? tool.name : tool.summary
		switch tool.state {
		case .asking: return "?  \(said)"
		case .running: return "…  \(tool.name)"
		case .done: return "✓  \(said)"
		case .failed: return "✕  \(said)"
		case .declined: return "–  \(said)"
		}
	}

	var textForTesting: String { text.stringValue }
	var toolLinesForTesting: [String] {
		tools.arrangedSubviews.compactMap { ($0 as? NSTextField)?.stringValue }
	}
}
