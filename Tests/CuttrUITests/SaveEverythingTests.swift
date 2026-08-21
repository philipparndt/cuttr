import AppKit
import Testing
@testable import CuttrCompose
@testable import CuttrKit
@testable import CuttrUI

/// One ⌘S, and everything open goes down.
///
/// The assertions here are about *files*, not about handlers: what is on disk
/// afterwards, byte for byte, and the one line the bar is given to say. That is
/// the only way to check the rule this program is built on — a save must not
/// rewrite a file that has not changed — because the difference between "wrote
/// it again" and "left it alone" is invisible from inside the program and
/// obvious from the file.
@MainActor @Suite struct SaveEverythingTests {

	private static let takeFile = """
		cuttr: 1

		video: media/clip.mov

		clips:
		  - slug:  mia-intro
		    name:  Mia, Intro
		    start: 00:00.000
		    end:   00:02.000
		"""

	/// A folder with a project and two takes in it, as somebody's shoot folder
	/// looks.
	private func shoot() throws -> (folder: URL, project: URL, first: URL, second: URL) {
		let folder = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("cuttr-saveall-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		let first = folder.appendingPathComponent("mia-take-1.cuttr")
		let second = folder.appendingPathComponent("walter-take-2.cuttr")
		for url in [first, second] {
			try Self.takeFile.write(to: url, atomically: true, encoding: .utf8)
		}
		let projectFile = folder.appendingPathComponent("programme.cuttrproj")
		var made = Project(takes: ["mia-take-1.cuttr", "walter-take-2.cuttr"],
		                   output: Output(file: "out.mov"))
		made.timeline = []
		try ProjectWriter.write(made).write(to: projectFile, atomically: true, encoding: .utf8)
		return (folder, projectFile, first, second)
	}

	private func take(at url: URL) throws -> MainWindowController {
		let document = TakeDocument()
		try document.read(from: url)
		return MainWindowController(document: document)
	}

	private func project(at url: URL) throws -> ComposeWindowController {
		let document = ComposeDocument()
		try document.read(from: url)
		return ComposeWindowController(document: document)
	}

	/// Renames the first clip, which is the smallest real edit there is.
	private func edit(_ controller: MainWindowController, to name: String) {
		guard let clip = controller.takeDocument.take.clips.first else {
			Issue.record("the take came back with no clips in it")
			return
		}
		controller.takeDocument.setName(name, for: clip.id)
	}

	/// The case the whole command exists for: two takes open, one of them cut
	/// since it was last saved.
	///
	/// The clean take's file is compared byte for byte, because "saved
	/// everything" must not mean "rewrote everything" — the emitters are
	/// hand-written to keep a diff still, and every write is a version in
	/// `refs/cuttr/saves`.
	@Test func onlyTheDirtyTakeIsWritten() throws {
		let files = try shoot()
		defer { try? FileManager.default.removeItem(at: files.folder) }
		let dirty = try take(at: files.first)
		let clean = try take(at: files.second)
		let before = try Data(contentsOf: files.second)
		edit(dirty, to: "Mia, the good one")

		let delegate = AppDelegate()
		delegate.adoptForTesting(controllers: [dirty, clean])
		let report = delegate.saveEverything()

		#expect(report.written == ["mia-take-1"])
		#expect(report.failed.isEmpty)
		#expect(report.untitled.isEmpty)
		#expect(report.line == "saved mia-take-1")
		// What was cut is on disk.
		let written = try String(contentsOf: files.first, encoding: .utf8)
		#expect(written.contains("Mia, the good one"))
		// And what was not cut is the same file it was.
		#expect(try Data(contentsOf: files.second) == before)
		#expect(clean.takeDocument.isDirty == false)
	}

	/// Nothing to do, and it says so rather than appearing to have ignored the
	/// key.
	@Test func nothingDirtySaysSo() throws {
		let files = try shoot()
		defer { try? FileManager.default.removeItem(at: files.folder) }
		let one = try take(at: files.first)
		let two = try take(at: files.second)
		let before = (try Data(contentsOf: files.first), try Data(contentsOf: files.second))

		let delegate = AppDelegate()
		delegate.adoptForTesting(controllers: [one, two])
		let report = delegate.saveEverything()

		#expect(report.written.isEmpty)
		#expect(report.line == "everything is already saved")
		#expect(try Data(contentsOf: files.first) == before.0)
		#expect(try Data(contentsOf: files.second) == before.1)
	}

	/// The project is one of the documents, and it is not rewritten either
	/// unless it changed. A project window writes as it is edited, so most ⌘S
	/// presses find it clean.
	@Test func theProjectGoesDownWithTheTakesAndOnlyWhenItChanged() throws {
		let files = try shoot()
		defer { try? FileManager.default.removeItem(at: files.folder) }
		let composer = try project(at: files.project)
		let cutting = try take(at: files.first)
		let before = try Data(contentsOf: files.project)
		edit(cutting, to: "Mia, take one")

		let delegate = AppDelegate()
		delegate.adoptForTesting(composers: [composer], controllers: [cutting])
		#expect(delegate.saveEverything().written == ["mia-take-1"])
		#expect(try Data(contentsOf: files.project) == before)

		// Now change the project itself, and both go down together.
		var changed = composer.composeDocument.project
		changed.output = Output(file: "programme.mov")
		composer.composeDocument.apply(changed)
		edit(cutting, to: "Mia, take two")
		let report = delegate.saveEverything()
		#expect(report.written == ["mia-take-1", "programme"])
		#expect(report.line == "saved 2 documents")
		#expect(try Data(contentsOf: files.project) != before)
	}

	/// A take whose folder has gone must not take the others with it, and must
	/// be named. This is what a card being unplugged mid-session looks like.
	@Test func oneThatCannotBeWrittenIsNamedAndTheRestGoDown() throws {
		let files = try shoot()
		defer { try? FileManager.default.removeItem(at: files.folder) }
		// A take in a folder of its own, so removing the folder breaks that one
		// take and nothing else.
		let away = files.folder.appendingPathComponent("card")
		try FileManager.default.createDirectory(at: away, withIntermediateDirectories: true)
		let strandedURL = away.appendingPathComponent("walter-take-3.cuttr")
		try Self.takeFile.write(to: strandedURL, atomically: true, encoding: .utf8)

		let good = try take(at: files.first)
		let stranded = try take(at: strandedURL)
		edit(good, to: "Mia, still here")
		edit(stranded, to: "Walter, gone")
		try FileManager.default.removeItem(at: away)

		let delegate = AppDelegate()
		delegate.adoptForTesting(controllers: [stranded, good])
		let report = delegate.saveEverything()

		#expect(report.written == ["mia-take-1"])
		#expect(report.failed.map(\.name) == ["walter-take-3"])
		#expect(report.line.hasPrefix("could not write walter-take-3 — "))
		#expect(report.line.contains("saved mia-take-1"))
		// The one that could be written was written, whatever happened to the
		// other.
		#expect(try String(contentsOf: files.first, encoding: .utf8).contains("Mia, still here"))
	}

	/// A take that has never been saved has nowhere to go, so it is named rather
	/// than asked about — twenty documents must not mean twenty sheets. ⌥⌘S is
	/// how somebody says where it should live.
	@Test func anUntitledTakeIsNamedRatherThanAskedAbout() throws {
		let files = try shoot()
		defer { try? FileManager.default.removeItem(at: files.folder) }
		let saved = try take(at: files.first)
		edit(saved, to: "Mia, named")

		let fresh = TakeDocument()
		var made = Take()
		made.video = "/Volumes/card/clip.mov"
		made.clips = [Clip(slug: "one", name: "One", start: 0, end: 1)]
		fresh.apply(made, actionName: "Cut")
		#expect(fresh.isDirty)
		let untitled = MainWindowController(document: fresh)

		let delegate = AppDelegate()
		delegate.adoptForTesting(controllers: [saved, untitled])
		let report = delegate.saveEverything()

		#expect(report.written == ["mia-take-1"])
		#expect(report.untitled == ["clip"])
		#expect(report.line == "saved mia-take-1  ·  clip has never been saved — ⌥⌘S says where")
		// Still unsaved, and still holding what was cut into it.
		#expect(untitled.takeDocument.url == nil)
		#expect(untitled.takeDocument.isDirty)
	}

	/// A take is two files when it has words in it, and the second one is the
	/// reason a transcript counts as unsaved work.
	///
	/// Naming who is speaking changes the sidecar and nothing else, so this is
	/// the one case where a save writes a `.cuttr` that says exactly what it
	/// said before — and it must still say it byte for byte.
	@Test func aTakeDirtyOnlyInItsWordsWritesTheSidecarAndNotTheTakeAgain() throws {
		let files = try shoot()
		defer { try? FileManager.default.removeItem(at: files.folder) }
		let cutting = try take(at: files.first)
		try cutting.takeDocument.setTranscript(
			Transcript(words: [Word(start: 0, end: 0.4, text: "Right"),
			                   Word(start: 0.5, end: 1.0, text: "then")]),
			recogniser: .hand, locale: "en_GB")

		let delegate = AppDelegate()
		delegate.adoptForTesting(controllers: [cutting])
		#expect(delegate.saveEverything().written == ["mia-take-1"])

		let sidecar = files.folder.appendingPathComponent("words/mia-take-1.words")
		let takeBytes = try Data(contentsOf: files.first)
		let wordsBytes = try Data(contentsOf: sidecar)

		cutting.takeDocument.assignSpeaker("mia", to: 0 ..< 1)
		#expect(cutting.takeDocument.isDirty)
		#expect(delegate.saveEverything().written == ["mia-take-1"])
		#expect(try Data(contentsOf: sidecar) != wordsBytes)
		#expect(try Data(contentsOf: files.first) == takeBytes)
	}

	/// Two untitled documents are one line, not two panels.
	@Test func severalUntitledDocumentsAreCounted() throws {
		var report = SaveReport()
		report.add(.untitled("one"))
		report.add(.untitled("two"))
		report.add(.unchanged)
		#expect(report.line == "2 documents have never been saved — ⌥⌘S says where")
	}

	/// Several failures are one line as well: the first by name, the rest
	/// counted. A label's width is the width of its whole string, so a line that
	/// joined twenty of them would decide the width of the window meant to
	/// contain it.
	@Test func severalFailuresAreOneLine() throws {
		var report = SaveReport()
		report.add(.failed(name: "one", reason: "the volume has gone"))
		report.add(.failed(name: "two", reason: "the volume has gone"))
		report.add(.saved("three"))
		#expect(report.line
			== "could not write one — the volume has gone · and 1 more  ·  saved three")
	}
}
