import AppKit
import Testing
import CuttrChat
@testable import CuttrCompose
@testable import CuttrKit
@testable import CuttrUI

/// The application, as far as the assistant can tell: some documents and which
/// of them is on screen.
@MainActor
private final class Desk: AssistantDesk {
	var documents: [DocumentEditor] = []
	var showing: DocumentEditor?
	var opened: [URL] = []
	var saves = 0

	func bring(_ document: DocumentEditor) { showing = document }
	func openFile(_ url: URL) { opened.append(url) }
	func saveEverything() -> SaveReport {
		saves += 1
		return SaveReport()
	}
}

/// What the assistant can do, done to real documents.
///
/// The assertions are about the documents and the files, the same as every
/// other test of an edit here: what the take says afterwards, whether ⌘Z takes
/// it back, what is and is not on disk. A tool that reports success is not
/// evidence of anything.
@MainActor @Suite struct AssistantToolsTests {

	private static let takeFile = """
		cuttr: 1

		video: media/clip.mov
		audio:
		  file:   media/clip-mic.wav
		  offset: +00:01.234

		clips:
		  - slug:  mia-intro
		    name:  Mia, Intro
		    start: 00:00.000
		    end:   00:02.000

		  - slug:  mia-outro
		    name:  Mia, Outro
		    start: 00:04.000
		    end:   00:06.000
		"""

	private let folder: URL
	private let desk = Desk()
	private let tools: AssistantTools

