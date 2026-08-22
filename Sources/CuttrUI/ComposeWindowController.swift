import AVFoundation
import AppKit
import CuttrCompose
import CuttrKit
import UniformTypeIdentifiers

/// The composing window: what the project comes to, played.
///
/// The content of a window rather than a window — see ``DocumentEditor``.
///
/// The preview is not an approximation of the render. It is the same
/// `AVComposition` the renderer builds and the same Core Animation tree the
/// renderer hands to the encoder — the only difference is that one is played and
/// the other is written. That is the point of ``OverlayLayers/Host``: a preview
/// that agrees with the export by construction rather than by care.
@MainActor
public final class ComposeWindowController: DocumentEditor,
	NSMenuItemValidation, NSSplitViewDelegate {

	public let composeDocument: ComposeDocument
	/// The same transport the cutting window uses. One playback path in the
	/// program, not two.
	private let transport = Transport()
	private var playerView: PlayerView!
	private let strip = ProgrammeStrip()
	private let markers = AnchorMarkerView()
	private let overlayHost = NSView()
	/// Everything the project is made of, in one tree. This was two panes with
	/// a drag handle between them; see ``Material``.
	private let materialTree = MaterialTree()
	/// The width of the pane it sits in, held so it can be folded to the side.
	private var materialPaneWidth: NSLayoutConstraint?
	/// What it was before it was folded, so it comes back the size it was.
	private var materialWasWide: CGFloat = 260
	/// The button in the bar that folds it, kept so its state can follow.
	private var materialFold: NSButton?
	private let inspector = ProjectInspector()
	private let source = ProjectTextEditor()
	/// A real frame, for the reason in `roomToLayOutIn`: a tab view sizes the
	/// item views inside it, so a tab view at 0×0 hands every pane of this
	/// window a required `width == 0` before anything has been laid out.
	private let modes = NSTabView(frame: .roomToLayOutIn)

	/// Which of the five is showing.
	/// The rail's order, which is also the tab index and the ⌘ number: the page
	/// somebody works *in* comes before the page they watch. Preview is last
	/// because it is the end of the process, and a new page inserted above it
	/// would otherwise push the number somebody has in their fingers.
	public enum Mode: Int { case project, edit, text, levels, preview }
	private var mode: Mode = .edit
	/// Whether the window is showing the picture and nothing else.
	private var presenting = false
	/// The panes whose size somebody can drag, and the constraint that says how
	/// big each one wants to be — updated as the divider moves, or the next
	/// layout pass puts it straight back.
	private var dragged: [(view: NSView, size: NSLayoutConstraint, horizontal: Bool)] = []
	/// The bar that comes back when the mouse moves in full screen.
	private let controls = PlaybackControls()
	private var pointerWatch: Any?

	/// Opening a take is the application's business, not this window's: it may
	/// already be open somewhere.
	/// The flag is "in a window of its own", for ⌥ on the double-click.
	public var onOpenTake: ((URL, Bool) -> Void)?
	/// Open a take *at* a moment: from a clip on the programme to the place it
	/// was cut from, which is the question somebody asks when a shot is wrong.
	public var onOpenTakeAt: ((URL, Double) -> Void)?
	/// Whether a take is open. Renaming one that is would leave a document
	/// writing to a file that no longer exists.
	/// A take was renamed, and where it went — so whoever has it open follows.
	///
	/// This replaced asking whether it was open at all. Knowing that a take is
	/// open is only useful if the answer is going to be "then you cannot rename
	/// it", and every document in this application now lives in the same
	/// window, so that answer had stopped being an explanation and become an
	/// obstacle.
	public var onTakeRenamed: ((_ from: URL, _ to: URL) -> Void)?
	/// Open a scene of this project in the scene editor. A scene is a window's
	/// worth of editing — parts, keyframes, a stage — and putting that inside
	/// one field of the properties panel is what this callback exists to avoid.
	/// `nil` means "whichever one, or a new one".
	public var onEditScene: ((ComposeDocument, String?) -> Void)?
	/// Which of the three has the window, down the left edge — the same shape
	/// and the same place as the cutting window's.
	private let rail = Rail([
		Rail.Item("Project", "info.circle",
		          "What this project is, and what it renders to (\u{2318}1)"),
		Rail.Item("Edit", "list.bullet.indent",
		          "The programme, and everything about it (\u{2318}2)"),
		Rail.Item("Text", "curlybraces", "The project file as it stands (\u{2318}3)"),
		Rail.Item("Levels", "slider.horizontal.3",
		          "Every take's level, seen and heard against the others (\u{2318}4)"),
		Rail.Item("Play", "play.rectangle", "What it comes to, played (\u{2318}5)"),
	])
	/// The project itself: what it renders to, and what it is called.
	///
	/// The same panel that edits everything else, held to `output`. It was
	/// reachable only by deselecting every row in the tree — which is to say, by
	/// knowing that deselecting was a way of selecting something — and the frame
	/// size and rate of the thing being made are not an afterthought of the
	/// timeline.
	private let projectPanel = PropertiesPanel()
	/// Every take's level, together. Its own page rather than a panel beside the
	/// programme, because the whole of it is a comparison across takes and a
	/// comparison needs the width of a window — see ``LevelsPage``.
	private let levels = LevelsPage(frame: .roomToLayOutIn)
	private let renderButton = NSButton()
	/// The two controls that belong to the picture, over the picture: the anchor
	/// markers, and the way to give the picture the screen. Neither is true of
	/// the editor or of the file, which is what they were in a bar with.
	private let pictureControls = NSStackView()
	private let anchorsSwitch = NSButton(
		checkboxWithTitle: "Anchors", target: nil, action: nil)
	private let fullScreenButton = NSButton()
	private let problemLabel = NSTextField(labelWithString: "")

	/// The overlay tree, held at `speed = 0` and scrubbed by `timeOffset`.
	///
	/// A paused layer tree is Core Animation's own way of being at a time rather
	/// than running: setting `timeOffset` shows exactly the frame the export
	/// would produce at that moment, including part-way through a slide. Letting
	/// it run at `speed = 1` instead would drift against the player within
	/// seconds, because they are two clocks.
	private var overlayLayer: CALayer?
	/// What the preview was last built from, kept so a still can be pulled out
	/// of it for the properties panel.
	private var builtSession: UUID?
	private var builtComposition: AVComposition?
	private var builtVideoComposition: AVVideoComposition?
	private var builtAudioMix: AVAudioMix?
	private var builtDuration: Double = 0
	private var itemStatus: NSKeyValueObservation?
	private var buildTask: Task<Void, Never>?

	private var playhead: Double = 0
	private var keyMonitor: Any?
	/// Which stretch of the programme the Play page's strip is showing.
	private var stripZoom: (start: Double, end: Double)?

	public init(document: ComposeDocument) {
		self.composeDocument = document
		super.init()
		openingSize = NSSize(width: 1200, height: 820)
		minimumSize = NSSize(width: 900, height: 600)
		build()
		wire()
		document.onChange?()
		rebuild()
		// A project with nothing in it opens on itself.
		//
		// The editor is three empty lists and a form, and that is the first
		// thing anybody sees when they start this program — a screen whose whole
		// content is four captions explaining what is not there yet. The project
		// page has something to say about a new project on the day it is made:
		// what it is called, what size it is, what rate, where it renders to.
		// Once there is a programme, the programme is the point and the editor
		// opens as before.
		if composeDocument.project.timeline.isEmpty && composeDocument.takes.isEmpty {
			show(.project)
		}
	}

	@available(*, unavailable) required init?(coder: NSCoder) { nil }

	// MARK: - Layout

	private func build() {
		playerView = PlayerView(player: transport.player)

		buildBar()
		buildPictureControls()
		controls.onPlayPause = { [weak self] in self?.togglePlay(nil) }
		controls.onScrub = { [weak self] time in self?.seek(to: time) }

		source.onApply = { [weak self] text in
			guard let self, let url = self.composeDocument.url else { return }
			// Written straight out, then re-read: the file is what this program
			// believes, so applying means putting it there and letting the
			// document notice, exactly as an external editor would.
			try? text.write(to: url, atomically: true, encoding: .utf8)
			self.composeDocument.reload()
			self.say("applied")
		}

		problemLabel.font = Theme.monoSmall
		problemLabel.textColor = NSColor(calibratedRed: 0.95, green: 0.5, blue: 0.5, alpha: 1)
		problemLabel.lineBreakMode = .byTruncatingTail
		problemLabel.usesSingleLineMode = true
		// A message may not decide how wide the window is. A label's intrinsic
		// width is the width of its whole string whatever its truncation says,
		// so thirteen warnings joined into one line asked for five thousand
		// points and got them: the window opened five screens wide. Truncation
		// is what to do when there is not room; being *given* the room is the
		// bug.
		problemLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
		problemLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
		// The picture takes the slack, the error line takes its own height.
		//
		// Without saying so the layout is ambiguous: the bar and the strip are
		// fixed, and *both* the player and this label can absorb what is left —
		// one equation, two unknowns. AppKit picks one, and it picked the empty
		// text field, so the preview was a video view zero points tall. It
		// looked exactly like a preview that could not decode.
		problemLabel.setContentHuggingPriority(.required, for: .vertical)
		problemLabel.setContentCompressionResistancePriority(.required, for: .vertical)
		playerView.setContentHuggingPriority(.defaultLow, for: .vertical)
		playerView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

		// The picture and the strip in a split view, which is how the cutting
		// window arranges its player — and the cutting window's player works.
		//
		// This is not superstition. A split view sets its arranged subviews'
		// frames itself, which drives the layout and display of what is inside
		// them; a plain constrained sibling of a plain view was not getting
		// there, and the preview was the window's own grey. Two windows, one
		// arrangement.
		// The markers sit over the picture, inside the same pane, so they move
		// and clip with it — and so they never have to reach across to a view
		// that is not on screen. A tab view only keeps the *selected* item's
		// view in the window, so a constraint from here to the player would be
		// tying together two hierarchies with nothing in common, which AppKit
		// answers by throwing.
		// The overlays get a view of their own between the picture and the
		// markers, rather than a sublayer of the player's own layer. A player
		// layer is the video's, and what it does with sublayers is its business.
		overlayHost.wantsLayer = true
		overlayHost.layer?.masksToBounds = true

		let picture = NSView()
		for view in [playerView, overlayHost, markers] as [NSView] {
			view.translatesAutoresizingMaskIntoConstraints = false
			picture.addSubview(view)
			NSLayoutConstraint.activate([
				view.topAnchor.constraint(equalTo: picture.topAnchor),
				view.bottomAnchor.constraint(equalTo: picture.bottomAnchor),
				view.leadingAnchor.constraint(equalTo: picture.leadingAnchor),
				view.trailingAnchor.constraint(equalTo: picture.trailingAnchor),
			])
		}
		// The full-screen controls: along the bottom of the picture, over
		// everything, invisible until somebody moves the mouse.
		controls.translatesAutoresizingMaskIntoConstraints = false
		picture.addSubview(controls)
		NSLayoutConstraint.activate([
			controls.leadingAnchor.constraint(equalTo: picture.leadingAnchor),
			controls.trailingAnchor.constraint(equalTo: picture.trailingAnchor),
			controls.bottomAnchor.constraint(equalTo: picture.bottomAnchor),
			controls.heightAnchor.constraint(equalToConstant: 76),
		])

		// The picture's own two controls, in its top corner.
		pictureControls.translatesAutoresizingMaskIntoConstraints = false
		picture.addSubview(pictureControls)
		NSLayoutConstraint.activate([
			pictureControls.trailingAnchor.constraint(
				equalTo: picture.trailingAnchor, constant: -12),
			pictureControls.topAnchor.constraint(equalTo: picture.topAnchor, constant: 12),
		])

		// A real frame, not zero.
		//
		// A split view created at 0x0 has its size turned into a pair of
		// *required* constraints by its autoresizing mask — `width == 0`,
		// `height == 0` — and every content minimum inside it is then one half
		// of a system with no solution. That is the same lesson `TableScroll`
		// already records for scroll views, and it is what filled the log with
		// `layout constraints are not satisfiable` before this window had ever
		// been shown.
		let split = NSSplitView(frame: .roomToLayOutIn)
		split.isVertical = false
		split.dividerStyle = .thin
		split.addArrangedSubview(picture)
		split.addArrangedSubview(strip)

		// The takes down the side. A project is a programme made of recordings,
		// and the recordings are the thing somebody reaches for next — to open
		// one, to cut another, to find out why one of them stopped resolving.
		// The takes belong with the editor: they are the material the programme
		// is made of, and choosing one is an editing act rather than something
		// to look at while the picture plays.
		//
		// Under them, everything those takes contain: the clips, the tags, the
		// tracked faces. A project is assembled by dragging from that list onto
		// the programme, which is why the two live in one column — the material
		// on the left, the programme in the middle, its properties on the right.
		let material = materialTree

		let editing = NSSplitView(frame: .roomToLayOutIn)
		editing.isVertical = true
		editing.dividerStyle = .thin
		editing.addArrangedSubview(material)
		editing.addArrangedSubview(inspector)

		// A tab view with no tabs of its own: the segmented control in the bar
		// is the switch, because it sits with the other things this window can
		// do rather than starting a second row of furniture.
		modes.tabViewType = .noTabsNoBorder
		modes.drawsBackground = false
		// In the rail's order, because `Mode`'s raw value is the index of both.
		for (identifier, view) in [("project", projectPage()), ("edit", editing),
		                          ("text", source), ("levels", levels),
		                          ("preview", split)] as [(String, NSView)] {
			let item = NSTabViewItem(identifier: identifier)
			item.view = view
			modes.addTabViewItem(item)
		}

		let content = DropView(frame: .roomToLayOutIn)
		content.onDrop = { [weak self] urls in
			guard let url = urls.first(where: { $0.pathExtension == "cuttrproj" }) else { return }
			try? self?.composeDocument.read(from: url)
		}
		content.wantsLayer = true
		content.layer?.backgroundColor = Theme.background.cgColor

		// The bar across the top, the rail down the left, and whatever the rail
		// has chosen filling the rest. The same three regions as the cutting
		// window, in the same places, so it is one arrangement to learn.
		// The content area is one colour and the rail is another.
		//
		// The warning line used to sit straight on the window's own ground,
		// which is what the rail is drawn in — so there was a band of the rail's
		// colour running along the top of the content, and the rail read as
		// turning a corner. Two areas, two colours, and this is the ground the
		// content area stands on.
		let ground = NSView()
		ground.wantsLayer = true
		ground.layer?.backgroundColor = Theme.panel.cgColor
		ground.translatesAutoresizingMaskIntoConstraints = false
		content.addSubview(ground)

		// No bar among them: it belongs to the window now, and this view is
		// what goes under it.
		for view in [rail, problemLabel, modes] as [NSView] {
			view.translatesAutoresizingMaskIntoConstraints = false
			content.addSubview(view)
		}
		NSLayoutConstraint.activate([
			// The rail says how wide it is; this only says where.
			rail.topAnchor.constraint(equalTo: content.topAnchor),
			rail.leadingAnchor.constraint(equalTo: content.leadingAnchor),
			rail.bottomAnchor.constraint(equalTo: content.bottomAnchor),

			ground.topAnchor.constraint(equalTo: content.topAnchor),
			ground.leadingAnchor.constraint(equalTo: rail.trailingAnchor),
			ground.trailingAnchor.constraint(equalTo: content.trailingAnchor),
			ground.bottomAnchor.constraint(equalTo: content.bottomAnchor),

			problemLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 2),
			problemLabel.leadingAnchor.constraint(equalTo: rail.trailingAnchor, constant: 10),
			problemLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
			problemLabel.heightAnchor.constraint(equalToConstant: 14),

			modes.topAnchor.constraint(equalTo: problemLabel.bottomAnchor, constant: 2),
			modes.leadingAnchor.constraint(equalTo: rail.trailingAnchor),
			modes.trailingAnchor.constraint(equalTo: content.trailingAnchor),
			modes.bottomAnchor.constraint(equalTo: content.bottomAnchor),
		])

		let preferred = NSLayoutConstraint.Priority(250)
		// The same as in the inspector: these say how big a pane wants to be,
		// and since nothing else does, they are also what pulls a dragged
		// divider back. Held on to and followed along as the dividers move.
		let materialWidth = material.widthAnchor.constraint(equalToConstant: 260)
		let stripHeight = strip.heightAnchor.constraint(equalToConstant: 200)
		dragged = [(material, materialWidth, true), (strip, stripHeight, false)]
		materialPaneWidth = materialWidth
		editing.delegate = self
		split.delegate = self
		let wishes = [materialWidth, stripHeight]
		for wish in wishes { wish.priority = preferred; wish.isActive = true }
		NSLayoutConstraint.activate([
			// Floors, not laws — see `asFloor`. All five are inside split views
			// inside a tab view, and the item that is not showing has no size.
			material.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).asFloor,
			strip.heightAnchor.constraint(greaterThanOrEqualToConstant: 90).asFloor,
			playerView.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).asFloor,
		])

		contentRoot = content
		// Nothing in this window opens with the keyboard in it.
		//
		// Left to itself AppKit hands the first responder to the first text
		// field it can find, which on the project page is the output's frame
		// width — so a new window opened with a cursor blinking in the size of
		// the film, where a stray keystroke edits it. It also broke opening a
		// file: the properties panel refuses to rebuild while one of its fields
		// is being edited, because a reload mid-word takes the cursor with it,
		// and a field that had focus merely by default looked exactly like a
		// field somebody was typing in. The file was read, the panel declined to
		// show it, and the page stayed on the empty project it had been built
		// with until somebody switched pages and back.
		initialResponder = rail

		// No marking here: an anchor is marked on the take, in the cutting
		// window, where the footage is. This window shows what was found.
	}

	/// The work tree this project's file sits in, if it sits in one.
	private var repositoryRoot: URL?
	private var repositoryFor: URL?

	private func findRepository() {
		guard composeDocument.url != repositoryFor else { return }
		repositoryFor = composeDocument.url
		repositoryRoot = composeDocument.url.flatMap { GitRepository.root(for: $0) }
	}

	/// For the tests: which of the four is showing.
	/// ⌘Z on a programme. There was none until now — see
	/// ``ComposeDocument/apply(_:actionName:)``.
	override var documentUndoManager: UndoManager? { composeDocument.undoManager }

	var modeForTesting: Mode { mode }
	/// For the test that watching the film does not mean watching the tracking
	/// marks over everybody's faces.
	var anchorsShowingForTesting: Bool { !markers.isHidden }

	/// Driving the switch the way a click on it would, rather than by sending
	/// one: an unhandled event reaches `NSResponder` and beeps.
	func setAnchorsForTesting(_ on: Bool) {
		anchorsSwitch.state = on ? .on : .off
		anchorsChanged()
	}

	/// For the tests: the rail, so its place can be compared with the other
	/// window's.
	var railForTesting: Rail { rail }
	/// For the tests: the takes list, so the double-click that opens a take can
	/// be driven where it actually starts.
	var materialForTesting: MaterialTree { materialTree }
	/// The last thing the status line was told, for the tests. `say` is how
	/// every outcome of a share reaches somebody, so a test that presses the
	/// button and reads this is the only one that can tell "it worked" from
	/// "it did nothing at all".
	var saidForTesting: String { said }

	/// Asking for a frame the way the info page does. A programme with no
	/// footage in it has none, and asking AVFoundation anyway aborts the
	/// process — see ``poster(at:then:)``.
	func posterForTesting(at time: Double, then done: @escaping (NSImage?) -> Void) {
		poster(at: time, then: done)
	}
	/// For the tests: the levels page, so a slider can be driven at its seam
	/// rather than by an event nobody handles.
	var levelsForTesting: LevelsPage { levels }
	/// For the test that this window still follows the tape. The handlers that
	/// do it spent every release so far stranded after a `return`, which is a
	/// thing only a test that asks whether they are installed can see.
	var transportForTesting: Transport { transport }
	var playheadForTesting: Double { playhead }
	/// For the tests: the project page's panel, so the frame in its head can be
	/// waited for.
	var projectPanelForTesting: PropertiesPanel { projectPanel }

	/// The bar: the project's name, the clock, what just happened — and two
	/// things that are true whatever mode is showing.
	///
	/// `Render…` is one of them: it is what the whole window is for and it does
	/// not belong to a mode. The mode switch is the other, and only until the
	/// rail takes it; `⌘1`/`⌘2`/`⌘3` already do the same thing.
	private func buildBar() {
		rail.onSelect = { [weak self] index in self?.show(Mode(rawValue: index) ?? .edit) }

		// The levels page says what it is doing in the window's own status line
		// and shows how far along it is on the window's own bar. Decoding a
		// folder of footage and measuring it are the two things on that page
		// that take long enough to need saying, and a page does not get
		// furniture of its own for what the window already has.
		levels.onSay = { [weak self] text in self?.say(text) }
		levels.onProgress = { [weak self] fraction in self?.showProgress(fraction) }

		// A picture rather than the word. It sits beside a clock and a play
		// button, which are both shapes, and one word among them reads as the
		// odd one out — `movieclapper` is what this makes: a film, written to a
		// file. The word is still there on hover and in the File menu.
		renderButton.isBordered = false
		renderButton.bezelStyle = .inline
		renderButton.imagePosition = .imageOnly
		renderButton.image = NSImage(
			systemSymbolName: "movieclapper", accessibilityDescription: "render")
			?? NSImage(systemSymbolName: "film", accessibilityDescription: "render")
		renderButton.image = renderButton.image?.withSymbolConfiguration(
			.init(pointSize: 13, weight: .medium).applying(.init(paletteColors: [Theme.text])))
		renderButton.target = self
		renderButton.action = #selector(render(_:))
		renderButton.toolTip = "Render\u{2026} (\u{21E7}\u{2318}R)"
		renderButton.translatesAutoresizingMaskIntoConstraints = false
		renderButton.widthAnchor.constraint(equalToConstant: 24).isActive = true
	}

	// MARK: - Being the document in the window

	override var documentTitle: String { composeDocument.displayName }
	override var documentFile: URL? { composeDocument.url }

	/// What a project puts in the shared bar: its name, the branch, `Render…`,
	/// and the two halves of the capsule.
	override func furnish(_ bar: DocumentBar) {
		// A project is the outermost thing there is; there is nowhere to go back to.
		bar.setBack(false)
		if shareButton.target == nil {
			shareButton.bezelStyle = .rounded
			shareButton.controlSize = .small
			shareButton.font = NSFont.systemFont(ofSize: 11)
			shareButton.target = self
			shareButton.action = #selector(shareProject(_:))
			shareButton.isHidden = true
			shareButton.setContentHuggingPriority(.defaultHigh, for: .horizontal)
		}
		bar.addTrailing(shareButton)
		bar.addTrailing(renderButton)

		// The fold, in the bar rather than in the pane it folds: a chevron
		// inside the material goes away with it, and then nothing on screen
		// brings it back. Run on every appearance, so it is made once and kept.
		let fold = materialFold ?? NSButton()
		if materialFold == nil {
			fold.isBordered = false
			fold.bezelStyle = .inline
			fold.imagePosition = .imageOnly
			fold.image = NSImage(systemSymbolName: "sidebar.leading",
			                     accessibilityDescription: "the material")?
				.withSymbolConfiguration(.init(pointSize: 12, weight: .semibold)
					.applying(.init(paletteColors: [Theme.dimText])))
			fold.target = self
			fold.action = #selector(toggleMaterial(_:))
			fold.toolTip = "Fold the material away"
			fold.translatesAutoresizingMaskIntoConstraints = false
			fold.widthAnchor.constraint(equalToConstant: 22).isActive = true
			materialFold = fold
		}
		bar.addLeading(fold)
		bar.onPlayPause = { [weak self] in self?.playPressed() }
		// The two halves of the capsule: the documents on the left, and what can
		// be done about the repository this one sits in on the right.
		bar.onProject = { [weak self] in
			guard let self else { return }
			self.bar?.setOpenHalf(.project)
			guard let (view, rect) = self.bar?.anchor(for: .project) else { return }
			AppDelegate.shared?.showDocumentSwitcher(from: view, rect: rect) {
				self.bar?.setOpenHalf(nil)
			}
		}
		bar.onBranch = { [weak self] in
			guard let self, let root = self.repositoryRoot else { return }
			self.bar?.setOpenHalf(.branch)
			guard let menu = BranchMenu.menu(for: root,
			                                 branch: GitRepository.branch(in: root)) else {
				self.bar?.setOpenHalf(nil)
				return
			}
			guard let (view, rect) = self.bar?.anchor(for: .branch) else { return }
			menu.popUp(positioning: nil, at: NSPoint(x: rect.minX, y: rect.maxY + 4), in: view)
			self.bar?.setOpenHalf(nil)
		}
		bar.setName(composeDocument.displayName)
		bar.setBranch(repositoryRoot.flatMap { GitRepository.branch(in: $0) })
		bar.setClock(playhead)
		bar.setPlaying(transport.isPlaying)
		bar.setStatus(said)
		bar.setProgress(progressed)
	}

	/// What this project last said, and how far along it was — kept here rather
	/// than on the bar, because the bar is the window's and the next document to
	/// come through it would otherwise be looking at this project's message.
	private var said = ""
	private var progressed: Double?

	/// A frame of the finished programme, or nothing when there is no picture
	/// to take one from.
	///
	/// **A composition with no video track is a real project**, not a broken
	/// one: a programme of cards and scenes has no footage in it anywhere.
	/// Asking `AVAssetImageGenerator` for a frame of one throws an
	/// Objective-C exception from inside AVFoundation — `[videoTracks count]
	/// >= 1` — and nothing in Swift can catch that, so it takes the whole
	/// program down. It took the test process down first, which is the only
	/// reason anybody found out.
	///
	/// One of these, not two. The info page and the placement dialogs both
	/// want the same frame from the same composition.
	/// Whether there is a frame to be had at all.
	///
	/// Split from the asking so it can be checked: reaching the throw needs a
	/// *built* composition, and a test that stops at `builtComposition == nil`
	/// passes whether or not the guard is there — which the first version of
	/// this test did.
	static func hasPicture(_ composition: AVAsset) -> Bool {
		!composition.tracks(withMediaType: .video).isEmpty
	}

	private func poster(at time: Double, then done: @escaping (NSImage?) -> Void) {
		guard let composition = builtComposition, Self.hasPicture(composition) else {
			return done(nil)
		}
		let generator = AVAssetImageGenerator(asset: composition)
		generator.videoComposition = builtVideoComposition
		generator.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
		generator.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)
		generator.generateCGImageAsynchronously(
			for: CMTime(seconds: max(0, time), preferredTimescale: 600)
		) { image, _, _ in
			let picture = image.map { NSImage(cgImage: Self.asShown($0), size: .zero) }
			Task { @MainActor in done(picture) }
		}
	}

	private func say(_ text: String) {
		said = text
		bar?.setStatus(text)
	}

	private func showProgress(_ fraction: Double?) {
		progressed = fraction
		bar?.setProgress(fraction)
	}

	/// Back on screen. The picture is only in the window on the preview page, so
	/// the overlays are laid out again against whatever size the window is now.
	override func documentAppeared() {
		layoutOverlays()
		refreshStanding()
		standingWatch?.invalidate()
		// Slow on purpose. Everything it reads is local — it never fetches —
		// but it is still three subprocesses, and what it watches for, somebody
		// else pushing, does not happen twice a second.
		standingWatch = Timer.scheduledTimer(timeInterval: 30, target: self,
		                                     selector: #selector(refreshStanding),
		                                     userInfo: nil, repeats: true)
	}

	/// Off screen and still open: the tape stops, and full-screen presentation
	/// ends — a project cannot present itself from behind another document.
	override func documentHidden() {
		if presenting { toggleFullScreenPreview(nil) }
		transport.pause()
		levels.stop()
		standingWatch?.invalidate()
		standingWatch = nil
	}

	/// The controls that belong to the picture, in the corner of the picture.
	///
	/// They were in the bar, where they were furniture for something that is not
	/// on screen two thirds of the time. Over the picture they are only there
	/// when the thing they are about is.
	private func buildPictureControls() {
		anchorsSwitch.state = .on
		anchorsSwitch.font = NSFont.systemFont(ofSize: 11)
		anchorsSwitch.target = self
		anchorsSwitch.action = #selector(anchorsChanged)
		anchorsSwitch.toolTip = "Show where the tracked faces are. They are for placing an overlay, "
			+ "and in the way once it is placed."

		fullScreenButton.bezelStyle = .rounded
		fullScreenButton.controlSize = .small
		fullScreenButton.imagePosition = .imageOnly
		fullScreenButton.image = NSImage(
			systemSymbolName: "arrow.up.left.and.arrow.down.right",
			accessibilityDescription: "full screen")?
			.withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
		fullScreenButton.target = self
		fullScreenButton.action = #selector(toggleFullScreenPreview(_:))
		fullScreenButton.toolTip = "Watch it full screen \u{2014} the picture and nothing else"
		fullScreenButton.translatesAutoresizingMaskIntoConstraints = false
		fullScreenButton.widthAnchor.constraint(equalToConstant: 26).isActive = true

		pictureControls.orientation = .horizontal
		pictureControls.spacing = 8
		pictureControls.alignment = .centerY
		pictureControls.addView(anchorsSwitch, in: .leading)
		pictureControls.addView(fullScreenButton, in: .leading)
		pictureControls.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
		pictureControls.wantsLayer = true
		pictureControls.layer?.backgroundColor = NSColor(calibratedWhite: 0, alpha: 0.45).cgColor
		pictureControls.layer?.cornerRadius = 6
	}

	@objc private func anchorsChanged() {
		// The markers are for placing an overlay against a face, and once it is
		// placed they are in the way of seeing the thing they placed.
		markers.isHidden = anchorsSwitch.state != .on
	}

	/// What the anchors were doing on the editing side, so going to watch the
	/// programme and coming back does not lose the choice.
	private var anchorsWereOn = true
	private var anchorsQuiet = false

	/// Anchors are off while the film is being watched, and on while it is
	/// being made.
	///
	/// A tracked face is a thing you place an overlay *against*; once it is
	/// placed, the dots are in the way of seeing the thing they placed. The
	/// preview page and full screen are both "show me the film", and a film
	/// with tracking marks over the faces is not the film.
	///
	/// One rule derived from where somebody is, rather than a pair of
	/// hand-offs at each door. Full screen is entered *through* the preview
	/// page, so an on-the-way-in and an on-the-way-out at both would fire
	/// twice going in — the second remembering the state the first had just
	/// set — and leaving full screen onto the preview page would have brought
	/// them back on the page that is supposed not to have them.
	///
	/// Off by default and not off for good: the switch is still on the picture,
	/// and turning them on while watching is a thing somebody may want once.
	private func anchorsFollowTheMode() {
		let watching = mode == .preview || presenting
		guard watching != anchorsQuiet else { return }
		anchorsQuiet = watching
		if watching {
			anchorsWereOn = anchorsSwitch.state == .on
			anchorsSwitch.state = .off
		} else {
			anchorsSwitch.state = anchorsWereOn ? .on : .off
		}
		anchorsChanged()
	}

	// MARK: - Wiring

	private func wire() {
		followTheTape()
		composeDocument.onChange = { [weak self] in
			self?.rebuild()
			// A save is what makes something to upload, so the button follows
			// it — otherwise it says "nothing to do" over a file that has just
			// changed, which is the way it was invisible before.
			self?.refreshStanding()
		}
		// A version being kept is worth a word in the line that already carries
		// what just happened, and nothing more. It must never be a sheet: the
		// save has already happened by the time this runs, and interrupting an
		// edit to talk about our own bookkeeping would be worse than keeping no
		// versions at all.
		composeDocument.history.onOutcome = { [weak self] outcome in
			guard let self else { return }
			switch outcome {
			case .kept(let version): self.say("kept a version — \(version.short)")
			// Not in a work tree, nothing changed, or somebody is mid-rebase.
			// All three are ordinary and none is worth a word.
			case .nothingChanged, .noRepository: break
			case .busy(let what): self.say("no version kept — \(what) is in progress")
			case .failed(let why): self.say("no version kept — \(why)")
			}
		}
		strip.onScrub = { [weak self] time in self?.seek(to: time) }
		// A zoom outlives the strip's own redraws but not the window, which is
		// right: it is a fact about what somebody is looking at, not about the
		// project. Held here so a re-resolve does not throw it away.
		strip.onZoom = { [weak self] window in self?.stripZoom = window }

		// Double-click a clip on the programme to open the take it came from,
		// at the moment under the pointer — the programme's clock turned back
		// into the take's.
		strip.onOpenClip = { [weak self] clip, time in
			guard let self, let take = self.composeDocument.takes
				.first(where: { $0.name == clip.takeName })
			else { return }
			self.onOpenTakeAt?(take.url, clip.takeTime(forProgramme: time))
		}

		// The same journey as a double-click on the programme, from the two
		// lists: right-click a placement or a clip and be taken to where it was
		// cut. The panel and the library know what was pointed at; only this
		// window knows which file that take is in.
		inspector.onOpenInTake = { [weak self] path in
			guard let self, let placed = self.composeDocument.resolved?.clips
				.first(where: { $0.entry == path }),
			      let take = self.composeDocument.takes
				.first(where: { $0.name == placed.takeName })
			else { return }
			// The first frame this placement shows, which is the clip's start
			// plus whatever was trimmed off for this use of it.
			self.onOpenTakeAt?(take.url, placed.clip.start)
		}
		// One section, from its own menu: to the preview, to its first frame,
		// and stopping where it ends rather than running on into the rest of
		// the programme.
		inspector.onPreviewSection = { [weak self] name in
			guard let self, let group = self.composeDocument.resolved?.groups
				.first(where: { $0.name == name })
			else { return }
			self.show(.preview)
			self.transport.play(from: group.start, to: group.end)
		}

		materialTree.onOpenInTake = { [weak self] item in
			guard let self, let take = self.composeDocument.takes
				.first(where: { $0.name == item.take })
			else { return }
			self.onOpenTakeAt?(take.url, item.start)
		}

		// Dragged on the big timeline, written back the way the file says it:
		// snapped to a clip, kept relative to one, or in programme times —
		// whichever that range was already using.
		strip.onMoveOverlay = { [weak self] origin, appearance, start, end in
			guard let self, let resolved = self.composeDocument.resolved else { return }
			var next = self.composeDocument.project
			// An overlay written inside an entry stays relative to that entry.
			//
			// It used to be written as programme times, and that quietly undid
			// the thing putting it inside a clip was *for*: it stopped following
			// the clip, so the next change upstream moved the shot and left the
			// overlay behind. See ``CuttrCompose/Overlay/Span/inside(_:start:end:in:)``
			// for what it cost. Same drag, same two ends, written the way that
			// survives a re-cut.
			var relative: Overlay.Span?
			if case .entry(let path, _) = origin, let entry = next.entry(at: path) {
				// A clip the programme uses more than once cannot be named by
				// its slug — `within:` that slug would put the overlay on at
				// every use of it. `as:` is the file's own way of naming one
				// placement, so the entry is given one, once, and the range
				// names that. Better a name in the file than an overlay that
				// comes on twice or drifts.
				if Overlay.Span.needsAName(entry, in: resolved) {
					var named = entry
					named.label = Slug.unique(entry.source.description,
					                          taken: next.entryNames)
					next.replaceEntry(at: path, with: named)
				}
				relative = next.entry(at: path).flatMap {
					Overlay.Span.inside($0, start: start, end: end, in: resolved)
				}
			}
			next.editOverlay(at: origin) { overlay in
				guard appearance < overlay.appearances.count else {
					guard overlay.appearances.isEmpty else { return }
					overlay.appearances = [Overlay.Appearance(relative
						?? Overlay.Span.times(from: start, to: end)
							.moved(start: start, end: end, in: resolved))]
					return
				}
				// A range that already says how it wants to be written keeps
				// that spelling; only programme times — the fragile one — are
				// turned into something relative.
				if case .times = overlay.appearances[appearance].span, let relative {
					overlay.appearances[appearance].span = relative
					return
				}
				overlay.appearances[appearance].span = overlay.appearances[appearance].span
					.moved(start: start, end: end, in: resolved)
			}
			self.composeDocument.apply(next, actionName: "Move Overlay")
			try? self.composeDocument.write()
		}

		// The project page writes through the same door as everything else: it
		// is the same panel, so an edit here is an edit there.
		projectPanel.onChange = { [weak self] project in
			guard let self else { return }
			self.composeDocument.apply(project)
			try? self.composeDocument.write()
		}

		inspector.onChange = { [weak self] project in
			guard let self else { return }
			// Straight to the file. The panel is a way of writing the project,
			// so an edit that only lived in memory would be a second source of
			// truth — and the file is the one this program believes.
			self.composeDocument.apply(project)
			try? self.composeDocument.write()
		}

		materialTree.onOpen = { [weak self] url, aside in self?.onOpenTake?(url, aside) }
		materialTree.onRemove = { [weak self] path in self?.composeDocument.removeTake(path) }
		materialTree.onAdd = { [weak self] in self?.addTake(nil) }
		materialTree.onRename = { [weak self] path, name in
			guard let self else { return }
			let from = URL(fileURLWithPath: path, relativeTo: self.composeDocument.baseURL)
				.standardizedFileURL
			switch self.composeDocument.renameTake(path, to: name) {
			case .unchanged:
				self.rebuild()
			case .refused(let why):
				self.say(why)
				self.rebuild()
			case .renamed(let to):
				// Whoever has this take open is told its new name. It used to be
				// refused instead — the open document held the old URL and its
				// next save would have written the old file back, undoing the
				// rename — and that was a fair reason to refuse when a take was
				// a window somebody had to go and close. It is not one now.
				self.onTakeRenamed?(from, to.standardizedFileURL)
				self.say("renamed to \(to.lastPathComponent)")
				self.rebuild()
			}
		}
		materialTree.onNew = { [weak self] in self?.newTake(nil) }

		// A scene is material this project is made of, so it is worked on from
		// the list of what the project is made of. `nil` is a new one.
		materialTree.onScene = { [weak self] name in
			guard let self else { return }
			self.onEditScene?(self.composeDocument, name)
		}
		// Arranging the takes. Each goes through `apply`, so each is one step
		// of undo with a name on it.
		materialTree.onNewFolder = { [weak self] name in
			guard let self else { return }
			var next = self.composeDocument.project
			next.addFolder(named: name)
			self.composeDocument.apply(next, actionName: "New Folder")
			try? self.composeDocument.write()
		}
		materialTree.onRenameFolder = { [weak self] name, wanted in
			guard let self else { return }
			var next = self.composeDocument.project
			next.renameFolder(name, to: wanted)
			self.composeDocument.apply(next, actionName: "Rename Folder")
			try? self.composeDocument.write()
		}
		materialTree.onRemoveFolder = { [weak self] name in
			guard let self else { return }
			var next = self.composeDocument.project
			next.removeFolder(name)
			self.composeDocument.apply(next, actionName: "Remove Folder")
			try? self.composeDocument.write()
		}
		materialTree.onMoveTake = { [weak self] take, folder in
			guard let self else { return }
			var next = self.composeDocument.project
			next.move(take: take, toFolder: folder)
			self.composeDocument.apply(next, actionName: "Move Take")
			try? self.composeDocument.write()
		}
		materialTree.onAddScene = { [weak self] in self?.addScene() }
		materialTree.onRemoveScene = { [weak self] name in
			guard let self else { return }
			var next = self.composeDocument.project
			next.scenes.removeValue(forKey: name)
			self.composeDocument.apply(next)
		}

		// A frame of the programme at a moment, for placing an overlay on. The
		// same composition the preview plays, so what is dragged over is what
		// will be rendered under.
		inspector.onScrub = { [weak self] time in self?.seek(to: time) }
		// The same clock read back, for `I` and `O` in the properties panel.
		inspector.playhead = { [weak self] in self?.playhead ?? 0 }

		// The dialogs that set a moment against the programme play the same
		// thing the preview plays, rather than building a second one.
		inspector.playable = { [weak self] in
			guard let self, let composition = self.builtComposition else { return nil }
			return (composition, self.builtVideoComposition, self.builtAudioMix,
			        self.builtDuration)
		}
		inspector.poster = { [weak self] time, done in
			guard let self else { return done(nil) }
			self.poster(at: time, then: done)
		}
		materialTree.onInsert = { [weak self] reference in self?.inspector.insert(reference: reference) }

		// The same arrangement as the cutting window, for the same reason: the
		// keys have to work wherever the focus happens to be.
		keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
			guard let self, event.window === self.window else { return event }
			return self.handle(event) ? nil : event
		}
	}

	/// What the tape rolling looks like: the playhead, the clock, and the
	/// overlay tree held at the same moment as the picture.
	///
	/// **This was never installed.** It sat at the bottom of `handle(_:)`,
	/// after a `switch` in which every case returns, so nothing ever reached
	/// it — the compiler said so and said so from the first commit. The picture
	/// played, because that is `AVPlayer`'s doing and needs nobody's help; the
	/// playhead line, the clock and the full-screen controls did not move,
	/// because this is what moves them.
	private func followTheTape() {
		transport.onTick = { [weak self] time in
			guard let self else { return }
			self.playhead = time
			self.strip.playhead = time
			self.markers.playhead = time
			// The overlay tree is paused; this is what puts it at the same
			// moment as the picture, exactly, every tick.
			self.overlayLayer?.timeOffset = time
			self.bar?.setClock(time)
			// The full-screen bar shows the same clock, and only while it is
			// the thing on screen.
			if self.presenting {
				self.controls.playhead = time
				self.controls.duration = self.composeDocument.resolved?.duration ?? 0
				self.controls.isPlaying = self.transport.isPlaying
			}
		}
		transport.onRateChange = { [weak self] rate in
			guard let self else { return }
			self.bar?.setPlaying(rate != 0)
			guard self.presenting else { return }
			self.controls.isPlaying = rate != 0
			// Pausing is a reason to see the controls: somebody has just
			// reached for them.
			if rate == 0 { self.controls.wake(for: 4) }
		}
	}

	// MARK: - Folding the material away

	/// Whether the material pane is showing.
	public private(set) var isMaterialShowing = true

	/// Folds the tree away to the side, and brings it back the width it was.
	///
	/// **The control cannot live in the pane.** A chevron inside it goes away
	/// with it, and then there is nothing on screen to bring it back — which is
	/// how a sidebar becomes a thing somebody loses. So it is in the bar, which
	/// is outside every pane and always there.
	///
	/// The width is remembered rather than reset, because the pane is dragged
	/// to a width somebody chose and coming back at 260 would throw that away.
	@objc public func toggleMaterial(_ sender: Any?) {
		guard let width = materialPaneWidth else { return }
		isMaterialShowing.toggle()
		if isMaterialShowing {
			width.constant = materialWasWide
			materialTree.isHidden = false
		} else {
			materialWasWide = max(width.constant, 200)
			materialTree.isHidden = true
			width.constant = 0
		}
		materialFold?.state = isMaterialShowing ? .on : .off
		materialFold?.toolTip = isMaterialShowing
			? "Fold the material away" : "Show the material"
	}

	// MARK: - The View menu's zooms

	/// ⌘+, ⌘− and ⌘0, which the View menu has always offered and which only the
	/// cutting window answered — so in this window the items were simply greyed
	/// out and the same keys that zoom a take did nothing to a programme.
	///
	/// Answered here rather than claimed in this window's key monitor: they are
	/// menu items with key equivalents, the menu is where somebody finds them,
	/// and a window that took ⌘ keys behind the menu's back would be a second
	/// answer to the same question.
	@objc public func zoomIn(_ sender: Any?) { strip.press(.in) }
	@objc public func zoomOut(_ sender: Any?) { strip.press(.out) }
	@objc public func zoomFit(_ sender: Any?) { strip.press(.whole) }

	/// Framing the selected overlay, which is this window's answer to "zoom to
	/// the clip".
	@objc public func zoomToClipAction(_ sender: Any?) { strip.frameSelection() }

	/// For the tests: the strip whose keys keep being reported as not working.
	var stripForTesting: ProgrammeStrip { strip }

	/// Every key this window answers, in one function.
	///
	/// A function rather than the body of the monitor closure, because a
	/// closure installed on a window cannot be tested — and the keys on this
	/// window have now been reported not working three times, each time for a
	/// reason no unit test could see: the key never reached the code that
	/// answers it. A test can call this.
	func handle(_ event: NSEvent) -> Bool {
		if window?.firstResponder is NSTextView { return false }
		// The Play page's timeline, asked before anything else takes its keys.
		// It used to answer only its own `keyDown`, which meant it was asked
		// only while it held the focus — and when it did not, the key fell
		// through the responder chain and beeped. Nothing is claimed here that
		// the strip does not answer, so every other key carries on.
		if !strip.isHidden, strip.handleKey(event) { return true }
		// A list has its own use for the arrows and the space bar: moving the
		// selection, folding a section, acting on a row. The window's own
		// shortcuts are for when nothing is being navigated — otherwise this
		// eats the keys on their way to the list and the keyboard silently does
		// nothing there.
		if window?.firstResponder is NSTableView { return false }
		if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) {
			return false
		}
		switch event.keyCode {
		case 49: togglePlay(nil); return true                       // space
		case 123: seek(to: playhead - frameStep); return true
		case 124: seek(to: playhead + frameStep); return true
		case 115: seek(to: 0); return true                          // home
		case 119: seek(to: composeDocument.resolved?.duration ?? 0); return true
		default: return false
		}
	}

	/// Rebuilds the composition and the overlays from the project.
	private func rebuild() {
		titleChanged()
		findRepository()
		bar?.setName(composeDocument.displayName)
		bar?.setBranch(repositoryRoot.flatMap { GitRepository.branch(in: $0) })
		inspector.resolved = composeDocument.resolved
		let vocabulary = composeDocument.vocabulary
		materialTree.reload(vocabulary, takes: composeDocument.takes,
		                    folders: composeDocument.project.folders)

		// So the file can say which of its names point at nothing.
		source.vocabulary = vocabulary
		inspector.reload(composeDocument.project, vocabulary: vocabulary)
		if mode == .project { reloadProjectPage() }
		if mode == .text { source.show(sourceText) }
		strip.resolved = composeDocument.resolved
		strip.restoreZoom(stripZoom)
		markers.markers = (composeDocument.resolved?.anchors ?? []).compactMap { entry in
			entry.path.map { (entry.anchor.name, $0) }
		}
		markers.videoSize = composeDocument.resolved?.project.output.size ?? .zero
		strip.emptyMessage = composeDocument.project.timeline.isEmpty
			? "Nothing on the timeline yet. Add clips by slug in \(composeDocument.displayName).cuttrproj."
			: nil
		// An empty project is a state, not a fault, so it is not printed in red
		// under the picture as though something had gone wrong.
		//
		// Warnings are not faults either: a section made and not yet filled, a
		// caption hung on one before there is anything under it. They are said
		// in the same place and in a colour that is not an alarm, because the
		// programme they describe is playing perfectly well beside them.
		let warnings = composeDocument.resolved?.warnings ?? []
		if let problem = composeDocument.problem, !composeDocument.project.timeline.isEmpty {
			problemLabel.stringValue = problem
			problemLabel.textColor = NSColor(calibratedRed: 0.95, green: 0.5, blue: 0.5, alpha: 1)
		} else if !warnings.isEmpty {
			problemLabel.stringValue = Self.line(from: warnings)
			problemLabel.textColor = Theme.dimText
		} else {
			problemLabel.stringValue = ""
		}
		renderButton.isEnabled = composeDocument.resolved != nil

		guard let resolved = composeDocument.resolved else { return }
		buildTask?.cancel()
		let resumeAt = playhead
		buildTask = Task { [weak self] in
			let built: Renderer.Built
			do {
				built = try await Renderer.build(resolved, host: .preview)
			} catch {
				// Swallowed with `try?` before, which is how a preview comes to
				// be black for a reason nobody can see.
				await MainActor.run { self?.say("preview: \(error.localizedDescription)") }
				return
			}
			guard !Task.isCancelled, let self else { return }
			// The compositor holds what it was told for as long as something is
			// playing it; the build before this one is finished with.
			Renderer.forget(self.builtSession)
			self.builtSession = built.session
			self.builtComposition = built.composition
			self.builtVideoComposition = built.videoComposition
			self.builtAudioMix = built.audioMix
			self.builtDuration = resolved.duration
			// The panels can have their frames now.
			//
			// Everything above this line ran before the build started, and the
			// panels ask for their pictures up there: opening a project reloads
			// them synchronously and the composition a frame is cut out of does
			// not exist until here. Whoever asked and was told `nil` gets no
			// second chance of their own — a form is rebuilt when the selection
			// or the project changes, and a build finishing is neither — so the
			// window says. Without this the project page came up with an empty
			// picture in its head and kept it until some unrelated edit happened
			// to rebuild the form.
			self.inspector.framesCanBeHad()
			self.projectPanel.framesCanBeHad()
			self.transport.present(built.composition,
			                       videoComposition: built.videoComposition,
			                       audioMix: built.audioMix,
			                       duration: resolved.duration)
			// A preview that fails says so. Silently showing black is the worst
			// outcome: it looks like a project that renders nothing, and the
			// reason is sitting in `item.error` where nobody looks.
			if let item = self.transport.player.currentItem {
				self.itemStatus = item.observe(\.status, options: [.new]) { item, _ in
					guard item.status == .failed else { return }
					let message = item.error?.localizedDescription ?? "unknown"
					Task { @MainActor in self.say("preview failed: \(message)") }
				}
			}

			self.overlayLayer?.removeFromSuperlayer()
			let overlays = built.overlays
			// Held still. Everything in it is an animation with an absolute
			// begin time, so a tree at `speed = 0` shows whatever moment
			// `timeOffset` names — which is how the preview can be scrubbed
			// frame by frame through a slide.
			overlays.speed = 0
			overlays.timeOffset = resumeAt
			self.overlayLayer = overlays
			self.attachOverlays()
			self.seek(to: resumeAt)
		}
	}

	/// A still, with its numbers left alone.
	///
	/// The generator hands back a frame tagged `CoreMedia709`, which is honest
	/// about what the footage is — and then AppKit does what a colour tag asks
	/// for and converts it to the screen's space. Measured on a flat grey: the
	/// file says 125, the panel drew 136. Eleven levels, which is exactly the
	/// "washed out" this program has already chased through the renderer twice.
	///
	/// So the tag is changed, not the pixels. `copy(colorSpace:)` re-labels the
	/// same bytes as sRGB, nothing is converted on the way to the screen, and
	/// the still shows what the footage holds — which is the rule everywhere
	/// else in here, and what the player beside it is showing.
	static func asShown(_ image: CGImage) -> CGImage {
		guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
		      let retagged = image.copy(colorSpace: sRGB)
		else { return image }
		return retagged
	}

	/// Puts the overlay tree over the picture, whenever there is a picture to
	/// put it over.
	///
	/// Not only when it is built. A tab view keeps just the selected item's view
	/// in the window, so a tree built while the editor was showing had nowhere
	/// to go — `playerView.layer` did not exist yet — and the preview played
	/// with no captions and no spinners on it until something happened to
	/// rebuild the project. Attaching is idempotent and cheap, so it is done
	/// whenever the preview comes to the front as well.
	private func attachOverlays() {
		guard let overlayLayer, let host = overlayHost.layer else { return }
		if overlayLayer.superlayer !== host {
			overlayLayer.removeFromSuperlayer()
			host.addSublayer(overlayLayer)
		}
		layoutOverlays()
	}

	/// Keeps the overlay tree exactly over the picture.
	///
	/// The tree is built at the output's pixel size and the player draws the
	/// video aspect-fitted into whatever the window is, so the overlays are
	/// scaled and positioned to match that rectangle rather than the view. Any
	/// other arrangement puts a lower third in a different place on screen than
	/// it will be in the file.
	private func layoutOverlays() {
		guard let overlayLayer, let resolved = composeDocument.resolved else { return }
		let output = resolved.project.output.size
		guard output.width > 0, output.height > 0 else { return }
		let bounds = overlayHost.bounds
		let scale = min(bounds.width / output.width, bounds.height / output.height)
		let size = CGSize(width: output.width * scale, height: output.height * scale)
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		overlayLayer.bounds = CGRect(origin: .zero, size: output)
		overlayLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
		overlayLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
		overlayLayer.transform = CATransform3DMakeScale(scale, scale, 1)
		_ = size
		CATransaction.commit()
	}

	/// What the project page shows: the output, headed by the project's name.
	///
	/// Nothing new is written. `output:` is where every one of these already
	/// lived; this is a way of reaching it that does not require knowing that
	/// deselecting the tree is how you select the project.
	private func reloadProjectPage() {
		projectPanel.documentName = composeDocument.displayName
		projectPanel.resolved = composeDocument.resolved
		projectPanel.poster = { [weak self] time, done in
			guard let self else { return done(nil) }
			self.poster(at: time, then: done)
		}
		projectPanel.reload(composeDocument.project,
		                    vocabulary: composeDocument.vocabulary, selection: .output)
	}

	/// The project's own page: the output form, in a column rather than smeared
	/// across a window that may be eighteen hundred points wide.
	///
	/// A form is read down its left edge, and a key column with two feet of
	/// empty space after it is a form nobody can follow from one row to the
	/// next. The width is a preference and the ceiling is the page, so it gives
	/// way on a narrow window instead of demanding room that is not there.
	private func projectPage() -> NSView {
		let page = NSView(frame: .roomToLayOutIn)
		page.wantsLayer = true
		page.layer?.backgroundColor = Theme.panel.cgColor
		projectPanel.translatesAutoresizingMaskIntoConstraints = false
		page.addSubview(projectPanel)
		let wide = projectPanel.widthAnchor.constraint(equalToConstant: 560)
		wide.priority = NSLayoutConstraint.Priority(250)
		wide.isActive = true
		NSLayoutConstraint.activate([
			projectPanel.topAnchor.constraint(equalTo: page.topAnchor),
			projectPanel.bottomAnchor.constraint(equalTo: page.bottomAnchor),
			projectPanel.centerXAnchor.constraint(equalTo: page.centerXAnchor),
			projectPanel.widthAnchor.constraint(lessThanOrEqualTo: page.widthAnchor),
		])
		return page
	}

	/// Switches which of the four has the window.
	public func show(_ mode: Mode) {
		self.mode = mode
		anchorsFollowTheMode()
		modes.selectTabViewItem(at: mode.rawValue)
		rail.select(mode.rawValue)
		if mode == .preview {
			// Now that the picture is in the window it has a layer to sit on.
			attachOverlays()
			Task { @MainActor [weak self] in self?.attachOverlays() }
		}
		if mode == .text { source.show(sourceText) }
		if mode == .project { reloadProjectPage() }
		if mode == .levels { levels.reload(from: composeDocument) }
		// Nothing plays behind a view that is not the picture: a project window
		// left on the editor should not keep decoding.
		if mode != .preview { transport.pause() }
		// The levels page has a player of its own, for one take at a time.
		// Leaving the page stops it and writes whatever level was half-set.
		if mode != .levels { levels.stop() }
	}

	/// Play, from wherever somebody happens to be.
	///
	/// The picture is only in the window on the preview page — a tab view keeps
	/// just the selected item's view — so pressing play on the editor started
	/// the transport with nowhere to draw, and what came out was the sound of a
	/// programme nobody could see. Play means "show me this", so it shows it.
	private func playPressed() {
		if mode != .preview { show(.preview) }
		togglePlay(nil)
	}

	@objc public func showProject(_ sender: Any?) { show(.project) }
	@objc public func showEditor(_ sender: Any?) { show(.edit) }
	@objc public func showText(_ sender: Any?) { show(.text) }
	@objc public func showPreview(_ sender: Any?) { show(.preview) }
	@objc public func showLevels(_ sender: Any?) { show(.levels) }

	/// The picture, and nothing else.
	///
	/// Not the window's own full screen, which would show the bar and the
	/// programme strip at the size of a wall. Watching is a different job from
	/// editing: the furniture goes, the picture takes the screen, and escape or
	/// the same key brings it back.
	/// A pane is the size its divider was dragged to.
	///
	/// Taken during the drag: these panes are laid out by constraints, so the
	/// frames a split view sets are put back on the next pass and reading them
	/// afterwards reads the old size. The position under the pointer is what
	/// somebody is asking for, and it goes straight into the constraint that
	/// decides.
	public func splitView(_ splitView: NSSplitView, constrainSplitPosition proposedPosition: CGFloat,
	                      ofSubviewAt dividerIndex: Int) -> CGFloat {
		let panes = splitView.arrangedSubviews
		guard dividerIndex + 1 < panes.count else { return proposedPosition }
		let before = panes[dividerIndex], after = panes[dividerIndex + 1]
		let total = splitView.isVertical ? splitView.frame.width : splitView.frame.height
		for (view, size, _) in dragged {
			if view === before {
				size.constant = proposedPosition
			} else if view === after {
				// The pane on the far side of the divider: what is left of the
				// split once the first one and the divider have had their share.
				size.constant = max(0, total - proposedPosition - splitView.dividerThickness)
			}
		}
		return proposedPosition
	}

	@objc public func toggleFullScreenPreview(_ sender: Any?) {
		guard let window else { return }
		presenting.toggle()
		if presenting { show(.preview) }
		anchorsFollowTheMode()
		place?.setBarHidden(presenting)
		rail.isHidden = presenting
		strip.isHidden = presenting
		pictureControls.isHidden = presenting
		window.toggleFullScreen(nil)
		if presenting { watchThePointer() } else { stopWatchingThePointer() }
	}

	/// The controls come back when the mouse moves, and go away when it stops.
	///
	/// A local monitor rather than a tracking area: full screen has one view
	/// worth pointing at and the whole screen to move in, and a tracking area
	/// on a view that is itself invisible half the time is a way of missing
	/// the movement that was meant to bring it back.
	private func watchThePointer() {
		controls.playhead = playhead
		controls.duration = composeDocument.resolved?.duration ?? 0
		controls.isPlaying = transport.isPlaying
		controls.wake()
		pointerWatch = NSEvent.addLocalMonitorForEvents(
			matching: [.mouseMoved, .leftMouseDragged]
		) { [weak self] event in
			self?.controls.wake()
			return event
		}
		window?.acceptsMouseMovedEvents = true
	}

	private func stopWatchingThePointer() {
		if let pointerWatch { NSEvent.removeMonitor(pointerWatch) }
		pointerWatch = nil
		controls.sleep()
		window?.acceptsMouseMovedEvents = false
	}

	override func placeDidExitFullScreen() {
		guard presenting else { return }
		presenting = false
		anchorsFollowTheMode()
		stopWatchingThePointer()
		place?.setBarHidden(false)
		rail.isHidden = false
		strip.isHidden = false
		pictureControls.isHidden = false
	}

	/// The file as it stands, for the text view.
	private var sourceText: String {
		if let url = composeDocument.url, let text = try? String(contentsOf: url, encoding: .utf8) {
			return text
		}
		return ProjectWriter.write(composeDocument.project)
	}

	override func placeDidResize() {
		layoutOverlays()
	}

	/// One frame of the *output*, which is what a project's timeline is in.
	private var frameStep: Double {
		1 / max(composeDocument.project.output.framesPerSecond, 1)
	}

	private func seek(to time: Double) {
		playhead = max(0, time)
		bar?.setClock(playhead)
		strip.playhead = playhead
		markers.playhead = playhead
		overlayLayer?.timeOffset = playhead
		transport.seek(to: playhead)
	}

	// MARK: - Anchors

	/// The picture's rectangle inside the player view, which is not the view:
	/// the video is aspect-fitted, so most of the time there are bars. The
	/// markers are placed against this, not against the view.
	private var pictureRect: NSRect { markers.picture }

	// MARK: - Takes

	/// Puts an existing take into the project.
	/// Brings a scene in from another project.
	///
	/// Scenes live inside a project file rather than in files of their own, so
	/// "add one" means copying a definition out of somebody else's — which is
	/// exactly what a template is for: an intro built once and used in every
	/// episode. The name is kept unless this project already has one, because
	/// the name is what an overlay points at.
	private func addScene() {
		let panel = NSOpenPanel()
		panel.allowedContentTypes = [UTType(filenameExtension: "cuttrproj") ?? .plainText]
		panel.message = "Choose the project to take a scene from"
		guard panel.runModal() == .OK, let url = panel.url,
		      let text = try? String(contentsOf: url, encoding: .utf8),
		      let other = try? ProjectReader.read(text)
		else { return }
		guard !other.scenes.isEmpty else {
			let alert = NSAlert()
			alert.messageText = "No scenes in \(url.lastPathComponent)"
			alert.informativeText = "A scene lives under `scenes:` in a project file."
			alert.runModal()
			return
		}

		// One is taken without asking; several are a question, and a popup in
		// an alert is the smallest thing that asks it.
		var chosen = other.scenes.keys.sorted().first ?? ""
		if other.scenes.count > 1 {
			let alert = NSAlert()
			alert.messageText = "Which scene?"
			alert.informativeText = "\(url.lastPathComponent) has \(other.scenes.count) of them."
			let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
			popup.addItems(withTitles: other.scenes.keys.sorted())
			alert.accessoryView = popup
			alert.addButton(withTitle: "Add")
			alert.addButton(withTitle: "Cancel")
			guard alert.runModal() == .alertFirstButtonReturn else { return }
			chosen = popup.titleOfSelectedItem ?? chosen
		}
		guard let scene = other.scenes[chosen] else { return }

		var next = composeDocument.project
		var name = chosen
		var suffix = 2
		while next.scenes[name] != nil {
			name = "\(chosen)-\(suffix)"
			suffix += 1
		}
		next.scenes[name] = scene
		composeDocument.apply(next)
		onEditScene?(composeDocument, name)
	}

	@objc public func addTake(_ sender: Any?) {
		guard ensureSaved() else { return }
		let panel = NSOpenPanel()
		panel.allowedContentTypes = [UTType(filenameExtension: "cuttr") ?? .plainText]
		panel.allowsMultipleSelection = true
		panel.message = "Choose the takes this programme is made from"
		guard panel.runModal() == .OK else { return }
		let added = panel.urls.filter { composeDocument.addTake($0) }.count
		say(added == 0 ? "already in this project" : "added \(added)")
	}

	/// Cuts a new take from a recording, and adds it.
	///
	/// The take file is written before the window opens, beside the project in
	/// `takes/`, so the project can point at it straight away — an untitled take
	/// has nowhere to be referenced from.
	@objc public func newTake(_ sender: Any?) {
		guard ensureSaved() else { return }
		let panel = NSOpenPanel()
		panel.allowedContentTypes = [.movie, .video, .audio]
		panel.allowsMultipleSelection = true
		panel.message = "Choose the recording to cut"
		guard panel.runModal() == .OK, let first = panel.urls.first else { return }

		var video: URL?
		var audio: URL?
		for url in panel.urls {
			guard let type = UTType(filenameExtension: url.pathExtension) else { continue }
			if type.conforms(to: .movie) || type.conforms(to: .video) { video = video ?? url }
			else if type.conforms(to: .audio) { audio = audio ?? url }
		}
		guard let place = composeDocument.placeForNewTake(
			named: (video ?? first).deletingPathExtension().lastPathComponent) else { return }

		let document = TakeDocument()
		document.setMedia(video: video, audio: audio)
		do {
			try document.write(to: place)
		} catch {
			report(error)
			return
		}
		composeDocument.addTake(place)
		say("added \(place.lastPathComponent) — open it to cut it")
		onOpenTake?(place, false)
	}

	// MARK: - Saving

	/// ⌘S. A project edited in this window is written as it is changed, so this
	/// is mostly for the one that has never been saved — but it is what
	/// somebody's hands do, and a window where it does nothing is a window
	/// somebody does not trust.
	@objc public func save(_ sender: Any?) {
		guard composeDocument.url != nil else { saveAs(sender); return }
		do {
			try composeDocument.write()
			say("saved \(composeDocument.displayName)")
		} catch {
			report(error)
		}
	}

	/// ⌘S over everything, arriving at this project.
	///
	/// Usually nothing to do, and that is the point: this window writes the
	/// project as it is edited, so by the time somebody saves there is normally
	/// no difference to write. Rewriting it anyway would be a version in
	/// `refs/cuttr/saves` that records no decision.
	func saveQuietly() -> DocumentSave {
		guard composeDocument.isDirty else { return .unchanged }
		guard composeDocument.url != nil else { return .untitled(composeDocument.displayName) }
		do {
			try composeDocument.write()
			say("saved \(composeDocument.displayName)")
			return .saved(composeDocument.displayName)
		} catch {
			say("could not save \(composeDocument.displayName)")
			return .failed(name: composeDocument.displayName,
			               reason: error.localizedDescription)
		}
	}

	/// What the application has to say, in the bar this document shares with the
	/// others in its window.
	func announce(_ text: String) { say(text) }

	/// ⇧⌘S. Somewhere else, with every path in the project rewritten to find
	/// the same media from there.
	@objc public func saveAs(_ sender: Any?) {
		let panel = NSSavePanel()
		panel.allowedContentTypes = [UTType(filenameExtension: "cuttrproj") ?? .plainText]
		panel.nameFieldStringValue = composeDocument.url?.lastPathComponent ?? "programme.cuttrproj"
		if let directory = composeDocument.url?.deletingLastPathComponent() {
			panel.directoryURL = directory
		}
		guard panel.runModal() == .OK, let url = panel.url else { return }
		do {
			try composeDocument.saveAs(url)
			AppDelegate.remember(url)
			say("saved \(url.lastPathComponent)")
			rebuild()
		} catch {
			report(error)
		}
	}

	/// The versions kept while somebody worked, and the way back to one.
	///
	/// Whatever is owed goes in first, so the list opens with the state on
	/// screen already in it — a versions list that does not contain what you are
	/// looking at is a list you cannot reason about.
	@objc public func showVersions(_ sender: Any?) {
		guard let url = composeDocument.url, let view = window?.contentView else { return }
		let repository = ProjectVersions(project: url)
		composeDocument.keepAVersion()
		let shown = VersionsSheet.present(over: view, versions: composeDocument.versions()) {
			[weak self] commit in
			guard let self else { return .noRepository }
			// Refused rather than half-done, exactly as a checkout is: an open
			// take window would write its stale cuts back over what was just
			// restored.
			if let root = repository?.root, let waiting = ProjectVersions.inTheWay(of: root) {
				return .failed(waiting)
			}
			let outcome = self.composeDocument.restore(commit)
			if case .kept(let version) = outcome {
				self.say("went back to \(version.short) — \(version.title)")
				self.rebuild()
			}
			return outcome
		}
		guard !shown else { return }
		// Nothing to show, and the reason is worth one line: a project on a
		// footage volume is not in a work tree and never will have versions.
		say(repository == nil
			? "no versions — this project is not in a git repository"
			: "no versions kept yet")
	}

	// MARK: - Sharing

	/// Send what is here and bring back what everybody else did.
	///
	/// A version is kept first, so that whatever the share turns out to do, the
	/// state before it is on `refs/cuttr/saves` and one keystroke away. Then the
	/// two refusals every other write into this repository already makes — a
	/// merge or rebase in progress, and an open take window whose in-memory cuts
	/// would land back on top of what just arrived.
	///
	/// The work happens off the main thread. It fetches and pushes, and a window
	/// that waited here for a remote would beachball for as long as the remote
	/// took — which on a train is for ever.
	@objc public func shareProject(_ sender: Any?) {
		guard let url = composeDocument.url else {
			say("save the project somewhere before sharing it")
			return
		}
		guard let sharing = ProjectSharing(project: url) else {
			say(ProjectSharing.Outcome.noRepository.sentence)
			return
		}
		// Asked here, on the main actor, because which take windows are open is
		// a question only the main actor can answer.
		if let waiting = ProjectVersions.inTheWay(of: sharing.root) {
			say(waiting)
			return
		}
		composeDocument.keepAVersion()
		say("sharing…")
		Task.detached { [weak self] in
			let (outcome, choose) = sharing.share()
			await MainActor.run { self?.shared(outcome, choose, with: sharing) }
		}
	}

	// MARK: - Saying where the project stands

	/// The button that says there is something to send, or something to bring
	/// in, and is the way to do either.
	///
	/// **Why a button and not a line of status.** Everything a share did, it
	/// said once in the status bar and then the line was gone. There was no way
	/// to tell "I have three changes nobody else has" from "the button did
	/// nothing", which is how the button came to be reported as doing nothing.
	/// This one is on screen for as long as there is something to do.
	private let shareButton = NSButton()
	private var standing: ProjectSharing.Standing?
	private var standingWatch: Timer?

	/// Asks the repository where things stand, off the main thread.
	///
	/// **Never fetches.** Asking a network how things stand is not something a
	/// window may do on a timer — that is a password prompt, or a stall, every
	/// half minute for as long as the program is open. What it reads is what is
	/// already on this machine: the project's own uncommitted files, and how
	/// far the branch is from the upstream as last fetched. A share fetches,
	/// and a share is something somebody asked for.
	@objc func refreshStanding() {
		guard let url = composeDocument.url, let sharing = ProjectSharing(project: url) else {
			standing = nil
			showStanding()
			return
		}
		Task.detached { [weak self] in
			let found = sharing.standing()
			await MainActor.run {
				self?.standing = found
				self?.showStanding()
			}
		}
	}

	private func showStanding() {
		guard let standing, standing.hasRemote, !standing.isSettled else {
			shareButton.isHidden = true
			bar?.groupChanged()
			return
		}
		shareButton.isHidden = false
		// What to say first. Bringing somebody else's work in comes before
		// sending yours: a push on top of work you have not seen is the thing
		// this whole feature exists to avoid.
		if standing.toMerge > 0 {
			let what = standing.toMerge == 1 ? "1 change" : "\(standing.toMerge) changes"
			shareButton.title = "Merge \(what)"
			shareButton.toolTip = "Somebody else has \(what) you have not got"
		} else {
			let count = standing.toUpload + (standing.uncommitted > 0 ? 1 : 0)
			let what = count == 1 ? "1 change" : "\(count) changes"
			shareButton.title = "Upload \(what)"
			shareButton.toolTip = standing.uncommitted > 0
				? "\(standing.uncommitted) file\(standing.uncommitted == 1 ? "" : "s") "
					+ "changed since the last share"
				: "\(what) nobody else has yet"
		}
		bar?.groupChanged()
	}

	/// What came back, and the one case that needs somebody.
	@MainActor
	private func shared(_ outcome: ProjectSharing.Outcome,
	                    _ choose: ProjectSharing.MustChoose?,
	                    with sharing: ProjectSharing) {
		// Whatever happened, the files on disk may have moved under the window.
		if case .brought = outcome {
			composeDocument.reload()
			rebuild()
		}
		refreshStanding()
		guard case .mustChoose = outcome, let choose, let view = window?.contentView else {
			say(outcome.sentence)
			// A refusal is a thing somebody has to act on — close a take
			// window, sign in, finish a rebase — and a line of status that is
			// gone by the time they look is how "it refused" became "nothing
			// happens". Success stays quiet: the button going away says it.
			if outcome.needsAnswering { insist(outcome.sentence) }
			mentionMissingFootage(sharing)
			return
		}
		let shown = ConflictSheet.present(over: view, rows: ConflictSheet.rows(for: choose)) {
			[weak self] choices in
			self?.say("finishing…")
			Task.detached {
				let outcome = sharing.finish(choosing: choices)
				await MainActor.run {
					self?.composeDocument.reload()
					self?.rebuild()
					self?.say(outcome.sentence)
					self?.refreshStanding()
					self?.mentionMissingFootage(sharing)
				}
			}
		}
		if !shown { say(outcome.sentence) }
	}

	/// Said in a way somebody cannot walk past.
	///
	/// Only for the outcomes that need them to do something. An alert for
	/// "sent your changes" would be a program congratulating itself.
	@MainActor
	private func insist(_ what: String) {
		let alert = NSAlert()
		alert.messageText = "Not shared"
		alert.informativeText = what
		alert.addButton(withTitle: "OK")
		// Only over a real window. Conjuring one to hang a sheet on is how a
		// window with no sheet parent aborts the process, which is what it did
		// the first time this ran in a test — and a window nobody can see is
		// not a place to put something somebody has to answer anyway.
		guard let window else { return }
		alert.beginSheetModal(for: window) { _ in }
	}

	/// Sharing moves text. The recordings are gigabytes and are not in the
	/// repository, so a take can arrive naming a file this machine has not got —
	/// and a project that opens to black with no explanation is the worst way to
	/// find that out.
	@MainActor
	private func mentionMissingFootage(_ sharing: ProjectSharing) {
		let missing = sharing.missingFootage()
		guard !missing.isEmpty else { return }
		let named = missing.prefix(3).joined(separator: ", ")
		let more = missing.count > 3 ? " and \(missing.count - 3) more" : ""
		say("\(named)\(more) " + (missing.count == 1 ? "is" : "are")
			+ " not on this machine — the footage is not shared, only the cut")
	}

	/// A project must be on disk before it can point at anything: every path in
	/// it is relative to where it sits.
	private func ensureSaved() -> Bool {
		if composeDocument.url != nil { return true }
		let panel = NSSavePanel()
		panel.allowedContentTypes = [UTType(filenameExtension: "cuttrproj") ?? .plainText]
		panel.nameFieldStringValue = "programme.cuttrproj"
		panel.message = "Save the project first — takes are named relative to it."
		guard panel.runModal() == .OK, let url = panel.url else { return false }
		do {
			try composeDocument.saveAs(url)
			AppDelegate.remember(url)
			return true
		} catch {
			report(error)
			return false
		}
	}

	private func report(_ error: Error) {
		guard let window else { return }
		NSAlert(error: error).beginSheetModal(for: window)
	}

	/// Copies the project and everything it depends on into one folder.
	@objc public func exportProject(_ sender: Any?) {
		guard ensureSaved(), let baseURL = composeDocument.baseURL else { return }
		let panel = NSOpenPanel()
		panel.canChooseDirectories = true
		panel.canChooseFiles = false
		panel.canCreateDirectories = true
		panel.prompt = "Export"
		panel.message = "Choose a new, empty folder. Everything the project uses is copied into it."
		guard panel.runModal() == .OK, let target = panel.url else { return }

		let project = composeDocument.project
		let name = composeDocument.displayName
		showProgress(0)
		say("exporting…")
		Task { [weak self] in
			// Off the main thread: on a real shoot this is gigabytes of copying.
			let outcome = await Task.detached(priority: .userInitiated) { () -> Result<ProjectExporter.Report, Error> in
				do { return .success(try ProjectExporter.export(project, named: name, from: baseURL, to: target)) }
				catch { return .failure(error) }
			}.value
			guard let self else { return }
			self.showProgress(nil)
			switch outcome {
			case .success(let report):
				self.say("exported to \(target.lastPathComponent) — \(report.summary)")
				// Missing files are worth a sheet rather than a status line:
				// the folder is complete apart from them, and somebody has to
				// know which before they hand it over.
				if !report.missing.isEmpty {
					let alert = NSAlert()
					alert.messageText = "Exported, but \(report.missing.count) files were not found"
					alert.informativeText = report.missing.prefix(12).joined(separator: "\n")
						+ (report.missing.count > 12 ? "\n…" : "")
					alert.addButton(withTitle: "Show Folder")
					alert.addButton(withTitle: "OK")
					if alert.runModal() == .alertFirstButtonReturn {
						NSWorkspace.shared.activateFileViewerSelecting([target])
					}
				} else {
					NSWorkspace.shared.activateFileViewerSelecting([target])
				}
			case .failure(let error):
				self.say(error.localizedDescription)
				self.report(error)
			}
		}
	}

	// MARK: - Rendering

	@objc public func render(_ sender: Any?) {
		guard let resolved = composeDocument.resolved else { return }
		let panel = NSSavePanel()
		panel.allowedContentTypes = [.quickTimeMovie]
		panel.nameFieldStringValue = composeDocument.project.output.file
			?? (composeDocument.displayName + ".mov")
		if let base = composeDocument.baseURL { panel.directoryURL = base }
		guard panel.runModal() == .OK, let url = panel.url else { return }

		showProgress(0)
		renderButton.isEnabled = false
		say("rendering…")
		Task { [weak self] in
			do {
				// Components first. This is the one place in the window that
				// bakes: a render must not use frames that are no longer what
				// the project asks for, and nothing else may take seconds.
				if let baking = try await self?.composeDocument.bakeComponents(),
				   !baking.baked.isEmpty {
					self?.say("components: \(baking.summary)")
				}
				// And the programme as it is now, which after a bake is not the
				// one the render button was pressed against.
				let programme = self?.composeDocument.resolved ?? resolved
				try await Renderer.export(programme, to: url) { fraction in
					Task { @MainActor in self?.showProgress(fraction) }
				}
				self?.say("wrote \(url.lastPathComponent)")
			} catch {
				self?.say(error.localizedDescription)
				self?.report(error)
			}
			self?.showProgress(nil)
			self?.renderButton.isEnabled = true
		}
	}

	@objc public func reloadProject(_ sender: Any?) { composeDocument.reload() }

	/// Opens the scene editor on this project.
	///
	/// On a scene of it when one is chosen in the library; otherwise on the
	/// first it has, and on an empty editor offering to make one when it has
	/// none. The scene window edits `scenes:` and hands the project back — the
	/// document here still owns the file.
	@objc public func editScene(_ sender: Any?) {
		onEditScene?(composeDocument, nil)
	}

	@objc public func togglePlay(_ sender: Any?) { transport.togglePlay() }

	public func validateMenuItem(_ item: NSMenuItem) -> Bool {
		if let undo = validateUndo(item) { return undo }
		switch item.action {
		case #selector(render(_:)): return composeDocument.resolved != nil
		case #selector(exportProject(_:)): return !composeDocument.project.takes.isEmpty
		case #selector(editScene(_:)): return onEditScene != nil
		// A project with no file has nowhere to keep versions and no repository
		// to keep them in.
		case #selector(showVersions(_:)): return composeDocument.url != nil
		default: return true
		}
	}

	override func documentClosed() {
		if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
		keyMonitor = nil
		buildTask?.cancel()
		transport.pause()
		// A level dragged and not let go of is still a level somebody set, and
		// this is the last moment there is to write it.
		levels.stop()
		// The last edit of the session is the one somebody most wants back, and
		// the quiet after it is the quiet in which the window was closed. On
		// this thread rather than off it: there is no later moment to finish in.
		composeDocument.keepAVersion()
	}

	/// One line, whatever happened.
	///
	/// A status line is a line: it says the first thing and how many others
	/// there are, and whoever wants the list opens the text or reads stderr.
	/// Joining them all was how a project with a dozen unfinished sections
	/// opened a window five screens wide — a label's intrinsic width is the
	/// width of its whole string however it is truncated, so the message was
	/// deciding the size of the window that was supposed to contain it.
	static func line(from warnings: [String], limit: Int = 120) -> String {
		guard let first = warnings.first else { return "" }
		let rest = warnings.count - 1
		let head = first.count <= limit ? first : String(first.prefix(limit - 1)) + "…"
		return rest > 0 ? "\(head)  · and \(rest) more" : head
	}

	/// For the tests: say something in the problem line without having to
	/// arrange a project that goes wrong in the right way.
	func setProblemForTesting(_ text: String) {
		problemLabel.stringValue = text
	}

}
