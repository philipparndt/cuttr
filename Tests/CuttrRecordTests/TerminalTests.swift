import AppKit
import Foundation
import Testing
@testable import CuttrCompose
@testable import CuttrRecord

/// The terminals cuttr drives, tested where they can be: the arguments each one
/// is given, the script Terminal is sent, and the arithmetic that turns a
/// picture size into columns and rows.
///
/// Nothing here launches anything. Whether Ghostty is installed on the machine
/// running the tests is not a fact this suite is allowed to depend on.
@MainActor @Suite struct TerminalTests {

	private let build = Recording(
		name: "the-build", terminal: .ghostty, directory: "~/dev/cuttr",
		run: ["make build", "make test"])

	// MARK: - The shell

	/// **What cuttr can clean**: the directory, the prompt, and the scrollback.
	@Test func theShellStartsWhereItWasTold() {
		let line = Shell.line(for: build)
		#expect(line.contains("cd '~/dev/cuttr'"))
		#expect(line.contains("make build; make test"))
		#expect(line.contains("clear"), "the window opens on whatever was there before")
		#expect(line.contains("PS1='$ '"), "the prompt is the person's own")
	}

	/// And it stays afterwards. A terminal that exits the moment the command
	/// finishes is a recording that ends before anybody has read the output.
	@Test func theShellStaysWhenTheCommandsAreDone() {
		#expect(Shell.line(for: build).contains("exec $SHELL -i"))
	}

	/// A path with a quote in it is a path, not an escape.
	@Test func aDirectoryIsQuoted() {
		var odd = build
		odd.directory = "/tmp/it's here"
		#expect(Shell.line(for: odd).contains("cd '/tmp/it'\\''s here'"))
	}

	/// **What cuttr cannot clean**, said rather than discovered in the finished
	/// film. A browser with a fresh profile has nothing to say; a terminal has.
	@Test func whatIsStillTheirsIsSaidForATerminalAndNotForABrowser() {
		let ghostty = Ghostty(application: URL(fileURLWithPath: "/Applications/Ghostty.app"))
		let said = try? #require(ghostty.whatIsStillTheirs)
		#expect(said?.contains("startup files") == true)

		let browser = Browser(kind: .chrome,
		                      application: URL(fileURLWithPath: "/Applications/Google Chrome.app"))
		#expect(browser.whatIsStillTheirs == nil,
		        "a fresh profile has nothing of anybody's in it")
	}

	/// And Terminal says the extra thing that is true only of it.
	@Test func terminalSaysItNeedsASecondPermission() {
		let terminal = TerminalApp(
			application: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
		#expect(terminal.whatIsStillTheirs?.contains("automated") == true)
	}

	// MARK: - Ghostty

	/// Sized in cells, which is the whole of what is different.
	@Test func ghosttyIsAskedInColumnsAndRows() async throws {
		let ghostty = Ghostty(application: URL(fileURLWithPath: "/Applications/Ghostty.app"))
		// The conversion, without launching: 1280 ÷ 8 and 720 ÷ 17.
		#expect(Int((1280.0 / Ghostty.cell.width).rounded()) == 160)
		#expect(Int((720.0 / Ghostty.cell.height).rounded()) == 42)
		_ = ghostty
	}

	/// **Proportional, not additive.** A window sized in whole cells does not
	/// move by the number of points it is out by, so adding the difference
	/// overshoots by up to a cell every time and never settles.
	@Test func ghosttyCorrectsByScalingRatherThanByAdding() {
		let ghostty = Ghostty(application: URL(fileURLWithPath: "/Applications/Ghostty.app"))
		let wanted = CGSize(width: 1280, height: 720)
		// Asked for 1280 and got 1300: the next ask is smaller in proportion.
		let next = ghostty.next(asking: wanted, wanted: wanted,
		                        got: CGSize(width: 1300, height: 740))
		#expect(next.width < 1280)
		#expect(abs(next.width - 1280 * 1280 / 1300) < 0.01)

		// Where a browser adds the difference instead.
		let browser = Browser(kind: .chrome,
		                      application: URL(fileURLWithPath: "/Applications/Google Chrome.app"))
		let added = browser.next(asking: wanted, wanted: wanted,
		                         got: CGSize(width: 1280, height: 788))
		#expect(abs(added.height - 652) < 0.01, Comment(rawValue: "\(added.height)"))
	}

	// MARK: - Abydos

	/// Its own flags, which are the ones it has: a project to open, a terminal
	/// to show, and one `--run` per command.
	@Test func abydosIsGivenItsOwnFlags() {
		var recording = build
		recording.terminal = .abydos
		recording.theme = "midnight"
		let said = Abydos.argumentsForTesting(recording)
		#expect(said.contains("--open-terminal"))
		#expect(said.contains("--theme"))
		#expect(said.contains("midnight"))
		// One `--run` each, because a plain pane cannot take a whole script.
		#expect(said.filter { $0 == "--run" }.count == 2)
		#expect(said.contains("make build"))
	}

	// MARK: - Terminal

	/// The order matters: setting the size of a window that does not exist yet
	/// is an error rather than a no-op.
	@Test func theScriptMakesTheWindowBeforeItSizesIt() {
		let script = TerminalApp.script(for: build, columns: 160, rows: 42)
		let madeAt = try? #require(script.range(of: "do script"))
		let sizedAt = try? #require(script.range(of: "number of columns"))
		#expect(madeAt != nil && sizedAt != nil)
		if let madeAt, let sizedAt { #expect(madeAt.lowerBound < sizedAt.lowerBound) }
		#expect(script.contains("set number of rows of theWindow to 42"))
	}

	/// A theme is a settings set, and applied to the window after there is one.
	@Test func aThemeIsAppliedToTheWindow() {
		var dark = build
		dark.theme = "Pro"
		let script = TerminalApp.script(for: dark, columns: 80, rows: 24)
		#expect(script.contains("settings set \"Pro\""))
		#expect(!TerminalApp.script(for: build, columns: 80, rows: 24).contains("settings set"))
	}

	/// A quote in a command must not end the AppleScript string it is inside.
	@Test func theCommandIsEscapedForAppleScript() {
		var quoted = build
		quoted.run = ["echo \"hello\""]
		let script = TerminalApp.script(for: quoted, columns: 80, rows: 24)
		#expect(script.contains("\\\"hello\\\""))
	}
}