	init() throws {
		folder = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("cuttr-assistant-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		tools = AssistantTools(desk: desk, menu: { nil })
	}

	private func take(_ name: String = "mia-take-1", open: Bool = true) throws -> MainWindowController {
		let url = folder.appendingPathComponent("\(name).cuttr")
		try Self.takeFile.write(to: url, atomically: true, encoding: .utf8)
		let document = TakeDocument()
		try document.read(from: url)
		let controller = MainWindowController(document: document)
		if open {
			desk.documents.append(controller)
			desk.showing = desk.showing ?? controller
		}
		return controller
	}

	/// An empty file where a recording or a piece of music would be. Finding
	/// the file is all that resolving a project asks of it.
	private func touch(_ path: String) throws {
		let url = folder.appendingPathComponent(path)
		try FileManager.default.createDirectory(
			at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
		try Data().write(to: url)
	}

	private func project(_ sounds: [Sound] = [], inside nested: [Sound] = []) throws -> ComposeWindowController {
		let url = folder.appendingPathComponent("programme.cuttrproj")
		var made = Project(takes: ["mia-take-1.cuttr"], output: Output(file: "out.mov"))
		made.timeline = [TimelineEntry(clip: ClipReference("mia-intro"), sounds: nested)]
		made.sounds = sounds
		try ProjectWriter.write(made).write(to: url, atomically: true, encoding: .utf8)
		let document = ComposeDocument()
		try document.read(from: url)
		let controller = ComposeWindowController(document: document)
		desk.documents.append(controller)
		return controller
	}

	// MARK: - The text of a take

	@Test func aTakeIsReadAsItsFileAndEditedAsOneUndoStep() async throws {
		let controller = try take()
		let document = controller.takeDocument
		let intro = try #require(document.take.clips.first).id

		let read = await tools.call("read_document", arguments: [:])
		#expect(read.text == TakeWriter.write(document.take))

		let edited = await tools.call("edit_document", arguments: [
			"old": "end:   00:02.000", "new": "end:   00:03.500", "summary": "Lengthen the intro",
		])
		#expect(!edited.isError, "\(edited.text)")
		#expect(edited.text.contains("clip mia-intro changed: 00:00.000–00:03.500"))
		#expect(document.take.clips[0].end == 3.5)
		// The same clip, not a new one that happens to be called the same.
		#expect(document.take.clips[0].id == intro)
		#expect(document.isDirty)
		#expect(document.undoManager.undoActionName == "Lengthen the intro")
		// Not written: a take is saved when somebody says so.
		#expect(try String(contentsOf: #require(document.url), encoding: .utf8) == Self.takeFile)

		let undone = await tools.call("undo", arguments: [:])
		#expect(undone.text == "Undid “Lengthen the intro” in mia-take-1.")
		#expect(document.take.clips[0].end == 2)
		#expect(!document.isDirty)
	}

	@Test func anEditThatDoesNotFitIsRefusedAndTheTakeLeftAlone() async throws {
		let controller = try take()
		let before = controller.takeDocument.take

		let missing = await tools.call("edit_document", arguments: ["old": "end: 00:02.000", "new": "x"])
		#expect(missing.isError)
		#expect(missing.text.contains("not in mia-take-1"))

		// `start:` is there four times over two clips; which was meant?
		let vague = await tools.call("edit_document", arguments: ["old": "    start:", "new": "    begin:"])
		#expect(vague.isError)
		#expect(vague.text.contains("2 times"))

		// And a text that is no longer a take says why, in the reader's words.
		let broken = await tools.call("edit_document", arguments: [
			"old": "end:   00:02.000", "new": "end:   yesterday",
		])
		#expect(broken.isError)
		#expect(controller.takeDocument.take == before)
		#expect(!controller.takeDocument.undoManager.canUndo)
	}

	@Test func aClipIsCutAndItsSlugIsSomebodysFromThenOn() async throws {
		let controller = try take()
		let document = controller.takeDocument

		let cut = await tools.call("add_clip", arguments: [
			"start": "00:07.000", "end": 9.5, "name": "The Good Laugh", "tags": ["B-Roll"], "color": "rose",
		])
		#expect(!cut.isError, "\(cut.text)")
		let clip = try #require(document.take.clips.first { $0.slug == "the-good-laugh" })
		#expect(clip.start == 7)
		#expect(clip.end == 9.5)
		#expect(clip.color == .rose)
		#expect(clip.tags == ["b-roll"])
		#expect(controller.selectedSlug == "the-good-laugh")
		#expect(document.undoManager.undoActionName == "Add Clip")

		// A slug is a reference. This one was written on the person's behalf,
		// so renaming the clip must not change what a project points at.
		document.setName("Something Else Entirely", for: clip.id)
		#expect(document.take.clips.first { $0.id == clip.id }?.slug == "the-good-laugh")

		let odd = await tools.call("add_clip", arguments: ["start": 1, "end": 2, "color": "mauve"])
		#expect(odd.isError)
	}

	// MARK: - Moving audio

	@Test func theAudioStartsLaterAndNoClipMoves() async throws {
		let controller = try take()
		let document = controller.takeDocument
		let clips = document.take.clips

		let later = await tools.call("set_audio_offset", arguments: ["shift": 0.5])
		#expect(!later.isError, "\(later.text)")
		#expect(abs((document.take.audio?.offset ?? 0) - 1.734) < 1e-9)
		#expect(later.summary.contains("starts 0.500 s later"))
		// One clock: the offset is the only thing that moved.
		#expect(document.take.clips == clips)
		#expect(document.undoManager.undoActionName == "Adjust Alignment")

		// An absolute one, and before the camera this time.
		let earlier = await tools.call("set_audio_offset", arguments: ["offset": "-00:00.250"])
		#expect(document.take.audio?.offset == -0.25)
		#expect(earlier.summary.contains("earlier"))

		let neither = await tools.call("set_audio_offset", arguments: [:])
		#expect(neither.isError)
	}

	@Test func aSoundOfTheProgrammeIsMovedAndWrittenAndComesBack() async throws {
		_ = try take(open: false)
		let controller = try project([
			Sound(file: "music/bed.wav", span: .times(from: 2, to: 10)),
			Sound(file: "music/sting.wav", span: .marks(from: .group("intro"), to: .group("intro"))),
		])
		desk.showing = controller
		let document = controller.composeDocument
		let file = try #require(document.url)

		let moved = await tools.call("shift_sound", arguments: ["sound": "bed.wav", "by": 1.5])
		#expect(!moved.isError, "\(moved.text)")
		#expect(document.project.sounds[0].span == .times(from: 3.5, to: 11.5))
		// A project is written as it is edited, by a person or by this.
		#expect(try ProjectReader.read(String(contentsOf: file, encoding: .utf8)).sounds[0].span
			== .times(from: 3.5, to: 11.5))

		// It cannot start before the programme does.
		_ = await tools.call("shift_sound", arguments: ["sound": 1, "by": -60])
		#expect(document.project.sounds[0].span == .times(from: 0, to: 8))

		document.undoManager.undo()
		document.undoManager.undo()
		#expect(document.project.sounds[0].span == .times(from: 2, to: 10))

		// One bound to a group has no time of its own; unbinding it is a
		// decision, so it is handed back rather than made.
		let bound = await tools.call("shift_sound", arguments: ["sound": "music/sting.wav", "by": 1])
		#expect(bound.isError)
		#expect(bound.text.contains("bound to a clip or a group"))
		#expect(document.project.sounds[1].span == .marks(from: .group("intro"), to: .group("intro")))

		let unknown = await tools.call("shift_sound", arguments: ["sound": "nope.wav", "by": 1])
		#expect(unknown.text.contains("1: music/bed.wav"))
	}

	/// The request this came from: start the song fourteen seconds in. That is
	/// a key on the sound, and the answer says what cuttr now takes it to mean —
	/// which is the only way to tell a key that was read from one that was not.
	@Test func aSoundIsStartedPartWayIntoItsFileAndTheAnswerSaysSo() async throws {
		_ = try take(open: false)
		for path in ["media/clip.mov", "media/clip-mic.wav", "music/song.mp3"] { try touch(path) }
		let controller = try project([Sound(file: "music/song.mp3", span: .times(from: 1, to: 2))])
		desk.showing = controller
		let document = controller.composeDocument
		#expect(document.resolved != nil, "\(document.problem ?? "")")

		let before = await tools.call("get_context", arguments: [:])
		#expect(before.text.contains("sound 1: music/song.mp3 plays 00:01.000–00:02.000, from the top of the file"))

		let edited = await tools.call("edit_document", arguments: [
			"old": "    to:    00:02.000\n", "new": "    to:    00:02.000\n    start: 00:13.915\n",
			"summary": "Start the song at the chorus",
		])
		#expect(!edited.isError, "\(edited.text)")
		#expect(document.project.sounds[0].fileStart == 13.915)
		// Where it plays has not moved; which part of the file is heard has.
		#expect(document.project.sounds[0].span == .times(from: 1, to: 2))
		#expect(edited.text.contains("sound 1: music/song.mp3 plays 00:01.000–00:02.000, from 00:13.915 of the file"))
		#expect(try String(contentsOf: #require(document.url), encoding: .utf8)
			.contains("    start: 00:13.915   # in the file\n"))

		// A key cuttr does not have changes nothing, and the answer shows that
		// it changed nothing rather than leaving it to be assumed.
		let guessed = await tools.call("edit_document", arguments: [
			"old": "    start: 00:13.915   # in the file\n", "new": "    skip: 00:20.000\n",
		])
		#expect(guessed.text.contains("from the top of the file"))

		let refused = await tools.call("edit_document", arguments: [
			"old": "    to:    00:02.000\n", "new": "    to:    00:02.000\n    start: 00:09.000\n    end: 00:03.000\n",
		])
		#expect(refused.isError)
	}

