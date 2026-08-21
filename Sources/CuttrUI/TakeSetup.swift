import AppKit
import CuttrKit

/// What a take is made of, and how the two recordings line up.
///
/// Behind the take's name in the bar rather than in it. These are the controls
/// somebody uses at the start of a session and then leaves alone: pick the
/// video, pick the separate recording, press `Align`, look at the waveforms,
/// nudge. Four things done once, taking a third of the width of a strip that is
/// on screen for the rest of the day.
///
/// The nudging is not done from here — `[` and `]` do that, against the
/// waveform, and the offset written here is the same number they move. That is
/// the answer to the old worry about hiding these: what a correction needs to
/// see is the *timeline*, and the timeline is still there behind the popover.
@MainActor
public final class TakeSetup: NSView {

	public var onChooseVideo: (() -> Void)?
	public var onChooseAudio: (() -> Void)?
	public var onOffsetTyped: ((Double) -> Void)?
	public var onAlign: (() -> Void)?
	/// How loud this whole recording should be, in decibels, as typed.
	public var onGainTyped: ((Double) -> Void)?

	private let videoButton = NSButton()
	private let audioButton = NSButton()
	private let offsetField = NSTextField()
	private let alignButton = NSButton()
	private let gainField = NSTextField()

	public override init(frame: NSRect) {
		super.init(frame: frame)

		configure(videoButton, title: "Video…", action: #selector(chooseVideo))
		configure(audioButton, title: "Audio…", action: #selector(chooseAudio))
		configure(alignButton, title: "Align", action: #selector(align))
		alignButton.toolTip = "Find the offset by correlating the two recordings (A)"

		offsetField.font = Theme.mono
		offsetField.alignment = .right
		offsetField.placeholderString = "+00:00.000"
		offsetField.target = self
		offsetField.action = #selector(offsetCommitted)
		offsetField.toolTip = "Seconds to add to the audio file's clock to reach the video's.\n"
			+ "[ and ] nudge by 1 ms, ⇧ by 10 ms, ⌥ by 100 ms.\n"
			+ "⌥-drag the audio waveform to slide it."

		gainField.font = Theme.mono
		gainField.alignment = .right
		gainField.placeholderString = "0"
		gainField.target = self
		gainField.action = #selector(gainCommitted)
		gainField.toolTip = "Decibels to add to this whole recording, for balancing it"
			+ " against the others.\nA clip's own Level is added to it; blank is nought."

		let rows = NSStackView(views: [
			row("video", videoButton),
			row("audio", audioButton),
			row("offset", offsetField, alignButton),
			row("level", gainField),
		])
		rows.orientation = .vertical
		rows.alignment = .leading
		rows.spacing = 8
		rows.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
		rows.translatesAutoresizingMaskIntoConstraints = false
		addSubview(rows)
		NSLayoutConstraint.activate([
			rows.topAnchor.constraint(equalTo: topAnchor),
			rows.bottomAnchor.constraint(equalTo: bottomAnchor),
			rows.leadingAnchor.constraint(equalTo: leadingAnchor),
			rows.trailingAnchor.constraint(equalTo: trailingAnchor),
			offsetField.widthAnchor.constraint(equalToConstant: 92),
			gainField.widthAnchor.constraint(equalToConstant: 92),
			videoButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
			audioButton.widthAnchor.constraint(equalTo: videoButton.widthAnchor),
		])
	}

	@available(*, unavailable) required init?(coder: NSCoder) { nil }

	private func row(_ key: String, _ controls: NSView...) -> NSStackView {
		let label = NSTextField(labelWithString: key)
		label.font = Theme.monoSmall
		label.textColor = Theme.dimText
		label.alignment = .right
		label.translatesAutoresizingMaskIntoConstraints = false
		label.widthAnchor.constraint(equalToConstant: 44).isActive = true

		let stack = NSStackView(views: [label] + controls)
		stack.orientation = .horizontal
		stack.spacing = 8
		stack.alignment = .centerY
		return stack
	}

	private func configure(_ button: NSButton, title: String, action: Selector) {
		button.title = title
		button.bezelStyle = .rounded
		button.controlSize = .small
		button.font = NSFont.systemFont(ofSize: 11)
		button.target = self
		button.action = action
	}

	// MARK: - State in

	public func update(document: TakeDocument) {
		videoButton.title = document.videoURL?.lastPathComponent ?? "Video…"
		audioButton.title = document.audioURL?.lastPathComponent ?? "Audio…"

		let hasAudio = document.take.audio != nil
		offsetField.isEnabled = hasAudio
		alignButton.isEnabled = hasAudio && document.audioWaveform != nil
			&& document.videoWaveform != nil
		// Not while it is being typed into: rewriting the field under the cursor
		// is how a text field eats a keystroke.
		if window?.firstResponder !== offsetField.currentEditor() {
			offsetField.stringValue = hasAudio
				? Timecode.offsetString(document.take.audio?.offset ?? 0) : ""
		}
		// Blank at nought rather than a zero that reads as a decision.
		if window?.firstResponder !== gainField.currentEditor() {
			gainField.stringValue = document.take.gain == 0
				? "" : TakeWriter.number(document.take.gain, places: 2)
		}
	}

	// MARK: - Actions

	@objc private func chooseVideo() { onChooseVideo?() }
	@objc private func chooseAudio() { onChooseAudio?() }
	@objc private func align() { onAlign?() }

	@objc private func offsetCommitted() {
		guard let value = Timecode.parse(offsetField.stringValue) else { return }
		onOffsetTyped?(value)
	}

	@objc private func gainCommitted() {
		let typed = gainField.stringValue.trimmingCharacters(in: .whitespaces)
		// Blank is nought, which is how a level is taken back off. Anything that
		// is not a number is refused rather than read as nought.
		if typed.isEmpty { onGainTyped?(0); return }
		guard let value = Double(typed) else { return }
		onGainTyped?((value * 100).rounded() / 100)
	}
}
