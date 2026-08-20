import AppKit
import CuttrCompose
import CuttrKit
import Testing
@testable import CuttrUI

/// The panel has to stand still.
///
/// Selecting a different thing changes what the form says, not where it is.
/// Every key starts at the same place down the left edge, and the form does not
/// move sideways because one selection happens to have a wider control in it —
/// which it did, because a picture spanning both columns handed its width to
/// the column of keys to share.
@Suite @MainActor struct LayoutTests {

	private func project() -> Project {
		Project(
			timeline: [
				TimelineEntry(clip: ClipReference("intro")),
				TimelineEntry(group: "middle", entries: [TimelineEntry(clip: ClipReference("demo"))]),
			],
			overlays: [
				Overlay(kind: .text("A caption long enough to matter", style: nil),
				        span: .clips(from: ClipReference("intro"), to: ClipReference("intro"))),
				Overlay(kind: .spinner(Spinner(words: [SpinnerWord("one")])),
				        spans: [.times(from: 0, to: 4), .times(from: 8, to: 12)],
				        anchor: "mia-eye"),
			])
	}

	private func keyOrigins(_ panel: PropertiesPanel) -> [CGFloat] {
		func labels(in view: NSView) -> [NSTextField] {
			view.subviews.flatMap { subview -> [NSTextField] in
				((subview as? NSTextField).map { [$0] } ?? []) + labels(in: subview)
			}
		}
		return labels(in: panel)
			.filter { !$0.isEditable && $0.font == Theme.mono && !$0.stringValue.isEmpty }
			.map { $0.convert($0.bounds, to: panel).minX }
	}

	@Test func everySelectionPutsTheKeysInTheSamePlace() {
		_ = NSApplication.shared
		let panel = PropertiesPanel()
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 900),
		                      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
		window.contentView = panel

		let project = self.project()
		var seen: Set<CGFloat> = []
		for selection: ProjectSelection in [.output, .entry([0]), .entry([1]), .overlay(.project(0)), .overlay(.project(1))] {
			panel.reload(project, vocabulary: ComposeDocument.Vocabulary(), selection: selection)
			panel.layoutSubtreeIfNeeded()
			let origins = keyOrigins(panel)
			#expect(!origins.isEmpty, "no keys for \(selection)")
			// Every key in one form starts at the same x…
			#expect(Set(origins).count == 1, "ragged keys for \(selection): \(Set(origins).sorted())")
			seen.formUnion(origins)
		}
		// …and it is the same x in every form.
		#expect(seen.count == 1, "the form moves between selections: \(seen.sorted())")
	}

	/// The form fits whatever width the pane has.
	///
	/// A control that insists on its ideal width in a pane narrower than that is
	/// how a form comes to need a horizontal scrollbar — and then the scrollbar
	/// takes height, which changes the layout, which is the flicker.
	@Test func theFormFitsEveryWidthItIsGiven() {
		_ = NSApplication.shared
		let panel = PropertiesPanel()
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 900),
		                      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
		window.contentView = panel
		panel.reload(project(), vocabulary: ComposeDocument.Vocabulary(), selection: .overlay(.project(1)))

		for width in [300.0, 340.0, 420.0, 560.0, 700.0] {
			window.setContentSize(NSSize(width: width, height: 900))
			panel.layoutSubtreeIfNeeded()
			for row in rows(of: panel) {
				#expect(row.frame.width <= width + 0.5,
				        "a row is \(row.frame.width) wide in a \(width) pane")
			}
		}
	}

	/// Laying out twice must change nothing.
	///
	/// Anything that answers differently the second time is a loop, and a loop
	/// is what the window flickering actually is: two views taking turns to be
	/// right about a size.
	@Test func layingOutTwiceSettles() {
		_ = NSApplication.shared
		let panel = PropertiesPanel()
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 820),
		                      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
		window.contentView = panel

		for selection: ProjectSelection in [.output, .overlay(.project(0)), .overlay(.project(1)), .entry([1])] {
			panel.reload(project(), vocabulary: ComposeDocument.Vocabulary(), selection: selection)
			panel.layoutSubtreeIfNeeded()
			let first = geometry(of: panel)
			panel.needsLayout = true
			panel.layoutSubtreeIfNeeded()
			#expect(geometry(of: panel) == first, "the layout moved on its own for \(selection)")
		}
	}

	/// Every row of the form.
	private func rows(of panel: PropertiesPanel) -> [NSView] {
		func stacks(in view: NSView) -> [NSStackView] {
			view.subviews.flatMap { subview -> [NSStackView] in
				((subview as? NSStackView).map { [$0] } ?? []) + stacks(in: subview)
			}
		}
		guard let form = stacks(in: panel).first(where: { $0.orientation == .vertical }) else { return [] }
		return form.arrangedSubviews
	}

	private func geometry(of view: NSView) -> [String] {
		view.subviews.flatMap { subview in
			["\(type(of: subview)) \(NSStringFromRect(subview.frame))"] + geometry(of: subview)
		}
	}
}
/// One bar, both windows, and the clock always in it.
///
/// This replaces two suites: one that asserted the mode buttons were on the
/// left of the composing window's bar, and one that asserted a checkbox for
/// the anchor markers was in it at all. Neither is true now on purpose — the
/// modes are on their way to the rail and the markers switch is over the
/// picture it draws on — and what is asserted instead is the arrangement that
/// is meant to be the same in both windows.
@Suite @MainActor struct DocumentBarTests {

