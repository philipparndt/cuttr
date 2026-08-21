import Foundation
import Testing
@testable import CuttrCompose

/// What somebody wrote in the file, and whether saving it keeps it.
///
/// The examples in this repository are annotated on purpose — they are how the
/// format is taught — and opening one in the app and saving it used to delete
/// every line of that teaching. The measurement is in
/// ``theAnnotatedExampleKeepsItsProse``, on the real file.
@Suite struct ProjectCommentTests {

	/// The repository's `examples/`, found from this file rather than from a
	/// bundle: the point of the test is the file somebody committed.
	private var examples: URL {
		URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent()
			.deletingLastPathComponent()
			.deletingLastPathComponent()
			.appendingPathComponent("examples")
	}

	private func commentLines(_ text: String) -> [String] {
		text.components(separatedBy: "\n")
			.map { $0.trimmingCharacters(in: .whitespaces) }
			.filter { $0.hasPrefix("#") }
	}

	@Test func theAnnotatedExampleKeepsItsProse() throws {
		let url = examples.appendingPathComponent("scenes/crawl.cuttrproj")
		let source = try String(contentsOf: url, encoding: .utf8)
		let written = ProjectWriter.write(try ProjectReader.read(source))

		// Thirty-five comment lines went in, and one came out: the emitter's own
		// header. That is what this is about.
		#expect(commentLines(source).count == 35)
		#expect(commentLines(written).count == 35)

		// The prose itself, not just the count. One line from each block,
		// including the one six levels in.
		for line in [
			"# cuttr project — an opening crawl, out of one `roll:` part.",
			"# **What this cannot do.** The famous version of this shot is a perspective",
			"# The blue line before it. Big, thin, and the one cool colour in the file.",
			"# Cut, not faded: the column arrives from below the frame and leaves above",
			"# One part. The three keys are the whole shot: `y` runs from half a column",
			"# The crawl itself. `tilt` lays the column on a plane tilted away from",
		] {
			#expect(written.contains(line), "lost: \(line)")
		}

		// Where they are, not only that they are there. A comment that survives
		// on the wrong key is worse than one that is lost.
		let lines = written.components(separatedBy: "\n")
		func line(after comment: String) -> String {
			guard let index = lines.firstIndex(where: { $0.contains(comment) }) else { return "" }
			return lines[(index + 1)...].first { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") } ?? ""
		}
		#expect(line(after: "The blue line before it").trimmingCharacters(in: .whitespaces)
			== "far-away:")
		#expect(line(after: "Cut, not faded").contains("scene:"))
		#expect(line(after: "One part. The three keys").trimmingCharacters(in: .whitespaces)
			== "crawl:")
		#expect(line(after: "`tilt` lays the column").contains("tilt:"))
	}

	@Test func everyAnnotatedExampleSurvivesBeingSaved() throws {
		// All of them, because one file passing is a file, and the argument is
		// about the format. Byte-identical is not claimed — several of these
		// were hand-aligned — but no line of prose may be lost.
		let files = FileManager.default.enumerator(atPath: examples.path)?
			.compactMap { $0 as? String }.filter { $0.hasSuffix(".cuttrproj") }.sorted() ?? []
		#expect(files.count > 10, "the examples should be found at all")
		for name in files {
			let url = examples.appendingPathComponent(name)
			let source = try String(contentsOf: url, encoding: .utf8)
			let written = ProjectWriter.write(try ProjectReader.read(source))
			for comment in commentLines(source) {
				#expect(written.contains(comment), "\(name) lost: \(comment)")
			}
		}
	}

	@Test func aFileTheEmitterWroteComesBackByteForByte() throws {
		// The guard on the whole scheme: reading the emitter's own output and
		// writing it again must not double up the comments the emitter writes
		// itself, and must not add any.
		let written = ProjectWriter.write(Project(
			takes: ["takes/take-01.cuttr"],
			timeline: [TimelineEntry(clip: ClipReference("intro"))],
			styles: ["title": TextStyle(size: 0.08)]))
		#expect(ProjectWriter.write(try ProjectReader.read(written)) == written)

		// And the empty one, which is nothing but the emitter's own comments:
		// a header and the block that says where clips go.
		let empty = ProjectWriter.write(Project())
		#expect(ProjectWriter.write(try ProjectReader.read(empty)) == empty)
	}

	@Test func aCommentStaysWithItsKeyWhenTheOrderChanges() throws {
		var project = try ProjectReader.read("""
		cuttr-project: 1

		timeline:
		  - clip: a

		overlays:
		  # about the first one
		  - text:   One
		    from:   00:01.000
		    to:     00:02.000

		  # about the second one
		  - text:   Two
		    from:   00:03.000
		    to:     00:04.000
		""")
		project.overlays.reverse()
		let written = ProjectWriter.write(project)
		let lines = written.components(separatedBy: "\n")
		func keyAfter(_ comment: String) -> String {
			guard let index = lines.firstIndex(where: { $0.contains(comment) }) else { return "" }
			return lines[index + 1].trimmingCharacters(in: .whitespaces)
		}
		// Addressed by what the entry says, not by where it is in the list: the
		// note about the second one is still about the second one.
		#expect(keyAfter("about the second one") == "- text:   Two")
		#expect(keyAfter("about the first one") == "- text:   One")
	}

	@Test func aCommentOnADeletedKeyDoesNotReappear() throws {
		var project = try ProjectReader.read("""
		cuttr-project: 1

		timeline:
		  - clip: a

		styles:
		  # about the one that is going away
		  gone:
		    size: 0.04
		  # about the one that stays
		  kept:
		    size: 0.05
		""")
		project.styles.removeValue(forKey: "gone")
		let written = ProjectWriter.write(project)
		#expect(!written.contains("going away"))
		#expect(written.contains("about the one that stays"))
		// And it did not land on the survivor on the way past.
		let lines = written.components(separatedBy: "\n")
		let index = lines.firstIndex { $0.contains("about the one that stays") } ?? 0
		#expect(lines[index + 1].trimmingCharacters(in: .whitespaces) == "kept:")
	}

	@Test func theStylesComeBackInTheOrderTheFileHadThem() throws {
		let source = """
		cuttr-project: 1

		timeline:
		  - clip: a

		styles:
		  zebra:
		    size: 0.04
		  antelope:
		    size: 0.05
		"""
		let written = ProjectWriter.write(try ProjectReader.read(source))
		guard let zebra = written.range(of: "zebra:"), let antelope = written.range(of: "antelope:")
		else { Issue.record("both styles should be written"); return }
		// Not alphabetical: somebody put the zebra first, and a save that
		// re-sorts the block is a diff nobody asked for.
		#expect(zebra.lowerBound < antelope.lowerBound)

		// A style the file did not declare goes after the ones it did, sorted,
		// so the writer is still deterministic.
		var project = try ProjectReader.read(source)
		project.styles["aardvark"] = TextStyle(size: 0.06)
		let again = ProjectWriter.write(project)
		#expect(again.range(of: "zebra:")!.lowerBound < again.range(of: "aardvark:")!.lowerBound)
		#expect(ProjectWriter.write(project) == again)
	}
}
