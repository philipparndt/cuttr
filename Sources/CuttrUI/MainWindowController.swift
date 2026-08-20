import AppKit
import AVFoundation
import CuttrKit
import UniformTypeIdentifiers

/// One window, one take.
///
/// This is where the keyboard lives, and the keyboard is the program. Cutting a
/// forty-minute recording into eighty named clips is eighty repetitions of the
/// same three seconds — mark, name, carry on — and anything that puts a mouse in
/// the middle of that loop costs a minute per take. So: every editing verb has a
/// bare key, the keys are under the left hand, and naming a clip is the *same*
/// keystroke that made it.
@MainActor
public final class MainWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {

	public let takeDocument: TakeDocument
	private let transport = Transport()

	private let bar = DocumentBar()
	/// What this take is made of, behind the take's name.
	private let setup = TakeSetup()
	/// The six lane colours, on the clips pane's heading, beside the clips they
	/// colour.
	private let swatches = ColorSwatches()
	/// Which microphone you hear, over the two lanes it chooses between.
	private let monitor = NSSegmentedControl()
	private let timeline = TimelineView()
	private let clipTable = ClipTable()
	private let anchorTable = AnchorTable()
	private let lookPanel = LookPanel()
	private let transcriptPane = TranscriptPane()
	/// The four things this window knows about the take, one at a time, chosen
	/// from the rail down the left edge.
	private let rail = Rail([
		Rail.Item("Clips", "timeline.selection", "What has been cut out of this take"),
		Rail.Item("Faces", "scope", "The faces being followed, for an overlay to hang on"),
		Rail.Item("Words", "text.alignleft", "What was said, and what was heard"),
		Rail.Item("Look", "circle.lefthalf.filled", "The grade this take is shown through"),
	])
	private var panes: PaneStack?
	/// A drag on a slider is sixty changes and one undo step: the first one
	/// registers the undo, and the rest are folded into it.
	private var gradingSince: Take?
	private var playerView: PlayerView!
	private let markers = AnchorMarkerView()
	private var solveTask: Task<Void, Never>?
	private var namingTask: Task<Void, Never>?
	/// Asking the model what a clip should be called. Its own task, because it
	/// is cancelled by the *next* proposal and by nothing else — an answer for
	/// a clip somebody has moved on from is an answer nobody wants.
	private var nameProposalTask: Task<Void, Never>?
	private var wordsTask: Task<Void, Never>?
	private var speakerTask: Task<Void, Never>?
	private var soundsTask: Task<Void, Never>?

	private var playhead: Double = 0
	private var pending: (start: Double, end: Double)?
	/// Whether the pending span came from reading the transcript rather than
	/// from marking.
	///
	/// The two look identical on the timeline and mean different things
	/// afterwards. A clip made from a sentence somebody has just read is a clip
	/// they have already decided about, so proposing a name for it is the next
	/// thing they were going to do anyway. A clip made by marking is the middle
	/// of a loop — play, mark, play, mark — and a text field in front of the
	/// next `S` stops that loop dead, which is a lesson this program has
	/// already learned once.
	private var pendingFromWords = false
	private var selectedClip: Clip.ID?
	/// The colour the next clip gets.
	///
	/// Follows the selection — clicking a rose clip makes rose current — so that
	/// "cut another one like that" needs no second gesture. Picking a swatch
	/// with a clip selected recolours it *and* sets this, which is the same
	/// rule any drawing program uses.
	private var currentColor: ClipColor = .default
	private var keyMonitor: Any?
	/// Set while a clip drag is in flight, so sixty mouse-moved events collapse
	/// into one undo step instead of sixty.
	private var dragUndoOpen = false

	public init(document: TakeDocument) {
		self.takeDocument = document
		let window = NSWindow(
			contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
			// No `.fullSizeContentView`: the bar along the top is a real strip
			// with the clock in it, and under a transparent titlebar the
			// document's name ends up behind the traffic lights.
			styleMask: [.titled, .closable, .miniaturizable, .resizable],
			backing: .buffered, defer: false)
		window.titlebarAppearsTransparent = false
		window.appearance = NSAppearance(named: .darkAqua)
		window.backgroundColor = Theme.background
		window.minSize = NSSize(width: 900, height: 600)
		// Takes and projects are tabs of one window rather than windows of
		// their own.
		//
		// The system's own tabbing rather than a tab bar of this program's
		// making: it is the bar everybody already knows, it comes with the
		// keyboard shortcuts and the tab-overview gesture, and it costs two
		// lines against a view-controller hierarchy. What it fixes is not
		// tidiness — two windows the same size, both centred, sit exactly on
		// top of each other, and the one underneath may as well not exist.
		window.tabbingIdentifier = "cuttr"
		window.tabbingMode = .preferred
		super.init(window: window)
		window.delegate = self
		build()
		wire()
		takeDocument.loadMedia()
		refresh()
		window.center()
	}

	@available(*, unavailable) required init?(coder: NSCoder) { nil }

	// MARK: - Layout

	private func build() {
		guard let window else { return }
		playerView = PlayerView(player: transport.player)

		// The markers sit over the picture, inside the same pane, so they move
		// and clip with it.
		let picture = NSView()
		picture.translatesAutoresizingMaskIntoConstraints = false
		for view in [playerView, markers] as [NSView] {
			view.translatesAutoresizingMaskIntoConstraints = false
			picture.addSubview(view)
			NSLayoutConstraint.activate([
				view.topAnchor.constraint(equalTo: picture.topAnchor),
				view.bottomAnchor.constraint(equalTo: picture.bottomAnchor),
				view.leadingAnchor.constraint(equalTo: picture.leadingAnchor),
				view.trailingAnchor.constraint(equalTo: picture.trailingAnchor),
			])
		}

		// The clips above, the anchors below. Both are lists of things the take
		// contains and both are referenced by name from a project, so they
		// belong side by side rather than one being a menu.
		// Four things about the take, each behind a heading that folds it: the
		// clips, the faces being followed, what was said, and the grade. Only
		// one of them is usually the thing being worked on — a grade is decided
		// once and left alone — and folding gives the list the room without
		// anybody dragging dividers about.
		// One pane at a time, and the rail says which.
		//
		// They were four panes stacked down a split view, each folding away
		// behind its heading — and the comment above them said the truth about
		// it: "only one of them is usually the thing being worked on — a grade
		// is decided once and left alone". Four headings, three of them folded,
		// and four heights negotiating with each other every time one was
		// clicked. The rail is one heading, in the place both windows now put
		// the question "what are you doing".
		//
		// A real frame on everything that holds something, not zero. A view
		// created at 0x0 has its size turned into a pair of *required*
		// constraints by its autoresizing mask, and every content minimum
		// inside it is then one half of a system with no solution.
		let lists = PaneStack([
			PaneBox("clips", content: clipTable, accessory: swatches),
			PaneBox("faces", content: anchorTable),
			PaneBox("words", content: transcriptPane,
			        accessory: transcriptPane.detachedHead()),
			PaneBox("look", content: lookPanel, accessory: lookPanel.detachedHead()),
		])
		panes = lists
		rail.onSelect = { [weak self] index in self?.panes?.show(index) }

		// The list beside the rail and the picture in the middle, which is the
		// order the whole design reads in: the left edge says what you are
		// doing, the middle is the thing.
		let top = NSSplitView(frame: .roomToLayOutIn)
		top.isVertical = true
		top.dividerStyle = .thin
		top.addArrangedSubview(lists)
		top.addArrangedSubview(picture)

		let outer = NSSplitView(frame: .roomToLayOutIn)
		outer.isVertical = false
		outer.dividerStyle = .thin
		outer.addArrangedSubview(top)
		outer.addArrangedSubview(timeline)

		let content = DropView()
		content.onDrop = { [weak self] urls in self?.accept(urls) }
		content.wantsLayer = true
		content.layer?.backgroundColor = Theme.background.cgColor

		for view in [bar, rail, outer] as [NSView] {
			view.translatesAutoresizingMaskIntoConstraints = false
			content.addSubview(view)
		}
		NSLayoutConstraint.activate([
			bar.topAnchor.constraint(equalTo: content.topAnchor),
			bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
			bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
			bar.heightAnchor.constraint(equalToConstant: DocumentBar.height),

			// The rail says how wide it is; this only says where.
			rail.topAnchor.constraint(equalTo: bar.bottomAnchor),
			rail.leadingAnchor.constraint(equalTo: content.leadingAnchor),
			rail.bottomAnchor.constraint(equalTo: content.bottomAnchor),

			outer.topAnchor.constraint(equalTo: bar.bottomAnchor),
			outer.leadingAnchor.constraint(equalTo: rail.trailingAnchor),
			outer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
			outer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
		])
		window.contentView = content
		// The timeline owns the keyboard from the moment the window opens, so
		// the first `space` rolls the tape and the first `S` marks. Everything
		// that takes focus away from it — a rename, a click in the table — hands
		// it back when it is done.
		window.initialFirstResponder = timeline

		// The panes are sized by constraints, not by placing dividers.
		//
		// This used to be a `DispatchQueue.main.async` block computing positions
		// from `bounds`, and it crashed the app on launch: the split views had
		// not been laid out when it ran, so `bounds.height` was zero and
		// `bounds.height - 150` handed `setPosition` a divider position of
		// −150. AppKit raised out of the layout pass and the process aborted.
		//
		// A constraint at a low priority says the same thing without depending
		// on when it is read: this pane would like to be this big, the other one
		// takes the slack, and dragging the divider overrides both. The minimums
		// are required, so no pane can be collapsed to nothing by a small
		// window.
		//
		// There are three of them now rather than seven. The four heights that
		// used to be negotiated down the side of this window are gone with the
		// panes: `PaneStack` keeps exactly one in the view hierarchy, so there is
		// one opinion about the height of that column and it is the split
		// view's. A pane that is not showing is not laid out — which `isHidden`
		// never achieved, and that was the crash.
		let preferred = NSLayoutConstraint.Priority(250)
		let sizes: [(NSLayoutConstraint, NSLayoutConstraint)] = [
			(lists.widthAnchor.constraint(equalToConstant: 430),
			 lists.widthAnchor.constraint(greaterThanOrEqualToConstant: 260)),
			(timeline.heightAnchor.constraint(equalToConstant: 280),
			 timeline.heightAnchor.constraint(greaterThanOrEqualToConstant: 140)),
			(picture.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
			 picture.widthAnchor.constraint(greaterThanOrEqualToConstant: 240)),
		]
		for (wish, floor) in sizes {
			// Floors, not laws — see `asFloor`. Every one of these is on a view
			// a split view sizes, and the sum of them can exceed the window.
			wish.priority = wish.relation == .equal ? preferred : .floor
			floor.priority = .floor
			wish.isActive = true
			floor.isActive = true
		}

		DispatchQueue.main.async {
			self.timeline.zoomToFit()
			// The timeline holds the focus to begin with, so the first `space`
			// rolls the tape rather than doing nothing.
			window.makeFirstResponder(self.timeline)
		}
	}

