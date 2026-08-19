import CuttrKit
import Foundation
import Testing
@testable import CuttrCompose

/// Cards: time on the programme with no take behind it.
@Suite struct CardFileTests {

	@Test func aCardIsALengthWhereASlugWouldBe() throws {
		let project = try ProjectReader.read("""
		timeline:
		  - card: 00:04.000
		  - intro
		""")
		guard case .card(let card) = project.timeline[0].source else {
			Issue.record("the first entry is not a card")
			return
		}
		#expect(card.duration == 4)
		// Black, because that is what a card is when nobody says.
		#expect(card.fill == Card.black)
	}

	@Test func aCardRoundTripsWithEverythingOnIt() throws {
		let project = Project(timeline: [
			TimelineEntry(clip: ClipReference("intro")),
			TimelineEntry(card: Card(duration: 2.5, fill: .solid(RGBA(hex: "#101014")!)),
			              transition: .dissolve(over: 1), label: "gap"),
			TimelineEntry(card: Card(duration: 4, fill: .gradient(
				top: RGBA(hex: "#202030")!, bottom: RGBA(hex: "#050508")!)), label: "intro"),
		])
		let back = try ProjectReader.read(ProjectWriter.write(project))
		#expect(back == project)
	}

	@Test func writingWhatWasReadChangesNothing() throws {
		// The rule the whole format is held to: a file opened and saved
		// unchanged is an unchanged file.
		let text = ProjectWriter.write(try ProjectReader.read("""
		timeline:
		  - card: 00:04.000
		    fill: "#101014"
		    as:   intro
		  - clip: demo
		    transition: 1
		"""))
		#expect(ProjectWriter.write(try ProjectReader.read(text)) == text)
	}

	@Test func aBlackCardIsOneLine() {
		let plain = ProjectWriter.fragment(for: TimelineEntry(card: Card(duration: 4)))
		#expect(plain == "timeline:\n  - card:  00:04.000\n")
		// And a coloured one says so, in the column the card's own key set.
		let coloured = ProjectWriter.fragment(
			for: TimelineEntry(card: Card(duration: 4, fill: .solid(RGBA(hex: "#101014")!))))
		#expect(coloured == "timeline:\n  - card:  00:04.000\n    fill:  \"#101014\"\n")
	}

	@Test func aGradientIsTwoColoursReadDownThePage() throws {
		let project = try ProjectReader.read("""
		timeline:
		  - card: 3
		    fill: ["#202030", "#050508"]
		""")
		guard case .card(let card) = project.timeline[0].source else {
			Issue.record("not a card")
			return
		}
		#expect(card.fill == .gradient(top: RGBA(hex: "#202030")!, bottom: RGBA(hex: "#050508")!))
		// Three seconds written as a number is three seconds: a card's length
		// goes where a time goes, and both spellings of a time are read.
		#expect(card.duration == 3)
		#expect(ProjectWriter.write(project).contains("fill:  [\"#202030\", \"#050508\"]"))
	}

	@Test func aCardInsideASectionIsStillACard() throws {
		let project = try ProjectReader.read("""
		timeline:
		  - group: introduction
		    clips:
		      - card: 00:02.000
		      - intro
		""")
		guard case .group(_, let inner) = project.timeline[0].source,
		      case .card(let card) = inner[0].source else {
			Issue.record("the card did not survive being nested")
			return
		}
		#expect(card.duration == 2)
		#expect(try ProjectReader.read(ProjectWriter.write(project)) == project)
	}
}

@Suite struct CardResolvingTests {