	private func bar(_ width: CGFloat = 1200) -> DocumentBar {
		_ = NSApplication.shared
		let bar = DocumentBar()
		let window = NSWindow(
			contentRect: NSRect(x: 0, y: 0, width: width, height: DocumentBar.height),
			styleMask: [.titled, .resizable], backing: .buffered, defer: false)
		window.contentView = bar
		bar.frame = NSRect(x: 0, y: 0, width: width, height: DocumentBar.height)
		bar.layoutSubtreeIfNeeded()
		return bar
	}

	/// The name on the left, the clock in the middle, what happened on the right.
	@Test func theDocumentIsLeftTheClockIsMiddleTheNewsIsRight() {
		let bar = self.bar()
		bar.setName("mia-take-1")
		bar.setClock(12.345)
		bar.setStatus("saved")
		bar.layoutSubtreeIfNeeded()

		let name = bar.nameForTesting.convert(bar.nameForTesting.bounds, to: bar)
		let clock = bar.clockForTesting.convert(bar.clockForTesting.bounds, to: bar)
		let status = bar.statusForTesting.convert(bar.statusForTesting.bounds, to: bar)

		#expect(name.minX < 20, "the name is not on the left: \(name)")
		#expect(abs(clock.midX - bar.bounds.midX) < 12,
		        "the clock is not centred: \(clock.midX) against \(bar.bounds.midX)")
		#expect(status.maxX > bar.bounds.width - 140, "the news is not on the right: \(status)")
		#expect(name.maxX < clock.minX)
		#expect(clock.maxX < status.maxX)
	}

	/// The clock does not move, whatever it says.
	///
	/// Tabular figures and a fixed box: a label that sizes itself to its text
	/// shifts the whole group sideways between `09.900` and `10.000`, and this
	/// is the number somebody watches while the tape rolls.
	@Test func theClockKeepsItsPlaceAndItsWidth() {
		let bar = self.bar()
		var frames: [NSRect] = []
		for time in [0.0, 9.9, 10.0, 59.999, 61.5, 3599.0, 3600.0] {
			bar.setClock(time)
			bar.layoutSubtreeIfNeeded()
			frames.append(bar.clockForTesting.convert(bar.clockForTesting.bounds, to: bar))
		}
		#expect(Set(frames.map(\.width)).count == 1,
		        "the clock changed width: \(frames.map(\.width))")
		#expect(Set(frames.map(\.minX)).count == 1,
		        "the clock moved: \(frames.map(\.minX))")
	}

	/// A long name cannot push the clock off centre, and a long status cannot
	/// either.
	@Test func nothingElseMovesTheClock() {
		let bar = self.bar()
		bar.setName("a")
		bar.setStatus("")
		bar.layoutSubtreeIfNeeded()
		let quiet = bar.clockForTesting.convert(bar.clockForTesting.bounds, to: bar)

		bar.setName("an-extremely-long-project-name-somebody-actually-typed")
		bar.setStatus(String(repeating: "and then this happened. ", count: 8))
		bar.layoutSubtreeIfNeeded()
		let busy = bar.clockForTesting.convert(bar.clockForTesting.bounds, to: bar)
		#expect(abs(quiet.minX - busy.minX) < 0.5, "the clock moved from \(quiet) to \(busy)")
	}

	/// The progress bar arrives *under* the status rather than beside it, so
	/// nothing moves when it appears.
	@Test func progressArrivesWithoutMovingAnything() {
		let bar = self.bar()
		bar.setStatus("exporting…")
		bar.layoutSubtreeIfNeeded()
		let before = bar.statusForTesting.convert(bar.statusForTesting.bounds, to: bar)
		#expect(bar.progressForTesting.isHidden)

		bar.setProgress(0.4)
		bar.layoutSubtreeIfNeeded()
		let after = bar.statusForTesting.convert(bar.statusForTesting.bounds, to: bar)
		#expect(bar.progressForTesting.isHidden == false)
		#expect(before == after, "the status moved: \(before) became \(after)")

		// Under it: the bar is not flipped, so lower on screen is a smaller y.
		let under = bar.progressForTesting.convert(bar.progressForTesting.bounds, to: bar)
		#expect(under.maxY <= after.minY + 0.5, "the progress is not under the status")
		#expect(abs(under.maxX - after.maxX) < 4, "the progress is not lined up with it")

		bar.setProgress(nil)
		#expect(bar.progressForTesting.isHidden)
	}

	/// The setting-up controls are behind the name, and the name only says so
	/// when there is something there.
	@Test func theNameIsAWayIntoTheSetUp() {
		let bar = self.bar()
		bar.setName("mia-take-1")
		#expect(bar.nameForTesting.isEnabled == false)
		#expect(bar.nameForTesting.attributedTitle.string == "mia-take-1")

		bar.setUp = TakeSetup()
		#expect(bar.nameForTesting.isEnabled)
		#expect(bar.nameForTesting.attributedTitle.string.hasPrefix("mia-take-1"))
		#expect(bar.nameForTesting.attributedTitle.string != "mia-take-1")
	}
}