	/// A sound written inside a timeline entry is a sound: it is in the list
	/// under the same numbering, and it can be moved.
	@Test func aSoundInsideATimelineEntryIsFoundAndMoved() async throws {
		_ = try take(open: false)
		for path in ["media/clip.mov", "media/clip-mic.wav", "bed.wav", "sting.wav", "whole.wav"] { try touch(path) }
		let controller = try project(
			[Sound(file: "bed.wav", span: .times(from: 0, to: 1))],
			inside: [
				Sound(file: "sting.wav", span: .within(.init("mia-intro"), from: 0.25, to: 1)),
				Sound(file: "whole.wav", span: nil),
			])
		desk.showing = controller
		let document = controller.composeDocument
		#expect(document.resolved != nil, "\(document.problem ?? "")")

		let context = await tools.call("get_context", arguments: [:])
		#expect(context.text.contains("sound 1: bed.wav plays"))
		#expect(context.text.contains("sound 2: sting.wav (inside a timeline entry) plays 00:00.250–00:01.000"))
		#expect(context.text.contains("sound 3: whole.wav (inside a timeline entry) plays 00:00.000–00:02.000"))

		let moved = await tools.call("shift_sound", arguments: ["sound": "sting.wav", "by": 0.5])
		#expect(!moved.isError, "\(moved.text)")
		#expect(document.project.timeline[0].sounds[0].span == .within(.init("mia-intro"), from: 0.75, to: 1.5))
		#expect(document.project.sounds[0].span == .times(from: 0, to: 1))

		// By the number the context gave it, too.
		_ = await tools.call("shift_sound", arguments: ["sound": 2, "by": -0.25])
		#expect(document.project.timeline[0].sounds[0].span == .within(.init("mia-intro"), from: 0.5, to: 1.25))

		// One with no range of its own plays for its placement and has no time
		// to shift — said, with the two things that can be done instead.
		let whole = await tools.call("shift_sound", arguments: ["sound": "whole.wav", "by": 1])
		#expect(whole.isError)
		#expect(whole.text.contains("no range of its own"))
		#expect(whole.text.contains("`start:`"))
		#expect(document.project.timeline[0].sounds[1].span == nil)
	}

