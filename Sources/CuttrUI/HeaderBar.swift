import AppKit
import CuttrKit

/// The strip above the picture: what is loaded, where the playhead is, and the
/// alignment between the two recordings.
///
/// The alignment controls are here rather than in a sheet or an inspector
/// because aligning is not a step somebody does once. It is checked against the
/// waveform, nudged, listened to, nudged again — and every one of those is a
/// look at the timeline. A control that hides the thing it adjusts cannot be
/// used for this.
@MainActor
public final class HeaderBar: NSView {

	public var onChooseVideo: (() -> Void)?
	public var onChooseAudio: (() -> Void)?
	public var onOffsetTyped: ((Double) -> Void)?
	public var onNudge: ((Double) -> Void)?
	public var onAlign: (() -> Void)?
	public var onMonitorChange: ((Transport.Monitor) -> Void)?
	/// A swatch was clicked: colour the selected clip, and use this colour for
	/// the next one.
	public var onColorChange: ((ClipColor) -> Void)?

	private let videoButton = NSButton()
	private let audioButton = NSButton()
	private let timeLabel = NSTextField(labelWithString: "00:00.000")
	private let offsetField = NSTextField()
	private let alignButton = NSButton()
	private let monitor = NSSegmentedControl()
	private let statusLabel = NSTextField(labelWithString: "")
	private let progress = NSProgressIndicator()
	private var swatches: [NSButton] = []

	public override init(frame: NSRect) {
		super.init(frame: frame)
		wantsLayer = true
		layer?.backgroundColor = Theme.panel.cgColor

		// The playhead, big and monospaced. It is read while the tape is
		// rolling, and proportional digits shift under the eye at every frame.
		timeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 17, weight: .medium)
		timeLabel.textColor = Theme.text

