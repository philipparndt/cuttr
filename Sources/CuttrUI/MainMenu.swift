import AppKit

/// The menu bar, and the list of keys that are not in it.
///
/// Most of what this program does is a bare key — `s`, `i`, `o`, `[`, `]` — and
/// those deliberately have no menu item. A menu item's key equivalent is
/// matched before the responder chain sees the event, including while somebody
/// is typing a clip name, so `s` in a menu would mean no clip could ever be
/// called "Slides". Hence ``shortcutSheet``, which is the same list in the one
/// place a menu can still show it.
@MainActor
enum MainMenu {

	static func build() -> NSMenu {
		let main = NSMenu()

		let appItem = NSMenuItem()
		let app = NSMenu()
		app.addItem(withTitle: "About cuttr", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
		app.addItem(.separator())
		// ⌘, wherever it is pressed, because the settings file is not about any
		// one window. It lands on the application delegate, which is the last
		// thing in the responder chain and is there whether a window is or not.
		app.addItem(command("Settings…", #selector(AppDelegate.showSettings(_:)), ","))
		app.addItem(.separator())
		app.addItem(withTitle: "Hide cuttr", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
		app.addItem(withTitle: "Quit cuttr", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
		appItem.submenu = app
		main.addItem(appItem)

		let fileItem = NSMenuItem()
		let file = NSMenu(title: "File")
		file.addItem(withTitle: "New Take", action: #selector(AppDelegate.newTake(_:)), keyEquivalent: "n")
		let newProject = NSMenuItem(title: "New Project…",
		                            action: #selector(AppDelegate.newProject(_:)), keyEquivalent: "N")
		newProject.keyEquivalentModifierMask = [.command, .shift]
		file.addItem(newProject)
		file.addItem(withTitle: "Open…", action: #selector(AppDelegate.openTake(_:)), keyEquivalent: "o")
		let openProject = NSMenuItem(title: "Open Project…",
		                             action: #selector(AppDelegate.openProject(_:)), keyEquivalent: "O")
		openProject.keyEquivalentModifierMask = [.command, .shift]
		file.addItem(openProject)
		let recents = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
		let recentsMenu = NSMenu(title: "Open Recent")
		// Filled in by hand when it opens.
		//
		// Naming the submenu `NSRecentDocumentsMenu` is the trick that makes
		// AppKit fill it in, and it is a trick that works when the menu comes
		// out of a nib and this program's menus do not — so the item sat there
		// empty. `NSDocumentController` still keeps the list, which is the part
		// worth having; only the filling in was missing.
		recentsMenu.delegate = RecentsMenuFiller.shared
		recents.submenu = recentsMenu
		file.addItem(recents)
		file.addItem(.separator())
		// Aimed at the project window through the responder chain, so they are
		// enabled exactly when one is in front.
		file.addItem(command("Add Take to Project…",
		                     #selector(ComposeWindowController.addTake(_:)), "a", [.command, .shift]))
		file.addItem(command("New Take in Project…",
		                     #selector(ComposeWindowController.newTake(_:)), "t", [.command, .shift]))
		// With the other two ways of putting material into a project, because
		// that is what it is: what arrives is a take like any other.
		file.addItem(command("Find a Meme…",
		                     #selector(ComposeWindowController.findMeme(_:)), "m", [.command, .shift]))
		file.addItem(command("New Scene…", #selector(AppDelegate.newScene(_:)), "s",
		                     [.command, .control]))
		file.addItem(command("Export Project to Folder…",
		                     #selector(ComposeWindowController.exportProject(_:)), "E", [.command, .shift]))
		file.addItem(.separator())
		let importItem = NSMenuItem(title: "Import Subclips from Resolve…",
		                            action: #selector(AppDelegate.importSubclips(_:)), keyEquivalent: "i")
		importItem.keyEquivalentModifierMask = [.command, .shift]
		importItem.toolTip = "An EDL, FCPXML or Final Cut Pro 7 XML timeline exported from DaVinci Resolve"
		file.addItem(importItem)
		file.addItem(.separator())
		file.addItem(withTitle: "Save", action: #selector(AppDelegate.save(_:)), keyEquivalent: "s")
		let saveAs = NSMenuItem(title: "Save As…", action: #selector(AppDelegate.saveAs(_:)), keyEquivalent: "S")
		saveAs.keyEquivalentModifierMask = [.command, .shift]
		file.addItem(saveAs)
		// Under the two ways of saving, because it is what saving has been
		// quietly doing: every pause in the editing leaves a version in the
		// repository the project lives in. This is where they are read and where
		// one is brought back.
		let versions = NSMenuItem(title: "Versions…",
		                          action: #selector(AppDelegate.showVersions(_:)),
		                          keyEquivalent: "y")
		versions.keyEquivalentModifierMask = [.command, .shift]
		versions.toolTip = "Versions kept on refs/cuttr/saves every time the editing went quiet"
		file.addItem(versions)
		file.addItem(.separator())
		// ⌘W closes the *document*, not the window.
		//
		// One window holds several documents now — the whole point of the model
		// — so a ⌘W that closed the window would take four takes away on one
		// keystroke. The window is still closable, and says so: ⇧⌘W, which asks
		// about every document in it.
		file.addItem(command("Close", #selector(AppDelegate.closeDocument(_:)), "w"))
		file.addItem(command("Close Window", #selector(AppDelegate.closeWindow(_:)), "W",
		                     [.command, .shift]))
		fileItem.submenu = file
		main.addItem(fileItem)

		let editItem = NSMenuItem()
		let edit = NSMenu(title: "Edit")
		// Aimed at the window controller, which implements these. `undo:` — the
		// selector an undo manager declares — has no target in the responder
		// chain, so a menu item using it is grey for ever and never asks
		// anybody why.
		edit.addItem(withTitle: "Undo", action: #selector(MainWindowController.undoEdit(_:)), keyEquivalent: "z")
		let redo = NSMenuItem(title: "Redo", action: #selector(MainWindowController.redoEdit(_:)), keyEquivalent: "Z")
		redo.keyEquivalentModifierMask = [.command, .shift]
		edit.addItem(redo)
		edit.addItem(.separator())
		edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
		edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
		edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
		edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
		editItem.submenu = edit
		main.addItem(editItem)

		// Clip, View and Audio.
		//
		// Every item here also has a bare key, and the menu is not a duplicate
		// of that — it is the part somebody can find. A program whose verbs
		// exist only as undocumented keystrokes is a program with one user.
		//
		// All ⌘-based, because a menu key equivalent is matched before the
		// responder chain and a bare `s` in a menu would mean no clip could ever
		// be called "Slides". AppKit maps ⌘ equivalents through the current
		// layout, so these work on a German keyboard where the bare punctuation
		// keys needed a key-code fallback to.
		let clipItem = NSMenuItem()
		let clip = NSMenu(title: "Clip")
		// ⌘B, the blade, because that is what it is called in every editor
		// somebody arrives here from. The bare `S` stays: it is the key the
		// marking loop runs on, and it does not need a modifier.
		clip.addItem(command("Split at Playhead", #selector(MainWindowController.splitAction(_:)), "b"))
		clip.addItem(command("New Clip from In/Out", #selector(MainWindowController.commitPendingAction(_:)), "\r"))
		// A clip made out of a sentence takes a little of the quiet on either
		// side of it, so a row of them assembled later is not glued together.
		// Here because somebody whose programme puts its own handles on wants
		// to turn it off, and would otherwise have no way of knowing it was
		// happening at all.
		clip.addItem(command("Air Around Word Clips",
		                     #selector(MainWindowController.toggleAirAction(_:)), ""))
		clip.addItem(.separator())
		// No key equivalent, deliberately. `[` and `]` as menu equivalents render
		// as whatever the layout puts on those physical keys — on a German
		// keyboard the menu advertised ⌘Ö and ⌘Ä, which is worse than
		// advertising nothing. The bare `I` and `O` are the real shortcuts and
		// they are in Help ▸ Keys.
		clip.addItem(command("Set In", #selector(MainWindowController.setInAction(_:)), ""))
		clip.addItem(command("Set Out", #selector(MainWindowController.setOutAction(_:)), ""))
		clip.addItem(.separator())
		clip.addItem(command("Rename…", #selector(MainWindowController.renameSelected(_:)), "r"))
		// The bare `W` is the real shortcut; this is where somebody finds out
		// that it exists.
		clip.addItem(command("Name from Words",
		                     #selector(MainWindowController.nameFromWordsAction(_:)), ""))
		clip.addItem(command("Edit Slug…", #selector(MainWindowController.editSlugOfSelected(_:)), "R", [.command, .shift]))
		clip.addItem(command("Edit Tags…", #selector(MainWindowController.editTagsOfSelected(_:)), "t"))
		let tagItem = NSMenuItem(title: "Tags", action: nil, keyEquivalent: "")
		tagItem.identifier = NSUserInterfaceItemIdentifier("clip-tags")
		clip.addItem(tagItem)
		clip.addItem(.separator())
		clip.addItem(command("Trim Start to Playhead", #selector(MainWindowController.trimStartToPoint(_:)), ""))
		clip.addItem(command("Trim End to Playhead", #selector(MainWindowController.trimEndToPoint(_:)), ""))
		clip.addItem(command("Set In/Out from Clip", #selector(MainWindowController.setInOutFromClip(_:)), ""))
		clip.addItem(.separator())
		clip.addItem(.separator())
		let colorItem = NSMenuItem(title: "Colour", action: nil, keyEquivalent: "")
		colorItem.identifier = NSUserInterfaceItemIdentifier("clip-colour")
		clip.addItem(colorItem)
		clip.addItem(.separator())
		clip.addItem(command("Delete", #selector(MainWindowController.deleteAction(_:)), "\u{8}"))
		clip.delegate = ColourMenuFiller.shared
		clipItem.submenu = clip
		main.addItem(clipItem)

		let viewItem = NSMenuItem()
		let view = NSMenu(title: "View")
		// The project window's four views, before the zooms — in the rail's own
		// order, numbered to match it. A rail whose first item is ⌘2 is a rail
		// somebody has to remember an exception about.
		view.addItem(command("Project", #selector(ComposeWindowController.showProject(_:)), "1"))
		view.addItem(command("Editor", #selector(ComposeWindowController.showEditor(_:)), "2"))
		view.addItem(command("Project File", #selector(ComposeWindowController.showText(_:)), "3"))
		view.addItem(command("Preview", #selector(ComposeWindowController.showPreview(_:)), "4"))
		view.addItem(command("Full-Screen Preview",
		                     #selector(ComposeWindowController.toggleFullScreenPreview(_:)),
		                     "f", [.command, .control]))
		view.addItem(.separator())
		// And the cutting window's four, in the same place in this menu as the
		// project window's three, because they are the same rail.
		view.addItem(bare("Clips", #selector(MainWindowController.showClips(_:))))
		view.addItem(bare("Faces", #selector(MainWindowController.showFaces(_:))))
		view.addItem(bare("Words", #selector(MainWindowController.showWords(_:))))
		view.addItem(bare("Look", #selector(MainWindowController.showLook(_:))))
		view.addItem(.separator())
		view.addItem(command("Zoom In", #selector(MainWindowController.zoomIn(_:)), "+"))
		view.addItem(command("Zoom Out", #selector(MainWindowController.zoomOut(_:)), "-"))
		view.addItem(command("Zoom to Fit", #selector(MainWindowController.zoomFit(_:)), "0"))
		view.addItem(command("Zoom to Clip", #selector(MainWindowController.zoomToClipAction(_:)), "9"))
		view.addItem(.separator())
		// Amplitude rather than time. ⌥ alongside ⌘ says "the same zoom, the
		// other axis", which is what it is.
		view.addItem(command("Zoom Audio In", #selector(MainWindowController.zoomAudioIn(_:)),
		                     "+", [.command, .option]))
		view.addItem(command("Zoom Audio Out", #selector(MainWindowController.zoomAudioOut(_:)),
		                     "-", [.command, .option]))
		view.addItem(command("Actual Audio Height", #selector(MainWindowController.resetAudioZoom(_:)),
		                     "0", [.command, .option]))
		viewItem.submenu = view
		main.addItem(viewItem)

		let audioItem = NSMenuItem()
		let audio = NSMenu(title: "Audio")
		audio.addItem(command("Align Automatically", #selector(MainWindowController.alignAction(_:)), "l"))
		audio.addItem(.separator())
		// Arrows rather than punctuation: the same two keys on every layout,
		// and the direction is the meaning.
		audio.addItem(command("Nudge Audio Earlier", #selector(MainWindowController.nudgeEarlier(_:)),
		                      "\u{f702}", [.command, .option]))
		audio.addItem(command("Nudge Audio Later", #selector(MainWindowController.nudgeLater(_:)),
		                      "\u{f703}", [.command, .option]))
		audio.addItem(.separator())
		audio.addItem(command("Cycle What You Hear", #selector(MainWindowController.cycleMonitor(_:)), "u"))
		audio.addItem(.separator())
		// With the audio, because that is what it listens to. ⌥⌘T rather than
		// ⌘T, which is already the clip's tags.
		let transcribe = command("Transcribe This Take",
		                         #selector(MainWindowController.transcribeAction(_:)), "t",
		                         [.command, .option])
		transcribe.toolTip = "Reads the audio on this Mac and writes the words beside the take.\n"
			+ "Nothing is uploaded. The answer is kept, so this is asked once."
		audio.addItem(transcribe)
		// Done as part of transcribing, and here as well, because a take that
		// was transcribed before this existed should not have to be listened to
		// again from scratch to get its laughs.
		let sounds = command("Find the Sounds",
		                     #selector(MainWindowController.findSoundsAction(_:)), "")
		sounds.toolTip = "Listens for what is not a word — a laugh, applause, a cough —\n"
			+ "and writes it into the take. On this Mac; nothing is uploaded."
		audio.addItem(sounds)
		audioItem.submenu = audio
		main.addItem(audioItem)

		// The composing window's own verbs. In a menu of their own rather than
		// mixed into File, because they are only ever meaningful there and a
		// permanently grey item in File would be a permanent question.
		let composeItem = NSMenuItem()
		let compose = NSMenu(title: "Compose")
		compose.addItem(command("Render…", #selector(ComposeWindowController.render(_:)), "r", [.command, .shift]))
		compose.addItem(command("Reload from Disk", #selector(ComposeWindowController.reloadProject(_:)), "r"))
		// No key equivalent: ⌘Space is Spotlight's, and a bare space in a menu
		// would be matched before any text field in the program ever saw one.
		// The composing window takes space through its own key monitor.
		compose.addItem(command("Play / Pause", #selector(ComposeWindowController.togglePlay(_:)), ""))
		compose.addItem(.separator())
		// The scene editor. In this menu because it is a thing done to a
		// project, and reachable from the library beside the programme as well
		// — a scene there is double-clicked like anything else in the list.
		compose.addItem(command("Edit Scenes…", #selector(ComposeWindowController.editScene(_:)),
		                        "k", [.command, .shift]))
		composeItem.submenu = compose
		main.addItem(composeItem)

		let windowItem = NSMenuItem()
		let window = NSMenu(title: "Window")
		window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
		window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
		window.addItem(.separator())
		// The keyboard path through the open documents, which the tab bar used
		// to own. It walks them in the order the name's menu lists them:
		// projects, each with its takes under it.
		// One place to be must not mean being unable to be in two: two takes side
		// by side is a real thing to want, and every other gesture in this
		// program swaps in place.
		window.addItem(command("Move to New Window",
		                       #selector(AppDelegate.moveToNewWindow(_:)), "n",
		                       [.command, .option]))
		window.addItem(.separator())
		window.addItem(command("Go to Document…",
		                       #selector(AppDelegate.showDocumentPalette(_:)), "p", [.command, .shift]))
		window.addItem(command("Previous Document",
		                       #selector(AppDelegate.previousDocument(_:)), "[", [.command, .shift]))
		window.addItem(command("Next Document",
		                       #selector(AppDelegate.nextDocument(_:)), "]", [.command, .shift]))
		windowItem.submenu = window
		main.addItem(windowItem)
		NSApp.windowsMenu = window

		let helpItem = NSMenuItem()
		let help = NSMenu(title: "Help")
		let keys = NSMenuItem(title: "Keys", action: #selector(AppDelegate.showShortcuts(_:)), keyEquivalent: "/")
		help.addItem(keys)
		helpItem.submenu = help
		main.addItem(helpItem)

		return main
	}

	/// A menu item aimed down the responder chain at whichever window is key.
	///
	/// `target: nil` is what makes that work: AppKit walks the chain looking for
	/// something that implements the selector, so the front window's controller
	/// gets it and a window that is not there disables the item by itself.
	private static func command(
		_ title: String, _ action: Selector, _ key: String,
		_ modifiers: NSEvent.ModifierFlags = [.command]
	) -> NSMenuItem {
		let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
		item.keyEquivalentModifierMask = modifiers
		return item
	}

	/// A menu item with no key equivalent, for the things that have no room for
	/// one.
	private static func bare(_ title: String, _ action: Selector) -> NSMenuItem {
		NSMenuItem(title: title, action: action, keyEquivalent: "")
	}

	/// Fills Open Recent from the document controller's list.
	final class RecentsMenuFiller: NSObject, NSMenuDelegate {
		static let shared = RecentsMenuFiller()

		func menuNeedsUpdate(_ menu: NSMenu) {
			menu.removeAllItems()
			// Filtered as well as gated on the way in, so takes recorded before
			// that rule existed drop out of the menu rather than lingering in
			// somebody's list for ever.
			let urls = NSDocumentController.shared.recentDocumentURLs
				.filter { $0.pathExtension.lowercased() == "cuttrproj" }
			guard !urls.isEmpty else {
				let empty = NSMenuItem(title: "No Projects Yet", action: nil, keyEquivalent: "")
				empty.isEnabled = false
				menu.addItem(empty)
				return
			}
			// Two files can share a name — a take and a project beside each
			// other usually do — so the ones that collide say which folder they
			// are in, and the ones that do not stay short.
			var counts: [String: Int] = [:]
			for url in urls {
				counts[url.deletingPathExtension().lastPathComponent, default: 0] += 1
			}

			for url in urls {
				let name = url.deletingPathExtension().lastPathComponent
				let folder = url.deletingLastPathComponent().lastPathComponent
				let item = NSMenuItem(
					title: counts[name, default: 0] > 1 ? "\(name)  —  \(folder)" : name,
					action: #selector(AppDelegate.openRecent(_:)), keyEquivalent: "")
				item.representedObject = url
				// The icon says which kind it is without a second column of
				// text: a take and a project are different documents and the
				// names are often the same word.
				let icon = NSWorkspace.shared.icon(forFile: url.path)
				icon.size = NSSize(width: 16, height: 16)
				item.image = icon
				// A file that has moved is still worth listing — its absence is
				// information — but it is not worth pretending it will open.
				item.isEnabled = FileManager.default.fileExists(atPath: url.path)
				menu.addItem(item)
			}
			menu.addItem(.separator())
			menu.addItem(NSMenuItem(
				title: "Clear Menu", action: #selector(AppDelegate.clearRecents(_:)), keyEquivalent: ""))
		}
	}

	/// Fills the Clip menu's Colour submenu from whichever window is front.
	///
	/// A submenu in the menu bar cannot be built once at launch, because it has
	/// to tick the selected clip's colour and there is no selected clip until
	/// somebody makes one. Built when the menu opens, which is the only moment
	/// the answer exists.
	final class ColourMenuFiller: NSObject, NSMenuDelegate {
		static let shared = ColourMenuFiller()

		func menuNeedsUpdate(_ menu: NSMenu) {
			let colour = menu.items.first { $0.identifier?.rawValue == "clip-colour" }
			let tags = menu.items.first { $0.identifier?.rawValue == "clip-tags" }
			guard let controller = AppDelegate.shared?.showing as? MainWindowController else {
				for item in [colour, tags].compactMap({ $0 }) {
					item.submenu = nil
					item.isEnabled = false
				}
				return
			}
			colour?.isEnabled = true
			colour?.submenu = controller.colorMenu(current: controller.selectedClipColor)
			tags?.isEnabled = true
			tags?.submenu = controller.tagsMenu()
		}
	}

	static let shortcutSheet = """
	Playing
	  space        play / pause — with a clip selected, play just that clip
	  J K L        rewind · stop · forward   (⇧ for 4×)
	  ← →          one frame                 (⌥ 0.1 s, ⇧ 1 s)
	  ⌘← ⌘→        previous / next cut mark
	  C            to the top of this clip — again for its end
	  home end     start / end of the take

	Cutting
	  S  or  ⌘B    split here — or close off the clip since the last one
	  double-click a clip's bar to name it in place
	  I O          set in / out
	  ⏎            make a clip from the in/out span —
	               or, with none, jump to the selected clip's start
	  N            rename the selected clip (or double-click its bar)
	  ⌘T           tag it — tags are what a project selects on
	  1…6          choose the colour lane to cut on next
	               (recolour an existing clip from its context menu)
	  ⌫            delete the selected clip
	  esc          drop the in/out span
	  right-click a clip for trim, colour and delete

	The words
	  ⌥⌘T          transcribe this take — on this Mac, nothing uploaded
	  drag across the transcript to set in and out; ⏎ makes it a clip
	  click a word to go there; the word being said is lit as it plays
	  W            name the selected clip after its first words
	  B            end the line before the word the caret is in — again to
	               take it back. For the turn of a conversation the recogniser
	               ran together, where nobody paused
	  type in the pane's field to find a phrase and be taken to it

	Aligning the separate audio
	  A            find the offset automatically
	  [ ]          nudge by 1 ms              (⇧ 10 ms, ⌥ 100 ms)
	  M            cycle what you hear — “Both” is the alignment tool
	  ⌥-drag       slide the audio waveform

	Files
	  ⌘S           save the cut list
	  ⇧⌘Y          versions of the project — every pause in the editing leaves
	               one, on refs/cuttr/saves, and this is the way back to one
	  ⇧⌘I          import subclips from a Resolve EDL or XML
	               (or drop the .edl / .xml on the window)

	Looking
	  F            fit the whole take
	  Z            zoom to the selected clip
	  - =          zoom out / in (also ⌘− and ⌘+, on any keyboard layout)
	  ⌥⌘+ ⌥⌘-      taller / shorter waveform  (⌥⌘0 back to normal)
	  ⌘-scroll     zoom · scroll or swipe to pan
	"""
}
