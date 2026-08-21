@preconcurrency import AVFoundation
import AppKit
import CuttrCompose
import CuttrKit

/// Every take of the project at once, with its level under it.
///
/// **Levelling is a comparison, and one take at a time is the one thing you
/// cannot compare.** ``CuttrKit/Take/gain`` has existed since the renderer
/// needed it and has been set, until now, in the take editor's set-up popover —
/// a field in a window showing one recording. So the number that balances this
/// recording against the others was typed where the others are not, which is
/// why it was mostly left alone. This page is the place it was meant for: one
/// row a take, all the audio lines drawn at one scale, a slider under each.
///
/// Three decisions hold the whole thing up.
///
/// **One scale, and it is shared by construction.** Every lane is drawn at the
/// same seconds-per-point — ``LevelScale`` works it out from the longest row —
/// and at the same amplitude scale, because the rows are the same height and
/// nothing here normalises a row to its own peak. The longest take fills the
/// width and every shorter one ends where it ends. A row stretched to fit would
/// be a lie about which take is longer, and two rows at two amplitude scales
/// would make the comparison this page exists for impossible while looking
/// exactly like it was working.
///
/// **The level is in the picture.** The drawn amplitude is multiplied by
/// ``CuttrKit/Levelling/amplitude(_:)`` of the take's own gain and clipped
/// against the lane, the same as the cutting room's timeline: pushing a take up
/// until it flattens against the top of its lane is the lane saying so.
///
/// **A row is the take's contribution, not the whole recording.** What is
/// drawn, what plays and what is measured are the same stretches of tape — the
/// spans this project actually uses, merged and in order. A five-minute
/// recording of which twenty seconds is used would otherwise be levelled
/// against four minutes and forty seconds of room tone, which is the mistake
/// ``CuttrKit/LoudnessMeter/measure(url:ranges:)`` was given its `ranges` for.
@MainActor
public final class LevelsPage: NSView {

	/// A line for the bar, and how far along a pass is. The page has no status
	/// line of its own: it is a page in a window that already has one.
	public var onSay: ((String) -> Void)?
	public var onProgress: ((Double?) -> Void)?

	private let board = LevelBoard()
	/// One take at a time. Levelling is a comparison and comparing means
	/// hearing one, then the other — two at once is a mix, which is a different
	/// question and not this one.
	private let transport = Transport()
	private var playing: URL?
	private var playTask: Task<Void, Never>?
	private var waveTask: Task<Void, Never>?
	private var measureTask: Task<Void, Never>?

	/// The display magnifier, shared by every lane on purpose.
	///
	/// The same distinction the timeline makes: a zoom changes nothing that will
	/// be heard, a level does. Per-row it would be a way of making two rows look
	/// alike that are not, so there is one of it for the page.
	private var zoom = 1.0

	private let rowsStack = NSStackView()
	private let scroll: NSScrollView
	private let measureButton = NSButton()
	private let zoomLabel = NSTextField(labelWithString: "×1")
	private let hint = NSTextField(labelWithString: "")
	private var empty: EmptyState?
	private var rowViews: [LevelRowView] = []

