import AppKit
import CuttrKit
import UniformTypeIdentifiers

public extension Notification.Name {
	/// A meme was added to a project. The `object` is the reference a project
	/// would write for it.
	///
	/// A notification rather than a callback wired through the window, and for
	/// a reason worth stating: the panel is opened from the menu, through the
	/// responder chain, and finishes minutes later in a folder the library is
	/// already watching. The library reloads itself either way — what this adds
	/// is the reveal, which is the difference between "it is in there
	/// somewhere" and having it selected under the pointer.
	static let cuttrMemeAdded = Notification.Name("de.rnd7.cuttr.memeAdded")
}

/// Finding a meme, from the project window.
///
/// In an extension of its own file rather than in the window controller,
/// because it is a complete thing: ask for a project to exist, put a sheet up,
/// download what comes back into the project's own folders, and add the take.
/// The window controller does not need to know any of it.
public extension ComposeWindowController {

	@objc func findMeme(_ sender: Any?) {
		guard let window, let content = window.contentView else { return }
		// Every path in a project is relative to the project file, so there has
		// to be a project file. The same rule as adding a take, and the same
		// moment it is asked.
		guard saveBeforeAddingMaterial() else { return }

		MemePanel.present(over: content, download: { [weak self] result in
			guard let self, let base = self.composeDocument.baseURL else {
				throw MemeError.noVideo(result.title)
			}
			// Downloads next to the project, take files where the project's
			// other takes go — so a meme is filed the way everything else in
			// the project is, and the whole folder still copies to another disk.
			// Where a new take goes is the document's decision and there is one
			// of it, so it is asked rather than guessed at a second time here.
			let takes = self.composeDocument.placeForNewTake(named: "meme")?
				.deletingLastPathComponent()
				?? base.appendingPathComponent("takes", isDirectory: true)
			let downloaded = try await MemeDownload.fetch(result, project: base, takes: takes)
			self.composeDocument.addTake(downloaded.take)
			return downloaded.slug
		}, onAdded: { reference in
			NotificationCenter.default.post(name: .cuttrMemeAdded, object: reference)
		})
	}

	/// A project has to be on disk before anything can be added to it.
	///
	/// The window controller has this too, privately, and this is deliberately
	/// not a call into it: one of the two will move eventually, and a meme
	/// arriving is not a take being cut.
	private func saveBeforeAddingMaterial() -> Bool {
		if composeDocument.url != nil { return true }
		let panel = NSSavePanel()
		panel.allowedContentTypes = [UTType(filenameExtension: "cuttrproj") ?? .plainText]
		panel.nameFieldStringValue = "programme.cuttrproj"
		panel.message = "Save the project first — a meme is filed next to it."
		guard panel.runModal() == .OK, let url = panel.url else { return false }
		do {
			try composeDocument.saveAs(url)
			AppDelegate.remember(url)
			return true
		} catch {
			if let window { NSAlert(error: error).beginSheetModal(for: window) }
			return false
		}
	}
}

/// Settings, from anywhere.
///
/// On the application delegate, which is the last thing in the responder chain,
/// so ⌘, works whichever window is in front and whether or not there is one.
extension AppDelegate {

	@objc func showSettings(_ sender: Any?) {
		if let window = NSApp.keyWindow, let content = window.contentView {
			SettingsSheet.present(over: content)
			return
		}
		// No window to hang a sheet on — which happens once every window has
		// been closed. A sheet needs a parent, so this one becomes a window.
		// Nothing here holds it: AppKit keeps a window that is on screen, and
		// it goes when it is closed, which is exactly the lifetime wanted.
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 260),
		                      styleMask: [.titled, .closable], backing: .buffered, defer: false)
		window.contentViewController = SettingsSheet()
		window.title = "Settings"
		window.isReleasedWhenClosed = false
		window.center()
		window.makeKeyAndOrderFront(nil)
	}
}