/// The file fragment is a teaching pane, not a working one.
@Suite @MainActor struct WritesPaneTests {

	@Test func itStartsFoldedAndOpensWhenAsked() {
		_ = NSApplication.shared
		let inspector = ProjectInspector()
		inspector.reload(Project(timeline: [TimelineEntry(clip: ClipReference("intro"))]),
		                 vocabulary: ComposeDocument.Vocabulary())
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
		                      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
		window.contentView = inspector
		inspector.layoutSubtreeIfNeeded()

		func text(in view: NSView) -> NSTextView? {
			for subview in view.subviews {
				if let found = subview as? NSTextView { return found }
				if let found = text(in: subview) { return found }
			}
			return nil
		}
		func button(in view: NSView) -> NSButton? {
			for subview in view.subviews {
				if let found = subview as? NSButton,
				   found.attributedTitle.string.contains("WHAT THIS WRITES") { return found }
				if let found = button(in: subview) { return found }
			}
			return nil
		}

		let fragment = text(in: inspector)
		#expect(fragment != nil)
		let folded = fragment?.enclosingScrollView?.frame.height ?? 0
		#expect(folded < 4, "the fragment pane is open to begin with: \(folded)")

		button(in: inspector)?.performClick(nil)
		inspector.layoutSubtreeIfNeeded()
		#expect((fragment?.enclosingScrollView?.frame.height ?? 0) > 100)
	}
}

