@preconcurrency import AVFoundation
import CuttrCompose
import CuttrKit
import Foundation
import ScreenCaptureKit

/// One screencast, made: a browser opened, a window recorded, a take written.
///
/// The whole of what this orchestrates is the order things are refused in.
/// Consent first, because an unconsented capture writes black frames rather
/// than failing. Then the browser, because there is no point asking the system
/// for a window that nothing is going to open. Then the window's size, because
/// a recording that is 8 points off has to be cropped, and cropping a screen
/// recording throws away the resolution that made it readable.
///
/// Everything that can be said no to is said no to before a file exists.
@MainActor
public final class Screencast {

	public enum Trouble: Error, Equatable {
		case noConsent(Consent)
		case noBrowser
		case didNotOpen
		case wrongSize(got: CGSize, wanted: CGSize)
		case cannotWrite(String)

		public var described: String {
			switch self {
			case .noConsent(let consent):
				return consent.explanation ?? "cuttr cannot record the screen."
			case .noBrowser:
				return Browser.missing
			case .didNotOpen:
				return "The browser did not open a window to record."
			case .wrongSize(let got, let wanted):
				return "The browser opened at \(Int(got.width))×\(Int(got.height)) "
					+ "and the recording asks for \(Int(wanted.width))×\(Int(wanted.height)). "
					+ "A window that will not take the size cannot be recorded at it."
			case .cannotWrite(let why):
				return "The recording could not be written: \(why)"
			}
		}
	}

	public let recording: Recording
	/// The folder the project is in: where the media lands, where the take is
	/// written, and where the browser's profile lives.
	public let project: URL

	private var browser: Process?
	private var recorder: WindowRecorder?

	public init(recording: Recording, project: URL) {
		self.recording = recording
		self.project = project
	}

	/// How long the recording has been running, for the clock on screen.
	public var elapsed: Double { recorder?.elapsed ?? 0 }
	public var isRecording: Bool { recorder != nil }

	// MARK: - Doing it

	/// Opens the browser, finds its window, and starts recording.
	public func start() async throws {
		let consent = await ConsentCheck.ask()
		guard consent.canRecord else { throw Trouble.noConsent(consent) }
		guard let found = Browser.find(recording.browser) else { throw Trouble.noBrowser }

		let wanted = recording.size
		// Asked for, measured, and asked again with the difference put right.
		//
		// `--window-size` is the browser's idea of a window size and not
		// necessarily the same idea as the one that gets recorded — the chrome
		// is above the page, and how much of it there is belongs to whichever
		// Chrome is installed. Rather than encode a guess about that, cuttr
		// asks, looks at what it got, and asks again once with the difference
		// applied. A version whose arithmetic changes costs one extra launch
		// rather than a wrong recording.
		var asking = wanted
		var window: SCWindow?
		for attempt in 0..<2 {
			try await open(found, asking: asking)
			guard let opened = try await windowOfBrowser() else { throw Trouble.didNotOpen }
			let got = opened.frame.size
			if abs(got.width - wanted.width) < 1, abs(got.height - wanted.height) < 1 {
				window = opened
				break
			}
			guard attempt == 0 else { throw Trouble.wrongSize(got: got, wanted: wanted) }
			asking = CGSize(width: asking.width + (wanted.width - got.width),
			                height: asking.height + (wanted.height - got.height))
			close()
		}
		guard let window else { throw Trouble.didNotOpen }

		// At the window's own scale, so the film is the pixels the window drew
		// rather than an enlargement of them. `size:` names the window; what
		// comes out is that at the display's resolution.
		let scale = NSScreen.screens.first { $0.frame.intersects(window.frame) }?
			.backingScaleFactor ?? 2
		let pixels = CGSize(width: (wanted.width * scale).rounded(),
		                    height: (wanted.height * scale).rounded())
		let media = project.appendingPathComponent("\(recording.name).mov")
		let made: WindowRecorder
		do {
			made = try WindowRecorder(window: window, size: pixels, to: unused(media))
		} catch let trouble as WindowRecorder.Trouble {
			close()
			if case .cannotWrite(let why) = trouble { throw Trouble.cannotWrite(why) }
			throw Trouble.didNotOpen
		}
		do {
			try await made.start()
		} catch {
			close()
			throw Trouble.cannotWrite(error.localizedDescription)
		}
		recorder = made
	}

