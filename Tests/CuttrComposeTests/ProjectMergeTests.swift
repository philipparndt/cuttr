import CuttrKit
import Foundation
import Testing
@testable import CuttrCompose

/// Two people's edits to one project.
///
/// The case that decides whether the feature is worth the button is the last
/// one: two people working in two different sections of the same programme,
/// merging without either of them being asked anything.
@Suite struct ProjectMergeTests {

	private func entry(_ text: String, label: String? = nil) throws -> TimelineEntry {
		var made = try TimelineEntry(text: text)
		made.label = label
		return made
	}

	private func project(_ timeline: [TimelineEntry], takes: [String] = ["a.cuttr"]) -> Project {
		Project(takes: takes, timeline: timeline)
	}

	// MARK: - The programme

	@Test func twoPeopleChangeDifferentShots() throws {
		let base = project([try entry("intro", label: "opening"),
		                    try entry("demo", label: "middle"),
		                    try entry("outro", label: "end")])
		var mine = base
		mine.timeline[0].trim.head = 1
		var theirs = base
		theirs.timeline[2].trim.tail = 2

		let merged = ProjectMerge.merge(base: base, mine: mine, theirs: theirs)
		#expect(merged.isClean)
		#expect(merged.project.timeline[0].trim.head == 1)
		#expect(merged.project.timeline[2].trim.tail == 2)
	}

	@Test func bothTrimmingOneShotIsAConflict() throws {
		let base = project([try entry("intro", label: "opening")])
		var mine = base
		mine.timeline[0].trim.head = 1
		var theirs = base
		theirs.timeline[0].trim.head = 2

		let merged = ProjectMerge.merge(base: base, mine: mine, theirs: theirs)
		#expect(merged.conflicts.count == 1)
		#expect(merged.conflicts.first?.id == "entry:as:opening")
		// Mine stands until it is answered.
		#expect(merged.project.timeline[0].trim.head == 1)
	}

	@Test func choosingTheirsKeepsTheShotWhereItWas() throws {
		let base = project([try entry("intro", label: "opening"),
		                    try entry("demo", label: "middle")])
		var mine = base
		mine.timeline[0].trim.head = 1
		var theirs = base
		theirs.timeline[0].trim.head = 2

		let merged = ProjectMerge.merge(base: base, mine: mine, theirs: theirs)
		let resolved = ProjectMerge.resolve(merged, choosing: ["entry:as:opening": .theirs])
		#expect(resolved.timeline.count == 2)
		#expect(resolved.timeline[0].trim.head == 2)
		#expect(resolved.timeline[0].label == "opening")
		#expect(resolved.timeline[1].label == "middle")
	}

	@Test func oneSideAddsAShot() throws {
		let base = project([try entry("intro", label: "opening")])
		let mine = base
		var theirs = base
		theirs.timeline.append(try entry("outro", label: "end"))

		let merged = ProjectMerge.merge(base: base, mine: mine, theirs: theirs)
		#expect(merged.isClean)
		#expect(merged.project.timeline.compactMap(\.label) == ["opening", "end"])
	}

	// MARK: - Sections

	/// The case the whole feature is for. Two people in two different parts of
	/// the programme, and neither is asked anything.
	@Test func twoPeopleWorkInTwoDifferentSections() throws {
		let base = project([
			TimelineEntry(group: "introduction", entries: [try entry("intro", label: "one")]),
			TimelineEntry(group: "wrap-up", entries: [try entry("outro", label: "two")]),
		])
		var mine = base
		if case .group(let name, var inside) = mine.timeline[0].source {
			inside.append(try entry("extra", label: "mine"))
			mine.timeline[0].source = .group(name, inside)
		}
		var theirs = base
		if case .group(let name, var inside) = theirs.timeline[1].source {
			inside.append(try entry("another", label: "theirs"))
			theirs.timeline[1].source = .group(name, inside)
		}

		let merged = ProjectMerge.merge(base: base, mine: mine, theirs: theirs)
		#expect(merged.isClean, "two sections is two places, not one conflict")

		guard case .group(_, let first) = merged.project.timeline[0].source,
		      case .group(_, let second) = merged.project.timeline[1].source else {
			Issue.record("the sections did not come back as sections"); return
		}
		#expect(first.compactMap(\.label) == ["one", "mine"])
		#expect(second.compactMap(\.label) == ["two", "theirs"])
	}