	// MARK: - A copy of part of a file

	private func wave(_ path: String, seconds: Double) throws {
		let rate = 8000, count = Int(Double(rate) * seconds)
		var data = Data()
		func put(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
		func put32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
		func put16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
		put("RIFF"); put32(UInt32(36 + count * 2)); put("WAVE")
		put("fmt "); put32(16); put16(1); put16(1)
		put32(UInt32(rate)); put32(UInt32(rate * 2)); put16(2); put16(16)
		put("data"); put32(UInt32(count * 2))
		for sample in 0..<count { put16(UInt16(bitPattern: Int16(sample % 20000))) }
		let url = folder.appendingPathComponent(path)
		try FileManager.default.createDirectory(
			at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
		try data.write(to: url)
	}

	@Test func aCopyOfPartOfAFileIsWrittenOnlyWhereASoundCouldLive() async throws {
		_ = try take(open: false)
		try wave("music/song.wav", seconds: 3)
		let controller = try project()
		desk.showing = controller
		let source = folder.appendingPathComponent("music/song.wav")
		let before = try Data(contentsOf: source)

		// Asked first: it puts a file on disk.
		let arguments: JSONObject = ["source": "music/song.wav", "start": "00:01.000", "end": 2.5]
		let question = try #require(tools.question(before: "trim_audio", arguments: arguments))
		#expect(question.contains("song-from-00-01.000.wav"))
		#expect(question.contains("the original is not changed"))

		let written = await tools.call("trim_audio", arguments: arguments)
		#expect(!written.isError, "\(written.text)")
		let copy = folder.appendingPathComponent("music/song-from-00-01.000.wav")
		#expect(FileManager.default.fileExists(atPath: copy.path))
		// Said the way the project file wants it.
		#expect(written.text.contains("`file: music/song-from-00-01.000.wav`"))
		#expect(written.text.contains("00:01.500 of song.wav"))
		#expect(try Data(contentsOf: source) == before)

		// Not twice over the same name, not over the original, and not anywhere
		// that is neither the project's folder nor the file's own.
		let again = await tools.call("trim_audio", arguments: arguments)
		#expect(again.isError)
		let outside = await tools.call("trim_audio", arguments: [
			"source": "music/song.wav", "start": 1, "target": NSTemporaryDirectory() + "elsewhere-\(UUID().uuidString).wav",
		])
		#expect(outside.isError)
		#expect(outside.text.contains("is neither"))
		let climbing = await tools.call("trim_audio", arguments: [
			"source": "music/song.wav", "start": 1, "target": "../\(UUID().uuidString).wav",
		])
		#expect(climbing.isError)
		let odd = await tools.call("trim_audio", arguments: [
			"source": "music/song.wav", "start": 1, "target": "music/copy.sh",
		])
		#expect(odd.isError)
		let missing = await tools.call("trim_audio", arguments: ["source": "music/nope.wav", "start": 1])
		#expect(missing.isError)
		// A place in the project's folder that is not beside the source is fine.
		let elsewhere = await tools.call("trim_audio", arguments: [
			"source": "music/song.wav", "start": 2, "target": "cuts/tail.wav",
		])
		#expect(!elsewhere.isError, "\(elsewhere.text)")
		#expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("cuts/tail.wav").path))
	}

	// MARK: - A project, and the takes it lists

	@Test func aProjectIsEditedThroughItsTextAndSaysWhatIsWrongWithIt() async throws {
		_ = try take(open: false)
		let controller = try project()
		desk.showing = controller
		let document = controller.composeDocument

		let edited = await tools.call("edit_document", arguments: [
			"old": "out.mov", "new": "final.mov", "summary": "Rename the output",
		])
		#expect(!edited.isError, "\(edited.text)")
		#expect(document.project.output.file == "final.mov")
		#expect(try String(contentsOf: #require(document.url), encoding: .utf8).contains("final.mov"))
		#expect(document.undoManager.undoActionName == "Rename the output")

		// A clip that is not there parses — and is exactly the thing to hear
		// about before saying "done".
		let wrong = await tools.call("edit_document", arguments: ["old": "mia-intro", "new": "mia-nowhere"])
		#expect(wrong.text.contains("mia-nowhere"))
	}

	@Test func aTakeThatIsNotOpenIsAskedAboutBeforeItIsWritten() async throws {
		let closed = try take(open: false)
		let url = try #require(closed.takeDocument.url)
		let controller = try project()
		desk.showing = controller

		let arguments: JSONObject = [
			"document": "mia-take-1", "old": "Mia, Intro", "new": "Mia, hello",
		]
		// Nothing to put an undo step on, so somebody is asked first.
		#expect(tools.question(before: "edit_document", arguments: arguments)
			== "Write mia-take-1.cuttr on disk? It is not open, so this cannot be undone.")
		// An open document is not asked about: ⌘Z is the answer there.
		#expect(tools.question(before: "edit_document", arguments: ["old": "a", "new": "b"]) == nil)

		let written = await tools.call("edit_document", arguments: arguments)
		#expect(!written.isError, "\(written.text)")
		#expect(try String(contentsOf: url, encoding: .utf8).contains("name:  Mia, hello"))

		let unknown = await tools.call("read_document", arguments: ["document": "walter"])
		#expect(unknown.isError)
		#expect(unknown.text.contains("project “programme”"))
	}

	// MARK: - Looking

	@Test func theContextSaysWhatIsOnScreen() async throws {
		let controller = try take()
		_ = try project()
		controller.go(to: 4.5)
		#expect(controller.show(clip: "mia-outro"))

		#expect(tools.context()
			== "cuttr, now — on screen: take “mia-take-1”, playhead 00:04.000, selected clip mia-outro; also open: project “programme”")

		let whole = await tools.call("get_context", arguments: [:])
		#expect(whole.text.contains("take “mia-take-1”"))
		#expect(whole.text.contains("ON SCREEN"))
		#expect(whole.text.contains("audio media/clip-mic.wav, offset +00:01.234"))
		#expect(whole.text.contains("not transcribed"))
		#expect(whole.text.contains("take “mia-take-1” (mia-take-1.cuttr): 2 clips, open"))

		let sought = await tools.call("seek", arguments: ["time": "00:01.500"])
		#expect(!sought.isError)
		#expect(controller.playheadTime == 1.5)

		let shown = await tools.call("show_document", arguments: ["document": "programme"])
		#expect(!shown.isError)
		#expect(desk.showing is ComposeWindowController)
	}

