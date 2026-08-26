import CuttrKit
import Foundation
import Testing
@testable import CuttrCompose
@testable import CuttrRecord

/// The browser cuttr drives, tested where it can be: the command line it
/// builds, the order it looks in, and where the profile lands.
///
/// Nothing here launches anything. Whether Chrome is installed on the machine
/// running the tests is not a fact this suite is allowed to depend on, so the
/// search is asked of a file manager that says what the test wants it to say.
@MainActor @Suite struct BrowserTests {

	/// A file manager that has exactly the applications the test says.
	private final class Installed: FileManager, @unchecked Sendable {
		let there: Set<String>
		init(_ there: [String]) {
			self.there = Set(there)
			super.init()
		}
		override func fileExists(atPath path: String) -> Bool { there.contains(path) }
	}

	private let demo = Recording(name: "install-demo", url: "https://example.com/download")

	@Test func chromeIsLookedForFirst() {
		let all = Installed(Recording.Browser.allCases.map(\.application))
		#expect(Browser.find(in: all)?.kind == .chrome)
	}

	@Test func theNextOneIsUsedWhenChromeIsNotThere() {
		let some = Installed([Recording.Browser.edge.application,
		                      Recording.Browser.chromium.application])
		#expect(Browser.find(in: some)?.kind == .chromium)
	}

	@Test func aNamedBrowserIsTheOnlyOneLookedFor() {
		let all = Installed(Recording.Browser.allCases.map(\.application))
		#expect(Browser.find(.edge, in: all)?.kind == .edge)
		let without = Installed([Recording.Browser.chrome.application])
		#expect(Browser.find(.edge, in: without) == nil,
		        "a browser nobody asked for was used instead")
	}

	/// Nothing is downloaded and nothing is bundled: a browser is a thing the
	/// machine has or has not got, and a video editor that installs one has
	/// misunderstood what it is for. So the refusal names what to install.
	@Test func nothingToDriveIsSaidByName() {
		#expect(Browser.find(in: Installed([])) == nil)
		for kind in Recording.Browser.allCases {
			#expect(Browser.missing.contains(kind.described), Comment(rawValue: kind.described))
		}
	}

	// MARK: - The command line

	private func arguments(_ recording: Recording) -> [String] {
		let browser = Browser(kind: .chrome,
		                      application: URL(fileURLWithPath: "/Applications/Google Chrome.app"))
		return browser.arguments(
			for: recording,
			profile: URL(fileURLWithPath: "/p/.cuttr/browser/install-demo"),
			content: recording.size)
	}

	/// The isolation, which is the whole reason cuttr starts a browser instead
	/// of using the one that is open: a fresh directory is a fresh browser.
	@Test func theProfileIsCuttrsOwn() {
		let said = arguments(demo)
		#expect(said.contains("--user-data-dir=/p/.cuttr/browser/install-demo"))
	}

	/// And it lives inside the project, so a page that needed a cookie accepted
	/// keeps it for that project and does not leak between them.
	@Test func theProfileLivesInTheProject() {
		let at = Browser.profile(for: demo, in: URL(fileURLWithPath: "/films/episode-3"))
		#expect(at.path == "/films/episode-3/.cuttr/browser/install-demo")
	}

	/// The address bar is in the film unless the recording says otherwise —
	/// `--app=` is what takes it away, so its absence is the default.
	@Test func theAddressBarIsThereByDefault() {
		let said = arguments(demo)
		#expect(!said.contains { $0.hasPrefix("--app=") }, "the address bar was hidden")
		#expect(said.last == "https://example.com/download",
		        "the URL is the argument, which is what opens an ordinary window")
	}

	@Test func aBareWindowIsAskedForWithApp() {
		var bare = demo
		bare.chrome = .none
		let said = arguments(bare)
		#expect(said.contains("--app=https://example.com/download"))
		#expect(!said.contains("https://example.com/download"),
		        "the URL was given twice, which opens two windows")
	}

	/// The three things a fresh profile puts on screen, and a recording must
	/// not have in it.
	@Test func aFreshProfileIsToldNotToIntroduceItself() {
		let said = arguments(demo)
		for flag in ["--no-first-run", "--no-default-browser-check",
		             "--hide-crash-restore-bubble"] {
			#expect(said.contains(flag), Comment(rawValue: flag))
		}
	}

	@Test func theSizeIsAskedFor() {
		var big = demo
		big.width = 1600
		big.height = 900
		#expect(arguments(big).contains("--window-size=1600,900"))
	}
}
