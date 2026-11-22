import AppKit
import CuttrChat
import CuttrCompose
import CuttrKit

/// What the assistant needs of the application: which documents there are, and
/// the three things done to them that are not done *in* them.
///
/// A protocol so the tools can be run against two documents a test made,
/// without an application around them.
@MainActor
protocol AssistantDesk: AnyObject {
	var documents: [DocumentEditor] { get }
	var showing: DocumentEditor? { get }
	func bring(_ document: DocumentEditor)
	func openFile(_ url: URL)
	func saveEverything() -> SaveReport
}

extension AppDelegate: AssistantDesk {
	func bring(_ document: DocumentEditor) { reveal(document) }
	func openFile(_ url: URL) { openDocument(url) }
}

/// The app's functions, as tools.
///
/// **The files are the interface, here as everywhere else.** A take and a
/// project are text, and everything somebody can do to a cut is a change to one
/// of the two — a clip trimmed, a sound moved two seconds later, a caption
/// reworded. So the assistant is not given eighty verbs that each change one
/// field. It reads a document as the file would say it and hands back the text
/// it wants, and that lands in the open document as one step: visible, undone
/// by ⌘Z, and written exactly as if a person had made the edit.
///
/// Around that, the things that are not in a file: where the playhead is, which
/// document is on screen, and every command in the menu bar, by name — which
/// is how "all of the app" is kept true without this list having to be kept in
/// step with the menus by hand.
@MainActor
final class AssistantTools: ChatToolHost {

	private weak var desk: AssistantDesk?
	/// The menu bar. Asked for each time: it does not exist until the
	/// application has launched, and a test hands over one it built.
	private let menu: @MainActor () -> NSMenu?

	init(desk: AssistantDesk?, menu: (@MainActor () -> NSMenu?)? = nil) {
		self.desk = desk
		self.menu = menu ?? { NSApp?.mainMenu }
	}

	private struct Refusal: Error { let text: String }

	// MARK: - What there is

	private static let document = ToolDefinition.Parameter.string(
		"Which document: its name (“take-01”), file name or path. Left out: the one on screen.")
	private static let summary = ToolDefinition.Parameter.string(
		"A few words naming the change, shown in the Undo menu — “Move music later”.")

	let tools: [ToolDefinition] = [
		ToolDefinition("get_context",
			"What is open in cuttr and what is on screen: every document with its path, the takes of each project, playheads, the selection, the sounds and where they play. Start here."),
		ToolDefinition("reference",
			"cuttr's own documentation of its two file formats and its features. Without a topic: the list of sections. With one: that section. Read the section before writing syntax you have not seen in the file.",
			[("topic", .string("A section heading or part of one — “Sounds”, “cut list”, “Bubbles”."))]),
		ToolDefinition("read_document",
			"The text of a take (.cuttr) or a project (.cuttrproj) as it stands now, unsaved changes included.",
			[("document", document)]),
		ToolDefinition("edit_document",
			"Changes a take or a project by replacing a piece of its text. `old` must be in the document exactly as read_document showed it. One undo step. The result says what the document now is, or why the text was refused.",
			[("document", document),
			 ("old", .string("The text to replace, exactly as it stands.")),
			 ("new", .string("What goes there instead.")),
			 ("replace_all", .boolean("Replace every occurrence rather than requiring exactly one.")),
			 ("summary", summary)],
			required: ["old", "new"]),
		ToolDefinition("write_document",
			"Replaces the whole text of a take or a project. For changes too scattered for edit_document. One undo step.",
			[("document", document), ("text", .string("The whole file.")), ("summary", summary)],
			required: ["text"]),
		ToolDefinition("add_clip",
			"Cuts a clip out of a take. Times are on the video's clock.",
			[("document", document),
			 ("start", .string("Where it starts: `MM:SS.mmm`, `HH:MM:SS.mmm` or seconds.")),
			 ("end", .string("Where it ends.")),
			 ("name", .string("What it is, in prose.")),
			 ("slug", .string("Its reference. Left out, one is made from the name.")),
			 ("color", .string("Its lane: green, blue, amber, violet, rose or teal.")),
			 ("tags", .strings("Tags a project can select on.")),
			 ("note", .string("A note to whoever cuts this next."))],
			required: ["start", "end"]),
		ToolDefinition("set_audio_offset",
			"Moves a take's separately recorded audio against its video. The offset is added to the audio's clock to get the video's, so a larger offset makes the audio start later. No cut mark moves.",
			[("document", document),
			 ("offset", .string("The new offset: `+00:01.234`, or seconds.")),
			 ("shift", .number("Or: seconds to move it by. Positive is later."))]),
		ToolDefinition("trim_audio",
			"Writes a stretch of an audio file out as a new file, leaving the original untouched. Only for when a copy is really wanted: to start a sound part-way into its file, set `start:` on it in the project instead — see reference “Sounds”.",
			[("source", .string("The audio file: a path, or one relative to the project.")),
			 ("start", .string("Where the copy begins in the file: `MM:SS.mmm` or seconds.")),
			 ("end", .string("Where it ends. Left out: the end of the file.")),
			 ("target", .string("Where to write it, inside the project's folder or beside the source. Left out: beside the source, named after it.")),
			 ("document", document)],
			required: ["source", "start"]),
		ToolDefinition("shift_sound",
			"Moves a sound of the project — music, an atmosphere — earlier or later in the programme. This moves *when* it plays; which part of the file is heard is its `start:`, changed with edit_document.",
			[("document", document),
			 ("sound", .string("Which sound: its file, or its number in get_context.")),
			 ("by", .number("Seconds. Positive starts it later."))],
			required: ["sound", "by"]),
		ToolDefinition("read_transcript",
			"What is said in a take, a line at a time with each line's times on the video's clock. Needs the take to have been transcribed.",
			[("document", document),
			 ("from", .string("Only from this time.")),
			 ("to", .string("Only up to this time.")),
			 ("find", .string("Only lines containing this."))]),
		ToolDefinition("seek",
			"Puts the playhead of the take or project on screen at a time.",
			[("time", .string("`MM:SS.mmm` or seconds.")), ("document", document)],
			required: ["time"]),
		ToolDefinition("play",
			"Starts or stops playing the document on screen.",
			[("playing", .boolean("True to play, false to stop."))], required: ["playing"]),
		ToolDefinition("select_clip",
			"Selects a clip of a take and shows it on the timeline.",
			[("slug", .string("The clip's slug.")), ("document", document)], required: ["slug"]),
		ToolDefinition("show_document",
			"Brings an open document to the screen.",
			[("document", document)], required: ["document"]),
		ToolDefinition("open_file",
			"Opens a take, a project, or a video or audio file to cut.",
			[("path", .string("The file's path."))], required: ["path"]),
		ToolDefinition("list_commands",
			"Every command in cuttr's menu bar and whether it can be used right now. Anything the app does that has no tool of its own is here: aligning the audio, transcribing, rendering, exporting, zooming, versions."),
		ToolDefinition("run_command",
			"Runs a command from the menu bar, as if it had been chosen there.",
			[("command", .string("As list_commands names it: “Audio ▸ Align Automatically”."))],
			required: ["command"]),
		ToolDefinition("undo",
			"Takes back the last change to a document.", [("document", document)]),
		ToolDefinition("redo",
			"Puts back the change that was last undone.", [("document", document)]),
		ToolDefinition("save_all",
			"Writes every open document that has changed to its file."),
	]

