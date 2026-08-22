import AppKit
import CuttrCompose
import CuttrKit
import UniformTypeIdentifiers

/// The scene editor: one intro screen, title card or end plate, being made.
///
/// The third kind of document, and it exists for the same reason the cutting
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
public final class SceneWindowController: DocumentEditor, NSMenuItemValidation {

	public let sceneDocument: SceneDocument
	/// Which project this scene belongs to, so the application can tell whether
	/// an editor for it is already open.
	public let projectURL: URL?

	private let stage = SceneStage()
	private let scrubber = SceneScrubber()
	private let parts = ScenePartsList()
	private let inspector = SceneInspector()
	/// The same bar as the other two windows: which document, the clock, what
	/// just happened. The scene editor had a bar of its own and was left out of
	/// the redesign — three windows, three arrangements, which is exactly the
	/// thing this was all for.
	private let setup = SceneSetup()

	private var playing: Timer?
	private var keyMonitor: Any?

	public init(document: SceneDocument, projectURL: URL?) {
		self.sceneDocument = document
		self.projectURL = projectURL
		super.init()
		openingSize = NSSize(width: 1180, height: 760)
		minimumSize = NSSize(width: 860, height: 560)
		build()
		wire()
		reload()
	}

	@available(*, unavailable) required init?(coder: NSCoder) { nil }

	// MARK: - Layout

	private func build() {
		// The picture and its clock, one above the other, in a split view —
		// which is how both of the other windows arrange a picture over a
		// timeline, and both of those work.
		// A real frame, not zero.
		//
		// A split view created at 0x0 has its size turned into a pair of
		// *required* constraints by its autoresizing mask — `width == 0`,
		// `height == 0` — and every content minimum inside it is then one half
		// of a system with no solution. That is the same lesson `TableScroll`
		// already records for scroll views, and it is what filled the log with
		// `layout constraints are not satisfiable` before this window had ever
		// been shown.
		let picture = NSSplitView(frame: .roomToLayOutIn)
		picture.isVertical = false
		picture.dividerStyle = .thin
		picture.addArrangedSubview(stage)
		picture.addArrangedSubview(scrubber)

		let middle = NSSplitView(frame: .roomToLayOutIn)
		middle.isVertical = true
		middle.dividerStyle = .thin
		middle.addArrangedSubview(parts)
		middle.addArrangedSubview(picture)
		middle.addArrangedSubview(inspector)

		let content = NSView()
		content.wantsLayer = true
		content.layer?.backgroundColor = Theme.background.cgColor
		// No bar among them: it belongs to the window, and this is what goes
		// under it.
		for view in [middle] as [NSView] {
			view.translatesAutoresizingMaskIntoConstraints = false
			content.addSubview(view)
		}
		NSLayoutConstraint.activate([
			middle.topAnchor.constraint(equalTo: content.topAnchor),
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
			// Floors, not laws — see `asFloor`. All four are inside split views,
			// which are the object that decides how big their children are.
			parts.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).asFloor,
			inspector.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).asFloor,
			stage.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).asFloor,
			scrubber.heightAnchor.constraint(greaterThanOrEqualToConstant: 60).asFloor,
		])
		contentRoot = content
		initialResponder = parts
	}

	// MARK: - Wiring

	private func wire() {
		sceneDocument.onChange = { [weak self] in self?.reload() }

		setup.onScene = { [weak self] name in
			self?.sceneDocument.show(name)
		}
		setup.onNewScene = { [weak self] in self?.newScene(nil) }
		setup.onLength = { [weak self] length in
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
		inspector.onShape = { [weak self] key, kind in
			guard let self, let part = self.sceneDocument.selectedPart else { return }
			self.sceneDocument.setKeyShape(kind, of: key, on: part)
		}
		inspector.onColor = { [weak self] key, colour in
			guard let self, let part = self.sceneDocument.selectedPart,
			      part < self.sceneDocument.scene.parts.count,
			      key < self.sceneDocument.scene.parts[part].keys.count else { return }
			var next = self.sceneDocument.scene
			next.parts[part].keys[key].color = colour
			self.sceneDocument.apply(next, actionName: colour == nil ? "Inherit Colour" : "Colour Key")
		}
		inspector.onSecondStop = { [weak self] key, colour in
			guard let self, let part = self.sceneDocument.selectedPart,
			      part < self.sceneDocument.scene.parts.count,
			      key < self.sceneDocument.scene.parts[part].keys.count else { return }
			var next = self.sceneDocument.scene
			next.parts[part].keys[key].to = colour
			self.sceneDocument.apply(next, actionName: colour == nil ? "Inherit Stop" : "Ramp Key")
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
		let document = sceneDocument
		titleChanged()

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

		findRepository()
		bar?.setName(document.name)
		bar?.setBranch(repositoryRoot.flatMap { GitRepository.branch(in: $0) })
		bar?.setClock(document.playhead)
		bar?.setPlaying(playing != nil)
		setup.show(names: document.sceneNames, current: document.name, length: document.length)
	}

	/// The work tree the project this scene belongs to sits in, if any.
	private var repositoryRoot: URL?
	private var repositoryFor: URL?

	private func findRepository() {
		let url = sceneDocument.baseURL
		guard url != repositoryFor else { return }
		repositoryFor = url
		repositoryRoot = url.flatMap { GitRepository.root(for: $0) }
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

	override var documentUndoManager: UndoManager? { sceneDocument.undoManager }

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

	override func documentClosed() {
		if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
		keyMonitor = nil
		playing?.invalidate()
		playing = nil
	}

	// MARK: - Being the document in the window

	override var documentTitle: String {
		"\(sceneDocument.name) — "
			+ (projectURL?.deletingPathExtension().lastPathComponent ?? "Untitled")
	}
	override var documentFile: URL? { sceneDocument.baseURL }

	/// What a scene puts in the shared bar: its name, the `…` behind which the
	/// scene picker and the length sit, and the two halves of the capsule.
	override func furnish(_ bar: DocumentBar) {
		// A scene is opened *from* a project, so there is always one to go back
		// out to and the window already knows which.
		bar.setBack(AppDelegate.shared?.projectOwning(self) != nil)
		bar.onBack = { [weak self] in
			guard let self, let project = AppDelegate.shared?.projectOwning(self) else { return }
			AppDelegate.shared?.reveal(project)
		}
		bar.setUp = setup
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
		bar.onPlayPause = { [weak self] in self?.togglePlay(nil) }
		bar.setName(sceneDocument.name)
		bar.setBranch(repositoryRoot.flatMap { GitRepository.branch(in: $0) })
		bar.setClock(sceneDocument.playhead)
		bar.setPlaying(playing != nil)
	}

	/// What the application has to say, in the bar this window shares with the
	/// other two.
	///
	/// A scene has no file of its own — every change goes straight into the
	/// project that holds it — so a save says nothing about this document. It is
	/// said here anyway because this is where the keystroke was pressed, and a
	/// key that answers in a window somebody is not looking at is a key that
	/// does nothing.
	func announce(_ text: String) { bar?.setStatus(text) }

	override func documentAppeared() { reload() }

	/// A scene plays on a timer of its own rather than through the transport, so
	/// this is what stopping it looks like.
	override func documentHidden() {
		playing?.invalidate()
		playing = nil
	}

}
