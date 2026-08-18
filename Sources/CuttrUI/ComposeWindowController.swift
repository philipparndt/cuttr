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
	private let takesTable = TakesTable()

	/// Opening a take is the application's business, not this window's: it may
	/// already be open in another tab.
	public var onOpenTake: ((URL) -> Void)?
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
		let split = NSSplitView()
		split.isVertical = false
		split.dividerStyle = .thin
		split.addArrangedSubview(playerView)
		split.addArrangedSubview(strip)

		// The takes down the side. A project is a programme made of recordings,
		// and the recordings are the thing somebody reaches for next — to open
		// one, to cut another, to find out why one of them stopped resolving.
		let withTakes = NSSplitView()
		withTakes.isVertical = true
		withTakes.dividerStyle = .thin
		withTakes.addArrangedSubview(takesTable)
		withTakes.addArrangedSubview(split)

		let content = DropView()
		content.onDrop = { [weak self] urls in
			guard let url = urls.first(where: { $0.pathExtension == "cuttrproj" }) else { return }
			try? self?.composeDocument.read(from: url)
		}
		content.wantsLayer = true
		content.layer?.backgroundColor = Theme.background.cgColor

		for view in [bar, problemLabel, withTakes] as [NSView] {
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

			withTakes.topAnchor.constraint(equalTo: problemLabel.bottomAnchor, constant: 2),
			withTakes.leadingAnchor.constraint(equalTo: content.leadingAnchor),
			withTakes.trailingAnchor.constraint(equalTo: content.trailingAnchor),
			withTakes.bottomAnchor.constraint(equalTo: content.bottomAnchor),
		])
		window.contentView = content

		markers.translatesAutoresizingMaskIntoConstraints = false
		content.addSubview(markers)
		NSLayoutConstraint.activate([
			markers.topAnchor.constraint(equalTo: playerView.topAnchor),
			markers.leadingAnchor.constraint(equalTo: playerView.leadingAnchor),
			markers.trailingAnchor.constraint(equalTo: playerView.trailingAnchor),
			markers.bottomAnchor.constraint(equalTo: playerView.bottomAnchor),
		])

		DispatchQueue.main.async {
			withTakes.setPosition(230, ofDividerAt: 0)
			split.setPosition(split.bounds.height - 170, ofDividerAt: 0)
		}

		// No marking here: an anchor is marked on the take, in the cutting
		// window, where the footage is. This window shows what was found.
	}

	// MARK: - Wiring

	private func wire() {
		composeDocument.onChange = { [weak self] in self?.rebuild() }
		strip.onScrub = { [weak self] time in self?.seek(to: time) }

		takesTable.onOpen = { [weak self] url in self?.onOpenTake?(url) }
		takesTable.onRemove = { [weak self] path in self?.composeDocument.removeTake(path) }
		takesTable.onAdd = { [weak self] in self?.addTake(nil) }
		takesTable.onNew = { [weak self] in self?.newTake(nil) }

		// The same arrangement as the cutting window, for the same reason: the
		// keys have to work wherever the focus happens to be.
		keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
			guard let self, event.window === self.window else { return event }
			if self.window?.firstResponder is NSTextView { return event }
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
			self.playerView.layer?.addSublayer(overlays)
			self.overlayLayer = overlays
			self.layoutOverlays()
			self.seek(to: resumeAt)
		}
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
		let bounds = playerView.bounds
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

	@objc public func togglePlay(_ sender: Any?) { transport.togglePlay() }

	public func validateMenuItem(_ item: NSMenuItem) -> Bool {
		switch item.action {
		case #selector(render(_:)): return composeDocument.resolved != nil
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