	let instructions = """
	You are the assistant inside cuttr, a macOS program that cuts video as text. \
	You work in the person's open documents through the tools; they watch it happen.

	Two kinds of document, both plain text (YAML):
	- A take (.cuttr) is one recording — a video, optionally a separately recorded \
	audio file — and the named clips cut out of it, with tags, colours and notes.
	- A project (.cuttrproj) assembles clips from several takes into a programme, \
	with overlays, captions, scenes and sounds laid over it.

	How to work:
	- Begin with get_context unless the message already tells you what you need.
	- To change something, read_document, then edit_document with the exact text \
	to replace. Every change is one undo step and is shown at once. Do not \
	restate a whole file when one line changes.
	- The `reference` tool is cuttr's own documentation. Read the section before \
	writing syntax you have not seen in the document — the project format is \
	large, and a guessed key is refused or, worse, kept as an unknown key that \
	does nothing.
	- Two clocks on a sound of a project: `from:`/`to:`/`within:`/`group:` say \
	when it plays, on the programme; `start:` and `end:` say which part of the \
	file is heard. To begin a song at its chorus, set `start:` — do not move \
	the sound and do not cut a copy.
	- If an edit is refused, the result says why. Fix that; do not retry unchanged.
	- Anything with no tool of its own is a menu command: list_commands, then \
	run_command.

	Rules of the program, which are not negotiable:
	- Every time in a take is on the video's clock. The separate audio's `offset` \
	is the only thing relating the two: audio + offset = video clock, so a \
	positive offset means the recorder started after the camera, and a larger \
	offset makes the audio start later. Moving the audio never moves a clip.
	- A slug is a reference: projects point at clips by slug. Renaming a clip \
	changes its `name`. Change a `slug` only when asked to, and then say what \
	in the project referred to it.
	- Keys and comments you do not recognise in a file are somebody's. Leave them.
	- Edits to a take stay unsaved until save_all; edits to a project are written \
	as they are made, as they are when a person makes them. Say which happened. \
	Do not save unless asked.

	Answer briefly and in the language the person writes in. Say what you did \
	and what it changed, with the times and slugs involved. Times are written \
	`MM:SS.mmm`.
	"""

	// MARK: - Which document

	@MainActor
	private enum Target {
		case take(MainWindowController)
		case project(ComposeWindowController)
		/// A take a project lists, or one named by path, that is not open.
		case file(URL)

		var name: String {
			switch self {
			case .take(let controller): return controller.takeDocument.displayName
			case .project(let controller): return controller.composeDocument.displayName
			case .file(let url): return url.deletingPathExtension().lastPathComponent
			}
		}
	}

	private var takes: [MainWindowController] {
		desk?.documents.compactMap { $0 as? MainWindowController } ?? []
	}

	private var projects: [ComposeWindowController] {
		desk?.documents.compactMap { $0 as? ComposeWindowController } ?? []
	}

	private func names(_ url: URL?, _ display: String) -> [String] {
		var out = [display.lowercased()]
		if let url {
			out.append(url.lastPathComponent.lowercased())
			out.append(url.standardizedFileURL.path.lowercased())
		}
		return out
	}

	private func openTake(at url: URL) -> MainWindowController? {
		takes.first { $0.takeDocument.url?.standardizedFileURL == url.standardizedFileURL }
	}

