@preconcurrency import AVFoundation
import AppKit
import CuttrCompose
import CuttrKit

/// A look at what is selected, taken without leaving the tree.
///
/// The composing window already has a place to watch the programme, and going
/// there is a journey: the tree goes away, the picture comes up, and coming back
/// means finding the row again. Most of the time the question is smaller than
/// that — *what is this one* — and the answer should arrive where the question
/// was asked. So space over the tree plays whatever is selected in a panel that
/// hovers beside the row, and putting it away leaves the window exactly as it
/// was.
///
/// This enum is the part with no window in it: what stretch of programme each
/// kind of row means, when the key is claimed, and where the panel goes. All of
/// it is answerable without a screen, which is why it is here rather than inside
/// the panel.
public enum QuickLook {

	/// One row of the tree, as far as a look is concerned.
	///
	/// A section carries its name *and* its path, because the name is what the
	/// right-click menu already previews by — see ``span(of:in:)``.
	public enum Row: Equatable {
		/// A clip or a card, at this path.
		case entry([Int])
		/// A section: the name it is written under, and where it sits.
		case section(String, path: [Int])
		case overlay(Origin)
		case sound(Origin)
	}

	/// A stretch of the programme's clock. The only clock there is — see the
	/// house rules — so a look at an overlay and a look at the clip under it are
	/// two spans of the same numbers.
	public struct Span: Equatable {
		public let start: Double
		public let end: Double
		public var duration: Double { end - start }

		public init(start: Double, end: Double) {
			self.start = start
			self.end = end
		}
	}

	/// Nothing shorter than this is a look.
	///
	/// A caption on for a tenth of a second is a real thing to select and a
	/// hopeless thing to watch: the player seeks, plays two frames and stops,
	/// which reads as a panel that failed to load. Short spans are given this
	/// much of the programme instead, taken forwards where there is programme
	/// left and backwards where there is not.
	public static let shortest: Double = 0.4

	// MARK: - What is selected

	/// What one row means, on the programme's clock.
	///
	/// - A clip is its span, and a card is its length: both are exactly what the
	///   resolver laid down for that entry, which is what ``Project/extent(of:in:)``
	///   records.
	/// - A section is its extent, and this asks for it *by name* rather than by
	///   path. Not because the name is better — a path tells two sections with
	///   one name apart and a name does not — but because the right-click menu
	///   already previews a section by name, and two ways of playing the same
	///   row that disagree about where it ends is worse than either of them.
	///   The path is the fallback, for a section whose name resolved to nothing.
	/// - An overlay or a sound is the stretch it is on for, which is its own
	///   business: one written inside a clip is that clip, one hung on two marks
	///   is whatever lies between them, and either may be shorter or longer than
	///   the entry the tree files it under. An overlay that is on more than once
	///   is its first appearance — a look is at one thing happening, and three
	///   appearances are three looks.
	public static func span(of row: Row, in resolved: ResolvedProject) -> Span? {
		switch row {
		case .entry(let path):
			return Project.extent(of: path, in: resolved).map { look(from: $0.start, to: $0.end, in: resolved) }
		case .section(let name, let path):
			if let group = resolved.groups.first(where: { $0.name == name }) {
				return look(from: group.start, to: group.end, in: resolved)
			}
			return span(of: .entry(path), in: resolved)
		case .overlay(let origin):
			guard let shown = resolved.overlays
				.filter({ $0.origin == origin })
				.min(by: { $0.start < $1.start })
			else { return nil }
			return look(from: shown.start, to: shown.end, in: resolved)
		case .sound(let origin):
			guard let played = resolved.sounds.first(where: { $0.origin == origin }) else { return nil }
			return look(from: played.start, to: played.end, in: resolved)
		}
	}

	/// Several rows: from the first of them to the last.
	///
	/// The tree selects in handfuls, and four shots selected are one run of
	/// programme — what somebody means by taking them together is "play this
	/// part". Rows scattered up and down the tree give the run between them,
	/// gaps and all, which is the honest reading of a selection that is not
	/// contiguous: there is no other single stretch that contains all of it.
	public static func span(of rows: [Row], in resolved: ResolvedProject) -> Span? {
		let spans = rows.compactMap { span(of: $0, in: resolved) }
		guard let start = spans.map(\.start).min(), let end = spans.map(\.end).max() else { return nil }
		return look(from: start, to: end, in: resolved)
	}

	/// A span, made long enough to watch and kept inside the programme.
	private static func look(from start: Double, to end: Double, in resolved: ResolvedProject) -> Span {
		let whole = resolved.duration
		guard end - start < shortest else { return Span(start: start, end: end) }
		let wanted = start + shortest
		guard wanted > whole, whole > shortest else { return Span(start: start, end: wanted) }
		// No programme left to play forwards, so it is taken off the front.
		return Span(start: max(0, whole - shortest), end: whole)
	}

