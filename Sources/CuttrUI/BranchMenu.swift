import AppKit

/// The menu behind the capsule's right half: where else this repository can be
/// opened, and which branch it is on.
///
/// Actions first, then the branches, because the actions are what somebody
/// reaches for most: cuttr is not a git client and never will be, so the useful
/// thing it can do about a repository is hand it to something that is.
///
/// Everything here is conditional on being real. No Fork row on a machine
/// without Fork, no host row for a remote that is a path on a disk, no menu at
/// all for a folder that is not a work tree — the capsule does not draw its
/// right half in that case either. A menu item that cannot work is worse than an
/// absent one.
@MainActor
public enum BranchMenu {

	/// Whether an open document would be left holding a stale file if the work
	/// tree moved under it. Asked by the window, which is the only thing that
	/// knows what is open.
	public static var documentsInTheWay: ((URL) -> [String])?

	/// Builds the menu for a work tree, or `nil` when there is nothing to say.
	public static func menu(for root: URL, branch: String?) -> NSMenu? {
		let menu = NSMenu()
		menu.autoenablesItems = false

		// First, and above the separator, because it is the one thing in here
		// somebody presses to *do* something rather than to go and look at
		// something. Absent rather than disabled where there is nowhere to send
		// to: plenty of repositories are one person's and never leave the
		// machine, and a greyed-out Share on one of those is a question nobody
		// asked.
		if GitRemote(root: root).hasOrigin() {
			let share = NSMenuItem(title: "Share…", action: #selector(Target.share(_:)),
			                       keyEquivalent: "")
			share.target = Target.shared
			share.image = NSImage(systemSymbolName: "arrow.trianglehead.2.clockwise",
			                      accessibilityDescription: nil)
			share.toolTip = "Send your changes and bring back everybody else's"
			menu.addItem(share)
			menu.addItem(.separator())
		}

		var handedOff = false
		if let fork = Handoff.fork.applicationURL() {
			menu.addItem(handoff("Open in Fork", root, fork, Handoff.fork.icon()))
			handedOff = true
		}
		if let abydos = Handoff.abydos.applicationURL() {
			menu.addItem(handoff("Open in Abydos", root, abydos, Handoff.abydos.icon()))
			handedOff = true
		}
		if let forge = GitRepository.forge(in: root) {
			let item = NSMenuItem(title: "Open on \(forge.displayName)", action: nil,
			                      keyEquivalent: "")
			item.submenu = hostMenu(forge, branch: branch)
			item.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
			menu.addItem(item)
			handedOff = true
		}
		if handedOff { menu.addItem(.separator()) }

		let branches = GitRepository.branches(in: root)
		// A branch with nothing committed on it has no ref, so `git branch`
		// cannot list it — and it is still the branch this work tree is on.
		let unborn = branch.flatMap { branches.contains($0) ? nil : $0 }
		if let unborn {
			let item = NSMenuItem(title: unborn, action: nil, keyEquivalent: "")
			item.state = .on
			item.isEnabled = false
			item.toolTip = "No commits yet"
			menu.addItem(item)
		}

		// Why a checkout may not be offered, worked out once for the whole menu.
		let blocked = documentsInTheWay?(root) ?? []
		for name in branches {
			let item = NSMenuItem(title: name, action: #selector(Target.checkout(_:)),
			                      keyEquivalent: "")
			item.state = name == branch ? .on : .off
			if name == branch {
				// Checking out the branch you are on is nothing.
				item.isEnabled = false
			} else if !blocked.isEmpty {
				item.isEnabled = false
				// Said on the row rather than in an alert after the fact: a
				// checkout rewrites the take files this program has open, and a
				// take window holds its cuts in memory and never re-reads. The
				// stale ones would be written back over the branch's own.
				item.toolTip = "Close \(blocked.joined(separator: ", ")) first — "
					+ "a checkout rewrites the files they are holding"
			} else {
				item.target = Target.shared
				item.representedObject = Checkout(root: root, branch: name)
			}
			menu.addItem(item)
		}

		return menu.items.isEmpty ? nil : menu
	}

