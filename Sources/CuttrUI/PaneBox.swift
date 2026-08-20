import AppKit

/// One of the rail's panes: a heading, whatever the heading says about it, and
/// the thing itself filling the rest.
///
/// The heading is not a control. It was — the four panes down the cutting
/// window's side each folded when their heading was clicked, which is how one of
/// them was given the room. The rail does that now, and a heading that also
/// folds would be a second way to do the same thing with a different result:
/// fold the only open pane and the column is empty.
///
/// What the heading is for is the *accessory*: the word count and the language
/// on the words, the grade in one line on the look, the six lane colours on the
/// clips. Each of those is a fact about the pane that is worth having without
/// reading the pane, and the heading is where it goes.
@MainActor
public final class PaneBox: NSView {

	public let content: NSView
	public static let headHeight: CGFloat = 24

	private let label = NSTextField(labelWithString: "")
	private let head = NSView()

	public init(_ title: String, content: NSView, accessory: NSView? = nil) {
		self.content = content
		// A real frame, and the mask off as well.
		//
		// Both, because they answer different halves of the same thing. The mask
		// off means *this* view never states a required size from its frame; a
		// real frame means everything inside it is first laid out against a
		// rectangle it can arrange, which matters here more than anywhere else
		// in the program — a pane is put into the window when the rail is
		// clicked, so it has a first layout every time somebody switches, not
		// only once at the start.
		super.init(frame: .roomToLayOutIn)
		translatesAutoresizingMaskIntoConstraints = false
		wantsLayer = true
		layer?.backgroundColor = Theme.panel.cgColor

		label.stringValue = title.uppercased()
		label.font = Theme.heading
		label.textColor = Theme.faintText

		// The pane's own colour, not the rail's.
		//
		// It was `background`, which is exactly what the rail is drawn in — so a
		// heading strip across the top of the content read as the rail turning a
		// corner and running along the top of the window. There are two areas
		// here and they get two colours: the rail is `background`, everything it
		// opens is `panel`. A heading is part of what it heads, and a hairline
		// under it is all the separation it needs.
		head.wantsLayer = true
		head.layer?.backgroundColor = Theme.panel.cgColor

		let rule = NSBox()
		rule.boxType = .custom
		rule.borderWidth = 0
		rule.fillColor = Theme.rule.withAlphaComponent(0.6)
		rule.translatesAutoresizingMaskIntoConstraints = false
		head.addSubview(rule)
		NSLayoutConstraint.activate([
			rule.leadingAnchor.constraint(equalTo: head.leadingAnchor),
			rule.trailingAnchor.constraint(equalTo: head.trailingAnchor),
			rule.bottomAnchor.constraint(equalTo: head.bottomAnchor),
			rule.heightAnchor.constraint(equalToConstant: 1),
		])

		label.translatesAutoresizingMaskIntoConstraints = false
		head.addSubview(label)
		NSLayoutConstraint.activate([
			label.leadingAnchor.constraint(equalTo: head.leadingAnchor, constant: 10),
			label.centerYAnchor.constraint(equalTo: head.centerYAnchor),
		])
		if let accessory {
			accessory.translatesAutoresizingMaskIntoConstraints = false
			head.addSubview(accessory)
			NSLayoutConstraint.activate([
				accessory.trailingAnchor.constraint(equalTo: head.trailingAnchor, constant: -8),
				accessory.centerYAnchor.constraint(equalTo: head.centerYAnchor),
				// It may not cross the title. Pinned only by its trailing edge,
				// an accessory that says more than it used to grows leftwards and
				// prints itself over the heading.
				accessory.leadingAnchor.constraint(
					greaterThanOrEqualTo: label.trailingAnchor, constant: 8),
			])
		}

		for view in [head, content] as [NSView] {
			view.translatesAutoresizingMaskIntoConstraints = false
			addSubview(view)
		}
		NSLayoutConstraint.activate([
			head.topAnchor.constraint(equalTo: topAnchor),
			head.leadingAnchor.constraint(equalTo: leadingAnchor),
			head.trailingAnchor.constraint(equalTo: trailingAnchor),
			// A floor, not a law — see `asFloor`. A split view decides how tall
			// this pane is, and a required heading height against a column that
			// has not been given one yet leaves the content a negative height to
			// find.
			head.heightAnchor.constraint(equalToConstant: Self.headHeight).asFloor,

			content.topAnchor.constraint(equalTo: head.bottomAnchor),
			content.leadingAnchor.constraint(equalTo: leadingAnchor),
			content.trailingAnchor.constraint(equalTo: trailingAnchor),
			content.bottomAnchor.constraint(equalTo: bottomAnchor),
		])
	}

	@available(*, unavailable) required init?(coder: NSCoder) { nil }
}

/// The place a rail's panes appear, one at a time.
///
/// Exactly one pane is in the view hierarchy, so exactly one thing has an
/// opinion about the height of what is in this column — which is the rule the
/// four-pane version kept breaking. A pane that is not showing is not laid out,
/// not measured and not negotiated with.
@MainActor
public final class PaneStack: NSView {

	private var panes: [NSView] = []
	private var showing: NSView?
	private var edges: [NSLayoutConstraint] = []

	public init(_ panes: [NSView]) {
		self.panes = panes
		super.init(frame: .roomToLayOutIn)
		translatesAutoresizingMaskIntoConstraints = false
		wantsLayer = true
		layer?.backgroundColor = Theme.panel.cgColor
		show(0)
	}

	@available(*, unavailable) required init?(coder: NSCoder) { nil }

	public func show(_ index: Int) {
		guard index >= 0, index < panes.count else { return }
		let wanted = panes[index]
		guard wanted !== showing else { return }
		NSLayoutConstraint.deactivate(edges)
		edges = []
		showing?.removeFromSuperview()
		showing = wanted
		wanted.translatesAutoresizingMaskIntoConstraints = false
		// Into the room this stack already has, rather than into whatever frame
		// the pane was left with when it was taken out. A pane inserted at a
		// degenerate size lays its table out against a rectangle it cannot
		// arrange, once, before the constraints below have said anything.
		if !bounds.isEmpty { wanted.frame = bounds }
		addSubview(wanted)
		edges = [
			wanted.topAnchor.constraint(equalTo: topAnchor),
			wanted.bottomAnchor.constraint(equalTo: bottomAnchor),
			wanted.leadingAnchor.constraint(equalTo: leadingAnchor),
			wanted.trailingAnchor.constraint(equalTo: trailingAnchor),
		]
		NSLayoutConstraint.activate(edges)
	}

	/// Which pane is up, for the tests and for anything that needs to know.
	public var current: NSView? { showing }
}