	// MARK: - The key

	/// Whether this key press is a look being asked for.
	///
	/// Asked rather than assumed, because space is claimed in four places in
	/// this program already — the cutting window plays the selected clip with
	/// it, the transcript pane plays the selected words, the trim dialog plays
	/// the shot, and any text field on screen types a space — and a fifth
	/// claimant that fires whenever it can reach the key would break all four.
	/// This one fires in the tree, with something selected, and never while a
	/// name is being typed.
	///
	/// Bare space only: `⌥space` and `⇧space` are somebody asking for something
	/// else, and `⌘space` is not ours to answer at all.
	static func claims(_ event: NSEvent, editing: Bool, hasSpan: Bool) -> Bool {
		guard !editing, hasSpan else { return false }
		guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty else { return false }
		return event.keyCode == 49
	}

	/// Whether this key press puts an open look away. Escape, which is what it
	/// means everywhere else in the system; space again is the same key that
	/// opened it and is answered by ``claims(_:editing:hasSpan:)``.
	static func dismisses(_ event: NSEvent) -> Bool { event.keyCode == 53 }

	// MARK: - Where it goes

	/// Where the panel sits: beside the tree, level with the row, inside the
	/// window.
	///
	/// The rule is that it must not cover the thing somebody just selected, so
	/// it is placed clear of the whole column rather than clear of the row —
	/// a panel that dodges one row and lands on the next four is no better. To
	/// the right of the tree, because the tree is down the left edge of this
	/// window and the room is over there.
	///
	/// A window too narrow for that is the one case where it has to overlap the
	/// column, and then it goes above or below the row instead: away from the
	/// half of the tree the row is in, so the row itself stays visible.
	///
	/// How far the panel keeps off the edge of the window it hovers over.
	static let margin: CGFloat = 16
	/// Narrower than this and it is not a look at anything.
	static let narrowest: CGFloat = 260

	/// Everything is in one coordinate space — screen points, as windows are.
	static func place(_ size: NSSize, beside column: NSRect, row: NSRect, inside window: NSRect) -> NSRect {
		let gap: CGFloat = 12
		let margin = Self.margin
		var x = column.maxX + gap
		if x + size.width > window.maxX - margin {
			x = window.maxX - margin - size.width
		}
		x = max(window.minX + margin, x)

		var y = row.midY - size.height / 2
		if x < column.maxX {
			// Over the column: clear of the row the long way instead.
			y = row.midY < window.midY ? row.maxY + gap : row.minY - gap - size.height
		}
		y = min(max(window.minY + margin, y), window.maxY - margin - size.height)
		return NSRect(x: x, y: y, width: size.width, height: size.height)
	}

	/// How big the picture is: a third of the window across, within reason.
	///
	/// Big enough to see a face and read a caption, small enough that it is
	/// plainly a look and not the preview mode wearing a hat. The shape is the
	/// programme's own, so nothing is letterboxed inside a panel that is itself
	/// the wrong shape.
	///
	/// `chosen` is a width somebody dragged the panel to, and it wins over the
	/// automatic one — but it is clamped like any other, because the window it
	/// hovers over may since have been made smaller than the window the size was
	/// chosen in.
	static func size(for output: NSSize, in window: NSRect, chosen: CGFloat? = nil) -> NSSize {
		let ratio = output.width > 0 && output.height > 0 ? output.height / output.width : 9.0 / 16
		let automatic = min(max(360, window.width * 0.38), 560)
		var width = min(chosen ?? automatic, window.width - 2 * margin)
		// A tall programme in a short window: the height is what runs out
		// first, and a panel taller than the window it hovers over cannot be
		// placed clear of anything in it.
		let room = window.height - 2 * margin - QuickLookPanel.captionHeight
		if ratio > 0, width * ratio > room { width = room / ratio }
		width = max(narrowest, width)
		let height = (width * ratio).rounded()
		return NSSize(width: width.rounded(), height: height + QuickLookPanel.captionHeight)
	}

	/// Where a row of a list is, and where the pane holding it is, in screen
	/// points.
	///
	/// The two rectangles ``place(_:beside:row:inside:)`` wants, worked out the
	/// one way rather than at each of the two lists that take looks: a row and a
	/// column are the same question about a table as about an outline. The
	/// column is the *pane* rather than the list inside it — a panel placed
	/// clear of the list but over the search field above it is still in the way.
	static func frames(of row: NSRect, in list: NSView, column pane: NSView,
	                   window: NSWindow) -> (column: NSRect, row: NSRect) {
		(column: window.convertToScreen(pane.convert(pane.bounds, to: nil)),
		 row: window.convertToScreen(list.convert(row, to: nil)))
	}

