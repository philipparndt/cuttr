import CuttrKit
import Foundation
import Testing
@testable import CuttrCompose

/// Sounds written inside a timeline entry.
///
/// The same case as a nested overlay and for the same reason: a sting belongs
/// to one use of a shot, and `from: intro` finds every use of it. What differs
/// is only that a sound is heard rather than drawn.
@Suite struct NestedSoundTests {

	private func fixture() throws -> URL {
		let directory = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("cuttr-nested-sound-\(UUID().uuidString)")
		try FileManager.default.createDirectory(
			at: directory.appendingPathComponent("takes"), withIntermediateDirectories: true)
		try Data().write(to: directory.appendingPathComponent("a.mov"))
		try Data().write(to: directory.appendingPathComponent("sting.wav"))
		let take = Take(video: "../a.mov", clips: [
			Clip(slug: "one", start: 0, end: 2),
			Clip(slug: "two", start: 2, end: 5),
			Clip(slug: "three", start: 5, end: 9),
		])
		try TakeWriter.write(take).write(
			to: directory.appendingPathComponent("takes/take-01.cuttr"),
			atomically: true, encoding: .utf8)
		return directory
	}

	private let header = "takes: [takes/take-01.cuttr]\n"

	@Test func aSoundCanBeWrittenInsideAnEntry() throws {
		let project = try ProjectReader.read("""
		timeline:
		  - clip: one
		    sounds:
		      - file: sting.wav
		        gain: -6
		sounds:
		  - file: music.wav
		    from: 00:00.000
		    to:   00:30.000
		""")
		#expect(project.timeline[0].sounds.count == 1)
		#expect(project.timeline[0].sounds[0].file == "sting.wav")
		#expect(project.timeline[0].sounds[0].gain == -6)
		// No range of its own: it plays for as long as the entry is on.
		#expect(project.timeline[0].sounds[0].span == nil)
		#expect(project.sounds.count == 1)
		#expect(project.sounds[0].span == .times(from: 0, to: 30))
	}

	@Test func aNestedSoundRoundTrips() throws {
		let project = try ProjectReader.read("""
		timeline:
		  - clip: one
		    sounds:
		      - file:  sting.wav
		        gain:  -6
		        in:    {fade: true, over: 0.5}
		  - group: build
		    clips: [two, three]
		    sounds:
		      - file: bed.wav
		        from: two
		        to:   three
		        ducks: 8
		""")
		let written = ProjectWriter.write(project)
		let back = try ProjectReader.read(written)
		#expect(back == project)
		#expect(ProjectWriter.write(back) == written)
		#expect(written.contains("    sounds:\n      - file:  sting.wav"))
	}

	@Test func aTopLevelSoundStillHasToSayWhenItPlays() throws {
		// Nothing to take a length from up there, so a sound that says nothing
		// about when is not read — the same rule the overlays get.
		let project = try ProjectReader.read("""
		timeline: [one]
		sounds:
		  - file: music.wav
		""")
		#expect(project.sounds.isEmpty)
	}

	@Test func aNestedSoundPlaysForItsPlacement() throws {
		let directory = try fixture()
		defer { try? FileManager.default.removeItem(at: directory) }
		let project = try ProjectReader.read(header + """
		timeline:
		  - clip: one
		  - clip: two
		    sounds:
		      - file: sting.wav
		""")
		let resolved = try Resolver.resolve(project, baseURL: directory)
		#expect(resolved.sounds.count == 1)
		#expect((resolved.sounds[0].start, resolved.sounds[0].end) == (2, 5))
		#expect(resolved.sounds[0].origin == .entry(path: [1], index: 0))
	}

	@Test func theSameClipTwiceGetsTheStingItWasGiven() throws {
		let directory = try fixture()
		defer { try? FileManager.default.removeItem(at: directory) }
		let project = try ProjectReader.read(header + """
		timeline:
		  - clip: one
		  - clip: two
		  - clip: one
		    sounds:
		      - file: sting.wav
		""")
		let resolved = try Resolver.resolve(project, baseURL: directory)
		#expect(resolved.sounds.count == 1)
		// one is 0–2, two is 2–5, one again is 5–7.
		#expect((resolved.sounds[0].start, resolved.sounds[0].end) == (5, 7))
	}

	@Test func aNestedSoundThatSaysWhenItPlaysIsBelieved() throws {
		let directory = try fixture()
		defer { try? FileManager.default.removeItem(at: directory) }
		let project = try ProjectReader.read(header + """
		timeline:
		  - clip: one
		  - group: build
		    clips: [two, three]
		    sounds:
		      - file:   sting.wav
		        within: three
		        from:   00:01.000
		        to:     00:02.000
		""")
		let resolved = try Resolver.resolve(project, baseURL: directory)
		#expect((resolved.sounds[0].start, resolved.sounds[0].end) == (6, 7))
	}

	// MARK: - Moving one

	@Test func unNestingASoundKeepsWhenItPlays() throws {
		let directory = try fixture()
		defer { try? FileManager.default.removeItem(at: directory) }
		var project = try ProjectReader.read(header + """
		timeline:
		  - clip: one
		  - group: build
		    clips: [two, three]
		    sounds:
		      - file: sting.wav
		""")
		let before = try Resolver.resolve(project, baseURL: directory).sounds
			.map { ($0.start, $0.end) }
		project.moveSound(at: .entry(path: [1], index: 0), into: nil,
		                  in: try Resolver.resolve(project, baseURL: directory))
		#expect(project.sounds.count == 1)
		#expect(project.sounds[0].span == .marks(from: .group("build"), to: .group("build")))
		let after = try Resolver.resolve(project, baseURL: directory).sounds
			.map { ($0.start, $0.end) }
		#expect(after.map(\.0) == before.map(\.0))
		#expect(after.map(\.1) == before.map(\.1))
	}

	@Test func droppingASoundOnAnEntryConstrainsItToIt() throws {
		let directory = try fixture()
		defer { try? FileManager.default.removeItem(at: directory) }
		var project = try ProjectReader.read(header + """
		timeline:
		  - clip: one
		  - clip: two
		sounds:
		  - file: sting.wav
		    from: 00:00.000
		    to:   00:09.000
		""")
		project.moveSound(at: .project(0), into: [1],
		                  in: try Resolver.resolve(project, baseURL: directory))
		#expect(project.sounds.isEmpty)
		#expect(project.timeline[1].sounds.count == 1)
		#expect(project.timeline[1].sounds[0].span == nil)
		let after = try Resolver.resolve(project, baseURL: directory)
		#expect((after.sounds[0].start, after.sounds[0].end) == (2, 5))
	}
}
