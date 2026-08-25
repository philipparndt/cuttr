import CuttrKit
import Foundation
import Testing
@testable import CuttrCompose

/// The scene that plays while the picture is held, and the two scenes that come
/// with the program.
@Suite struct PresentationSceneTests {

	private func fixture() throws -> URL {
		let directory = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("cuttr-presentation-\(UUID().uuidString)")
		try FileManager.default.createDirectory(
			at: directory.appendingPathComponent("takes"), withIntermediateDirectories: true)
		try Data().write(to: directory.appendingPathComponent("screen.mov"))
		let take = Take(video: "../screen.mov", clips: [
			Clip(slug: "install", start: 0, end: 20),
		])
		try TakeWriter.write(take).write(
			to: directory.appendingPathComponent("takes/take-01.cuttr"),
			atomically: true, encoding: .utf8)
		return directory
	}

	private let header = "takes: [takes/take-01.cuttr]\n"

	private func resolve(_ body: String) throws -> (ResolvedProject, URL) {
		let directory = try fixture()
		let project = try ProjectReader.read(header + body)
		return (try Resolver.resolve(project, baseURL: directory), directory)
	}

	/// The named scene is on the programme for exactly the hold, at the moment
	/// the picture stops — and it is an ordinary scene overlay, so everything
	/// downstream draws it without knowing a treatment was involved.
	@Test func theSceneIsOnForTheHold() throws {
		let (resolved, directory) = try resolve("""
		timeline:
		  - clip: install
		    presentations:
		      - at:    00:05.000
		        into:  [0.04, 0.2, 0.42, 0.6]
		        hold:  6
		        scene: bullets
		        with:  {one: "Download it", two: "Open it"}
		""")
		defer { try? FileManager.default.removeItem(at: directory) }
		let shown = try #require(resolved.overlays.first)
		guard case .scene(let name, let parameters) = shown.overlay.kind else {
			Issue.record("the treatment did not lay a scene")
			return
		}
		#expect(name == "bullets")
		#expect(parameters["one"] == "Download it")
		#expect(shown.start == 5)
		#expect(shown.end == 11)
		// And the picture is aside for all of it.
		#expect(resolved.clips[0].picture(atProgramme: 8) != .whole)
	}

	/// Two treatments on one clip: the second one's scene is where the first
	/// one's hold has already pushed it to.
	@Test func aSecondSceneIsPushedAlongByTheFirstHold() throws {
		let (resolved, directory) = try resolve("""
		timeline:
		  - clip: install
		    presentations:
		      - at:    00:05.000
		        into:  [0.04, 0.2, 0.42, 0.6]
		        hold:  6
		        scene: bullets
		        with:  {one: "First"}
		      - at:    00:12.000
		        into:  [0.54, 0.2, 0.42, 0.6]
		        hold:  4
		        scene: boxes
		        with:  {one: "Second"}
		""")
		defer { try? FileManager.default.removeItem(at: directory) }
		#expect(resolved.overlays.count == 2)
		#expect(resolved.overlays[0].start == 5)
		#expect(resolved.overlays[1].start == 18)
		#expect(resolved.overlays[1].end == 22)
	}

	/// A name nothing defines is said. A hold with nothing in it is six seconds
	/// of a still picture and no explanation of why.
	@Test func aSceneNothingDefinesIsSaid() throws {
		let (resolved, directory) = try resolve("""
		timeline:
		  - clip: install
		    presentations:
		      - at:    00:05.000
		        into:  [0.04, 0.2, 0.42, 0.6]
		        hold:  6
		        scene: whatever
		""")
		defer { try? FileManager.default.removeItem(at: directory) }
		#expect(resolved.overlays.isEmpty)
		#expect(resolved.warnings.contains { $0.contains("whatever") })
	}

	/// The escape hatch, and the rule every built-in name in this program
	/// follows: what the project says beats what the program brings.
	@Test func aProjectsOwnBulletsWins() throws {
		let directory = try fixture()
		defer { try? FileManager.default.removeItem(at: directory) }
		let project = try ProjectReader.read(header + """
		scenes:
		  bullets:
		    parts:
		      - text: "{{one}}"
		        keys: [{t: 0, x: 0.5, y: 0.5, opacity: 1}]
		timeline:
		  - clip: install
		""")
		let mine = try #require(project.scene(named: "bullets", with: ["one": "hello"]))
		#expect(mine.parts.count == 1)
		// And a name it does not define still finds the built-in.
		let ours = try #require(project.scene(named: "boxes", with: ["one": "hello"]))
		#expect(ours.parts.count == 2)   // a plate and its words
	}

	// MARK: - The built-ins