	// MARK: - Moving it and sizing it

	/// What a press on the panel has hold of.
	///
	/// The panel is a look and not a window full of controls, so most of it is
	/// not anything to take hold of: the picture belongs to whatever is playing
	/// and a press on it means "enough", the same as a press beside it. What is
	/// left is the caption strip, which is where a title bar would be if this
	/// had one, and the corner of it.
	enum Grip: Equatable {
		/// The caption strip: dragged, it moves the panel.
		case bar
		/// The right-hand end of the strip: dragged, it resizes it.
		case corner
	}

	/// How much of the caption strip is the resize corner.
	static let gripWidth: CGFloat = 18

	/// What is under a point on the panel, in the panel's own coordinates.
	static func grip(at point: NSPoint, in bounds: NSRect) -> Grip? {
		let bar = NSRect(x: bounds.minX, y: bounds.minY,
		                 width: bounds.width, height: QuickLookPanel.captionHeight)
		guard bar.contains(point) else { return nil }
		let corner = NSRect(x: bar.maxX - gripWidth, y: bar.minY,
		                    width: gripWidth, height: bar.height)
		return corner.contains(point) ? .corner : .bar
	}

	/// The panel, dragged bigger or smaller by its corner.
	///
	/// One number decides it, because the picture keeps the programme's shape: a
	/// width is a height, and a corner drag that asked for two different things
	/// would have to ignore one of them. The number is whichever of the two the
	/// pointer moved further, so dragging right and dragging down both make it
	/// bigger — which is what a corner looks as though it should do.
	///
	/// The top left corner stays where it is. The panel is anchored beside the
	/// row it is about, and growing it must not walk that end of it away.
	///
	/// `drag` is in points from where the press landed, right and down positive.
	static func resized(_ frame: NSRect, by drag: NSSize, output: NSSize,
	                    inside window: NSRect) -> NSRect {
		let by = abs(drag.width) > abs(drag.height) ? drag.width : drag.height
		let size = size(for: output, in: window, chosen: frame.width + by)
		return NSRect(x: frame.minX, y: frame.maxY - size.height,
		              width: size.width, height: size.height)
	}

	/// Where the picture actually is inside the panel's picture area.
	///
	/// The player draws the video aspect-fitted, so a programme whose shape is
	/// not quite the panel's is letterboxed — and the overlays have to be over
	/// the *picture* rather than over the view, or a lower third sits in a
	/// different place on screen than it will in the file.
	static func picture(of output: NSSize, in bounds: NSRect) -> NSRect {
		guard output.width > 0, output.height > 0, bounds.width > 0, bounds.height > 0
		else { return bounds }
		let scale = min(bounds.width / output.width, bounds.height / output.height)
		let size = NSSize(width: output.width * scale, height: output.height * scale)
		return NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
		              width: size.width, height: size.height)
	}

	// MARK: - What is over the picture

	/// The overlay tree a look draws over its picture.
	///
	/// **A tree of its own, and not a second implementation.**
	/// ``CuttrCompose/OverlayLayers/build(_:size:host:)`` is the only place any
	/// of this is drawn — the preview over the window's player calls it, the
	/// export's `AVVideoCompositionCoreAnimationTool` calls it — and this is a
	/// third caller of the same function rather than a third way of drawing. It
	/// has to be a second tree because a `CALayer` can only be in one place at a
	/// time: handing the look the window's own tree takes the captions and the
	/// spinners off the preview underneath it, which is a worse bug than the one
	/// being fixed.
	///
	/// The export's way in is not available here. An
	/// `AVVideoCompositionCoreAnimationTool` draws during *offline* rendering
	/// and does nothing during playback, and the video composition the preview
	/// plays is a Core Image one, which ignores the tool anyway — see
	/// ``CuttrCompose/Renderer/overlays(of:onto:to:progress:)``, which is why an
	/// export with overlays on it is encoded twice. What draws a layer tree over
	/// a *playing* item is `AVSynchronizedLayer`, which is what the panel hosts
	/// this in.
	///
	/// Only the layered overlays are in here, which is the same division the
	/// preview and the export make: an effect, film mode, or anything hung
	/// behind a person is drawn into the frame by the video composition, so the
	/// look already has those from the composition it is playing.
	static func overlays(for resolved: ResolvedProject) -> CALayer {
		OverlayLayers.build(resolved, size: resolved.project.output.size, host: .preview)
	}
}

