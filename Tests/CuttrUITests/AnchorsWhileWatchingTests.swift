import AppKit
import Testing
@testable import CuttrCompose
@testable import CuttrUI

/// Tracking marks are for making the film, not for watching it.
///
/// A tracked face is a thing you place an overlay *against*; once it is placed,
/// the dots are in the way of seeing the thing they placed. So they are off on
/// the preview page and in full screen, and back on when the editing side
/// returns — and the choice somebody made on that side survives the trip.
@MainActor @Suite struct AnchorsWhileWatchingTests {

	private func window() throws -> ComposeWindowController {
		_ = NSApplication.shared
		let project = try ProjectReader.read("""
			timeline:
			  - {card: 00:10.000, fill: "#101010"}
			""")
		let document = ComposeDocument(project: project)
		document.apply(project)
		let controller = ComposeWindowController(document: document)
		let window = controller.windowForTesting
		window.setContentSize(NSSize(width: 1400, height: 900))
		window.layoutIfNeeded()
		return controller
	}

	@Test func anchorsAreOnWhileEditing() throws {
		let controller = try window()
		controller.show(.edit)
		#expect(controller.anchorsShowingForTesting)
	}

	@Test func andOffOnThePreviewPage() throws {
		let controller = try window()
		controller.show(.preview)
		#expect(!controller.anchorsShowingForTesting,
		        "the film is being watched through a face full of dots")
	}

	@Test func andBackOnComingAwayFromIt() throws {
		let controller = try window()
		controller.show(.preview)
		controller.show(.edit)
		#expect(controller.anchorsShowingForTesting)
	}

	/// The choice somebody made while editing survives going to watch and
	/// coming back. Turning them off and going to the preview must not have
	/// them come back on afterwards.
	@Test func aChoiceToHideThemSurvivesTheTrip() throws {
		let controller = try window()
		controller.show(.edit)
		controller.setAnchorsForTesting(false)
		#expect(!controller.anchorsShowingForTesting)

		controller.show(.preview)
		controller.show(.edit)
		#expect(!controller.anchorsShowingForTesting,
		        "they came back on after a trip to the preview")
	}

	/// Going to the preview twice must not remember the state the first trip
	/// set. This is what a pair of hand-offs at each door got wrong: full
	/// screen is entered *through* the preview page, so it fired twice.
	@Test func goingToWatchTwiceStillRemembersTheEditingSide() throws {
		let controller = try window()
		controller.show(.edit)
		#expect(controller.anchorsShowingForTesting)

		controller.show(.preview)
		controller.show(.preview)
		controller.show(.edit)
		#expect(controller.anchorsShowingForTesting,
		        "the second trip remembered what the first one had just set")
	}
}
