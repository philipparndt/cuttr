import AppKit
import CuttrKit

/// What was said, as text you can cut with.
///
/// The rest of this window looks at a recording as a shape — a waveform, a
/// picture, a bar on a timeline — and every one of those makes you *listen* to
/// find the sentence you meant. This pane is the same recording as words, so
/// finding it is reading, and the four things it can do are the four things
/// somebody does with a sentence they have found:
///
/// - drag across it, and it becomes the in/out span, so `⏎` makes it a clip;
/// - click a word, and the playhead goes there;
/// - play, and the word being spoken is lit, so the pane and the picture stay
///   in step in both directions;
/// - type a phrase into the field and be taken to it.
///
/// A text view rather than a list of rows. Speech is prose and it wraps like
/// prose: a table would give one word per line and a five-minute take would be
/// four hundred rows of one word each, which is neither readable nor
/// selectable as a sentence.
@MainActor
public final class TranscriptPane: NSView, NSTextViewDelegate {

	/// Words were selected: the span they cover, on the video's clock. What the
	/// window turns into the in/out marks.
	public var onSelectWords: ((_ start: Double, _ end: Double) -> Void)?
	/// A word was clicked: take the playhead there.
	public var onMoveTo: ((Double) -> Void)?
	/// The button in the heading, with the language to listen in.
	public var onTranscribe: ((Locale) -> Void)?
	/// Somebody chose a language. Worth remembering for the next take.
	public var onLanguage: ((String) -> Void)?
	/// Play exactly these words, and stop at the end of them.
	public var onPlayWords: ((_ start: Double, _ end: Double) -> Void)?
	/// Make a clip of exactly these words.
	public var onClipWords: ((_ start: Double, _ end: Double) -> Void)?
	/// Something worth saying in the window's status line.
	public var onStatus: ((String) -> Void)?

	private let text = NSTextView()
	private let scroll = NSScrollView()
	private let search = NSSearchField()
	private let provenance = NSTextField(labelWithString: "")
	private let language = NSPopUpButton()
	private let button = NSButton()

	private var transcript = Transcript()
	/// Where each word sits in the text, parallel to `transcript.words`.
	private var ranges: [NSRange] = []
	/// The word the playhead is in, if any.
	private var marked: Int?
	/// Set while the selection is being changed from here, so that redrawing
	/// the pane does not read back as somebody having selected something.
	private var quiet = false
	/// Where the last find stopped, so pressing Return again goes to the next
	/// one rather than back to the same place.
	private var searchedTo = 0
	/// What is on screen, so the window's refresh can be ignored when nothing
	/// about the transcript has changed.
	private var shown = false
	private var shownWords: Words?
	/// The languages offered, parallel to the pop-up's items.
	private var known: [Transcriber.Language] = []
	/// What the menu that is open is about, on the video's clock.
	private var pointed: (start: Double, end: Double)?

	public override init(frame: NSRect) {
		super.init(frame: frame)
		wantsLayer = true
		layer?.backgroundColor = Theme.panel.cgColor
		build()
	}

	@available(*, unavailable) required init?(coder: NSCoder) { nil }

	// MARK: - Building it

