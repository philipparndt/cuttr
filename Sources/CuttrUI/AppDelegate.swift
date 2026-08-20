import AppKit
import CuttrCompose
import CuttrKit
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

	/// The documents open, held here and nowhere else — a document no longer
	/// owns a window, so nothing else keeps it alive.
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
		// Which place somebody was last in, so a document opened from a menu
		// goes where they are looking. `NSApp.keyWindow` is nil while a menu is
		// tracking or a popover is up, which is exactly when this is asked.
		NotificationCenter.default.addObserver(
			forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
		) { [weak self] note in
			MainActor.assumeIsolated {
				guard let window = note.object as? NSWindow,
				      let place = self?.places.first(where: { $0.window === window })
				else { return }
				self?.lastPlace = place
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
	}

	/// A document has gone: from a place that closed, or closed on its own.
	private func forget(_ document: DocumentEditor) {
		controllers.removeAll { $0 === document }
		composers.removeAll { $0 === document }
		if let scene = document as? SceneWindowController {
			if let observer = sceneObservers.removeValue(forKey: ObjectIdentifier(scene)) {
				NotificationCenter.default.removeObserver(observer)
			}
			sceneOwners.removeValue(forKey: ObjectIdentifier(scene))
		}
		scenes.removeAll { $0 === document }
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

	private func openProject(_ url: URL, aside: Bool = false) {
		if let existing = composers.first(where: {
			$0.composeDocument.url?.standardizedFileURL == url.standardizedFileURL
		}) {
			if aside { revealAside(existing) } else { reveal(existing) }
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
			if aside { revealAside(blank) } else { reveal(blank) }
			return
		}
		let document = ComposeDocument()
		do { try document.read(from: url) } catch {
			NSAlert(error: error).runModal()
			return
		}
		AppDelegate.remember(url)
		showComposer(document, aside: aside)
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
			reveal(existing)
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
		reveal(controller)
	}

	/// File ▸ New Scene, with no project window in front: there is nothing for
	/// a scene to belong to, so the project comes first.
	@objc func newScene(_ sender: Any?) {
		// The project on screen, else whichever one is open. Asked of the place
		// rather than of `NSApp.keyWindow`, which names a window and a window
		// holds several documents.
		guard let composer = (showing as? ComposeWindowController) ?? composers.last else {
			let alert = NSAlert()
			alert.messageText = "A scene belongs to a project"
			alert.informativeText = "Open or make a project first — a scene lives in its "
				+ "`scenes:` block, and is used by an overlay on its timeline."
			alert.runModal()
			return
		}
		showScene(for: composer.composeDocument, named: nil)
	}

	private func showComposer(_ document: ComposeDocument, aside: Bool = false) {
		let controller = ComposeWindowController(document: document)
		wire(controller)
		composers.append(controller)
		if aside { revealAside(controller) } else { reveal(controller) }
	}

	/// What a project window asks the application to do for it.
	///
	/// Its own method rather than a block inside ``showComposer(_:aside:)``,
	/// because a project made in a test has to be able to do the same things —
	/// and a test that opens a take by calling ``open(_:aside:)`` directly is
	/// not testing the gesture, it is testing the last link of it.
	private func wire(_ controller: ComposeWindowController) {
		// The project opens its takes, and they take its place — or open beside
		// it, when that is what was asked for.
		controller.onOpenTake = { [weak self] url, aside in self?.open(url, aside: aside) }
		controller.onOpenTakeAt = { [weak self] url, time in self?.open(url, at: time) }
		controller.isTakeOpen = { [weak self] url in
			self?.controllers.contains { $0.takeDocument.url?.standardizedFileURL == url } ?? false
		}
		controller.onEditScene = { [weak self] document, name in
			self?.showScene(for: document, named: name)
		}
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
		/// The document itself. A window would not do any more: one window holds
		/// several documents, so "go to this window" no longer names one.
		var editor: DocumentEditor?
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
			                        kind: .scene, project: nil, editor: composer,
			                        url: composer.composeDocument.url))
			let paths = Set(composer.composeDocument.takes.map(\.url.standardizedFileURL))
			for controller in controllers
			where controller.takeDocument.url.map({ paths.contains($0.standardizedFileURL) }) == true {
				owned.insert(ObjectIdentifier(controller))
				out.append(OpenDocument(name: controller.takeDocument.displayName,
				                        kind: .take,
				                        project: composer.composeDocument.displayName,
				                        editor: controller,
				                        url: controller.takeDocument.url))
			}
		}
		// And the takes no open project owns. Said plainly rather than filed
		// under an empty parenthesis: a take can be opened on its own, and that
		// is not a fault.
		for controller in controllers where !owned.contains(ObjectIdentifier(controller)) {
			out.append(OpenDocument(name: controller.takeDocument.displayName,
			                        kind: .take, project: nil, editor: controller,
			                        url: controller.takeDocument.url))
		}
		for scene in scenes {
			out.append(OpenDocument(name: scene.sceneDocument.name,
			                        kind: .section, project: nil, editor: scene,
			                        url: scene.sceneDocument.baseURL))
		}
		return out
	}

	func documentsMenu(for here: DocumentEditor?) -> NSMenu {
		let menu = NSMenu()
		var wasTake = false
		for document in openDocuments() {
			// A separator where the takes stop belonging to anything.
			if document.kind == .take, document.project == nil, wasTake, !menu.items.isEmpty {
				menu.addItem(.separator())
				wasTake = false
			}
			if document.kind == .take, document.project != nil { wasTake = true }
			menu.addItem(item(for: document.editor, name: document.name, kind: document.kind,
			                  under: document.project, here: here))
		}
		return menu
	}

	private func item(for editor: DocumentEditor?, name: String, kind: Theme.Kind,
	                  under project: String?, here: DocumentEditor?) -> NSMenuItem {
		let item = NSMenuItem(title: name, action: #selector(goToDocument(_:)), keyEquivalent: "")
		item.target = self
		item.representedObject = editor
		item.image = Theme.symbol(kind, size: 12)
		// The tick has to be readable at a glance, including when the list is a
		// list of one: with a single document open the menu should still look
		// like an answer to "which am I in" rather than like a stray item.
		item.state = editor === here ? .on : .off
		if let project {
			item.indentationLevel = 1
			item.toolTip = "in \(project)"
		}
		return item
	}

	/// For the tests: a delegate holding these documents, without the
	/// application having opened them. Nothing is on screen until something is
	/// revealed, exactly as at launch.
	func adoptForTesting(composers: [ComposeWindowController] = [],
	                     controllers: [MainWindowController] = [],
	                     scenes: [SceneWindowController] = []) {
		self.composers = composers
		self.controllers = controllers
		self.scenes = scenes
		// Wired as the application wires them, so a double click in a takes list
		// arrives here rather than stopping at a `nil` callback.
		for composer in composers { wire(composer) }
	}

	/// For the tests: the places, so a test can count the windows and ask which
	/// document each holds.
	var placesForTesting: [DocumentPlace] { places }

	@objc func goToDocument(_ sender: NSMenuItem) {
		reveal(sender.representedObject as? DocumentEditor)
	}

	/// The list behind the capsule's left half and behind `⇧⌘P`: what is open,
	/// then what this project is made of, then what was open before.
	///
	/// Three groups rather than one flat pile, because they answer three
	/// questions — which of these am I already in, what else is in the thing I
	/// am working on, and what did I work on last week — and a list that mixes
	/// them makes somebody read every row to find out which kind each one is.
	///
	/// The middle group is what makes this a navigator rather than a window
	/// list, and it is the reason the panel's height matters: a real project has
	/// twenty takes and a scene or two, so the list is long by design and the
	/// filter is how it is used.
	func switcherGroups(current: DocumentEditor? = nil) -> [DocumentSwitcher.Group] {
		var groups: [DocumentSwitcher.Group] = []

		let here = current ?? showing
		let listed = openDocuments()
		let open = listed.map { document in
			DocumentSwitcher.Entry(
				name: document.name,
				// Always the folder, never "in dingsda". The indent already says
				// which project a take belongs to; the folder is the thing that
				// tells two takes called `take-1` apart, and it was the column
				// this list was missing.
				path: shortPath(document.url),
				kind: document.kind,
				indented: document.project != nil,
				isCurrent: document.editor === here,
				open: { [weak self] in self?.reveal(document.editor) },
				openAside: { [weak self] in self?.revealAside(document.editor) })
		}
		if !open.isEmpty { groups.append(.init("Open Documents", open)) }

		// Everything the project on screen is made of, opened or not.
		//
		// This is what turns the capsule from a window list into a navigator,
		// and it is what the user asked for: "maybe we should show directly all
		// scenes and takes in the dropdown". A project lists its takes and its
		// scenes; there is no reason to have to open one before it can be
		// switched to, and a list that only offers what is already open cannot
		// answer "take me to walter-take-3".
		//
		// Once each. A take that is open is in the group above, so it is left
		// out here rather than appearing twice under two headings — which would
		// make the count of rows a lie and give two rows the same effect.
		let alreadyOpen = Set(listed.compactMap { $0.url?.standardizedFileURL.path })
		if let project = projectOnScreen {
			var inside: [DocumentSwitcher.Entry] = []
			for take in project.composeDocument.takes
			where !alreadyOpen.contains(take.url.standardizedFileURL.path) {
				let url = take.url
				inside.append(DocumentSwitcher.Entry(
					name: take.name,
					path: shortPath(url),
					kind: .take,
					// A take whose file has gone says so rather than offering a
					// row that opens an alert. The project already knows: that
					// is what `problem` is.
					missing: take.problem != nil,
					open: take.problem == nil ? { [weak self] in self?.open(url) } : nil,
					openAside: take.problem == nil
						? { [weak self] in self?.open(url, aside: true) } : nil))
			}
			let mine = ObjectIdentifier(project.composeDocument)
			let openScenes = Set(scenes
				.filter { sceneOwners[ObjectIdentifier($0)] == mine }
				.map { $0.sceneDocument.name })
			for name in project.composeDocument.project.scenes.keys.sorted()
			where !openScenes.contains(name) {
				inside.append(DocumentSwitcher.Entry(
					name: name,
					path: shortPath(project.composeDocument.url),
					kind: .section,
					open: { [weak self] in
						self?.showScene(for: project.composeDocument, named: name)
					}))
			}
			if !inside.isEmpty {
				groups.append(.init("In \(project.composeDocument.displayName)", inside))
			}
		}

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
					open: there ? { [weak self] in self?.open(url) } : nil,
					openAside: there ? { [weak self] in self?.open(url, aside: true) } : nil)
			}
		if !recent.isEmpty { groups.append(.init("Recent Documents", Array(recent))) }
		return groups
	}

	/// The project the document on screen belongs to.
	///
	/// Itself when a project is showing; the project that lists this take when a
	/// take is; the project a scene is a scene of. A take opened on its own that
	/// no open project names falls back to whichever project is open, because
	/// the answer to "what else is there" is better than no answer.
	private var projectOnScreen: ComposeWindowController? {
		if let composer = showing as? ComposeWindowController { return composer }
		if let scene = showing as? SceneWindowController,
		   let owner = sceneOwners[ObjectIdentifier(scene)] {
			return composers.first { ObjectIdentifier($0.composeDocument) == owner }
		}
		if let take = showing as? MainWindowController, let url = take.takeDocument.url {
			let wanted = url.standardizedFileURL
			if let owner = composers.first(where: { composer in
				composer.composeDocument.takes.contains { $0.url.standardizedFileURL == wanted }
			}) {
				return owner
			}
		}
		return composers.first
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
		let groups = switcherGroups()
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
		// The place somebody is looking at, and its bar — which is the window's
		// own now, so there is nothing to go looking for in a view tree.
		// Reached from the Window menu there is no key window at all, since the
		// menu is tracking, and this used to give up and do nothing having first
		// lit the capsule's chevron and left it lit.
		guard let place = current ?? places.first else { return }
		let bar = place.bar
		bar.setOpenHalf(.project)
		let (view, rect) = bar.anchor(for: .project)
		showDocumentSwitcher(from: view, rect: rect) { bar.setOpenHalf(nil) }
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
		let open = openDocuments().compactMap(\.editor)
		guard open.count > 1 else { return }
		// From the document on screen rather than from whichever window is
		// key: with a menu tracking or a popover up there may be no key window
		// at all, and stepping from index 0 then goes somewhere arbitrary.
		let here = open.firstIndex { $0 === showing } ?? 0
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

	/// Opens a take. `aside` puts it in a window of its own rather than in the
	/// one somebody is looking at — ⌥-double-clicking a take in a project, which
	/// is how two takes get compared side by side.
	func open(_ url: URL, aside: Bool = false) {
		if url.pathExtension != "cuttr" { openMedia([url], aside: aside); return }
		// Compared standardised. `/tmp/x` and `/private/tmp/x` are one file
		// under two names, and a project naming its takes relative to itself
		// hands over the other one from the panel — so plain `==` opened a
		// second window on a take that was already open, which is the one
		// thing this model must never do.
		if let existing = controllers.first(where: {
			$0.takeDocument.url?.standardizedFileURL == url.standardizedFileURL
		}) {
			// Already open: it comes to the front of the place it is in, or moves
			// to a window of its own when that is what was asked for.
			if aside { revealAside(existing) } else { reveal(existing) }
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
		show(MainWindowController(document: document), aside: aside)
	}

	private func openMedia(_ urls: [URL], aside: Bool = false) {
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
			if FileManager.default.fileExists(atPath: beside.path) { open(beside, aside: aside); return }
		}
		let document = TakeDocument()
		document.setMedia(video: video, audio: audio)
		show(MainWindowController(document: document), aside: aside)
	}

	private func show(_ controller: MainWindowController, aside: Bool = false) {
		controllers.append(controller)
		if aside { revealAside(controller) } else { reveal(controller) }
	}

	// MARK: - One place to work

	/// The windows. One usually, and each of them a place a document can be.
	///
	/// **A window is a place to work, and the document in it changes.** Not a
	/// window per document with one ordered in at a time — which is what this
	/// replaces, and which the user could see through twice: "it still seems to
	/// open a new window instead of just switching the contents". It did. Six
	/// windows for six documents, all at one frame, `orderOut` on five of them.
	/// From the inside that reads as a switch; from the outside the Window menu
	/// listed six, Mission Control showed six, and every switch was macOS
	/// fading one window in over another rather than a view being replaced.
	///
	/// So: a ``DocumentPlace`` is one `NSWindow` with a bar across the top and
	/// whichever document underneath. Switching swaps the view under the bar.
	/// The frame, the screen and the full-screen state come through untouched
	/// because they belong to a window nobody touched.
	private var places: [DocumentPlace] = []
	/// Which place somebody was last in — the one a document opens into.
	private weak var lastPlace: DocumentPlace?

	/// Every window holding a document.
	var documentWindows: [NSWindow] { places.map(\.window) }

	/// Every document open, in the order they were opened, whatever place each
	/// is in.
	var documents: [DocumentEditor] {
		(composers as [DocumentEditor]) + (controllers as [DocumentEditor])
			+ (scenes as [DocumentEditor])
	}

	/// The document somebody is looking at.
	var showing: DocumentEditor? { current?.showing }

	/// The place a document opens into: the one whose window is key, else the
	/// one last used, else whatever there is.
	var current: DocumentPlace? {
		if let key = places.first(where: { $0.window.isKeyWindow }) { return key }
		if let last = lastPlace, places.contains(where: { $0 === last }) { return last }
		return places.last
	}

	/// Puts a document on screen.
	///
	/// In the place it is already in, if it is in one — a document is in exactly
	/// one place, because it *is* a view tree and a view is in one window. Else
	/// in the place asked for, or the one somebody is looking at, or a new one
	/// when there is none.
	func reveal(_ document: DocumentEditor?, in wanted: DocumentPlace? = nil) {
		guard let document else { return }
		if let holding = document.place, holding.holds(document) {
			if let wanted, wanted !== holding {
				holding.release(document, closing: false)
				wanted.adopt(document)
			} else {
				holding.show(document)
			}
		} else {
			let place = wanted ?? current ?? makePlace(for: document)
			place.adopt(document)
		}
		lastPlace = document.place
		NSApp.activate(ignoringOtherApps: true)
	}

	/// A window of its own for this document, which is the answer to "one place
	/// to be must not mean being unable to be in two".
	///
	/// Comparing two takes side by side is a real thing to want, and the default
	/// gesture swaps in place. So there is a second gesture and it is explicit:
	/// ⌥⌘N in the Window menu, ⌥-double-click on a take in a project, or ⌥ held
	/// while choosing in the switcher.
	@discardableResult
	func revealAside(_ document: DocumentEditor?) -> DocumentPlace? {
		guard let document else { return nil }
		let place = makePlace(for: document)
		reveal(document, in: place)
		return place
	}

	/// ⌥⌘N: the document on screen moves into a window of its own, leaving
	/// whatever else is open in the one it came from.
	@objc func moveToNewWindow(_ sender: Any?) {
		guard let here = current, let document = here.showing else { return }
		// A place with one document in it is already a window of its own.
		guard here.documents.count > 1 else { return }
		revealAside(document)
	}

	private func makePlace(for document: DocumentEditor) -> DocumentPlace {
		let place = DocumentPlace(size: document.openingSize)
		place.onClose = { [weak self] going in self?.places.removeAll { $0 === going } }
		place.onCloseDocument = { [weak self] document in self?.forget(document) }
		// Not exactly on top of the window it came from. Two windows at one
		// frame is the fault the tab bar existed to fix, and the whole point of
		// a second window is seeing both.
		if let over = current?.window {
			var frame = over.frame
			frame.origin.x += 32
			frame.origin.y -= 32
			place.window.setFrame(frame, display: false)
		} else {
			place.window.center()
		}
		places.append(place)
		lastPlace = place
		return place
	}

	/// ⌘W: closes the *document*, and the window with it when it was the last
	/// one in it.
	///
	/// A window holding four documents must not take all four away on one ⌘W —
	/// that is the cost of one window per place, and this is the answer to it.
	/// ⇧⌘W closes the window, asking about every document in it.
	@objc func closeDocument(_ sender: Any?) {
		guard let place = current, let document = place.showing else { return }
		guard document.mayClose() else { return }
		place.release(document, closing: true)
	}

	@objc func closeWindow(_ sender: Any?) { current?.window.performClose(nil) }

	// MARK: - Menu targets

	/// The take on screen. Asked of the place rather than of `NSApp.keyWindow`:
	/// a window holds several documents now, so "which window is key" no longer
	/// says which document a menu item is about.
	private var currentTake: MainWindowController? {
		if let take = showing as? MainWindowController { return take }
		return controllers.last
	}

	/// The project somebody is looking at, if that is what they are looking at.
	/// A scene belongs to a project, and saving from one saves that project — a
	/// scene is written inside it, not in a file of its own.
	private var currentComposer: ComposeWindowController? {
		if let composer = showing as? ComposeWindowController { return composer }
		guard let scene = showing as? SceneWindowController,
		      let owner = sceneOwners[ObjectIdentifier(scene)]
		else { return nil }
		return composers.first { ObjectIdentifier($0.composeDocument) == owner }
	}

	/// ⌘S in a project window used to save *a take* — whichever cutting window
	/// happened to be open — or nothing at all when none was. Save As opened a
	/// panel offering to write a `.cuttr` file from a window showing a
	/// `.cuttrproj`. Both now ask the key window what it is.
	@objc func save(_ sender: Any?) {
		if let composer = currentComposer { composer.save(sender) } else { currentTake?.save(sender) }
	}

	@objc func saveAs(_ sender: Any?) {
		if let composer = currentComposer { composer.saveAs(sender) } else { currentTake?.saveAs(sender) }
	}

	/// The versions kept of a project. Only a project window has them: a take is
	/// kept as part of the project that names it, because a version has to
	/// restore a coherent state rather than half of one.
	@objc func showVersions(_ sender: Any?) { currentComposer?.showVersions(sender) }
	@objc func importSubclips(_ sender: Any?) { currentTake?.importSubclips(sender) }

	@objc func showShortcuts(_ sender: Any?) {
		let alert = NSAlert()
		alert.messageText = "Keys"
		alert.informativeText = MainMenu.shortcutSheet
		alert.addButton(withTitle: "OK")
		alert.runModal()
	}
}
