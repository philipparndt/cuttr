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
	/// The button in the heading.
	public var onTranscribe: (() -> Void)?
	/// Something worth saying in the window's status line.
	public var onStatus: ((String) -> Void)?

	private let text = NSTextView()
	private let scroll = NSScrollView()
	private let search = NSSearchField()
	private let provenance = NSTextField(labelWithString: "")
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
		text.font = Theme.body
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
	}

	/// The heading's furniture, for the pane that provides the heading — what
	/// made these words, and the way to ask for them.
	public func detachedHead() -> NSView {
		let row = NSStackView(views: [provenance, button])
		row.orientation = .horizontal
		row.spacing = 8
		row.alignment = .centerY
		return row
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
			for (index, word) in transcript.words.enumerated() {
				if index > 0 { body.append(NSAttributedString(string: " ")) }
				let start = body.length
				body.append(NSAttributedString(
					string: word.text,
					attributes: [.font: Theme.body, .foregroundColor: Theme.text]))
				ranges.append(NSRange(location: start, length: body.length - start))
			}
		}

		quiet = true
		text.textStorage?.setAttributedString(body)
		text.setSelectedRange(NSRange(location: 0, length: 0))
		quiet = false

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

	@objc private func transcribePressed() { onTranscribe?() }

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
