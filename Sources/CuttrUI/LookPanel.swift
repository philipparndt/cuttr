import AppKit
import CuttrKit

/// The take's own grade, decided by looking at it.
///
/// A look is five numbers, and every one of them is meaningless as a number:
/// nobody knows what `contrast: 1.14` is, they know whether the picture in
/// front of them is right. So the controls are sliders, they work while the
/// picture is playing, and the number beside each one is a read-out rather than
/// the way in.
///
/// It belongs to the take rather than to a project, which is the whole reason
/// it is in this window. A camera that runs warm runs warm in every programme
/// that ever draws on the footage; correcting it once here is correcting it
/// everywhere, and correcting it in one project is doing it again next time.
@MainActor
public final class LookPanel: NSView {

	/// Changed, and whether the change is finished.
	///
	/// A drag is sixty of these and one undo step. The panel says which is
	/// which; what to do about it is the document's business.
	public var onChange: ((Look, _ commit: Bool) -> Void)?

	/// One control: what it sets, over what range, and how it reads.
	private struct Dial {
		let name: String
		let range: ClosedRange<Double>
		let neutral: Double
		let places: Int
		let note: String
		let get: (Look) -> Double
		let set: (inout Look, Double) -> Void
	}

	/// Positive is warmer, positive is magenta — the same directions the file
	/// uses, said in the words beside the slider so nobody has to remember.
	private static let dials: [Dial] = [
		Dial(name: "exposure", range: -3 ... 3, neutral: 0, places: 2, note: "stops",
		     get: { $0.exposure }, set: { $0.exposure = $1 }),
		Dial(name: "temperature", range: -3000 ... 3000, neutral: 0, places: 0, note: "warmer +",
		     get: { $0.temperature }, set: { $0.temperature = $1 }),
		Dial(name: "tint", range: -100 ... 100, neutral: 0, places: 0, note: "magenta +",
		     get: { $0.tint }, set: { $0.tint = $1 }),
		Dial(name: "saturation", range: 0 ... 2, neutral: 1, places: 2, note: "1 is unchanged",
		     get: { $0.saturation }, set: { $0.saturation = $1 }),
		Dial(name: "contrast", range: 0.5 ... 1.5, neutral: 1, places: 2, note: "1 is unchanged",
		     get: { $0.contrast }, set: { $0.contrast = $1 }),
	]

	private var look = Look.none
	private var sliders: [NSSlider] = []
	private var readouts: [NSTextField] = []
	private let profileField = NSTextField()
	private let matchLabel = NSTextField(labelWithString: "")
	private let title = NSTextField(labelWithString: "LOOK")

	public override init(frame: NSRect) {
		super.init(frame: frame)
		wantsLayer = true
		layer?.backgroundColor = Theme.panel.cgColor
		build()
	}

	@available(*, unavailable) required init?(coder: NSCoder) { nil }

	/// What the take says now. Set from the document, so undo and a file opened
	/// from disk both land here.
	public func show(_ look: Look) {
		self.look = look
		for (index, dial) in Self.dials.enumerated() {
			sliders[index].doubleValue = dial.get(look)
			readouts[index].stringValue = TakeWriter.number(dial.get(look), places: dial.places)
			readouts[index].textColor = dial.get(look) == dial.neutral ? Theme.faintText : Theme.text
		}
		profileField.stringValue = look.profile ?? ""
		// The matched gain is not a control: it is what the analysis worked out,
		// and hand-editing it would be editing a measurement.
		if let gain = look.gain, gain.count == 3 {
			matchLabel.stringValue = "matched ×"
				+ gain.map { TakeWriter.number($0, places: 2) }.joined(separator: " ")
		} else {
			matchLabel.stringValue = ""
		}
	}

	// MARK: - Building it