	@Test func theWordsAreReadALineAtATimeWithTheirTimes() async throws {
		let controller = try take()
		let none = await tools.call("read_transcript", arguments: [:])
		#expect(none.isError)
		#expect(none.text.contains("Transcribe This Take"))

		try controller.takeDocument.setTranscript(Transcript(words: [
			Word(start: 1.0, end: 1.4, text: "Hello"), Word(start: 1.4, end: 2.0, text: "there."),
			Word(start: 5.0, end: 5.5, text: "Second"), Word(start: 5.5, end: 6.0, text: "line."),
		]), recogniser: .allCases[0], locale: "en-GB")

		let all = await tools.call("read_transcript", arguments: [:])
		#expect(all.text == "[00:01.000–00:02.000] Hello there.\n[00:05.000–00:06.000] Second line.")
		let found = await tools.call("read_transcript", arguments: ["find": "second"])
		#expect(found.text == "[00:05.000–00:06.000] Second line.")
		let early = await tools.call("read_transcript", arguments: ["to": 3])
		#expect(early.text == "[00:01.000–00:02.000] Hello there.")
	}

	// MARK: - Commands

	@MainActor private final class Receiver: NSObject {
		var ran: [String] = []
		@objc func align(_ sender: Any?) { ran.append("align") }
		@objc func close(_ sender: Any?) { ran.append("close") }
	}