/// Pictures keep their own shape.
///
/// Every symbol in this program was drawn into a rectangle picked by eye, and
/// a folder is not 17 by 16.
@Suite @MainActor struct SymbolFittingTests {

	@Test func aWidePictureFitsTheSlotWithoutStretching() {
		let slot = NSRect(x: 10, y: 20, width: 20, height: 10)
		let fitted = Theme.fit(NSSize(width: 40, height: 10), in: slot)
		#expect(fitted.width == 20)
		#expect(fitted.height == 5)
		// And it sits in the middle of the room it was given.
		#expect(fitted.midX == slot.midX)
		#expect(fitted.midY == slot.midY)
	}

	@Test func aTallPictureFitsTheOtherWay() {
		let fitted = Theme.fit(NSSize(width: 20, height: 80),
		                       in: NSRect(x: 0, y: 0, width: 20, height: 20))
		#expect(fitted.height == 20)
		#expect(fitted.width == 5)
	}

	/// A small picture is left the size it is. Two states of one control —
	/// `chevron.right` is tall and narrow, `chevron.down` wide and short — must
	/// not come out at two sizes because each filled the slot its own way.
	@Test func aSmallPictureIsNotBlownUp() {
		let slot = NSRect(x: 0, y: 0, width: 20, height: 20)
		let narrow = Theme.fit(NSSize(width: 5, height: 9), in: slot)
		let wide = Theme.fit(NSSize(width: 9, height: 5), in: slot)
		#expect(narrow.size == NSSize(width: 5, height: 9))
		#expect(wide.size == NSSize(width: 9, height: 5))
		#expect(narrow.midX == slot.midX && wide.midY == slot.midY)
	}

	/// A picture with no size cannot be fitted, and stretching nothing is not
	/// an improvement — it gets the slot.
	@Test func nothingIsLeftAlone() {
		let slot = NSRect(x: 1, y: 2, width: 3, height: 4)
		#expect(Theme.fit(.zero, in: slot) == slot)
	}

	/// The symbols this program actually draws are not square, which is the
	/// whole reason any of this is here.
	@Test func theSymbolsInUseAreNotSquare() {
		let folder = Theme.symbol(.section, size: 13)
		#expect(folder != nil)
		if let folder {
			let slot = NSRect(x: 0, y: 0, width: 17, height: 16)
			let fitted = Theme.fit(folder.size, in: slot)
			#expect(abs(fitted.width / fitted.height - folder.size.width / folder.size.height) < 0.001)
		}
	}
}

/// A still keeps the numbers the footage has.
///
/// The image generator tags its frames `CoreMedia709`, and AppKit does what a
/// tag asks for: on a flat grey the file says 125 and the panel drew 136.
@Suite @MainActor struct PosterColourTests {

	@Test func aStillIsShownWithItsOwnNumbers() throws {
		// A frame whose bytes *are* 125, labelled the way the generator labels
		// one. Built from the bytes rather than filled with a colour, because a
		// fill is itself a conversion and this test is about conversions.
		// The space the image generator actually hands back, which is not the
		// same as `itur_709` and does not move the numbers the same way.
		let space = try #require(CGColorSpace(name: "kCGColorSpaceCoreMedia709" as CFString))
		let bytes = [UInt8](repeating: 125, count: 4 * 4 * 4)
		let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
		let frame = try #require(CGImage(
			width: 4, height: 4, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 16,
			space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
			provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))

		/// What lands on an sRGB screen.
		func shown(_ image: CGImage) -> UInt8 {
			let screen = CGColorSpace(name: CGColorSpace.sRGB)!
			let out = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8,
			                    bytesPerRow: 16, space: screen,
			                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
			out.draw(image, in: CGRect(x: 0, y: 0, width: 4, height: 4))
			return out.data!.assumingMemoryBound(to: UInt8.self)[0]
		}

		// Left as it is, the tag moves it on the way to the screen.
		let asTagged = shown(frame)
		#expect(asTagged > 125, "the tag should lift it; it drew \(asTagged)")
		// Re-labelled, the same bytes arrive as themselves.
		#expect(shown(ComposeWindowController.asShown(frame)) == 125)
	}
}

