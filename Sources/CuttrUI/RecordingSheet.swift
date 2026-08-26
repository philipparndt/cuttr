import AppKit
import CuttrCompose
import CuttrKit
import CuttrRecord

/// The recording panel, over the project it records into.
///
/// A sheet rather than a window of its own, because a recording belongs to a
/// project: it lands beside that project's file, its browser profile lives in
/// that project's folder, and the take it writes appears in that project's
/// material tree.
@MainActor
public final class RecordingSheet: NSViewController {

	private let panel = RecordingPanel()
	private let project: URL
	private let onDone: (URL) -> Void
	private var screencast: Screencast?
	private var clock: Timer?
	private var hosted: NSWindow?

	public init(project: URL, stated: [Recording] = [], onDone: @escaping (URL) -> Void) {
		self.project = project
		self.onDone = onDone
		super.init(nibName: nil, bundle: nil)
		panel.stated = stated
		if let first = stated.first { panel.recording = first }
	}

	@available(*, unavailable) required init?(coder: NSCoder) { nil }

	@discardableResult
	public static func present(over view: NSView, project: URL, stated: [Recording] = [],
	                           onDone: @escaping (URL) -> Void) -> Bool {
		guard let window = view.window else { return false }
		let sheet = RecordingSheet(project: project, stated: stated, onDone: onDone)
		window.beginSheet(sheet.sheet()) { _ in }
		return true
	}

	private func sheet() -> NSWindow {
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 340),
		                      styleMask: [.titled, .closable], backing: .buffered, defer: false)
		window.contentViewController = self
		window.title = "Record a screencast"
		window.isReleasedWhenClosed = false
		hosted = window
		return window
	}

	public override func loadView() {
		view = panel
		panel.frame = NSRect(x: 0, y: 0, width: 520, height: 340)
	}

	public override func viewDidLoad() {
		super.viewDidLoad()
		panel.onOpenSettings = { NSWorkspace.shared.open(Consent.settings) }
		panel.onRecord = { [weak self] recording in self?.begin(recording) }
		panel.onStop = { [weak self] in self?.end() }
		// Asked as the sheet opens rather than when the button is pressed: both
		// of the things that can be missing are cheap to look for, and knowing
		// before somebody has typed a URL is the whole difference between a
		// panel that explains and one that refuses.
		Task { @MainActor in
			let consent = await ConsentCheck.ask()
			guard !consent.canRecord else {
				if Browser.find() == nil { panel.show(.noBrowser) }
				return
			}
			panel.show(.needsConsent(consent))
		}
	}

	private func begin(_ recording: Recording) {
		let made = Screencast(recording: recording, project: project)
		screencast = made
		panel.show(.opening)
		Task { @MainActor in
			do {
				try await made.start()
				panel.show(.recording)
				clock?.invalidate()
				clock = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
					MainActor.assumeIsolated { self.panel.tick(made.elapsed) }
				}
			} catch let trouble as Screencast.Trouble {
				screencast = nil
				if case .noConsent(let consent) = trouble { panel.show(.needsConsent(consent)) }
				else if case .noBrowser = trouble { panel.show(.noBrowser) }
				else { panel.show(.refused(trouble.described)) }
			} catch {
				screencast = nil
				panel.show(.refused(error.localizedDescription))
			}
		}
	}

	private func end() {
		clock?.invalidate()
		clock = nil
		guard let screencast else { return }
		Task { @MainActor in
			let made = await screencast.stop()
			self.screencast = nil
			guard let made else {
				panel.show(.refused("Nothing was captured, so nothing was written."))
				return
			}
			panel.show(.made(made))
			onDone(made)
		}
	}

	/// The browser goes with the sheet. A window nobody owns is what happens
	/// otherwise, still holding cuttr's profile open.
	public override func viewWillDisappear() {
		super.viewWillDisappear()
		clock?.invalidate()
		clock = nil
		screencast?.close()
		screencast = nil
	}
}
