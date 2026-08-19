import AVFoundation
import AppKit
import CuttrCompose
import CuttrKit
import UniformTypeIdentifiers

/// The composing window: what the project comes to, played.
///
/// The preview is not an approximation of the render. It is the same
/// `AVComposition` the renderer builds and the same Core Animation tree the
/// renderer hands to the encoder — the only difference is that one is played and
/// the other is written. That is the point of ``OverlayLayers/Host``: a preview
/// that agrees with the export by construction rather than by care.
@MainActor
public final class ComposeWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {

	public let composeDocument: ComposeDocument
	/// The same transport the cutting window uses. One playback path in the
	/// program, not two.
	private let transport = Transport()
	private var playerView: PlayerView!
	private let strip = ProgrammeStrip()
	private let markers = AnchorMarkerView()
	private let overlayHost = NSView()
	private let takesTable = TakesTable()
	private let library = LibraryView()
	private let inspector = ProjectInspector()
	private let source = ProjectTextEditor()
	private let modes = NSTabView()

	/// Which of the three is showing.
	public enum Mode: Int { case edit, text, preview }
	private var mode: Mode = .edit
	/// Whether the window is showing the picture and nothing else.
	private var presenting = false

	/// Opening a take is the application's business, not this window's: it may
	/// already be open in another tab.
	public var onOpenTake: ((URL) -> Void)?
	/// Open a take *at* a moment: from a clip on the programme to the place it
	/// was cut from, which is the question somebody asks when a shot is wrong.
	public var onOpenTakeAt: ((URL, Double) -> Void)?
	/// Whether a take already has a tab of its own. Renaming one that is open
	/// would leave that tab writing to a file that no longer exists.
	public var isTakeOpen: ((URL) -> Bool)?
	/// Open a scene of this project in the scene editor. A scene is a window's
	/// worth of editing — parts, keyframes, a stage — and putting that inside
	/// one field of the properties panel is what this callback exists to avoid.
	/// `nil` means "whichever one, or a new one".
	public var onEditScene: ((ComposeDocument, String?) -> Void)?
	private let bar = ComposeBar()
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

	public init(document: ComposeDocument) {
		self.composeDocument = document
		let window = NSWindow(
			contentRect: NSRect(x: 0, y: 0, width: 1200, height: 820),
			styleMask: [.titled, .closable, .miniaturizable, .resizable],
			backing: .buffered, defer: false)
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
		document.onChange?()
		rebuild()
		window.center()
	}

	@available(*, unavailable) required init?(coder: NSCoder) { nil }

	// MARK: - Layout

	private func build() {
		guard let window else { return }
		playerView = PlayerView(player: transport.player)

		bar.onRender = { [weak self] in self?.render(nil) }
		bar.onReload = { [weak self] in self?.composeDocument.reload() }
		bar.onMode = { [weak self] index in self?.show(Mode(rawValue: index) ?? .edit) }
		bar.onFullScreen = { [weak self] in self?.toggleFullScreenPreview(nil) }
		bar.onAnchors = { [weak self] shown in
			// The markers are for placing an overlay against a face, and once it
			// is placed they are in the way of seeing the thing they placed.
			self?.markers.isHidden = !shown
		}

		source.onApply = { [weak self] text in
			guard let self, let url = self.composeDocument.url else { return }
			// Written straight out, then re-read: the file is what this program
			// believes, so applying means putting it there and letting the
			// document notice, exactly as an external editor would.
			try? text.write(to: url, atomically: true, encoding: .utf8)
			self.composeDocument.reload()
			self.bar.setStatus("applied")
		}

		problemLabel.font = Theme.monoSmall
		problemLabel.textColor = NSColor(calibratedRed: 0.95, green: 0.5, blue: 0.5, alpha: 1)
		problemLabel.lineBreakMode = .byTruncatingTail
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

		let split = NSSplitView()
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
		let material = NSSplitView()
		material.isVertical = false
		material.dividerStyle = .thin
		material.addArrangedSubview(takesTable)
		material.addArrangedSubview(library)

		let editing = NSSplitView()
		editing.isVertical = true
		editing.dividerStyle = .thin
		editing.addArrangedSubview(material)
		editing.addArrangedSubview(inspector)

		// A tab view with no tabs of its own: the segmented control in the bar
		// is the switch, because it sits with the other things this window can
		// do rather than starting a second row of furniture.
		modes.tabViewType = .noTabsNoBorder
		modes.drawsBackground = false
		for (identifier, view) in [("edit", editing), ("text", source), ("preview", split)] as [(String, NSView)] {
			let item = NSTabViewItem(identifier: identifier)
			item.view = view
			modes.addTabViewItem(item)
		}

		let content = DropView()
		content.onDrop = { [weak self] urls in
			guard let url = urls.first(where: { $0.pathExtension == "cuttrproj" }) else { return }
			try? self?.composeDocument.read(from: url)
		}
		content.wantsLayer = true
		content.layer?.backgroundColor = Theme.background.cgColor

		for view in [bar, problemLabel, modes] as [NSView] {
			view.translatesAutoresizingMaskIntoConstraints = false
			content.addSubview(view)
		}
		NSLayoutConstraint.activate([
			bar.topAnchor.constraint(equalTo: content.topAnchor),
			bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
			bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
			bar.heightAnchor.constraint(equalToConstant: 38),

			problemLabel.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 2),
			problemLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
			problemLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
			problemLabel.heightAnchor.constraint(equalToConstant: 14),

			modes.topAnchor.constraint(equalTo: problemLabel.bottomAnchor, constant: 2),
			modes.leadingAnchor.constraint(equalTo: content.leadingAnchor),
			modes.trailingAnchor.constraint(equalTo: content.trailingAnchor),
			modes.bottomAnchor.constraint(equalTo: content.bottomAnchor),
		])

