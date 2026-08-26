import AppKit
import Foundation
import Testing
@testable import CuttrCompose
@testable import CuttrKit
@testable import CuttrUI

/// Levelling a project's takes against each other.
///
/// The assertions here are about the two things that can be got wrong without
/// anybody noticing. **One scale**, because rows drawn at two scales cannot be
/// compared and look exactly like rows that can. And **the file**, because a
/// slider that writes on every event would rewrite a take per pixel of travel —
/// and a take being written is a version kept, so it would fill somebody's
/// version branch too.
@MainActor @Suite struct LevelBoardTests {

	// MARK: - A shoot to level

	private static func takeFile(media: String, clips: [(String, String, String)]) -> String {
		var text = "cuttr: 1\n\n\(media)\n\nclips:\n"
		for (slug, start, end) in clips {
			text += "  - slug:  \(slug)\n    start: \(start)\n    end:   \(end)\n"
		}
		return text
	}

	/// A folder with a project and two takes in it, as somebody's shoot folder
	/// looks. The media is named but not written: nothing here decodes.
	private func shoot(timeline: Bool = true) throws
		-> (folder: URL, project: URL, first: URL, second: URL) {
		let folder = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("cuttr-levels-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		let first = folder.appendingPathComponent("mia-take-1.cuttr")
		let second = folder.appendingPathComponent("walter-take-2.cuttr")
		try Self.takeFile(media: "video: media/mia.mov",
		                  clips: [("mia-intro", "00:01.000", "00:04.000"),
		                          ("mia-again", "00:10.000", "00:12.000")])
			.write(to: first, atomically: true, encoding: .utf8)
		try Self.takeFile(media: "video: media/walter.mov",
		                  clips: [("walter-one", "00:00.000", "00:06.000")])
			.write(to: second, atomically: true, encoding: .utf8)

		let projectFile = folder.appendingPathComponent("programme.cuttrproj")
		var made = Project(takes: ["mia-take-1.cuttr", "walter-take-2.cuttr"],
		                   output: Output(file: "out.mov"))
		made.timeline = timeline
			? [TimelineEntry(clip: ClipReference("mia-intro")),
			   TimelineEntry(clip: ClipReference("walter-one"))]
			: []
		try ProjectWriter.write(made).write(to: projectFile, atomically: true, encoding: .utf8)
		return (folder, projectFile, first, second)
	}

	private func boardOver(_ project: URL) throws -> (LevelBoard, ComposeDocument) {
		let document = ComposeDocument()
		try document.read(from: project)
		let board = LevelBoard()
		board.reload(from: document)
		return (board, document)
	}

	// MARK: - One scale

	/// The longest take fills the row and the rest end where they end.
	///
	/// The whole page rests on this: a row stretched to fit would be a lie about
	/// which take is longer, and the reader would have no way of telling.
	@Test func theLongestTakeFillsTheWidthAndTheRestEndWhereTheyEnd() {
		let scale = LevelScale.across([30, 60, 15], width: 600)
		#expect(abs(scale.secondsPerPoint - 0.1) < 1e-12)
		#expect(scale.width(forSeconds: 60) == 600)
		#expect(scale.width(forSeconds: 30) == 300)
		#expect(scale.width(forSeconds: 15) == 150)
	}

	/// One seconds-per-point, so a second is the same distance on every row.
	/// Adding a longer take shrinks all of them by the same factor rather than
	/// re-fitting each one.
	@Test func aSecondIsTheSameDistanceOnEveryRow() {
		let two = LevelScale.across([30, 60], width: 600)
		for length in [1.0, 7.5, 30.0, 60.0] {
			#expect(abs(two.width(forSeconds: length) - CGFloat(length * 10)) < 1e-9)
		}
		// A five-minute take joins the project: every row is now at the new
		// scale, and the ratios between them are what they were.
		let three = LevelScale.across([30, 60, 300], width: 600)
		#expect(three.width(forSeconds: 60) / three.width(forSeconds: 30) == 2)
		#expect(three.width(forSeconds: 60) < two.width(forSeconds: 60))
	}

	/// Nothing to draw, and no width to draw it in, are both answered rather
	/// than divided by.
	@Test func anEmptyPageHasNoScaleAndDoesNotDivideByIt() {
		#expect(LevelScale.across([], width: 600).secondsPerPoint == 0)
		#expect(LevelScale.across([0, 0], width: 600).secondsPerPoint == 0)
		#expect(LevelScale.across([60], width: 0).secondsPerPoint == 0)
		#expect(LevelScale.across([60], width: 0).width(forSeconds: 60) == 0)
	}

	/// The level is in the picture: ten decibels is a little over three times
	/// the height, and what goes past the lane is drawn flat against it.
	@Test func theLevelIsInTheHeightOfTheLine() {
		let plain = LevelLane.amplitude(height: 46, zoom: 1, gain: 0)
		#expect(plain == 21)
		let up = LevelLane.amplitude(height: 46, zoom: 1, gain: 10)
		#expect(abs(up / plain - 3.1623) < 0.001)
		let down = LevelLane.amplitude(height: 46, zoom: 1, gain: -6)
		#expect(abs(down / plain - 0.5012) < 0.001)
		// The magnifier multiplies the same height and means something else
		// entirely, which is why it is not the level.
		#expect(LevelLane.amplitude(height: 46, zoom: 4, gain: 0) == plain * 4)
		// A peak past the edge is drawn at the edge.
		#expect(LevelLane.limit(height: 46) == 22)
		#expect(min(1.0 * up, LevelLane.limit(height: 46)) == 22)
	}

	// MARK: - The slider

	/// Tenths of a decibel, which is what the take file holds exactly, and no
	/// further than a correction goes.
	@Test func theSliderWritesTenthsAndStopsAtTheLimit() {
		#expect(LevelBoard.level(fromSlider: 0) == 0)
		#expect(LevelBoard.level(fromSlider: 3.04) == 3)
		#expect(LevelBoard.level(fromSlider: 3.06) == 3.1)
		#expect(LevelBoard.level(fromSlider: -2.449) == -2.4)
		#expect(LevelBoard.level(fromSlider: 40) == Levelling.limit)
		#expect(LevelBoard.level(fromSlider: -40) == -Levelling.limit)
		// A tenth survives the file: what is read back is what was set.
		var take = Take(video: "a.mov", clips: [Clip(slug: "one", start: 0, end: 1)])
		take.gain = LevelBoard.level(fromSlider: -7.649)
		let read = try? TakeReader.read(TakeWriter.write(take))
		#expect(read?.gain == -7.6)
	}

	/// Nought reads as nought rather than as a blank row that has not loaded.
	@Test func aLevelReadsAsASignAndATenth() {
		#expect(LevelBoard.decibels(0) == "0 dB")
		#expect(LevelBoard.decibels(3) == "+3 dB")
		#expect(LevelBoard.decibels(-4.5) == "−4.5 dB")
	}

	// MARK: - What is drawn, played and measured

	/// The spans are the stretches the programme plays, merged and in order.
	///
	/// Merged because a clip used twice, and two clips cut on different lanes
	/// over the same seconds, are one piece of recording as far as a level is
	/// concerned — and because the meter counts a second once however many
	/// ranges cover it, so anything that drew or played it twice would be
	/// levelling by a picture of something it had not measured.
	@Test func theSpansAreTheStretchesTheProgrammePlays() {
		let take = Take(clips: [Clip(slug: "a", start: 0, end: 5),
		                        Clip(slug: "b", start: 30, end: 40)])
		let used = LevelBoard.spans(of: take, usedBy: [
			2 ... 4,        // one shot
			2 ... 4,        // the same shot, used twice on the programme
			3 ... 6,        // an alternate that overlaps it
			30 ... 31,
		])
		#expect(used == [2 ... 6, 30 ... 31])

		// A take the timeline has not reached yet is still a take to level, so
		// its own clips are what it is for.
		#expect(LevelBoard.spans(of: take, usedBy: []) == [0 ... 5, 30 ... 40])

		// And a take nobody has cut is the whole recording, said the way the
		// meter says it.
		#expect(LevelBoard.spans(of: Take(), usedBy: []).isEmpty)
		#expect(LevelBoard.spans(of: nil, usedBy: []).isEmpty)
	}

	/// A separate recorder's spans are on its own clock.
	///
	/// One clock: the clips are on the video's, and the offset is the only thing
	/// that relates the two. Positive means the recorder was started after the
	/// camera, so a clip at video time `t` is at `t − offset` in its file — and
	/// a clip from before the recorder was rolling is trimmed to where the file
	/// begins rather than asked for at a negative second.
	@Test func aSeparateRecordersSpansAreOnItsOwnClock() {
		let board = LevelBoard()
		let recorder = LevelBoard.Row(
			url: URL(fileURLWithPath: "/tmp/take.cuttr"), name: "take",
			media: URL(fileURLWithPath: "/tmp/rec.wav"), offset: 2.5,
			spans: [10 ... 14, 1 ... 3, 0 ... 1], gain: 0, written: 0)
		#expect(board.fileSpans(for: recorder) == [7.5 ... 11.5, 0 ... 0.5])

		// The camera's own sound is already on the clock the clips are on.
		let camera = LevelBoard.Row(
			url: URL(fileURLWithPath: "/tmp/take.cuttr"), name: "take",
			media: URL(fileURLWithPath: "/tmp/clip.mov"), offset: 0,
			spans: [10 ... 14], gain: 0, written: 0)
		#expect(board.fileSpans(for: camera) == [10 ... 14])

		// And the whole recording stays the whole recording, which is what an
		// empty list means to the meter.
		let uncut = LevelBoard.Row(
			url: URL(fileURLWithPath: "/tmp/take.cuttr"), name: "take",
			media: URL(fileURLWithPath: "/tmp/clip.mov"), offset: 3,
			spans: [], gain: 0, written: 0)
		#expect(board.fileSpans(for: uncut).isEmpty)
	}

	/// A row is a take, in the order the project lists them, and it knows how
	/// much tape it has to draw.
	@Test func aRowPerTakeInTheProjectsOwnOrder() throws {
		let files = try shoot()
		defer { try? FileManager.default.removeItem(at: files.folder) }
		let (board, _) = try boardOver(files.project)

		#expect(board.rows.map(\.name) == ["mia-take-1", "walter-take-2"])
		// Only what the programme uses: `mia-again` is cut and not used, so it
		// is not part of what this take contributes.
		#expect(board.rows[0].spans == [1 ... 4])
		#expect(board.rows[0].length == 3)
		#expect(board.rows[1].length == 6)
	}

	/// A take the timeline does not use yet is still on the page, because a
	/// level is a fact about a recording and a shoot is levelled before it is
	/// assembled.
	@Test func aTakeTheProgrammeDoesNotUseIsStillARow() throws {
		let files = try shoot(timeline: false)
		defer { try? FileManager.default.removeItem(at: files.folder) }
		let (board, _) = try boardOver(files.project)
		#expect(board.rows.count == 2)
		#expect(board.rows[0].spans == [1 ... 4, 10 ... 12])
	}

	// MARK: - When a level reaches the file

	/// Dragging sets the level; letting go writes it.
	@Test func aLevelReachesTheFileWhenTheSliderIsLetGo() throws {
		let files = try shoot()
		defer { try? FileManager.default.removeItem(at: files.folder) }
		let (board, _) = try boardOver(files.project)
		let before = try Data(contentsOf: files.first)

		board.set(-4.5, for: files.first)
		#expect(board.rows[0].gain == -4.5)
		#expect(board.rows[0].isPending)
		#expect(try Data(contentsOf: files.first) == before,
		        "the file was written while the slider was still moving")

		#expect(board.commit(files.first) == .wrote("mia-take-1"))
		#expect(board.rows[0].isPending == false)
		let written = try String(contentsOf: files.first, encoding: .utf8)
		#expect(written.contains("gain:  -4.5"))
		// The rest of the take is the take: a level is one key of somebody
		// else's file.
		#expect(written.contains("mia-intro"))
		#expect(written.contains("mia-again"))
		#expect(try TakeReader.read(written).clips.count == 2)
	}

