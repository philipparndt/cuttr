import AppKit
import CuttrCompose
import CuttrKit
import CuttrRecord

/// Where a recording is made: the settings, the button, and the clock.
///
/// **A page rather than a sheet.** It was a sheet on a menu item, and the first
/// thing that happened was somebody looking for it under *New Take* and not
/// finding it. Recording is not a dialogue somebody dismisses — it is one of the
/// things this window is for, alongside cutting and previewing, and the settings
/// it needs are worth leaving on screen while the browser is open beside them.
///
/// The rail's order is the ⌘ number, so this is last even though recording comes
/// first in the work: putting it above Preview would move a number somebody
/// already has in their fingers.
@MainActor
public final class RecordPage: NSView {

	private let panel = RecordingPanel()
	private let heading = NSTextField(labelWithString: "RECORD")
	private var screencast: Screencast?
	private var clock: Timer?

	/// Where recordings land, and where the browser's profile lives. `nil` for a
	/// project that has never been saved — which is the one state this page
	/// cannot work in, and says so.
	public var project: URL? { didSet { showWhereItStands() } }

	/// What the project already says it records.
	public var stated: [Recording] = [] {
		didSet {
			panel.stated = stated
			if let first = stated.first, panel.recording.url.isEmpty,
			   !panel.recording.recordsATerminal {
				panel.recording = first
			}
		}
	}

	/// A recording was made and is at this URL. The window adds the take.
	public var onRecorded: ((URL) -> Void)?

	public override init(frame: NSRect) {
		super.init(frame: frame)
		wantsLayer = true
		layer?.backgroundColor = Theme.background.cgColor

		heading.font = Theme.heading
		heading.textColor = Theme.faintText
		heading.isHidden = true   // the box carries the title

		panel.onOpenSettings = { NSWorkspace.shared.open(Consent.settings) }
		panel.onRecord = { [weak self] recording in self?.begin(recording) }
		panel.onStop = { [weak self] in self?.end() }

		let box = PaneBox("Record a screencast", content: panel)
		let stack = NSStackView(views: [box])
		stack.orientation = .vertical
		stack.alignment = .leading
		stack.spacing = 10
		stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
		stack.translatesAutoresizingMaskIntoConstraints = false
		addSubview(stack)
		NSLayoutConstraint.activate([
			stack.topAnchor.constraint(equalTo: topAnchor),
			stack.leadingAnchor.constraint(equalTo: leadingAnchor),
			stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
			stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
		])
	}

	@available(*, unavailable) required init?(coder: NSCoder) { nil }

	/// Asked when the page comes up rather than when the button is pressed.
	///
	/// Both of the things that can be missing are cheap to look for, and knowing
	/// before somebody has typed a URL is the whole difference between a panel
	/// that explains and one that refuses.
	public func appeared() {
		guard project != nil else { return }
		Task { @MainActor in
			let consent = await ConsentCheck.ask()
			guard consent.canRecord else {
				panel.show(.needsConsent(consent))
				return
			}
			if Sitters.find(for: panel.recording) == nil {
				panel.show(.nothing(Sitters.missing(for: panel.recording)))
			} else {
				panel.show(.ready)
			}
		}
	}

	private func showWhereItStands() {
		guard project == nil else { return }
		// A recording lands *beside* the project file and its profile lives in
		// the project's folder. A project that is nowhere has nowhere to put
		// either, and that is a thing to say rather than a button to grey.
		panel.show(.nothing("Save the project first — a recording lands beside it, "
			+ "and a project that has not been saved has nowhere to put one."))
	}

	// MARK: - Doing it

	private func begin(_ recording: Recording) {
		guard let project else { showWhereItStands(); return }
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
				switch trouble {
				case .noConsent(let consent): panel.show(.needsConsent(consent))
				case .nothingToDrive(let said): panel.show(.nothing(said))
				default: panel.show(.refused(trouble.described))
				}
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
			onRecorded?(made)
		}
	}

	/// Leaving the page stops the recording and closes what cuttr opened. A
	/// browser left running with cuttr's profile in it is a window nobody owns.
	public func left() {
		clock?.invalidate()
		clock = nil
		guard screencast != nil else { return }
		Task { @MainActor in _ = await screencast?.stop() }
	}

	// MARK: - For the tests

	var panelForTesting: RecordingPanel { panel }
}