	public override init(frame frameRect: NSRect) {
		rowsStack.orientation = .vertical
		rowsStack.alignment = .leading
		rowsStack.spacing = 2
		rowsStack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 10, right: 10)
		// Laid out by constraints rather than by its frame, because a scroll
		// view's document view is normally frame-based and this one has to be
		// exactly as wide as the clip view while being as tall as its rows.
		rowsStack.translatesAutoresizingMaskIntoConstraints = false
		scroll = TableScroll.wrap(rowsStack, horizontal: false)
		super.init(frame: frameRect)
		wantsLayer = true
		layer?.backgroundColor = Theme.panel.cgColor
		build()
		board.onChange = { [weak self] in self?.refresh() }
	}

	@available(*, unavailable) required init?(coder: NSCoder) { nil }

	// MARK: - Layout

	private func build() {
		measureButton.title = "Measure"
		measureButton.bezelStyle = .rounded
		measureButton.controlSize = .small
		measureButton.font = NSFont.systemFont(ofSize: 11)
		measureButton.target = self
		measureButton.action = #selector(measurePressed)
		measureButton.toolTip = "Listen to every take over the spans this project uses,"
			+ " and propose trims that bring them level with the middle of what was heard."

		hint.font = Theme.monoSmall
		hint.textColor = Theme.dimText
		hint.stringValue = "one scale for every row — the longest take fills the width"
		// A sentence may not decide how wide the window is. A label's intrinsic
		// width is the width of its whole string whatever its truncation says,
		// which is how a warning line once opened this window five screens
		// wide — see `problemLabel`.
		hint.lineBreakMode = .byTruncatingTail
		hint.usesSingleLineMode = true
		hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
		hint.setContentHuggingPriority(.defaultLow, for: .horizontal)

		zoomLabel.font = Theme.monoSmall
		zoomLabel.textColor = Theme.dimText

		let head = NSStackView(views: [hint, NSView(), zoomOut(), zoomLabel, zoomIn(), measureButton])
		head.orientation = .horizontal
		head.spacing = 6
		head.alignment = .centerY
		head.translatesAutoresizingMaskIntoConstraints = false
		scroll.translatesAutoresizingMaskIntoConstraints = false
		addSubview(head)
		addSubview(scroll)
		NSLayoutConstraint.activate([
			head.topAnchor.constraint(equalTo: topAnchor, constant: 8),
			head.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
			head.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

			scroll.topAnchor.constraint(equalTo: head.bottomAnchor, constant: 6),
			scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
			scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
			scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
			rowsStack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
			rowsStack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
			// As wide as what is actually visible, not as the scroll view: the
			// vertical scroller takes room from the clip view, and a stack as
			// wide as the whole thing would put a horizontal scroller under a
			// page that has nothing to scroll sideways to.
			rowsStack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
		])
	}

	private func zoomIn() -> NSButton { zoomButton("plus", by: 2) }
	private func zoomOut() -> NSButton { zoomButton("minus", by: 0.5) }

	private func zoomButton(_ symbol: String, by factor: Double) -> NSButton {
		let button = NSButton()
		button.bezelStyle = .rounded
		button.controlSize = .small
		button.imagePosition = .imageOnly
		button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)
		button.target = self
		button.action = factor > 1 ? #selector(zoomedIn) : #selector(zoomedOut)
		button.toolTip = "Magnify every waveform. A magnifier, not a level: nothing"
			+ " about what will be heard changes."
		return button
	}

	@objc private func zoomedIn() { setZoom(zoom * 2) }
	@objc private func zoomedOut() { setZoom(zoom / 2) }

	/// The same clamp the timeline uses, so the two windows magnify by the same
	/// amounts.
	func setZoom(_ value: Double) {
		zoom = min(max(value, 0.25), 64)
		zoomLabel.stringValue = String(format: "×%g", zoom)
		for view in rowViews { view.zoom = zoom }
	}

	/// The shared scale is worked out here because here is the only place that
	/// knows how wide a lane came out.
	public override func layout() {
		super.layout()
		applyScale()
	}

	private func applyScale() {
		guard let width = rowViews.first?.laneWidth, width > 1 else { return }
		let scale = LevelScale.across(rowViews.map(\.length), width: width)
		for view in rowViews { view.scale = scale }
	}

	// MARK: - What there is to level

	/// Reads the project's takes. Called when the page comes up rather than on
	/// every project change: it reads every take file, and the levels of takes
	/// nobody is looking at are not worth a read per keystroke in the editor.
	public func reload(from document: ComposeDocument) {
		// Anything half-set goes to the file before the rows are replaced under
		// it. A slider let go of writes; a slider dragged and then left by
		// switching pages must not be a level somebody set and lost.
		commitPending()
		board.reload(from: document)
		rebuildRows()
		loadWaves()
	}

	private func rebuildRows() {
		for view in rowViews { view.removeFromSuperview() }
		rowViews = []
		empty?.removeFromSuperview()
		empty = nil

		guard !board.rows.isEmpty else {
			let state = EmptyState(.take, "No takes to level",
			                       "A project's levels are a comparison between its "
				                       + "recordings. Add takes on the Edit page first.")
			addSubview(state)
			NSLayoutConstraint.activate([
				state.centerXAnchor.constraint(equalTo: centerXAnchor),
				state.centerYAnchor.constraint(equalTo: centerYAnchor),
			])
			empty = state
			measureButton.isEnabled = false
			return
		}
		measureButton.isEnabled = true

		for row in board.rows {
			let view = LevelRowView(row)
			view.zoom = zoom
			view.onLevel = { [weak self] value, finished in
				self?.level(row.url, to: value, finished: finished)
			}
			view.onPlay = { [weak self] in self?.togglePlay(row.url) }
			rowsStack.addView(view, in: .top)
			// The row fills the stack between its insets. A width rather than
			// leading and trailing anchors: the stack states the leading edge
			// itself, and saying it twice is how two constraints come to
			// disagree about one edge.
			view.widthAnchor.constraint(equalTo: rowsStack.widthAnchor,
			                            constant: -20).isActive = true
			rowViews.append(view)
		}
		refresh()
	}

	/// The rows say again what the board says. Cheap: a row is a label, a
	/// slider and a lane, and the lane redraws itself.
	private func refresh() {
		// The board is read before the rows are rebuilt against it — a project
		// that has just gained a take says so before there is a view for it —
		// and pairing off two lists of different lengths would show one take's
		// level on another take's row.
		guard rowViews.count == board.rows.count else { return }
		for (view, row) in zip(rowViews, board.rows) {
			view.show(row, spans: board.fileSpans(for: row), playing: playing == row.url)
		}
		applyScale()
		needsLayout = true
	}

	// MARK: - The slider

	/// A level as it is dragged, and once more when it is let go.
	///
	/// **The file is written on release and not before.** A slider is sixty
	/// events a second and a take file is the product: writing on every one of
	/// them would rewrite a file per pixel of travel, and — because a take
	/// being written is what tells the project window to keep a version — would
	/// fill somebody's version branch with a commit per pixel too. Leaving it
	/// to ⌘S was the other candidate and does not work: ⌘S saves the *open
	/// documents*, and the takes on this page are files the project points at,
	/// not documents in a window. A level nobody wrote would be a level lost
	/// with the window.
	private func level(_ url: URL, to value: Double, finished: Bool) {
		let wanted = LevelBoard.level(fromSlider: value)
		board.set(wanted, for: url)
		// What is heard follows the slider while it is being dragged, which is
		// the only way somebody can set a level by ear.
		if playing == url { transport.gain = wanted }
		if finished {
			switch board.commit(url) {
			case .wrote(let name): say("\(name) at \(LevelBoard.decibels(wanted))")
			case .unchanged: break
			// A card unplugged mid-session, usually. Named, because the row
			// will still show the level it was given and the file will not.
			case .failed(let why):
				say("could not write \(url.deletingPathExtension().lastPathComponent) — \(why)")
			}
		}
		refresh()
	}

	/// Writes whatever is half-set. The way out of the page, and the way the
	/// window closes.
	@discardableResult
	public func commitPending() -> [String] {
		let written = board.commitPending()
		if !written.isEmpty {
			say(written.count == 1 ? "levelled \(written[0])"
				: "levelled \(written.count) takes")
		}
		return written
	}

	// MARK: - Listening

	/// Plays what the row draws: the stretches of this take the project uses,
	/// laid end to end, at the level the slider says.
	///
	/// The whole recording was the other option and is the wrong one — minutes
	/// of it are not in the programme, and a level is a decision about the parts
	/// that are.
	private func togglePlay(_ url: URL) {
		guard let row = board.rows.first(where: { $0.url == url }) else { return }
		if playing == url {
			stopPlaying()
			return
		}
		guard let media = row.media else {
			say("\(row.name) has no media to play")
			return
		}
		playTask?.cancel()
		playing = url
		refresh()
		let spans = board.fileSpans(for: row)
		let gain = row.gain
		playTask = Task { [weak self] in
			guard let assembled = await LevelBoard.assemble(media, spans: spans) else {
				guard let self, !Task.isCancelled else { return }
				self.playing = nil
				self.refresh()
				self.say("could not read \(media.lastPathComponent)")
				return
			}
			guard let self, !Task.isCancelled, self.playing == url else { return }
			// The mix is handed over with the composition rather than set after
			// it: `Transport.gain` only reaches the player when it *changes*,
			// and two takes at the same level would otherwise play the second
			// one at full.
			self.transport.present(
				assembled.composition, videoComposition: nil,
				audioMix: LevelBoard.mix(gain, over: assembled.composition),
				duration: assembled.duration)
			self.transport.gain = gain
			self.transport.play()
		}
	}

	private func stopPlaying() {
		playTask?.cancel()
		playTask = nil
		transport.pause()
		playing = nil
		refresh()
	}

	/// Off the page: nothing plays behind a view that is not showing, and
	/// anything half-set goes to the file.
	public func stop() {
		stopPlaying()
		waveTask?.cancel()
		waveTask = nil
		measureTask?.cancel()
		measureTask = nil
		onProgress?(nil)
		commitPending()
	}

	// MARK: - Drawing the lines

	/// Decodes every take's audio, and shows each row as it arrives.
	///
	/// Concurrently, because a project is a dozen recordings and one at a time
	/// is a page that looks broken for a minute. The extractor serialises the
	/// decoding itself — see ``CuttrKit/WaveformExtractor`` — so this is not a
	/// dozen decoders fighting over the disk; it is a dozen files whose
	/// metadata is read at once and whose rows fill in as they finish.
	private func loadWaves() {
		waveTask?.cancel()
		var jobs: [(URL, URL)] = []
		for row in board.rows where row.waveform == nil {
			guard let media = row.media else { continue }
			// Asked of the file system rather than of the decoder. A card that
			// has been unplugged is the commonest reason a row has no line in
			// it, and "the audio has gone" is a different thing to be told from
			// whatever AVFoundation says about a file it cannot open.
			guard FileManager.default.fileExists(atPath: media.path) else {
				board.show(nil, problem: "\(media.lastPathComponent) is not there", for: row.url)
				continue
			}
			jobs.append((row.url, media))
		}
		guard !jobs.isEmpty else { return }
		say("decoding \(jobs.count) recording\(jobs.count == 1 ? "" : "s")…")
		onProgress?(0)
		waveTask = Task { [weak self] in
			var done = 0
			await withTaskGroup(of: (URL, Waveform?, String?).self) { group in
				for (take, media) in jobs {
					group.addTask {
						do { return (take, try await WaveformExtractor.extract(
							url: media, bucketsPerSecond: LevelBoard.bucketsPerSecond), nil) }
						catch { return (take, nil, error.localizedDescription) }
					}
				}
				for await (take, wave, problem) in group {
					guard let self, !Task.isCancelled else { continue }
					self.board.show(wave, problem: problem, for: take)
					done += 1
					self.onProgress?(Double(done) / Double(jobs.count))
				}
			}
			guard let self, !Task.isCancelled else { return }
			self.onProgress?(nil)
			self.say("\(jobs.count) recording\(jobs.count == 1 ? "" : "s") drawn at one scale")
		}
	}

	// MARK: - Measuring

	@objc private func measurePressed() { measure() }

	/// Listens to every take and proposes trims.
	///
	/// Concurrently, and saying how far along it is. The cutting room's
	/// per-clip version of this measured serially at first and was reported as
	/// "not working", because minutes passed with nothing on screen — which is
	/// indistinguishable from a button that does nothing.
	public func measure() {
		guard measureTask == nil else { return }
		measureButton.isEnabled = false
		say("listening to \(board.rows.count) takes to level them…")
		onProgress?(0)
		measureTask = Task { [weak self] in
			guard let self else { return }
			let line = await self.board.measure { [weak self] fraction in
				self?.onProgress?(fraction)
			}
			guard !Task.isCancelled else { return }
			self.measureTask = nil
			self.measureButton.isEnabled = true
			self.onProgress?(nil)
			self.say(line)
			self.refresh()
		}
	}

	private func say(_ text: String) { onSay?(text) }

	// MARK: - For the tests

	var rowsForTesting: [LevelRowView] { rowViews }
	/// What a drag on the nth slider does, without an `NSEvent`: a synthesised
	/// event nothing handles walks up the responder chain and beeps on
	/// somebody's desk.
	func dragForTesting(_ index: Int, to value: Double, finished: Bool) {
		guard index < board.rows.count else { return }
		level(board.rows[index].url, to: value, finished: finished)
	}
}

