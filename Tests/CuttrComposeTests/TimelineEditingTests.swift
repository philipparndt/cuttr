import Testing
@testable import CuttrCompose

/// Arithmetic on the timeline tree, which is where an editor gets things
/// quietly wrong.
@Suite struct TimelineEditingTests {

	private func project() -> Project {
		Project(timeline: [
			TimelineEntry(clip: ClipReference("one")),
			TimelineEntry(group: "middle", entries: [
				TimelineEntry(clip: ClipReference("two")),
				TimelineEntry(clip: ClipReference("three")),
			]),
			TimelineEntry(clip: ClipReference("four")),
		])
	}

	@Test func flatteningIndentsTheContents() {
		let rows = project().rows
        #expect(rows.map(\.depth) == [0, 0, 1, 1, 0])
		#expect(rows.map(\.path) == [[0], [1], [1, 0], [1, 1], [2]])
		#expect(rows.map(\.entry.source.description) == ["one", "@middle", "two", "three", "four"])
	}

	@Test func aPathReachesInside() {
		#expect(project().entry(at: [1, 1])?.source.description == "three")
		#expect(project().entry(at: [9]) == nil)
		#expect(project().entry(at: [0, 0]) == nil)
	}

	@Test func removingInsideAGroupLeavesTheRestAlone() {
		var p = project()
		p.removeEntry(at: [1, 0])
		#expect(p.rows.map(\.entry.source.description) == ["one", "@middle", "three", "four"])
	}

	@Test func addingWithAGroupSelectedGoesInsideIt() {
		// Which is what selecting a group and pressing plus obviously means.
		var p = project()
		p.insertEntry(TimelineEntry(clip: ClipReference("new")), after: [1])
		#expect(p.rows.map(\.entry.source.description) == ["one", "@middle", "two", "three", "new", "four"])
	}

	@Test func addingAfterAClipPutsItNext() {
		var p = project()
		p.insertEntry(TimelineEntry(clip: ClipReference("new")), after: [0])
		#expect(p.rows.map(\.entry.source.description) == ["one", "new", "@middle", "two", "three", "four"])
	}

	@Test func addingAfterNothingAppends() {
		var p = project()
		p.insertEntry(TimelineEntry(clip: ClipReference("new")), after: nil)
		#expect(p.timeline.last?.source.description == "new")
	}

	@Test func movingStaysInsideItsOwnParent() {
		var p = project()
		// `two` and `three` are in the group; moving `two` down swaps them and
		// does not escape into the top level.
		let landed = p.moveEntry(at: [1, 0], by: 1)
		#expect(landed == [1, 1])
		#expect(p.rows.map(\.entry.source.description) == ["one", "@middle", "three", "two", "four"])
	}

	@Test func movingPastTheEndDoesNothing() {
		var p = project()
		p.moveEntry(at: [1, 1], by: 1)
		p.moveEntry(at: [0], by: -1)
		#expect(p.rows.map(\.entry.source.description) == ["one", "@middle", "two", "three", "four"])
	}

	@Test func replacingKeepsTheShapeAroundIt() {
		var p = project()
		p.replaceEntry(at: [1, 0], with: TimelineEntry(clip: ClipReference("swapped")))
		#expect(p.rows.map(\.entry.source.description) == ["one", "@middle", "swapped", "three", "four"])
	}

	@Test func editsSurviveTheFile() throws {
		var p = project()
		p.insertEntry(TimelineEntry(clip: ClipReference("new")), after: [1])
		p.moveEntry(at: [0], by: 1)
		let back = try ProjectReader.read(ProjectWriter.write(p))
		#expect(back.rows.map(\.entry.source.description) == p.rows.map(\.entry.source.description))
	}
}