/// What keeps a look open only for as long as somebody is looking.
///
/// Which is to say: while the list it was taken from is being moved about in. A
/// click anywhere else — a panel beside the list, another window — is somebody
/// finished, and so is the window being resized, moved, deactivated or closed. A
/// click *in* the list is not: it selects a row, and the look follows the
/// selection.
///
/// One implementation, because there are two lists that take looks — the
/// programme tree and the library — and two copies of this rule would be two
/// answers to "what does a click mean" the first time one of them was changed.
///
/// The panel's own handles are the single exception: it can be moved and resized
/// while a look is open, and a press on the strip that moves it is not somebody
/// saying they are finished with it.
@MainActor
final class LookWatch {
	private var undo: [() -> Void] = []

	var isWatching: Bool { !undo.isEmpty }

	/// Starts watching, if it is not already. `list` is the list the look was
	/// taken from; `look` is the panel, so its handles can be left alone.
	func begin(in list: NSView, look: QuickLookPanel, close: @escaping () -> Void) {
		guard undo.isEmpty, let window = list.window else { return }
		let mouse = NSEvent.addLocalMonitorForEvents(
			matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
		) { event in
			if event.window === look, look.takes(event) { return event }
			if event.window !== window
				|| !list.bounds.contains(list.convert(event.locationInWindow, from: nil)) {
				close()
			}
			return event
		}
		undo.append { if let mouse { NSEvent.removeMonitor(mouse) } }
		for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification,
		             NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
			let token = NotificationCenter.default.addObserver(
				forName: name, object: window, queue: nil
			) { _ in
				MainActor.assumeIsolated { close() }
			}
			undo.append { NotificationCenter.default.removeObserver(token) }
		}
	}

	func end() {
		for undo in undo { undo() }
		undo = []
	}
}

/// The panel a look happens in.
///
/// A window rather than a view in the window's own hierarchy, and that is the
/// one decision everything else follows from. A child window can hover over a
/// split view without being inside it, needs nothing from the layout it covers,
/// and — because it never takes the keyboard — leaves the tree first responder
/// while it plays. So the arrows keep walking the tree, space keeps coming back
/// here to close it, and the whole thing needs no focus dance.
///
/// It plays through a ``Transport`` of its own, handed the composition the
/// window has already built. Not a second playback path: the same class the
/// cutting window and the trim dialog play through, with the same seek and tick
/// rules, pointed at the same `AVComposition` the preview is pointed at. What it
/// deliberately does not touch is the window's transport — so the playhead the
/// strip and the clock are showing does not move while a look is taken, and
/// there is nothing to put back when it closes.
///
/// It does not use ``PlaybackControls``. That bar is for a picture somebody is
/// living in: it fades in when the mouse moves, carries a scrubber, a play
/// button and a way out of full screen, and it is seventy-six points tall. Over
/// a look that lasts four seconds it would be a third of the panel, fading in
/// and out, offering controls for something that is over. What a look needs said
/// is *what this is and how long it is*, which is a caption and a rule.
@MainActor
public final class QuickLookPanel: NSPanel {

	/// The programme as the preview plays it. The window has already assembled
	/// this — see `ComposeWindowController.rebuild` — and a look that built its
	/// own would be a look somebody waits for.
	public typealias Playable = () -> (
		composition: AVComposition, videoComposition: AVVideoComposition?,
		audioMix: AVAudioMix?, duration: Double)?

	/// A take's own media, for a look at material that is not on the programme
	/// at all — see ``MaterialTree``.
	///
	/// The three things a take says about what it is made of, which is exactly
	/// what ``Transport/load(video:audio:offset:completion:)`` takes: the
	/// composition of a video and a separate recorder is *that* class's, and
	/// this panel assembling its own would be a second answer to a question
	/// with one right answer.
	///
	/// One clock, the video's. A positive `offset` means the recorder was
	/// started after the camera — see the house rules.
	public struct Media: Equatable {
		public let video: URL?
		public let audio: URL?
		public let offset: Double

		public init(video: URL?, audio: URL?, offset: Double) {
			self.video = video
			self.audio = audio
			self.offset = offset
		}
	}

	/// The caption strip under the picture, which is also the panel's handle.
	///
	/// `nonisolated` so that the arithmetic in ``QuickLook`` — which is the part
	/// of a look with no window in it — can ask how tall it is.
	nonisolated static let captionHeight: CGFloat = 34