	/// For the tests: the rail and the pane it opens.
	var railForTesting: Rail { rail }
	var panesForTesting: PaneStack? { panes }

	// MARK: - Wiring

	private func wire() {
		timeline.document = takeDocument

		// The grade, live. Every move of a slider changes the take — so the
		// picture changes with it — but only the first of a drag registers an
		// undo, and the rest are folded into that one step. Sixty entries in
		// the Edit menu for one decision is not an undo history.
		lookPanel.onChange = { [weak self] look, finished in
			guard let self else { return }
			var next = self.takeDocument.take
			next.look = look
			if self.gradingSince == nil {
				self.gradingSince = self.takeDocument.take
				self.takeDocument.apply(next, actionName: "Grade")
			} else {
				self.takeDocument.replaceWithoutUndo(next)
			}
			self.transport.look = look
			if finished { self.gradingSince = nil }
		}

		takeDocument.onChange = { [weak self] in self?.refresh() }
		takeDocument.onMediaChange = { [weak self] in
			guard let self else { return }
			self.transport.load(video: self.takeDocument.videoURL,
			                    audio: self.takeDocument.audioURL,
			                    offset: self.takeDocument.take.audio?.offset ?? 0)
			// The duration arrives with the probe and the waveform after it, so
			// the fit is asked for on every media event until somebody zooms.
			self.timeline.zoomToFitIfUntouched()
			self.refresh()
		}

		transport.onTick = { [weak self] time in
			guard let self else { return }
			self.playhead = time
			self.timeline.playhead = time
			self.markers.playhead = time
			// The transcript scrolls itself only while the tape is rolling.
			// Stopped, somebody is reading it, and text that moves under a
			// reader is text nobody can read.
			self.transcriptPane.follows = self.transport.isPlaying
			self.transcriptPane.playhead = time
			if self.transport.isPlaying { self.timeline.followPlayhead() }
			self.showDocument(at: time)
		}

		timeline.onScrub = { [weak self] time in self?.move(to: time) }
		timeline.onSelectClip = { [weak self] id in
			self?.selectedClip = id
			self?.clipTable.reload(self?.takeDocument.take.clips ?? [], selected: id)
			self?.adoptColorOfSelection()
		}
		timeline.onPendingChange = { [weak self] value in self?.pending = value }
		timeline.onEditClip = { [weak self] id, start, end, commit in
			self?.resize(id, start: start, end: end, commit: commit)
		}
		timeline.onOffsetChange = { [weak self] offset, commit in
			self?.setOffset(offset, commit: commit)
		}

		clipTable.onSelect = { [weak self] id in
			self?.selectedClip = id
			self?.timeline.selectedClip = id
			self?.adoptColorOfSelection()
		}
		clipTable.onRename = { [weak self] id, name in self?.takeDocument.setName(name, for: id) }
		clipTable.onSlugChange = { [weak self] id, slug in self?.takeDocument.setSlug(slug, for: id) }
		clipTable.onNoteChange = { [weak self] id, note in self?.takeDocument.setNote(note, for: id) }
		clipTable.onTagsChange = { [weak self] id, text in
			// Split on commas or spaces, and slugged on the way in, so `B Roll`,
			// `b-roll` and `b roll` are one tag rather than three.
			let tags = text.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
			self?.takeDocument.setTags(tags, for: id)
		}
		clipTable.onOrderChange = { [weak self] id, text in
			guard let value = Int(text.trimmingCharacters(in: .whitespaces)) else {
				self?.refresh()
				return
			}
			self?.takeDocument.setOrder(value, for: id)
		}
		clipTable.onActivate = { [weak self] id in self?.reveal(id) }
		clipTable.onTimeChange = { [weak self] id, isStart, text in
			self?.setTime(id, isStart: isStart, text: text)
		}
		clipTable.contextMenu = { [weak self] id in self?.clipMenu(for: id, at: nil) }

		// Selecting words is setting in and out. That is the whole claim this
		// pane makes: a sentence you can read is a cut you can make, and the
		// key that turns a span into a clip is the one that already did.
		transcriptPane.onSelectWords = { [weak self] start, end in
			guard let self else { return }
			let grid = self.takeDocument.grid
			self.pending = (grid.snap(start), grid.snap(end))
			self.pendingFromWords = true
			self.timeline.pending = self.pending
			self.timeline.reveal(from: start - 0.5, to: end + 0.5)
		}
		transcriptPane.onMoveTo = { [weak self] time in
			self?.move(to: time)
			self?.timeline.followPlayhead()
		}
		// The two things the menu on the words offers, which are the two things
		// somebody does with a sentence they have found.
		transcriptPane.onPlayWords = { [weak self] start, end in
			self?.transport.play(from: start, to: end)
			self?.timeline.followPlayhead()
		}
		transcriptPane.onClipWords = { [weak self] start, end in
			guard let self else { return }
			let grid = self.takeDocument.grid
			self.pending = (grid.snap(start), grid.snap(end))
			self.pendingFromWords = true
			self.timeline.pending = self.pending
			self.commitPending()
		}
		// Space, with the cursor in the words: play what is selected. Reading is
		// the point of the pane, and asking somebody to leave it to hear the
		// sentence they are reading undoes that.
		transcriptPane.onSpace = { [weak self] in
			guard let self else { return }
			if self.transport.isPlaying {
				self.transport.pause()
				return
			}
			if let span = self.transcriptPane.selectedSpan {
				self.transport.play(from: span.start, to: span.end)
				self.timeline.followPlayhead()
			} else {
				self.transport.play()
			}
		}
		transcriptPane.onTranscribe = { [weak self] locale in self?.transcribe(in: locale) }
		// Somebody working through a German shoot says so once, not once per
		// take: the choice is remembered, and a take that has been transcribed
		// already says for itself which language it was heard in.
		transcriptPane.onLanguage = { MainWindowController.remember(language: $0) }
		Task { [weak self] in
			let languages = await Transcriber.languages()
			guard let self else { return }
			self.transcriptPane.offer(languages, choosing: self.preferredLanguage)
		}
		transcriptPane.onStatus = { [weak self] note in self?.bar.setStatus(note) }

		// Who is speaking. One key per turn of an interview, and the pane walks
		// the caret on by itself — so a take is labelled without the hand ever
		// leaving the number row.
		transcriptPane.onAssign = { [weak self] word, slug in
			guard let self else { return }
			let changed = self.takeDocument.assignSpeaker(slug, from: word)
			guard changed > 0 else { return }
			let who = slug.map { self.takeDocument.take.speakerTitle($0) } ?? "nobody"
			self.bar.setStatus(changed == 1
				? "this line is \(who)"
				: "\(who), for \(changed) lines — until somebody else was already named")
			self.refresh()
		}
		transcriptPane.onAddSpeaker = { [weak self] name, word in
			guard let self, let added = self.takeDocument.addSpeaker(named: name) else { return }
			self.refresh()
			// Adding somebody while a line is under the caret is nearly always
			// the same act as naming that line — the first two speakers of a
			// take are made exactly this way.
			if let word { self.transcriptPane.assign(added.slug, from: word) }
			self.bar.setStatus("\(added.title) is \(self.takeDocument.take.speakers.count)"
				+ " — press that number in the words")
		}
		transcriptPane.onRenameSpeaker = { [weak self] slug, name in
			self?.takeDocument.renameSpeaker(slug, to: name)
			self?.refresh()
		}
		transcriptPane.onRemoveSpeaker = { [weak self] slug in
			self?.takeDocument.removeSpeaker(slug)
			self?.refresh()
		}
		transcriptPane.onSuggestSpeakers = { [weak self] in self?.guessSpeakers() }
		transcriptPane.onAcceptSuggestions = { [weak self] in
			guard let self else { return }
			let count = self.takeDocument.suggestedSpeakers.count
			self.takeDocument.acceptSuggestions()
			self.bar.setStatus("\(count) lines written down")
			self.refresh()
		}

		anchorTable.onRename = { [weak self] old, new in self?.renameAnchor(old, to: new) }
		anchorTable.onActivate = { [weak self] name in
			guard let anchor = self?.takeDocument.take.anchors.first(where: { $0.name == name })
			else { return }
			self?.move(to: anchor.markedAt)
			self?.timeline.reveal(from: anchor.from, to: anchor.to)
		}
		anchorTable.onSelect = { [weak self] name in self?.selectedAnchor = name }
		anchorTable.contextMenu = { [weak self] name in self?.anchorMenu(for: name) }
		timeline.contextMenu = { [weak self] id, time in self?.clipMenu(for: id, at: time) }
		timeline.onRenameInPlace = { [weak self] id, name in self?.takeDocument.setName(name, for: id) }
		timeline.onLanePicked = { [weak self] color in
			// Clicking a lane chooses it. Nothing is recoloured — the click was
			// on the bar, not on a clip — so this deliberately does not go
			// through `applyColor`.
			self?.currentColor = color
			self?.swatches.setColor(color)
		}

		bar.setUp = setup
		setup.onChooseVideo = { [weak self] in self?.chooseMedia(video: true) }
		setup.onChooseAudio = { [weak self] in self?.chooseMedia(video: false) }
		setup.onOffsetTyped = { [weak self] value in self?.setOffset(value, commit: true) }
		setup.onAlign = { [weak self] in self?.autoAlign() }
		swatches.onChoose = { [weak self] color in self?.chooseLane(color) }

		// Which microphone you hear, over the two lanes it chooses between.
		//
		// Short labels rather than the full ones: this sits on the waveform, and
		// a control 220 points wide there is a control in the way of the thing
		// it is for. The tooltip says the rest, and `U` cycles it.
		for (index, mode) in Transport.Monitor.allCases.enumerated() {
			monitor.segmentCount = max(monitor.segmentCount, index + 1)
			monitor.setLabel(mode.short, forSegment: index)
			monitor.setWidth(38, forSegment: index)
		}
		monitor.controlSize = .small
		monitor.font = NSFont.systemFont(ofSize: 10)
		monitor.selectedSegment = transport.monitor.rawValue
		monitor.target = self
		monitor.action = #selector(monitorChanged)
		monitor.toolTip = "Which microphone you hear (U). \u{201C}Both\u{201D} is the alignment tool:\n"
			+ "nudge until the hollow, flanging sound goes away."
		timeline.laneAccessory = monitor

		// Right-click the picture to track something in it. The footage is here,
		// so the marking is here.
		playerView.contextMenu = { [weak self] point in self?.pictureMenu(at: point) }

		installKeyMonitor()
	}