/// One seconds-per-point for every row.
///
/// The arithmetic is four lines and has a type of its own because it is the
/// claim the page rests on: rows drawn at two scales cannot be compared, and a
/// scale worked out per row is exactly what would happen if each lane were left
/// to fit its own contents. So it is computed once, from the longest row, and
/// handed to all of them.
public struct LevelScale: Hashable, Sendable {
	/// How much time a point of width is worth. Nought when there is nothing to
	/// draw, which every caller has to allow for anyway.
	public let secondsPerPoint: Double

	public init(secondsPerPoint: Double) {
		self.secondsPerPoint = secondsPerPoint
	}

	/// The longest of them fills the width; the rest end where they end.
	///
	/// Stretching every row to the full width was the alternative and would be
	/// a lie about the material: two rows the same length on screen, one of
	/// them four times the tape. A row that stops two thirds of the way across
	/// is a take that contributes two thirds as much, which is worth seeing.
	public static func across(_ lengths: [Double], width: CGFloat) -> LevelScale {
		let longest = lengths.filter { $0.isFinite && $0 > 0 }.max() ?? 0
		guard longest > 0, width > 1 else { return LevelScale(secondsPerPoint: 0) }
		return LevelScale(secondsPerPoint: longest / Double(width))
	}

	public func width(forSeconds seconds: Double) -> CGFloat {
		guard secondsPerPoint > 0, seconds > 0 else { return 0 }
		return CGFloat(seconds / secondsPerPoint)
	}