		configure(videoButton, title: "Video…", action: #selector(chooseVideo))
		configure(audioButton, title: "Audio…", action: #selector(chooseAudio))

		offsetField.font = Theme.mono
		offsetField.alignment = .right
		offsetField.placeholderString = "+00:00.000"
		offsetField.target = self
		offsetField.action = #selector(offsetCommitted)
		offsetField.toolTip = "Seconds to add to the audio file's clock to reach the video's.\n"
			+ "[ and ] nudge by 1 ms, ⇧ by 10 ms, ⌥ by 100 ms.\n"
			+ "⌥-drag the audio waveform to slide it."

		configure(alignButton, title: "Align", action: #selector(align))
		alignButton.toolTip = "Find the offset by correlating the two recordings (A)"

		monitor.segmentCount = Transport.Monitor.allCases.count
		for (index, mode) in Transport.Monitor.allCases.enumerated() {
			monitor.setLabel(mode.title, forSegment: index)
			monitor.setWidth(72, forSegment: index)
		}
		monitor.selectedSegment = 0
		monitor.target = self
		monitor.action = #selector(monitorChanged)
		monitor.toolTip = "Which microphone you hear. “Both” is the alignment tool:\n"
			+ "nudge until the hollow, flanging sound goes away."

		statusLabel.font = Theme.monoSmall
		statusLabel.textColor = Theme.dimText
		statusLabel.lineBreakMode = .byTruncatingTail

		progress.style = .bar
		progress.isIndeterminate = false
		progress.minValue = 0
		progress.maxValue = 1
		progress.controlSize = .small
		// Hidden until there is something to report, and detached from the
		// stack while hidden so it leaves no gap.
		progress.isHidden = true

		let offsetLabel = NSTextField(labelWithString: "offset")
		offsetLabel.font = Theme.monoSmall
		offsetLabel.textColor = Theme.dimText

		// The swatches.
		//
		// In the toolbar rather than only in a menu, because the colour is
		// chosen *before* the cut as often as after it: somebody working through
		// alternate takes picks rose, marks four of them, picks green, marks the
		// keepers. A colour that could only be applied afterwards would make
		// that two passes.
		for color in ClipColor.allCases {
			let button = NSButton(frame: .zero)
			button.title = ""
			button.isBordered = false
			button.wantsLayer = true
			button.layer?.backgroundColor = Theme.base(color).cgColor
			button.layer?.cornerRadius = 4
			button.layer?.borderColor = NSColor.white.cgColor
			button.toolTip = "\(color.title) — colours the selected clip, and the next one you cut"
			button.target = self
			button.action = #selector(swatchClicked(_:))
			button.tag = ClipColor.allCases.firstIndex(of: color) ?? 0
			button.translatesAutoresizingMaskIntoConstraints = false
			button.widthAnchor.constraint(equalToConstant: 16).isActive = true
			button.heightAnchor.constraint(equalToConstant: 16).isActive = true
			swatches.append(button)
		}
		let colorStack = NSStackView(views: swatches)
		colorStack.orientation = .horizontal
		colorStack.spacing = 4

		let stack = NSStackView(views: [
			timeLabel, spacer(8), videoButton, audioButton, spacer(12),
			offsetLabel, offsetField, alignButton, spacer(8), monitor,
			spacer(10), colorStack, spacer(8), progress, statusLabel,
		])
		stack.orientation = .horizontal
		stack.spacing = 6
		stack.alignment = .centerY
		stack.translatesAutoresizingMaskIntoConstraints = false
		addSubview(stack)
		NSLayoutConstraint.activate([
			stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
			stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
			stack.centerYAnchor.constraint(equalTo: centerYAnchor),
			offsetField.widthAnchor.constraint(equalToConstant: 92),
			progress.widthAnchor.constraint(equalToConstant: 110),
		])
		statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
	}

	@available(*, unavailable) required init?(coder: NSCoder) { nil }

	private func configure(_ button: NSButton, title: String, action: Selector) {
		button.title = title
		button.bezelStyle = .rounded
		button.controlSize = .small
		button.font = NSFont.systemFont(ofSize: 11)
		button.target = self
		button.action = action
	}

	private func spacer(_ width: CGFloat) -> NSView {
		let view = NSView()
		view.translatesAutoresizingMaskIntoConstraints = false
		view.widthAnchor.constraint(equalToConstant: width).isActive = true
		return view
	}

	// MARK: - State in

	/// Which swatch is ringed. The current colour, which is the selected clip's
	/// when there is one and the pending choice when there is not.
	public func setColor(_ color: ClipColor) {
		for (index, button) in swatches.enumerated() {
			let isCurrent = ClipColor.allCases[index] == color
			button.layer?.borderWidth = isCurrent ? 2 : 0
		}
	}

	public func update(document: TakeDocument, playhead: Double, monitorMode: Transport.Monitor) {
		timeLabel.stringValue = Timecode.string(playhead)
		videoButton.title = document.videoURL?.lastPathComponent ?? "Video…"
		audioButton.title = document.audioURL?.lastPathComponent ?? "Audio…"

		let hasAudio = document.take.audio != nil
		offsetField.isEnabled = hasAudio
		alignButton.isEnabled = hasAudio && document.audioWaveform != nil && document.videoWaveform != nil
		monitor.isEnabled = hasAudio
		monitor.selectedSegment = monitorMode.rawValue
		// Not while it is being typed into: rewriting the field under the
		// cursor is how a text field eats a keystroke.
		if window?.firstResponder !== offsetField.currentEditor() {
			offsetField.stringValue = hasAudio ? Timecode.offsetString(document.take.audio?.offset ?? 0) : ""
		}
	}

	public func setStatus(_ text: String) { statusLabel.stringValue = text }

	/// `nil` puts the bar away.
	public func setProgress(_ fraction: Double?) {
		progress.isHidden = fraction == nil
		if let fraction { progress.doubleValue = fraction }
	}

	// MARK: - Actions

	@objc private func chooseVideo() { onChooseVideo?() }
	@objc private func chooseAudio() { onChooseAudio?() }
	@objc private func align() { onAlign?() }

	@objc private func offsetCommitted() {
		guard let value = Timecode.parse(offsetField.stringValue) else { return }
		onOffsetTyped?(value)
	}

	@objc private func swatchClicked(_ sender: NSButton) {
		guard sender.tag < ClipColor.allCases.count else { return }
		onColorChange?(ClipColor.allCases[sender.tag])
	}

	@objc private func monitorChanged() {
		guard let mode = Transport.Monitor(rawValue: monitor.selectedSegment) else { return }
		onMonitorChange?(mode)
	}
}
