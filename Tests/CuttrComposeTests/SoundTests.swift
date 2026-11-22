import CuttrKit
import Foundation
import Testing
@testable import CuttrCompose

/// Sound that is not from a take: music, an atmosphere, a sting.
@Suite struct SoundFileTests {

	@Test func aSoundSaysWhenItPlaysTheWayAnOverlayDoes() throws {
		let project = try ProjectReader.read("""
		timeline: [intro]
		sounds:
		  - file:  music/opening.wav
		    group: intro
		    gain:  -6
		    in:    {fade: true, over: 0.5}
		    out:   {fade: true, over: 1.5}
		    ducks: 8
		""")
		#expect(project.sounds.count == 1)
		let sound = project.sounds[0]
		#expect(sound.file == "music/opening.wav")
		#expect(sound.span == .marks(from: .group("intro"), to: .group("intro")))
		#expect(sound.gain == -6)
		#expect(sound.arrival == .fade(over: 0.5))
		#expect(sound.departure == .fade(over: 1.5))
		#expect(sound.ducks == 8)
	}

	@Test func everySpellingOfWhenIsRead() throws {
		let project = try ProjectReader.read("""
		timeline: [intro]
		sounds:
		  - file: a.wav
		    from: intro
		    to:   outro
		  - file:   b.wav
		    within: intro
		    from:   00:01.000
		    to:     00:03.000
		  - file: c.wav
		    from: 00:05.000
		    to:   00:09.000
		""")
		#expect(project.sounds[0].span == .clips(from: ClipReference("intro"),
		                                         to: ClipReference("outro")))
		#expect(project.sounds[1].span == .within(.clip(ClipReference("intro")), from: 1, to: 3))
		#expect(project.sounds[2].span == .times(from: 5, to: 9))
	}

	@Test func roundTripsAndOnlySaysWhatIsNotUsual() throws {
		let project = Project(
			timeline: [TimelineEntry(clip: ClipReference("intro"))],
			sounds: [
				Sound(file: "music/opening.wav",
				      span: .marks(from: .group("intro"), to: .group("intro")),
				      gain: -6, arrival: .fade(over: 0.5), departure: .fade(over: 1.5),
				      ducks: 8),
				// Nothing but a file and a place: no gain, no fades, no ducking.
				Sound(file: "sting.wav", span: .times(from: 12, to: 13)),
			])
		let text = ProjectWriter.write(project)
		#expect(try ProjectReader.read(text) == project)
		// The plain one says four things and no more.
		#expect(text.contains("  - file:  sting.wav\n    from:  00:12.000\n    to:    00:13.000\n"))
		#expect(!text.contains("gain:  0"))
		// Writing what was read changes nothing, which is the rule the whole
		// format is held to.
		#expect(ProjectWriter.write(try ProjectReader.read(text)) == text)
	}

	// MARK: - Which part of the file

	/// A sound has two clocks, and `start:` is the file's: where in the
	/// recording it begins. It is not when it plays — that is still `from:`.
	@Test func aSoundSaysWhereInItsFileItBegins() throws {
		let project = try ProjectReader.read("""
		timeline: [intro]
		sounds:
		  - file:  music/song.mp3
		    from:  04:55.485
		    to:    06:10.000
		    start: 00:13.915
		    end:   75
		""")
		let sound = project.sounds[0]
		#expect(sound.span == .times(from: 295.485, to: 370))
		#expect(sound.fileStart == 13.915)
		#expect(sound.fileEnd == 75)
		#expect(sound.fileLength == 75 - 13.915)

		// From the top and to the end when it says neither, as it always was.
		let plain = try ProjectReader.read("sounds:\n  - file: a.wav\n    from: 00:01.000\n    to: 00:02.000\n")
		#expect(plain.sounds[0].fileStart == 0)
		#expect(plain.sounds[0].fileEnd == nil)
		#expect(plain.sounds[0].fileLength == nil)
	}

	@Test func theFilesClockRoundTripsUnderTheProgrammes() throws {
		let project = Project(
			timeline: [TimelineEntry(clip: ClipReference("intro"))],
			sounds: [Sound(file: "music/song.mp3", span: .times(from: 295.485, to: 370),
			               gain: -6, fileStart: 13.915, fileEnd: 75)])
		let text = ProjectWriter.write(project)
		#expect(try ProjectReader.read(text) == project)
		// When it plays, then which part, then how loud.
		#expect(text.contains("""
		  - file:  music/song.mp3
		    from:  04:55.485
		    to:    06:10.000
		    start: 00:13.915   # in the file
		    end:   01:15.000   # in the file
		    gain:  -6

		"""))
		#expect(ProjectWriter.write(try ProjectReader.read(text)) == text)
		// And a sound from the top says nothing about it.
		var whole = project
		whole.sounds[0].fileStart = 0
		whole.sounds[0].fileEnd = nil
		#expect(!ProjectWriter.write(whole).contains("start:"))
	}

	/// `within:` is as long as the column a sound's values line up at, and was
	/// written with no space after it: `within:intro`, which is one word. A
	/// sound placed inside a clip made a project that could not be read back.
	@Test func aSoundInsideAClipIsWrittenSoThatItReadsBack() throws {
		let project = Project(
			timeline: [TimelineEntry(clip: ClipReference("intro"), sounds: [
				Sound(file: "sting.wav", span: .within(.init("intro"), from: 0.25, to: 1)),
			])],
			sounds: [Sound(file: "bed.wav", span: .within(.init("intro"), from: 1, to: 2), fileStart: 3)])
		let text = ProjectWriter.write(project)
		#expect(text.contains("    within: intro\n    from:  00:01.000\n    to:    00:02.000\n    start: 00:03.000"))
		#expect(try ProjectReader.read(text) == project)
		#expect(ProjectWriter.write(try ProjectReader.read(text)) == text)
	}

	/// A stretch of nothing is refused, not read as a silent track.
	@Test func aStretchOfTheFileThatIsNoStretchIsRefused() {
		func read(_ lines: String) throws -> Project {
			try ProjectReader.read("sounds:\n  - file: a.wav\n    from: 00:01.000\n    to: 00:09.000\n" + lines)
		}
		#expect(throws: ProjectError.self) { try read("    start: -1\n") }
		#expect(throws: ProjectError.self) { try read("    start: 00:05.000\n    end: 00:05.000\n") }
		#expect(throws: ProjectError.self) { try read("    start: 00:05.000\n    end: 00:02.000\n") }
		#expect(throws: ProjectError.self) { try read("    start: soon\n") }
	}

	@Test func aFadeIsWrittenTheWayAnOverlaysIs() {
		let text = ProjectWriter.fragment(for: Sound(
			file: "bed.wav", span: .times(from: 0, to: 10),
			arrival: .fade(over: 2), departure: .fade(over: 3)))
		#expect(text.contains("in:    {fade: true, over: 2}"))
		#expect(text.contains("out:   {fade: true, over: 3}"))
	}

	@Test func aBareNumberIsAFadeOfThatManySeconds() throws {
		let project = try ProjectReader.read("""
		timeline: [intro]
		sounds:
		  - file: a.wav
		    from: 0
		    to:   4
		    in:   0.75
		    out:  fade
		""")
		#expect(project.sounds[0].arrival == .fade(over: 0.75))
		#expect(project.sounds[0].departure == .fade(over: 0.5))
	}

	@Test func aSoundWithNoFileIsNotASound() throws {
		// A list entry that names nothing is skipped rather than resolved into
		// a missing file later, which would blame the wrong thing.
		#expect(try ProjectReader.read("timeline: [a]\nsounds:\n  - from: a\n").sounds.isEmpty)
	}
}

@Suite struct SoundResolvingTests {

	/// A take, a clip, and a file to play under it.
	private func fixture() throws -> URL {
		let directory = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("cuttr-sound-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		try Data().write(to: directory.appendingPathComponent("a.mov"))
		try Data().write(to: directory.appendingPathComponent("music.wav"))
		let take = Take(video: "a.mov", clips: [
			Clip(slug: "intro", start: 0, end: 5),
			Clip(slug: "demo", start: 5, end: 15),
		])
		try TakeWriter.write(take).write(
			to: directory.appendingPathComponent("take.cuttr"), atomically: true, encoding: .utf8)
		return directory
	}

	private func resolve(_ text: String) throws -> ResolvedProject {
		let directory = try fixture()
		defer { try? FileManager.default.removeItem(at: directory) }
		return try Resolver.resolve(
			try ProjectReader.read("takes: [take.cuttr]\n" + text), baseURL: directory)
	}

	@Test func aSoundLandsWhereItsSpanSays() throws {
		let resolved = try resolve("""
		timeline:
		  - intro
		  - demo
		sounds:
		  - file: music.wav
		    from: demo
		""")
		#expect(resolved.sounds.count == 1)
		#expect(resolved.sounds[0].start == 5)
		#expect(resolved.sounds[0].end == 15)
		// Resolved against the project file, the same as take media is.
		#expect(resolved.sounds[0].url.lastPathComponent == "music.wav")
	}

	/// A start in the file moves nothing on the programme. An end in the file
	/// stops the sound there, however much room its span had left — and that is
	/// settled here, so the fade, the ducking and the lane all end with it.
	@Test func whereItBeginsInTheFileDoesNotMoveItAndWhereItEndsStopsIt() throws {
		let from = try resolve("""
		timeline: [intro, demo]
		sounds:
		  - file:  music.wav
		    from:  00:02.000
		    to:    00:12.000
		    start: 00:13.915
		""")
		#expect(from.sounds.map(\.start) == [2])
		#expect(from.sounds.map(\.end) == [12])

		let to = try resolve("""
		timeline: [intro, demo]
		sounds:
		  - file:  music.wav
		    from:  00:02.000
		    to:    00:12.000
		    start: 00:10.000
		    end:   00:13.000
		""")
		#expect(to.sounds.map(\.start) == [2])
		#expect(to.sounds.map(\.end) == [5])
	}

	@Test func aSoundOverASectionMovesWithIt() throws {
		let resolved = try resolve("""
		timeline:
		  - group: opening
		    clips:
		      - intro
		      - demo
		sounds:
		  - file:  music.wav
		    group: opening
		""")
		#expect(resolved.sounds[0].start == 0)
		#expect(resolved.sounds[0].end == 15)
	}

	@Test func aSoundCanBeHungOnACard() throws {
		let resolved = try resolve("""
		timeline:
		  - card: 00:04.000
		    as:   titles
		  - intro
		sounds:
		  - file:  music.wav
		    group: titles
		""")
		#expect(resolved.sounds[0].start == 0)
		#expect(resolved.sounds[0].end == 4)
	}

	@Test func aMissingSoundIsNamedRatherThanSwallowed() throws {
		#expect(throws: ResolveError.self) {
			try resolve("""
			timeline: [intro]
			sounds:
			  - file: nowhere/absent.wav
			    from: intro
			""")
		}
	}

	@Test func aSoundUsedOnceForEachTimeItsClipIs() throws {
		// The same rule an overlay gets: a clip used twice is two places, so a
		// sound hung on it plays twice rather than across the middle.
		let resolved = try resolve("""
		timeline:
		  - intro
		  - demo
		  - intro
		sounds:
		  - file: music.wav
		    from: intro
		""")
		#expect(resolved.sounds.map(\.start) == [0, 15])
		#expect(resolved.sounds.map(\.end) == [5, 20])
	}
}
