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
	/// Everything is in one coordinate space — screen points, as windows are.
	static func place(_ size: NSSize, beside column: NSRect, row: NSRect, inside window: NSRect) -> NSRect {
		let gap: CGFloat = 12
		let margin: CGFloat = 16
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
	static func size(for output: NSSize, in window: NSRect) -> NSSize {
		let width = min(max(360, window.width * 0.38), 560)
		let ratio = output.width > 0 && output.height > 0 ? output.height / output.width : 9.0 / 16
		let height = (width * ratio).rounded()
		return NSSize(width: width.rounded(), height: height + QuickLookPanel.captionHeight)
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

	/// The caption strip under the picture.
	static let captionHeight: CGFloat = 34

	private let transport = Transport()
	private var playerView: PlayerView!
	private let caption = Caption()
	/// What is presented now, so re-aiming at the next row does not replace an
	/// item that is already the right one.
	private var presented: AVComposition?
	private var span = QuickLook.Span(start: 0, end: 0)

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
		// Nothing on it to click. A look is a look — every gesture that is not
		// moving about the tree means "enough", and letting the click through to
		// the window underneath is how one rule covers clicking on the panel and
		// clicking beside it.
		ignoresMouseEvents = true

		let root = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 304))
		root.wantsLayer = true
		root.layer?.backgroundColor = Theme.card.cgColor
		root.layer?.cornerRadius = 10
		root.layer?.masksToBounds = true
		root.layer?.borderWidth = 1
		root.layer?.borderColor = Theme.rule.cgColor

		playerView = PlayerView(player: transport.player)
		playerView.translatesAutoresizingMaskIntoConstraints = false
		caption.translatesAutoresizingMaskIntoConstraints = false
		root.addSubview(playerView)
		root.addSubview(caption)
		NSLayoutConstraint.activate([
			playerView.topAnchor.constraint(equalTo: root.topAnchor),
			playerView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
			playerView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
			caption.topAnchor.constraint(equalTo: playerView.bottomAnchor),
			caption.leadingAnchor.constraint(equalTo: root.leadingAnchor),
			caption.trailingAnchor.constraint(equalTo: root.trailingAnchor),
			caption.bottomAnchor.constraint(equalTo: root.bottomAnchor),
			caption.heightAnchor.constraint(equalToConstant: Self.captionHeight),
		])
		contentView = root

		transport.onTick = { [weak self] time in
			guard let self, self.transport.isPlaying else { return }
			self.caption.done = self.span.duration > 0
				? min(1, max(0, (time - self.span.start) / self.span.duration)) : 0
		}
	}

	public var isShowing: Bool { isVisible }

	/// Takes the look: presents the programme, plays the span, and puts the
	/// panel beside the row.
	///
	/// Called again while it is open to aim it somewhere else, which is what
	/// happens when somebody arrows down the tree — see
	/// ``ProgrammePanel/quickLook(at:)``.
	public func show(_ span: QuickLook.Span, titled title: String, saying note: String,
	                 playing playable: Playable?, over parent: NSWindow,
	                 beside column: NSRect, row: NSRect, output: NSSize) {
		self.span = span
		caption.title = title
		caption.note = note
		caption.done = 0

		let size = QuickLook.size(for: output, in: parent.frame)
		setFrame(QuickLook.place(size, beside: column, row: row, inside: parent.frame), display: true)

		if let played = playable?() {
			if presented !== played.composition {
				presented = played.composition
				transport.present(played.composition, videoComposition: played.videoComposition,
				                  audioMix: played.audioMix, duration: played.duration)
			}
			caption.waiting = false
		} else {
			// The window is still assembling the programme. Said rather than
			// shown as black: a panel with nothing in it and no explanation is
			// the worst thing a look can be.
			caption.waiting = true
		}

		if parent.childWindows?.contains(self) != true {
			parent.addChildWindow(self, ordered: .above)
		}
		orderFront(nil)
		guard presented != nil else { return }
		transport.play(from: span.start, to: span.end)
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
	}

	/// For the tests: whether the look is running, and where it has got to.
	var isPlayingForTesting: Bool { transport.isPlaying }
	var timeForTesting: Double { transport.currentTime }

	/// The strip under the picture: what this is, how long it is, how far
	/// through it is.
	private final class Caption: NSView {
		var title = "" { didSet { needsDisplay = true } }
		var note = "" { didSet { needsDisplay = true } }
		var waiting = false { didSet { needsDisplay = true } }
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
			let said = waiting ? "assembling the programme…" : note
			let attributes: [NSAttributedString.Key: Any] = [
				.font: Theme.monoSmall, .foregroundColor: Theme.dimText,
			]
			let width = (said as NSString).size(withAttributes: attributes).width
			(said as NSString).draw(at: NSPoint(x: bounds.maxX - 10 - width, y: bounds.midY - 6),
			                        withAttributes: attributes)
		}
	}
}