	private let transport = Transport()
	private var playerView: PlayerView!
	private let overlays = LookOverlays()
	private let caption = Caption()
	private var chrome: Chrome!
	/// What is presented now, so re-aiming at the next row does not replace an
	/// item that is already the right one.
	private var presented: AVComposition?
	/// And the same for a take's media, which is loaded rather than presented.
	private var loaded: Media?
	private var span = QuickLook.Span(start: 0, end: 0)
	/// The shape of what is playing, so a corner drag knows what to keep.
	private var output = NSSize(width: 16, height: 9)
	/// A width somebody dragged the panel to.
	///
	/// Kept for as long as the panel lives, because it is a preference and not a
	/// position: somebody who wants a bigger look wants it for the next row too.
	private var chosenWidth: CGFloat?
	/// Whether the panel has been dragged somewhere by hand during this look.
	///
	/// Kept only until it is put away. Walking the tree with one open re-aims it
	/// and must not snatch it back from where it was put; taking a fresh look at
	/// a row somewhere else in the list starts it beside that row again, which is
	/// the whole point of it being anchored to a row.
	private var putByHand = false
	/// The frame a corner drag started from, so the drag is read as a distance
	/// from where the press landed rather than as sixty separate nudges.
	private var sizingFrom = NSRect.zero

	public init() {
		super.init(contentRect: NSRect(x: 0, y: 0, width: 480, height: 304),
		           styleMask: [.borderless, .nonactivatingPanel],
		           backing: .buffered, defer: false)
		isFloatingPanel = true
		// Never the key window: the tree keeps the keyboard for as long as the
		// look is open, which is what makes space and the arrows go on working
		// where somebody is looking.
		becomesKeyOnlyIfNeeded = true
		hidesOnDeactivate = true
		isOpaque = false
		backgroundColor = .clear
		hasShadow = true
		// Mouse events, but only for the two things there are to take hold of.
		//
		// This panel used to ignore the mouse outright, and the reasoning was
		// that a look is a look: every gesture that is not moving about the list
		// means "enough", so letting every click through to the window
		// underneath covered clicking on the panel and clicking beside it with
		// one rule. That rule is still here and still single — it lives in
		// ``LookWatch``, which puts the look away on any press that is not in
		// the list — but a panel that cannot be moved is a panel that covers the
		// one row somebody wanted to compare with, and there is nothing to be
		// done about it. So the caption strip is a handle and its corner is a
		// size, and a press anywhere else still means enough.
		ignoresMouseEvents = false
		// Not by its background: the background is the picture, and a look that
		// slid across the screen whenever somebody pressed on the picture would
		// be a look that moves when nobody asked it to.
		isMovableByWindowBackground = false

		let root = Chrome(frame: NSRect(x: 0, y: 0, width: 480, height: 304))
		root.wantsLayer = true
		root.layer?.backgroundColor = Theme.card.cgColor
		root.layer?.cornerRadius = 10
		root.layer?.masksToBounds = true
		root.layer?.borderWidth = 1
		root.layer?.borderColor = Theme.rule.cgColor

		playerView = PlayerView(player: transport.player)
		playerView.translatesAutoresizingMaskIntoConstraints = false
		overlays.translatesAutoresizingMaskIntoConstraints = false
		caption.translatesAutoresizingMaskIntoConstraints = false
		root.addSubview(playerView)
		// Over the picture, in the same rectangle: the tree of layers is placed
		// against the picture rather than against the view — see
		// ``QuickLook/picture(of:in:)``.
		root.addSubview(overlays)
		root.addSubview(caption)
		NSLayoutConstraint.activate([
			playerView.topAnchor.constraint(equalTo: root.topAnchor),
			playerView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
			playerView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
			overlays.topAnchor.constraint(equalTo: playerView.topAnchor),
			overlays.leadingAnchor.constraint(equalTo: playerView.leadingAnchor),
			overlays.trailingAnchor.constraint(equalTo: playerView.trailingAnchor),
			overlays.bottomAnchor.constraint(equalTo: playerView.bottomAnchor),
			caption.topAnchor.constraint(equalTo: playerView.bottomAnchor),
			caption.leadingAnchor.constraint(equalTo: root.leadingAnchor),
			caption.trailingAnchor.constraint(equalTo: root.trailingAnchor),
			caption.bottomAnchor.constraint(equalTo: root.bottomAnchor),
			caption.heightAnchor.constraint(equalToConstant: Self.captionHeight),
		])
		contentView = root
		chrome = root

		root.onGrab = { [weak self] in self?.putByHand = true }
		root.onSizeStart = { [weak self] in self?.sizingFrom = self?.frame ?? .zero }
		root.onSizeDrag = { [weak self] drag in self?.resize(by: drag) }

		transport.onTick = { [weak self] time in
			guard let self, self.transport.isPlaying else { return }
			self.caption.done = self.span.duration > 0
				? min(1, max(0, (time - self.span.start) / self.span.duration)) : 0
		}
	}

	/// Never the key window, whatever is pressed on it.
	///
	/// The list keeps the keyboard for as long as the look is open, which is
	/// what makes space and the arrows go on working where somebody is looking.
	/// `becomesKeyOnlyIfNeeded` says the same thing about clicks and would very
	/// likely be enough on its own — nothing on this panel takes typing — but
	/// "very likely" is not what should be standing between the arrow keys and
	/// the list they belong to.
	public override var canBecomeKey: Bool { false }
	public override var canBecomeMain: Bool { false }

