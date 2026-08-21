import AppKit
import Foundation
import Testing
@testable import CuttrCompose
@testable import CuttrKit
@testable import CuttrUI

/// How long a section runs, said in the tree beside how much is in it.
///
/// "Five entries" does not answer the question somebody is actually asking of a
/// section, which is whether the intro is thirty seconds or four minutes.
@MainActor @Suite struct SectionLengthTests {

	private func panel(_ project: Project) throws -> (ProgrammePanel, Project) {
		let panel = ProgrammePanel(frame: NSRect(x: 0, y: 0, width: 320, height: 600))
		panel.resolved = try Resolver.resolve(
			project, baseURL: URL(fileURLWithPath: NSTemporaryDirectory()))
		panel.reload(project, vocabulary: ComposeDocument.Vocabulary())
		return (panel, project)
	}

	private func section(_ entries: [TimelineEntry], named name: String) -> TimelineEntry {
		TimelineEntry(group: name, entries: entries)
	}

	private func card(_ seconds: Double) -> TimelineEntry {
		TimelineEntry(source: .card(Card(duration: seconds)))
	}

	@Test func aSectionSaysHowLongItRuns() throws {
		let project = Project(timeline: [
			section([card(4), card(6)], named: "intro"),
			section([card(3)], named: "outro"),
		])
		let (panel, _) = try panel(project)
		#expect(panel.length(ofSection: [0], project.timeline[0]) == 10)
		#expect(panel.length(ofSection: [1], project.timeline[1]) == 3)
	}

	/// Measured on the programme, not by adding the clips up: two shots that
	/// overlap are on screen for less than the sum of their lengths, and the
	/// section is as long as it is on screen.
	@Test func aDissolveIsCountedOnce() throws {
		var second = card(6)
		let plain = Project(timeline: [section([card(4), second], named: "intro")])
		second.transition = Transition(.dissolve, seconds: 1)
		let overlapped = Project(timeline: [section([card(4), second], named: "intro")])
		let (a, _) = try panel(plain)
		let (b, _) = try panel(overlapped)
		#expect(a.length(ofSection: [0], plain.timeline[0]) == 10)
		#expect(b.length(ofSection: [0], overlapped.timeline[0]) == 9)
	}

	/// A section nobody has filled has nothing to say. "0 entries" and
	/// "00:00.000" beside it is the same thing said twice.
	@Test func anEmptySectionSaysNothing() throws {
		// With something else on the programme, because a programme with
		// nothing on it does not resolve at all.
		let project = Project(timeline: [card(2), section([], named: "later")])
		let (panel, _) = try panel(project)
		#expect(panel.length(ofSection: [1], project.timeline[1]) == nil)
	}

	/// Only a section. A clip's row already says what it is and how much of it
	/// was taken; a card's says how long it is in its own name.
	@Test func onlyASectionIsMeasuredThisWay() throws {
		let project = Project(timeline: [card(4), section([card(6)], named: "intro")])
		let (panel, _) = try panel(project)
		#expect(panel.length(ofSection: [0], project.timeline[0]) == nil)
		#expect(panel.length(ofSection: [1], project.timeline[1]) == 6)
	}

	/// A section inside a section counts everything under it, however deep.
	@Test func aSectionCountsWhatIsNestedInIt() throws {
		let project = Project(timeline: [
			section([card(2), section([card(3), card(4)], named: "inner")], named: "outer"),
		])
		let (panel, _) = try panel(project)
		#expect(panel.length(ofSection: [0], project.timeline[0]) == 9)
	}
}
