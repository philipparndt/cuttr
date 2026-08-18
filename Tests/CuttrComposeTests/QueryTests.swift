import CuttrKit
import Testing
@testable import CuttrCompose

@Suite struct QueryTests {

	private func clip(_ slug: String, tags: [String] = [], order: Int = Clip.defaultOrder) -> Clip {
		Clip(slug: slug, start: 0, end: 1, tags: tags, order: order)
	}

	@Test func aTagSelectsEveryClipCarryingIt() throws {
		let query = try QueryParser.parse("#b-roll")
		#expect(query.matches(takeName: "t1", clip: clip("a", tags: ["b-roll"])))
		#expect(!query.matches(takeName: "t1", clip: clip("b", tags: ["a-roll"])))
	}

	@Test func aTakeNarrowsIt() throws {
		let query = try QueryParser.parse("take-01/#interview")
		#expect(query.matches(takeName: "take-01", clip: clip("a", tags: ["interview"])))
		#expect(!query.matches(takeName: "take-02", clip: clip("a", tags: ["interview"])))
	}

	@Test func aStarIsEveryClipOfATake() throws {
		let query = try QueryParser.parse("take-01/*")
		#expect(query.matches(takeName: "take-01", clip: clip("anything")))
		#expect(!query.matches(takeName: "take-02", clip: clip("anything")))
	}

	@Test func aBareWordIsASlug() throws {
		let query = try QueryParser.parse("intro")
		#expect(query.matches(takeName: "t", clip: clip("intro")))
		// A tag called `intro` is not the clip called `intro`.
		#expect(!query.matches(takeName: "t", clip: clip("other", tags: ["intro"])))
	}

	@Test func notAndOrCombine() throws {
		let query = try QueryParser.parse("#b-roll and not #reject")
		#expect(query.matches(takeName: "t", clip: clip("a", tags: ["b-roll"])))
		#expect(!query.matches(takeName: "t", clip: clip("b", tags: ["b-roll", "reject"])))

		let either = try QueryParser.parse("#a-roll or #b-roll")
		#expect(either.matches(takeName: "t", clip: clip("a", tags: ["a-roll"])))
		#expect(either.matches(takeName: "t", clip: clip("b", tags: ["b-roll"])))
		#expect(!either.matches(takeName: "t", clip: clip("c", tags: ["c-roll"])))
	}

	@Test func juxtapositionIsAnd() throws {
		// Two labels side by side read as "both", which is how anybody writes it.
		let query = try QueryParser.parse("#interview #keep")
		#expect(query.matches(takeName: "t", clip: clip("a", tags: ["interview", "keep"])))
		#expect(!query.matches(takeName: "t", clip: clip("b", tags: ["interview"])))
	}

	@Test func bracketsGroup() throws {
		let query = try QueryParser.parse("(#a or #b) and not #reject")
		#expect(query.matches(takeName: "t", clip: clip("x", tags: ["a"])))
		#expect(!query.matches(takeName: "t", clip: clip("y", tags: ["a", "reject"])))
		#expect(!query.matches(takeName: "t", clip: clip("z", tags: ["c"])))
	}

	@Test func tagsAreSluggedOnBothSides() throws {
		// `#B-Roll` in a project and `B Roll` typed into the clip list are the
		// same tag, or the whole thing is a trap.
		let query = try QueryParser.parse("#B-Roll")
		let tagged = Clip(slug: "a", start: 0, end: 1, tags: ["B Roll"])
		#expect(tagged.tags == ["b-roll"])
		#expect(query.matches(takeName: "t", clip: tagged))
	}

	@Test func nonsenseIsRefusedRatherThanMatchingNothing() {
		#expect(throws: QueryError.self) { try QueryParser.parse("") }
		#expect(throws: QueryError.self) { try QueryParser.parse("(#a") }
		#expect(throws: QueryError.self) { try QueryParser.parse("#a)") }
	}

	@Test func queriesRoundTripThroughTheFile() throws {
		let project = try ProjectReader.read("""
		timeline:
		  - intro
		  - query: "#b-roll and not #reject"
		  - clips: [one, two, three]
		  - tag: outro
		""")
		#expect(project.timeline.count == 4)
		#expect(project.timeline[0].clip?.slug == "intro")
		#expect(project.timeline[1].source.description == "#b-roll and not #reject")
		if case .list(let references) = project.timeline[2].source {
			#expect(references.map(\.slug) == ["one", "two", "three"])
		} else {
			Issue.record("expected a list")
		}
		#expect(project.timeline[3].source.description == "#outro")

		// And back out unchanged: a query somebody wrote comes back the way
		// they wrote it, not re-printed from the parse tree.
		let text = ProjectWriter.write(project)
		#expect(text.contains("query: \"#b-roll and not #reject\""))
		#expect(text.contains("clips: [one, two, three]"))
		let back = try ProjectReader.read(text)
		#expect(back.timeline.map(\.source.description) == project.timeline.map(\.source.description))
	}
}
