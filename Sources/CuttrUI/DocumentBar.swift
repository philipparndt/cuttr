import AppKit
import CuttrKit

/// The strip along the top of both windows.
///
/// One bar, learned once. Three things in it and nothing else: **which
/// document** on the left, **the clock** in the middle, **what just happened**
/// on the right, with the progress of whatever is happening underneath it.
///
/// The test for anything else that wanted to live up here is whether it is true
/// in every mode. Choosing the video file is not — it is done once, at the
/// start, and belongs behind the take's name. A checkbox for markers over the
/// picture is not — there is no picture in two of the three modes. Both used to
/// be in a bar; neither is now.
///
/// The clock is the reason this view exists at all. Somebody watching wants to
/// know where they are, always, in both windows, in the same place — and the
/// two bars this replaces each had their own answer, one of which was to let a
/// status message overwrite it.
@MainActor
public final class DocumentBar: NSView {

	/// The height every window gives it.
	///
	/// Tall, because it *is* the title bar. The window draws no separate one:
	/// the content runs to the top of the frame, the titlebar is transparent,
	/// and this strip stands in the whole of that band. One row of furniture
	/// where there were two, and the document's name sits where a window's
	/// title has always sat.
	public static let height: CGFloat = 52

	/// Makes the window's title band as tall as this bar, with the close,
	/// minimise and zoom buttons in the middle of it.
	///
	/// An empty `NSToolbar` in the `.unified` style, and nothing else. macOS
	/// gives a unified toolbar a 52-point band and centres the traffic lights in
	/// it — which is exactly this bar's height, and exactly the arrangement
	/// wanted. Nothing goes *in* the toolbar: the bar is a view in the content
	/// view, which runs up behind the titlebar because the window is
	/// `.fullSizeContentView`.
	///
	/// This replaced setting the buttons' frames by hand and setting them again
	/// on every resize, because AppKit put them back. Measured, both put the
	/// buttons in the same place — but only this one makes the *band* 52 points:
	/// by hand the buttons were centred while `contentLayoutRect` still reported
	/// a 32-point titlebar, so anything asking the window how much room the
	/// titlebar wanted got the wrong answer.
	///
	/// The empty row does not take the clicks. Hit-testing a point in the middle
	/// of the band lands on the bar's own clock, not on the toolbar: with no
	/// items in it there is nothing there to hit.
	public static func growTitleBand(of window: NSWindow) {
		let toolbar = NSToolbar(identifier: "cuttr.band")
		toolbar.displayMode = .iconOnly
		toolbar.allowsUserCustomization = false
		toolbar.showsBaselineSeparator = false
		window.toolbar = toolbar
		window.toolbarStyle = .unified
	}

	/// How far in the first thing starts, so it clears the traffic lights.
	///
	/// This is the reason the program refused `.fullSizeContentView` for so
	/// long — under a transparent titlebar the alignment field ended up behind
	/// the close button. The controls have moved since, and the answer to the
	/// old objection is to leave room for them.
	///
	/// A fallback, not the answer. The number was 78 and the buttons ended at
	/// 79 once the band became a unified toolbar, so the capsule sat one point
	/// over the zoom button — near enough to look deliberate and wrong. Where
	/// there is a window to ask, ``roomForTrafficLights(in:)`` asks it; a
	/// guess about somebody else's furniture goes stale the moment they move
	/// it.
	public static let trafficLights: CGFloat = 82

	public override func viewDidMoveToWindow() {
		super.viewDidMoveToWindow()
		// The buttons are placed by AppKit, and where they end has changed
		// under this program once already. Ask them.
		remeasure()
	}

	/// Asks the window where the buttons are now.
	///
	/// Called again whenever they can have moved, which in practice means going
	/// in and out of full screen: it was measured once when the bar arrived in
	/// its window and never again, so the eighty-two points held for three
	/// buttons stayed held in full screen, where there are no buttons. A hole
	/// at the leading edge with nothing in it, and the capsule sitting where it
	/// had been pushed by furniture that was no longer there.
	public func remeasure() {
		let room = Self.roomForTrafficLights(in: window)
		backLeading?.constant = room
		// The capsule starts after the chevron when there is one, and where the
		// chevron would have been when there is not.
		leading?.constant = room + (back.isHidden ? 0 : Self.backWidth + Self.backGap)
	}

