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

	func applicationDidFinishLaunching(_ notification: Notification) {
		NSApp.mainMenu = MainMenu.build()
		NotificationCenter.default.addObserver(
			forName: NSWindow.willCloseNotification, object: nil, queue: .main
		) { [weak self] note in
			MainActor.assumeIsolated {
				guard let window = note.object as? NSWindow else { return }
				self?.controllers.removeAll { $0.window === window }
				self?.composers.removeAll { $0.window === window }
			}
		}
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
		if let existing = composers.first(where: { $0.composeDocument.url == url }) {
			existing.window?.makeKeyAndOrderFront(nil)
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
			blank.window?.makeKeyAndOrderFront(nil)
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

	private func showComposer(_ document: ComposeDocument) {
		let controller = ComposeWindowController(document: document)
		// The project opens its takes, and they arrive as tabs beside it.
		controller.onOpenTake = { [weak self] url in self?.open(url) }
		controller.isTakeOpen = { [weak self] url in
			self?.controllers.contains { $0.takeDocument.url?.standardizedFileURL == url } ?? false
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

	private func open(_ url: URL) {
		if url.pathExtension != "cuttr" { openMedia([url]); return }
		if let existing = controllers.first(where: { $0.takeDocument.url == url }) {
			existing.window?.makeKeyAndOrderFront(nil)
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

	/// Puts a window up as a tab of whichever one is already there.
	///
	/// `addTabbedWindow` rather than `makeKeyAndOrderFront` alone: without it a
	/// second window opens on top of the first at the same size and position,
	/// and the one underneath is invisible and unreachable except through the
	/// Window menu. With it, a take and a project are two tabs of one window,
	/// which is what somebody working on both actually has.
	private func present(_ window: NSWindow?) {
		guard let window else { return }
		// Hosted by the project window when there is one, so the project keeps
		// its place as the first tab and takes accumulate after it rather than
		// in front of it.
		let host = composers.compactMap(\.window).first { $0.isVisible && $0 !== window }
			?? NSApp.keyWindow
			?? allWindows.first { $0 !== window }
		if let host, host !== window {
			host.addTabbedWindow(window, ordered: .above)
		}
		window.makeKeyAndOrderFront(nil)
		NSApp.activate(ignoringOtherApps: true)
	}

	private var allWindows: [NSWindow] {
		(controllers.compactMap(\.window) + composers.compactMap(\.window)).filter { $0.isVisible }
	}

	// MARK: - Menu targets

	private var current: MainWindowController? {
		controllers.first { $0.window?.isKeyWindow == true } ?? controllers.last
	}

	@objc func save(_ sender: Any?) { current?.save(sender) }
	@objc func saveAs(_ sender: Any?) { current?.saveAs(sender) }
	@objc func importSubclips(_ sender: Any?) { current?.importSubclips(sender) }

	@objc func showShortcuts(_ sender: Any?) {
		let alert = NSAlert()
		alert.messageText = "Keys"
		alert.informativeText = MainMenu.shortcutSheet
		alert.addButton(withTitle: "OK")
		alert.runModal()
	}
}
