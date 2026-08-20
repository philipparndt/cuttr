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
	/// Space was pressed with the cursor in the text. What that means is the
	/// window's business — it is the one that knows whether the tape is
	/// already rolling — and ``selectedSpan`` is what it should play.
	public var onSpace: (() -> Void)?
	/// Make a clip of exactly these words.
	public var onClipWords: ((_ start: Double, _ end: Double) -> Void)?
	/// Something worth saying in the window's status line.
	public var onStatus: ((String) -> Void)?

	private let text = TranscriptText()
	private let scroll = NSScrollView()
	private let search = NSSearchField()
	private let provenance = NSTextField(labelWithString: "")
	private let language = NSPopUpButton()
	private let button = NSButton()

	private var transcript = Transcript()
	private var sounds: [SoundEvent] = []

	/// One thing in the laid-out text.
	///
	/// There were two kinds of thing in this text and there are now three, and
	/// three arrays that have to be kept parallel to each other is two too
	/// many. They are one kind with a ``What`` on it instead, because
	/// everything this pane does asks all three the same two questions: where
	/// are you in the text, and what stretch of the take are you? The selection
	/// arithmetic, the lit thing under the playhead and the menu are each one
	/// pass over one array now, and none of them has a special case in it.
	private struct Piece {
		enum What: Equatable {
			/// A word, by its index in the transcript.
			case word(Int)
			/// The silence after the word at this index. Not a word — the
			/// *absence* of one — but a real stretch of the take, and somebody
			/// who selects it means it.
			case pause(after: Int)
			/// Something that was heard and not said, by its index in
			/// ``sounds``. Selectable exactly like a word, because a laugh is
			/// as much a thing to play or cut as a sentence is.
			case sound(Int)
		}

		var what: What
		/// Where it sits in the text.
		var range: NSRange
		/// What stretch of the take it is, on the video's clock.
		var start: Double
		var end: Double

		var wordIndex: Int? {
			if case .word(let index) = what { return index }
			return nil
		}

		var soundIndex: Int? {
			if case .sound(let index) = what { return index }
			return nil
		}

		func contains(_ time: Double) -> Bool { time >= start && time < end }
	}

	/// Everything in the text, in the order it is laid out.
	private var pieces: [Piece] = []
	/// Where each word sits among the pieces, parallel to `transcript.words` —
	/// so that "the third word" is still one lookup, which is what the playhead
	/// asks for on every tick.
	private var wordPieces: [Int] = []
	/// The piece the playhead is inside, if any.
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
		// Space plays what is selected. A non-editable text view otherwise
		// treats it as "scroll down a page", which in a pane somebody is
		// reading alongside a picture is not what their thumb meant.
		text.onSpace = { [weak self] in
			guard let self, self.onSpace != nil else { return false }
			self.onSpace?()
			return true
		}
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
		// The first thing to give way when the pane is narrow: the language is
		// named by the pop-up beside it and the word count is a nicety, while
		// the two controls are the point of the row.
		provenance.lineBreakMode = .byTruncatingTail
		provenance.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
		provenance.setContentHuggingPriority(.defaultHigh, for: .horizontal)
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
	public func show(_ transcript: Transcript, words: Words?, sounds: [SoundEvent] = []) {
		let heard = sounds.sorted { $0.start < $1.start }
		guard !shown || transcript != self.transcript || words != shownWords
			|| heard != self.sounds else { return }
		shown = true
		shownWords = words
		self.transcript = transcript
		self.sounds = heard
		marked = nil
		searchedTo = 0
		pieces = []
		wordPieces = []

		let body = NSMutableAttributedString()

		/// A space before whatever comes next, unless a pause has just ended
		/// the line for us.
		func separate() {
			guard let last = pieces.last else { return }
			if case .pause = last.what { return }
			body.append(NSAttributedString(string: " ", attributes: [.font: Theme.transcript]))
		}

		func add(_ what: Piece.What, _ string: NSAttributedString,
		         from start: Double, to end: Double, length: Int? = nil) {
			let at = body.length
			body.append(string)
			if case .word(let index) = what {
				precondition(index == wordPieces.count)
				wordPieces.append(pieces.count)
			}
			pieces.append(Piece(what: what,
			                    range: NSRange(location: at, length: length ?? (body.length - at)),
			                    start: start, end: end))
		}

		if transcript.isEmpty, heard.isEmpty {
			body.append(NSAttributedString(
				string: "No words yet.\n\nTranscribe reads this take's audio on this Mac —"
					+ " nothing is uploaded — and writes what it hears into a file beside the"
					+ " take. Then: drag across a sentence to set in and out, ⏎ to make a clip"
					+ " of it, W to name a clip after what is said in it.",
				attributes: [.font: Theme.body, .foregroundColor: Theme.dimText]))
		} else {
			// Laid out by its silences: a line for a beat, a paragraph for a
			// rest, and an ellipsis at the end of the line so the pause itself
			// is on the page rather than merely implied by the white space.
			//
			// The sounds go in among the words at the moment they happened,
			// which is usually in one of those silences — people laugh between
			// sentences — so a laugh reads as the thing that came between two
			// lines, which is what it was.
			var next = 0
			func soundsBefore(_ time: Double) {
				while next < heard.count, heard[next].start < time {
					separate()
					add(.sound(next),
					    NSAttributedString(string: "[\(heard[next].label)]",
					                       attributes: [.font: Theme.transcript,
					                                    .foregroundColor: Theme.heardNotSaid]),
					    from: heard[next].start, to: heard[next].end)
					next += 1
				}
			}

			for (index, word) in transcript.words.enumerated() {
				soundsBefore(word.start)
				separate()
				add(.word(index),
				    NSAttributedString(string: word.text,
				                       attributes: [.font: Theme.transcript,
				                                    .foregroundColor: Theme.text]),
				    from: word.start, to: word.end)
				let silence = transcript.silence(after: index)
				guard silence != .none else { continue }
				// Only as far as the ellipsis: the newlines after it belong to
				// the layout rather than to the silence, and a selection that
				// runs to the end of a line should not be read as reaching into
				// the next one.
				add(.pause(after: index), pause(silence == .rest ? "\n\n" : "\n"),
				    from: word.end, to: transcript.words[index + 1].start, length: 2)
			}
			// Anything heard after the last word, or in a take where nobody
			// said anything at all.
			soundsBefore(.infinity)
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
			// Not the language: the pop-up beside this says that, and saying it
			// twice is what made the row too wide for its own heading.
			provenance.stringValue = "\(transcript.count) words · \(words.recogniser.rawValue)"
				+ (heard.isEmpty ? "" : " · \(heard.count) sounds")
		} else {
			provenance.stringValue = ""
		}
		button.title = transcript.isEmpty ? "Transcribe" : "Again"
	}

	/// While it plays. Lights whatever is happening and keeps it on screen.
	public var playhead: Double = 0 {
		didSet { mark(happening(at: playhead)) }
	}

	/// Whether the pane scrolls itself to keep up. Off while somebody is
	/// reading it with the tape stopped, so the text does not move under them.
	public var follows = false

	/// What is going on at `time`: the word being said, or the laugh being
	/// laughed. `nil` in the gaps, because the highlight is a claim about what
	/// is happening *now* — leaving the last word lit through four seconds of
	/// silence says she is still saying it.
	private func happening(at time: Double) -> Int? {
		if let word = transcript.index(at: time) { return wordPieces[safe: word] }
		return pieces.firstIndex { $0.soundIndex != nil && $0.contains(time) }
	}

	private func mark(_ index: Int?) {
		guard index != marked else { return }
		if let old = marked, old < pieces.count {
			text.textStorage?.removeAttribute(.backgroundColor, range: pieces[old].range)
		}
		marked = index
		guard let index, index < pieces.count else { return }
		// The playhead's own colour, so the lit word and the line on the
		// timeline are recognisably the same claim about where you are.
		text.textStorage?.addAttribute(
			.backgroundColor, value: Theme.playhead.withAlphaComponent(0.35),
			range: pieces[index].range)
		if follows { text.scrollRangeToVisible(pieces[index].range) }
	}

	/// The mark a pause leaves: dim, so it reads as the shape of the take
	/// rather than as something somebody said.
	private func pause(_ ending: String) -> NSAttributedString {
		NSAttributedString(string: " …" + ending,
		                   attributes: [.font: Theme.transcript, .foregroundColor: Theme.dimText])
	}

	/// What is selected, on the video's clock: a run of words, a silence, or
	/// both. `nil` when nothing is.
	public var selectedSpan: (start: Double, end: Double)? {
		let selected = text.selectedRange()
		guard selected.length > 0, let touched = touched(by: selected) else { return nil }
		return (touched.start, touched.end)
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
		guard !transcript.isEmpty, let about = clicked(at: charIndex) else { return nil }
		// Shown as chosen, so what the menu is about is what is lit.
		highlight(about.characters)
		pointed = (about.start, about.end)

		let made = NSMenu()
		let length = String(format: "%.1fs", about.end - about.start)
		made.addItem(item("Play \(about.name) · \(length)", #selector(playPointed)))
		made.addItem(item("Make a clip of \(about.count == 1 ? "it" : "them")", #selector(clipPointed)))
		made.addItem(.separator())
		made.addItem(item("Copy", #selector(NSText.copy(_:)), target: view))
		return made
	}

	private func item(_ title: String, _ action: Selector, target: AnyObject? = nil) -> NSMenuItem {
		let made = NSMenuItem(title: title, action: action, keyEquivalent: "")
		made.target = target ?? self
		return made
	}

	/// What a click is about: whatever is selected when the click is inside the
	/// selection, then the pause or the sound under the pointer, then the line
	/// it is in.
	///
	/// The pause and the sound come before the line because clicking an
	/// ellipsis is somebody pointing at the silence itself and clicking
	/// `[laughter]` is somebody pointing at the laugh — answering either with
	/// the sentence beside it would be answering a different question.
	private func clicked(at charIndex: Int)
		-> (start: Double, end: Double, characters: NSRange, name: String, count: Int)?
	{
		let selected = text.selectedRange()
		if selected.length > 0, NSLocationInRange(charIndex, selected),
		   let touched = touched(by: selected) {
			let count = touched.words?.count ?? 1
			return (touched.start, touched.end, selected, describe(selected), count)
		}
		if let at = pieces.firstIndex(where: { NSLocationInRange(charIndex, $0.range) }),
		   pieces[at].wordIndex == nil {
			let piece = pieces[at]
			return (piece.start, piece.end, piece.range,
			        piece.soundIndex.map { "[\(sounds[$0].label)]" } ?? "this pause", 1)
		}
		guard let index = word(containing: charIndex, orBefore: true) else { return nil }
		let line = transcript.segment(around: index)
		guard let span = transcript.span(line), let characters = characters(of: line)
		else { return nil }
		return (span.start, span.end, characters,
		        line.count == 1 ? "this word" : "these \(line.count) words", line.count)
	}

	/// What a selection is, said out loud: the words in it, else the sounds in
	/// it, else how long the silence was.
	private func describe(_ selected: NSRange) -> String {
		let hit = pieces.filter { NSIntersectionRange($0.range, selected).length > 0 }
		let spoken = hit.compactMap(\.wordIndex)
		if let first = spoken.min(), let last = spoken.max() {
			return spoken.count == 1 ? "this word" : "these \(last - first + 1) words"
		}
		let heard = hit.compactMap { $0.soundIndex.map { "[\(sounds[$0].label)]" } }
		if !heard.isEmpty { return heard.joined(separator: " ") }
		return "this pause"
	}

	/// Where a run of words sits in the text.
	private func characters(of range: Range<Int>) -> NSRange? {
		guard let first = wordPieces[safe: range.lowerBound].flatMap({ pieces[safe: $0] }),
		      let last = wordPieces[safe: range.upperBound - 1].flatMap({ pieces[safe: $0] })
		else { return nil }
		return NSRange(location: first.range.location,
		               length: NSMaxRange(last.range) - first.range.location)
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
		guard let whole = characters(of: range) else { return }
		highlight(whole)
	}

	private func highlight(_ characters: NSRange) {
		quiet = true
		text.setSelectedRange(characters)
		quiet = false
		text.scrollRangeToVisible(characters)
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
		guard !quiet, !pieces.isEmpty else { return }
		if selected.length == 0 {
			// A click. A non-editable text view answers one with an empty
			// selection where the caret would have gone, which is the only
			// thing about it worth knowing.
			if let at = pieces.firstIndex(where: { NSLocationInRange(selected.location, $0.range) }),
			   pieces[at].wordIndex == nil {
				onMoveTo?(pieces[at].start)
			} else if let index = word(containing: selected.location, orBefore: true) {
				clickWord(at: index)
			}
			return
		}
		guard let touched = touched(by: selected) else { return }
		onSelectWords?(touched.start, touched.end)
		let what = said(in: selected) ?? String(
			format: "a pause of %.1fs", touched.end - touched.start)
		onStatus?("\(Timecode.string(touched.start))–\(Timecode.string(touched.end))"
			+ (what.isEmpty ? "" : " · \(what) — ⏎ to make a clip"))
	}

	/// What a selection *says*, for the status line and for naming a clip after
	/// it: the words in it, or failing that the sounds in it. `nil` when it is
	/// nothing but silence, which has no words to be named after.
	func said(in selected: NSRange) -> String? {
		let hit = pieces.filter { NSIntersectionRange($0.range, selected).length > 0 }
		let spoken = hit.compactMap(\.wordIndex)
		if let first = spoken.min(), let last = spoken.max() {
			return transcript.phrase(first ..< (last + 1), limit: 4)
		}
		let heard = hit.compactMap { $0.soundIndex.map { "[\(sounds[$0].label)]" } }
		return heard.isEmpty ? nil : heard.joined(separator: " ")
	}

	/// Everything a selection covers: words, silences and sounds alike.
	///
	/// A pause is selectable because a pause is part of the take — the beat
	/// before an answer is often the thing that has to go, or the thing that
	/// has to stay — and a laugh is selectable for the plainer reason that it
	/// is a thing that happened. So the span runs from the earliest piece the
	/// selection touches to the latest, whatever kinds those are, which is also
	/// what the highlight on screen already says it is.
	///
	/// One pass over one array. This used to be two — a walk over the words and
	/// a filter over the pauses, reconciled afterwards — and a third kind of
	/// thing in the text would have made it three.
	func touched(by selected: NSRange) -> (start: Double, end: Double, words: Range<Int>?)? {
		let hit = pieces.filter { NSIntersectionRange($0.range, selected).length > 0 }
		guard let start = hit.map(\.start).min(), let end = hit.map(\.end).max() else { return nil }
		let spoken = hit.compactMap(\.wordIndex)
		guard let first = spoken.min(), let last = spoken.max() else { return (start, end, nil) }
		return (start, end, first ..< (last + 1))
	}

	/// Which word a character belongs to. A character in the space between two
	/// words belongs to whichever side the caller is looking from, so that a
	/// selection dragged from mid-gap to mid-gap covers the words between them
	/// and not one on either side.
	private func word(containing location: Int, orBefore: Bool) -> Int? {
		var before: Int?
		for piece in pieces {
			guard let index = piece.wordIndex else { continue }
			if location < piece.range.location { return orBefore ? before : index }
			if location < NSMaxRange(piece.range) { return index }
			before = index
		}
		return orBefore ? before : nil
	}

	/// For the tests: a real selection in the text view, the way dragging makes
	/// one — which is what `selectedSpan` reads.
	func selectForTest(_ characters: NSRange) {
		text.setSelectedRange(characters)
		selectionChanged(to: characters)
	}

	/// For the tests: the space bar, without the responder chain. Only the key
	/// the view claims is ever sent — an unclaimed one reaches `NSResponder`
	/// and beeps on somebody's machine.
	func pressSpaceForTest() {
		let event = NSEvent.keyEvent(
			with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
			windowNumber: 0, context: nil, characters: " ",
			charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!
		text.keyDown(with: event)
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
	var soundCount: Int { sounds.count }
	var markedWord: Int? { marked.flatMap { pieces[safe: $0]?.wordIndex } }
	var markedSound: Int? { marked.flatMap { pieces[safe: $0]?.soundIndex } }
	var searchField: NSSearchField { search }
}

private extension Array {
	subscript(safe index: Int) -> Element? {
		index >= 0 && index < count ? self[index] : nil
	}
}

/// The transcript's text view, which claims the space bar.
///
/// A subclass for one key, because the alternative is a monitor on the window
/// that has to work out whether the text view is first responder — and that
/// question has one honest answer here and it is this class.
@MainActor
final class TranscriptText: NSTextView {
	/// Returns true when it has dealt with it.
	var onSpace: (() -> Bool)?

	override func keyDown(with event: NSEvent) {
		if event.charactersIgnoringModifiers == " ", event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
		   onSpace?() == true {
			return
		}
		super.keyDown(with: event)
	}
}
