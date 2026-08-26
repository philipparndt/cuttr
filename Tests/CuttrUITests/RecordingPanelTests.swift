import AppKit
import Testing
@testable import CuttrCompose
@testable import CuttrRecord
@testable import CuttrUI

/// The panel that makes a screencast, in the states it can be in.
///
/// The states are the point. Recording the screen needs a permission macOS
/// grants outside the app, and cuttr needs a browser it did not write; both are
/// ordinary situations rather than faults, both are invisible until somebody
/// presses record, and both are cheap to say in advance. A panel that collapsed
/// them into "recording failed" would be a panel nobody could act on.
@MainActor @Suite struct RecordingPanelTests {

	private func panel() -> RecordingPanel {
		_ = NSApplication.shared
		let made = RecordingPanel(frame: NSRect(x: 0, y: 0, width: 460, height: 320))
		made.layoutSubtreeIfNeeded()
		return made
	}

	/// Nothing to record until there is somewhere to go.
	@Test func recordWaitsForAUrl() {
		let panel = self.panel()
		#expect(!panel.canRecordForTesting)
		panel.typeForTesting(url: "https://example.com")
		#expect(panel.canRecordForTesting)
	}

	/// **Said before the button is pressed, not after.** The permission is a
	/// state with a sentence and a button, because it cannot be granted from
	/// inside the app.
	@Test func theMissingPermissionIsSaidWithSomewhereToGo() {
		let panel = self.panel()
		panel.typeForTesting(url: "https://example.com")
		panel.show(.needsConsent(.refused))
		#expect(!panel.canRecordForTesting, "it would have recorded black frames")
		#expect(panel.saysForTesting.contains("Screen Recording"))
		#expect(panel.offersSettingsForTesting)
	}

	/// And the state that wastes the most time says the thing that fixes it.
	@Test func grantedButNotYetSaysToStartAgain() {
		let panel = self.panel()
		panel.show(.needsConsent(.grantedButNotYet))
		#expect(panel.saysForTesting.lowercased().contains("again"))
	}

	@Test func noBrowserNamesWhatToInstall() {
		let panel = self.panel()
		panel.show(.noBrowser)
		#expect(!panel.canRecordForTesting)
		#expect(panel.saysForTesting.contains("Google Chrome"))
	}

	/// While it runs the button is the way out of it.
	@Test func recordingOffersStop() {
		let panel = self.panel()
		panel.typeForTesting(url: "https://example.com")
		panel.show(.recording)
		#expect(panel.recordTitleForTesting == "Stop")
		#expect(panel.canRecordForTesting)
	}

	/// **What the recording gives away**, said where the URL is typed and only
	/// when it applies — with the address bar hidden there is nothing to warn
	/// about.
	@Test func theUrlBeingInTheFilmIsSaid() {
		let panel = self.panel()
		panel.typeForTesting(url: "http://localhost:3000/admin")
		#expect(panel.saysForTesting.contains("readable"),
		        "nothing said that the URL is in the film")

		var bare = panel.recording
		bare.chrome = .none
		panel.recording = bare
		panel.show(.ready)
		#expect(!panel.saysForTesting.contains("readable"),
		        "warned about a URL that is not in the film")
	}

	/// And how much disk a recording costs, before the first one is made.
	@Test func whatItCostsIsSaidUpFront() {
		let panel = self.panel()
		panel.typeForTesting(url: "https://example.com")
		#expect(panel.saysForTesting.contains("MB a minute"))
	}

	/// A refusal keeps its own sentence rather than being turned into a
	/// generic one.
	@Test func aRefusalKeepsItsOwnWords() {
		let panel = self.panel()
		panel.typeForTesting(url: "https://example.com")
		let sized = Screencast.Trouble.wrongSize(
			got: CGSize(width: 1280, height: 788), wanted: CGSize(width: 1280, height: 720))
		panel.show(.refused(sized.described))
		#expect(panel.saysForTesting.contains("1280×788"))
		#expect(panel.canRecordForTesting, "there was no way to try again")
	}

	/// **A recording that was written down is made again rather than typed
	/// again**, which is the whole reason it is in the file. Choosing one fills
	/// the fields with it.
	@Test func theProjectsOwnRecordingsAreOffered() {
		let panel = self.panel()
		panel.stated = [
			Recording(name: "install-demo", url: "https://example.com/download",
			          width: 1600, height: 900),
			Recording(name: "the-settings", url: "https://example.com/settings"),
		]
		#expect(panel.statedNamesForTesting == ["something new", "install-demo", "the-settings"])

		panel.chooseForTesting(1)
		#expect(panel.recording.name == "install-demo")
		#expect(panel.recording.width == 1600)
		#expect(panel.recording.url == "https://example.com/download")
	}

	/// And a project that states none does not grow a menu with one item in it.
	@Test func aProjectWithNoRecordingsIsNotOfferedAList() {
		let panel = self.panel()
		#expect(panel.statedNamesForTesting.isEmpty)
	}

	/// What the fields say is what gets recorded.
	@Test func theFieldsAreTheRecording() {
		let panel = self.panel()
		panel.typeForTesting(url: "https://example.com/x")
		#expect(panel.recording.url == "https://example.com/x")
		#expect(panel.recording.width == 1280)
		#expect(panel.recording.chrome == .bar)
	}
}