	public var isShowing: Bool { isVisible }

	/// Whether this press is one the panel wants: its handle, or its corner.
	///
	/// Asked by ``LookWatch`` before it decides that a press means "enough".
	func takes(_ event: NSEvent) -> Bool {
		guard let chrome else { return false }
		return QuickLook.grip(at: chrome.convert(event.locationInWindow, from: nil),
		                      in: chrome.bounds) != nil
	}

	/// Takes the look: presents the programme, plays the span, and puts the
	/// panel beside the row.
	///
	/// Called again while it is open to aim it somewhere else, which is what
	/// happens when somebody arrows down the tree — see
	/// ``ProgrammePanel/showLook()``.
	///
	/// `overlaid` is the tree of captions, spinners, scenes and bubbles that go
	/// over the picture — ``QuickLook/overlays(for:)``. Without it the look plays
	/// the programme with nothing on it, which is a look at something nobody is
	/// going to render.
	public func show(_ span: QuickLook.Span, titled title: String, saying note: String,
	                 playing playable: Playable?, over parent: NSWindow,
	                 beside column: NSRect, row: NSRect, output: NSSize,
	                 overlaid overlays: CALayer? = nil) {
		say(span, titled: title, saying: note)
		place(over: parent, beside: column, row: row, output: output)

		if let played = playable?() {
			if presented !== played.composition {
				presented = played.composition
				transport.present(played.composition, videoComposition: played.videoComposition,
				                  audioMix: played.audioMix, duration: played.duration)
			}
			caption.waiting = nil
		} else {
			// The window is still assembling the programme. Said rather than
			// shown as black: a panel with nothing in it and no explanation is
			// the worst thing a look can be.
			caption.waiting = "assembling the programme…"
		}

		attach(to: parent)
		guard presented != nil else { return }
		// After the item exists, because the overlays are synchronised to it.
		self.overlays.show(overlays, of: output, on: transport.player.currentItem)
		transport.play(from: span.start, to: span.end)
	}

	/// The same, at a take's own media rather than at the assembled programme.
	///
	/// For material that is not on the programme at all — a clip in the library,
	/// which may never have been placed. There is nothing over it: overlays
	/// belong to a project, and this is a look at what a take holds.
	///
	/// `media` of `nil` is nothing to play and `note` says why, which is the
	/// answer for a take whose video has been moved somewhere else: a caption
	/// that says so beats a panel that plays black.
	public func show(_ span: QuickLook.Span, titled title: String, saying note: String,
	                 playing media: Media?, over parent: NSWindow,
	                 beside column: NSRect, row: NSRect, output: NSSize) {
		say(span, titled: title, saying: note)
		place(over: parent, beside: column, row: row, output: output)
		attach(to: parent)

		guard let media else {
			caption.waiting = "the take's media is not where it says it is"
			overlays.show(nil, of: output, on: nil)
			transport.pause()
			presented = nil
			loaded = nil
			return
		}
		guard loaded != media else {
			transport.play(from: span.start, to: span.end)
			return
		}
		loaded = media
		presented = nil
		caption.waiting = "reading the take…"
		// Loading reads the tracks, which is a few milliseconds and not
		// nothing — so the span is played when the media is there rather than
		// at a player that has not been given anything yet.
		transport.load(video: media.video, audio: media.audio, offset: media.offset) {
			[weak self] in
			guard let self, self.loaded == media, self.isVisible else { return }
			self.caption.waiting = nil
			self.transport.play(from: self.span.start, to: self.span.end)
		}
	}

	/// What the caption says about what is playing.
	private func say(_ span: QuickLook.Span, titled title: String, saying note: String) {
		self.span = span
		caption.title = title
		caption.note = note
		caption.done = 0
	}

	/// Where the panel goes, and how big it is.
	private func place(over parent: NSWindow, beside column: NSRect, row: NSRect, output: NSSize) {
		self.output = output
		let size = QuickLook.size(for: output, in: parent.frame, chosen: chosenWidth)
		guard !putByHand else {
			// Somebody has put this panel somewhere. Re-aiming it at the next row
			// keeps it there, and keeps its top left corner still while it does.
			setFrame(NSRect(x: frame.minX, y: frame.maxY - size.height,
			                width: size.width, height: size.height), display: true)
			return
		}
		setFrame(QuickLook.place(size, beside: column, row: row, inside: parent.frame),
		         display: true)
	}

	private func attach(to parent: NSWindow) {
		if parent.childWindows?.contains(self) != true {
			parent.addChildWindow(self, ordered: .above)
		}
		orderFront(nil)
	}