	/// One take, one clip, five seconds of it — enough to put a card beside.
	private func fixture() throws -> URL {
		let directory = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("cuttr-card-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		try Data().write(to: directory.appendingPathComponent("a.mov"))
		let take = Take(video: "a.mov", clips: [
			Clip(slug: "intro", start: 0, end: 5),
			Clip(slug: "demo", start: 5, end: 15),
		])
		try TakeWriter.write(take).write(
			to: directory.appendingPathComponent("take.cuttr"), atomically: true, encoding: .utf8)
		return directory
	}

	private func resolve(_ timeline: String) throws -> ResolvedProject {
		let directory = try fixture()
		defer { try? FileManager.default.removeItem(at: directory) }
		let project = try ProjectReader.read("takes: [take.cuttr]\n" + timeline)
		return try Resolver.resolve(project, baseURL: directory)
	}

	@Test func aCardTakesItsTimeOnTheClock() throws {
		let resolved = try resolve("""
		timeline:
		  - card: 00:04.000
		  - intro
		""")
		#expect(resolved.cards.map(\.start) == [0])
		#expect(resolved.clips.map(\.start) == [4])
		#expect(resolved.duration == 9)
	}

	@Test func aCardAtTheEndIsPartOfTheProgramme() throws {
		let resolved = try resolve("""
		timeline:
		  - intro
		  - card: 00:03.000
		""")
		// The duration used to be the last clip's end, which would have stopped
		// the programme three seconds early — and the render with it.
		#expect(resolved.duration == 8)
	}

	@Test func aShotDissolvesIntoACardAndOutAgain() throws {
		let resolved = try resolve("""
		timeline:
		  - intro
		  - card: 00:04.000
		    transition: 1
		  - clip: demo
		    transition: 1
		""")
		// Five seconds, then a second of overlap eaten out of the middle at
		// each of the two dissolves: 5 + 4 + 10 − 1 − 1.
		#expect(resolved.cards[0].start == 4)
		#expect(resolved.cards[0].transition == 1)
		#expect(resolved.clips[1].start == 7)
		#expect(resolved.clips[1].transition == 1)
		#expect(resolved.duration == 17)
	}

	@Test func aDissolveIsNeverLongerThanHalfTheCard() throws {
		let resolved = try resolve("""
		timeline:
		  - intro
		  - card: 00:01.000
		    transition: 3
		""")
		// Half of one second, not three: a three-second dissolve into a
		// one-second card would run past both ends of it.
		#expect(resolved.cards[0].transition == 0.5)
		#expect(resolved.cards[0].start == 4.5)
	}

	@Test func aNamedCardIsASectionOfOne() throws {
		let resolved = try resolve("""
		timeline:
		  - card: 00:04.000
		    as:   intro
		  - intro
		""")
		// `as:` on a card registers a group exactly as it does on a clip, which
		// is the whole point: a card is somewhere to put a title, and the title
		// finds it with `group: intro`.
		let group = resolved.groups.first { $0.name == "intro" }
		#expect(group?.start == 0)
		#expect(group?.end == 4)
	}

	@Test func anOverlayCanBeHungOnACard() throws {
		let resolved = try resolve("""
		timeline:
		  - card: 00:04.000
		    as:   intro
		  - intro
		overlays:
		  - text:  Hello
		    group: intro
		""")
		#expect(resolved.overlays.count == 1)
		#expect(resolved.overlays[0].start == 0)
		#expect(resolved.overlays[0].end == 4)
	}

	@Test func aProgrammeOfNothingButCardsIsAProgramme() throws {
		let resolved = try resolve("""
		timeline:
		  - card: 00:04.000
		""")
		#expect(resolved.clips.isEmpty)
		#expect(resolved.duration == 4)
	}

	@Test func aCardOfNoLengthIsNothing() throws {
		// The same rule a clip trimmed to nothing gets: it is not a frame of
		// nothing, it is nothing.
		let resolved = try resolve("""
		timeline:
		  - card: 0
		  - intro
		""")
		#expect(resolved.cards.isEmpty)
		#expect(resolved.clips[0].start == 0)
	}

	@Test func theProgrammeIsTheTwoOfThemInOrder() throws {
		let resolved = try resolve("""
		timeline:
		  - card: 00:02.000
		  - intro
		  - card: 00:01.000
		  - demo
		""")
		#expect(resolved.programme.map { $0.start } == [0, 2, 7, 8])
		#expect(resolved.programme.map { $0.duration } == [2, 5, 1, 10])
		#expect(resolved.programme.compactMap { $0.fill }.count == 2)
	}
}
