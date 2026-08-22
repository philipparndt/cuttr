import AppKit

/// The projects somebody has had open, and what to call each one in a menu.
///
/// **Why this is a type and not four lines in a menu delegate.** Three places
/// list recent projects — the File menu's Open Recent, the Dock menu, and the
/// document switcher — and the interesting part is not the list but the
/// *naming*: two projects called `film.cuttrproj` in two different folders are
/// two rows saying the same word, and a row somebody cannot tell from the one
/// under it is a row they have to open to identify. Worked out once, so the
/// three agree by construction rather than by being kept in step.
///
/// Only projects are in here at all, because only projects are ever remembered
/// — see ``AppDelegate/remember(_:)``. A list with every take in it buries the
/// thing somebody wants to reopen under the material it is made of.
@MainActor
enum RecentProjects {

	struct Entry {
		var url: URL
		/// What to put on the row: the name, and the folder as well when
		/// another recent project shares that name.
		var title: String
		/// The folder on its own, for a caller with somewhere to put it.
		var folder: String
		/// A file that has moved is still worth listing — its absence is
		/// information — but it is not worth pretending it will open.
		var exists: Bool
	}

	/// The list, most recent first. `limit` of nought is all of them.
	static func entries(limit: Int = 0) -> [Entry] {
		entries(from: NSDocumentController.shared.recentDocumentURLs, limit: limit)
	}

	/// The same, from a list handed in.
	///
	/// Separate so the naming can be checked without `NSDocumentController`,
	/// which in a test process will not take a URL at all — and the naming is
	/// the only part of this worth checking.
	static func entries(from remembered: [URL], limit: Int = 0) -> [Entry] {
		// Filtered here as well as gated on the way in, so takes recorded
		// before that rule existed drop out rather than lingering in somebody's
		// list for ever.
		let urls = remembered.filter { $0.pathExtension.lowercased() == "cuttrproj" }

		// Counted across the whole list rather than across what a caller is
		// about to show. A name that collides is ambiguous whether or not its
		// twin fits in the first eight rows, and a row that says which folder
		// it is in is never the wrong answer.
		var counts: [String: Int] = [:]
		for url in urls {
			counts[url.deletingPathExtension().lastPathComponent, default: 0] += 1
		}

		let wanted = limit > 0 ? Array(urls.prefix(limit)) : urls
		return wanted.map { url in
			let name = url.deletingPathExtension().lastPathComponent
			let folder = url.deletingLastPathComponent().lastPathComponent
			return Entry(
				url: url,
				// The ones that collide say which folder they are in, and the
				// ones that do not stay short. An em dash rather than a slash:
				// this is a name and a place, not a path somebody could type.
				title: counts[name, default: 0] > 1 ? "\(name)  —  \(folder)" : name,
				folder: folder,
				exists: FileManager.default.fileExists(atPath: url.path))
		}
	}

	/// One row, with the file's own icon.
	///
	/// The icon says which kind of thing it is without a second column of text,
	/// which matters most in the Dock menu — where there is no room for one.
	static func item(for entry: Entry, action: Selector, target: AnyObject?) -> NSMenuItem {
		let item = NSMenuItem(title: entry.title, action: action, keyEquivalent: "")
		item.representedObject = entry.url
		item.target = target
		let icon = NSWorkspace.shared.icon(forFile: entry.url.path)
		icon.size = NSSize(width: 16, height: 16)
		item.image = icon
		item.isEnabled = entry.exists
		// The whole path in the tooltip, because the folder alone is enough to
		// tell two rows apart and not always enough to say where either is.
		item.toolTip = entry.url.path
		return item
	}

	/// The Dock icon's own list, or nothing when there is nothing to put in it.
	///
	/// Only projects that are still where they were: Open Recent can afford to
	/// list one that has moved, because saying it is gone is information. A
	/// Dock menu is a shortcut, and a row that cannot be pressed is not one.
	static func dockMenu(for entries: [Entry], action: Selector,
	                     target: AnyObject?) -> NSMenu? {
		let there = entries.filter(\.exists)
		guard !there.isEmpty else { return nil }
		let menu = NSMenu()
		for entry in there { menu.addItem(item(for: entry, action: action, target: target)) }
		return menu
	}
}