	private func target(_ arguments: JSONObject) throws -> Target {
		let asked = (arguments["document"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
		guard !asked.isEmpty else {
			switch desk?.showing {
			case let take as MainWindowController: return .take(take)
			case let project as ComposeWindowController: return .project(project)
			default:
				// A scene is written inside its project, so that is the document.
				if let project = projects.first { return .project(project) }
				if let take = takes.first { return .take(take) }
				throw Refusal(text: "No document is open in cuttr.")
			}
		}
		let wanted = (asked as NSString).expandingTildeInPath.lowercased()
		for take in takes where names(take.takeDocument.url, take.takeDocument.displayName).contains(wanted) {
			return .take(take)
		}
		for project in projects
		where names(project.composeDocument.url, project.composeDocument.displayName).contains(wanted) {
			return .project(project)
		}
		for project in projects {
			for entry in project.composeDocument.takes
			where names(entry.url, entry.name).contains(wanted) || entry.path.lowercased() == wanted {
				if let open = openTake(at: entry.url) { return .take(open) }
				return .file(entry.url)
			}
		}
		let path = (asked as NSString).expandingTildeInPath
		if path.hasPrefix("/"), path.hasSuffix(".cuttr"), FileManager.default.fileExists(atPath: path) {
			return .file(URL(fileURLWithPath: path))
		}
		throw Refusal(text: "No document called “\(asked)”. \(openLine())")
	}

	private func openLine() -> String {
		let open = takes.map { "take “\($0.takeDocument.displayName)”" }
			+ projects.map { "project “\($0.composeDocument.displayName)”" }
		return open.isEmpty ? "Nothing is open." : "Open: \(open.joined(separator: ", "))."
	}

	// MARK: - Before a call

	/// The commands that end something or reach outside this computer. Listed
	/// by what they are called, because that is how they are run.
	private static let asksFirst = [
		"quit cuttr", "close", "close window", "share…", "delete", "clear menu",
		"reload from disk",
	]

	func question(before name: String, arguments: JSONObject) -> String? {
		switch name {
		case "save_all":
			return "Save every document that has changed?"
		case "trim_audio":
			guard let plan = try? trimPlan(arguments) else { return nil }
			return "Write \(plan.target.lastPathComponent) into \(plan.target.deletingLastPathComponent().path)? It is a copy of part of \(plan.source.lastPathComponent); the original is not changed."
		case "edit_document", "write_document", "add_clip", "set_audio_offset":
			// A take that is not open has no undo stack to put the change on.
			guard case .file(let url)? = try? target(arguments) else { return nil }
			return "Write \(url.lastPathComponent) on disk? It is not open, so this cannot be undone."
		case "run_command":
			guard let asked = arguments["command"] as? String,
			      let found = try? command(asked) else { return nil }
			let title = found.item.title.lowercased()
			guard Self.asksFirst.contains(title) else { return nil }
			return "Run “\(found.path)”?"
		default:
			return nil
		}
	}

	// MARK: - Context

	func context() -> String {
		guard let desk else { return "cuttr" }
		var parts: [String] = []
		switch desk.showing {
		case let take as MainWindowController:
			var line = "on screen: take “\(take.takeDocument.displayName)”, playhead \(Timecode.string(take.playheadTime))"
			if let slug = take.selectedSlug { line += ", selected clip \(slug)" }
			if let span = take.pendingSpan {
				line += ", in/out \(Timecode.string(span.start))–\(Timecode.string(span.end))"
			}
			parts.append(line)
		case let project as ComposeWindowController:
			parts.append("on screen: project “\(project.composeDocument.displayName)”, playhead \(Timecode.string(project.playheadTime))")
		case let scene as SceneWindowController:
			parts.append("on screen: scene “\(scene.sceneDocument.name)” of a project")
		default:
			parts.append("nothing on screen")
		}
		let others = takes.filter { $0 !== desk.showing }.map { "take “\($0.takeDocument.displayName)”" }
			+ projects.filter { $0 !== desk.showing }.map { "project “\($0.composeDocument.displayName)”" }
		if !others.isEmpty { parts.append("also open: \(others.joined(separator: ", "))") }
		return "cuttr, now — " + parts.joined(separator: "; ")
	}

	// MARK: - Calls

	func call(_ name: String, arguments: JSONObject) async -> ToolResult {
		do {
			switch name {
			case "get_context": return getContext()
			case "reference": return reference(arguments["topic"] as? String)
			case "read_document": return try read(arguments)
			case "edit_document": return try edit(arguments)
			case "write_document":
				guard let text = arguments["text"] as? String else { throw Refusal(text: "No text given.") }
				return try apply(text, to: target(arguments), action: action(arguments))
			case "add_clip": return try addClip(arguments)
			case "set_audio_offset": return try setOffset(arguments)
			case "shift_sound": return try shiftSound(arguments)
			case "trim_audio": return try await trimAudio(arguments)
			case "read_transcript": return try transcript(arguments)
			case "seek": return try seek(arguments)
			case "play": return try play(arguments)
			case "select_clip": return try selectClip(arguments)
			case "show_document": return try show(arguments)
			case "open_file": return try open(arguments)
			case "list_commands": return listCommands()
			case "run_command": return try runCommand(arguments)
			case "undo": return try undo(arguments, redo: false)
			case "redo": return try undo(arguments, redo: true)
			case "save_all":
				let line = desk?.saveEverything().line ?? "nothing to save"
				return ToolResult(line, summary: line.prefix(1).uppercased() + line.dropFirst())
			default:
				return .failure("cuttr has no tool called \(name).")
			}
		} catch let refusal as Refusal {
			return .failure(refusal.text)
		} catch {
			return .failure(error.localizedDescription)
		}
	}

	/// A number, whichever kind of number it arrived as.
	private func number(_ value: Any?) -> Double? {
		if let double = value as? Double { return double }
		if let int = value as? Int { return Double(int) }
		return nil
	}

	/// A time as a model writes one: a number of seconds, or a timecode, with
	/// or without a sign in front.
	private func time(_ value: Any?) -> Double? {
		if let number = number(value) { return number }
		guard var text = (value as? String)?.trimmingCharacters(in: .whitespaces) else { return nil }
		let negative = text.hasPrefix("-")
		if negative || text.hasPrefix("+") { text.removeFirst() }
		return Timecode.parse(text).map { negative ? -$0 : $0 }
	}

	private func action(_ arguments: JSONObject) -> String {
		let said = (arguments["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		return said.isEmpty ? "Assistant Edit" : String(said.prefix(48))
	}

	// MARK: Reading

	private func describe(_ take: Take, name: String, url: URL?) -> [String] {
		var lines: [String] = []
		var media = "video \(take.video ?? "none")"
		if let audio = take.audio {
			media += " · audio \(audio.file), offset \(Timecode.offsetString(audio.offset))"
		}
		lines.append("  \(media)")
		var facts = "\(take.clips.count) clip\(take.clips.count == 1 ? "" : "s")"
		if !take.tags.isEmpty { facts += " · tags \(take.tags.joined(separator: ", "))" }
		lines.append("  \(facts)")
		return lines
	}

	private func getContext() -> ToolResult {
		guard let desk else { return .failure("cuttr is not running.") }
		var out: [String] = []
		for take in takes {
			let document = take.takeDocument
			var head = "take “\(document.displayName)”"
			head += document.url.map { " — \($0.path)" } ?? " — never saved"
			if document.isDirty { head += " — unsaved changes" }
			if take === desk.showing { head += " — ON SCREEN" }
			out.append(head)
			out += describe(document.take, name: document.displayName, url: document.url)
			var state = "  length \(Timecode.string(document.duration)) · playhead \(Timecode.string(take.playheadTime))"
			if let slug = take.selectedSlug { state += " · selected clip \(slug)" }
			if let span = take.pendingSpan {
				state += " · in/out \(Timecode.string(span.start))–\(Timecode.string(span.end))"
			}
			out.append(state)
			out.append(document.transcript.isEmpty
				? "  not transcribed (Audio ▸ Transcribe This Take)"
				: "  transcribed: \(document.transcript.count) words")
			if let problem = document.mediaError { out.append("  problem: \(problem)") }
		}
		for project in projects {
			let document = project.composeDocument
			var head = "project “\(document.displayName)”"
			head += document.url.map { " — \($0.path)" } ?? " — never saved"
			if project === desk.showing { head += " — ON SCREEN" }
			out.append(head)
			if let resolved = document.resolved {
				out.append("  programme \(Timecode.string(resolved.duration)) · \(resolved.clips.count) clips placed · playhead \(Timecode.string(project.playheadTime))")
				out += soundLines(document)
				for warning in resolved.warnings.prefix(8) { out.append("  warning: \(warning)") }
			}
			if let problem = document.problem { out.append("  problem: \(problem)") }
			for entry in document.takes {
				var line = "  take “\(entry.name)” (\(entry.path)): \(entry.clips) clips"
				line += openTake(at: entry.url) == nil ? ", not open" : ", open"
				if let problem = entry.problem { line += " — \(problem)" }
				out.append(line)
			}
		}
		if case let scene as SceneWindowController = desk.showing {
			out.append("scene “\(scene.sceneDocument.name)” — ON SCREEN; it is written in its project's file, under `scenes:`")
		}
		if out.isEmpty { return ToolResult("Nothing is open in cuttr.") }
		let count = takes.count + projects.count
		return ToolResult(out.joined(separator: "\n"),
		                  summary: "Looked at \(count) open document\(count == 1 ? "" : "s")")
	}

	private func text(of target: Target) throws -> String {
		switch target {
		case .take(let controller): return TakeWriter.write(controller.takeDocument.take)
		case .project(let controller): return ProjectWriter.write(controller.composeDocument.project)
		case .file(let url): return try String(contentsOf: url, encoding: .utf8)
		}
	}

	private func read(_ arguments: JSONObject) throws -> ToolResult {
		let target = try target(arguments)
		let text = try text(of: target)
		var note = ""
		if case .project(let controller) = target, let problem = controller.composeDocument.problem {
			note = "\n\n# cuttr says about this file: \(problem)"
		}
		return ToolResult(text + note, summary: "Read \(target.name)")
	}

	// MARK: Changing

	private func edit(_ arguments: JSONObject) throws -> ToolResult {
		guard let old = arguments["old"] as? String, !old.isEmpty,
		      let new = arguments["new"] as? String
		else { throw Refusal(text: "edit_document needs `old` and `new`.") }
		let target = try target(arguments)
		let before = try text(of: target)
		let found = before.components(separatedBy: old).count - 1
		let all = arguments["replace_all"] as? Bool ?? false
		guard found > 0 else {
			throw Refusal(text: "That text is not in \(target.name). Use read_document and copy it exactly, spacing included.")
		}
		guard found == 1 || all else {
			throw Refusal(text: "That text is in \(target.name) \(found) times. Give more of what surrounds it, or set replace_all.")
		}
		return try apply(before.replacingOccurrences(of: old, with: new), to: target,
		                 action: action(arguments))
	}

	/// Puts a text into a document. The one way any of the tools changes one.
	private func apply(_ text: String, to target: Target, action: String) throws -> ToolResult {
		switch target {
		case .take(let controller):
			let document = controller.takeDocument
			let before = document.take
			try document.applyText(text, actionName: action)
			let take = document.take
			guard take != before else {
				return ToolResult("Nothing changed: \(target.name) already says that.")
			}
			return ToolResult(
				"Changed \(target.name) — not saved yet, ⌘Z takes it back.\n" + difference(before, take),
				summary: "\(action): \(target.name)")
		case .project(let controller):
			let document = controller.composeDocument
			let project = try ProjectReader.read(text)
			guard project != document.project else {
				return ToolResult("Nothing changed: \(target.name) already says that.")
			}
			document.apply(project, actionName: action)
			// As every edit in the project window is: applied, and written.
			var said = "Changed \(target.name)"
			if document.url != nil {
				try document.write()
				said += " and wrote it"
			}
			said += " — ⌘Z takes it back."
			if let resolved = document.resolved {
				said += "\nThe programme is now \(Timecode.string(resolved.duration)) long."
				// The sounds as cuttr now understands them, so that what was
				// written can be checked against what it means: a key that was
				// read shows here, and one that was not does not.
				for line in soundLines(document) { said += "\n" + line.trimmingCharacters(in: .whitespaces) }
				for warning in resolved.warnings.prefix(8) { said += "\nwarning: \(warning)" }
			}
			if let problem = document.problem { said += "\nPROBLEM: \(problem)" }
			return ToolResult(said, summary: "\(action): \(target.name)")
		case .file(let url):
			let take = try TakeReader.read(text)
			try TakeWriter.write(take).write(to: url, atomically: true, encoding: .utf8)
			NotificationCenter.default.post(name: .cuttrTakeChanged, object: url.standardizedFileURL)
			return ToolResult("Wrote \(url.lastPathComponent): \(take.clips.count) clips.",
			                  summary: "\(action): \(target.name), on disk")
		}
	}

	/// What changed between two takes, said the way somebody would check it.
	private func difference(_ before: Take, _ after: Take) -> String {
		var lines: [String] = []
		let was = Dictionary(before.clips.map { ($0.slug, $0) }, uniquingKeysWith: { first, _ in first })
		let now = Dictionary(after.clips.map { ($0.slug, $0) }, uniquingKeysWith: { first, _ in first })
		for clip in after.clips where was[clip.slug] == nil {
			lines.append("new clip \(clip.slug): \(Timecode.string(clip.start))–\(Timecode.string(clip.end))")
		}
		for clip in before.clips where now[clip.slug] == nil { lines.append("clip \(clip.slug) is gone") }
		for clip in after.clips {
			guard let old = was[clip.slug], old != clip else { continue }
			lines.append("clip \(clip.slug) changed: \(Timecode.string(clip.start))–\(Timecode.string(clip.end))")
		}
		if before.audio != after.audio, let audio = after.audio {
			lines.append("audio offset is \(Timecode.offsetString(audio.offset))")
		}
		if lines.isEmpty { lines.append("\(after.clips.count) clips, as before; something else in the take changed") }
		return lines.prefix(20).joined(separator: "\n")
	}

	private func addClip(_ arguments: JSONObject) throws -> ToolResult {
		guard let start = time(arguments["start"]), let end = time(arguments["end"]), end != start else {
			throw Refusal(text: "add_clip needs a `start` and a different `end`, as `MM:SS.mmm` or seconds.")
		}
		let target = try target(arguments)
		if case .project = target {
			throw Refusal(text: "A clip is cut out of a take, not a project. Name the take.")
		}
		var color = ClipColor.default
		if let asked = arguments["color"] as? String {
			guard let known = ClipColor(rawValue: asked.lowercased()) else {
				throw Refusal(text: "No colour called \(asked): green, blue, amber, violet, rose or teal.")
			}
			color = known
		}
		let name = arguments["name"] as? String ?? ""
		let typed = (arguments["slug"] as? String).map { Slug.make(from: $0) } ?? ""
		func added(to take: inout Take, snap: FrameGrid) -> Clip {
			let slug = !typed.isEmpty ? typed
				: (Slug.make(from: name).isEmpty ? Slug.numbered(taken: take.slugs) : "")
			return take.add(Clip(slug: slug, name: name, start: snap.snap(start), end: snap.snap(end),
			                     note: arguments["note"] as? String, color: color,
			                     tags: arguments["tags"] as? [String] ?? []))
		}
		switch target {
		case .take(let controller):
			var next = controller.takeDocument.take
			let clip = added(to: &next, snap: controller.takeDocument.grid)
			// Through the text, so the slug is claimed the way a typed one is.
			try controller.takeDocument.applyText(TakeWriter.write(next), actionName: "Add Clip")
			_ = controller.show(clip: clip.slug)
			return ToolResult(
				"Cut clip \(clip.slug) in \(target.name): \(Timecode.string(clip.start))–\(Timecode.string(clip.end)). Not saved yet.",
				summary: "Cut clip \(clip.slug), \(Timecode.string(clip.start))–\(Timecode.string(clip.end))")
		case .file(let url):
			var next = try TakeReader.read(try String(contentsOf: url, encoding: .utf8))
			let clip = added(to: &next, snap: .none)
			_ = try apply(TakeWriter.write(next), to: target, action: "Add Clip")
			return ToolResult("Cut clip \(clip.slug) in \(url.lastPathComponent), on disk.",
			                  summary: "Cut clip \(clip.slug) in \(target.name)")
		case .project:
			throw Refusal(text: "Name the take.")
		}
	}

	private func setOffset(_ arguments: JSONObject) throws -> ToolResult {
		let target = try target(arguments)
		func moved(_ take: Take) throws -> (Take, Double, Double) {
			guard var audio = take.audio else {
				throw Refusal(text: "\(target.name) has no separate audio file to move. A sound in a project is moved with shift_sound.")
			}
			let was = audio.offset
			if let absolute = arguments["offset"] {
				guard let value = time(absolute) else { throw Refusal(text: "The offset is not a time.") }
				audio.offset = value
			} else if let shift = number(arguments["shift"]) {
				audio.offset += shift
			} else {
				throw Refusal(text: "Give `offset` or `shift`.")
			}
			var next = take
			next.audio = audio
			return (next, was, audio.offset)
		}
		func said(_ was: Double, _ now: Double) -> String {
			let by = now - was
			return "\(Timecode.offsetString(was)) → \(Timecode.offsetString(now)): the audio starts "
				+ String(format: "%.3f s ", abs(by)) + (by >= 0 ? "later" : "earlier")
		}
		switch target {
		case .take(let controller):
			let (_, was, now) = try moved(controller.takeDocument.take)
			controller.takeDocument.setOffset(now)
			return ToolResult("Audio offset of \(target.name) \(said(was, now)). No clip moved. Not saved yet.",
			                  summary: "Audio of \(target.name) \(said(was, now))")
		case .file:
			let (next, was, now) = try moved(try TakeReader.read(try text(of: target)))
			_ = try apply(TakeWriter.write(next), to: target, action: "Adjust Alignment")
			return ToolResult("Audio offset of \(target.name) \(said(was, now)), on disk.",
			                  summary: "Audio of \(target.name) \(said(was, now))")
		case .project:
			throw Refusal(text: "An offset belongs to a take. A sound in a project is moved with shift_sound.")
		}
	}

	/// Every sound of a project, in the order the file has them: the top-level
	/// list, then the ones written inside timeline entries.
	///
	/// One list, numbered once. get_context numbers the sounds and shift_sound
	/// is asked for one by that number, so the two have to be counting the same
	/// things — and a sound written inside a group is a sound.
	private func sounds(of document: ComposeDocument) -> [(origin: Origin, sound: Sound)] {
		// The nested ones come from the resolved programme, which has them by
		// when they play. Put back in the order the file has them, so a number
		// means the same sound before and after it is moved.
		var nested: [(path: [Int], index: Int)] = []
		for placed in document.resolved?.sounds ?? [] {
			guard case .entry(let path, let index) = placed.origin,
			      !nested.contains(where: { $0.path == path && $0.index == index }) else { continue }
			nested.append((path, index))
		}
		nested.sort { $0.path == $1.path ? $0.index < $1.index : $0.path.lexicographicallyPrecedes($1.path) }
		let origins = document.project.sounds.indices.map { Origin.project($0) }
			+ nested.map { Origin.entry(path: $0.path, index: $0.index) }
		return origins.compactMap { origin in
			document.project.sound(at: origin).map { (origin, $0) }
		}
	}

	private func soundLines(_ document: ComposeDocument) -> [String] {
		sounds(of: document).enumerated().map { index, entry in
			var line = "  sound \(index + 1): \(entry.sound.file)"
			if Project.home(of: entry.origin) != nil { line += " (inside a timeline entry)" }
			let placed = (document.resolved?.sounds ?? []).filter { $0.origin == entry.origin }
			if placed.isEmpty {
				line += " does not play"
			} else {
				line += " plays " + placed.prefix(4)
					.map { "\(Timecode.string($0.start))–\(Timecode.string($0.end))" }
					.joined(separator: " and ")
			}
			if entry.sound.fileStart > 0 || entry.sound.fileEnd != nil {
				line += ", from \(Timecode.string(entry.sound.fileStart)) of the file"
				if let end = entry.sound.fileEnd { line += " to \(Timecode.string(end))" }
			} else {
				line += ", from the top of the file"
			}
			if entry.sound.gain != 0 { line += ", gain \(entry.sound.gain) dB" }
			return line
		}
	}

	private func shiftSound(_ arguments: JSONObject) throws -> ToolResult {
		guard case .project(let controller) = try target(arguments) else {
			throw Refusal(text: "Sounds belong to a project. A take's own audio is moved with set_audio_offset.")
		}
		let document = controller.composeDocument
		guard let by = number(arguments["by"]), by != 0 else { throw Refusal(text: "Give `by`, in seconds.") }
		let all = sounds(of: document)
		let listed = all.enumerated().map { "\($0.offset + 1): \($0.element.sound.file)" }.joined(separator: ", ")
		let asked = (arguments["sound"] as? String) ?? (arguments["sound"] as? Int).map(String.init) ?? ""
		let chosen: (origin: Origin, sound: Sound)
		if let number = Int(asked), all.indices.contains(number - 1) {
			chosen = all[number - 1]
		} else {
			let matches = all.filter {
				$0.sound.file == asked || ($0.sound.file as NSString).lastPathComponent == asked
			}
			guard matches.count == 1 else {
				throw Refusal(text: matches.isEmpty
					? "No sound “\(asked)” in this project. There are: \(listed.isEmpty ? "none" : listed)."
					: "“\(asked)” is used \(matches.count) times; say which by number: \(listed).")
			}
			chosen = matches[0]
		}
		let file = chosen.sound.file
		func plays() -> String {
			let placed = (document.resolved?.sounds ?? []).filter { $0.origin == chosen.origin }
			guard let first = placed.first else { return "" }
			return " It plays \(Timecode.string(first.start))–\(Timecode.string(first.end))."
		}
		let moved: Overlay.Span
		switch chosen.sound.span {
		case .times(let from, let to)?:
			let step = max(-from, by)
			moved = .times(from: from + step, to: to + step)
		case .within(let clip, let from, let to)?:
			let step = max(-from, by)
			moved = .within(clip, from: from + step, to: to + step)
		case nil:
			throw Refusal(text: "\(file) is written inside a timeline entry with no range of its own, so it plays for exactly as long as that entry is on and has no time to shift.\(plays()) To start it later, give it `within:` that clip with `from:` and `to:` — see reference “Sounds”. To start it further into its *file*, set `start:`.")
		default:
			// Bound to marks: it plays where a clip or a group is, and has no
			// time of its own to add to. Unbinding it is a decision, so it is
			// handed back rather than made.
			throw Refusal(text: "\(file) is bound to a clip or a group rather than to times, so it moves when they do and has no time to shift.\(plays()) To start it later, edit its entry under `sounds:` — see reference “Sounds” — and tell the person it will no longer follow a re-cut. To start it further into its *file*, set `start:`.")
		}
		let direction = by > 0 ? "later" : "earlier"
		let action = "Move Sound \(direction.prefix(1).uppercased())\(direction.dropFirst())"
		var project = document.project
		project.editSound(at: chosen.origin) { $0.span = moved }
		document.apply(project, actionName: action)
		if document.url != nil { try document.write() }
		let said = "\(file) starts \(String(format: "%.3f", abs(by))) s \(direction).\(plays())"
		return ToolResult(said + " ⌘Z takes it back.", summary: said)
	}

	// MARK: Cutting a copy

	private struct TrimPlan {
		var source: URL
		var target: URL
		var start: Double
		var end: Double?
		/// The folder paths are said against, when there is a project.
		var base: URL?
	}

	/// Where a trimmed copy comes from and where it goes — worked out once,
	/// for the question that is asked first and for the writing after it.
	///
	/// The copy lands in one of two places and nowhere else: under the folder
	/// the project is in, or beside the file it was cut from. Those are the two
	/// folders a sound of this project could sensibly live in, and a tool that
	/// would write wherever it was told is one prompt away from writing
	/// somewhere it should not.
	private func trimPlan(_ arguments: JSONObject) throws -> TrimPlan {
		var base: URL?
		if case .project(let controller)? = try? target(arguments) { base = controller.composeDocument.baseURL }
		base = base ?? projects.first?.composeDocument.baseURL
		func url(_ path: String) -> URL {
			let expanded = (path as NSString).expandingTildeInPath
			if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded).standardizedFileURL }
			return URL(fileURLWithPath: expanded, relativeTo: base ?? URL(fileURLWithPath: "/")).standardizedFileURL
		}
		guard let named = arguments["source"] as? String, !named.isEmpty else {
			throw Refusal(text: "trim_audio needs the `source` file.")
		}
		let source = url(named)
		guard FileManager.default.fileExists(atPath: source.path) else {
			throw Refusal(text: "There is no file at \(source.path).")
		}
		guard let start = time(arguments["start"]), start >= 0 else {
			throw Refusal(text: "`start` is not a time.")
		}
		let end = time(arguments["end"])
		if let end, end <= start { throw Refusal(text: "`end` has to be after `start`.") }

		let target: URL
		if let asked = arguments["target"] as? String, !asked.isEmpty {
			target = url(asked)
		} else {
			let stamp = Timecode.string(start).replacingOccurrences(of: ":", with: "-")
			target = source.deletingLastPathComponent().appendingPathComponent(
				"\(source.deletingPathExtension().lastPathComponent)-from-\(stamp).\(AudioTrim.kind(for: source))")
		}
		func inside(_ folder: URL?) -> Bool {
			guard let folder else { return false }
			let root = folder.standardizedFileURL.resolvingSymlinksInPath().path
			let there = target.deletingLastPathComponent().resolvingSymlinksInPath().path
			return there == root || there.hasPrefix(root.hasSuffix("/") ? root : root + "/")
		}
		guard inside(base) || inside(source.deletingLastPathComponent()) else {
			throw Refusal(text: "A copy is written inside the project's folder or beside the file it is cut from, and \(target.path) is neither.")
		}
		guard ["wav", "aif", "aiff", "caf", "m4a"].contains(target.pathExtension.lowercased()) else {
			throw Refusal(text: "The copy is written as .wav, .aiff, .caf or .m4a — \(AudioTrim.kind(for: source)) for this file.")
		}
		return TrimPlan(source: source, target: target, start: start, end: end, base: base)
	}

	private func trimAudio(_ arguments: JSONObject) async throws -> ToolResult {
		let plan = try trimPlan(arguments)
		// Off the main thread: a song is tens of megabytes to read and write,
		// and the window should not stop while it happens.
		let seconds = try await Task.detached(priority: .userInitiated) {
			try AudioTrim.write(plan.source, from: plan.start, to: plan.end, at: plan.target)
		}.value
		let path = plan.base.map { MediaPath.relative(plan.target, toFolder: $0) } ?? plan.target.path
		return ToolResult(
			"Wrote \(plan.target.path): \(Timecode.string(seconds)) of \(plan.source.lastPathComponent), from \(Timecode.string(plan.start)). The original is unchanged. In the project it is `file: \(path)`.",
			summary: "Wrote \(plan.target.lastPathComponent), \(Timecode.string(seconds)) from \(Timecode.string(plan.start))")
	}

	// MARK: Words

	private func transcript(_ arguments: JSONObject) throws -> ToolResult {
		let target = try target(arguments)
		let words: Transcript
		let take: Take
		switch target {
		case .take(let controller):
			words = controller.takeDocument.transcript
			take = controller.takeDocument.take
		case .file(let url):
			take = try TakeReader.read(try String(contentsOf: url, encoding: .utf8))
			let sidecar = take.words.map {
				URL(fileURLWithPath: $0.path, relativeTo: url.deletingLastPathComponent())
			}
			words = sidecar.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
				.map(Transcript.read) ?? Transcript()
		case .project:
			throw Refusal(text: "Words belong to a take. Name one of the project's takes.")
		}
		guard !words.isEmpty else {
			throw Refusal(text: "\(target.name) has not been transcribed. Open it and run “Audio ▸ Transcribe This Take” — it takes a while and happens on this Mac.")
		}
		let from = time(arguments["from"]) ?? 0
		let to = time(arguments["to"]) ?? .infinity
		let find = (arguments["find"] as? String)?.lowercased()
		var lines: [String] = []
		for range in words.lines {
			guard let first = words.words[range].first, let last = words.words[range].last,
			      last.end >= from, first.start <= to else { continue }
			let said = words.words[range].map(\.text).joined(separator: " ")
			if let find, !said.lowercased().contains(find) { continue }
			let who = words.speaker(ofLine: range).map { "\(take.speakerTitle($0)): " } ?? ""
			lines.append("[\(Timecode.string(first.start))–\(Timecode.string(last.end))] \(who)\(said)")
		}
		guard !lines.isEmpty else { return ToolResult("No line of \(target.name) matches.") }
		// A forty-minute take is more than a model wants in one answer.
		let shown = lines.prefix(400)
		var out = shown.joined(separator: "\n")
		if lines.count > shown.count {
			out += "\n… \(lines.count - shown.count) more lines. Ask again with `from` or `find`."
		}
		return ToolResult(out, summary: "Read \(lines.count) line\(lines.count == 1 ? "" : "s") of \(target.name)")
	}

	// MARK: Looking

	private func seek(_ arguments: JSONObject) throws -> ToolResult {
		guard let time = time(arguments["time"]) else { throw Refusal(text: "The time is not a time.") }
		let target = try target(arguments)
		switch target {
		case .take(let controller): controller.go(to: time)
		case .project(let controller): controller.go(to: time)
		case .file: throw Refusal(text: "\(target.name) is not open. open_file first.")
		}
		return ToolResult("The playhead of \(target.name) is at \(Timecode.string(time)).")
	}

	private func play(_ arguments: JSONObject) throws -> ToolResult {
		let playing = arguments["playing"] as? Bool ?? true
		switch desk?.showing {
		case let take as MainWindowController: take.setPlaying(playing)
		case let project as ComposeWindowController: project.setPlaying(playing)
		default: throw Refusal(text: "Nothing that plays is on screen.")
		}
		return ToolResult(playing ? "Playing." : "Stopped.")
	}

	private func selectClip(_ arguments: JSONObject) throws -> ToolResult {
		guard case .take(let controller) = try target(arguments) else {
			throw Refusal(text: "Clips are selected in an open take.")
		}
		let slug = arguments["slug"] as? String ?? ""
		guard controller.show(clip: slug) else {
			let known = controller.takeDocument.take.clips.map(\.slug).prefix(60).joined(separator: ", ")
			throw Refusal(text: "No clip \(slug) in \(controller.takeDocument.displayName). There are: \(known).")
		}
		return ToolResult("Selected clip \(slug).")
	}

	private func show(_ arguments: JSONObject) throws -> ToolResult {
		let target = try target(arguments)
		switch target {
		case .take(let controller): desk?.bring(controller)
		case .project(let controller): desk?.bring(controller)
		case .file(let url): desk?.openFile(url)
		}
		return ToolResult("\(target.name) is on screen.")
	}

	private func open(_ arguments: JSONObject) throws -> ToolResult {
		let path = ((arguments["path"] as? String ?? "") as NSString).expandingTildeInPath
		guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) else {
			throw Refusal(text: "There is no file at \(path). Give the whole path.")
		}
		desk?.openFile(URL(fileURLWithPath: path))
		return ToolResult("Opened \((path as NSString).lastPathComponent).")
	}

	private func undo(_ arguments: JSONObject, redo: Bool) throws -> ToolResult {
		let target = try target(arguments)
		let manager: UndoManager?
		switch target {
		case .take(let controller): manager = controller.documentUndoManager
		case .project(let controller): manager = controller.documentUndoManager
		case .file: manager = nil
		}
		guard let manager, redo ? manager.canRedo : manager.canUndo else {
			throw Refusal(text: "There is nothing to \(redo ? "redo" : "undo") in \(target.name).")
		}
		let what = redo ? manager.redoActionName : manager.undoActionName
		if redo { manager.redo() } else { manager.undo() }
		let said = "\(redo ? "Redid" : "Undid")\(what.isEmpty ? " the last change" : " “\(what)”") in \(target.name)."
		return ToolResult(said)
	}

	// MARK: Reference

	/// The README, cut at its headings.
	private static let sections: [(title: String, text: String)] = {
		guard let url = Bundle.module.url(forResource: "README", withExtension: "md"),
		      let whole = try? String(contentsOf: url, encoding: .utf8) else { return [] }
		var out: [(String, String)] = []
		var title = "cuttr"
		var lines: [String] = []
		var fenced = false
		for line in whole.components(separatedBy: "\n") {
			if line.hasPrefix("```") { fenced.toggle() }
			if !fenced, line.hasPrefix("## ") || line.hasPrefix("### ") {
				out.append((title, lines.joined(separator: "\n")))
				title = String(line.drop { $0 == "#" || $0 == " " })
				lines = []
			}
			lines.append(line)
		}
		out.append((title, lines.joined(separator: "\n")))
		return out
	}()

	private func reference(_ topic: String?) -> ToolResult {
		let sections = Self.sections
		guard !sections.isEmpty else { return .failure("The reference is missing from this build.") }
		let asked = topic?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
		guard !asked.isEmpty else {
			let list = sections.map { "- \($0.title) (\($0.text.components(separatedBy: "\n").count) lines)" }
			return ToolResult("Sections of cuttr's documentation. Ask for one by name.\n" + list.joined(separator: "\n"),
			                  summary: "Looked at the documentation's sections")
		}
		var found = sections.filter { $0.title.lowercased().contains(asked) }
		// Nothing called that: the sections that talk about it, then.
		if found.isEmpty { found = sections.filter { $0.text.lowercased().contains(asked) } }
		guard !found.isEmpty else {
			return .failure("Nothing in the documentation about “\(asked)”. Call reference without a topic for the sections.")
		}
		var out = ""
		var titles: [String] = []
		for section in found {
			guard out.count + section.text.count < 11_000 || out.isEmpty else {
				out += "\n\n(Also: \(found.dropFirst(titles.count).map(\.title).joined(separator: ", ")) — ask for each by name.)"
				break
			}
			out += (out.isEmpty ? "" : "\n\n") + section.text
			titles.append(section.title)
		}
		return ToolResult(out, summary: "Read the documentation: \(titles.joined(separator: ", "))")
	}

	// MARK: Commands

	private struct Command {
		var path: String
		var menu: NSMenu
		var item: NSMenuItem
	}

	/// Every item in the menu bar that does something.
	///
	/// Each menu is brought up to date first, as it would be on its way to being
	/// shown: that is what fills Open Recent and the Colour submenu, and what
	/// asks each window whether its items apply right now.
	private func commands() -> [Command] {
		guard let bar = menu() else { return [] }
		var out: [Command] = []
		func walk(_ menu: NSMenu, _ path: [String]) {
			menu.delegate?.menuNeedsUpdate?(menu)
			menu.update()
			for item in menu.items where !item.isSeparatorItem && !item.title.isEmpty {
				let here = path + [item.title]
				if let submenu = item.submenu {
					walk(submenu, here)
				} else if item.action != nil {
					out.append(Command(path: here.joined(separator: " ▸ "), menu: menu, item: item))
				}
			}
		}
		for top in bar.items {
			guard let submenu = top.submenu else { continue }
			// The application's own menu has no title of its own to go by.
			walk(submenu, [submenu.title.isEmpty ? "cuttr" : submenu.title])
		}
		return out
	}

	private func command(_ asked: String) throws -> Command {
		func plain(_ text: String) -> String {
			text.lowercased().replacingOccurrences(of: "...", with: "…")
				.replacingOccurrences(of: ">", with: "▸")
				.components(separatedBy: "▸").map { $0.trimmingCharacters(in: .whitespaces) }
				.joined(separator: " ▸ ")
		}
		let all = commands()
		let wanted = plain(asked)
		if let exact = all.first(where: { plain($0.path) == wanted }) { return exact }
		// By its own name alone, when there is only one of that name — and
		// forgiving the ellipsis, which nobody types.
		func bare(_ text: String) -> String { text.replacingOccurrences(of: "…", with: "") }
		let named = all.filter { bare($0.item.title.lowercased()) == bare(wanted) }
		if named.count == 1 { return named[0] }
		throw Refusal(text: "No command “\(asked)”. Use list_commands and give one as it is written there.")
	}

	private func keys(_ item: NSMenuItem) -> String {
		guard !item.keyEquivalent.isEmpty else { return "" }
		var out = ""
		let flags = item.keyEquivalentModifierMask
		if flags.contains(.control) { out += "⌃" }
		if flags.contains(.option) { out += "⌥" }
		if flags.contains(.shift) || item.keyEquivalent != item.keyEquivalent.lowercased() { out += "⇧" }
		if flags.contains(.command) { out += "⌘" }
		let key: String
		switch item.keyEquivalent {
		case "\r": key = "⏎"
		case "\u{8}": key = "⌫"
		case "\u{f702}": key = "←"
		case "\u{f703}": key = "→"
		default: key = item.keyEquivalent.uppercased()
		}
		return "  (\(out)\(key))"
	}

	private func listCommands() -> ToolResult {
		let all = commands()
		guard !all.isEmpty else { return .failure("cuttr's menu bar is not there yet.") }
		let lines = all.map { command -> String in
			var line = command.path + keys(command.item)
			if !command.item.isEnabled { line += "  — not available now" }
			if command.item.state == .on { line += "  — on" }
			if let tip = command.item.toolTip { line += "\n    \(tip.replacingOccurrences(of: "\n", with: " "))" }
			return line
		}
		return ToolResult(
			"Commands apply to the document on screen. One marked “not available now” needs another document in front, or a selection.\n"
				+ lines.joined(separator: "\n"),
			summary: "Looked at \(all.count) commands")
	}

	private func runCommand(_ arguments: JSONObject) throws -> ToolResult {
		let found = try command(arguments["command"] as? String ?? "")
		guard found.item.isEnabled else {
			throw Refusal(text: "“\(found.path)” is not available now. It applies to the document on screen (\(context())); show_document another, or select what it works on.")
		}
		let index = found.menu.index(of: found.item)
		guard index >= 0 else { throw Refusal(text: "“\(found.path)” has gone from the menu.") }
		found.menu.performActionForItem(at: index)
		return ToolResult("Ran “\(found.path)”. If it opened a panel or a sheet, the person finishes it there; if it started something long (a transcription, a render), it runs on — get_context says where things stand.",
		                  summary: "Ran “\(found.path)”")
	}
}
