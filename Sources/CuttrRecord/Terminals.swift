import AppKit
import CuttrCompose
import Foundation

/// What every terminal cuttr drives has to say for itself.
///
/// **The thing none of them can promise.** A browser gets `--user-data-dir` and
/// the frame is genuinely cuttr's: no bookmarks, no extensions, no account. A
/// terminal has no such flag. Its prompt carries the person's username, their
/// hostname and their working directory — the same problem as a bookmarks bar
/// and worse, because it is in every frame rather than at the top of the first.
///
/// What cuttr does about it: start in a named directory, with a prompt of its
/// own, in a window with no scrollback. What it will not do: stop the person's
/// startup files from running. A shell started without them is not the shell
/// they use, and a screencast of a shell nobody has is a lie in the other
/// direction — so the limit is stated instead, and stated before the recording
/// rather than found in it.
enum Shell {

	/// The prompt cuttr records with: a dollar and a space.
	///
	/// Nothing else. Not a directory — the recording named the directory, and
	/// putting it in every line spends the width somebody wanted for the
	/// command. Not a hostname, which is the whole thing being avoided.
	static let prompt = "$ "

	/// The command a terminal is asked to run.
	///
	/// One shell invocation that sets the prompt, changes directory, runs
	/// whatever the recording asked for, and then stays — because a terminal
	/// that exits the moment the command finishes is a recording that ends
	/// before anybody has read the output.
	static func line(for recording: Recording) -> String {
		var parts: [String] = []
		if let directory = recording.directory, !directory.isEmpty {
			parts.append("cd \(quoted(directory))")
		}
		parts.append(contentsOf: recording.run)
		// `-i` after the setup so the shell is interactive and the person can
		// carry on typing, which is what a screencast of a terminal is for.
		let setup = parts.isEmpty ? "" : parts.joined(separator: "; ") + "; "
		return "PS1='\(prompt)' PROMPT='\(prompt)'; clear; \(setup)exec $SHELL -i"
	}

	/// Single-quoted for a shell, with the one escape that needs doing.
	static func quoted(_ text: String) -> String {
		"'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
	}

	/// Said on the panel before the first recording, per terminal, because only
	/// the terminal knows.
	static let stillTheirs = "Your shell's own startup files still run, so an "
		+ "alias, a version manager's banner or a prompt that draws itself will be "
		+ "in the film. cuttr sets a plain prompt and starts in the directory you "
		+ "name; the rest of your setup is yours."
}

/// Ghostty.
///
/// Sized in cells, which is the whole of what is different: `--window-width` and
/// `--window-height` count columns and rows, and how wide a column is depends on
/// a font this program has no business knowing about. So it guesses, and the
/// ask-measure-correct loop puts it right — which is why ``next(asking:…)`` is
/// proportional here rather than additive.
@MainActor
struct Ghostty: Sitter {
	let application: URL
	var described: String { "Ghostty" }
	var whatIsStillTheirs: String? { Shell.stillTheirs }

	/// A guess at a cell, for the first ask only. Roughly a 13-point monospace,
	/// which is what a terminal is set to unless somebody has changed it — and
	/// if they have, the second ask is the right one.
	static let cell = CGSize(width: 8, height: 17)

	func open(_ recording: Recording, in project: URL,
	          asking: CGSize) async throws -> NSRunningApplication {
		let columns = max(20, Int((asking.width / Self.cell.width).rounded()))
		let rows = max(6, Int((asking.height / Self.cell.height).rounded()))
		var arguments = [
			"--window-width=\(columns)",
			"--window-height=\(rows)",
		]
		// The palette to record in, so the film does not depend on whoever's
		// settings this machine happens to have.
		if let theme = recording.theme { arguments.append("--theme=\(theme)") }
		// Ghostty's own way of saying "run this": everything after `-e` is the
		// command.
		arguments += ["-e", "/bin/sh", "-c", Shell.line(for: recording)]
		return try await launch(application, arguments: arguments)
	}

	/// Proportional rather than additive.
	///
	/// A window sized in cells does not move by the number of points it is out
	/// by — it moves by whole cells — so adding the difference overshoots by up
	/// to a cell every time and never settles. Scaling the ask by how wrong it
	/// was lands on the right number of cells in one more round.
	func next(asking: CGSize, wanted: CGSize, got: CGSize) -> CGSize {
		guard got.width > 1, got.height > 1 else { return asking }
		return CGSize(width: asking.width * wanted.width / got.width,
		              height: asking.height * wanted.height / got.height)
	}
}