	@Test func aMenuCommandIsRunByItsNameAndTheOnesThatEndThingsAsk() async throws {
		let receiver = Receiver()
		let bar = NSMenu()
		func menu(_ title: String, _ items: [(String, Selector, Bool)]) {
			let top = NSMenuItem()
			let menu = NSMenu(title: title)
			menu.autoenablesItems = false
			for (name, action, enabled) in items {
				let item = NSMenuItem(title: name, action: action, keyEquivalent: "")
				item.target = receiver
				item.isEnabled = enabled
				menu.addItem(item)
			}
			top.submenu = menu
			bar.addItem(top)
		}
		menu("Audio", [("Align Automatically", #selector(Receiver.align(_:)), true),
		               ("Transcribe This Take", #selector(Receiver.align(_:)), false)])
		menu("File", [("Close", #selector(Receiver.close(_:)), true)])
		let tools = AssistantTools(desk: desk, menu: { bar })

		let listed = await tools.call("list_commands", arguments: [:])
		#expect(listed.text.contains("Audio ▸ Align Automatically"))
		#expect(listed.text.contains("Audio ▸ Transcribe This Take  — not available now"))

		let ran = await tools.call("run_command", arguments: ["command": "audio > align automatically"])
		#expect(!ran.isError, "\(ran.text)")
		#expect(receiver.ran == ["align"])

		let greyed = await tools.call("run_command", arguments: ["command": "Transcribe This Take"])
		#expect(greyed.isError)
		let unknown = await tools.call("run_command", arguments: ["command": "Make It Good"])
		#expect(unknown.isError)
		#expect(receiver.ran == ["align"])

		#expect(tools.question(before: "run_command", arguments: ["command": "File ▸ Close"])
			== "Run “File ▸ Close”?")
		#expect(tools.question(before: "run_command", arguments: ["command": "Align Automatically"]) == nil)
		#expect(tools.question(before: "save_all", arguments: [:]) != nil)
	}

	/// The real menu bar, listed. Not run: a command aimed down the responder
	/// chain has nowhere to land in a test.
	@Test func everyCommandInTheMenuBarIsThere() async {
		// The menu bar is the application's, so there has to be one.
		_ = NSApplication.shared
		// Listing the commands fills Open Recent, and a test does not ask the
		// system what was open lately.
		RecentProjects.remembered = { [] }
		let bar = MainMenu.build()
		let tools = AssistantTools(desk: desk, menu: { bar })
		let listed = await tools.call("list_commands", arguments: [:])
		for command in ["Audio ▸ Align Automatically", "Audio ▸ Transcribe This Take",
		                "Compose ▸ Render…", "File ▸ Share…", "View ▸ Assistant",
		                "Clip ▸ Split at Playhead", "File ▸ Export Project to Folder…"] {
			#expect(listed.text.contains(command), "\(command)")
		}
		#expect(tools.question(before: "run_command", arguments: ["command": "Share…"]) == "Run “File ▸ Share…”?")
		#expect(tools.question(before: "run_command", arguments: ["command": "Quit cuttr"]) != nil)
	}

	// MARK: - The reference

	/// The reference is the README, and a copy of it only because a package
	/// cannot bundle a file from outside its own target. `make reference`
	/// brings the copy up to date; this is what notices when nobody did.
	@Test func referenceIsTheReadme() throws {
		let root = URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
		let readme = try String(contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8)
		let copy = try String(
			contentsOf: root.appendingPathComponent("Sources/CuttrUI/Reference/README.md"), encoding: .utf8)
		#expect(copy == readme, "Sources/CuttrUI/Reference/README.md is behind README.md — run `make reference`")
	}

	@Test func theReferenceIsReadASectionAtATime() async {
		let sections = await tools.call("reference", arguments: [:])
		#expect(sections.text.contains("- The cut list"))
		#expect(sections.text.contains("- Sounds — audio that is not from a take"))

		let sounds = await tools.call("reference", arguments: ["topic": "sounds"])
		#expect(sounds.text.hasPrefix("### Sounds"))
		#expect(sounds.text.contains("ducks:"))
		#expect(!sounds.text.contains("### Anchors"))

		let nothing = await tools.call("reference", arguments: ["topic": "zeppelins"])
		#expect(nothing.isError)
	}

	/// Every tool the model is told about is one the app answers.
	@Test func everyToolOnTheListIsAnswered() async {
		#expect(Set(tools.tools.map(\.name)).count == tools.tools.count)
		for tool in tools.tools {
			let result = await AssistantTools(desk: nil, menu: { nil }).call(tool.name, arguments: [:])
			#expect(!result.text.contains("no tool called"), "\(tool.name)")
		}
		let unknown = await tools.call("make_coffee", arguments: [:])
		#expect(unknown.text == "cuttr has no tool called make_coffee.")
	}
}