	private func made(_ name: String, _ parameters: [String: String]) throws -> Scene {
		try #require(Scene.builtIn(name, with: parameters))
	}

	/// Only the snippets given are drawn, and a gap in the names closes up —
	/// the names order the lines, they do not place them.
	@Test func onlyTheSnippetsGivenAreDrawn() throws {
		#expect(Scene.snippets(in: ["one": "a", "three": "c"]) == ["a", "c"])
		#expect(Scene.snippets(in: ["one": "a", "two": "", "three": "c"]) == ["a", "c"])
		let two = try made("bullets", ["one": "a", "three": "c"])
		#expect(two.parts.count == 2)
		#expect(two.parts.allSatisfy { if case .text(let said, _, _) = $0.content {
			return said.hasPrefix("•  ")
		} else { return false } })
		let three = try made("bullets", ["one": "a", "two": "b", "three": "c"])
		#expect(three.parts.count == 3)
		// A box is a plate and its words, so it is two parts a row.
		#expect(try made("boxes", ["one": "a", "two": "b"]).parts.count == 4)
	}

	/// The rows are evenly spaced and centred on the frame, whether there are
	/// two of them or five.
	@Test func theRowsAreEvenlySpacedAndCentred() throws {
		for count in 2...5 {
			let names = ["one", "two", "three", "four", "five"]
			var parameters: [String: String] = [:]
			for index in 0..<count { parameters[names[index]] = "line \(index)" }
			let scene = try made("boxes", parameters)
			let rows = scene.parts.compactMap { part -> Double? in
				guard case .text = part.content else { return nil }
				return part.keys.last?.y
			}
			#expect(rows.count == count)
			let middle = rows.reduce(0, +) / Double(count)
			#expect(abs(middle - 0.5) < 1e-9, "\(count) rows are not centred")
			// Descending, and evenly.
			let gaps = zip(rows, rows.dropFirst()).map { $0 - $1 }
			#expect(gaps.allSatisfy { $0 > 0 })
			#expect(gaps.allSatisfy { abs($0 - (gaps.first ?? 0)) < 1e-9 })
		}
	}

	/// Five snippets over six seconds appear every 1.2 — the hold divided by
	/// the number of them, so dragging the hold longer re-times them and
	/// nothing has to be written down.
	@Test func oneByOneDividesTheHoldEvenly() throws {
		let scene = try made("bullets", [
			"one": "a", "two": "b", "three": "c", "four": "d", "five": "e",
			"hold": "6", "reveal": "one-by-one",
		])
		let arrivals = scene.parts.compactMap { part -> Double? in
			guard case .text = part.content else { return nil }
			return part.keys.first?.t
		}
		#expect(arrivals.count == 5)
		for (index, arrival) in arrivals.enumerated() {
			#expect(abs(arrival - Double(index) * 1.2) < 1e-9)
		}
	}

	/// Together is the default, and it is not quite together: a line every
	/// twelfth of a second reads as a list being put up rather than as a
	/// sequence.
	@Test func togetherIsTheDefault() throws {
		let scene = try made("boxes", ["one": "a", "two": "b", "hold": "6"])
		let arrivals = scene.parts.compactMap { part -> Double? in
			guard case .text = part.content else { return nil }
			return part.keys.first?.t
		}
		#expect(arrivals.allSatisfy { $0 < 0.2 })
		#expect(arrivals[0] < arrivals[1])
	}

	/// The built-in lays itself out in the part of the frame the picture has
	/// left free, so the same scene works with the picture on either side.
	@Test func theBuiltInUsesTheSideThePictureIsNotOn() throws {
		let onTheLeft = Presentation.Rectangle(x: 0.04, y: 0.2, width: 0.42, height: 0.6)
		#expect(abs(onTheLeft.free.x - 0.46) < 1e-9)
		#expect(abs(onTheLeft.free.width - 0.54) < 1e-9)

		let onTheRight = Presentation.Rectangle(x: 0.54, y: 0.2, width: 0.42, height: 0.6)
		#expect(onTheRight.free.x == 0)
		#expect(abs(onTheRight.free.width - 0.54) < 1e-9)

		let left = try made("boxes", ["one": "a", "column-x": "0.46", "column-width": "0.54"])
		let right = try made("boxes", ["one": "a", "column-x": "0", "column-width": "0.54"])
		func centre(_ scene: Scene) -> Double? {
			scene.parts.compactMap { part -> Double? in
				guard case .text = part.content else { return nil }
				return part.keys.last?.x
			}.first
		}
		#expect((centre(left) ?? 0) > 0.5)
		#expect((centre(right) ?? 1) < 0.5)
	}
}
