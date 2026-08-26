import Foundation
import Testing
@testable import CuttrRecord

/// The three answers to "may cuttr record the screen", worked out from the two
/// facts, without asking the system anything.
///
/// It has to be testable apart from the machine: whether *this* Mac has granted
/// the permission is not something a test can arrange, and a suite that only
/// passes on a machine somebody has clicked through System Settings on is a
/// suite that says nothing.
@Suite struct ConsentTests {

	@Test func grantedIsGranted() {
		#expect(ConsentCheck.reading(now: true, atLaunch: true) == .granted)
		#expect(Consent.granted.canRecord)
		#expect(Consent.granted.explanation == nil)
	}

	@Test func refusedIsSaidWithWhereToGoAndFixIt() {
		let consent = ConsentCheck.reading(now: false, atLaunch: false)
		#expect(consent == .refused)
		#expect(!consent.canRecord)
		let said = try? #require(consent.explanation)
		#expect(said?.contains("Screen Recording") == true)
	}

	/// **The state that wastes the most time.** Somebody grants the permission,
	/// comes back, presses record, and gets black frames — because what a
	/// running process may do was decided when it launched. Saying "quit and
	/// open it again" is the whole fix, and only something that knows the
	/// difference can say it.
	@Test func grantedSinceLaunchSaysToStartAgain() {
		let consent = ConsentCheck.reading(now: true, atLaunch: false)
		#expect(consent == .grantedButNotYet)
		#expect(!consent.canRecord, "it would have recorded black frames")
		let said = try? #require(consent.explanation)
		#expect(said?.lowercased().contains("again") == true)
	}

	/// Taken away since launch is refused, not "not yet": there is nothing to
	/// wait for.
	@Test func takenAwaySinceLaunchIsARefusal() {
		#expect(ConsentCheck.reading(now: false, atLaunch: true) == .refused)
	}

	/// The button beside the sentence goes to the pane the sentence names.
	@Test func thereIsSomewhereToGo() {
		#expect(Consent.settings.absoluteString.contains("Privacy_ScreenCapture"))
	}
}