	/// Whether there is anywhere to go back to. Said by the window, which is
	/// the only thing that knows whether this document belongs to a project.
	public func setBack(_ shown: Bool) {
		guard back.isHidden == shown else { return }
		back.isHidden = !shown
		remeasure()
	}

	@objc private func goBack() { onBack?() }

	static let backWidth: CGFloat = 18
	static let backGap: CGFloat = 4

	/// Where the first thing can start in this window, measured from the
	/// buttons themselves.
	///
	/// The gap is the same one the buttons have between each other, so the
	/// capsule reads as the next thing in the row rather than as a separate
	/// arrangement that happens to start nearby.
	///
	/// Nothing to clear in full screen: macOS takes the buttons into the
	/// titlebar that slides down, and asking the ones it left behind gives
	/// their last windowed frame — a measurement of where they used to be.
	public static func roomForTrafficLights(in window: NSWindow?) -> CGFloat {
		let edges = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
			.compactMap { window?.standardWindowButton($0) }
			.filter { !$0.isHidden }
			.map(\.frame.maxX)
		return room(clearing: edges,
		            inFullScreen: window?.styleMask.contains(.fullScreen) ?? false)
	}

	/// The arithmetic on its own, so it can be checked without a window.
	///
	/// `.fullScreen` cannot be put into a style mask by hand — AppKit traps on
	/// it — so a test cannot make a window that is in full screen. What it can
	/// do is ask this the question a full-screen window would.
	static func room(clearing edges: [CGFloat], inFullScreen: Bool) -> CGFloat {
		if inFullScreen { return edgeOfTheScreen }
		guard let last = edges.max() else { return trafficLights }
		return last + 20
	}

	/// The inset with no buttons to clear. The same air the capsule has above
	/// and below it, so it sits in from the corner rather than against it.
	public static let edgeOfTheScreen: CGFloat = 20

	/// The setting-up controls, shown in a popover from the document's name.
	///
	/// Behind the name rather than in the bar because that is what they are
	/// about: which files this take is made of, and how they line up. Set once,
	/// checked occasionally, and in the way for the rest of the session.
	public var setUp: NSView? {
		didSet {
			more.isHidden = setUp == nil
			showGroup()
			setName(documentName)
		}
	}

	/// The rule is only worth drawing when there is something on the far side of
	/// it. A window with no set-up and no controls of its own gets a name and a
	/// clock, and no furniture between them.
	private func showGroup() {
		let anything = group.arrangedSubviews.contains { !$0.isHidden }
		group.isHidden = !anything
		divider.isHidden = !anything
	}

	/// Every document open, for the menu behind the name.
	///
	/// A document's name opening a list of documents is what a name is *for*.
	/// The take's files and its alignment were behind it until now, and they
	/// were never that: one is "which document am I in", the other is "what is
	/// this document made of", and putting the second behind the first is what
	/// made it wrong. The rule the bar follows now — the leading group is the
	/// document you are in, the trailing group is what this window does with it.
	public var onProject: (() -> Void)?
	/// Asked to show what can be done about the repository this document sits
	/// in, and which branch it is on. `nil` when the folder is not a work tree,
	/// which is the ordinary case for footage.
	public var onBranch: (() -> Void)?

	/// Asked to go out to the project this take or scene belongs to.
	public var onBack: (() -> Void)?

	/// Rolling the tape, from the bar that says where the tape is.
	///
	/// Beside the clock rather than anywhere else, because it is the verb that
	/// changes the number: the two are one control in everything but code. Both
	/// windows get it — the cutting window has had `space` for this since the
	/// beginning and the composing window has too, and a keyboard shortcut with
	/// nothing on screen is a shortcut only the person who wrote it knows.
	public var onPlayPause: (() -> Void)?