	/// Only the takes that moved are written, and writing a level twice writes
	/// it once. Re-saving an unchanged take must leave the file alone.
	@Test func onlyTheTakesThatMovedAreWritten() throws {
		let files = try shoot()
		defer { try? FileManager.default.removeItem(at: files.folder) }
		let (board, _) = try boardOver(files.project)
		let untouched = try Data(contentsOf: files.second)

		board.set(2, for: files.first)
		#expect(board.commitPending() == ["mia-take-1"])
		#expect(try Data(contentsOf: files.second) == untouched,
		        "levelling one take rewrote another")

		let after = try Data(contentsOf: files.first)
		#expect(board.commitPending().isEmpty)
		#expect(board.commit(files.first) == .unchanged)
		#expect(try Data(contentsOf: files.first) == after,
		        "the same level was written again")

		// And back to nought takes the key out of the file rather than leaving
		// `gain: 0` behind looking like a decision.
		board.set(0, for: files.first)
		#expect(board.commit(files.first) == .wrote("mia-take-1"))
		#expect(try String(contentsOf: files.first, encoding: .utf8).contains("gain:") == false)
	}

	/// A take re-cut in another tab while this page was open keeps its cuts.
	///
	/// This is why the write reads the file again instead of writing back the
	/// take it read when the page opened: a level is one key, and the rest of
	/// the file is work somebody else has done since.
	@Test func aTakeReCutWhileThePageWasOpenKeepsItsCuts() throws {
		let files = try shoot()
		defer { try? FileManager.default.removeItem(at: files.folder) }
		let (board, _) = try boardOver(files.project)

		// Somebody cuts another clip in the cutting window and saves.
		var recut = try TakeReader.read(try String(contentsOf: files.first, encoding: .utf8))
		recut.clips.append(Clip(slug: "mia-third", start: 20, end: 22))
		try TakeWriter.write(recut).write(to: files.first, atomically: true, encoding: .utf8)

		board.set(1.5, for: files.first)
		#expect(board.commit(files.first) == .wrote("mia-take-1"))
		let take = try TakeReader.read(try String(contentsOf: files.first, encoding: .utf8))
		#expect(take.gain == 1.5)
		#expect(take.clips.map(\.slug) == ["mia-intro", "mia-again", "mia-third"])
	}

	/// The prose and the keys a later version wrote are carried through, because
	/// the emitter is the one that carries them.
	@Test func aLevelDoesNotEatWhatTheFileCarried() throws {
		let files = try shoot()
		defer { try? FileManager.default.removeItem(at: files.folder) }
		var text = try String(contentsOf: files.first, encoding: .utf8)
		text = text.replacingOccurrences(
			of: "clips:", with: "chapters: [one, two]\n\n# Mia's good take.\nclips:")
		try text.write(to: files.first, atomically: true, encoding: .utf8)

		let (board, _) = try boardOver(files.project)
		board.set(-1, for: files.first)
		#expect(board.commit(files.first) == .wrote("mia-take-1"))
		let written = try String(contentsOf: files.first, encoding: .utf8)
		#expect(written.contains("chapters:"))
		#expect(written.contains("# Mia's good take."))
	}

	/// A take whose file has gone is named rather than taking the page down
	/// with it.
	@Test func aTakeThatCannotBeWrittenSaysSo() throws {
		let files = try shoot()
		defer { try? FileManager.default.removeItem(at: files.folder) }
		let (board, _) = try boardOver(files.project)
		try FileManager.default.removeItem(at: files.first)

		board.set(3, for: files.first)
		guard case .failed = board.commit(files.first) else {
			Issue.record("a missing take was written")
			return
		}
		// The other one still goes down.
		board.set(-3, for: files.second)
		#expect(board.commit(files.second) == .wrote("walter-take-2"))
	}

	// MARK: - The page in the window

	/// The rail has a fifth place, and going there draws every take at one
	/// scale in one width.
	@Test func theRailHasAFifthPlaceForLevels() throws {
		_ = NSApplication.shared
		let files = try shoot()
		defer { try? FileManager.default.removeItem(at: files.folder) }
		let document = ComposeDocument()
		try document.read(from: files.project)
		let controller = ComposeWindowController(document: document)
		defer { controller.window?.close() }
		let window = controller.windowForTesting
		window.setContentSize(NSSize(width: 1400, height: 900))
		window.layoutIfNeeded()

		#expect(controller.railForTesting.countForTesting
			== ComposeWindowController.Mode.allCases.count)
		#expect(ComposeWindowController.Mode.levels.rawValue == 3)
		controller.show(.levels)
		window.layoutIfNeeded()
		#expect(controller.railForTesting.selected == 3)
		#expect(controller.modeForTesting == .levels)

		let page = controller.levelsForTesting
		let rows = page.rowsForTesting
		#expect(rows.count == 2, "\(rows.count) rows for two takes")
		// Every lane the same width, which is what makes one scale possible at
		// all: the controls to their left are fixed widths on purpose.
		let widths = Set(rows.map(\.laneWidth))
		#expect(widths.count == 1, "the lanes came out \(widths)")
		#expect((widths.first ?? 0) > 100, "the lanes are \(widths) wide")
		// And one scale, handed to all of them.
		#expect(Set(rows.map(\.scale)).count == 1)
		let scale = try #require(rows.first?.scale)
		#expect(scale.width(forSeconds: 6) > scale.width(forSeconds: 3))
	}

	/// Leaving the page writes what was left half-set. ⌘S cannot: the takes on
	/// this page are files the project points at, not documents in a window.
	@Test func leavingThePageWritesWhatWasSet() throws {
		_ = NSApplication.shared
		let files = try shoot()
		defer { try? FileManager.default.removeItem(at: files.folder) }
		let document = ComposeDocument()
		try document.read(from: files.project)
		let controller = ComposeWindowController(document: document)
		defer { controller.window?.close() }
		let window = controller.windowForTesting
		window.setContentSize(NSSize(width: 1400, height: 900))
		controller.show(.levels)
		window.layoutIfNeeded()

		// A drag that has not been let go of.
		controller.levelsForTesting.dragForTesting(1, to: -5.05, finished: false)
		#expect(try String(contentsOf: files.second, encoding: .utf8).contains("gain:") == false)

		controller.show(.edit)
		let written = try String(contentsOf: files.second, encoding: .utf8)
		#expect(written.contains("gain:  -5.1"), "the file says \(written)")
	}

	// MARK: - Measuring, on real audio

	/// Two recordings six decibels apart come level with each other, and the
	/// trims land in the take files.
	///
	/// A real decode: two WAVs through the meter, matched to the median — which
	/// for two is the middle of them, so each moves half the distance and
	/// neither is turned up to meet the louder one.
	@Test func measuringBringsTwoTakesLevel() async throws {
		let folder = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("cuttr-levels-heard-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: folder) }
		try sine(amplitude: 0.05, seconds: 4, to: folder.appendingPathComponent("quiet.wav"))
		try sine(amplitude: 0.1, seconds: 4, to: folder.appendingPathComponent("loud.wav"))

		let quiet = folder.appendingPathComponent("quiet-take.cuttr")
		let loud = folder.appendingPathComponent("loud-take.cuttr")
		try Self.takeFile(media: "audio: quiet.wav",
		                  clips: [("quiet-one", "00:00.500", "00:03.500")])
			.write(to: quiet, atomically: true, encoding: .utf8)
		try Self.takeFile(media: "audio: loud.wav",
		                  clips: [("loud-one", "00:00.500", "00:03.500")])
			.write(to: loud, atomically: true, encoding: .utf8)
		let projectFile = folder.appendingPathComponent("programme.cuttrproj")
		var made = Project(takes: ["quiet-take.cuttr", "loud-take.cuttr"],
		                   output: Output(file: "out.mov"))
		made.timeline = [TimelineEntry(clip: ClipReference("quiet-one")),
		                 TimelineEntry(clip: ClipReference("loud-one"))]
		try ProjectWriter.write(made).write(to: projectFile, atomically: true, encoding: .utf8)

		let (board, _) = try boardOver(projectFile)
		#expect(board.rows.count == 2)
		var seen: [Double] = []
		let line = await board.measure { seen.append($0) }

		// Something moved, and it said so as it went rather than after minutes
		// of nothing.
		#expect(seen.last == 1)
		#expect(line.contains("heard 2 takes"), "it said \(line)")
		let up = try #require(board.rows.first { $0.name == "quiet-take" })
		let down = try #require(board.rows.first { $0.name == "loud-take" })
		#expect(abs(up.gain - 3.0) < 0.3, "the quiet one moved \(up.gain)")
		#expect(abs(down.gain + 3.0) < 0.3, "the loud one moved \(down.gain)")
		#expect(abs((up.loudness ?? 0) - (down.loudness ?? 0) + 6.0206) < 0.2)

		// And both are in the files, so the renderer will honour them.
		#expect(try TakeReader.read(try String(contentsOf: quiet, encoding: .utf8)).gain == up.gain)
		#expect(try TakeReader.read(try String(contentsOf: loud, encoding: .utf8)).gain == down.gain)
	}

	/// One take is not a comparison, and it says so rather than proposing a
	/// trim of nought.
	@Test func oneTakeIsNotAComparison() async throws {
		let folder = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("cuttr-levels-one-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: folder) }
		let only = folder.appendingPathComponent("only.cuttr")
		try Self.takeFile(media: "video: only.mov",
		                  clips: [("one", "00:00.000", "00:01.000")])
			.write(to: only, atomically: true, encoding: .utf8)
		let projectFile = folder.appendingPathComponent("programme.cuttrproj")
		var made = Project(takes: ["only.cuttr"], output: Output(file: "out.mov"))
		made.timeline = [TimelineEntry(clip: ClipReference("one"))]
		try ProjectWriter.write(made).write(to: projectFile, atomically: true, encoding: .utf8)

		let (board, _) = try boardOver(projectFile)
		let line = await board.measure { _ in }
		#expect(line.contains("comparison"), "it said \(line)")
		#expect(board.rows[0].gain == 0)
	}

	// MARK: - A signal whose loudness is arithmetic

	/// A mono WAV of a 1 kHz sine, the same shape `LoudnessTests` uses.
	private func sine(amplitude: Double, seconds: Double, to url: URL,
	                  rate: Double = 48000) throws {
		let count = Int(seconds * rate)
		var samples = [Float](repeating: 0, count: count)
		for i in 0 ..< count {
			samples[i] = Float(amplitude * sin(2 * .pi * 1000 * Double(i) / rate))
		}
		var data = Data()
		func append<T>(_ value: T) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
		let bytes = UInt32(samples.count * 4)
		data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + bytes))
		data.append(contentsOf: Array("WAVEfmt ".utf8))
		append(UInt32(16)); append(UInt16(3))            // IEEE float
		append(UInt16(1)); append(UInt32(rate))
		append(UInt32(rate) * 4); append(UInt16(4)); append(UInt16(32))
		data.append(contentsOf: Array("data".utf8)); append(bytes)
		for s in samples { append(s) }
		try data.write(to: url)
	}
}