/// A pane that folds away to its heading.
@Suite @MainActor struct FoldingPaneTests {

	private func pane() -> FoldingPane {
		_ = NSApplication.shared
		let content = NSView()
		content.translatesAutoresizingMaskIntoConstraints = false
		content.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
		return FoldingPane("clips", content: content)
	}

	@Test func foldingLeavesTheHeadingAndNothingElse() {
		let pane = self.pane()
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400),
		                      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
		window.contentView = pane
		pane.layoutSubtreeIfNeeded()
		#expect(pane.frame.height > 120)
		#expect(pane.content.isHidden == false)

		pane.fold(true)
		pane.layoutSubtreeIfNeeded()
		#expect(pane.content.isHidden)
		#expect(pane.frame.height == FoldingPane.headHeight)

		pane.fold(false)
		pane.layoutSubtreeIfNeeded()
		#expect(pane.content.isHidden == false)
		#expect(pane.frame.height > 120)
	}

	/// A click on the heading folds it; a click in the content does not.
	@Test func theHeadingIsWhatFolds() {
		let pane = self.pane()
		pane.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
		pane.layoutSubtreeIfNeeded()
		var told: [Bool] = []
		pane.onFold = { told.append($0) }

		func click(at point: NSPoint) -> NSEvent {
			NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
			                   timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
			                   clickCount: 1, pressure: 1)!
		}
		// The heading is at the top of the pane, which in AppKit's coordinates
		// is the highest y.
		pane.mouseDown(with: click(at: NSPoint(x: 40, y: pane.bounds.maxY - 8)))
		#expect(told == [true])
		pane.mouseDown(with: click(at: NSPoint(x: 40, y: 40)))
		#expect(told == [true], "a click in the content should not fold it")
	}
}

/// Every sheet opens at a size somebody can work in.
///
/// A window whose `contentViewController` is set takes its size from the view's
/// fitting size, and a view laid out with edge constraints alone has none worth
/// having — the meme panel came up as a column one search field wide.
@Suite @MainActor struct SheetSizeTests {

	@Test func theSheetsAreNotSlivers() {
		_ = NSApplication.shared
		let controllers: [(String, NSViewController)] = [
			("meme", MemePanel(download: { _ in "" }, onAdded: { _ in })),
			("settings", SettingsSheet()),
			("endpoint", EndpointPicker(catalogue: EndpointCatalogue(entries: []),
			                            current: "", onChoose: { _ in })),
			("trim", TrimDialog(clip: "clip", source: .media(video: nil, audio: nil, offset: 0),
			                    span: (start: 0, end: 4), trim: (0, 0), step: 1.0 / 25,
			                    onDone: { _ in })),
		]
		for (name, controller) in controllers {
			controller.loadView()
			let wanted = controller.preferredContentSize
			#expect(wanted.width >= 400, "\(name) wants to be \(wanted.width) wide")
			#expect(wanted.height >= 200, "\(name) wants to be \(wanted.height) tall")
			// And the view can actually reach that size, rather than being held
			// narrow by something inside it.
			let fitting = controller.view.fittingSize
			#expect(fitting.width <= wanted.width + 1,
			        "\(name) will not fit in the size it asks for: \(fitting)")
		}
	}
}

/// The controls that come back in full screen.
@Suite @MainActor struct PlaybackControlsTests {

