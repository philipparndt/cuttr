import AppKit
import CuttrCompose
import Foundation

/// Whatever is being recorded: an application cuttr opens, sizes, records and
/// closes.
///
/// **Why a protocol rather than a browser and a terminal.** The four things a
/// recording needs of an application are the same four whichever it is — open
/// it, get it to a size, know which process it is so its window can be found,
/// and close it afterwards — and only two of them differ between a browser and a
/// terminal. Everything else in ``Screencast`` is about the order things are
/// refused in, and that does not change at all.
///
/// The odd one out is ``whatIsStillTheirs``, and it is on the protocol because
/// only the sitter can answer it. A browser with a fresh profile has nothing of
/// anybody's in the frame and says nothing. A terminal reads the person's own
/// startup files and cannot be stopped from doing so, and saying that out loud
/// before the recording is the difference between a known limit and a surprise
/// in the finished film.
@MainActor
public protocol Sitter: Sendable {

	/// What it is called, for a refusal that names it.
	var described: String { get }

	/// What of the person's own setup will be in the frame, or nothing when the
	/// answer is nothing.
	var whatIsStillTheirs: String? { get }

	/// Opens it, asking for a picture of this size.
	///
	/// `asking` is in pixels — always, whatever the application measures itself
	/// in. A terminal that counts columns converts, and gets the conversion
	/// wrong, and is corrected by the loop below; nothing outside a sitter ever
	/// has to know how wide a character is.
	func open(_ recording: Recording, in project: URL,
	          asking: CGSize) async throws -> NSRunningApplication

	/// What to ask for next, having asked for one size and got another.
	///
	/// The default puts the difference on: ask for 1280 wide, get 1264, ask for
	/// 1296. That converges in one round for anything whose chrome is a fixed
	/// number of points, which is every browser.
	func next(asking: CGSize, wanted: CGSize, got: CGSize) -> CGSize
}

public extension Sitter {

	var whatIsStillTheirs: String? { nil }

	func next(asking: CGSize, wanted: CGSize, got: CGSize) -> CGSize {
		CGSize(width: asking.width + (wanted.width - got.width),
		       height: asking.height + (wanted.height - got.height))
	}

	/// Opens an application the way the system opens one, and hands back the
	/// instance.
	///
	/// **Not `Process`, and not `open`.** Running the binary inside a bundle is
	/// not the same thing as launching an application, and terminals are where
	/// the difference shows: Ghostty refuses it outright and says so. `open`
	/// launches properly and hands back nothing, so there is no process to size,
	/// to find the window of, or to close.
	///
	/// `openApplication` does both, and `createsNewApplicationInstance` is what
	/// makes it cuttr's own copy rather than another window of the one somebody
	/// is working in.
	func launch(_ application: URL, arguments: [String],
	            environment: [String: String] = [:]) async throws -> NSRunningApplication {
		let configuration = NSWorkspace.OpenConfiguration()
		configuration.arguments = arguments
		configuration.createsNewApplicationInstance = true
		configuration.activates = true
		if !environment.isEmpty { configuration.environment = environment }
		return try await NSWorkspace.shared.openApplication(
			at: application, configuration: configuration)
	}
}

/// Which sitter a recording wants, and whether it is there.
@MainActor
public enum Sitters {

	/// The one this recording needs, or nothing when it is not installed.
	public static func find(for recording: Recording,
	                        in manager: FileManager = .default) -> (any Sitter)? {
		if let terminal = recording.terminal {
			let at = URL(fileURLWithPath: terminal.application)
			guard manager.fileExists(atPath: at.path) else { return nil }
			switch terminal {
			case .terminal: return TerminalApp(application: at)
			case .ghostty: return Ghostty(application: at)
			case .abydos: return Abydos(application: at)
			}
		}
		return Browser.find(recording.browser, in: manager)
	}

	/// What to say when it is not.
	public static func missing(for recording: Recording) -> String {
		guard let terminal = recording.terminal else { return Browser.missing }
		return "\(terminal.described) is not installed. cuttr drives "
			+ Recording.Terminal.allCases.map(\.described).joined(separator: ", ")
			+ " — install one of them, or choose another."
	}
}