	public func seconds(atX x: CGFloat) -> Double { Double(x) * secondsPerPoint }
}

/// The takes of one project, their levels, and what was heard.
///
/// The model behind ``LevelsPage``, kept apart from it so that the questions
/// with right answers — which spans are measured, when a level reaches the
/// file, whether an unchanged take is written — can be asked without a window.
@MainActor
public final class LevelBoard {

	/// One take.
	public struct Row {
		/// The take file, which is also this row's identity: a project cannot
		/// list the same take twice.
		public let url: URL
		public let name: String
		/// What somebody will actually hear: the separate recorder when there is
		/// one, because that is why it was recorded, and the video's own sound
		/// otherwise.
		public let media: URL?
		/// Seconds to add to the recorder's clock to reach the video's — nought
		/// when the media *is* the video. One clock: see the house rules.
		public let offset: Double
		/// The stretches of this take the project uses, on the take's own
		/// (video) clock, merged and in order. **Empty means the whole
		/// recording**, which is what the meter already means by no ranges.
		public let spans: [ClosedRange<Double>]
		/// The level as it stands here, which is what the slider moves.
		public var gain: Double
		/// The level the file says, so a row can show that it is owed a write.
		public var written: Double
		public var waveform: Waveform?
		/// What it measured, LUFS, once anybody has asked.
		public var loudness: Double?
		public var problem: String?

		/// Set but not written. Half a hundredth of a decibel, because the file
		/// holds two places and anything finer is the same number.
		public var isPending: Bool { abs(gain - written) >= 0.005 }

		/// How much tape this row draws: its contribution, or the whole
		/// recording when the project uses none of it and the decode has said
		/// how long that is.
		public var length: Double {
			guard !spans.isEmpty else { return waveform?.duration ?? 0 }
			return spans.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
		}
	}

	/// What a write came to.
	public enum Written: Equatable {
		case wrote(String)
		case unchanged
		case failed(String)
	}

	public private(set) var rows: [Row] = []
	public var onChange: (() -> Void)?

	/// Coarser than the timeline's millisecond, because a row here is minutes
	/// of tape in eight hundred points and the alignment pane's resolution
	/// would be 29 MB an hour bought for nothing.
	static let bucketsPerSecond = 200.0

	public init() {}

	// MARK: - Reading the project

	/// Builds a row per take the project lists — all of them, including the
	/// ones the timeline does not use yet, because a level is a fact about a
	/// recording and somebody balancing a shoot wants the whole shoot in front
	/// of them.
	///
	/// Waveforms already decoded are kept: switching to this page and back must
	/// not decode a folder of footage twice.
	public func reload(from document: ComposeDocument) {
		let used = spansUsed(by: document.resolved)
		let waves = Dictionary(uniqueKeysWithValues: rows.map { ($0.url, $0.waveform) })
		let heard = Dictionary(uniqueKeysWithValues: rows.map { ($0.url, $0.loudness) })
		rows = document.takes.map { entry in
			let directory = entry.url.deletingLastPathComponent()
			let take = (try? String(contentsOf: entry.url, encoding: .utf8))
				.flatMap { try? TakeReader.read($0) }
			let audio = take?.audio.map {
				URL(fileURLWithPath: $0.file, relativeTo: directory).standardizedFileURL
			}
			let video = take?.video.map {
				URL(fileURLWithPath: $0, relativeTo: directory).standardizedFileURL
			}
			let gain = take?.gain ?? 0
			return Row(
				url: entry.url,
				name: entry.name,
				media: audio ?? video,
				// The offset relates two clocks and only means anything about
				// the recorder's file. The camera's own sound is already on the
				// clock the clips are on.
				offset: audio == nil ? 0 : (take?.audio?.offset ?? 0),
				spans: Self.spans(of: take, usedBy: used[entry.name] ?? []),
				gain: gain,
				written: gain,
				waveform: waves[entry.url] ?? nil,
				loudness: heard[entry.url] ?? nil,
				problem: entry.problem)
		}
		onChange?()
	}