	private func controls() -> PlaybackControls {
		_ = NSApplication.shared
		let bar = PlaybackControls(frame: NSRect(x: 0, y: 0, width: 1000, height: 76))
		bar.duration = 100
		bar.playhead = 25
		return bar
	}

	/// Invisible until something happens, and gone again after it stops.
	@Test func itIsInvisibleUntilTheMouseMoves() {
		let bar = controls()
		#expect(bar.alphaValue == 0)
		bar.wake(for: 0.05)
		#expect(bar.alphaValue == 1)
		bar.sleep()
		#expect(bar.alphaValue == 0)
	}

	/// A click on the left is play/pause; anywhere on the track is a scrub to
	/// that moment.
	@Test func theTrackScrubsAndTheCornerPlays() {
		let bar = controls()
		var played = 0
		var scrubbed: [Double] = []
		bar.onPlayPause = { played += 1 }
		bar.onScrub = { scrubbed.append($0) }

		func click(at x: CGFloat) -> NSEvent {
			NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: x, y: 38),
			                   modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
			                   eventNumber: 0, clickCount: 1, pressure: 1)!
		}
		bar.mouseDown(with: click(at: 40))
		#expect(played == 1)
		#expect(scrubbed.isEmpty)

		// The track runs from 92 to width − 150; halfway along it is halfway
		// through the programme.
		let middle: CGFloat = 92 + (1000 - 92 - 150) / 2
		bar.mouseDown(with: click(at: middle))
		bar.mouseUp(with: click(at: middle))
		#expect(scrubbed.count == 1)
		#expect(abs((scrubbed.first ?? 0) - 50) < 1)
	}

	/// And a scrub is clamped to the programme rather than running off it.
	@Test func aScrubStaysInsideTheProgramme() {
		let bar = controls()
		#expect(bar.timeForTesting(at: CGFloat(-500)) == 0)
		#expect(bar.timeForTesting(at: CGFloat(5000)) == 100)
	}
}


/// Collapsing a pane in the cutting window, and everything else staying put.
///
/// A folded pane is exactly its heading, and it says so with a *required*
/// constraint so that a split view cannot hand it room it does not want. The
/// window used to state a required floor on the same panes — how short each may
/// be squeezed — and the two cannot both hold: `height >= 96` and `height == 24`
/// is a system autolayout cannot solve. What it does instead is break one, log
/// `layout constraints are not satisfiable`, and go round the display cycle
/// again looking for an arrangement that works. Through four nested split views
/// and the scroll views inside them that is a great many passes for one click,
/// and AppKit raises out of the layout pass when a window has had more of them
/// than it has views.
///
/// Both of the things somebody sees when that happens are asserted here: a pane
/// that will not fold because a floor beat it, and panes that come back shorter
/// than they were because a constraint that got broken stays broken.
@Suite @MainActor struct CollapsingPanesTests {

	private func opened() -> (MainWindowController, NSWindow, [FoldingPane]) {
		_ = NSApplication.shared
		var clips: [Clip] = []
		for i in 0..<30 {
			clips.append(Clip(slug: "clip-\(i)", name: "clip number \(i)",
			                  start: Double(i) * 3, end: Double(i) * 3 + 2.5))
		}
		var take = Take(video: "a.mov", clips: clips)
		for i in 0..<6 {
			_ = take.add(Anchor(name: "anchor-\(i)", from: Double(i), to: Double(i) + 5,
			                    markedAt: Double(i), point: CGPoint(x: 0.5, y: 0.5)))
		}
		let controller = MainWindowController(document: TakeDocument(take: take))
		let window = controller.window!
		window.setContentSize(NSSize(width: 1500, height: 1100))
		window.layoutIfNeeded()

		func panes(in view: NSView) -> [FoldingPane] {
			view.subviews.flatMap { sub -> [FoldingPane] in
				((sub as? FoldingPane).map { [$0] } ?? []) + panes(in: sub)
			}
		}
		return (controller, window, panes(in: window.contentView!))
	}