		let preferred = NSLayoutConstraint.Priority(250)
		let wishes = [
			material.widthAnchor.constraint(equalToConstant: 260),
			takesTable.heightAnchor.constraint(equalToConstant: 180),
			strip.heightAnchor.constraint(equalToConstant: 200),
		]
		for wish in wishes { wish.priority = preferred; wish.isActive = true }
		NSLayoutConstraint.activate([
			material.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
			takesTable.heightAnchor.constraint(greaterThanOrEqualToConstant: 90),
			library.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
			strip.heightAnchor.constraint(greaterThanOrEqualToConstant: 90),
			playerView.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
		])

		window.contentView = content

		// No marking here: an anchor is marked on the take, in the cutting
		// window, where the footage is. This window shows what was found.
	}

	// MARK: - Wiring

	private func wire() {
		composeDocument.onChange = { [weak self] in self?.rebuild() }
		strip.onScrub = { [weak self] time in self?.seek(to: time) }

		// Double-click a clip on the programme to open the take it came from,
		// at the moment under the pointer — the programme's clock turned back
		// into the take's.
		strip.onOpenClip = { [weak self] clip, time in
			guard let self, let take = self.composeDocument.takes
				.first(where: { $0.name == clip.takeName })
			else { return }
			self.onOpenTakeAt?(take.url, clip.takeTime(forProgramme: time))
		}

		// Dragged on the big timeline, written back the way the file says it:
		// snapped to a clip, kept relative to one, or in programme times —
		// whichever that range was already using.
		strip.onMoveOverlay = { [weak self] source, appearance, start, end in
			guard let self, let resolved = self.composeDocument.resolved else { return }
			var next = self.composeDocument.project
			guard source < next.overlays.count,
			      appearance < next.overlays[source].appearances.count else { return }
			let span = next.overlays[source].appearances[appearance].span
			next.overlays[source].appearances[appearance].span =
				span.moved(start: start, end: end, in: resolved)
			self.composeDocument.apply(next)
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

		takesTable.onOpen = { [weak self] url in self?.onOpenTake?(url) }
		takesTable.onRemove = { [weak self] path in self?.composeDocument.removeTake(path) }
		takesTable.onAdd = { [weak self] in self?.addTake(nil) }
		takesTable.onRename = { [weak self] path, name in
			guard let self else { return }
			let url = URL(fileURLWithPath: path, relativeTo: self.composeDocument.baseURL)
			// Refused rather than half-done: the open tab holds the old URL and
			// would recreate the old file on its next save.
			if self.isTakeOpen?(url.standardizedFileURL) == true {
				self.bar.setStatus("close that take's tab before renaming it")
				self.rebuild()
				return
			}
			if let problem = self.composeDocument.renameTake(path, to: name) {
				self.bar.setStatus(problem)
				self.rebuild()
			}
		}
		takesTable.onNew = { [weak self] in self?.newTake(nil) }

		// A frame of the programme at a moment, for placing an overlay on. The
		// same composition the preview plays, so what is dragged over is what
		// will be rendered under.
		inspector.onScrub = { [weak self] time in self?.seek(to: time) }

		// The dialogs that set a moment against the programme play the same
		// thing the preview plays, rather than building a second one.
		inspector.playable = { [weak self] in
			guard let self, let composition = self.builtComposition else { return nil }
			return (composition, self.builtVideoComposition, self.builtAudioMix,
			        self.builtDuration)
		}
		inspector.poster = { [weak self] time, done in
			guard let self, let composition = self.builtComposition else { return done(nil) }
			let generator = AVAssetImageGenerator(asset: composition)
			generator.videoComposition = self.builtVideoComposition
			generator.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
			generator.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)
			generator.generateCGImageAsynchronously(
				for: CMTime(seconds: max(0, time), preferredTimescale: 600)
			) { image, _, _ in
				let picture = image.map { NSImage(cgImage: Self.asShown($0), size: .zero) }
				Task { @MainActor in done(picture) }
			}
		}
		library.onInsert = { [weak self] reference in self?.inspector.insert(reference: reference) }
		library.onEditScene = { [weak self] name in
			guard let self else { return }
			self.onEditScene?(self.composeDocument, name)
		}

		// The same arrangement as the cutting window, for the same reason: the
		// keys have to work wherever the focus happens to be.
		keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
			guard let self, event.window === self.window else { return event }
			if self.window?.firstResponder is NSTextView { return event }
			// A list has its own use for the arrows and the space bar: moving
			// the selection, folding a section, acting on a row. The window's
			// own shortcuts are for when nothing is being navigated — otherwise
			// this monitor eats the keys on their way to the list and the
			// keyboard silently does nothing there.
			if self.window?.firstResponder is NSTableView { return event }
			if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) { return event }
			switch event.keyCode {
			case 49: self.togglePlay(nil); return nil                       // space
			case 123: self.seek(to: self.playhead - self.frameStep); return nil
			case 124: self.seek(to: self.playhead + self.frameStep); return nil
			case 115: self.seek(to: 0); return nil                          // home
			case 119: self.seek(to: self.composeDocument.resolved?.duration ?? 0); return nil
			default: return event
			}
		}

		transport.onTick = { [weak self] time in
			guard let self else { return }
			self.playhead = time
			self.strip.playhead = time
			self.markers.playhead = time
			// The overlay tree is paused; this is what puts it at the same
			// moment as the picture, exactly, every tick.
			self.overlayLayer?.timeOffset = time
			self.bar.setStatus(Timecode.string(time))
		}
	}

	/// Rebuilds the composition and the overlays from the project.
	private func rebuild() {
		guard let window else { return }
		window.title = composeDocument.displayName
		window.representedURL = composeDocument.url
		takesTable.reload(composeDocument.takes)
		inspector.resolved = composeDocument.resolved
		let vocabulary = composeDocument.vocabulary
		library.reload(vocabulary)
		inspector.reload(composeDocument.project, vocabulary: vocabulary)
		if mode == .text { source.show(sourceText) }
		strip.resolved = composeDocument.resolved
		markers.markers = (composeDocument.resolved?.anchors ?? []).compactMap { entry in
			entry.path.map { (entry.anchor.name, $0) }
		}
		markers.videoSize = composeDocument.resolved?.project.output.size ?? .zero
		strip.emptyMessage = composeDocument.project.timeline.isEmpty
			? "Nothing on the timeline yet. Add clips by slug in \(composeDocument.displayName).cuttrproj."
			: nil
		// An empty project is a state, not a fault, so it is not printed in red
		// under the picture as though something had gone wrong.
		problemLabel.stringValue = composeDocument.project.timeline.isEmpty
			? "" : (composeDocument.problem ?? "")
		bar.setEnabled(composeDocument.resolved != nil)

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
				await MainActor.run { self?.bar.setStatus("preview: \(error.localizedDescription)") }
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
					Task { @MainActor in self.bar.setStatus("preview failed: \(message)") }
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

	/// Switches which of the three has the window.
	public func show(_ mode: Mode) {
		self.mode = mode
		modes.selectTabViewItem(at: mode.rawValue)
		bar.setMode(mode.rawValue)
		if mode == .preview {
			// Now that the picture is in the window it has a layer to sit on.
			attachOverlays()
			Task { @MainActor [weak self] in self?.attachOverlays() }
		}
		if mode == .text { source.show(sourceText) }
		// Nothing plays behind a view that is not the picture: a project window
		// left on the editor should not keep decoding.
		if mode != .preview { transport.pause() }
	}

	@objc public func showEditor(_ sender: Any?) { show(.edit) }
	@objc public func showText(_ sender: Any?) { show(.text) }
	@objc public func showPreview(_ sender: Any?) { show(.preview) }

	/// The picture, and nothing else.
	///
	/// Not the window's own full screen, which would show the bar and the
	/// programme strip at the size of a wall. Watching is a different job from
	/// editing: the furniture goes, the picture takes the screen, and escape or
	/// the same key brings it back.
	@objc public func toggleFullScreenPreview(_ sender: Any?) {
		guard let window else { return }
		presenting.toggle()
		if presenting { show(.preview) }
		bar.isHidden = presenting
		strip.isHidden = presenting
		window.toggleFullScreen(nil)
	}

	public func windowDidExitFullScreen(_ notification: Notification) {
		guard presenting else { return }
		presenting = false
		bar.isHidden = false
		strip.isHidden = false
	}

	/// The file as it stands, for the text view.
	private var sourceText: String {
		if let url = composeDocument.url, let text = try? String(contentsOf: url, encoding: .utf8) {
			return text
		}
		return ProjectWriter.write(composeDocument.project)
	}

	public func windowDidResize(_ notification: Notification) {
		layoutOverlays()
	}

	/// One frame of the *output*, which is what a project's timeline is in.
	private var frameStep: Double {
		1 / max(composeDocument.project.output.framesPerSecond, 1)
	}

	private func seek(to time: Double) {
		playhead = max(0, time)
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
	@objc public func addTake(_ sender: Any?) {
		guard ensureSaved() else { return }
		let panel = NSOpenPanel()
		panel.allowedContentTypes = [UTType(filenameExtension: "cuttr") ?? .plainText]
		panel.allowsMultipleSelection = true
		panel.message = "Choose the takes this programme is made from"
		guard panel.runModal() == .OK else { return }
		let added = panel.urls.filter { composeDocument.addTake($0) }.count
		bar.setStatus(added == 0 ? "already in this project" : "added \(added)")
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
		bar.setStatus("added \(place.lastPathComponent) — cut it in its own tab")
		onOpenTake?(place)
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
		bar.setProgress(0)
		bar.setStatus("exporting…")
		Task { [weak self] in
			// Off the main thread: on a real shoot this is gigabytes of copying.
			let outcome = await Task.detached(priority: .userInitiated) { () -> Result<ProjectExporter.Report, Error> in
				do { return .success(try ProjectExporter.export(project, named: name, from: baseURL, to: target)) }
				catch { return .failure(error) }
			}.value
			guard let self else { return }
			self.bar.setProgress(nil)
			switch outcome {
			case .success(let report):
				self.bar.setStatus("exported to \(target.lastPathComponent) — \(report.summary)")
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
				self.bar.setStatus(error.localizedDescription)
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

		bar.setProgress(0)
		bar.setRenderEnabled(false)
		bar.setStatus("rendering…")
		Task { [weak self] in
			do {
				try await Renderer.export(resolved, to: url) { fraction in
					Task { @MainActor in self?.bar.setProgress(fraction) }
				}
				self?.bar.setStatus("wrote \(url.lastPathComponent)")
			} catch {
				self?.bar.setStatus(error.localizedDescription)
			}
			self?.bar.setProgress(nil)
			self?.bar.setRenderEnabled(true)
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
		switch item.action {
		case #selector(render(_:)): return composeDocument.resolved != nil
		case #selector(exportProject(_:)): return !composeDocument.project.takes.isEmpty
		case #selector(editScene(_:)): return onEditScene != nil
		default: return true
		}
	}

	public func windowWillClose(_ notification: Notification) {
		if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
		keyMonitor = nil
		buildTask?.cancel()
		transport.pause()
	}
}
