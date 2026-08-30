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

	@Test func aQuotedTakeNameMayHaveSpacesInIt() throws {
		// A take is named by its file, and files have spaces in their names.
		// Without this there is no way at all to scope a query to `Mia 1`.
		let query = try QueryParser.parse("\"Mia 1\"/#interview")
		#expect(query.matches(takeName: "Mia 1", clip: clip("a", tags: ["interview"])))
		#expect(!query.matches(takeName: "Mia 2", clip: clip("a", tags: ["interview"])))
		// Unquoted, the space is what it has always been: a separator. Two
		// terms, and no clip answers both.
		let split = try QueryParser.parse("Mia 1/#interview")
		#expect(!split.matches(takeName: "Mia 1", clip: clip("a", tags: ["interview"])))

		#expect(try QueryParser.parse("'Mia 1'/*")
			.matches(takeName: "Mia 1", clip: clip("anything")))
		#expect(try QueryParser.parse("\"Mia 1\"/* or \"Mia 2\"/*")
			.matches(takeName: "Mia 2", clip: clip("anything")))
	}

	@Test func aReferenceIsASlugAndATakeMaySayAnything() {
		// The rule that tells an entry's kinds apart, stated over the thing it
		// is easiest to be sure about: what a reference looks like.
		#expect(ClipReference(reference: "intro")?.slug == "intro")
		#expect(ClipReference(reference: "Mia 1/mia-blick")?.take == "Mia 1")
		#expect(ClipReference(reference: "Mia 1/mia-blick")?.slug == "mia-blick")
		// Not references: each of these ends in something that is not a slug.
		#expect(ClipReference(reference: "#b-roll") == nil)
		#expect(ClipReference(reference: "Mia 1/#b-roll") == nil)
		#expect(ClipReference(reference: "Mia 1/*") == nil)
		#expect(ClipReference(reference: "intro or outro") == nil)
		#expect(ClipReference(reference: "/mia-blick") == nil)
	}

	@Test func draggingAClipOutOfASpacedTakeStaysAClip() throws {
		// The bug this rule exists for: the library writes `Mia 1/slug` for a
		// slug two takes share, the programme read the space as a query, and
		// the project was then saved as a query that could never match.
		let entry = try TimelineEntry(text: "Mia 1/mia-was-machen-oma-und-opa")
		#expect(entry.clip?.take == "Mia 1")
		#expect(entry.clip?.slug == "mia-was-machen-oma-und-opa")

		// The kinds either side of it are untouched.
		#expect(try TimelineEntry(text: "intro").clip?.slug == "intro")
		#expect(try TimelineEntry(text: "#b-roll").clip == nil)
		#expect(try TimelineEntry(text: "Mia 1/#b-roll").clip == nil)
		#expect(try TimelineEntry(text: "intro or outro").clip == nil)
		if case .group(let name, _) = try TimelineEntry(text: "@introduction").source {
			#expect(name == "introduction")
		} else {
			Issue.record("expected a section")
		}
	}

	@Test func aSpacedReferenceSurvivesTheFile() throws {
		// Round trip, because saving is where the mistake used to become
		// permanent: read as a clip, written back as a clip.
		let project = try ProjectReader.read("""
		timeline:
		  - Mia 1/mia-blick
		""")
		#expect(project.timeline[0].clip?.take == "Mia 1")
		let text = ProjectWriter.write(project)
		#expect(!text.contains("query:"))
		let back = try ProjectReader.read(text)
		#expect(back.timeline[0].clip?.take == "Mia 1")
		#expect(back.timeline[0].clip?.slug == "mia-blick")
	}

	@Test func aQueryThatMatchesNothingSaysWhy() {
		// The message is the whole point of the error, so it is worth a test:
		// the old one said "check the tag" about a query with no tag in it.
		let split = ResolveError.emptyQuery("Mia 1/mia-blick").errorDescription ?? ""
		#expect(split.contains("\"Mia 1\"/mia-blick"))
		#expect(!split.contains("lower-case"))

		let tag = ResolveError.emptyQuery("#b-rol").errorDescription ?? ""
		#expect(tag.contains("lower-case"))

		let bare = ResolveError.emptyQuery("b-rol").errorDescription ?? ""
		#expect(bare.contains("#b-rol"))
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