	@Test func everyPaneCanBeCollapsedToItsHeading() {
		let (_, window, panes) = opened()
		#expect(panes.count == 4)
		for height in [1100.0, 900.0, 740.0, 640.0, window.minSize.height] {
			window.setContentSize(NSSize(width: 1500, height: height))
			window.layoutIfNeeded()
			for (index, pane) in panes.enumerated() {
				pane.fold(true)
				window.layoutIfNeeded()
				#expect(pane.frame.height == FoldingPane.headHeight,
				        "at \(height), pane \(index) folded to \(pane.frame.height)")
				pane.fold(false)
				window.layoutIfNeeded()
			}
		}
		window.close()
	}

	/// At every height the column is worth having, because the sizes that show
	/// this are the ones where the panes are already near their floors — which
	/// is most of them, on a laptop screen.
	///
	/// Not at the very smallest the window goes to. There the column has only a
	/// few points of slack over the sum of the floors, and which pane gets them
	/// is a tie: a split view remembers a dragged divider with a constraint of
	/// its own at priority 250, and the panes ask for their preferred heights at
	/// the same 250. A tie is decided by whatever the engine did last, so it
	/// comes out differently after a fold. That is untidy and it long predates
	/// this; it is not what crashed, and raising the panes above the split
	/// view would stop a dragged divider from staying where it was put.
	@Test func thePanesComeBackTheSizeTheyWere() {
		let (_, window, panes) = opened()
		for height in [1100.0, 980.0, 900.0, 820.0, 740.0, 680.0, 640.0] {
			window.setContentSize(NSSize(width: 1500, height: height))
			window.layoutIfNeeded()
			let before = panes.map(\.frame.height)
			for pane in panes {
				pane.fold(true)
				window.layoutIfNeeded()
				pane.fold(false)
				window.layoutIfNeeded()
			}
			let after = panes.map(\.frame.height)
			// Within a few points, not to the point. Which pane gets the last
			// of the slack is a tie — a split view remembers a dragged divider
			// at priority 250 and the panes ask for their preferred heights at
			// the same 250 — so a fold can move a point or two between
			// neighbours. What this is looking for is a pane that lost its
			// room: the bug shrank one by 52 points, and left another at its
			// heading.
			let moved = zip(before, after).map { abs($0 - $1) }.max() ?? 0
			#expect(moved <= 4,
			        "at \(height) the column shifted by \(moved): \(before) became \(after)")
		}
		window.close()
	}

	/// The rule underneath both of those, stated directly.
	///
	/// Autolayout has no opinion about *where* two contradictory required
	/// constraints came from, so the only way to be sure they can never
	/// contradict is for there to be one of them. A second required word about a
	/// pane's height — from the window, from a split view delegate, from
	/// anywhere — is the bug coming back, whether or not it happens to be
	/// satisfiable on the day it is added.
	@Test func onlyOneRequiredThingIsSaidAboutAPanesHeight() {
		let (_, window, panes) = opened()
		func requiredHeights(on pane: FoldingPane) -> [NSLayoutConstraint] {
			let mine = pane.constraints.filter { ($0.firstItem as? NSView) === pane }
			let theirs = pane.superview?.constraints.filter {
				($0.firstItem as? NSView) === pane || ($0.secondItem as? NSView) === pane
			} ?? []
			// A split view's own stacking and edge constraints are how the
			// column is assembled and are not an opinion about one pane's
			// height; what is being counted is height stated as a size.
			return (mine + theirs).filter {
				$0.priority == .required && $0.firstAttribute == .height
					&& $0.secondItem == nil
			}
		}
		for state in [false, true, false] {
			for pane in panes { pane.fold(state) }
			window.layoutIfNeeded()
			for (index, pane) in panes.enumerated() {
				let said = requiredHeights(on: pane)
				#expect(said.count <= 1,
				        "pane \(index) \(state ? "folded" : "open") has \(said.count) required heights: \(said)")
			}
		}
		window.close()
	}
}