	/// What the programme plays, take by take, on each take's own clock.
	private func spansUsed(by resolved: ResolvedProject?) -> [String: [ClosedRange<Double>]] {
		var found: [String: [ClosedRange<Double>]] = [:]
		for clip in resolved?.clips ?? [] {
			found[clip.takeName, default: []].append(clip.clip.span)
		}
		return found
	}

	/// The stretches of a take this page draws, plays and measures.
	///
	/// The ladder is deliberate. What the programme uses is the answer when
	/// there is one — it is what a level is a decision about. A take the
	/// timeline has not reached yet still has to be levelled before it is
	/// dropped in, so its own clips are the next best statement of what it is
	/// for. A take nobody has cut at all is the whole recording, said by an
	/// empty list, which is what ``CuttrKit/LoudnessMeter`` already means by no
	/// ranges.
	static func spans(of take: Take?, usedBy used: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
		if !used.isEmpty { return merged(used) }
		let own = (take?.clips ?? []).map(\.span)
		return own.isEmpty ? [] : merged(own)
	}

	/// One stretch of tape per stretch of tape.
	///
	/// A clip used twice, and two clips cut on different lanes over the same
	/// seconds, are both one piece of recording as far as a level is concerned.
	/// Merging is what keeps the three things this page does — draw, play,
	/// measure — about exactly the same audio: the meter counts a second once
	/// however many ranges cover it, so anything that drew or played it twice
	/// would be levelling by a picture of something it had not measured.
	static func merged(_ spans: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
		let sorted = spans.filter { $0.upperBound > $0.lowerBound }
			.sorted { $0.lowerBound < $1.lowerBound }
		var out: [ClosedRange<Double>] = []
		for span in sorted {
			if let last = out.last, span.lowerBound <= last.upperBound {
				out[out.count - 1] = last.lowerBound ... max(last.upperBound, span.upperBound)
			} else {
				out.append(span)
			}
		}
		return out
	}

	/// The row's spans on the *media file's* own clock.
	///
	/// One clock, and this is the one place the other one is dealt with: clip
	/// times are on the video's, a separate recorder has its own, and the take's
	/// offset is the only thing that relates them. A positive offset means the
	/// recorder was started after the camera, so a clip at video time `t` is at
	/// `t − offset` in its file — and a clip from before the recorder was
	/// rolling is trimmed to where the file begins rather than asked for at a
	/// negative second.
	public func fileSpans(for row: Row) -> [ClosedRange<Double>] {
		guard !row.spans.isEmpty else { return [] }
		return row.spans.compactMap { span in
			let end = span.upperBound - row.offset
			guard end > 0 else { return nil }
			return max(0, span.lowerBound - row.offset) ... end
		}
	}

	// MARK: - The level

	/// What a slider position means, in decibels.
	///
	/// Decibels straight off the slider, not a curve: a decibel *is* the
	/// perceptual scale, and a slider linear in amplitude would spend two
	/// thirds of its travel on the top six units.
	///
	/// Bounded by ``CuttrKit/Levelling/limit`` on both sides, the same figure
	/// the automatic match is bounded by, and snapped to a tenth — which is
	/// finer than anybody can hear and is what the take file holds exactly. A
	/// value the file cannot say would come back different on the next read and
	/// leave the take looking edited when nothing had changed.
	public static func level(fromSlider value: Double) -> Double {
		let bounded = min(max(value, -Levelling.limit), Levelling.limit)
		return (bounded * 10).rounded() / 10
	}

	/// A level as it reads on the row: a sign, a tenth, and `0` for nought
	/// rather than a blank, because a row with no number in it looks like a row
	/// that has not loaded.
	public static func decibels(_ value: Double) -> String {
		let text = TakeWriter.number(abs(value), places: 1)
		return value > 0 ? "+\(text) dB" : (value < 0 ? "−\(text) dB" : "0 dB")
	}

	/// Moves a level in memory. Nothing is written: see
	/// ``LevelsPage/level(_:to:finished:)`` for why not.
	public func set(_ gain: Double, for url: URL) {
		guard let index = rows.firstIndex(where: { $0.url == url }),
		      rows[index].gain != gain else { return }
		rows[index].gain = gain
		onChange?()
	}

	/// Puts one row's level in its take file.
	///
	/// **Read again, then write.** The take on disk may have been re-cut in
	/// another tab since this page read it, and a level is one key of a file
	/// that is somebody else's work — so what goes back is that file with this
	/// one number changed, written by the hand-written emitter, which is what
	/// carries the comments and the keys this version does not understand
	/// through. An unchanged level writes nothing at all: re-saving a take that
	/// has not changed must leave the file alone.
	@discardableResult
	public func commit(_ url: URL) -> Written {
		guard let index = rows.firstIndex(where: { $0.url == url }) else { return .unchanged }
		let wanted = rows[index].gain
		do {
			var take = try TakeReader.read(try String(contentsOf: url, encoding: .utf8))
			guard take.gain != wanted else {
				rows[index].written = wanted
				return .unchanged
			}
			take.gain = wanted
			try TakeWriter.write(take).write(to: url, atomically: true, encoding: .utf8)
			rows[index].written = wanted
			// How the project window notices: it re-resolves, so the preview
			// plays at the level that was just set, and it keeps a version.
			NotificationCenter.default.post(
				name: .cuttrTakeChanged, object: url.standardizedFileURL)
			onChange?()
			return .wrote(rows[index].name)
		} catch {
			rows[index].problem = error.localizedDescription
			onChange?()
			return .failed(error.localizedDescription)
		}
	}

