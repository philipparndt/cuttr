import AppKit

/// The field at the head of the bar: which project on the left, which branch on
/// the right, and the shortcut that turns the whole thing into a search.
///
/// One control rather than two, because the two questions it answers — where am
/// I, and where do I want to go — are the same question at different moments. It
/// stays two hit targets: the halves light separately and open their own lists,
/// so pointing at the project and pointing at the take are still two different
/// acts.
///
/// The pair is a project and the git branch checked out in the folder it sits
/// in. The takes belong on the left, indented under the project they are made
/// from, because a take is *part of* a project — where a branch is a state of
/// the folder, and a different kind of fact.
///
/// The right half is often absent, and that is the ordinary case rather than an
/// error: footage lives on a volume that is not a work tree. With no branch
/// there is nothing on the right to point at and the whole capsule belongs to
/// the project.
@MainActor
public final class DocumentCapsule: NSView {

	public enum Half { case project, branch }

	/// Asked to show the list of projects, or of takes.
	public var onHalf: ((Half) -> Void)?

	/// Which half the list about to open belongs to, so the right one is lit.
	public var openHalf: Half? {
		didSet { needsDisplay = true }
	}

	private var project = ""
	private var branch: String?
	private var hovered: Half?
	private var pressed: Half?
	private var tracking: NSTrackingArea?

	// MARK: - Metrics

	private static let padding: CGFloat = 11
	private static let gap: CGFloat = 7
	private static let chevron: CGFloat = 9
	private static let minimumWidth: CGFloat = 300
	/// A hairline of air inside the frame, so the shape does not touch whatever
	/// the bar puts beside it.
	private static let inset: CGFloat = 1
	public static let height: CGFloat = 30

	private static var nameFont: NSFont { NSFont.systemFont(ofSize: 13, weight: .semibold) }
	private static var branchFont: NSFont { NSFont.systemFont(ofSize: 13, weight: .medium) }
	private static var hintFont: NSFont { NSFont.systemFont(ofSize: 10.5, weight: .medium) }

	/// The same key the menu bar uses, because the hint is only worth printing
	/// if it is true.
	public static let hint = "⇧⌘P"