/// Abydos, which takes a window size directly and is therefore the one that
/// converges in a single round.
@MainActor
struct Abydos: Sitter {
	let application: URL
	var described: String { "Abydos" }
	var whatIsStillTheirs: String? { Shell.stillTheirs }

	func open(_ recording: Recording, in project: URL,
	          asking: CGSize) async throws -> NSRunningApplication {
		var arguments = ["--open-terminal"]
		if let directory = recording.directory, !directory.isEmpty {
			arguments += ["--project", (directory as NSString).expandingTildeInPath]
		}
		// Abydos has the flag for exactly this reason and says so: a capture
		// should not depend on whoever's settings the machine has.
		if let theme = recording.theme { arguments += ["--theme", theme] }
		// One `--run` per command, which is how abydos takes them: a plain pane
		// cannot be handed a whole script at once.
		for command in recording.run { arguments += ["--run", command] }
		return try await launch(application, arguments: arguments)
	}

	/// For the tests: the command line, without launching anything.
	static func argumentsForTesting(_ recording: Recording) -> [String] {
		var out = ["--open-terminal"]
		if let directory = recording.directory, !directory.isEmpty {
			out += ["--project", (directory as NSString).expandingTildeInPath]
		}
		if let theme = recording.theme { out += ["--theme", theme] }
		for command in recording.run { out += ["--run", command] }
		return out
	}
}

/// Terminal, driven by AppleScript.
///
/// **It costs a second permission**, and that is the whole reason this one is
/// different. Automating another application on a hardened runtime needs the
/// automation entitlement *and* a consent prompt — a different dialogue, about a
/// different thing, at a different moment from the screen recording one.
///
/// Supported anyway, because it is the terminal every Mac has and the one a
/// viewer is most likely to recognise. Asked for only when a recording names it,
/// so somebody who uses Ghostty is never asked at all.
@MainActor
struct TerminalApp: Sitter {
	let application: URL
	var described: String { "Terminal" }
	var whatIsStillTheirs: String? {
		Shell.stillTheirs + " Terminal also needs permission to be automated, "
			+ "which macOS asks for the first time cuttr opens it."
	}

	static let cell = CGSize(width: 7, height: 15)

	func open(_ recording: Recording, in project: URL,
	          asking: CGSize) async throws -> NSRunningApplication {
		let running = try await launch(application, arguments: [])
		let columns = max(20, Int((asking.width / Self.cell.width).rounded()))
		let rows = max(6, Int((asking.height / Self.cell.height).rounded()))
		try run(Self.script(for: recording, columns: columns, rows: rows))
		return running
	}

	func next(asking: CGSize, wanted: CGSize, got: CGSize) -> CGSize {
		guard got.width > 1, got.height > 1 else { return asking }
		return CGSize(width: asking.width * wanted.width / got.width,
		              height: asking.height * wanted.height / got.height)
	}

	/// A window, a size, and the command — in that order, because setting the
	/// size of a window that does not exist yet is an error rather than a
	/// no-op.
	static func script(for recording: Recording, columns: Int, rows: Int) -> String {
		let command = Shell.line(for: recording)
			.replacingOccurrences(of: "\\", with: "\\\\")
			.replacingOccurrences(of: "\"", with: "\\\"")
		// Terminal calls a theme a settings set, and applying one to a window
		// that does not exist yet is an error rather than a no-op — so it goes
		// after the window, with the size.
		let palette = recording.theme.map {
			"\n\tset current settings of theWindow to settings set \"\($0)\""
		} ?? ""
		return """
		tell application "Terminal"
			activate
			set made to do script "\(command)"
			set theWindow to window 1
			set number of columns of theWindow to \(columns)
			set number of rows of theWindow to \(rows)\(palette)
		end tell
		"""
	}

	private func run(_ source: String) throws {
		var trouble: NSDictionary?
		NSAppleScript(source: source)?.executeAndReturnError(&trouble)
		if let trouble {
			throw Screencast.Trouble.cannotWrite(
				(trouble[NSAppleScript.errorMessage] as? String)
					?? "Terminal would not take the command")
		}
	}
}