	/// Writes every row that is owed one, and names them. Only those: a take
	/// nobody touched is not rewritten.
	@discardableResult
	public func commitPending() -> [String] {
		var written: [String] = []
		for row in rows where row.isPending {
			if case .wrote(let name) = commit(row.url) { written.append(name) }
		}
		return written
	}

	// MARK: - What was heard

	public func show(_ waveform: Waveform?, problem: String?, for url: URL) {
		guard let index = rows.firstIndex(where: { $0.url == url }) else { return }
		rows[index].waveform = waveform
		if let problem { rows[index].problem = problem }
		onChange?()
	}

	/// Measures every take over the spans it contributes, and proposes trims.
	///
	/// Matched to the median of what was heard — see
	/// ``CuttrKit/Levelling/match(_:existing:limit:)`` for why the median and
	/// not the loudest and not a target. What lands in the file is `gain` and
	/// only `gain`: the measured figures are deliberately *not* written into
	/// `measured:`, because that is what a project matching to
	/// `output.audio.target` reads, and a take both matched to a target and
	/// trimmed toward the median would be two things pulling at one knob.
	///
	/// Returns the one line the window should say.
	public func measure(progress: @escaping (Double) -> Void) async -> String {
		let jobs = rows.enumerated().compactMap { index, row -> (Int, URL, [ClosedRange<Double>])? in
			guard let media = row.media else { return nil }
			return (index, media, fileSpans(for: row))
		}
		guard jobs.count >= 2 else {
			return "levelling is a comparison — this project has one take to listen to"
		}
		var measured = [Double?](repeating: nil, count: rows.count)
		var done = 0
		await withTaskGroup(of: (Int, Double?).self) { group in
			for (index, media, spans) in jobs {
				group.addTask {
					let heard = try? await LoudnessMeter.measure(url: media, ranges: spans)
					return (index, heard?.integrated)
				}
			}
			for await (index, loudness) in group {
				measured[index] = loudness
				done += 1
				progress(Double(done) / Double(jobs.count))
			}
		}
		guard !Task.isCancelled else { return "" }

		let before = rows.map(\.gain)
		let wanted = Levelling.match(measured, existing: before)
		for (index, level) in wanted.enumerated() where index < rows.count {
			rows[index].loudness = measured[index]
			rows[index].gain = level
		}
		let written = commitPending()
		onChange?()

		let silent = jobs.count - measured.compactMap { $0 }.count
		let widest = zip(wanted, before).map { abs($0 - $1) }.max() ?? 0
		var line = "heard \(jobs.count - silent) takes, \(written.count) moved"
		if widest >= 0.1 { line += String(format: ", the furthest by %.1f dB", widest) }
		if silent > 0 { line += " — \(silent) had nothing to measure and were left alone" }
		return line
	}

	// MARK: - Playing it

	/// The take's contribution as one thing to play: its spans, in order, laid
	/// end to end.
	///
	/// The same stretches the row draws and the meter measures. Audio only —
	/// there is no picture on this page, and a level is set by ear and by the
	/// line under it.
	static func assemble(_ media: URL, spans: [ClosedRange<Double>])
		async -> (composition: AVComposition, duration: Double)? {
		let asset = AVURLAsset(url: media)
		guard let source = try? await asset.loadTracks(withMediaType: .audio).first else { return nil }
		let whole = (try? await asset.load(.duration)) ?? .zero
		let composition = AVMutableComposition()
		guard let track = composition.addMutableTrack(
			withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
		let scale: Int32 = 48000
		var cursor = CMTime.zero
		let wanted = spans.isEmpty ? [0 ... whole.seconds] : spans
		for span in wanted {
			let start = CMTime(seconds: span.lowerBound, preferredTimescale: scale)
			let length = CMTime(seconds: span.upperBound - span.lowerBound, preferredTimescale: scale)
			guard length > .zero, start < whole else { continue }
			let fits = min(length, whole - start)
			try? track.insertTimeRange(CMTimeRange(start: start, duration: fits),
			                           of: source, at: cursor)
			cursor = cursor + fits
		}
		guard cursor > .zero else { return nil }
		return (composition, cursor.seconds)
	}

	/// The level, as a mix over what is about to be played.
	///
	/// ``CuttrKit/Levelling/amplitude(_:)`` again — the one conversion from what
	/// the file says to what a mix wants — so what is heard here is what the
	/// renderer will encode.
	static func mix(_ gain: Double, over composition: AVComposition) -> AVAudioMix? {
		guard gain != 0 else { return nil }
		let volume = Float(Levelling.amplitude(gain))
		let mix = AVMutableAudioMix()
		mix.inputParameters = composition.tracks(withMediaType: .audio).map { track in
			let parameters = AVMutableAudioMixInputParameters(track: track)
			parameters.setVolume(volume, at: .zero)
			return parameters
		}
		return mix
	}
}

/// One take's row: what it is called, its level, and its audio line.
@MainActor
public final class LevelRowView: NSView {

	/// A level as it is dragged. `finished` is what says the mouse has come up,
	/// which is when the file is written.
	public var onLevel: ((_ decibels: Double, _ finished: Bool) -> Void)?
	public var onPlay: (() -> Void)?