	private static func handoff(_ title: String, _ root: URL, _ application: URL,
	                            _ icon: NSImage?) -> NSMenuItem {
		let item = NSMenuItem(title: title, action: #selector(Target.open(_:)), keyEquivalent: "")
		item.target = Target.shared
		item.representedObject = Open(application: application, folder: root)
		item.image = icon
		return item
	}

	/// What there is to look at on the host.
	///
	/// Every entry twice: the plain one, and an alternate under `⌥` that copies
	/// the address instead of opening it. Half the time a link is wanted for a
	/// message rather than for a browser tab, and `⌥` is where a Mac user
	/// already looks for the variant of a command.
	private static func hostMenu(_ forge: GitRepository.Forge, branch: String?) -> NSMenu {
		let menu = NSMenu()
		menu.autoenablesItems = false
		var entries: [(String, URL?)] = []
		if let branch {
			entries.append(("This Branch", forge.branch(branch)))
			entries.append(("Commits", forge.commits(on: branch)))
		}
		entries.append(("Pull Requests", forge.pullRequests))
		entries.append(("Repository Home", forge.home))

		for (title, url) in entries {
			guard let url else { continue }
			let open = NSMenuItem(title: title, action: #selector(Target.link(_:)),
			                      keyEquivalent: "")
			open.target = Target.shared
			open.representedObject = url
			menu.addItem(open)

			let copy = NSMenuItem(title: "Copy Link to \(title)",
			                      action: #selector(Target.copyLink(_:)), keyEquivalent: "")
			copy.target = Target.shared
			copy.representedObject = url
			copy.keyEquivalentModifierMask = .option
			copy.isAlternate = true
			menu.addItem(copy)
		}
		return menu
	}

	// MARK: - The applications this can hand a folder to

	/// An application that knows what to do with a repository folder.
	public struct Handoff {
		public var bundleIdentifier: String
		public var conventionalPath: String

		public static let fork = Handoff(bundleIdentifier: "com.DanPristupov.Fork",
		                                 conventionalPath: "/Applications/Fork.app")
		public static let abydos = Handoff(bundleIdentifier: "de.rnd7.ideai",
		                                   conventionalPath: "/Applications/Abydos.app")

		/// By bundle identifier first, so a copy outside `/Applications` is
		/// still found, with the conventional path as a fallback.
		public func applicationURL() -> URL? {
			if let url = NSWorkspace.shared
				.urlForApplication(withBundleIdentifier: bundleIdentifier) {
				return url
			}
			let conventional = URL(fileURLWithPath: conventionalPath)
			return FileManager.default.fileExists(atPath: conventional.path) ? conventional : nil
		}

		public var isInstalled: Bool { applicationURL() != nil }

		/// The application's own icon, so the row reads as a handoff to it.
		public func icon() -> NSImage? {
			guard let url = applicationURL() else { return nil }
			let image = NSWorkspace.shared.icon(forFile: url.path)
			image.size = NSSize(width: 16, height: 16)
			return image
		}
	}

	private struct Open {
		let application: URL
		let folder: URL
	}

	private struct Checkout {
		let root: URL
		let branch: String
	}

	/// Somebody moved the work tree. Whatever is open on it should re-read.
	public static let repositoryChanged = Notification.Name("cuttr.repositoryChanged")

	@MainActor private final class Target: NSObject {
		static let shared = Target()

		@objc func open(_ sender: NSMenuItem) {
			guard let request = sender.representedObject as? Open else { return }
			let configuration = NSWorkspace.OpenConfiguration()
			configuration.activates = true
			NSWorkspace.shared.open([request.folder], withApplicationAt: request.application,
			                        configuration: configuration) { _, _ in }
		}

		@objc func link(_ sender: NSMenuItem) {
			guard let url = sender.representedObject as? URL else { return }
			NSWorkspace.shared.open(url)
		}

		@objc func copyLink(_ sender: NSMenuItem) {
			guard let url = sender.representedObject as? URL else { return }
			NSPasteboard.general.clearContents()
			NSPasteboard.general.setString(url.absoluteString, forType: .string)
		}

		/// Sent up the responder chain rather than done here, so that the
		/// capsule and the File menu are one implementation and not two. The
		/// window that is in front is the one holding the project.
		@objc func share(_ sender: NSMenuItem) {
			NSApp.sendAction(#selector(AppDelegate.shareProject(_:)), to: nil, from: sender)
		}

		@objc func checkout(_ sender: NSMenuItem) {
			guard let request = sender.representedObject as? Checkout else { return }
			if let problem = GitRepository.checkout(request.branch, in: request.root) {
				let alert = NSAlert()
				alert.messageText = "Could not switch to \(request.branch)"
				alert.informativeText = problem
				alert.runModal()
				return
			}
			NotificationCenter.default.post(name: BranchMenu.repositoryChanged,
			                                object: request.root)
		}
	}
}