	/// A corner drag, in points from where the press landed.
	private func resize(by drag: NSSize) {
		guard let parent, sizingFrom.width > 0 else { return }
		let next = QuickLook.resized(sizingFrom, by: drag, output: output, inside: parent.frame)
		chosenWidth = next.width
		setFrame(next, display: true)
	}

	/// Puts it away, and leaves nothing behind.
	///
	/// The range comes off the item as well as the player being paused: a
	/// `forwardPlaybackEndTime` outlives the play that set it, and a transport
	/// left with one still on it stops in the middle of the next thing it is
	/// asked to play.
	public func hide() {
		transport.pause()
		transport.clearRange()
		parent?.removeChildWindow(self)
		orderOut(nil)
		// Where it was put was about this look. How big it was made is a
		// preference, and stays.
		putByHand = false
	}

	/// For the tests: whether the look is running, and where it has got to.
	var isPlayingForTesting: Bool { transport.isPlaying }
	var timeForTesting: Double { transport.currentTime }
	/// For the tests: the overlay tree over the picture, and the item it is
	/// synchronised to. Whether the tree is *there* is the whole of the bug this
	/// answers, so it is a thing a test can ask about.
	var overlayTreeForTesting: CALayer? { overlays.tree }
	var overlayItemForTesting: AVPlayerItem? { overlays.item }
	/// For the tests: the take's media the look was given, which is where the
	/// one clock and its offset can be checked.
	var mediaForTesting: Media? { loaded }
	/// For the tests: taking hold of the handle, without a mouse.
	func grabForTesting() { putByHand = true }
	func sizeForTesting(by drag: NSSize) {
		sizingFrom = frame
		resize(by: drag)
	}

	/// The strip under the picture: what this is, how long it is, how far
	/// through it is.
	private final class Caption: NSView {
		var title = "" { didSet { needsDisplay = true } }
		var note = "" { didSet { needsDisplay = true } }
		/// What is being waited for, said in place of the note. `nil` when
		/// nothing is.
		var waiting: String? { didSet { needsDisplay = true } }
		var done: Double = 0 { didSet { needsDisplay = true } }

		override func draw(_ dirtyRect: NSRect) {
			Theme.card.setFill()
			bounds.fill()
			// The rule is the whole of the transport furniture: it says how far
			// through the look is and it cannot be dragged, because a look is
			// too short to scrub.
			Theme.rule.setFill()
			NSRect(x: 0, y: bounds.maxY - 2, width: bounds.width, height: 2).fill()
			Theme.accent.setFill()
			NSRect(x: 0, y: bounds.maxY - 2, width: bounds.width * CGFloat(done), height: 2).fill()

			(title as NSString).draw(
				at: NSPoint(x: 10, y: bounds.midY - 8),
				withAttributes: [.font: Theme.bodyStrong, .foregroundColor: Theme.text])
			let said = waiting ?? note
			let attributes: [NSAttributedString.Key: Any] = [
				.font: Theme.monoSmall, .foregroundColor: Theme.dimText,
			]
			let width = (said as NSString).size(withAttributes: attributes).width
			// Clear of the corner, which is the size and not something to write
			// over.
			let right = bounds.maxX - QuickLook.gripWidth - 4
			(said as NSString).draw(at: NSPoint(x: right - width, y: bounds.midY - 6),
			                        withAttributes: attributes)
			grip()
		}

		/// Three short diagonals in the corner: the same thing every resizable
		/// corner on the machine has, which is how somebody knows it is one
		/// without being told.
		private func grip() {
			Theme.dimText.setStroke()
			let path = NSBezierPath()
			path.lineWidth = 1
			for step in stride(from: CGFloat(4), through: 12, by: 4) {
				path.move(to: NSPoint(x: bounds.maxX - 4, y: bounds.minY + step))
				path.line(to: NSPoint(x: bounds.maxX - 4 - step, y: bounds.minY + 4))
			}
			path.stroke()
		}
	}

	/// The panel's own view: the two presses it answers, and the one it does not.
	///
	/// A press on the caption strip drags the panel; a press on the corner of it
	/// resizes; a press anywhere else is left alone, because ``LookWatch`` has
	/// already read it as somebody finished looking. Nothing here decides that —
	/// two places deciding what a press means is how the rule stops being single.
	private final class Chrome: NSView {
		/// The panel is about to be dragged somewhere.
		var onGrab: (() -> Void)?
		/// A corner press, and then the distance dragged from it.
		var onSizeStart: (() -> Void)?
		var onSizeDrag: ((NSSize) -> Void)?

		/// Where a corner drag started, in screen points. Screen rather than
		/// window, because the window is being resized underneath the pointer
		/// and a point in its coordinates means something different on every
		/// event of the drag.
		private var from: NSPoint?