	private var documentName = ""
	/// Which project on the left, which branch on the right, and `⇧⌘P`.
	private let capsule = DocumentCapsule()
	/// How far in the capsule starts. Set from the buttons themselves once
	/// there is a window to measure.
	private var leading: NSLayoutConstraint?
	private var backLeading: NSLayoutConstraint?
	/// The way into the setting-up controls: an ellipsis, which is what a menu
	/// of more things about the thing beside it looks like everywhere else on
	/// this machine.
	///
	/// It was a `⌄` glued onto the end of the name with two spaces, which put
	/// the mark on the text's baseline rather than on the row's centre and moved
	/// it every time the name changed length. A button of its own sits still and
	/// is a target somebody can hit.
	private let more = NSButton()
	/// The way back out of a take or a scene, to the project it belongs to.
	///
	/// Between the traffic lights and the capsule, which is where a back
	/// chevron lives in everything else on this machine — and it is the same
	/// direction the capsule reads in, so "out of this and up to that" is left
	/// to right. Absent for a project, which has nowhere further out to go.
	private let back = NSButton()
	private let play = NSButton()
	private let clock = NSTextField(labelWithString: "00:00.000")
	private let statusLabel = NSTextField(labelWithString: "")
	private let progress = NSProgressIndicator()
	/// One slot on the far right for a verb that belongs to the whole document
	/// rather than to a mode. The composing window's `Render…` is the only
	/// tenant; everything else that was in a bar found a home nearer the thing
	/// it acts on.
	private let trailing = NSStackView()
	/// What this window is playing, and what it is aligned against.
	///
	/// One cluster rather than several things that happen to be adjacent: the
	/// controls a window adds with ``addLeading(_:)`` and the `…` that opens the
	/// setting-up popover, in that order, evenly spaced, with a rule between
	/// them and the document's name. The name is a name and nothing else — it
	/// had the `…` hanging off it as though the two were one thing, and they are
	/// not: one says which document, the other is a control over it.
	private let group = NSStackView()
	/// The line that says where the name stops and the controls begin.
	private let divider = NSView()
	/// Controls that belong at the far end of the bar.
	///
	/// The bar filled up from the left and left half of itself empty: the name,
	/// a rule, the monitor, six lane colours and a `…` all crowded against the
	/// traffic lights while everything past the clock was air. What goes here is
	/// what somebody reaches for rather than reads — the lane the next cut lands
	/// on — and it reads better in the space that was going spare.
	///
	/// Against the *right edge* rather than against the clock. Put straight
	/// after it, the colours crowded the number they were meant to be giving
	/// room to: the clock is the one thing in this bar that must not move, and a
	/// row of swatches pressed up against it reads as part of it. Out at the
	/// edge they are their own thing and the middle is the time.
	private let afterClock = NSStackView()
	private var popover: NSPopover?

