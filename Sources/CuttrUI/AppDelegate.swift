import AppKit
import CuttrCompose
import CuttrKit
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

	/// Windows are held here and nowhere else. An `NSWindowController` whose
	/// only reference is the window it made is deallocated the moment the
	/// window closes, taking the key monitor and the transport with it — which
	/// is fine, and is why the array is pruned on close rather than never.
	private var controllers: [MainWindowController] = []
	private var composers: [ComposeWindowController] = []
	/// Scene editors, and what each is listening to. A scene window shows one
	/// scene of one project, so it has to hear when that project changes —
	/// reloaded from disk, or edited in its own window.
	private var scenes: [SceneWindowController] = []
	private var sceneObservers: [ObjectIdentifier: NSObjectProtocol] = [:]
	/// Which project each scene window belongs to. By identity rather than by
	/// file, because two untitled projects have the same URL — none — and would
	/// otherwise share one scene window between them.
	private var sceneOwners: [ObjectIdentifier: ObjectIdentifier] = [:]

	/// Installed here rather than at launch.
	///
	/// These watch the windows, and the windows are the thing being tested.
	/// `applicationDidFinishLaunching(_:)` is never called in a test — it
	/// builds the menu bar and puts an untitled project on screen — so an
	/// observer registered there is an observer no test can see the effect of.
	/// A delegate that has been made is a delegate that is watching.
	override init() {
		super.init()
		watchWindows()
	}

	func applicationDidFinishLaunching(_ notification: Notification) {
		NSApp.mainMenu = MainMenu.build()
		// A window with nothing in it, and a prompt in the timeline saying what
		// to drop on it. Opening straight into a file panel is the other choice
		// and it is worse: the first thing this program should show is what it
		// is, not a list of the user's folders.
		//
		// On the next turn of the run loop, because `application(_:open:)` has
		// not been called yet: launching by double-clicking a project used to
		// give an empty take tab as well, sitting in front of the thing that was
		// actually asked for.
		DispatchQueue.main.async { [weak self] in
			guard let self, self.controllers.isEmpty, self.composers.isEmpty else { return }
			// A project, not a take. The project is the thing somebody works
			// from — it lists the takes, opens them, and makes new ones — so
			// starting in a take is starting one level down.
			//
			// Untitled, and it says so: demanding a save location before the
			// window has appeared is a file panel as a splash screen. Adding a
			// take is what asks, because that is the first moment a path has to
			// be relative to something.
			self.showComposer(ComposeDocument())
		}
	}

	private func watchWindows() {
		// A tab group restored from a launch before tabbing was turned off
		// comes back with its tab bar, and that bar draws over a title bar the
		// program draws itself. Turning the mechanism off does not undo an
		// arrangement already on disk, so any window that comes up in a group
		// is taken out of it.
		NotificationCenter.default.addObserver(
			forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
		) { note in
			MainActor.assumeIsolated {
				guard let window = note.object as? NSWindow,
				      let group = window.tabGroup, group.windows.count > 1
				else { return }
				window.moveTabToNewWindow(nil)
			}
		}

		// Which open documents a checkout would pull the ground out from under.
		//
		// A `ComposeDocument` writes on every edit and re-reads its file, so a
		// work tree moving under it is a reload and nothing is lost. A
		// `TakeDocument` does neither: it holds its cuts in memory until
		// somebody saves, and it never watches the file. Switch a branch under
		// an open take and the window is unaware — the next save writes the
		// stale take over the branch's own. So the branch menu asks, and offers
		// no checkout while any take from that repository is open.
		BranchMenu.documentsInTheWay = { [weak self] root in
			let inside = root.standardizedFileURL.path
			return (self?.controllers ?? []).compactMap { controller in
				guard let url = controller.takeDocument.url,
				      url.standardizedFileURL.path.hasPrefix(inside)
				else { return nil }
				return controller.takeDocument.displayName
			}
		}
		NotificationCenter.default.addObserver(
			forName: NSWindow.willCloseNotification, object: nil, queue: .main
		) { [weak self] note in
			MainActor.assumeIsolated {
				guard let window = note.object as? NSWindow else { return }
				// The place outlives the document that was in it.
				if self?.documentWindows.contains(window) == true { self?.place = window.frame }
				self?.controllers.removeAll { $0.window === window }
				self?.composers.removeAll { $0.window === window }
				for scene in self?.scenes.filter({ $0.window === window }) ?? [] {
					if let observer = self?.sceneObservers
						.removeValue(forKey: ObjectIdentifier(scene)) {
						NotificationCenter.default.removeObserver(observer)
					}
					self?.sceneOwners.removeValue(forKey: ObjectIdentifier(scene))
				}
				self?.scenes.removeAll { $0.window === window }
				self?.fillThePlace(without: window)
			}
		}
	}

	/// Files handed over by the Finder, by `open -a`, or by a drop on the Dock
	/// icon.
	///
	/// Grouped rather than opened one at a time. A video and its audio arrive
	/// here as two URLs in one call, and they are one take with two files in
	/// it — opening them separately makes two windows, each half a take, and
	/// the second one covers the first so it looks like the video was ignored.
	func application(_ application: NSApplication, open urls: [URL]) {
		let projects = urls.filter { $0.pathExtension.lowercased() == "cuttrproj" }
		let takes = urls.filter { $0.pathExtension.lowercased() == "cuttr" }
		let media = urls.filter { !["cuttr", "cuttrproj"].contains($0.pathExtension.lowercased()) }
		for url in projects { openProject(url) }
		for url in takes { open(url) }
		if !media.isEmpty { openMedia(media) }
	}

	func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

	// MARK: - Documents

	@objc func newTake(_ sender: Any?) {
		show(MainWindowController(document: TakeDocument()))
	}

	// MARK: - Composing

	@objc func newProject(_ sender: Any?) {
		// A project needs a file before it needs anything else: every path in
		// it is relative to where it sits, so there is nowhere to put a take
		// until somebody says where the project is.
		let panel = NSSavePanel()
		panel.allowedContentTypes = [UTType(filenameExtension: "cuttrproj") ?? .plainText]
		panel.nameFieldStringValue = "programme.cuttrproj"
		panel.message = "Where should the project live? Takes are named relative to it."
		guard panel.runModal() == .OK, let url = panel.url else { return }

		// Seeded with whatever takes are beside it, because that is almost
		// always what somebody is about to type by hand anyway.
		let directory = url.deletingLastPathComponent()
		let takes = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
			.filter { $0.hasSuffix(".cuttr") }.sorted()
		var project = Project(takes: takes, output: Output(file: url.deletingPathExtension().lastPathComponent + ".mov"))
		if let first = takes.first,
		   let take = try? TakeReader.read(try String(contentsOf: directory.appendingPathComponent(first), encoding: .utf8)),
		   let clip = take.clips.first {
			project.timeline = [TimelineEntry(clip: ClipReference(clip.slug))]
		}
		do {
			try ProjectWriter.write(project).write(to: url, atomically: true, encoding: .utf8)
		} catch {
			NSAlert(error: error).runModal()
			return
		}
		openProject(url)
	}

	@objc func openProject(_ sender: Any?) {
		let panel = NSOpenPanel()
		panel.allowedContentTypes = [UTType(filenameExtension: "cuttrproj") ?? .plainText]
		panel.message = "Open a cuttr project"
		guard panel.runModal() == .OK, let url = panel.url else { return }
		openProject(url)
	}

	private func openProject(_ url: URL) {
		if let existing = composers.first(where: {
			$0.composeDocument.url?.standardizedFileURL == url.standardizedFileURL
		}) {
			reveal(existing.window)
			return
		}
		// An untitled project window that nobody has touched is a placeholder,
		// not a document: opening a real one takes its place rather than piling
		// a second tab on top.
		if let blank = composers.first(where: { $0.composeDocument.url == nil && !$0.composeDocument.isDirty }) {
			do { try blank.composeDocument.read(from: url) } catch {
				NSAlert(error: error).runModal()
				return
			}
			AppDelegate.remember(url)
			reveal(blank.window)
			return
		}
		let document = ComposeDocument()
		do { try document.read(from: url) } catch {
			NSAlert(error: error).runModal()
			return
		}
		AppDelegate.remember(url)
		showComposer(document)
	}

	// MARK: - Scenes

	/// Opens the scene editor on a project, and on a scene of it.
	///
	/// One window per project rather than one per scene: a scene window has a
	/// picker in its bar, so a second window for a second scene would be two
	/// windows showing the same list. Asking for a scene that is already open
	/// switches the window to it.
	func showScene(for document: ComposeDocument, named name: String?) {
		let chosen = name ?? document.project.scenes.keys.sorted().first
		if let existing = scenes.first(where: {
			sceneOwners[ObjectIdentifier($0)] == ObjectIdentifier(document)
		}) {
			if let chosen { existing.sceneDocument.show(chosen) }
			reveal(existing.window)
			return
		}
		// A project with no scenes yet opens on one this program made, under a
		// name somebody can change — an editor that opens on nothing gives a
		// blank stage and no idea where to start.
		var project = document.project
		let editing = chosen ?? "intro"
		if project.scenes[editing] == nil {
			project.scenes[editing] = SceneDocument.starter
			document.apply(project)
			try? document.write()
		}
		let longest = document.resolved?.overlays.reduce(into: Double?.none) { longest, overlay in
			guard case .scene(let used, _) = overlay.overlay.kind, used == editing else { return }
			longest = max(longest ?? 0, overlay.duration)
		} ?? nil
		let scene = SceneDocument(project: document.project, baseURL: document.baseURL,
		                          name: editing, playedFor: longest)
		// The project keeps the file. Everything the scene window changes comes
		// back here to be written, exactly as a take window writes its take.
		scene.onWrite = { [weak document] project in
			guard let document else { return }
			document.apply(project)
			try? document.write()
		}
		let controller = SceneWindowController(document: scene, projectURL: document.url)
		sceneOwners[ObjectIdentifier(controller)] = ObjectIdentifier(document)
		sceneObservers[ObjectIdentifier(controller)] = NotificationCenter.default.addObserver(
			forName: .cuttrProjectChanged, object: document, queue: .main
		) { [weak controller, weak document] _ in
			MainActor.assumeIsolated {
				guard let controller, let document else { return }
				controller.refresh(document.project)
			}
		}
		scenes.append(controller)
		present(controller.window)
	}

	/// File ▸ New Scene, with no project window in front: there is nothing for
	/// a scene to belong to, so the project comes first.
	@objc func newScene(_ sender: Any?) {
		guard let composer = composers.first(where: { $0.window?.isKeyWindow == true })
			?? composers.last else {
			let alert = NSAlert()
			alert.messageText = "A scene belongs to a project"
			alert.informativeText = "Open or make a project first — a scene lives in its "
				+ "`scenes:` block, and is used by an overlay on its timeline."
			alert.runModal()
			return
		}
		showScene(for: composer.composeDocument, named: nil)
	}

	private func showComposer(_ document: ComposeDocument) {
		let controller = ComposeWindowController(document: document)
		// The project opens its takes, and they arrive as tabs beside it.
		controller.onOpenTake = { [weak self] url in self?.open(url) }
		controller.onOpenTakeAt = { [weak self] url, time in self?.open(url, at: time) }
		controller.isTakeOpen = { [weak self] url in
			self?.controllers.contains { $0.takeDocument.url?.standardizedFileURL == url } ?? false
		}
		controller.onEditScene = { [weak self] document, name in
			self?.showScene(for: document, named: name)
		}
		composers.append(controller)
		present(controller.window)
	}

	/// Records a file in the recents list. Projects only.
	///
	/// A take is opened *from* the project that uses it — it is listed down the
	/// side of the project window with its clip count beside it — so putting
	/// takes in Open Recent fills the menu with the material and buries the
	/// thing somebody actually wants to reopen. One rule, here, rather than a
	/// judgement at each of the five call sites.
	///
	/// Standardised first. `/tmp/x` and `/private/tmp/x` are the same file and
	/// two different URLs, and noting both puts the same document in the menu
	/// twice under the same name — which looks like a bug in the menu and is
	/// really a bug at the call site.
	// MARK: - Which document am I in

	/// The delegate, for the windows that need to ask it something.
	static var shared: AppDelegate? { NSApp.delegate as? AppDelegate }

	/// One document open, as anything that lists them needs it.
	///
	/// One enumeration, because there are two things that show this list — the
	/// menu behind the document's name and the palette on `⇧⌘P` — and two
	/// enumerations of the same thing come apart.
	struct OpenDocument {
		var name: String
		var kind: Theme.Kind
		/// The project a take belongs to, when one that is open owns it.
		var project: String?
		var window: NSWindow?
		/// Its file, so a row can say where it is and a recent one that is
		/// already open can be left out of the second group.
		var url: URL?
	}

	/// Every document open: the projects, and under each the takes it is made
	/// of, then the takes no open project owns, then the scenes.
	///
	/// This is what replaced the window tab bar. A tab bar spends a permanent
	/// row of every window answering a question somebody asks a few times an
	/// hour, and it answers it in the one place the bar already says: the
	/// document's name, top left.
	func openDocuments() -> [OpenDocument] {
		var out: [OpenDocument] = []
		var owned = Set<ObjectIdentifier>()

		for composer in composers {
			out.append(OpenDocument(name: composer.composeDocument.displayName,
			                        kind: .scene, project: nil, window: composer.window,
			                        url: composer.composeDocument.url))
			let paths = Set(composer.composeDocument.takes.map(\.url.standardizedFileURL))
			for controller in controllers
			where controller.takeDocument.url.map({ paths.contains($0.standardizedFileURL) }) == true {
				owned.insert(ObjectIdentifier(controller))
				out.append(OpenDocument(name: controller.takeDocument.displayName,
				                        kind: .take,
				                        project: composer.composeDocument.displayName,
				                        window: controller.window,
				                        url: controller.takeDocument.url))
			}
		}
		// And the takes no open project owns. Said plainly rather than filed
		// under an empty parenthesis: a take can be opened on its own, and that
		// is not a fault.
		for controller in controllers where !owned.contains(ObjectIdentifier(controller)) {
			out.append(OpenDocument(name: controller.takeDocument.displayName,
			                        kind: .take, project: nil, window: controller.window,
			                        url: controller.takeDocument.url))
		}
		for scene in scenes {
			out.append(OpenDocument(name: scene.sceneDocument.name,
			                        kind: .section, project: nil, window: scene.window,
			                        url: scene.sceneDocument.baseURL))
		}
		return out
	}

	func documentsMenu(for current: NSWindow?) -> NSMenu {
		let menu = NSMenu()
		var wasTake = false
		for document in openDocuments() {
			// A separator where the takes stop belonging to anything.
			if document.kind == .take, document.project == nil, wasTake, !menu.items.isEmpty {
				menu.addItem(.separator())
				wasTake = false
			}
			if document.kind == .take, document.project != nil { wasTake = true }
			menu.addItem(item(for: document.window, name: document.name, kind: document.kind,
			                  under: document.project, current: current))
		}
		return menu
	}

	private func item(for window: NSWindow?, name: String, kind: Theme.Kind,
	                  under project: String?, current: NSWindow?) -> NSMenuItem {
		let item = NSMenuItem(title: name, action: #selector(goToDocument(_:)), keyEquivalent: "")
		item.target = self
		item.representedObject = window
		item.image = Theme.symbol(kind, size: 12)
		// The tick has to be readable at a glance, including when the list is a
		// list of one: with a single document open the menu should still look
		// like an answer to "which am I in" rather than like a stray item.
		item.state = window === current ? .on : .off
		if let project {
			item.indentationLevel = 1
			item.toolTip = "in \(project)"
		}
		return item
	}

	/// For the tests: a delegate holding these windows, without the application
	/// having opened them.
	func adoptForTesting(composers: [ComposeWindowController] = [],
	                     controllers: [MainWindowController] = [],
	                     scenes: [SceneWindowController] = []) {
		self.composers = composers
		self.controllers = controllers
		self.scenes = scenes
	}

	@objc func goToDocument(_ sender: NSMenuItem) {
		reveal(sender.representedObject as? NSWindow)
	}

	/// The keyboard path, which must not regress now that the tabs are gone:
	/// `⌘⇧[` and `⌘⇧]` still walk the open documents in the order the menu
	/// lists them.
	/// The list behind the capsule's left half and behind `⇧⌘P`: what is open,
	/// then what was open before.
	///
	/// Two groups rather than one flat pile. "Open" and "Recent" answer two
	/// different questions — which of these am I already in, and which did I
	/// work on last week — and a list that mixes them makes somebody read every
	/// row to find out which kind each one is.
	func switcherGroups(current: NSWindow? = nil) -> [DocumentSwitcher.Group] {
		var groups: [DocumentSwitcher.Group] = []

		let here = current ?? NSApp.keyWindow
		let open = openDocuments().map { document in
			DocumentSwitcher.Entry(
				name: document.name,
				// Always the folder, never "in dingsda". The indent already says
				// which project a take belongs to; the folder is the thing that
				// tells two takes called `take-1` apart, and it was the column
				// this list was missing.
				path: shortPath(document.url),
				kind: document.kind,
				indented: document.project != nil,
				isCurrent: document.window === here,
				open: { [weak self] in self?.reveal(document.window) })
		}
		if !open.isEmpty { groups.append(.init("Open Documents", open)) }

		// What was open before. `remember(_:)` already files these with the
		// document controller, so the list is there for the taking — but a
		// remembered file can have moved since, and a row offering a path that
		// opens nothing is worse than a row that says so.
		//
		// Takes as well as projects, and eight of them. A take is a document
		// somebody opens directly — double-clicking a `.cuttr` is the ordinary
		// way into one — so leaving them out would make the list answer a
		// narrower question than it is asked. Eight because the list is
		// most-recent-first and this is a switcher rather than an archive: past
		// the first handful, somebody is looking for a file rather than for the
		// thing they had open on Tuesday, and `⌘O` is the better door.
		let alreadyOpen = Set(openDocuments().compactMap { $0.url?.standardizedFileURL.path })
		let recent = NSDocumentController.shared.recentDocumentURLs
			.filter { !alreadyOpen.contains($0.standardizedFileURL.path) }
			.prefix(8)
			.map { url -> DocumentSwitcher.Entry in
				let there = FileManager.default.fileExists(atPath: url.path)
				return DocumentSwitcher.Entry(
					name: url.deletingPathExtension().lastPathComponent,
					path: shortPath(url),
					kind: url.pathExtension == "cuttr" ? .take : .scene,
					missing: !there,
					open: there ? { [weak self] in self?.open(url) } : nil)
			}
		if !recent.isEmpty { groups.append(.init("Recent Documents", Array(recent))) }
		return groups
	}

	/// A path as somebody would say it: under the home folder, `~` stands in.
	private func shortPath(_ url: URL?) -> String {
		guard let url else { return "" }
		let path = url.deletingLastPathComponent().path
		let home = FileManager.default.homeDirectoryForCurrentUser.path
		return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
	}

	/// Shows it under a part of a view — a half of the capsule.
	@discardableResult
	func showDocumentSwitcher(from view: NSView, rect: NSRect,
	                          onClose: @escaping () -> Void) -> Bool {
		let groups = switcherGroups(current: view.window)
		guard !groups.isEmpty else { onClose(); return false }
		return DocumentSwitcher.show(groups, from: view, rect: rect, onClose: onClose)
	}

	/// `⇧⌘P`: the same list, for a hand on the keyboard.
	///
	/// The same list, and that is the point — the capsule prints this key, so
	/// pressing it has to arrive at what clicking the capsule arrives at. It
	/// hangs from the capsule of the document on screen, so the popover appears
	/// where the eye already is rather than in the middle of the screen.
	@objc func showDocumentPalette(_ sender: Any?) {
		// The document on screen first, and only then whichever window is key.
		// Reached from the Window menu there is no key window — the menu is
		// tracking — and this used to give up and do nothing at all, having
		// first lit the capsule's chevron and left it lit.
		guard let window = showing ?? NSApp.keyWindow ?? documentWindows.first,
		      let bar = documentBar(in: window)
		else { return }
		bar.setOpenHalf(.project)
		let (view, rect) = bar.anchor(for: .project)
		showDocumentSwitcher(from: view, rect: rect) { bar.setOpenHalf(nil) }
	}

	/// The bar at the top of a window, whichever kind of window it is.
	private func documentBar(in window: NSWindow) -> DocumentBar? {
		func find(_ view: NSView) -> DocumentBar? {
			for sub in view.subviews {
				if let bar = sub as? DocumentBar { return bar }
				if let found = find(sub) { return found }
			}
			return nil
		}
		return window.contentView.flatMap(find)
	}

	/// What a document is, when it is not filed under something else.
	private func kindName(_ kind: Theme.Kind) -> String {
		switch kind {
		case .take: return "take"
		case .scene: return "project"
		case .section: return "scene"
		default: return ""
		}
	}

	@objc func nextDocument(_ sender: Any?) { step(by: 1) }
	@objc func previousDocument(_ sender: Any?) { step(by: -1) }

	private func step(by offset: Int) {
		let open = openDocuments().compactMap(\.window)
		guard open.count > 1 else { return }
		// From the document on screen rather than from whichever window is
		// key: with a menu tracking or a popover up there may be no key window
		// at all, and stepping from index 0 then goes somewhere arbitrary.
		let here = open.firstIndex { $0 === showing } ?? open.firstIndex { $0.isKeyWindow } ?? 0
		let landing = (here + offset + open.count) % open.count
		reveal(open[landing])
	}

	static func remember(_ url: URL) {
		guard url.pathExtension.lowercased() == "cuttrproj" else { return }
		NSDocumentController.shared.noteNewRecentDocumentURL(url.standardizedFileURL.resolvingSymlinksInPath())
	}

	@objc func openRecent(_ sender: NSMenuItem) {
		guard let url = sender.representedObject as? URL else { return }
		openProject(url)
	}

	@objc func clearRecents(_ sender: Any?) {
		NSDocumentController.shared.clearRecentDocuments(nil)
	}

	@objc func openTake(_ sender: Any?) {
		let panel = NSOpenPanel()
		// Media as well as cut lists, because "open" is what somebody reaches
		// for with a fresh recording and no take file yet. Dropping them on the
		// window does the same thing.
		panel.allowedContentTypes = [
			UTType(filenameExtension: "cuttr") ?? .plainText, .movie, .video, .audio,
		]
		panel.allowsMultipleSelection = true
		panel.message = "Open a take, or a video or audio file to cut"
		guard panel.runModal() == .OK else { return }
		let urls = panel.urls
		// One window for a video and an audio picked together: that is a take
		// with two files in it, not two takes.
		let takes = urls.filter { $0.pathExtension == "cuttr" }
		let media = urls.filter { $0.pathExtension != "cuttr" }
		for url in takes { open(url) }
		if !media.isEmpty { openMedia(media) }
	}

	/// Opens a take and puts the playhead somewhere in it — what the composing
	/// window asks for when somebody wants to see where a clip came from.
	private func open(_ url: URL, at time: Double?) {
		open(url)
		guard let time,
		      let controller = controllers.first(where: {
		      	$0.takeDocument.url?.standardizedFileURL == url.standardizedFileURL
		      })
		else { return }
		controller.reveal(at: time)
	}

	func open(_ url: URL) {
		if url.pathExtension != "cuttr" { openMedia([url]); return }
		// Compared standardised. `/tmp/x` and `/private/tmp/x` are one file
		// under two names, and a project naming its takes relative to itself
		// hands over the other one from the panel — so plain `==` opened a
		// second window on a take that was already open, which is the one
		// thing this model must never do.
		if let existing = controllers.first(where: {
			$0.takeDocument.url?.standardizedFileURL == url.standardizedFileURL
		}) {
			reveal(existing.window)
			return
		}
		let document = TakeDocument()
		do {
			try document.read(from: url)
		} catch {
			NSAlert(error: error).runModal()
			return
		}
		AppDelegate.remember(url)
		show(MainWindowController(document: document))
	}

	private func openMedia(_ urls: [URL]) {
		var video: URL?
		var audio: URL?
		for url in urls {
			guard let type = UTType(filenameExtension: url.pathExtension) else { continue }
			if type.conforms(to: .movie) || type.conforms(to: .video) { video = video ?? url }
			else if type.conforms(to: .audio) { audio = audio ?? url }
		}
		guard video != nil || audio != nil else { return }
		// If the recording already has a take beside it, that is the file to
		// open: dropping a video on this program twice should not produce two
		// windows disagreeing about the same recording.
		if let media = video ?? audio {
			let beside = media.deletingPathExtension().appendingPathExtension("cuttr")
			if FileManager.default.fileExists(atPath: beside.path) { open(beside); return }
		}
		let document = TakeDocument()
		document.setMedia(video: video, audio: audio)
		show(MainWindowController(document: document))
	}

	private func show(_ controller: MainWindowController) {
		controllers.append(controller)
		present(controller.window)
	}

	// MARK: - One place to work

	/// The frame the documents take turns in.
	///
	/// **A window is a place to work, and the document in it changes.** That is
	/// the model, and it is the one the user asked for twice: opening a take
	/// from a project puts the take where the project was, and the switcher
	/// behind the document's name puts anything else back there. Exactly one
	/// document window is on screen at a time. The others stay *open* — still
	/// in memory, still holding unsaved cuts, still listed in the capsule — and
	/// are simply not on screen.
	///
	/// What this replaces was two mechanisms pulling opposite ways.
	/// ``present(_:)`` put each new window into a tab group with the project by
	/// calling `addTabbedWindow`, which works whatever `tabbingMode` says —
	/// `.disallowed` declines *automatic* tabbing and does not refuse an
	/// explicit request. So a group was formed, a system tab bar appeared over
	/// the title bar this program draws itself, and the observer installed in
	/// ``applicationDidFinishLaunching(_:)`` then saw a window become key
	/// inside a group of two and called `moveTabToNewWindow` on it — during the
	/// very notification the tabbing had just caused. The take ended up in a
	/// window of its own, cascaded away from the project, sometimes behind it
	/// and off screen: "it only opens sometimes and then in a different
	/// window". Measured on a real project, three documents open, every take
	/// hidden and the project window walked 58 points down and right each time.
	///
	/// Two windows can never show one document here, because no document has
	/// two controllers and no more than one controller is on screen at all.
	var place: NSRect?

	/// Every window that holds a document, in the order the capsule lists them.
	var documentWindows: [NSWindow] {
		composers.compactMap(\.window) + controllers.compactMap(\.window)
			+ scenes.compactMap(\.window)
	}

	/// Whichever document is on screen.
	var showing: NSWindow? { documentWindows.first { $0.isVisible } }

	/// Puts a document in the place, and takes whatever was there out of sight.
	///
	/// The same gesture lands the same way every time: there is no host window
	/// to look for, no tab group to form, and nothing that depends on which
	/// window happened to be key.
	func reveal(_ window: NSWindow?) {
		guard let window else { return }
		let leaving = documentWindows.filter { $0 !== window && $0.isVisible }
		if let frame = leaving.first?.frame { place = frame }
		// A window somebody has taken full screen keeps its own arrangement:
		// putting a frame on it would drop it out, which is not what opening a
		// take asked for.
		if let frame = place, !window.styleMask.contains(.fullScreen) {
			window.setFrame(fitted(frame, to: window), display: false)
		}
		window.makeKeyAndOrderFront(nil)
		NSApp.activate(ignoringOtherApps: true)
		// Afterwards, never before. Ordering the outgoing window out first
		// leaves the screen blank for a frame — and ordering it out at all is
		// what stops AppKit handing key status back to it.
		for window in leaving { window.orderOut(nil) }
	}

	/// A frame this window can actually take. Windows differ in what they will
	/// go down to, and a project asked to fit into a take's frame must not end
	/// up smaller than it can draw itself in.
	private func fitted(_ frame: NSRect, to window: NSWindow) -> NSRect {
		var frame = frame
		frame.size.width = max(frame.width, window.minSize.width)
		frame.size.height = max(frame.height, window.minSize.height)
		return frame
	}

	/// When the document on screen closes, the next one takes its place rather
	/// than leaving an empty screen with documents still open.
	///
	/// The window that is closing is named rather than waited for. `willClose`
	/// arrives while it is still on screen, so asking `showing` at that moment
	/// gets the answer "the one that is going" — and deferring the question to
	/// the next turn of the run loop makes the whole thing depend on a hop
	/// that a test cannot see the far side of.
	private func fillThePlace(without closing: NSWindow?) {
		let open = documentWindows.filter { $0 !== closing }
		guard !open.contains(where: \.isVisible), let next = open.first else { return }
		reveal(next)
	}

	private func present(_ window: NSWindow?) { reveal(window) }

	// MARK: - Menu targets

	private var current: MainWindowController? {
		controllers.first { $0.window?.isKeyWindow == true } ?? controllers.last
	}

	/// The compose window somebody is looking at, if that is what they are
	/// looking at.
	/// A scene window belongs to a project, and saving from one saves that
	/// project — a scene is written inside it, not in a file of its own.
	private var currentComposer: ComposeWindowController? {
		if let composer = composers.first(where: { $0.window?.isKeyWindow == true }) { return composer }
		guard let scene = scenes.first(where: { $0.window?.isKeyWindow == true }),
		      let owner = sceneOwners[ObjectIdentifier(scene)]
		else { return nil }
		return composers.first { ObjectIdentifier($0.composeDocument) == owner }
	}

	/// ⌘S in a project window used to save *a take* — whichever cutting window
	/// happened to be open — or nothing at all when none was. Save As opened a
	/// panel offering to write a `.cuttr` file from a window showing a
	/// `.cuttrproj`. Both now ask the key window what it is.
	@objc func save(_ sender: Any?) {
		if let composer = currentComposer { composer.save(sender) } else { current?.save(sender) }
	}

	@objc func saveAs(_ sender: Any?) {
		if let composer = currentComposer { composer.saveAs(sender) } else { current?.saveAs(sender) }
	}
	@objc func importSubclips(_ sender: Any?) { current?.importSubclips(sender) }

	@objc func showShortcuts(_ sender: Any?) {
		let alert = NSAlert()
		alert.messageText = "Keys"
		alert.informativeText = MainMenu.shortcutSheet
		alert.addButton(withTitle: "OK")
		alert.runModal()
	}
}
