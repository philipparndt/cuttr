import AppKit
import CuttrCompose

/// A bigger picture to place an overlay in.
///
/// The placement picture in the properties panel is about two hundred points
/// across, which is enough to see that a bubble is beside a face and nowhere
/// near enough to put the tail of it on a mouth. One point of that picture is
/// worth six or seven of the frame, so the tail lands where the hand could
/// reach rather than where it was aimed — and the smaller the pane is dragged,
/// the coarser the placing gets.
///
/// So the same picture again, at the size of most of the window, hovering over
/// it. The arrangement a look already uses — see ``QuickLookPanel`` — and for
/// the same reason: what is being asked is about the thing that is selected, so
/// the answer belongs where the selection is rather than in another mode of the
/// window that has to be travelled to and come back from.
///
/// **The same view, not a second one.** What hovers is a ``FramePreview``
/// holding the same content, and a drag in it goes out through the little
/// picture's own callbacks. Every number is a fraction of the frame and the
/// picture letterboxes inside whatever it is given, so a drag two thirds of the
/// way across writes the same `offset:` in either — which is the whole claim,
/// and it is measured in `BubbleDragTests`. A panel that placed by its own
/// arithmetic would be a second answer to a question the renderer has already
/// answered.
public enum Placing {

	/// How much room is left round the picture inside the window.
	private static let margin: CGFloat = 24

	/// How big the picture is: most of the window, within reason.
	///
	/// Big rather than moderate. A look is a glance and is deliberately kept to
	/// a third of the window; this is a place to work, and the point of opening
	/// it is that the little one was too coarse to hit anything with. The panel
	/// is resizable, so this is only where it starts.
	///
	/// The size is the **view's**, not the picture's: a ``FramePreview`` keeps a
	/// strip under the picture for what a drag writes and a margin round it, and
	/// a panel sized to the frame's own shape would letterbox the frame inside
	/// itself and waste both.
	public static func size(for output: NSSize, in window: NSRect) -> NSSize {
		let ratio = output.width > 0 && output.height > 0
			? output.height / output.width : 9.0 / 16
		let room = NSSize(width: max(320, window.width - margin * 2),
		                  height: max(240, window.height - margin * 2))
		var width = min(max(560, window.width * 0.66), 1280)
		width = min(width, room.width - FramePreview.frameInset.width)
		var height = width * ratio
		if height > room.height - FramePreview.frameInset.height {
			height = room.height - FramePreview.frameInset.height
			width = ratio > 0 ? height / ratio : width
		}
		return NSSize(width: (width + FramePreview.frameInset.width).rounded(),
		              height: (height + FramePreview.frameInset.height).rounded())
	}

	/// Where it opens: the middle of the window it came from, inside it.
	///
	/// The middle rather than clear of the column it came out of, which is what
	/// ``QuickLook/place(_:beside:row:inside:)`` does for a look. A look must not
	/// cover the row it is about, because the row is what somebody is reading. A
	/// placing picture *is* what somebody is looking at, and the two hundred
	/// point one it came from is a thing they have deliberately stopped using.
	/// It is a panel with a title bar, so it can be dragged off the middle by
	/// anybody who disagrees.
	public static func place(_ size: NSSize, inside window: NSRect) -> NSRect {
		let x = min(max(window.minX + margin, window.midX - size.width / 2),
		            max(window.minX + margin, window.maxX - margin - size.width))
		let y = min(max(window.minY + margin, window.midY - size.height / 2),
		            max(window.minY + margin, window.maxY - margin - size.height))
		return NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
	}
}

/// The window the bigger picture happens in.
///
/// A titled, closable, resizable utility panel, which is the plainest thing
/// AppKit has that can be dragged somewhere else and made bigger still. A child
/// window of the one it came from, so it travels with that window, closes with
/// it, and needs nothing from the layout it covers.
///
/// It takes the mouse, unlike a look, because taking the mouse is the entire
/// point of it. It does not take the keyboard unless it is asked for: nothing on
/// it is typed into, and the panel it was opened from should still answer the
/// keys it answered before.
@MainActor
public final class PlacingPanel: NSPanel {