		override func mouseDown(with event: NSEvent) {
			switch QuickLook.grip(at: convert(event.locationInWindow, from: nil), in: bounds) {
			case .bar:
				onGrab?()
				// The system's own drag: it moves the window against the pointer
				// exactly, snaps where the system snaps, and needs no tracking
				// loop of ours.
				window?.performDrag(with: event)
			case .corner:
				from = window?.convertPoint(toScreen: event.locationInWindow)
				onSizeStart?()
			case nil:
				break
			}
		}

		override func mouseDragged(with event: NSEvent) {
			guard let from, let now = window?.convertPoint(toScreen: event.locationInWindow)
			else { return }
			onSizeDrag?(NSSize(width: now.x - from.x, height: from.y - now.y))
		}

		override func mouseUp(with event: NSEvent) { from = nil }

		override func resetCursorRects() {
			let bar = NSRect(x: 0, y: 0, width: bounds.width - QuickLook.gripWidth,
			                 height: QuickLookPanel.captionHeight)
			addCursorRect(bar, cursor: .openHand)
			let corner = NSRect(x: bounds.maxX - QuickLook.gripWidth, y: 0,
			                    width: QuickLook.gripWidth,
			                    height: QuickLookPanel.captionHeight)
			if #available(macOS 15.0, *) {
				addCursorRect(corner, cursor: .frameResize(position: .bottomRight,
				                                           directions: .all))
			} else {
				addCursorRect(corner, cursor: .crosshair)
			}
		}
	}
}

/// The overlays over a look, on the player's own clock.
///
/// An `AVSynchronizedLayer`, and not the paused tree the composing window
/// scrubs. That window is always at *a* moment: it holds the tree at `speed = 0`
/// and names the moment with `timeOffset`, which is exact for a still and for a
/// frame step, and it is driven from the playback ticks. A look does not sit at a
/// moment — it plays four seconds and stops — and a layer tree stepped from
/// sixty ticks a second is a tree that stutters and slides against the picture:
/// two clocks again, which is the thing this program has a house rule about. A
/// synchronized layer has the item's clock, which is the clock the frames arrive
/// on, so a spinner turns at the speed it will turn at in the file.
@MainActor
final class LookOverlays: NSView {
	/// What is being shown, and what it is synchronised to. Kept so that
	/// re-aiming a look at the next row does not rebuild either.
	private(set) var tree: CALayer?
	private(set) var item: AVPlayerItem?
	private var synchronized: AVSynchronizedLayer?
	private var output = CGSize.zero

	override init(frame: NSRect) {
		super.init(frame: frame)
		wantsLayer = true
	}

	@available(*, unavailable) required init?(coder: NSCoder) { nil }

	/// Nothing on it to press. It covers the picture, and what a press on the
	/// picture means is the panel's business rather than a layer's.
	override func hitTest(_ point: NSPoint) -> NSView? { nil }

	func show(_ tree: CALayer?, of output: CGSize, on item: AVPlayerItem?) {
		self.output = output
		guard let tree, let item else { clear(); return }
		if self.tree !== tree || self.item !== item {
			clear()
			self.tree = tree
			self.item = item
		}
		attach()
	}

	private func clear() {
		synchronized?.removeFromSuperlayer()
		tree?.removeFromSuperlayer()
		synchronized = nil
		tree = nil
		item = nil
	}

	/// Attaching is idempotent and cheap, and it is done from `layout` as well
	/// as from ``show(_:of:on:)`` — a panel that has not been on screen yet has
	/// no backing layer to attach anything to, and the composing window learned
	/// that one the hard way: a tree built before there was a layer to hold it
	/// meant a preview with no captions on it until something happened to
	/// rebuild the project.
	private func attach() {
		guard let host = layer, let tree, let item else { return }
		if synchronized == nil {
			let synchronized = AVSynchronizedLayer(playerItem: item)
			synchronized.addSublayer(tree)
			host.addSublayer(synchronized)
			self.synchronized = synchronized
		}
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		synchronized?.frame = bounds
		// The tree is built at the output's pixel size and the player draws the
		// video aspect-fitted, so it is scaled and positioned onto the picture's
		// own rectangle. Any other arrangement puts a lower third somewhere else
		// on screen than it will be in the file.
		let picture = QuickLook.picture(of: output, in: bounds)
		tree.bounds = CGRect(origin: .zero, size: output)
		tree.anchorPoint = CGPoint(x: 0.5, y: 0.5)
		tree.position = CGPoint(x: picture.midX, y: picture.midY)
		tree.transform = CATransform3DMakeScale(
			output.width > 0 ? picture.width / output.width : 1,
			output.height > 0 ? picture.height / output.height : 1, 1)
		CATransaction.commit()
	}

	override func layout() {
		super.layout()
		attach()
	}
}