	private func build() {
		title.font = Theme.heading
		title.textColor = Theme.faintText

		let reset = NSButton(title: "Reset", target: self, action: #selector(reset))
		reset.bezelStyle = .rounded
		reset.controlSize = .small
		reset.toolTip = "the footage as it was shot"

		matchLabel.font = Theme.monoSmall
		matchLabel.textColor = Theme.dimText

		let head = NSStackView(views: [title, matchLabel, NSView(), reset])
		head.orientation = .horizontal
		head.spacing = 8
		head.alignment = .centerY

		var rows: [NSView] = [head]
		for (index, dial) in Self.dials.enumerated() {
			let name = NSTextField(labelWithString: dial.name)
			name.font = Theme.mono
			name.textColor = Theme.text
			name.translatesAutoresizingMaskIntoConstraints = false
			name.widthAnchor.constraint(equalToConstant: 86).isActive = true

			let slider = NSSlider(value: dial.get(look), minValue: dial.range.lowerBound,
			                      maxValue: dial.range.upperBound,
			                      target: self, action: #selector(dragged(_:)))
			slider.tag = index
			slider.controlSize = .small
			// Live while it is dragged, and one more when it is let go — which
			// is what makes a drag one undo step instead of sixty.
			slider.isContinuous = true
			slider.setContentCompressionResistancePriority(
				NSLayoutConstraint.Priority(1), for: .horizontal)
			sliders.append(slider)

			let readout = NSTextField(labelWithString: TakeWriter.number(dial.get(look),
			                                                          places: dial.places))
			readout.font = Theme.mono
			readout.alignment = .right
			readout.textColor = Theme.faintText
			readout.translatesAutoresizingMaskIntoConstraints = false
			readout.widthAnchor.constraint(equalToConstant: 52).isActive = true
			readouts.append(readout)

			let note = NSTextField(labelWithString: dial.note)
			note.font = Theme.monoSmall
			note.textColor = Theme.faintText
			note.translatesAutoresizingMaskIntoConstraints = false
			note.widthAnchor.constraint(equalToConstant: 92).isActive = true

			let row = NSStackView(views: [name, slider, readout, note])
			row.orientation = .horizontal
			row.spacing = 8
			row.alignment = .centerY
			rows.append(row)
		}

		// The profile underneath everything, which is what `over` means: the
		// project's named look first, this take's numbers on top of it.
		let profileName = NSTextField(labelWithString: "profile")
		profileName.font = Theme.mono
		profileName.textColor = Theme.text
		profileName.translatesAutoresizingMaskIntoConstraints = false
		profileName.widthAnchor.constraint(equalToConstant: 86).isActive = true

		profileField.font = Theme.mono
		profileField.placeholderString = "a name from the project's profiles:"
		profileField.target = self
		profileField.action = #selector(profileTyped)
		profileField.setContentCompressionResistancePriority(
			NSLayoutConstraint.Priority(1), for: .horizontal)

		let profileRow = NSStackView(views: [profileName, profileField])
		profileRow.orientation = .horizontal
		profileRow.spacing = 8
		profileRow.alignment = .centerY
		rows.append(profileRow)

		let stack = NSStackView(views: rows)
		stack.orientation = .vertical
		stack.alignment = .leading
		stack.spacing = 6
		stack.translatesAutoresizingMaskIntoConstraints = false
		addSubview(stack)
		NSLayoutConstraint.activate([
			stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
			stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
			stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
			stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8),
		])
		for row in rows.dropFirst() {
			row.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
			row.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
		}
		head.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
		head.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
	}

	// MARK: - Changing it

	@objc private func dragged(_ sender: NSSlider) {
		guard sender.tag < Self.dials.count else { return }
		let dial = Self.dials[sender.tag]
		var next = look
		dial.set(&next, sender.doubleValue)
		look = next
		readouts[sender.tag].stringValue = TakeWriter.number(sender.doubleValue, places: dial.places)
		readouts[sender.tag].textColor = sender.doubleValue == dial.neutral
			? Theme.faintText : Theme.text
		// `NSSlider` says whether the mouse is still down, which is exactly the
		// question "is this drag finished".
		let finished = NSApp.currentEvent.map { $0.type != .leftMouseDragged } ?? true
		onChange?(next, finished)
	}

	@objc private func profileTyped() {
		let name = profileField.stringValue.trimmingCharacters(in: .whitespaces)
		var next = look
		next.profile = name.isEmpty ? nil : Slug.make(from: name)
		look = next
		onChange?(next, true)
	}

	@objc func reset() {
		// The measured match is kept: it is not a decision, it is what the
		// footage is, and throwing it away here would mean analysing again.
		var next = Look.none
		next.gain = look.gain
		show(next)
		onChange?(next, true)
	}

	/// For the tests: what the panel would write.
	var current: Look { look }
	func set(_ name: String, to value: Double) {
		guard let index = Self.dials.firstIndex(where: { $0.name == name }) else { return }
		sliders[index].doubleValue = value
		dragged(sliders[index])
	}
}
