@preconcurrency import AVFoundation
import Foundation
import ScreenCaptureKit

/// Whether cuttr may record the screen, asked before anything is opened.
///
/// **Why this is a state and not an error.** macOS grants screen recording
/// outside the app, in System Settings, and cannot be asked for it inline. An
/// app that does not have it is not refused: it is handed a picture of an empty
/// desktop, frame after frame, and writes a film of nothing. That is the worst
/// possible answer — a file that looks like a recording, plays like a recording,
/// and is black.
///
/// So it is asked before the browser is opened and before a frame is written,
/// and the answer is one of three things rather than a thrown error.
public enum Consent: Sendable, Equatable {
	/// cuttr can record.
	case granted
	/// It cannot, and macOS has never been asked.
	case refused
	/// It has been granted since this process started, and this process cannot
	/// use it yet.
	///
	/// A real state and the one that wastes the most time: somebody grants the
	/// permission, comes back, presses record, and gets black frames — because
	/// the answer was cached when the process launched. Saying "quit and open
	/// it again" is the whole fix, and it can only be said by something that
	/// knows the difference.
	case grantedButNotYet

	public var canRecord: Bool { self == .granted }

	/// What to tell somebody, in one sentence.
	public var explanation: String? {
		switch self {
		case .granted:
			return nil
		case .refused:
			return "cuttr needs permission to record the screen. "
				+ "Turn it on in Privacy & Security → Screen Recording."
		case .grantedButNotYet:
			return "Screen recording is now allowed. Quit cuttr and open it again "
				+ "to use it — macOS only hands the permission out at launch."
		}
	}

	/// The settings pane to open, for the button beside the sentence above.
	public static let settings = URL(
		string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
}

/// What the system says, and what it said when this process started.
///
/// Two answers rather than one, because the difference between them is the
/// ``Consent/grantedButNotYet`` case: `CGPreflightScreenCaptureAccess` answers
/// what is true *now*, and what a running process can actually do was decided
/// when it launched.
public enum ConsentCheck {

	/// What was true when this was first asked, which is as near to launch as
	/// anything asks.
	private nonisolated(unsafe) static var atLaunch: Bool?
	private static let lock = NSLock()

	/// Whether cuttr may record, and whether it may record *yet*.
	///
	/// `SCShareableContent` is the honest question — it is the thing that will
	/// be asked for the window — and it throws when the permission is not
	/// there. `CGPreflightScreenCaptureAccess` is asked as well, because it
	/// answers without a round trip and without the possibility of a prompt.
	public static func ask() async -> Consent {
		let now = CGPreflightScreenCaptureAccess()
		lock.lock()
		if atLaunch == nil { atLaunch = now }
		let then = atLaunch ?? now
		lock.unlock()

		guard now else { return .refused }
		guard then else { return .grantedButNotYet }
		// Granted, and granted early enough — so the content is really askable.
		// A failure here is the permission being true and unusable, which is
		// the same thing to somebody sitting in front of it.
		do {
			_ = try await SCShareableContent.excludingDesktopWindows(
				false, onScreenWindowsOnly: true)
			return .granted
		} catch {
			return .grantedButNotYet
		}
	}

	/// For the tests, and for the one case that cannot be reached from a test:
	/// what the answer was at launch.
	static func rememberForTesting(_ granted: Bool?) {
		lock.lock()
		atLaunch = granted
		lock.unlock()
	}

	/// The three answers, worked out from the two facts, without asking the
	/// system anything.
	///
	/// Separated so the states can be tested apart from a machine that has —
	/// or has not — been granted the permission, which is not something a test
	/// can arrange.
	static func reading(now: Bool, atLaunch: Bool) -> Consent {
		guard now else { return .refused }
		guard atLaunch else { return .grantedButNotYet }
		return .granted
	}
}