	private let name = NSTextField(labelWithString: "")
	private let slider = NSSlider()
	private let readout = NSTextField(labelWithString: "")
	private let heard = NSTextField(labelWithString: "")
	private let playButton = NSButton()
	private let lane = LevelLane()

	public var zoom: Double = 1 {
		didSet { lane.zoom = zoom }
	}

	public var scale: LevelScale {
		get { lane.scale }
		set { lane.scale = newValue }
	}

	/// How much tape this row has to draw, for the shared scale.
	public private(set) var length: Double = 0

	/// How wide the lane came out, which is the width the scale is worked out
	/// against. Every row's is the same — the controls to its left are all
	/// fixed widths — which is what makes one scale possible at all.
	public var laneWidth: CGFloat { lane.bounds.width }

	public init(_ row: LevelBoard.Row) {
		super.init(frame: .roomToLayOutIn)
		translatesAutoresizingMaskIntoConstraints = false

		name.font = Theme.mono
		name.textColor = Theme.text
		name.lineBreakMode = .byTruncatingMiddle
		name.usesSingleLineMode = true
		name.translatesAutoresizingMaskIntoConstraints = false
		name.widthAnchor.constraint(equalToConstant: 150).isActive = true

		slider.minValue = -Levelling.limit
		slider.maxValue = Levelling.limit
		slider.doubleValue = row.gain
		slider.numberOfTickMarks = 5
		slider.allowsTickMarkValuesOnly = false
		slider.tickMarkPosition = .below
		slider.controlSize = .small
		slider.isContinuous = true
		slider.target = self
		slider.action = #selector(dragged)
		slider.toolTip = "Decibels for this whole recording, against the others."
			+ "\nThe waveform grows with it, and flattens when it clips."
			+ "\nWritten to the take file when the slider is let go."
		slider.translatesAutoresizingMaskIntoConstraints = false
		slider.widthAnchor.constraint(equalToConstant: 130).isActive = true

		readout.font = Theme.mono
		readout.alignment = .right
		readout.translatesAutoresizingMaskIntoConstraints = false
		readout.widthAnchor.constraint(equalToConstant: 62).isActive = true

		heard.font = Theme.monoSmall
		heard.textColor = Theme.faintText
		heard.alignment = .right
		heard.translatesAutoresizingMaskIntoConstraints = false
		heard.widthAnchor.constraint(equalToConstant: 74).isActive = true

		playButton.bezelStyle = .rounded
		playButton.controlSize = .small
		playButton.imagePosition = .imageOnly
		playButton.target = self
		playButton.action = #selector(played)
		playButton.toolTip = "Play the stretches of this take the project uses,"
			+ " at the level above. One take at a time."
		playButton.translatesAutoresizingMaskIntoConstraints = false
		playButton.widthAnchor.constraint(equalToConstant: 28).isActive = true

		let line = NSStackView(views: [name, slider, readout, heard, playButton, lane])
		line.orientation = .horizontal
		line.spacing = 8
		line.alignment = .centerY
		line.translatesAutoresizingMaskIntoConstraints = false
		addSubview(line)
		NSLayoutConstraint.activate([
			line.topAnchor.constraint(equalTo: topAnchor, constant: 3),
			line.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
			line.leadingAnchor.constraint(equalTo: leadingAnchor),
			line.trailingAnchor.constraint(equalTo: trailingAnchor),
			lane.heightAnchor.constraint(equalToConstant: 46),
		])
		show(row, spans: [], playing: false)
	}

	@available(*, unavailable) required init?(coder: NSCoder) { nil }

	// MARK: - State in

	public func show(_ row: LevelBoard.Row, spans: [ClosedRange<Double>], playing: Bool) {
		name.stringValue = row.name
		name.toolTip = row.url.path
		// Not while it is being dragged: putting the value back under the mouse
		// is how a slider fights the hand on it.
		if !dragging { slider.doubleValue = row.gain }
		readout.stringValue = LevelBoard.decibels(row.gain)
		// A level that is not nought is a decision, and it is written in the
		// colour of something somebody said rather than of something derived.
		readout.textColor = row.gain == 0 ? Theme.faintText : Theme.text
		// A dot for a level that is set and not yet in the file, which is the
		// state a slider still under somebody's finger is in.
		readout.stringValue += row.isPending ? " •" : ""
		heard.stringValue = row.loudness.map { String(format: "%.1f LUFS", $0) } ?? ""
		playButton.image = NSImage(
			systemSymbolName: playing ? "stop.fill" : "play.fill",
			accessibilityDescription: playing ? "stop" : "play")
		length = row.length
		lane.show(row, spans: spans)
	}

	// MARK: - Actions

	/// True between the first drag event and the mouse coming up, so that a
	/// refresh does not put the old value back under the hand.
	private var dragging = false

	@objc private func dragged() {
		// `NSSlider` says whether the mouse is still down, which is exactly the
		// question "is this drag finished" — the same reading `LookPanel` takes.
		let finished = NSApp.currentEvent.map { $0.type != .leftMouseDragged } ?? true
		dragging = !finished
		onLevel?(slider.doubleValue, finished)
	}

	@objc private func played() { onPlay?() }

}

/// One take's audio line, at the page's scale and the take's level.
@MainActor
public final class LevelLane: NSView {

	private var waveform: Waveform?
	/// On the media file's own clock, in the order they play. Empty means the
	/// whole recording.
	private var spans: [ClosedRange<Double>] = []
	private var gain: Double = 0
	private var caption = ""
	private var problem: String?

