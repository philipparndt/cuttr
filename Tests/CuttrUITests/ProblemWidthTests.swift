import AppKit
import Testing
@testable import CuttrCompose
@testable import CuttrUI

/// What the window says about a project it could not resolve entirely.
@MainActor @Suite struct ProblemWidthTests {

	/// A project with thirteen unfilled sections opened a window five screens
	/// wide. The warnings were joined into one line, and a label's intrinsic
	/// width is the width of its whole string however it is truncated — so the
	/// message decided how wide the window was.
	@Test func aLongMessageDoesNotDecideHowWideTheWindowIs() throws {
		let document = ComposeDocument(project: Project(
			takes: [], timeline: [TimelineEntry(source: .card(Card(duration: 2)))]))
		let controller = ComposeWindowController(document: document)
		let window = controller.windowForTesting
		let many = (1...20).map {
			"The section `@a-question-somebody-has-not-answered-yet-\($0)` has nothing in it."
		}
		controller.setProblemForTesting(ComposeWindowController.line(from: many))
		guard let content = window.contentView else {
			Issue.record("no window")
			return
		}
		content.layoutSubtreeIfNeeded()
		// Roomy, and nothing like the 5,810 points that started this.
		// Roomy, and nothing like the 5,810 points that started this.
		#expect(content.fittingSize.width < 1200)
		// And it still says the first thing, with a count of the rest.
		#expect(ComposeWindowController.line(from: many).contains("and 19 more"))
		#expect(ComposeWindowController.line(from: ["just the one"]) == "just the one")
		#expect(ComposeWindowController.line(from: []).isEmpty)
	}
}