	/// Inside one section, the same rule again.
	@Test func aConflictInsideASectionIsNamedForWhereItIs() throws {
		let base = project([
			TimelineEntry(group: "introduction", entries: [try entry("intro", label: "one")]),
		])
		var mine = base, theirs = base
		if case .group(let name, var inside) = mine.timeline[0].source {
			inside[0].trim.head = 1
			mine.timeline[0].source = .group(name, inside)
		}
		if case .group(let name, var inside) = theirs.timeline[0].source {
			inside[0].trim.head = 2
			theirs.timeline[0].source = .group(name, inside)
		}

		let merged = ProjectMerge.merge(base: base, mine: mine, theirs: theirs)
		#expect(merged.conflicts.count == 1)
		#expect(merged.conflicts.first?.id == "entry:@introduction/as:one")
	}

	// MARK: - Everything else

	@Test func twoPeopleAddingATakeEachGetBoth() {
		let base = project([], takes: ["a.cuttr"])
		var mine = base
		mine.takes.append("b.cuttr")
		var theirs = base
		theirs.takes.append("c.cuttr")

		let merged = ProjectMerge.merge(base: base, mine: mine, theirs: theirs)
		#expect(merged.isClean)
		#expect(merged.project.takes == ["a.cuttr", "b.cuttr", "c.cuttr"])
	}

	@Test func twoPeopleAddingAStyleEachGetBoth() {
		let base = project([])
		var mine = base
		mine.styles["shouting"] = TextStyle.lowerThird
		var theirs = base
		theirs.styles["whispering"] = TextStyle.lowerThird

		let merged = ProjectMerge.merge(base: base, mine: mine, theirs: theirs)
		#expect(merged.isClean)
		#expect(merged.project.styles["shouting"] != nil)
		#expect(merged.project.styles["whispering"] != nil)
	}

	@Test func bothChangingTheOutputIsAConflict() {
		let base = project([])
		// Both away from the default, or one of them has not changed anything
		// and there is nothing to disagree about.
		var mine = base
		mine.output = Output(width: 1280, height: 720, framesPerSecond: 25)
		var theirs = base
		theirs.output = Output(width: 3840, height: 2160, framesPerSecond: 25)

		let merged = ProjectMerge.merge(base: base, mine: mine, theirs: theirs)
		#expect(merged.conflicts.map(\.id) == ["output"])
	}

	@Test func aKeyOnlyTheirSideCarriesIsKept() {
		let base = project([])
		let mine = base
		var theirs = base
		theirs.unknownKeys = ["grade-v2": "filmic"]

		let merged = ProjectMerge.merge(base: base, mine: mine, theirs: theirs)
		#expect(merged.project.unknownKeys["grade-v2"] as? String == "filmic")
	}

	/// Same guarantee the emitter makes everywhere else: a merged project is a
	/// project, and re-saving it changes nothing.
	@Test func aMergedProjectReSavesUnchanged() throws {
		let base = project([try entry("intro", label: "opening"),
		                    try entry("demo", label: "middle")])
		var mine = base
		mine.timeline[0].trim.head = 1
		var theirs = base
		theirs.timeline[1].trim.tail = 2

		let merged = ProjectMerge.merge(base: base, mine: mine, theirs: theirs)
		let once = ProjectWriter.write(merged.project)
		let back = try ProjectReader.read(once)
		#expect(ProjectWriter.write(back) == once)
		#expect(!once.contains("<<<<<<<"))
	}
}
