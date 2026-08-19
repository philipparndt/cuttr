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

	/// The one that deleted somebody's clip: dragging into a section that comes
	/// *after* it. Taking the clip out moves the section up a place, and writing
	/// into where the section used to be writes into nothing.
	@Test func draggingIntoASectionBelowItKeepsTheClip() {
		var project = self.project()
		let landed = project.moveEntry(at: [0], toParent: [1], index: -1)
		#expect(landed == [0, 2])
		#expect(project.rows.map(\.entry.source.description)
			== ["@middle", "two", "three", "one", "four"])
	}

	@Test func draggingOutOfASectionKeepsIt() {
		var project = self.project()
		let landed = project.moveEntry(at: [1, 0], toParent: [], index: 0)
		#expect(landed == [0])
		#expect(project.rows.map(\.entry.source.description)
			== ["two", "one", "@middle", "three", "four"])
	}

	@Test func draggingWithinOneParentCountsTheGapItLeaves() {
		var project = self.project()
		#expect(project.moveEntry(at: [0], toParent: [], index: 2) == [1])
		#expect(project.rows.map(\.entry.source.description)
			== ["@middle", "two", "three", "one", "four"])
	}

	@Test func aSectionCannotBeDroppedInsideItself() {
		var project = self.project()
		#expect(project.moveEntry(at: [1], toParent: [1], index: 0) == [1])
		#expect(project.rows.count == 5)
	}

	@Test func droppingAtTheTopOfASectionGoesFirst() {
		var project = self.project()
		let landed = project.insertEntry(TimelineEntry(clip: ClipReference("new")), into: [1], at: 0)
		#expect(landed == [1, 0])
		#expect(project.rows.map(\.entry.source.description)
			== ["one", "@middle", "new", "two", "three", "four"])
	}

	@Test func droppingPastTheEndAppends() {
		var project = self.project()
		#expect(project.insertEntry(TimelineEntry(clip: ClipReference("new")), into: [], at: 99) == [3])
		#expect(project.entry(at: [3])?.source.description == "new")
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