	public override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)
		wantsLayer = true
		translatesAutoresizingMaskIntoConstraints = false
		heightAnchor.constraint(equalToConstant: Self.height).isActive = true
	}

	@available(*, unavailable) required init?(coder: NSCoder) { nil }

	public override var isFlipped: Bool { true }

	// MARK: - What it says

	public func show(project: String, branch: String?) {
		self.project = project
		self.branch = branch
		invalidateIntrinsicContentSize()
		needsDisplay = true
	}

	/// Whether the right half has anything to say. A folder that is not a work
	/// tree has no branch, and the divider goes with it.
	public var hasBranch: Bool { branch != nil }

	// MARK: - Measuring

	private func width(of text: String, font: NSFont) -> CGFloat {
		ceil((text as NSString).size(withAttributes: [.font: font]).width)
	}

	private var branchWidth: CGFloat {
		let hint = width(of: Self.hint, font: Self.hintFont)
		guard let branch else { return Self.padding + hint + Self.padding }
		return Self.padding + width(of: branch, font: Self.branchFont)
			+ Self.gap + Self.chevron + Self.gap + hint + Self.padding
	}

	private var projectWidth: CGFloat {
		Self.padding + width(of: project, font: Self.nameFont)
			+ Self.gap + Self.chevron + Self.padding
	}

	public override var intrinsicContentSize: NSSize {
		NSSize(width: Self.inset * 2 + max(Self.minimumWidth, projectWidth + branchWidth),
		       height: Self.height)
	}

	private var shape: NSRect { bounds.insetBy(dx: Self.inset, dy: Self.inset) }
	private var divider: CGFloat { shape.maxX - branchWidth }

	/// The project half, for anchoring its list under it.
	public var projectRect: NSRect {
		NSRect(x: shape.minX, y: shape.minY, width: divider - shape.minX, height: shape.height)
	}

	public var branchRect: NSRect {
		NSRect(x: divider, y: shape.minY, width: shape.maxX - divider, height: shape.height)
	}

	private func half(at point: NSPoint) -> Half? {
		guard shape.contains(point) else { return nil }
		// With no branch there is nothing on the right to point at, so the whole
		// capsule belongs to the project.
		guard hasBranch else { return .project }
		return point.x < divider ? .project : .branch
	}

	// MARK: - Pointing

	public override func updateTrackingAreas() {
		super.updateTrackingAreas()
		if let tracking { removeTrackingArea(tracking) }
		// `.mouseMoved` as well as enter and exit: which half is being pointed
		// at changes without the pointer ever leaving the view.
		let area = NSTrackingArea(rect: bounds,
		                          options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp],
		                          owner: self)
		addTrackingArea(area)
		tracking = area
	}

	private func setHovered(_ half: Half?) {
		guard hovered != half else { return }
		hovered = half
		needsDisplay = true
	}

	public override func mouseEntered(with event: NSEvent) {
		setHovered(half(at: convert(event.locationInWindow, from: nil)))
	}

	public override func mouseMoved(with event: NSEvent) {
		setHovered(half(at: convert(event.locationInWindow, from: nil)))
	}

	public override func mouseExited(with event: NSEvent) { setHovered(nil) }

	public override func mouseDown(with event: NSEvent) {
		pressed = half(at: convert(event.locationInWindow, from: nil))
		needsDisplay = true
	}

	public override func mouseUp(with event: NSEvent) {
		let released = half(at: convert(event.locationInWindow, from: nil))
		let was = pressed
		pressed = nil
		needsDisplay = true
		// Only when it goes down and comes up on the same half, which is what
		// every other button on the system does.
		guard let released, released == was else { return }
		onHalf?(released)
	}

	// MARK: - Drawing

	public override func draw(_ dirtyRect: NSRect) {
		let path = NSBezierPath(roundedRect: shape, xRadius: 8, yRadius: 8)
		// A field sunk into the band rather than raised off it: the bar is the
		// chrome, and this is a place you can type into as much as look at.
		Theme.panel.setFill()
		path.fill()
		Theme.rule.setStroke()
		path.lineWidth = 1
		path.stroke()

		if let lit = openHalf ?? pressed ?? hovered {
			let strong = openHalf != nil || pressed != nil
			NSGraphicsContext.saveGraphicsState()
			path.setClip()
			NSColor.white.withAlphaComponent(strong ? 0.10 : 0.05).setFill()
			(lit == .project ? projectRect : branchRect).fill()
			NSGraphicsContext.restoreGraphicsState()
		}

		drawProject()
		if hasBranch { drawDivider() }
		drawBranch()
	}

	private func drawProject() {
		let text = NSAttributedString(string: project, attributes: [
			.font: Self.nameFont, .foregroundColor: Theme.text,
		])
		let size = text.size()
		let x = shape.minX + Self.padding
		text.draw(at: NSPoint(x: x, y: shape.midY - size.height / 2))
		// The chevron is drawn only for the half being pointed at: at rest the
		// capsule is two names and a hint.
		if hovered == .project || openHalf == .project {
			drawChevron(at: NSPoint(x: x + ceil(size.width) + Self.gap, y: shape.midY))
		}
	}

	private func drawDivider() {
		Theme.rule.setFill()
		NSRect(x: divider, y: shape.midY - 8, width: 1, height: 16).fill()
	}

	private func drawBranch() {
		let hint = NSAttributedString(string: Self.hint, attributes: [
			.font: Self.hintFont, .foregroundColor: Theme.faintText,
		])
		let hintSize = hint.size()
		hint.draw(at: NSPoint(x: shape.maxX - Self.padding - ceil(hintSize.width),
		                      y: shape.midY - hintSize.height / 2))

		guard let branch else { return }
		let text = NSAttributedString(string: branch, attributes: [
			.font: Self.branchFont, .foregroundColor: Theme.dimText,
		])
		let size = text.size()
		let x = divider + Self.padding
		text.draw(at: NSPoint(x: x, y: shape.midY - size.height / 2))
		if hovered == .branch || openHalf == .branch {
			drawChevron(at: NSPoint(x: x + ceil(size.width) + Self.gap, y: shape.midY))
		}
	}

	private func drawChevron(at point: NSPoint) {
		let path = NSBezierPath()
		path.move(to: NSPoint(x: point.x, y: point.y - 2))
		path.line(to: NSPoint(x: point.x + 3.5, y: point.y + 2))
		path.line(to: NSPoint(x: point.x + 7, y: point.y - 2))
		path.lineWidth = 1.3
		path.lineCapStyle = .round
		path.lineJoinStyle = .round
		Theme.dimText.setStroke()
		path.stroke()
	}

	/// For the tests: what each half is, and where.
	func halfForTesting(at point: NSPoint) -> Half? { half(at: point) }
	var projectForTesting: String { project }
	var branchForTesting: String? { branch }
}
