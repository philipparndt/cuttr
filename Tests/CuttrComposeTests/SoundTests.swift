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