	/// The picture. One of them, kept across every re-aiming, so what a drag put
	/// down survives the reload that drag causes — see ``FramePreview``.
	private let preview = FramePreview()

	public init() {
		super.init(contentRect: NSRect(x: 0, y: 0, width: 720, height: 435),
		           styleMask: [.titled, .closable, .resizable, .utilityWindow,
		                       .nonactivatingPanel],
		           backing: .buffered, defer: false)
		isFloatingPanel = true
		becomesKeyOnlyIfNeeded = true
		// Put away when the app goes to the back, like every other panel that
		// hovers: it is furniture over one window, not a document of its own.
		hidesOnDeactivate = true
		// Or the second opening talks to a deallocated window.
		isReleasedWhenClosed = false
		contentMinSize = NSSize(width: 360, height: 240)
		titlebarAppearsTransparent = false

		let root = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 435))
		root.wantsLayer = true
		root.layer?.backgroundColor = Theme.card.cgColor
		preview.translatesAutoresizingMaskIntoConstraints = false
		// The panel decides the size; the picture fills it. Its own idea of how
		// tall it should be is about a row in a form and has no business here.
		preview.setContentHuggingPriority(.defaultLow, for: .vertical)
		preview.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
		root.addSubview(preview)
		NSLayoutConstraint.activate([
			preview.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
			preview.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
			preview.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
			preview.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),
		])
		contentView = root
	}

	public var isShowing: Bool { isVisible }

	/// For the tests: the picture, so a drag in the big one can be measured
	/// against the same drag in the little one.
	var previewForTesting: FramePreview { preview }

	/// Shows the same overlay the little picture is showing, and puts the panel
	/// over the window.
	///
	/// Called again while it is open to re-aim it, which is what happens after
	/// every edit: the properties panel is rebuilt, hands its own picture the
	/// overlay again, and passes it through here so both are showing one thing.
	/// Re-aiming leaves the frame alone — a panel that jumped back to the middle
	/// of the window whenever a bubble was nudged would be unusable.
	public func show(like little: FramePreview, titled name: String,
	                 over parent: NSWindow, output: NSSize) {
		title = name
		aim(at: little)
		guard !isVisible else { return }
		setFrame(Placing.place(Placing.size(for: output, in: parent.frame),
		                       inside: parent.frame), display: true)
		if parent.childWindows?.contains(self) != true {
			parent.addChildWindow(self, ordered: .above)
		}
		orderFront(nil)
	}

	/// Everything the little picture is showing, and a way out for what is
	/// dragged here.
	///
	/// The drag leaves through the little picture's own callbacks rather than
	/// through callbacks of its own. There is one door into the file for a
	/// placement and this is not a second one: the panel is a bigger picture,
	/// not a bigger editor.
	private func aim(at little: FramePreview) {
		preview.aspect = little.aspect
		// The frame the little one already has. Fetched at the render's own size
		// and drawn into whatever rectangle it is given, so blowing it up costs
		// nothing — and asking for it again would leave this panel black for as
		// long as the generator took.
		preview.poster = little.poster
		preview.anchorPoint = little.anchorPoint
		preview.anchorName = little.anchorName
		preview.moment = little.moment
		preview.spot = little.spot
		preview.explanation = little.explanation
		preview.content = little.content
		preview.onOffset = { [weak little] in little?.onOffset?($0) }
		preview.onTail = { [weak little] in little?.onTail?($0) }
		preview.onMove = { [weak little] in little?.onMove?($0) }
	}

	/// Escape puts it away, which is what escape means everywhere else in this
	/// program. Overridden rather than answered in `keyDown`: an unhandled key
	/// press reaches `NSResponder` and beeps.
	public override func cancelOperation(_ sender: Any?) { close() }

	public override func close() {
		parent?.removeChildWindow(self)
		super.close()
	}
}