	private func build() {
		search.font = Theme.body
		search.placeholderString = "Find a phrase"
		search.target = self
		search.action = #selector(searchChanged)
		// Whole string, on Return: unlike the library's filter, this *moves*
		// the playhead, and jumping the picture about on every keystroke while
		// somebody types a sentence is not a thing to do to them.
		search.sendsSearchStringImmediately = false
		search.sendsWholeSearchString = true

		text.isEditable = false
		text.isSelectable = true
		text.isRichText = false
		text.drawsBackground = true
		text.backgroundColor = Theme.panel
		text.textColor = Theme.text
		text.font = Theme.transcript
		text.delegate = self
		text.textContainerInset = NSSize(width: 4, height: 6)
		text.isVerticallyResizable = true
		text.isHorizontallyResizable = false
		text.autoresizingMask = [.width]
		text.textContainer?.widthTracksTextView = true
		text.selectedTextAttributes = [
			.backgroundColor: Theme.accent.withAlphaComponent(0.45),
			.foregroundColor: NSColor.white,
		]

		scroll.documentView = text
		scroll.hasVerticalScroller = true
		scroll.drawsBackground = false
		scroll.borderType = .noBorder

		let stack = NSStackView(views: [search, scroll])
		stack.orientation = .vertical
		stack.spacing = 6
		stack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
		stack.translatesAutoresizingMaskIntoConstraints = false
		addSubview(stack)
		scroll.translatesAutoresizingMaskIntoConstraints = false
		NSLayoutConstraint.activate([
			stack.topAnchor.constraint(equalTo: topAnchor),
			stack.bottomAnchor.constraint(equalTo: bottomAnchor),
			stack.leadingAnchor.constraint(equalTo: leadingAnchor),
			stack.trailingAnchor.constraint(equalTo: trailingAnchor),
			search.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16),
			scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16),
		])

		provenance.font = Theme.monoSmall
		provenance.textColor = Theme.dimText
		button.title = "Transcribe"
		button.bezelStyle = .rounded
		button.controlSize = .small
		button.target = self
		button.action = #selector(transcribePressed)
		button.toolTip = "Reads the audio on this Mac and writes the words beside the take.\n"
			+ "Nothing is uploaded. Ask once; the file is kept."

		language.controlSize = .small
		language.font = Theme.label
		language.target = self
		language.action = #selector(languageChanged)
		language.toolTip = "What language is spoken in this take.\n"
			+ "A take listened to in the wrong one comes back as confident nonsense."
		// Forty-five languages named in full make a pop-up wider than the pane
		// it sits in, and the heading is a row, not a column.
		language.translatesAutoresizingMaskIntoConstraints = false
		language.widthAnchor.constraint(lessThanOrEqualToConstant: 190).isActive = true
	}

	/// The heading's furniture, for the pane that provides the heading — what
	/// made these words, and the way to ask for them.
	public func detachedHead() -> NSView {
		let row = NSStackView(views: [provenance, language, button])
		row.orientation = .horizontal
		row.spacing = 8
		row.alignment = .centerY
		return row
	}

	// MARK: - What it listens in

	/// The languages this Mac has, and which of them to use for this take.
	///
	/// A take that has been transcribed already says which language it was
	/// heard in, and that is the one shown — reading a take again in a
	/// different language than the words beside it were made in is a thing
	/// somebody has to *choose*, not a thing that happens because the Mac's own
	/// language is English.
	public func offer(_ languages: [Transcriber.Language], choosing identifier: String?) {
		// Rebuilding the menu drops whatever was chosen, so a language this Mac
		// does not have would silently become the first in the list.
		let previous = chosenLanguage
		known = languages
		language.removeAllItems()
		for entry in languages {
			language.addItem(withTitle: entry.installed
				? "\(entry.name) — \(entry.identifier)"
				: "\(entry.name) — \(entry.identifier) (fetches)")
			language.lastItem?.representedObject = entry.identifier
		}
		language.isEnabled = !languages.isEmpty
		if !select(identifier) { _ = select(previous) }
	}

	/// The language somebody has chosen, as a tag.
	public var chosenLanguage: String? {
		language.selectedItem?.representedObject as? String
	}

	/// Chooses the best match for a tag: the tag itself, then anything in the
	/// same language — `de` picks `de-DE` — then what is already chosen.
	@discardableResult
	private func select(_ identifier: String?) -> Bool {
		guard let identifier, !identifier.isEmpty else { return false }
		let index = known.firstIndex { $0.identifier == identifier }
			?? known.firstIndex { $0.identifier.hasPrefix(identifier.prefix(2) + "-") }
		guard let index else { return false }
		language.selectItem(at: index)
		return true
	}

	@objc private func languageChanged() {
		guard let chosen = chosenLanguage else { return }
		onLanguage?(chosen)
		if let entry = known.first(where: { $0.identifier == chosen }), !entry.installed {
			onStatus?("\(entry.name) will be fetched the first time it is used")
		}
	}

	// MARK: - Showing it

	/// The words, and where they came from.
	///
	/// Called from the window's general refresh, which runs on every edit —
	/// so it returns early unless something here has actually changed. Laying
	/// four hundred words out again on every keystroke would be waste, and it
	/// would also drop the selection somebody was in the middle of making.
	public func show(_ transcript: Transcript, words: Words?) {
		guard !shown || transcript != self.transcript || words != shownWords else { return }
		shown = true
		shownWords = words
		self.transcript = transcript
		marked = nil
		searchedTo = 0
		ranges = []

		let body = NSMutableAttributedString()
		if transcript.isEmpty {
			body.append(NSAttributedString(
				string: "No words yet.\n\nTranscribe reads this take's audio on this Mac —"
					+ " nothing is uploaded — and writes what it hears into a file beside the"
					+ " take. Then: drag across a sentence to set in and out, ⏎ to make a clip"
					+ " of it, W to name a clip after its first words.",
				attributes: [.font: Theme.body, .foregroundColor: Theme.dimText]))
		} else {
			// Laid out by its silences: a line for a beat, a paragraph for a
			// rest, and an ellipsis at the end of the line so the pause itself
			// is on the page rather than merely implied by the white space.
			//
			// `ranges` stays parallel to the *words* — the ellipses and the
			// newlines are not words, and every other thing this pane does
			// (the lit word, the selection, the find) counts in words.
			for (index, word) in transcript.words.enumerated() {
				let start = body.length
				body.append(NSAttributedString(
					string: word.text,
					attributes: [.font: Theme.transcript, .foregroundColor: Theme.text]))
				ranges.append(NSRange(location: start, length: body.length - start))
				switch transcript.silence(after: index) {
				case .none:
					if index + 1 < transcript.count {
						body.append(NSAttributedString(
							string: " ", attributes: [.font: Theme.transcript]))
					}
				case .beat:
					body.append(pause("\n"))
				case .rest:
					body.append(pause("\n\n"))
				}
			}
		}

		quiet = true
		text.textStorage?.setAttributedString(body)
		text.setSelectedRange(NSRange(location: 0, length: 0))
		quiet = false

		// A take that has words says which language they were heard in, and that
		// is a fact about this take rather than a preference: showing anything
		// else beside them would be a lie about where they came from.
		if let words, !words.locale.isEmpty { select(words.locale) }

		if let words, !transcript.isEmpty {
			provenance.stringValue = "\(transcript.count) words · \(words.recogniser.rawValue)"
				+ (words.locale.isEmpty ? "" : " · \(words.locale)")
		} else {
			provenance.stringValue = ""
		}
		button.title = transcript.isEmpty ? "Transcribe" : "Again"
	}

	/// While it plays. Lights the word being said and keeps it on screen.
	public var playhead: Double = 0 {
		didSet { mark(transcript.index(at: playhead)) }
	}

	/// Whether the pane scrolls itself to keep up. Off while somebody is
	/// reading it with the tape stopped, so the text does not move under them.
	public var follows = false

	private func mark(_ index: Int?) {
		guard index != marked else { return }
		if let old = marked, old < ranges.count {
			text.textStorage?.removeAttribute(.backgroundColor, range: ranges[old])
		}
		marked = index
		guard let index, index < ranges.count else { return }
		// The playhead's own colour, so the lit word and the line on the
		// timeline are recognisably the same claim about where you are.
		text.textStorage?.addAttribute(
			.backgroundColor, value: Theme.playhead.withAlphaComponent(0.35), range: ranges[index])
		if follows { text.scrollRangeToVisible(ranges[index]) }
	}

	/// The mark a pause leaves: dim, so it reads as the shape of the take
	/// rather than as something somebody said.
	private func pause(_ ending: String) -> NSAttributedString {
		NSAttributedString(string: " …" + ending,
		                   attributes: [.font: Theme.transcript, .foregroundColor: Theme.dimText])
	}

	// MARK: - The menu on the words

	/// What a right-click means, which is not what one usually means in a text
	/// view.
	///
	/// The system's menu here offers to look the word up in a dictionary and to
	/// speak it aloud — for a transcript of somebody speaking, the second is a
	/// joke. What is wanted is the two things this pane exists for, aimed at
	/// whatever was clicked: a selection if there is one, and otherwise the line
	/// under the pointer, which is the run of words between two silences and is
	/// what somebody means when they point at it.
	public func textView(
		_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int
	) -> NSMenu? {
		guard !transcript.isEmpty, let words = clicked(at: charIndex),
		      let span = transcript.span(of: words) else { return nil }
		// Shown as chosen, so what the menu is about is what is lit.
		highlight(words)
		pointed = span

		let made = NSMenu()
		let count = words.count
		let length = String(format: "%.1fs", span.end - span.start)
		made.addItem(item("Play \(count == 1 ? "this word" : "these \(count) words") · \(length)",
		                  #selector(playPointed)))
		made.addItem(item("Make a clip of \(count == 1 ? "it" : "them")", #selector(clipPointed)))
		made.addItem(.separator())
		made.addItem(item("Copy", #selector(NSText.copy(_:)), target: view))
		return made
	}

	private func item(_ title: String, _ action: Selector, target: AnyObject? = nil) -> NSMenuItem {
		let made = NSMenuItem(title: title, action: action, keyEquivalent: "")
		made.target = target ?? self
		return made
	}

	/// The words a click is about: the selection when it covers any, and the
	/// line under the pointer when it does not.
	private func clicked(at charIndex: Int) -> Range<Int>? {
		let selected = text.selectedRange()
		if selected.length > 0,
		   let first = word(containing: selected.location, orBefore: false),
		   let last = word(containing: NSMaxRange(selected) - 1, orBefore: true),
		   first <= last,
		   NSLocationInRange(charIndex, selected) {
			return first..<(last + 1)
		}
		guard let index = word(containing: charIndex, orBefore: true) else { return nil }
		return transcript.segment(around: index)
	}

	@objc private func playPointed() {
		guard let pointed else { return }
		onPlayWords?(pointed.start, pointed.end)
	}

	@objc private func clipPointed() {
		guard let pointed else { return }
		onClipWords?(pointed.start, pointed.end)
	}

	// MARK: - What it does

	/// A word was clicked. Public so a test can ask without an event.
	func clickWord(at index: Int) {
		guard index >= 0, index < transcript.count else { return }
		onMoveTo?(transcript.words[index].start)
	}

	/// A run of words was selected: that is the in/out span.
	func selectWords(_ range: Range<Int>) {
		guard let span = transcript.span(range) else { return }
		onSelectWords?(span.start, span.end)
		let phrase = transcript.phrase(range, limit: 4)
		onStatus?("\(Timecode.string(span.start))–\(Timecode.string(span.end))"
			+ (phrase.isEmpty ? "" : " · \(phrase) — ⏎ to make a clip"))
	}

	/// Selects a run of words in the text, without reporting it back.
	private func highlight(_ range: Range<Int>) {
		guard let first = ranges[safe: range.lowerBound],
		      let last = ranges[safe: range.upperBound - 1] else { return }
		let whole = NSRange(location: first.location,
		                    length: last.location + last.length - first.location)
		quiet = true
		text.setSelectedRange(whole)
		quiet = false
		text.scrollRangeToVisible(whole)
	}

	/// Finds a phrase and goes to it. The hook the search field calls, and the
	/// one a test calls instead of typing.
	@discardableResult
	func find(_ phrase: String) -> Range<Int>? {
		let trimmed = phrase.trimmingCharacters(in: .whitespaces)
		guard !trimmed.isEmpty else { return nil }
		guard let found = transcript.find(trimmed, from: searchedTo) else {
			onStatus?("no “\(trimmed)” in this take")
			return nil
		}
		searchedTo = found.upperBound
		highlight(found)
		selectWords(found)
		// Taken there, not merely shown: the point of finding a sentence is to
		// look at it, and that means the picture as well as the text.
		onMoveTo?(transcript.words[found.lowerBound].start)
		return found
	}

	@objc private func searchChanged() { find(search.stringValue) }

	@objc private func transcribePressed() {
		onTranscribe?(chosenLanguage.map(Locale.init(identifier:)) ?? .current)
	}

	/// Said while the recogniser is running, in place of the word count.
	public func setNote(_ note: String) { provenance.stringValue = note }

	/// The button, greyed while there is nothing to listen to or while it is
	/// already listening.
	public func setBusy(_ busy: Bool, enabled: Bool = true) {
		button.isEnabled = enabled && !busy
		button.title = busy ? "Listening…" : (transcript.isEmpty ? "Transcribe" : "Again")
	}

	// MARK: - The text view talking back

	public func textViewDidChangeSelection(_ notification: Notification) {
		selectionChanged(to: text.selectedRange())
	}

	/// What a change of selection means, given as characters.
	///
	/// Split out from the delegate method so a test can hand it a range
	/// instead of a mouse: what is worth checking here is the arithmetic that
	/// turns character positions into words, and dragging a pointer across a
	/// view is a poor way to ask about arithmetic.
	func selectionChanged(to selected: NSRange) {
		guard !quiet, !ranges.isEmpty else { return }
		if selected.length == 0 {
			// A click. A non-editable text view answers one with an empty
			// selection where the caret would have gone, which is the only
			// thing about it worth knowing.
			if let index = word(containing: selected.location, orBefore: true) { clickWord(at: index) }
			return
		}
		guard let first = word(containing: selected.location, orBefore: false),
		      let last = word(containing: NSMaxRange(selected) - 1, orBefore: true)
		else { return }
		selectWords(first ..< (last + 1))
	}

	/// Which word a character belongs to. A character in the space between two
	/// words belongs to whichever side the caller is looking from, so that a
	/// selection dragged from mid-gap to mid-gap covers the words between them
	/// and not one on either side.
	private func word(containing location: Int, orBefore: Bool) -> Int? {
		guard !ranges.isEmpty else { return nil }
		for (index, range) in ranges.enumerated() {
			if location < range.location { return orBefore ? (index > 0 ? index - 1 : nil) : index }
			if location < NSMaxRange(range) { return index }
		}
		return orBefore ? ranges.count - 1 : nil
	}

	/// For the tests: the laid-out text, and the menu without a mouse.
	var shownText: String { text.string }

	func menuForTest(at charIndex: Int) -> NSMenu? {
		let event = NSEvent.mouseEvent(
			with: .rightMouseDown, location: .zero, modifierFlags: [],
			timestamp: 0, windowNumber: 0, context: nil,
			eventNumber: 0, clickCount: 1, pressure: 1)!
		return textView(text, menu: NSMenu(), for: event, at: charIndex)
	}

	/// For the tests: what the pane is showing.
	var wordCount: Int { transcript.count }
	var markedWord: Int? { marked }
	var searchField: NSSearchField { search }
}

private extension Array {
	subscript(safe index: Int) -> Element? {
		index >= 0 && index < count ? self[index] : nil
	}
}