	// MARK: - Tracking a point in the picture

	/// The picture's rectangle inside the player view: the video is
	/// aspect-fitted, so most of the time there are bars either side.
	private var pictureRect: NSRect { markers.picture }

	private func pictureMenu(at point: NSPoint) -> NSMenu? {
		let picture = pictureRect
		guard picture.contains(point) else { return nil }
		// Normalised, origin bottom left — the coordinates Vision speaks and
		// the ones the path file holds, so nothing is converted twice.
		lastClick = CGPoint(x: (point.x - picture.minX) / picture.width,
		                    y: (point.y - picture.minY) / picture.height)

		let menu = NSMenu()
		let track = NSMenuItem(title: "Track Eye Here", action: #selector(trackEyeHere(_:)), keyEquivalent: "")
		track.target = self
		track.toolTip = "Vision finds the face nearest this point, locks to the eye,\n"
			+ "and follows it for the length of the clip under the playhead."
		menu.addItem(track)

		// Picking up a lost face. Offered only for anchors that do *not* already
		// cover this moment — continuing something already tracked here is not
		// a thing anybody means to do, and listing it would be noise.
		let resumable = takeDocument.take.anchors.filter { anchor in
			takeDocument.anchorPaths[anchor.name]?.covers(playhead) != true
		}
		if !resumable.isEmpty {
			menu.addItem(.separator())
			for anchor in resumable {
				let item = NSMenuItem(title: "Continue “\(anchor.name)” Here",
				                      action: #selector(continueAnchorHere(_:)), keyEquivalent: "")
				item.target = self
				item.representedObject = anchor.name
				item.toolTip = "Follow this face again from here and add it to \(anchor.name),\n"
					+ "leaving a gap where the tracker had lost it."
				menu.addItem(item)
			}
		}

		// The rest is managed in the list below, where it can be seen and
		// renamed. Repeating every anchor twice in this menu made it longer with
		// every face tracked and told you nothing about any of them.
		return menu
	}

	private var lastClick: CGPoint?
	private var selectedAnchor: String?

	/// The anchor list's own menu, and the picture's when it is over one.
	private func anchorMenu(for name: String?) -> NSMenu? {
		guard let name else { return nil }
		let menu = NSMenu()
		for (title, action) in [("Rename…", #selector(renameAnchorAction(_:))),
		                        ("Follow Again", #selector(resolveAnchor(_:))),
		                        ("Remove", #selector(removeAnchorAction(_:)))] {
			let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
			item.target = self
			item.representedObject = name
			menu.addItem(item)
			if title == "Rename…" { menu.addItem(.separator()) }
		}
		return menu
	}

	@objc private func renameAnchorAction(_ sender: NSMenuItem) {
		guard let name = sender.representedObject as? String else { return }
		anchorTable.beginRenaming(name)
	}

	private func renameAnchor(_ old: String, to new: String) {
		guard let name = takeDocument.renameAnchor(old, to: new) else { return }
		// Said out loud, because this rename reaches outside the file: a
		// project pointing at the old name stops resolving, and finding that out
		// at render time is finding it out too late.
		bar.setStatus(name == old
			? "unchanged"
			: "renamed to \(name) — any project saying `anchor: \(old)` needs updating")
	}

	@objc private func trackEyeHere(_ sender: Any?) {
		guard let point = lastClick else { return }
		// No clip needed. The tracker follows the shot outward from here, and
		// whichever subclips end up overlapping it can all use the result.
		solve(takeDocument.addAnchor(name: "anchor", at: playhead, point: point))
	}

	@objc private func continueAnchorHere(_ sender: NSMenuItem) {
		guard let name = sender.representedObject as? String,
		      let point = lastClick,
		      let anchor = takeDocument.take.anchors.first(where: { $0.name == name })
		else { return }
		solve(anchor, from: playhead, at: point, extending: true)
	}

	@objc private func resolveAnchor(_ sender: NSMenuItem) {
		guard let name = sender.representedObject as? String,
		      let anchor = takeDocument.take.anchors.first(where: { $0.name == name })
		else { return }
		solve(anchor)
	}

	@objc private func removeAnchorAction(_ sender: NSMenuItem) {
		guard let name = sender.representedObject as? String else { return }
		takeDocument.removeAnchor(named: name)
		bar.setStatus("removed \(name)")
	}

	private func solve(_ anchor: Anchor) {
		solve(anchor, from: anchor.markedAt, at: anchor.point, extending: false)
	}

	/// Follows a face from a mark. `extending` lays the result into whatever the
	/// anchor already has rather than replacing it.
	private func solve(_ anchor: Anchor, from time: Double, at point: CGPoint, extending: Bool) {
		guard let video = takeDocument.videoURL else { return }
		solveTask?.cancel()
		bar.setStatus("following \(anchor.name)…")
		bar.setProgress(0)
		let duration = takeDocument.duration
		solveTask = Task { [weak self] in
			do {
				let path = try await AnchorSolver.solveShot(
					videoURL: video, method: anchor.method,
					markedAt: time, point: point,
					within: 0 ... max(duration, time),
					onProgress: { step in
						Task { @MainActor in
							self?.bar.setProgress(step.fraction)
							self?.bar.setStatus(String(
								format: "following %@… %d of at most %d",
								anchor.name, step.solved, step.total))
						}
					})
				guard !Task.isCancelled, let self else { return }
				var anchor = anchor
				if extending {
					try self.takeDocument.extendPath(path, for: anchor.name)
				} else {
					if let range = path.timeRange {
						self.takeDocument.setRange(range, for: anchor.name)
						anchor.from = range.lowerBound
						anchor.to = range.upperBound
					}
					try self.takeDocument.writePath(path, for: anchor)
				}
				self.bar.setProgress(nil)

				let spans = self.takeDocument.anchorPaths[anchor.name]?.covered ?? []
				let where_ = spans
					.map { "\(Timecode.string($0.lowerBound))–\(Timecode.string($0.upperBound))" }
					.joined(separator: ", ")
				// Where it got to, and — when it stopped short of the end of the
				// recording — that it stopped because it lost her, which is the
				// cue to pick her up again further on.
				let end = path.timeRange?.upperBound ?? time
				var status = spans.count > 1
					? "\(anchor.name): \(spans.count) stretches — \(where_)"
					: "\(anchor.name): \(where_), \(path.samples.count) samples"
				if end < duration - 0.5 {
					status += "  ·  lost her here — right-click later to continue"
				}
				self.bar.setStatus(status)
			} catch {
				self?.bar.setProgress(nil)
				self?.bar.setStatus(error.localizedDescription)
			}
		}
	}

	// MARK: - The words

	/// Asks for the take's transcript, once.
	///
	/// Once, because it is a minute of somebody's machine and the answer does
	/// not change: the words are written beside the take and read back when it
	/// is opened. Pressing the button again is a deliberate act — a re-align, a
	/// swapped-in re-export — and it says "Again" so that it looks like one.
	private func transcribe(in locale: Locale) {
		guard wordsTask == nil else { return }
		guard let source = Transcriber.Source.forTake(
			takeDocument.take, videoURL: takeDocument.videoURL,
			audioURL: takeDocument.audioURL, duration: takeDocument.duration)
		else {
			bar.setStatus("nothing to listen to — give this take a video or an audio file first")
			return
		}
		bar.setStatus("listening to \(source.url.lastPathComponent)"
			+ " — on this Mac, and nothing is uploaded")
		bar.setProgress(0)
		transcriptPane.setBusy(true)
		wordsTask = Task { [weak self] in
			do {
				let made = try await Transcriber.transcribe(
					source, locale: locale,
					onProgress: { step in
						Task { @MainActor in
							self?.bar.setProgress(step.fraction)
							self?.transcriptPane.setNote(step.note)
						}
					})
				guard !Task.isCancelled, let self else { return }
				try self.takeDocument.setTranscript(
					made.transcript, recogniser: made.recogniser, locale: made.locale)
				self.bar.setStatus(
					"\(made.transcript.count) words · \(made.recogniser.rawValue) · \(made.locale)"
						+ " — listening for what is not a word…")
				self.refresh()

				// The same audio, listened to a second time for what nobody
				// said. Not a button of its own here, because asking what was
				// said and asking what was heard are one question — and this
				// pass is seconds where the one above was minutes.
				let heard = try? await SoundSpotter.listen(source)
				guard !Task.isCancelled else { return }
				self.wordsTask = nil
				self.bar.setProgress(nil)
				if let heard, !heard.isEmpty {
					self.report(heard)
				} else {
					self.bar.setStatus(
						"\(made.transcript.count) words · \(made.recogniser.rawValue) · \(made.locale)"
							+ " — select a sentence and press ⏎")
				}
				self.refresh()
			} catch {
				guard let self else { return }
				self.wordsTask = nil
				self.bar.setProgress(nil)
				self.bar.setStatus(error.localizedDescription)
				self.refresh()
			}
		}
	}

	/// Works out who is speaking, and offers it.
	///
	/// **An offer, and drawn as one.** What comes back goes into
	/// ``TakeDocument/suggestedSpeakers`` and is shown in brackets; nothing is
	/// written until somebody keeps it. A colour that is wrong a third of the
	/// time is worse than no colour, and the honest way to hold that line is
	/// for the guess and the record to be different things all the way down.
	///
	/// Which method: whose mouth is moving, when the take has faces it is
	/// already following, because that is the one that scored above chance on
	/// real footage. Otherwise timbre, which needs nothing at all. Neither
	/// touches the network. See `docs/speakers.md`.
	private func guessSpeakers() {
		guard speakerTask == nil else { return }
		guard !takeDocument.transcript.isEmpty else {
			bar.setStatus("no words yet — transcribe this take first")
			return
		}
		guard let audio = takeDocument.audioURL ?? takeDocument.videoURL else { return }
		let faces = takeDocument.take.anchors.compactMap { anchor -> SpeakerDetector.Candidate? in
			guard let path = takeDocument.anchorPaths[anchor.name] else { return nil }
			return SpeakerDetector.Candidate(name: anchor.name, path: path)
		}
		let method: SpeakerProposal.Method = faces.isEmpty ? .timbre : .mouth
		let offset = takeDocument.take.video == nil ? 0 : (takeDocument.take.audio?.offset ?? 0)
		let transcript = takeDocument.transcript
		let known = takeDocument.take.speakers.map(\.slug)
		let locale = takeDocument.take.words?.locale ?? ""
		let video = takeDocument.videoURL

		bar.setStatus("\(method.title.lowercased()): working out who is speaking…")
		speakerTask = Task { [weak self] in
			let offer = try? await SpeakerProposal.propose(
				for: transcript, audio: audio, offset: offset, method: method,
				names: known, locale: locale, video: video, faces: faces)
			guard let self, !Task.isCancelled else { return }
			self.speakerTask = nil
			guard let offer, !offer.isEmpty else {
				// Saying nothing is an answer, and it is the right one when the
				// voices did not separate. See `SpeakerClustering.silhouette`.
				self.bar.setStatus("the voices in this take did not separate —"
					+ " nothing worth offering")
				return
			}
			self.takeDocument.suggest(offer.byLine)
			self.bar.setStatus(String(
				format: "%d lines guessed, %d left alone — the bracketed names."
					+ " Keep them, or answer a line yourself. (separation %.2f)",
				offer.byLine.count, offer.skipped, offer.separation))
			self.refresh()
		}
	}

	/// Listens for what is not a word: a laugh, applause, a cough.
	///
	/// Separate from transcribing as well as part of it, because a take that
	/// was transcribed before this existed should not have to sit through the
	/// recogniser again to get its laughs — and this pass is seconds where that
	/// one is minutes.
	private func findSounds() {
		guard soundsTask == nil, wordsTask == nil else { return }
		guard let source = Transcriber.Source.forTake(
			takeDocument.take, videoURL: takeDocument.videoURL,
			audioURL: takeDocument.audioURL, duration: takeDocument.duration)
		else {
			bar.setStatus("nothing to listen to — give this take a video or an audio file first")
			return
		}
		bar.setStatus("listening to \(source.url.lastPathComponent) for what is not a word")
		soundsTask = Task { [weak self] in
			let heard = try? await SoundSpotter.listen(source)
			guard !Task.isCancelled, let self else { return }
			self.soundsTask = nil
			self.report(heard)
			self.refresh()
		}
	}

	/// What the classifier found, said out loud. Nothing found is worth saying
	/// too: an empty pane after a pass that looked like it did something reads
	/// as a failure.
	private func report(_ heard: [SoundEvent]?) {
		guard let heard else {
			bar.setStatus("this Mac's sound classifier would not run")
			return
		}
		guard !heard.isEmpty else {
			bar.setStatus("nothing but words in this one")
			return
		}
		takeDocument.setSounds(heard)
		var counted: [String: Int] = [:]
		for sound in heard { counted[sound.label, default: 0] += 1 }
		bar.setStatus(counted.sorted { $0.value > $1.value }
			.map { "\($0.value) × \($0.key)" }.joined(separator: ", "))
	}

	/// Names the selected clip after what is said in it.
	///
	/// The keystroke that turns `clip-7` into `arbeitsanzug`.
	private func nameFromWords() {
		guard let id = selectedClip else {
			bar.setStatus("select a clip first — W names it after what is said in it")
			return
		}
		guard !takeDocument.transcript.isEmpty || !takeDocument.take.sounds.isEmpty else {
			bar.setStatus("no words yet — transcribe this take first")
			return
		}
		propose(for: id)
	}

	/// Puts a name for a clip in front of somebody, editable and ready to be
	/// typed over.
	///
	/// **The keystroke is never blocked.** The field opens straight away with
	/// the first words in it, which is a usable name and is what this program
	/// did before there was a model to ask. The model's answer arrives about
	/// seven tenths of a second later and replaces what is in the field *only
	/// if nobody has started typing* — see ``TimelineView/repropose(_:for:replacing:)``.
	/// Seven tenths of a second is nothing to wait for a better name and far
	/// too long to hold a key down for.
	///
	/// **Nothing is written until somebody presses Return.** A name reaching a
	/// take goes through `setName`, which re-derives the slug unless somebody
	/// has typed one — the same route a name typed by hand takes, including the
	/// rule that a slug somebody wrote is theirs and stays.
	private func propose(for id: Clip.ID) {
		guard let clip = takeDocument.take.clips.first(where: { $0.id == id }) else { return }
		let span = clip.start ... clip.end
		let firstWords = firstWordsOrSound(covering: span)
		guard !firstWords.isEmpty else {
			bar.setStatus("nothing is said in \(clip.slug)")
			return
		}
		timeline.reveal(from: clip.start, to: clip.end)
		timeline.beginRenaming(clip, proposing: firstWords)
		bar.setStatus("\(firstWords) — ⏎ to keep it, or type over it")

		let said = takeDocument.transcript.text(covering: span)
		guard !said.isEmpty, ClipNamer.availability.isAvailable else { return }
		nameProposalTask?.cancel()
		nameProposalTask = Task { [weak self] in
			let naming = await ClipNamer.propose(for: said, orFirstWords: firstWords)
			guard !Task.isCancelled, let self else { return }
			self.nameProposalTask = nil
			guard self.timeline.repropose(naming.name, for: id, replacing: firstWords) else { return }
			// Which of the two answered, always. A name somebody cannot account
			// for is a name they cannot trust, and both of these are honest
			// answers to the same question.
			switch naming.source {
			case .model:
				self.bar.setStatus("\(naming.name) — suggested here on this Mac."
					+ " ⏎ to keep it, or type over it")
			case .invented(let made):
				self.bar.setStatus("kept “\(naming.name)”: nobody said “\(made)”")
			case .firstWords(let why):
				self.bar.setStatus("\(naming.name) — its first words, because \(why)")
			}
		}
	}

	/// What goes in the field: the clip's first words, or the sound in it when
	/// nothing is said.
	///
	/// A clip made from a laugh is called `Lachen`, and needs no model to work
	/// that out.
	private func firstWordsOrSound(covering span: ClosedRange<Double>) -> String {
		let phrase = takeDocument.transcript.phrase(covering: span)
		guard phrase.isEmpty else { return phrase }
		return takeDocument.take.sounds
			.filter { $0.start < span.upperBound && $0.end > span.lowerBound }
			.map(\.label)
			.joined(separator: " ")
	}

	/// The bar, the popover behind the name, and the monitor switch, told what
	/// is open and where the playhead is.
	///
	/// One method, called from everywhere that used to call four setters, so the
	/// clock and the file names can never disagree about which take this is.
	private func showDocument(at time: Double) {
		bar.setName(takeDocument.displayName)
		bar.setClock(time)
		setup.update(document: takeDocument)
		let hasAudio = takeDocument.take.audio != nil
		monitor.isHidden = !hasAudio
		monitor.selectedSegment = transport.monitor.rawValue
	}

	@objc private func monitorChanged() {
		guard let mode = Transport.Monitor(rawValue: monitor.selectedSegment) else { return }
		transport.monitor = mode
	}

	private func refresh() {
		guard let window else { return }
		window.title = takeDocument.displayName + (takeDocument.isDirty ? " — edited" : "")
		window.representedURL = takeDocument.url
		window.isDocumentEdited = takeDocument.isDirty
		timeline.needsDisplay = true
		timeline.window?.invalidateCursorRects(for: timeline)
		markers.markers = takeDocument.take.anchors.compactMap { anchor in
			takeDocument.anchorPaths[anchor.name].map { (anchor.name, $0) }
		}
		lookPanel.show(takeDocument.take.look)
		transport.look = takeDocument.take.look
		anchorTable.reload(takeDocument.take.anchors,
		                   paths: takeDocument.anchorPaths,
		                   selected: selectedAnchor)
		markers.videoSize = takeDocument.videoInfo?.naturalSize ?? .zero
		transcriptPane.show(takeDocument.transcript, words: takeDocument.take.words,
		                    sounds: takeDocument.take.sounds,
		                    cast: takeDocument.take.speakers,
		                    suggestions: takeDocument.suggestedSpeakers)
		transcriptPane.setBusy(wordsTask != nil,
		                       enabled: takeDocument.videoURL != nil || takeDocument.audioURL != nil)
		clipTable.reload(takeDocument.take.clips, selected: selectedClip)
		showDocument(at: playhead)
		swatches.setColor(currentColor)
		if let error = takeDocument.mediaError { bar.setStatus(error) }
	}

	// MARK: - Transport

	private func move(to time: Double) {
		playhead = max(0, time)
		timeline.playhead = playhead
		markers.playhead = playhead
		transcriptPane.playhead = playhead
		transport.seek(to: playhead)
		showDocument(at: playhead)
	}

	private func step(_ seconds: Double) { move(to: playhead + seconds) }

	/// Space: play the selected clip, beginning to end.
	///
	/// With a clip selected, that is the question being asked — "does this cut
	/// work" — and answering it should not need scrubbing to the head first and
	/// hitting stop before the next one starts. With nothing selected it is the
	/// ordinary play/pause from wherever the playhead is.
	///
	/// Playing always stops, whichever it was, so the key never has two
	/// meanings at once.
	private func playSelectionOrToggle() {
		if transport.isPlaying {
			transport.pause()
			return
		}
		// A clip is played end to end only when the clip *list* has the
		// keyboard. Everywhere else — the timeline, the picture, the anchors —
		// space is what it is in every player there has ever been: play from
		// where the playhead is. Selecting a clip in order to look at it should
		// not change what the space bar means for the rest of the window.
		guard clipTable.hasKeyboard,
		      let id = selectedClip,
		      let clip = takeDocument.take.clips.first(where: { $0.id == id })
		else {
			transport.togglePlay()
			return
		}
		transport.play(from: clip.start, to: clip.end)
		bar.setStatus("\(clip.slug) — \(Timecode.string(clip.duration))")
	}

	/// To the top of the clip somebody is working on, or to its end if the
	/// playhead is already at the top.
	///
	/// "The clip" is the selected one when there is a selection, and otherwise
	/// whatever the playhead is inside — so it works whether somebody is
	/// working from the list or from the timeline.
	/// Put the playhead on a moment of this take, and select the clip that is
	/// there — how the composing window hands over.
	public func reveal(at time: Double) {
		let clip = takeDocument.take.clips.last { $0.contains(time) }
		if let clip {
			selectedClip = clip.id
			clipTable.reload(takeDocument.take.clips, selected: clip.id)
			timeline.selectedClip = clip.id
			timeline.reveal(from: clip.start, to: clip.end)
		}
		move(to: time)
	}

	private func jumpToEdge() {
		let clips = takeDocument.take.clips
		let clip = selectedClip.flatMap { id in clips.first { $0.id == id } }
			?? clips.last { $0.contains(playhead) }
		guard let clip else { return }
		move(to: clip.edge(from: playhead))
		bar.setStatus("\(clip.slug) — \(Timecode.string(playhead))")
	}

	/// The next place something starts or ends, in the given direction.
	private func stepToMark(forward: Bool) {
		var marks = takeDocument.take.clips.flatMap { [$0.start, $0.end] }
		marks.append(0)
		marks.append(takeDocument.duration)
		let sorted = marks.sorted()
		let target = forward
			? sorted.first { $0 > playhead + 1e-4 }
			: sorted.last { $0 < playhead - 1e-4 }
		if let target { move(to: target) }
	}

	// MARK: - Cutting

	/// The one key that does the obvious thing wherever the playhead is.
	///
	/// Inside a clip, it splits it. Outside one, it closes off everything since
	/// the last clip ended — which makes the whole contiguous pass a matter of
	/// playing the take and hitting one key at each boundary, without ever
	/// setting an in-point by hand.
	private func split() {
		var next = takeDocument.take
		guard let clip = next.mark(at: takeDocument.grid.snap(playhead), color: currentColor) else {
			// Nothing to mark: the playhead has not moved since the last one.
			// Said rather than ignored, because a key that silently does
			// nothing reads as a key that has stopped working.
			bar.setStatus("nothing to mark here — the playhead is on a cut already")
			return
		}
		takeDocument.apply(next, actionName: next.clips.count == takeDocument.take.clips.count + 1 ? "Mark Clip" : "Split Clip")
		select(clip.id)
		nameAfterWhoeverIsTalking(clip)
	}

	/// Names a fresh clip after whoever is speaking in it.
	///
	/// After the mark, never during it. Working out who is talking means
	/// decoding a second or two of video and asking Vision about every frame,
	/// and the marking loop — play, mark, play, mark — must not stop for
	/// anything. So the clip appears instantly as `clip-4` and becomes `mia-2`
	/// a moment later, or stays `clip-4` if nobody was clearly talking.
	///
	/// An anchor is a person: rename the tracked face to `mia` and the clips
	/// she speaks in are named after her. Nothing to define twice.
	private func nameAfterWhoeverIsTalking(_ clip: Clip) {
		guard let video = takeDocument.videoURL else { return }
		let candidates = takeDocument.take.anchors.compactMap { anchor -> SpeakerDetector.Candidate? in
			guard let path = takeDocument.anchorPaths[anchor.name], path.covers(clip.start) else { return nil }
			return SpeakerDetector.Candidate(name: anchor.name, path: path)
		}
		guard !candidates.isEmpty else { return }

		namingTask?.cancel()
		let id = clip.id
		namingTask = Task { [weak self] in
			guard let finding = try? await SpeakerDetector.speaking(
				videoURL: video, among: candidates, from: clip.start, to: clip.end)
			else { return }
			guard !Task.isCancelled, let self else { return }
			// Only if nobody has touched it. A slug somebody typed is theirs,
			// and a guess arriving two seconds later must not overwrite it.
			guard let current = self.takeDocument.take.clips.first(where: { $0.id == id }),
			      current.name.isEmpty, current.slug.hasPrefix("clip-")
			else { return }
			let name = Slug.numbered(finding.name, taken: self.takeDocument.take.slugs)
			self.takeDocument.setSlug(name, for: id)
			self.bar.setStatus(String(
				format: "%@ — %@ was talking (%.0f%% more than anyone else)",
				name, finding.name,
				finding.margin.isFinite ? (finding.margin - 1) * 100 : 100))
		}
	}

	/// What Return does, which depends on what is in front of you.
	///
	/// An in/out span is a question waiting to be answered — turn it into a
	/// clip — so it wins. With no span, Return is "take me to this clip", which
	/// is what the key means everywhere else in this program's neighbourhood:
	/// select a thing in a list, press Return, go there. From the clip table
	/// that is the only sensible reading, and the table is where a Return is
	/// most likely to be pressed.
	private func commitReturn() {
		if pending != nil, let span = pending, abs(span.end - span.start) > 0.01 {
			commitPending()
			return
		}
		guard let id = selectedClip,
		      let clip = takeDocument.take.clips.first(where: { $0.id == id }) else { return }
		move(to: clip.start)
		// Brought on screen if it is not, but the zoom is left alone: Return is
		// "go there", and re-framing the timeline is what `Z` is for.
		if timeline.x(for: clip.start) < 0 || timeline.x(for: clip.start) > timeline.bounds.width {
			timeline.followPlayhead()
		}
	}

	/// Commits the in/out span, if there is one.
	private func commitPending() {
		guard let pending, abs(pending.end - pending.start) > 0.01 else { return }
		var next = takeDocument.take
		let clip = Clip(slug: Slug.numbered(taken: next.slugs),
		                start: min(pending.start, pending.end),
		                end: max(pending.start, pending.end),
		                color: currentColor)
		next.clips.append(clip)
		takeDocument.apply(next, actionName: "New Clip")
		let fromWords = pendingFromWords
		self.pending = nil
		pendingFromWords = false
		timeline.pending = nil
		select(clip.id)
		// See ``pendingFromWords``: a clip cut out of a sentence somebody just
		// read is one they are ready to name, and a clip cut by marking is not.
		if fromWords { propose(for: clip.id) }
	}

	private func setIn() {
		let t = takeDocument.grid.snap(playhead)
		pending = (t, max(pending?.end ?? t, t))
		pendingFromWords = false
		timeline.pending = pending
	}

	private func setOut() {
		let t = takeDocument.grid.snap(playhead)
		pending = (min(pending?.start ?? t, t), t)
		pendingFromWords = false
		timeline.pending = pending
	}

	private func deleteSelected() {
		guard let selectedClip else { return }
		var next = takeDocument.take
		next.clips.removeAll { $0.id == selectedClip }
		takeDocument.apply(next, actionName: "Delete Clip")
		self.selectedClip = nil
		timeline.selectedClip = nil
	}

	private func resize(_ id: Clip.ID, start: Double, end: Double, commit: Bool) {
		guard let index = takeDocument.take.clips.firstIndex(where: { $0.id == id }) else { return }
		var next = takeDocument.take
		next.clips[index].start = max(0, min(start, end))
		next.clips[index].end = max(start, end)
		// One undo step for the whole drag: the first event opens a group and
		// every later one is folded into it, so ⌘Z undoes "the trim" rather
		// than the last pixel of it.
		if !dragUndoOpen {
			dragUndoOpen = true
			takeDocument.apply(next, actionName: "Trim Clip")
		} else {
			takeDocument.undoManager.disableUndoRegistration()
			takeDocument.apply(next, actionName: "Trim Clip")
			takeDocument.undoManager.enableUndoRegistration()
		}
		if commit { dragUndoOpen = false }
	}

	/// Selects a clip and **keeps the keyboard on the timeline**.
	///
	/// Marking used to open the name editor on the new clip, on the theory that
	/// naming it immediately was the fast path. It is not: it put a text field
	/// in front of the very next `S`, so a run of marks stopped dead after the
	/// first one and the second keystroke went into a clip name instead. Marking
	/// is the loop that has to stay unbroken — play, mark, play, mark — and
	/// naming is a separate pass, which is what `clip-1`, `clip-2`, `clip-3` are
	/// for: they are usable references from the moment they exist.
	///
	/// Renaming is asked for explicitly, and never happens by itself:
	/// double-click the bar, press `N`, or use the clip menu.
	private func select(_ id: Clip.ID) {
		selectedClip = id
		timeline.selectedClip = id
		clipTable.reload(takeDocument.take.clips, selected: id)
		adoptColorOfSelection()
		// Said out loud rather than assumed. A table reload can move the first
		// responder into the list, and the next `S` has to reach the timeline.
		window?.makeFirstResponder(timeline)
	}

	private func reveal(_ id: Clip.ID) {
		guard let clip = takeDocument.take.clips.first(where: { $0.id == id }) else { return }
		timeline.reveal(from: clip.start, to: clip.end)
		move(to: clip.start)
	}

	/// A start or an end, typed into the table.
	private func setTime(_ id: Clip.ID, isStart: Bool, text: String) {
		guard let clip = takeDocument.take.clips.first(where: { $0.id == id }),
		      let value = Timecode.parse(text)
		else {
			// Unreadable, so nothing happens and the old value comes back on
			// the next reload. Refusing quietly beats an alert for a typo.
			refresh()
			return
		}
		takeDocument.setTimes(start: isStart ? value : clip.start,
		                      end: isStart ? clip.end : value,
		                      for: id)
	}

	// MARK: - Colour

	/// Choosing the lane to cut on next. **Changes nothing that already exists.**
	///
	/// It used to recolour the selected clip as well, on the drawing-program
	/// rule that a swatch acts on the selection. That is wrong here, because the
	/// selection after a mark is *the clip that was just made* — so picking the
	/// colour for the next one silently moved the last one to a different lane.
	/// The swatch is a mode, not an edit. Recolouring an existing clip is the
	/// context menu's Colour submenu, where it is unambiguous.
	private func chooseLane(_ color: ClipColor) {
		currentColor = color
		swatches.setColor(color)
	}

	/// Recolouring a clip that exists — from the context menu, or the Clip menu.
	private func recolour(_ color: ClipColor, id: Clip.ID) {
		var next = takeDocument.take
		next.setColor(color, for: id)
		takeDocument.apply(next, actionName: "Colour Clip")
		currentColor = color
		swatches.setColor(color)
		timeline.needsDisplay = true
	}

	private func adoptColorOfSelection() {
		guard let id = selectedClip,
		      let clip = takeDocument.take.clips.first(where: { $0.id == id }) else { return }
		currentColor = clip.color
		swatches.setColor(clip.color)
	}

	/// The colour the menu bar should tick.
	public var selectedClipColor: ClipColor? {
		guard let id = selectedClip else { return currentColor }
		return takeDocument.take.clips.first { $0.id == id }?.color
	}

	@objc public func chooseColor(_ sender: NSMenuItem) {
		guard sender.tag < ClipColor.allCases.count else { return }
		let color = ClipColor.allCases[sender.tag]
		// From a menu opened on a clip, this recolours it. From the menu bar
		// with nothing selected, it is only a choice of lane.
		if let id = actionTarget { recolour(color, id: id) } else { chooseLane(color) }
	}

	// MARK: - The clip menu

	/// What the right-click menu offers, and what the Clip menu offers.
	///
	/// One builder for both, because they are the same list of verbs and a menu
	/// bar that disagrees with a context menu is a menu bar nobody reads. `time`
	/// is where the pointer was — `nil` when the menu came from the table, where
	/// there is no time under the cursor and the playhead is the only sensible
	/// place to trim to.
	private func clipMenu(for id: Clip.ID?, at time: Double?) -> NSMenu? {
		contextClip = id
		contextTime = time
		let menu = NSMenu()

		if id != nil {
			add(to: menu, "Rename", #selector(renameSelected))
			add(to: menu, "Edit Slug", #selector(editSlugOfSelected))

			let tagItem = NSMenuItem(title: "Tags", action: nil, keyEquivalent: "")
			tagItem.submenu = tagMenu(for: id)
			menu.addItem(tagItem)
			menu.addItem(.separator())
			// Trimming to the pointer when there is one, to the playhead when
			// there is not. Both are named for where they will trim *to*, so
			// the item says what will happen rather than which control it is.
			let target = time == nil ? "Playhead" : "Here"
			add(to: menu, "Trim Start to \(target)", #selector(trimStartToPoint))
			add(to: menu, "Trim End to \(target)", #selector(trimEndToPoint))
			add(to: menu, "Set In/Out from Clip", #selector(setInOutFromClip))
			menu.addItem(.separator())
			let colorItem = NSMenuItem(title: "Colour", action: nil, keyEquivalent: "")
			colorItem.submenu = colorMenu(current: takeDocument.take.clips.first { $0.id == id }?.color)
			menu.addItem(colorItem)
			menu.addItem(.separator())
			add(to: menu, "Split at Playhead", #selector(splitAction))
			add(to: menu, "Zoom to Clip", #selector(zoomToClipAction))
			menu.addItem(.separator())
			add(to: menu, "Delete", #selector(deleteAction))
		} else {
			add(to: menu, "New Clip from In/Out", #selector(commitPendingAction))
			add(to: menu, "Split at Playhead", #selector(splitAction))
			menu.addItem(.separator())
			add(to: menu, "Zoom to Fit", #selector(zoomFit))
		}
		return menu
	}

	/// The tags already in use in this take, ticked for the clip in hand.
	///
	/// Toggling rather than typing, because a tag's whole value is that it is
	/// the *same* tag on several clips — and the reliable way to get the same
	/// string twice is not to type it twice. Typing is still there for the
	/// first one.
	/// The same menu, for the menu bar, aimed at whatever is selected.
	public func tagsMenu() -> NSMenu { tagMenu(for: selectedClip) }

	private func tagMenu(for id: Clip.ID?) -> NSMenu {
		let menu = NSMenu()
		let current = Set(takeDocument.take.clips.first { $0.id == id }?.tags ?? [])
		for tag in takeDocument.take.tags {
			let item = NSMenuItem(title: tag, action: #selector(toggleTag(_:)), keyEquivalent: "")
			item.target = self
			item.representedObject = tag
			item.state = current.contains(tag) ? .on : .off
			menu.addItem(item)
		}
		if !takeDocument.take.tags.isEmpty { menu.addItem(.separator()) }
		let edit = NSMenuItem(title: takeDocument.take.tags.isEmpty ? "Add Tags…" : "Edit Tags…",
		                      action: #selector(editTagsOfSelected(_:)), keyEquivalent: "")
		edit.target = self
		menu.addItem(edit)
		return menu
	}

	@objc private func toggleTag(_ sender: NSMenuItem) {
		guard let tag = sender.representedObject as? String, let id = actionTarget,
		      let clip = takeDocument.take.clips.first(where: { $0.id == id })
		else { return }
		var tags = clip.tags
		if let index = tags.firstIndex(of: tag) { tags.remove(at: index) } else { tags.append(tag) }
		takeDocument.setTags(tags, for: id)
	}

	/// The palette as a menu, with a swatch drawn into each item.
	///
	/// An image rather than the colour's name alone: the name is what the file
	/// says, and the swatch is what the timeline shows, so the menu that
	/// connects them shows both.
	func colorMenu(current: ClipColor?) -> NSMenu {
		let menu = NSMenu()
		for (index, color) in ClipColor.allCases.enumerated() {
			let item = NSMenuItem(title: color.title, action: #selector(chooseColor(_:)), keyEquivalent: "")
			item.target = self
			item.tag = index
			item.state = color == current ? .on : .off
			let swatch = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
				Theme.base(color).setFill()
				NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
				return true
			}
			item.image = swatch
			menu.addItem(item)
		}
		return menu
	}

	private func add(to menu: NSMenu, _ title: String, _ action: Selector) {
		let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
		item.target = self
		menu.addItem(item)
	}

	/// What the menu that is currently open was opened on.
	private var contextClip: Clip.ID?
	private var contextTime: Double?

	/// The clip a menu action applies to: the one the menu was opened on, or
	/// the selection when the action came from the menu bar.
	private var actionTarget: Clip.ID? { contextClip ?? selectedClip }

	// MARK: - Menu and context-menu actions

	/// Menu-bar actions clear the context, so that "Delete" in the Clip menu
	/// deletes the selection rather than whatever was last right-clicked.
	/// Context-menu items set it again on the way in, so they are unaffected.
	@objc public func clearContext() { contextClip = nil; contextTime = nil }

	@objc public func splitAction(_ sender: Any? = nil) { split() }
	@objc public func commitPendingAction(_ sender: Any? = nil) { commitPending() }
	@objc public func setInAction(_ sender: Any? = nil) { setIn() }
	@objc public func setOutAction(_ sender: Any? = nil) { setOut() }
	@objc public func alignAction(_ sender: Any? = nil) { autoAlign() }
	@objc public func transcribeAction(_ sender: Any? = nil) {
		transcribe(in: transcriptPane.chosenLanguage.map(Locale.init(identifier:)) ?? .current)
	}

	/// What to listen in, before anybody has said: what this take was heard in
	/// last time, then what was chosen for the last take, then the Mac's own
	/// language — which is the one that was wrong.
	private var preferredLanguage: String {
		let recorded = takeDocument.take.words?.locale ?? ""
		if !recorded.isEmpty { return recorded }
		if let remembered = UserDefaults.standard.string(forKey: Self.languageKey) { return remembered }
		return Locale.current.identifier(.bcp47)
	}

	private static let languageKey = "de.rnd7.cuttr.transcript.language"

	private static func remember(language: String) {
		UserDefaults.standard.set(language, forKey: languageKey)
	}
	@objc public func nameFromWordsAction(_ sender: Any? = nil) { nameFromWords() }
	@objc public func findSoundsAction(_ sender: Any? = nil) { findSounds() }
	/// The rail, from the menu bar.
	///
	/// No key equivalents: the composing window already has `⌘1`–`⌘3` for its
	/// own three, and two menu items with one key equivalent means only the
	/// first of them ever gets the key. Four more of those would be a shortcut
	/// that works in one window and silently does nothing in the other, which is
	/// worse than a menu item somebody has to find once.
	@objc public func showClips(_ sender: Any? = nil) { showPane(0) }
	@objc public func showFaces(_ sender: Any? = nil) { showPane(1) }
	@objc public func showWords(_ sender: Any? = nil) { showPane(2) }
	@objc public func showLook(_ sender: Any? = nil) { showPane(3) }

	private func showPane(_ index: Int) {
		rail.select(index)
		panes?.show(index)
	}

	@objc public func zoomIn(_ sender: Any? = nil) { timeline.zoomAroundPlayhead(by: 1 / 1.6) }
	@objc public func zoomOut(_ sender: Any? = nil) { timeline.zoomAroundPlayhead(by: 1.6) }
	@objc public func zoomFit(_ sender: Any? = nil) { timeline.zoomToFit() }

	@objc public func zoomAudioIn(_ sender: Any? = nil) {
		timeline.zoomWaveform(by: 2)
		bar.setStatus(String(format: "waveform ×%g", timeline.waveformGain))
	}

	@objc public func zoomAudioOut(_ sender: Any? = nil) {
		timeline.zoomWaveform(by: 0.5)
		bar.setStatus(String(format: "waveform ×%g", timeline.waveformGain))
	}

	@objc public func resetAudioZoom(_ sender: Any? = nil) {
		timeline.resetWaveformGain()
		bar.setStatus("waveform ×1")
	}
	@objc public func nudgeEarlier(_ sender: Any? = nil) { nudge(-0.001) }
	@objc public func nudgeLater(_ sender: Any? = nil) { nudge(0.001) }

	@objc public func cycleMonitor(_ sender: Any? = nil) {
		transport.monitor = Transport.Monitor(
			rawValue: (transport.monitor.rawValue + 1) % Transport.Monitor.allCases.count) ?? .external
		monitor.selectedSegment = transport.monitor.rawValue
		bar.setStatus("monitoring \(transport.monitor.title)")
	}

	@objc public func renameSelected(_ sender: Any? = nil) {
		guard let id = actionTarget,
		      let clip = takeDocument.take.clips.first(where: { $0.id == id }) else { return }
		timeline.beginRenaming(clip)
	}

	@objc public func editTagsOfSelected(_ sender: Any? = nil) {
		guard let id = actionTarget else { return }
		clipTable.beginEditingTags(id)
	}

	@objc public func editSlugOfSelected(_ sender: Any? = nil) {
		guard let id = actionTarget else { return }
		clipTable.beginEditingSlug(id)
	}

	@objc public func deleteAction(_ sender: Any? = nil) {
		guard let id = actionTarget else { return }
		var next = takeDocument.take
		next.clips.removeAll { $0.id == id }
		takeDocument.apply(next, actionName: "Delete Clip")
		if selectedClip == id { selectedClip = nil; timeline.selectedClip = nil }
		contextClip = nil
	}

	@objc public func zoomToClipAction(_ sender: Any? = nil) {
		guard let id = actionTarget else { return }
		reveal(id)
	}

	@objc public func trimStartToPoint(_ sender: Any? = nil) {
		guard let id = actionTarget,
		      let clip = takeDocument.take.clips.first(where: { $0.id == id }) else { return }
		takeDocument.setTimes(start: contextTime ?? playhead, end: clip.end, for: id)
	}

	@objc public func trimEndToPoint(_ sender: Any? = nil) {
		guard let id = actionTarget,
		      let clip = takeDocument.take.clips.first(where: { $0.id == id }) else { return }
		takeDocument.setTimes(start: clip.start, end: contextTime ?? playhead, for: id)
	}

	@objc public func setInOutFromClip(_ sender: Any? = nil) {
		guard let id = actionTarget,
		      let clip = takeDocument.take.clips.first(where: { $0.id == id }) else { return }
		pending = (clip.start, clip.end)
		timeline.pending = pending
		move(to: clip.start)
	}

	// MARK: - Alignment

	private func setOffset(_ offset: Double, commit: Bool) {
		guard takeDocument.take.audio != nil else { return }
		if !commit {
			// Live, during a drag: the player and the drawing follow, but the
			// undo stack does not fill up with every intermediate millisecond.
			takeDocument.undoManager.disableUndoRegistration()
			takeDocument.setOffset(offset)
			takeDocument.undoManager.enableUndoRegistration()
		} else {
			takeDocument.setOffset(offset)
		}
		transport.setOffset(offset)
		timeline.needsDisplay = true
		showDocument(at: playhead)
	}

	private func nudge(_ seconds: Double) {
		guard let audio = takeDocument.take.audio else { return }
		setOffset(audio.offset + seconds, commit: true)
		bar.setStatus("offset \(Timecode.offsetString(takeDocument.take.audio?.offset ?? 0))")
	}

	private func autoAlign() {
		guard let video = takeDocument.videoWaveform, let audio = takeDocument.audioWaveform else {
			bar.setStatus("Both recordings have to finish decoding first.")
			return
		}
		bar.setStatus("aligning…")
		Task {
			// Off the main thread: an exhaustive search over an hour of
			// envelope is about a second, which is four dropped frames of
			// playback and a window that stops redrawing.
			let result = await Task.detached(priority: .userInitiated) {
				AudioAligner.align(videoAudio: video, audio: audio)
			}.value
			guard let result else {
				bar.setStatus("No match — is one of the recordings silent?")
				return
			}
			setOffset(result.offset, commit: true)
			bar.setStatus(String(
				format: "offset %@  ·  match %.2f  ·  measured at %@",
				Timecode.offsetString(result.offset), result.confidence,
				Timecode.string(result.probeStart + result.offset)))
			// Jump to where the match was measured, zoomed in far enough that a
			// millisecond is visible. The number is a claim; this is the view
			// that lets somebody check it in two seconds.
			move(to: result.probeStart + result.offset)
			timeline.reveal(from: result.probeStart + result.offset,
			                to: result.probeStart + result.offset + 0.5)
		}
	}

	// MARK: - Files

	private func chooseMedia(video: Bool) {
		let panel = NSOpenPanel()
		panel.allowedContentTypes = video ? [.movie, .video, .mpeg4Movie, .quickTimeMovie] : [.audio, .mp3, .wav, .aiff, .mpeg4Audio]
		panel.allowsMultipleSelection = false
		panel.message = video ? "Choose the video" : "Choose the audio recording"
		guard panel.runModal() == .OK, let url = panel.url else { return }
		takeDocument.setMedia(video: video ? url : nil, audio: video ? nil : url)
	}

	/// Files dropped on the window, sorted into the two slots by what they are.
	private func accept(_ urls: [URL]) {
		var video: URL?
		var audio: URL?
		for url in urls {
			guard let type = UTType(filenameExtension: url.pathExtension) else { continue }
			if type.conforms(to: .movie) || type.conforms(to: .video) { video = url }
			else if type.conforms(to: .audio) { audio = url }
			else if ["edl", "xml", "fcpxml"].contains(url.pathExtension.lowercased()) {
				importSubclips(from: url)
				return
			}
			else if url.pathExtension == "cuttr" {
				AppDelegate.remember(url)
				try? takeDocument.read(from: url)
				refresh()
				return
			}
		}
		guard video != nil || audio != nil else { return }
		takeDocument.setMedia(video: video, audio: audio)
	}

	/// Subclips made in DaVinci Resolve.
	///
	/// A take that has already been cut somewhere else should not have to be
	/// cut again. Resolve does not export its media pool, so the way across is
	/// a timeline — EDL, FCPXML or the older Final Cut Pro 7 XML — and all
	/// three arrive here.
	@objc public func importSubclips(_ sender: Any?) {
		let panel = NSOpenPanel()
		panel.allowedContentTypes = [
			UTType(filenameExtension: "edl") ?? .plainText,
			UTType(filenameExtension: "fcpxml") ?? .xml,
			.xml,
		]
		panel.allowsMultipleSelection = false
		panel.message = "Choose an EDL or XML timeline exported from Resolve"
		guard panel.runModal() == .OK, let url = panel.url else { return }
		importSubclips(from: url)
	}

	private func importSubclips(from url: URL) {
		do {
			let text = try String(contentsOf: url, encoding: .utf8)
			let clips = try ResolveImport.read(text, framesPerSecond: takeDocument.grid.framesPerSecond)
			// Camera timecode, shifted onto the take's clock when it plainly is
			// not on it already. Reported rather than done quietly: it moves
			// every mark in the file, and somebody has to be able to disagree.
			let (rebased, shift) = ResolveImport.rebase(clips, against: takeDocument.duration)
			let result = ResolveImport.merge(rebased, into: takeDocument.take, duration: takeDocument.duration)
			guard result.added > 0 else {
				bar.setStatus("nothing to import — every clip lands outside this recording")
				return
			}
			takeDocument.apply(result.take, actionName: "Import Subclips")
			var message = "imported \(result.added) from \(url.lastPathComponent)"
			if shift != 0 { message += "  ·  shifted by \(Timecode.offsetString(shift))" }
			if result.skipped > 0 { message += "  ·  \(result.skipped) outside the recording" }
			bar.setStatus(message)
			timeline.zoomToFit()
		} catch {
			report(error)
		}
	}

	@objc public func save(_ sender: Any?) {
		guard let url = takeDocument.url else { saveAs(sender); return }
		write(to: url)
	}

	@objc public func saveAs(_ sender: Any?) {
		let panel = NSSavePanel()
		panel.allowedContentTypes = [UTType(filenameExtension: "cuttr") ?? .plainText]
		panel.nameFieldStringValue = takeDocument.suggestedURL?.lastPathComponent ?? "take.cuttr"
		if let directory = takeDocument.suggestedURL?.deletingLastPathComponent() {
			panel.directoryURL = directory
		}
		guard panel.runModal() == .OK, let url = panel.url else { return }
		write(to: url)
	}

	private func write(to url: URL) {
		do {
			try takeDocument.write(to: url)
			AppDelegate.remember(url)
			bar.setStatus("saved \(url.lastPathComponent)")
			refresh()
		} catch {
			report(error)
		}
	}

	private func report(_ error: Error) {
		let alert = NSAlert(error: error)
		alert.beginSheetModal(for: window!)
	}

	/// Hands the window's responder chain this take's undo manager.
	///
	/// This is what a field editor asks for when somebody types into a clip
	/// name, so ⌘Z inside one takes back a keystroke.
	public func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
		takeDocument.undoManager
	}

	/// Undo and redo, as actions this controller answers to.
	///
	/// Not the bare `undo:` selector, which is what this was and which left the
	/// Edit menu permanently grey. `undo:` is `NSUndoManager`'s own method, and
	/// an undo manager is not in the responder chain — nothing between the first
	/// responder and the application implements it, so AppKit found no target,
	/// disabled the item, and never called `validateMenuItem` to ask. The chain
	/// has to reach an object that actually declares the method, and this is it.
	///
	/// A field editor still wins while somebody is typing, because it is earlier
	/// in the chain and has an undo manager of its own for the keystrokes.
	@objc public func undoEdit(_ sender: Any?) {
		if let editor = window?.firstResponder as? NSTextView,
		   let manager = editor.undoManager, manager !== takeDocument.undoManager, manager.canUndo {
			manager.undo()
			return
		}
		takeDocument.undoManager.undo()
	}

	@objc public func redoEdit(_ sender: Any?) {
		takeDocument.undoManager.redo()
	}

	/// Names what ⌘Z will do, so the menu says "Undo Trim Clip" rather than
	/// "Undo" — which is the only way to know whether it is about to take back
	/// the thing you meant.
	public func validateMenuItem(_ item: NSMenuItem) -> Bool {
		let manager = takeDocument.undoManager
		switch item.action {
		case #selector(undoEdit(_:)):
			item.title = manager.canUndo && !manager.undoActionName.isEmpty
				? "Undo \(manager.undoActionName)" : "Undo"
			return manager.canUndo
		case #selector(redoEdit(_:)):
			item.title = manager.canRedo && !manager.redoActionName.isEmpty
				? "Redo \(manager.redoActionName)" : "Redo"
			return manager.canRedo
		case #selector(deleteAction(_:)), #selector(renameSelected(_:)),
		     #selector(editSlugOfSelected(_:)), #selector(editTagsOfSelected(_:)),
		     #selector(zoomToClipAction(_:)),
		     #selector(trimStartToPoint(_:)), #selector(trimEndToPoint(_:)),
		     #selector(setInOutFromClip(_:)):
			return selectedClip != nil
		case #selector(alignAction(_:)):
			return takeDocument.videoWaveform != nil && takeDocument.audioWaveform != nil
		case #selector(nudgeEarlier(_:)), #selector(nudgeLater(_:)), #selector(cycleMonitor(_:)):
			return takeDocument.take.audio != nil
		case #selector(commitPendingAction(_:)):
			return pending != nil
		case #selector(transcribeAction(_:)):
			return wordsTask == nil
				&& (takeDocument.videoURL != nil || takeDocument.audioURL != nil)
		case #selector(nameFromWordsAction(_:)):
			return selectedClip != nil
				&& !(takeDocument.transcript.isEmpty && takeDocument.take.sounds.isEmpty)
		case #selector(findSoundsAction(_:)):
			return soundsTask == nil && wordsTask == nil
				&& (takeDocument.videoURL != nil || takeDocument.audioURL != nil)
		default:
			return true
		}
	}

	public func windowShouldClose(_ sender: NSWindow) -> Bool {
		guard takeDocument.isDirty else { return true }
		let alert = NSAlert()
		alert.messageText = "Save changes to \(takeDocument.displayName)?"
		alert.informativeText = "The clip list has unsaved cuts."
		alert.addButton(withTitle: "Save")
		alert.addButton(withTitle: "Discard")
		alert.addButton(withTitle: "Cancel")
		switch alert.runModal() {
		case .alertFirstButtonReturn: save(nil); return !takeDocument.isDirty
		case .alertSecondButtonReturn: return true
		default: return false
		}
	}

	public func windowWillClose(_ notification: Notification) {
		solveTask?.cancel()
		namingTask?.cancel()
		nameProposalTask?.cancel()
		wordsTask?.cancel()
		speakerTask?.cancel()
		soundsTask?.cancel()
		if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
		keyMonitor = nil
		transport.pause()
	}

	// MARK: - Keyboard

	/// A local event monitor rather than `keyDown` on a view.
	///
	/// The verbs have to work wherever the focus happens to be — the pointer is
	/// on the waveform and the last click was in the clip list, and `S` still
	/// has to mark. Putting them on a first responder means they stop working
	/// depending on where somebody clicked last, which is the sort of thing that
	/// is blamed on the app being slow.
	///
	/// The one exception is a field being *edited*, which gets every key: `S`
	/// in a clip name is an `s`.
	///
	/// Editable, not merely a text view. The transcript is an `NSTextView` too
	/// — it has to be, because a transcript is prose and wraps like prose — and
	/// it is where somebody selects the sentence they want to cut. If having
	/// the selection there swallowed the keyboard, the `⏎` that turns that
	/// selection into a clip would do nothing, having been handed to a view
	/// that takes no input. Nobody is typing into it, so it is not a field.
	private func installKeyMonitor() {
		keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
			guard let self, event.window === self.window else { return event }
			if let editing = self.window?.firstResponder as? NSTextView, editing.isEditable {
				return event
			}
			return self.handle(event) ? nil : event
		}
	}

	private func handle(_ event: NSEvent) -> Bool {
		// The words get first refusal, and only while the caret is in them.
		// Naming who is speaking is `1`, `2`, `3` — the same keys that pick a
		// clip lane everywhere else in this window — and a person reading a
		// transcript is unambiguously doing the first thing and not the
		// second. Nothing here is claimed under a modifier, so the menu keeps
		// every ⌘ it had.
		if transcriptPane.handleKey(event) { return true }

		let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
		let shift = flags.contains(.shift)
		let option = flags.contains(.option)
		let command = flags.contains(.command)

		// ⌘ belongs to the menu, with two exceptions that are navigation rather
		// than commands and have no sensible place in one.
		if command {
			switch event.keyCode {
			case 123: stepToMark(forward: false); return true   // ⌘←
			case 124: stepToMark(forward: true); return true    // ⌘→
			default: return false
			}
		}

		switch event.keyCode {
		case 49:   // space
			playSelectionOrToggle()
			return true
		case 123:  // ←
			step(-stepSize(shift: shift, option: option))
			return true
		case 124:  // →
			step(stepSize(shift: shift, option: option))
			return true
		case 115: move(to: 0); return true                        // home
		case 119: move(to: takeDocument.duration); return true        // end
		case 51, 117:                                             // ⌫ / ⌦
			deleteSelected()
			return true
		case 36, 76:                                              // return / enter
			commitReturn()
			return true
		case 53:                                                  // esc
			pending = nil
			timeline.pending = nil
			return true
		default:
			break
		}

		// Punctuation, by physical key as well as by character.
		//
		// `charactersIgnoringModifiers` returns what the *layout* produces, and
		// on a German keyboard `=` is Shift+0 and `[` and `]` are AltGr+8 and
		// AltGr+9 — so those three came back as "0", "8" and "9" and matched
		// nothing. Half the shortcuts in this program simply did not exist
		// outside a US layout.
		//
		// Key codes are physical positions and are the same everywhere, so they
		// are checked first; the characters stay as the second chance, which is
		// what makes the German `+` key (a different physical key from the US
		// one) zoom in as well.
		switch event.keyCode {
		case 24: timeline.zoomAroundPlayhead(by: 1 / 1.6); return true   // = / +
		case 27: timeline.zoomAroundPlayhead(by: 1.6); return true       // -
		case 33: nudge(-nudgeSize(shift: shift, option: option)); return true  // [
		case 30: nudge(nudgeSize(shift: shift, option: option)); return true   // ]
		default: break
		}

		// 1…6 pick a colour, the way they do in every editor that has labels.
		// Characters rather than key codes: the digit row is the digit row on
		// every layout this will meet.
		if let character = event.charactersIgnoringModifiers,
		   let digit = Int(character), digit >= 1, digit <= ClipColor.allCases.count {
			// The same rule as the swatches: this chooses the lane to cut on
			// next and does not touch anything already on the timeline.
			chooseLane(ClipColor.allCases[digit - 1])
			return true
		}

		switch event.charactersIgnoringModifiers?.lowercased() {
		case "c": jumpToEdge(); return true
		case "s": split(); return true
		case "i": setIn(); return true
		case "o": setOut(); return true
		case "n":
			if let selectedClip, let clip = takeDocument.take.clips.first(where: { $0.id == selectedClip }) {
				timeline.reveal(from: clip.start, to: clip.end)
				timeline.beginRenaming(clip)
			}
			return true
		case "a": autoAlign(); return true
		case "w": nameFromWords(); return true
		// `,` and `.` alongside `[` and `]`: both are unshifted on every layout
		// this is likely to meet, and they are where an editor's trim keys live
		// anyway.
		case "[", ",": nudge(-nudgeSize(shift: shift, option: option)); return true
		case "]", ".": nudge(nudgeSize(shift: shift, option: option)); return true
		case "f": timeline.zoomToFit(); return true
		case "z":
			// Zoom to the selected clip, or to a second around the playhead —
			// the two things somebody wants to look at closely.
			if let selectedClip { reveal(selectedClip) }
			else { timeline.reveal(from: playhead - 0.5, to: playhead + 0.5) }
			return true
		case "-", "_": timeline.zoomAroundPlayhead(by: 1.6); return true
		case "=", "+": timeline.zoomAroundPlayhead(by: 1 / 1.6); return true
		case "j": transport.setRate(shift ? -4 : -2); return true
		case "k": transport.pause(); return true
		case "l": transport.setRate(shift ? 4 : 2); return true
		case "m": cycleMonitor(); return true
		default:
			return false
		}
	}

	/// A frame, a tenth, or a second. The frame is the default because that is
	/// what "just past the breath" means when placing a cut.
	private func stepSize(shift: Bool, option: Bool) -> Double {
		if shift { return 1 }
		if option { return 0.1 }
		return takeDocument.grid.frameDuration
	}

	/// A millisecond, ten, or a hundred. Milliseconds by default: at this stage
	/// the alignment is already within a frame and the ear is doing the judging.
	private func nudgeSize(shift: Bool, option: Bool) -> Double {
		if option { return 0.1 }
		if shift { return 0.01 }
		return 0.001
	}
}

/// The window's content view, which takes files dropped on it.
final class DropView: NSView {
	var onDrop: (([URL]) -> Void)?

	override init(frame: NSRect) {
		super.init(frame: frame)
		registerForDraggedTypes([.fileURL])
	}

	@available(*, unavailable) required init?(coder: NSCoder) { nil }

	override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

	override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
		guard let urls = sender.draggingPasteboard.readObjects(
			forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
		else { return false }
		onDrop?(urls)
		return true
	}
}
