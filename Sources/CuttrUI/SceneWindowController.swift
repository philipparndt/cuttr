import AppKit
import CuttrCompose
import CuttrKit
import UniformTypeIdentifiers

/// The scene window: one intro screen, title card or end plate, being made.
///
/// The third kind of window, and it exists for the same reason the cutting
/// window does. A project window is about a programme — which shots, in what
/// order, with what over them — and a scene is a thing made of six parts and
/// twenty keyframes that happens to be *used* by one overlay. Putting that in
/// the properties panel would be putting a whole editor inside one field of
/// another one.
///
/// It does not own a file. The project document does, exactly as a take
/// document owns a `.cuttr`: this window edits `scenes:` and hands the project
/// back, and the project writes it.
@MainActor
public final class SceneWindowController: NSWindowController, NSWindowDelegate,
                                          NSMenuItemValidation {

	public let sceneDocument: SceneDocument
	/// Which project this scene belongs to, so the application can tell whether
	/// a window for it is already open.
	public let projectURL: URL?

	private let stage = SceneStage()
	private let scrubber = SceneScrubber()
	private let parts = ScenePartsList()
	private let inspector = SceneInspector()
	private let bar = Bar()

	private var playing: Timer?
	private var keyMonitor: Any?

	public init(document: SceneDocument, projectURL: URL?) {
		self.sceneDocument = document
		self.projectURL = projectURL
		let window = NSWindow(
			contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
			styleMask: [.titled, .closable, .miniaturizable, .resizable],
			backing: .buffered, defer: false)
		window.appearance = NSAppearance(named: .darkAqua)
		window.backgroundColor = Theme.background
		window.minSize = NSSize(width: 860, height: 560)
		// A tab of the same window as the project it belongs to, like takes.
		window.tabbingIdentifier = "cuttr"
		window.tabbingMode = .preferred
		super.init(window: window)
		window.delegate = self
		build()
		wire()
		reload()
		window.center()
	}

	@available(*, unavailable) required init?(coder: NSCoder) { nil }

	// MARK: - Layout

	private func build() {
		guard let window else { return }

		// The picture and its clock, one above the other, in a split view —
		// which is how both of the other windows arrange a picture over a
		// timeline, and both of those work.
		let picture = NSSplitView()
		picture.isVertical = false
		picture.dividerStyle = .thin
		picture.addArrangedSubview(stage)
		picture.addArrangedSubview(scrubber)

		let middle = NSSplitView()
		middle.isVertical = true
		middle.dividerStyle = .thin
		middle.addArrangedSubview(parts)
		middle.addArrangedSubview(picture)
		middle.addArrangedSubview(inspector)

		let content = NSView()
		content.wantsLayer = true
		content.layer?.backgroundColor = Theme.background.cgColor
		for view in [bar, middle] as [NSView] {
			view.translatesAutoresizingMaskIntoConstraints = false
			content.addSubview(view)
		}
		NSLayoutConstraint.activate([
			bar.topAnchor.constraint(equalTo: content.topAnchor),
			bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
			bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
			bar.heightAnchor.constraint(equalToConstant: 38),
			middle.topAnchor.constraint(equalTo: bar.bottomAnchor),
			middle.leadingAnchor.constraint(equalTo: content.leadingAnchor),
			middle.trailingAnchor.constraint(equalTo: content.trailingAnchor),
			middle.bottomAnchor.constraint(equalTo: content.bottomAnchor),
		])

		// Wishes rather than rules, so every pane can still be dragged: a
		// required width here is a divider that will not move.
		let preferred = NSLayoutConstraint.Priority(250)
		for wish in [parts.widthAnchor.constraint(equalToConstant: 230),
		             inspector.widthAnchor.constraint(equalToConstant: 300),
		             scrubber.heightAnchor.constraint(equalToConstant: 130)] {
			wish.priority = preferred
			wish.isActive = true
		}
		NSLayoutConstraint.activate([
			parts.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
			inspector.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
			stage.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
			scrubber.heightAnchor.constraint(greaterThanOrEqualToConstant: 60),
		])
		window.contentView = content
	}

	// MARK: - Wiring

	private func wire() {
		sceneDocument.onChange = { [weak self] in self?.reload() }

		bar.onScene = { [weak self] name in
			self?.sceneDocument.show(name)
		}
		bar.onNewScene = { [weak self] in self?.newScene(nil) }
		bar.onPlay = { [weak self] in self?.togglePlay(nil) }
		bar.onLength = { [weak self] length in
			guard let self else { return }
			self.sceneDocument.length = length
			self.reload()
		}

		stage.onSelect = { [weak self] part in
			guard let self else { return }
			self.sceneDocument.selectedPart = part
			self.sceneDocument.selectedKey = nil
			self.reload()
		}
		stage.onMove = { [weak self] part, x, y, commit in
			self?.sceneDocument.move(part, x: x, y: y, commit: commit)
		}
		stage.onScale = { [weak self] part, scale, commit in
			self?.sceneDocument.set(.scale, to: scale, on: part,
			                        actionName: "Scale Part", commit: commit)
		}
		stage.onRotate = { [weak self] part, rotation, commit in
			self?.sceneDocument.set(.rotation, to: rotation, on: part,
			                        actionName: "Turn Part", commit: commit)
		}

		scrubber.onScrub = { [weak self] time in self?.seek(to: time) }
		scrubber.onSelectPart = { [weak self] part in
			guard let self else { return }
			self.sceneDocument.selectedPart = part
			self.reload()
		}
		scrubber.onSelectKey = { [weak self] key in
			guard let self else { return }
			self.sceneDocument.selectedKey = key
			// The playhead goes to the key that was clicked, because the next
			// thing somebody does is look at what the frame is like there.
			if let part = self.sceneDocument.selectedPart,
			   part < self.sceneDocument.scene.parts.count,
			   key < self.sceneDocument.scene.parts[part].keys.count {
				self.sceneDocument.playhead = self.sceneDocument.scene.parts[part].keys[key].t
			}
			self.reload()
		}
		scrubber.onMoveKey = { [weak self] part, key, time, commit in
			guard let self, commit else { return }
			self.sceneDocument.setKeyTime(time, of: key, on: part)
		}
		scrubber.onAddKey = { [weak self] part, time in
			guard let self else { return }
			self.sceneDocument.selectedPart = part
			self.sceneDocument.playhead = time
			self.sceneDocument.addKey(at: time, on: part)
		}

		parts.onSelect = { [weak self] part in
			guard let self, self.sceneDocument.selectedPart != part else { return }
			self.sceneDocument.selectedPart = part
			self.sceneDocument.selectedKey = nil
			self.reload()
		}
		parts.onAdd = { [weak self] content in
			guard let self else { return }
			if case .image = content {
				self.sceneDocument.addPart(content)
				self.chooseImage()
				return
			}
			self.sceneDocument.addPart(content)
		}
		parts.onRemove = { [weak self] part in self?.sceneDocument.removePart(part) }
		parts.onReorder = { [weak self] part, by in self?.sceneDocument.movePart(part, by: by) }

		inspector.onContent = { [weak self] content in
			guard let self, let part = self.sceneDocument.selectedPart else { return }
			self.sceneDocument.setContent(content, on: part, actionName: "Edit Part")
		}
		inspector.onChooseImage = { [weak self] in self?.chooseImage() }
		inspector.onSelectKey = { [weak self] key in
			guard let self else { return }
			self.sceneDocument.selectedKey = key
			if let part = self.sceneDocument.selectedPart,
			   part < self.sceneDocument.scene.parts.count,
			   key < self.sceneDocument.scene.parts[part].keys.count {
				self.sceneDocument.playhead = self.sceneDocument.scene.parts[part].keys[key].t
			}
			self.reload()
		}
		inspector.onAddKey = { [weak self] in
			guard let self, let part = self.sceneDocument.selectedPart else { return }
			self.sceneDocument.addKey(at: self.sceneDocument.playhead, on: part)
		}
		inspector.onRemoveKey = { [weak self] key in
			guard let self, let part = self.sceneDocument.selectedPart else { return }
			self.sceneDocument.removeKey(key, on: part)
		}
		inspector.onKeyTime = { [weak self] key, time in
			guard let self, let part = self.sceneDocument.selectedPart else { return }
			self.sceneDocument.setKeyTime(time, of: key, on: part)
		}
		inspector.onEase = { [weak self] key, ease in
			guard let self, let part = self.sceneDocument.selectedPart else { return }
			self.sceneDocument.setEase(ease, of: key, on: part)
		}
		inspector.onField = { [weak self] key, field, value in
			guard let self, let part = self.sceneDocument.selectedPart else { return }
			self.sceneDocument.setField(field, to: value, of: key, on: part)
		}
		inspector.onColor = { [weak self] key, colour in
			guard let self, let part = self.sceneDocument.selectedPart,
			      part < self.sceneDocument.scene.parts.count,
			      key < self.sceneDocument.scene.parts[part].keys.count else { return }
			var next = self.sceneDocument.scene
			next.parts[part].keys[key].color = colour
			self.sceneDocument.apply(next, actionName: colour == nil ? "Inherit Colour" : "Colour Key")
		}

		// The same arrangement the other two windows use: a monitor, so the
		// keys work wherever the focus happens to be — except inside a text
		// field, where a space is a space.
		keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
			guard let self, event.window === self.window else { return event }
			if self.window?.firstResponder is NSTextView { return event }
			if event.modifierFlags.intersection(.deviceIndependentFlagsMask)
				.contains(.command) { return event }
			switch event.keyCode {
			case 49: self.togglePlay(nil); return nil                   // space
			case 123: self.seek(to: self.sceneDocument.playhead - self.step); return nil
			case 124: self.seek(to: self.sceneDocument.playhead + self.step); return nil
			case 115: self.seek(to: 0); return nil                      // home
			case 119: self.seek(to: self.sceneDocument.length); return nil
			case 51, 117:                                               // delete
				if let part = self.sceneDocument.selectedPart {
					if let key = self.sceneDocument.selectedKey {
						self.sceneDocument.removeKey(key, on: part)
					} else {
						self.sceneDocument.removePart(part)
					}
					return nil
				}
				return event
			default: return event
			}
		}
	}

	/// One frame of the output, which is the clock a scene is judged on.
	private var step: Double {
		1 / max(sceneDocument.project.output.framesPerSecond, 1)
	}

	// MARK: - Showing it

	private func reload() {
		guard let window else { return }
		let document = sceneDocument
		window.title = "\(document.name) — \(projectURL?.deletingPathExtension().lastPathComponent ?? "Untitled")"

		stage.project = document.project
		stage.baseURL = document.baseURL
		stage.parameters = document.parameters
		stage.outputSize = document.project.output.size
		stage.scene = document.scene
		stage.time = document.playhead
		stage.selected = document.selectedPart
		stage.window?.invalidateCursorRects(for: stage)

		scrubber.scene = document.scene
		scrubber.length = document.length
		scrubber.playhead = document.playhead
		scrubber.selectedPart = document.selectedPart
		scrubber.selectedKey = document.selectedKey
		scrubber.invalidateIntrinsicContentSize()

		parts.reload(document.scene, selected: document.selectedPart)
		inspector.reload(document.scene, project: document.project,
		                 part: document.selectedPart, key: document.selectedKey)

		bar.show(names: document.sceneNames, current: document.name,
		         time: document.playhead, length: document.length, playing: playing != nil)
	}

	private func seek(to time: Double) {
		sceneDocument.playhead = min(max(0, time), sceneDocument.length)
		reload()
	}

	// MARK: - Playing

	@objc public func togglePlay(_ sender: Any?) {
		if let playing {
			playing.invalidate()
			self.playing = nil
			reload()
			return
		}
		// A scene is seconds long and made of keyframes, so it is played by
		// walking the playhead rather than by a player: there is no media here,
		// and the picture at a moment is a function of the moment.
		if sceneDocument.playhead >= sceneDocument.length - 1e-6 { sceneDocument.playhead = 0 }
		let interval = step
		playing = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
			MainActor.assumeIsolated {
				guard let self else { return }
				var next = self.sceneDocument.playhead + interval
				// Round, because a title card is watched over and over while it
				// is being made and stopping dead at the end each time is worse
				// than starting again.
				if next > self.sceneDocument.length { next = 0 }
				self.sceneDocument.playhead = next
				self.reload()
			}
		}
		reload()
	}

	// MARK: - Verbs

	@objc public func newScene(_ sender: Any?) {
		let alert = NSAlert()
		alert.messageText = "What is this scene called?"
		alert.informativeText = "The name an overlay uses to put it on the programme."
		let field = NSTextField(string: "intro")
		field.frame = NSRect(x: 0, y: 0, width: 220, height: 22)
		alert.accessoryView = field
		alert.addButton(withTitle: "Create")
		alert.addButton(withTitle: "Cancel")
		guard alert.runModal() == .alertFirstButtonReturn else { return }
		let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !name.isEmpty else { return }
		_ = sceneDocument.add(sceneNamed: name)
	}

	/// Picks a file for an image part, and keeps the path relative to the
	/// project — a scene that says `/Users/somebody/logo.png` survives being
	/// copied to another disk no better than a project that does.
	private func chooseImage() {
		guard let part = sceneDocument.selectedPart else { return }
		let panel = NSOpenPanel()
		panel.allowedContentTypes = [.image]
		panel.message = "Choose a picture. It is kept as a path relative to the project."
		guard panel.runModal() == .OK, let url = panel.url else { return }
		let path: String
		if let base = sceneDocument.baseURL, url.path.hasPrefix(base.path) {
			path = String(url.path.dropFirst(base.path.count).drop { $0 == "/" })
		} else {
			path = url.path
		}
		sceneDocument.setContent(.image(path), on: part, actionName: "Choose Picture")
	}

	/// The project changed elsewhere — the file was edited, or the project
	/// window wrote it.
	public func refresh(_ project: Project) {
		sceneDocument.refresh(project)
	}

	// MARK: - Undo

	public func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
		sceneDocument.undoManager
	}

	@objc public func undoEdit(_ sender: Any?) {
		if let editor = window?.firstResponder as? NSTextView,
		   let manager = editor.undoManager, manager !== sceneDocument.undoManager,
		   manager.canUndo {
			manager.undo()
			return
		}
		sceneDocument.undoManager.undo()
	}

	@objc public func redoEdit(_ sender: Any?) { sceneDocument.undoManager.redo() }

	public func validateMenuItem(_ item: NSMenuItem) -> Bool {
		let manager = sceneDocument.undoManager
		switch item.action {
		case #selector(undoEdit(_:)):
			item.title = manager.canUndo && !manager.undoActionName.isEmpty
				? "Undo \(manager.undoActionName)" : "Undo"
			return manager.canUndo
		case #selector(redoEdit(_:)):
			item.title = manager.canRedo && !manager.redoActionName.isEmpty
				? "Redo \(manager.redoActionName)" : "Redo"
			return manager.canRedo
		default: return true
		}
	}

	public func windowWillClose(_ notification: Notification) {
		if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
		keyMonitor = nil
		playing?.invalidate()
		playing = nil
	}

	// MARK: - The bar

	/// Which scene, how long it runs while it is being made, and the clock.
	///
	/// The length is here rather than in the inspector because it belongs to
	/// the session and not to the part: it is the one control in this window
	/// that changes nothing in the file.
	@MainActor
	final class Bar: NSView {
		var onScene: ((String) -> Void)?
		var onNewScene: (() -> Void)?
		var onPlay: (() -> Void)?
		var onLength: ((Double) -> Void)?

		private let scenes = NSPopUpButton()
		private let create = NSButton()
		private let play = NSButton()
		private let clock = NSTextField(labelWithString: "0.00 s")
		private let length = NSTextField(string: "4")
		private var names: [String] = []

		override init(frame: NSRect) {
			super.init(frame: frame)
			wantsLayer = true
			layer?.backgroundColor = Theme.panel.cgColor

			scenes.target = self
			scenes.action = #selector(pickScene)
			scenes.controlSize = .small
			scenes.font = Theme.mono

			create.title = "New Scene…"
			create.bezelStyle = .rounded
			create.controlSize = .small
			create.font = NSFont.systemFont(ofSize: 11)
			create.target = self
			create.action = #selector(makeScene)

			play.title = "Play"
			play.bezelStyle = .rounded
			play.controlSize = .small
			play.font = NSFont.systemFont(ofSize: 11)
			play.target = self
			play.action = #selector(hitPlay)

			clock.font = Theme.mono
			clock.textColor = Theme.dimText

			length.font = Theme.mono
			length.target = self
			length.action = #selector(setLength)
			length.translatesAutoresizingMaskIntoConstraints = false
			length.widthAnchor.constraint(equalToConstant: 52).isActive = true
			length.toolTip = "How long the scene runs while you work on it. "
				+ "Not written to the file — a scene plays for as long as the overlay using it."

			let caption = NSTextField(labelWithString: "runs for")
			caption.font = Theme.monoSmall
			caption.textColor = Theme.faintText

			let stack = NSStackView(views: [scenes, create, play, clock, NSView(), caption, length])
			stack.orientation = .horizontal
			stack.spacing = 8
			stack.alignment = .centerY
			stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
			stack.translatesAutoresizingMaskIntoConstraints = false
			addSubview(stack)
			NSLayoutConstraint.activate([
				stack.topAnchor.constraint(equalTo: topAnchor),
				stack.bottomAnchor.constraint(equalTo: bottomAnchor),
				stack.leadingAnchor.constraint(equalTo: leadingAnchor),
				stack.trailingAnchor.constraint(equalTo: trailingAnchor),
			])
		}

		@available(*, unavailable) required init?(coder: NSCoder) { nil }

		func show(names: [String], current: String, time: Double, length: Double, playing: Bool) {
			if names != self.names {
				self.names = names
				scenes.removeAllItems()
				scenes.addItems(withTitles: names)
			}
			if let index = names.firstIndex(of: current) { scenes.selectItem(at: index) }
			clock.stringValue = String(format: "%.2f s", time)
			play.title = playing ? "Pause" : "Play"
			// Not while somebody is typing in it, or the field rewrites itself
			// under the cursor on every frame of playback.
			if window?.firstResponder !== self.length.currentEditor() {
				self.length.stringValue = TakeWriter.number(length, places: 2)
			}
		}

		@objc private func pickScene() {
			guard let title = scenes.titleOfSelectedItem else { return }
			onScene?(title)
		}

		@objc private func makeScene() { onNewScene?() }
		@objc private func hitPlay() { onPlay?() }

		@objc private func setLength() {
			guard let value = Double(length.stringValue
				.replacingOccurrences(of: ",", with: ".")) else { return }
			onLength?(value)
		}
	}
}