	public var zoom: Double = 1 { didSet { needsDisplay = true } }
	public var scale = LevelScale(secondsPerPoint: 0) {
		didSet { if scale != oldValue { needsDisplay = true } }
	}

	public init() {
		super.init(frame: .roomToLayOutIn)
		translatesAutoresizingMaskIntoConstraints = false
		setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
	}

	@available(*, unavailable) required init?(coder: NSCoder) { nil }

	public override var isFlipped: Bool { true }

	public func show(_ row: LevelBoard.Row, spans: [ClosedRange<Double>]) {
		waveform = row.waveform
		self.spans = spans
		gain = row.gain
		problem = row.problem
		caption = row.media?.lastPathComponent ?? "no media"
		needsDisplay = true
	}

	/// How far a sample of 1 reaches from the middle of a lane this tall.
	///
	/// The take's own level as well as the display zoom, which are two
	/// different things — the zoom is a magnifying glass and changes nothing,
	/// the level is what will be heard. One conversion from decibels, the same
	/// one the mix uses, so the picture and the sound cannot disagree.
	static func amplitude(height: CGFloat, zoom: Double, gain: Double) -> CGFloat {
		(height / 2 - 2) * CGFloat(zoom) * CGFloat(Levelling.amplitude(gain))
	}

	/// Where a lane this tall stops. A peak pushed past this is drawn flat
	/// against the edge, the same as any overdriven peak: a take turned up
	/// until its row flattens is the row saying so.
	static func limit(height: CGFloat) -> CGFloat { height / 2 - 1 }

	/// The stretches this lane draws. An empty list means the whole recording,
	/// which is only knowable once it has been decoded.
	private var drawn: [ClosedRange<Double>] {
		guard spans.isEmpty else { return spans }
		guard let duration = waveform?.duration, duration > 0 else { return [] }
		return [0 ... duration]
	}

	public override func draw(_ dirtyRect: NSRect) {
		Theme.panel.setFill()
		bounds.fill()

		let middle = bounds.midY
		Theme.rule.setStroke()
		let centre = NSBezierPath()
		centre.move(to: NSPoint(x: 0, y: middle))
		centre.line(to: NSPoint(x: bounds.maxX, y: middle))
		centre.lineWidth = 0.5
		centre.stroke()

		guard let waveform, scale.secondsPerPoint > 0 else {
			write(problem ?? "decoding audio…", at: 6)
			return
		}
		let stretches = drawn
		let total = stretches.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
		guard total > 0 else {
			write("nothing of this take is used", at: 6)
			return
		}

		// The ground under the part of the lane there is tape for, so a take
		// that contributes a third of the longest one reads as a third of a row
		// rather than as a row that failed to draw.
		let end = min(scale.width(forSeconds: total), bounds.maxX)
		Theme.card.setFill()
		NSRect(x: 0, y: 0, width: end, height: bounds.height).fill()

		let reach = Self.amplitude(height: bounds.height, zoom: zoom, gain: gain)
		let limit = Self.limit(height: bounds.height)
		let path = NSBezierPath()
		path.lineWidth = 1
		var x: CGFloat = 0
		while x < end {
			let a = scale.seconds(atX: x), b = scale.seconds(atX: x + 1)
			if let from = time(at: a, in: stretches), let to = time(at: b, in: stretches),
			   let extremes = waveform.extremes(from: from, to: max(to, from)) {
				let top = middle - min(CGFloat(extremes.max) * reach, limit)
				let bottom = middle - max(CGFloat(extremes.min) * reach, -limit)
				// Half a point either side, so a quiet passage is a line rather
				// than nothing: "there is audio here and it is quiet" and
				// "there is no audio here" have to look different.
				path.move(to: NSPoint(x: x + 0.5, y: min(top, middle - 0.5)))
				path.line(to: NSPoint(x: x + 0.5, y: max(bottom, middle + 0.5)))
			}
			x += 1
		}
		Theme.externalWave.setStroke()
		path.stroke()

		// A hairline where one stretch of tape gives way to the next, because
		// the row is a splice and pretending otherwise would make a cut look
		// like a transient.
		Theme.rule.setStroke()
		var cursor = 0.0
		for span in stretches.dropLast() {
			cursor += span.upperBound - span.lowerBound
			let at = scale.width(forSeconds: cursor)
			let mark = NSBezierPath()
			mark.move(to: NSPoint(x: at, y: 2))
			mark.line(to: NSPoint(x: at, y: bounds.height - 2))
			mark.lineWidth = 0.5
			mark.stroke()
		}

		write(caption, at: 6)
		let length = Timecode.string(total)
		let width = (length as NSString).size(withAttributes: [.font: Theme.monoSmall]).width
		write(length, at: max(6, min(end, bounds.maxX) - width - 6))
	}

	private func write(_ text: String, at x: CGFloat) {
		(text as NSString).draw(
			at: NSPoint(x: x, y: bounds.height - 13),
			withAttributes: [.font: Theme.monoSmall, .foregroundColor: Theme.dimText])
	}

	/// Where a second of the row lands in the recording: the row is the
	/// stretches laid end to end, so this walks them.
	private func time(at seconds: Double, in stretches: [ClosedRange<Double>]) -> Double? {
		var cursor = 0.0
		for span in stretches {
			let length = span.upperBound - span.lowerBound
			if seconds <= cursor + length { return span.lowerBound + (seconds - cursor) }
			cursor += length
		}
		return nil
	}
}
