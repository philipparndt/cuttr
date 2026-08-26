import CuttrCompose
import Foundation

/// A browser that is cuttr's rather than anybody's.
///
/// **Why not drive the browser somebody already has open.** It has their
/// bookmarks in it, their extensions, their accounts and their notifications,
/// and every one of those is in the frame the moment it is recorded. Closing it
/// afterwards would close their tabs. A tool that touches somebody's own browser
/// session to make a film is a tool nobody runs twice.
///
/// So cuttr starts one of its own, with `--user-data-dir` pointing inside the
/// project. That flag is the whole of the isolation and it is a supported one
/// rather than a trick: a fresh directory is a fresh browser, with no bookmarks,
/// no extensions, no history and no account. Kept inside the project rather than
/// somewhere shared, so a page that needed a cookie accepted or a login done
/// keeps it for that project and does not leak between them.
public struct Browser: Sendable {

	/// Which browser, and where it is.
	public let kind: Recording.Browser
	public let application: URL

	public init(kind: Recording.Browser, application: URL) {
		self.kind = kind
		self.application = application
	}

	/// The binary inside the bundle. Started directly rather than through
	/// `open`, because a recording has to be able to close the browser it
	/// opened and `open` hands back no process to close.
	public var executable: URL {
		application.appendingPathComponent("Contents/MacOS")
			.appendingPathComponent(Self.binary(for: kind))
	}

	static func binary(for kind: Recording.Browser) -> String {
		switch kind {
		case .chrome: return "Google Chrome"
		case .chromium: return "Chromium"
		case .edge: return "Microsoft Edge"
		}
	}

	/// The first of the browsers cuttr drives that is installed, or the one
	/// asked for.
	///
	/// Chrome, then Chromium, then Edge — the order they are likely to be
	/// there, and all three take the same flags because all three are Chromium.
	/// Nothing is downloaded and nothing is bundled: a browser is a thing the
	/// machine has or has not got, and a video editor that installs one has
	/// misunderstood what it is for.
	public static func find(_ wanted: Recording.Browser? = nil,
	                        in manager: FileManager = .default) -> Browser? {
		for kind in wanted.map { [$0] } ?? Recording.Browser.allCases {
			let at = URL(fileURLWithPath: kind.application)
			if manager.fileExists(atPath: at.path) { return Browser(kind: kind, application: at) }
		}
		return nil
	}

	/// What to say when there is none.
	public static var missing: String {
		"No browser to record. cuttr drives "
			+ Recording.Browser.allCases.map(\.described).joined(separator: ", ")
			+ " — install one of them."
	}

	/// The command line for a recording.
	///
	/// Every flag here is load-bearing and none of it is clever.
	///
	/// - `--user-data-dir` is the isolation, and the reason there is nothing of
	///   anybody's in the frame.
	/// - `--window-size` is the size, given as the *content* size — the outer
	///   window is that plus the chrome, and which of the two cuttr wants is
	///   settled by measuring the captured frame rather than by believing this.
	/// - `--window-position` puts it somewhere predictable rather than cascaded
	///   from wherever the last window was.
	/// - `--no-first-run`, `--no-default-browser-check` and
	///   `--hide-crash-restore-bubble` are the three things a fresh profile puts
	///   on screen and a recording must not have in it.
	/// - `--app=` is the *only* one that is conditional: it opens a window with
	///   no tab strip and no address bar, which is what `chrome: none` asks for.
	///   Without it the address bar is in the film, which is the default,
	///   because a screencast that does not say where it is has to say it in
	///   words instead.
	public func arguments(for recording: Recording, profile: URL,
	                      content: CGSize) -> [String] {
		var out = [
			"--user-data-dir=\(profile.path)",
			"--window-size=\(Int(content.width)),\(Int(content.height))",
			"--window-position=0,0",
			"--no-first-run",
			"--no-default-browser-check",
			"--hide-crash-restore-bubble",
			"--disable-session-crashed-bubble",
			// A fresh profile asks to be the default browser, offers to sign
			// in, and shows what is new. None of that is in a screencast.
			"--disable-features=Translate,MediaRouter",
			"--no-service-autorun",
			"--disable-background-networking",
		]
		switch recording.chrome {
		case .none:
			out.append("--app=\(recording.url)")
		case .bar:
			out.append(recording.url)
		}
		return out
	}

	/// Where a project keeps the profile for a recording.
	///
	/// Inside the project's own `.cuttr/`, beside the baked components, because
	/// it is a fact about this project's recordings and not about this machine.
	public static func profile(for recording: Recording, in project: URL) -> URL {
		project.appendingPathComponent(".cuttr/browser", isDirectory: true)
			.appendingPathComponent(recording.name, isDirectory: true)
	}
}