	public override init(frame: NSRect) {
		super.init(frame: frame)
		// The window's chrome is one colour and the content is another.
		//
		// This was `panel`, and so is the ground the content stands on — so the
		// bar and the thing under it were the same grey and the only edge in the
		// window was the rail's. The bar and the rail are the same kind of thing
		// — furniture that says where you are and what you are doing — so they
		// share a ground and make one L down and across the window, and
		// everything they frame is `panel`.
		wantsLayer = true
		layer?.backgroundColor = Theme.background.cgColor

		// A hairline along the bottom, so the edge between chrome and content is
		// a line somebody can see rather than a two-percent step in grey.
		let edge = NSView()
		edge.wantsLayer = true
		edge.layer?.backgroundColor = Theme.rule.withAlphaComponent(0.8).cgColor
		edge.translatesAutoresizingMaskIntoConstraints = false
		addSubview(edge)
		NSLayoutConstraint.activate([
			edge.leadingAnchor.constraint(equalTo: leadingAnchor),
			edge.trailingAnchor.constraint(equalTo: trailingAnchor),
			edge.bottomAnchor.constraint(equalTo: bottomAnchor),
			edge.heightAnchor.constraint(equalToConstant: 1),
		])

		capsule.onHalf = { [weak self] half in
			guard let self else { return }
			switch half {
			case .project: self.onProject?()
			case .branch: self.onBranch?()
			}
		}
		capsule.setContentCompressionResistancePriority(
			NSLayoutConstraint.Priority(1), for: .horizontal)

		// Tabular figures, and a width that never changes.
		//
		// Proportional digits shift under the eye at every frame, and a label
		// that sizes itself to its text moves the whole group sideways between
		// `09.900` and `10.000`. So: monospaced digits in a box wide enough for
		// the longest time this program can show, and the text centred in it.
		clock.font = NSFont.monospacedDigitSystemFont(ofSize: 17, weight: .medium)
		clock.textColor = Theme.text
		clock.alignment = .center
		clock.translatesAutoresizingMaskIntoConstraints = false
		let widest = ("0:00:00.000" as NSString)
			.size(withAttributes: [.font: clock.font as Any]).width
		clock.widthAnchor.constraint(equalToConstant: ceil(widest) + 2).isActive = true

		back.isBordered = false
		back.bezelStyle = .inline
		back.imagePosition = .imageOnly
		back.image = NSImage(systemSymbolName: "chevron.backward",
		                     accessibilityDescription: "back to the project")?
			.withSymbolConfiguration(.init(pointSize: 12, weight: .semibold)
				.applying(.init(paletteColors: [Theme.dimText])))
		back.target = self
		back.action = #selector(goBack)
		back.isHidden = true
		back.translatesAutoresizingMaskIntoConstraints = false
		back.widthAnchor.constraint(equalToConstant: Self.backWidth).isActive = true

		more.isBordered = false
		more.bezelStyle = .inline
		more.imagePosition = .imageOnly
		more.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "more")?
			.withSymbolConfiguration(.init(pointSize: 12, weight: .semibold)
				.applying(.init(paletteColors: [Theme.dimText])))
		more.target = self
		more.action = #selector(showSetUp)
		more.isHidden = true
		more.translatesAutoresizingMaskIntoConstraints = false
		more.widthAnchor.constraint(equalToConstant: 20).isActive = true

		play.isBordered = false
		play.bezelStyle = .inline
		play.imagePosition = .imageOnly
		play.target = self
		play.action = #selector(playTapped)
		play.toolTip = "Play, or stop (space)"
		play.translatesAutoresizingMaskIntoConstraints = false
		play.widthAnchor.constraint(equalToConstant: 22).isActive = true
		setPlaying(false)

		statusLabel.font = Theme.monoSmall
		statusLabel.textColor = Theme.dimText
		statusLabel.alignment = .right
		statusLabel.lineBreakMode = .byTruncatingTail
		statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

		progress.style = .bar
		progress.isIndeterminate = false
		progress.minValue = 0
		progress.maxValue = 1
		progress.controlSize = .small
		progress.isHidden = true

		for stack in [group, afterClock, trailing] {
			stack.orientation = .horizontal
			stack.spacing = 8
			stack.alignment = .centerY
		}

		group.addView(more, in: .trailing)

		divider.wantsLayer = true
		divider.layer?.backgroundColor = Theme.rule.cgColor
		divider.translatesAutoresizingMaskIntoConstraints = false
		NSLayoutConstraint.activate([
			divider.widthAnchor.constraint(equalToConstant: 1),
			divider.heightAnchor.constraint(equalToConstant: 16),
		])

		for view in [back, capsule, divider, group, play, clock, afterClock, statusLabel,
		             progress, trailing] as [NSView] {
			view.translatesAutoresizingMaskIntoConstraints = false
			addSubview(view)
		}

		// The clock is centred on the *window* rather than on what is left over,
		// so it does not shuffle sideways as the name beside it changes length.
		let centred = clock.centerXAnchor.constraint(equalTo: centerXAnchor)
		centred.priority = .defaultHigh
		centred.isActive = true