	/// Stops, closes the browser, and writes the take.
	///
	/// The browser is closed on every path out of here including the ones that
	/// fail, because a browser left running with cuttr's profile in it is a
	/// window nobody owns.
	@discardableResult
	public func stop() async -> URL? {
		defer {
			close()
			recorder = nil
		}
		guard let recorder else { return nil }
		guard let media = await recorder.stop() else { return nil }
		try? writeTake(for: media)
		return media
	}

	/// Closes the browser cuttr started, and only that one.
	public func close() {
		browser?.terminate()
		browser = nil
	}

	// MARK: - The parts

	private func open(_ found: Browser, asking: CGSize) async throws {
		let profile = Browser.profile(for: recording, in: project)
		try? FileManager.default.createDirectory(
			at: profile, withIntermediateDirectories: true)
		let task = Process()
		task.executableURL = found.executable
		task.arguments = found.arguments(for: recording, profile: profile, content: asking)
		do {
			try task.run()
		} catch {
			throw Trouble.noBrowser
		}
		browser = task
	}

	/// The window the browser cuttr started has opened.
	///
	/// Matched by process, not by title: a title is the page's and changes
	/// while the page loads, and there is no reason to guess when the process
	/// is known. Waited for, because a browser takes a moment to put a window
	/// on screen and asking too early answers nothing.
	private func windowOfBrowser() async throws -> SCWindow? {
		guard let pid = browser?.processIdentifier else { return nil }
		for _ in 0..<40 {
			let content = try? await SCShareableContent.excludingDesktopWindows(
				false, onScreenWindowsOnly: true)
			let mine = (content?.windows ?? []).filter {
				$0.owningApplication?.processID == pid && $0.isOnScreen
					&& $0.frame.width > 200 && $0.frame.height > 200
			}
			// The biggest, which is the page rather than a panel or a tooltip.
			if let window = mine.max(by: { $0.frame.width * $0.frame.height
				< $1.frame.width * $1.frame.height }) {
				return window
			}
			try? await Task.sleep(nanoseconds: 250_000_000)
		}
		return nil
	}

	/// A name nothing is using yet.
	///
	/// A second recording of the same thing is a second take, never a
	/// replacement — the reason to record something again is nearly always to
	/// compare the two, and the rest of the program already knows how to say
	/// that.
	func unused(_ wanted: URL) -> URL {
		guard FileManager.default.fileExists(atPath: wanted.path) else { return wanted }
		let stem = wanted.deletingPathExtension().lastPathComponent
		let extension_ = wanted.pathExtension
		for number in 2...99 {
			let tried = wanted.deletingLastPathComponent()
				.appendingPathComponent("\(stem)-\(number)").appendingPathExtension(extension_)
			if !FileManager.default.fileExists(atPath: tried.path) { return tried }
		}
		return wanted
	}

	/// The take for a recording that has just been made.
	///
	/// Written so the recording arrives as *material* rather than as a file
	/// somebody has to import: it is in the material tree the moment the
	/// project is reloaded, with one clip covering the whole of it, which is
	/// where cutting starts.
	@discardableResult
	func writeTake(for media: URL) throws -> URL {
		let asset = AVURLAsset(url: media)
		let seconds = CMTimeGetSeconds(asset.duration)
		let length = seconds.isFinite && seconds > 0 ? seconds : 0
		let name = media.deletingPathExtension().lastPathComponent
		let takes = project.appendingPathComponent("takes", isDirectory: true)
		try? FileManager.default.createDirectory(at: takes, withIntermediateDirectories: true)
		let at = unused(takes.appendingPathComponent(name).appendingPathExtension("cuttr"))
		let take = Take(video: "../\(media.lastPathComponent)", clips: [
			Clip(slug: Slug.make(from: name), name: "the whole recording",
			     start: 0, end: length),
		])
		try TakeWriter.write(take).write(to: at, atomically: true, encoding: .utf8)
		return at
	}
}