		// The status sits above the middle and its progress directly under it,
		// so the bar looks the same whether or not something is being counted.
		// A progress indicator that appears *beside* a label pushes the label,
		// and then every message that arrives with one arrives in a different
		// place.
		backLeading = back.leadingAnchor.constraint(equalTo: leadingAnchor,
		                                            constant: Self.trafficLights)
		backLeading?.isActive = true
		back.centerYAnchor.constraint(equalTo: capsule.centerYAnchor).isActive = true
		leading = capsule.leadingAnchor.constraint(equalTo: leadingAnchor,
		                                           constant: Self.trafficLights)
		NSLayoutConstraint.activate([
			leading!,
			capsule.centerYAnchor.constraint(equalTo: centerYAnchor),

			// The rule, then the group: a clear gap either side of it, so the
			// cluster is plainly separate from the name at one end and from the
			// clock at the other.
			divider.leadingAnchor.constraint(equalTo: capsule.trailingAnchor, constant: 14),
			divider.centerYAnchor.constraint(equalTo: centerYAnchor),

			group.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 14),
			group.centerYAnchor.constraint(equalTo: centerYAnchor),

			// The clock is what is centred, and the button hangs off it. Centring
			// the pair instead would move the number sideways by half a button,
			// and the one thing this bar promises is that the clock does not
			// move.
			clock.centerYAnchor.constraint(equalTo: centerYAnchor),
			play.trailingAnchor.constraint(equalTo: clock.leadingAnchor, constant: -6),
			play.centerYAnchor.constraint(equalTo: centerYAnchor),
			play.leadingAnchor.constraint(greaterThanOrEqualTo: group.trailingAnchor, constant: 16),

			// Against the right rather than against the clock. Put straight
			// after it they crowded the number they were supposed to be giving
			// room to — the clock is the one thing in this bar that must not
			// move, and a row of colours pressed up to it reads as part of it.
			// Out at the edge they are their own thing, and the middle is the
			// time.
			afterClock.trailingAnchor.constraint(equalTo: trailing.leadingAnchor, constant: -10),
			// And never close enough to touch the clock, however narrow the
			// window gets.
			afterClock.leadingAnchor.constraint(
				greaterThanOrEqualTo: clock.trailingAnchor, constant: 14),
			afterClock.centerYAnchor.constraint(equalTo: centerYAnchor),

			trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
			trailing.centerYAnchor.constraint(equalTo: centerYAnchor),

			// To the left of whatever is out at the edge, so a message that
			// arrives does not land on the colours.
			statusLabel.trailingAnchor.constraint(equalTo: afterClock.leadingAnchor,
			                                      constant: -10),
			statusLabel.leadingAnchor.constraint(
				greaterThanOrEqualTo: clock.trailingAnchor, constant: 12),
			statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -4),
			statusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 420),

			progress.trailingAnchor.constraint(equalTo: statusLabel.trailingAnchor),
			progress.widthAnchor.constraint(equalToConstant: 110),
			progress.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 2),
			progress.heightAnchor.constraint(equalToConstant: 4),
		])
		setName("")
		showGroup()
	}

	@available(*, unavailable) required init?(coder: NSCoder) { nil }

	// MARK: - State in

	/// Which document this window is about.
	public func setName(_ text: String) {
		documentName = text
		capsule.show(project: text, branch: branchName)
		capsule.toolTip = "Which document this is \u{2014} and every other one that is open"
		more.toolTip = setUp == nil
			? nil : "What this take is made of, and how the two line up"
	}

	private var branchName: String?

	/// Which branch the folder this document sits in is on. `nil` takes the
	/// right half away altogether, which is what a folder outside a work tree
	/// should look like: not an empty box, no box.
	public func setBranch(_ branch: String?) {
		branchName = branch
		capsule.show(project: documentName, branch: branch)
	}

	/// Lights the half whose list is up, and puts it out again after.
	public func setOpenHalf(_ half: DocumentCapsule.Half?) {
		capsule.openHalf = half
	}

	/// Where a list should hang from, for the half that was clicked.
	///
	/// Never an empty rectangle. `NSPopover.show(relativeTo:)` given one
	/// declines silently — no panel, no error, and no closing to report — and a
	/// squeezed capsule is exactly where that used to happen.
	public func anchor(for half: DocumentCapsule.Half) -> (NSView, NSRect) {
		let wanted = half == .project ? capsule.projectRect : capsule.branchRect
		guard wanted.width >= 8, wanted.height >= 8 else { return (capsule, capsule.bounds) }
		return (capsule, wanted)
	}

	/// Where the playhead is. Always, in every mode — that is the point.
	public func setClock(_ seconds: Double) {
		clock.stringValue = Timecode.string(seconds)
	}

	/// Which way round the button is: the shape of what pressing it will do.
	public func setPlaying(_ playing: Bool) {
		play.image = NSImage(
			systemSymbolName: playing ? "pause.fill" : "play.fill",
			accessibilityDescription: playing ? "pause" : "play")?
			.withSymbolConfiguration(.init(pointSize: 13, weight: .medium)
				.applying(.init(paletteColors: [Theme.text])))
	}

	public func setStatus(_ text: String) { statusLabel.stringValue = text }

	/// `nil` puts the bar away.
	public func setProgress(_ fraction: Double?) {
		progress.isHidden = fraction == nil
		if let fraction { progress.doubleValue = fraction }
	}

	/// Adds a document-level verb to the far right.
	public func addTrailing(_ view: NSView) { trailing.addView(view, in: .trailing) }

	/// Adds a control on the far side of the clock. See ``afterClock``.
	public func addAfterClock(_ view: NSView) {
		afterClock.addView(view, in: .leading)
	}

	/// Adds a control to the group, before the `…`.
	///
	/// The `…` stays last because it is the way to more of the same: files, the
	/// offset, `Align`. A control the window adds is a thing somebody uses while
	/// working, and those come first.
	public func addLeading(_ view: NSView) {
		let place = group.arrangedSubviews.firstIndex(of: more) ?? group.arrangedSubviews.count
		group.insertArrangedSubview(view, at: place)
		showGroup()
	}

	/// Told when something in the group is shown or hidden, since a stack view
	/// does not say so itself.
	public func groupChanged() { showGroup() }

	/// Empties the bar, for the next document to furnish.
	///
	/// One bar per window means the bar outlives the document in it, and every
	/// piece of it is about a document: the name, the branch, the `…` behind
	/// which a take's files sit, the monitor a take adds and the `Render…` a
	/// project adds, what just happened and how far along it is. All of it goes,
	/// and ``DocumentEditor/furnish(_:)`` puts the next document's back.
	///
	/// The controls are *removed*, not hidden. A stack view handed a view that
	/// is already in another stack takes it out of that one — so leaving the
	/// last take's monitor in place would have it silently stolen the moment
	/// another take furnished the bar, and the take that comes back would find
	/// its own control gone.
	public func reset() {
		for view in group.arrangedSubviews where view !== more {
			group.removeView(view)
		}
		for view in trailing.arrangedSubviews { trailing.removeView(view) }
		// The far end too, which was missed when it was added: the lane colours
		// stayed in the bar when the take that put them there left, so a
		// project window showed them, and a second take furnishing the bar
		// added a second set beside the first.
		for view in afterClock.arrangedSubviews { afterClock.removeView(view) }
		setUp = nil
		onProject = nil
		onBranch = nil
		onPlayPause = nil
		setOpenHalf(nil)
		setStatus("")
		setProgress(nil)
		setClock(0)
		setPlaying(false)
		setBranch(nil)
		setName("")
		isHidden = false
	}

	// MARK: - The popover behind the name

	@objc private func playTapped() { onPlayPause?() }

	@objc private func showSetUp() {
		guard let content = setUp else { return }
		if let popover, popover.isShown { popover.close(); return }
		let from: NSView = more.isHidden ? capsule : more
		let holder = NSViewController()
		holder.view = content
		let showing = NSPopover()
		showing.contentViewController = holder
		showing.behavior = .transient
		showing.appearance = NSAppearance(named: .darkAqua)
		popover = showing
		showing.show(relativeTo: from.bounds, of: from, preferredEdge: .maxY)
	}

	/// For the tests: the clock's own label, so its width can be measured
	/// without going through the view tree looking for a font.
	var clockForTesting: NSTextField { clock }
	var playForTesting: NSButton { play }
	var capsuleForTesting: DocumentCapsule { capsule }
	var moreForTesting: NSButton { more }
	var groupForTesting: NSStackView { group }
	var dividerForTesting: NSView { divider }
	var statusForTesting: NSTextField { statusLabel }
	var progressForTesting: NSProgressIndicator { progress }
}
