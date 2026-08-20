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
/// The traffic lights sit in the middle of the bar.
///
/// AppKit centres them in the *titlebar*, which is 28 points whatever the window
/// does — so under a 52-point bar they sat ten points high while the name and
/// the clock were centred below them, and three dots lining up with nothing are
/// the first thing the eye finds in a window.
///
/// The mechanism is an empty `NSToolbar` in the `.unified` style: macOS gives
/// one a 52-point band and centres the buttons in it. This test outlived the
/// first attempt — setting the frames by hand and setting them again on every
/// resize — which put the buttons in the same place but left the *band* at 32,
/// so anything asking the window how much room the titlebar wanted got the
/// wrong answer. Both pass this; only one of them makes `contentLayoutRect`
/// true, which is why the band is measured here too.
@Suite @MainActor struct TrafficLightTests {

	private func buttons(of window: NSWindow) -> [(NSWindow.ButtonType, CGFloat)] {
		guard let content = window.contentView else { return [] }
		return [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
			.compactMap { kind in
				guard let button = window.standardWindowButton(kind) else { return nil }
				let here = button.convert(button.bounds, to: content)
				return (kind, content.bounds.maxY - here.midY)
			}
	}

	@Test func theySitInTheMiddleOfTheBandInEveryWindow() {
		_ = NSApplication.shared
		let cutting = MainWindowController(document: TakeDocument())
		let composing = ComposeWindowController(document: ComposeDocument())
		defer {
			cutting.window?.close()
			composing.window?.close()
		}
		for controller in [cutting as DocumentEditor, composing as DocumentEditor] {
			let window = controller.windowForTesting
			window.setContentSize(NSSize(width: 1400, height: 900))
			window.makeKeyAndOrderFront(nil)
			window.layoutIfNeeded()
			let placed = buttons(of: window)
			#expect(placed.count == 3, "no traffic lights on \(type(of: controller))")
			for (kind, fromTop) in placed {
				#expect(abs(fromTop - DocumentBar.height / 2) < 1,
				        "\(kind) is \(fromTop) from the top of a \(DocumentBar.height) band")
			}
		}
	}

	/// And the band the window reports is the band the bar fills, which is the
	/// half the hand-placed version got wrong.
	@Test func theBandIsAsTallAsTheBar() {
		_ = NSApplication.shared
		let controller = MainWindowController(document: TakeDocument())
		defer { controller.window?.close() }
		let window = controller.windowForTesting
		guard let content = window.contentView else { return }
		window.setContentSize(NSSize(width: 1400, height: 900))
		window.makeKeyAndOrderFront(nil)
		window.layoutIfNeeded()
		let layout = window.contentLayoutRect
		let band = content.bounds.height - layout.height - layout.origin.y
		#expect(abs(band - DocumentBar.height) < 1,
		        "the window says its titlebar is \(band), the bar is \(DocumentBar.height)")
	}

	/// And they stay put across resizes.
	@Test func theyStayThereWhenTheWindowIsResized() {
		_ = NSApplication.shared
		let controller = MainWindowController(document: TakeDocument())
		defer { controller.window?.close() }
		let window = controller.windowForTesting
		window.makeKeyAndOrderFront(nil)
		for size in [NSSize(width: 1400, height: 900), NSSize(width: 1000, height: 700),
		             NSSize(width: 1600, height: 1000)] {
			window.setContentSize(size)
			window.layoutIfNeeded()
			for (kind, fromTop) in buttons(of: window) {
				#expect(abs(fromTop - DocumentBar.height / 2) < 1,
				        "at \(size) \(kind) drifted to \(fromTop)")
			}
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

		let name = bar.capsuleForTesting.convert(bar.capsuleForTesting.bounds, to: bar)
		let clock = bar.clockForTesting.convert(bar.clockForTesting.bounds, to: bar)
		let status = bar.statusForTesting.convert(bar.statusForTesting.bounds, to: bar)

		// After the traffic lights, because the bar *is* the title bar now: the
		// content runs to the top of the frame and this strip stands in the
		// whole of that band.
		//
		// Clear of them, not at a particular number. The number was 78 while
		// the buttons ended at 79, which is how the capsule came to sit one
		// point over the zoom button; a bar with no window falls back to the
		// constant, and this one has none.
		#expect(name.minX >= DocumentBar.trafficLights - 1,
		        "the name is not clear of the traffic lights: \(name)")
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

	/// The capsule is the way to the other documents; the ellipsis is the way to
	/// this take's files, and it is only there when there are some.
	///
	/// The two used to be one control: a `⌄` glued onto the end of the name with
	/// two spaces, opening the take's files. That was wrong twice over — the
	/// mark sat on the text's baseline rather than the row's centre, and a
	/// document's name opening "what is this document made of" is not what a
	/// name is for. A name opening a list of documents is.
	@Test func theNameIsAWayIntoTheSetUp() {
		let bar = self.bar()
		bar.setName("mia-take-1")
		#expect(bar.moreForTesting.isHidden, "an ellipsis with nothing behind it")
		#expect(bar.capsuleForTesting.projectForTesting == "mia-take-1")

		bar.setUp = TakeSetup()
		#expect(bar.moreForTesting.isHidden == false)
		// The name is the name, whatever is behind it.
		#expect(bar.capsuleForTesting.projectForTesting == "mia-take-1")

		// And the ellipsis is on the row's centre, not on the text's baseline.
		bar.layoutSubtreeIfNeeded()
		let more = bar.moreForTesting.convert(bar.moreForTesting.bounds, to: bar)
		// Within half a point: the bar is an even height and the button is not,
		// so the exact centre lands between two of them. What this is about is
		// the old mark sitting on the *text's* baseline, which was out by six.
		#expect(abs(more.midY - bar.bounds.midY) <= 0.5, "the ellipsis is off-centre: \(more)")
	}

	/// The controls over this document are one group, and the name is a name.
	///
	/// The `…` used to hang off the end of the name as though the two were one
	/// thing. They are not: one says which document, the other is a control over
	/// it. Everything a window adds joins the `…` in a cluster with a rule
	/// between it and the name.
	@Test func theControlsAreAGroupAndTheNameIsNotOneOfThem() {
		let bar = self.bar()
		bar.setName("mia-take-1")
		bar.setUp = TakeSetup()
		let monitor = NSSegmentedControl(labels: ["rec", "cam", "both"],
		                                 trackingMode: .selectOne, target: nil, action: nil)
		bar.addLeading(monitor)
		bar.layoutSubtreeIfNeeded()

		// Everything the window added, and the `…`, in one stack.
		#expect(bar.groupForTesting.arrangedSubviews.contains(monitor))
		#expect(bar.groupForTesting.arrangedSubviews.contains(bar.moreForTesting))
		// The `…` is last: it is the way to *more* of the same.
		#expect(bar.groupForTesting.arrangedSubviews.last === bar.moreForTesting)

		let name = bar.capsuleForTesting.convert(bar.capsuleForTesting.bounds, to: bar)
		let rule = bar.dividerForTesting.convert(bar.dividerForTesting.bounds, to: bar)
		let group = bar.groupForTesting.convert(bar.groupForTesting.bounds, to: bar)
		let clock = bar.clockForTesting.convert(bar.clockForTesting.bounds, to: bar)

		// Name, rule, group, clock — in that order, with the rule between the
		// name and the group and clear air either side of it.
		#expect(name.maxX < rule.minX)
		#expect(rule.maxX < group.minX)
		#expect(group.maxX < clock.minX)
		#expect(rule.minX - name.maxX >= 10, "the rule is crowding the name")
		#expect(group.minX - rule.maxX >= 10, "the rule is crowding the group")
		#expect(bar.dividerForTesting.isHidden == false)

		// And the spacing inside the group is even.
		let inside = bar.groupForTesting.arrangedSubviews.map {
			$0.convert($0.bounds, to: bar)
		}.sorted { $0.minX < $1.minX }
		let gaps = zip(inside, inside.dropFirst()).map { $1.minX - $0.maxX }
		#expect(Set(gaps.map { ($0 * 10).rounded() }).count <= 1,
		        "ragged spacing inside the group: \(gaps)")
	}

	/// A window with nothing to put there gets a name and a clock, and no
	/// furniture between them.
	@Test func anEmptyGroupDrawsNoRule() {
		let bar = self.bar()
		bar.setName("mia-take-1")
		bar.layoutSubtreeIfNeeded()
		#expect(bar.dividerForTesting.isHidden, "a rule with nothing on the far side of it")
		#expect(bar.groupForTesting.isHidden)
	}

	/// Rolling the tape, from the bar that says where the tape is.
	@Test func theBarPlaysAndSaysWhichWayRoundItIs() {
		let bar = self.bar()
		var asked = 0
		bar.onPlayPause = { asked += 1 }
		bar.playForTesting.performClick(nil)
		#expect(asked == 1)

		bar.setPlaying(true)
		let playing = bar.playForTesting.image
		bar.setPlaying(false)
		#expect(playing != bar.playForTesting.image, "the button looks the same either way")

		// Beside the clock, and the clock is still what is centred.
		bar.layoutSubtreeIfNeeded()
		let play = bar.playForTesting.convert(bar.playForTesting.bounds, to: bar)
		let clock = bar.clockForTesting.convert(bar.clockForTesting.bounds, to: bar)
		#expect(play.maxX <= clock.minX)
		#expect(abs(clock.midX - bar.bounds.midX) < 12,
		        "the play button moved the clock: \(clock.midX) against \(bar.bounds.midX)")
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


/// One pane at a time, chosen from the rail, and nothing arguing about a size.
///
/// This replaces the suite that drove the four folding panes down the side of
/// the cutting window. Those panes are gone: the rail chooses which of the four
/// has the column, and exactly one of them is in the view hierarchy at a time.
///
/// The rule the old suite was defending is the one that matters and it is
/// asserted here directly. Two *required* constraints about one dimension is a
/// system autolayout cannot solve; what it does instead is break one, log
/// `layout constraints are not satisfiable`, and go round the display cycle
/// again looking for an arrangement that works — and through several nested
/// split views that is a great many passes for one click. The four-pane version
/// had a required floor from the window and a required folded height from the
/// pane, and could not help but have both. One pane in the hierarchy cannot.
@Suite @MainActor struct RailPaneTests {

	private func opened() -> (MainWindowController, NSWindow) {
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
		let window = controller.windowForTesting
		window.setContentSize(NSSize(width: 1500, height: 1100))
		window.layoutIfNeeded()
		return (controller, window)
	}

	/// Four places to be, and clicking one puts you there.
	@Test func theRailOpensEachPaneInTurn() {
		let (controller, window) = opened()
		let rail = controller.railForTesting
		#expect(rail.countForTesting == 4)
		var seen: [ObjectIdentifier] = []
		for index in 0..<4 {
			rail.clickForTesting(index)
			window.layoutIfNeeded()
			#expect(rail.selected == index)
			let showing = try! #require(controller.panesForTesting?.current)
			seen.append(ObjectIdentifier(showing))
			#expect(showing.frame.height > 40,
			        "pane \(index) came up \(showing.frame.height) tall")
		}
		#expect(Set(seen).count == 4, "the rail showed the same pane twice")
		window.close()
	}

	/// Only one of them is in the window, at every size the window goes to.
	///
	/// This is the whole reason the arrangement changed. A pane that is not
	/// showing is not laid out, not measured and not negotiated with, so there
	/// is exactly one opinion about the height of that column.
	@Test func onlyOnePaneIsEverInTheWindow() {
		let (controller, window) = opened()
		let rail = controller.railForTesting
		func boxes(in view: NSView) -> [PaneBox] {
			view.subviews.flatMap { sub -> [PaneBox] in
				((sub as? PaneBox).map { [$0] } ?? []) + boxes(in: sub)
			}
		}
		for height in [1100.0, 900.0, 740.0, 640.0, window.minSize.height] {
			window.setContentSize(NSSize(width: 1500, height: height))
			window.layoutIfNeeded()
			for index in 0..<4 {
				rail.clickForTesting(index)
				window.layoutIfNeeded()
				let found = boxes(in: window.contentView!)
				#expect(found.count == 1,
				        "at \(height), pane \(index): \(found.count) panes in the window")
			}
		}
		window.close()
	}

	/// And nothing says a required thing about that column's height twice.
	@Test func onlyOneRequiredThingIsSaidAboutThePanesHeight() {
		let (controller, window) = opened()
		let rail = controller.railForTesting
		for index in 0..<4 {
			rail.clickForTesting(index)
			window.layoutIfNeeded()
			guard let stack = controller.panesForTesting else { continue }
			let mine = stack.constraints.filter { ($0.firstItem as? NSView) === stack }
			let theirs = stack.superview?.constraints.filter {
				($0.firstItem as? NSView) === stack || ($0.secondItem as? NSView) === stack
			} ?? []
			let said = (mine + theirs).filter {
				$0.priority == .required && $0.firstAttribute == .height && $0.secondItem == nil
			}
			#expect(said.count <= 1, "pane \(index) has \(said.count) required heights: \(said)")
		}
		window.close()
	}

	/// Switching panes twice over settles: the second layout is the first one.
	@Test func switchingPanesSettles() {
		let (controller, window) = opened()
		let rail = controller.railForTesting
		for index in [0, 2, 0] {
			rail.clickForTesting(index)
			window.layoutIfNeeded()
		}
		let first = controller.panesForTesting?.current?.frame
		window.contentView?.needsLayout = true
		window.layoutIfNeeded()
		#expect(controller.panesForTesting?.current?.frame == first,
		        "the pane moved on its own")
		window.close()
	}

	/// The rail is in the same place and the same width in both windows, which
	/// is the point of there being one of them.
	@Test func bothWindowsPutTheRailInTheSamePlace() {
		_ = NSApplication.shared
		let cutting = MainWindowController(document: TakeDocument())
		let composing = ComposeWindowController(document: ComposeDocument())
		var frames: [NSRect] = []
		for (controller, rail) in [(cutting as DocumentEditor, cutting.railForTesting),
		                           (composing as DocumentEditor, composing.railForTesting)] {
			let window = controller.windowForTesting
			guard let content = window.contentView else { continue }
			window.setContentSize(NSSize(width: 1400, height: 900))
			window.layoutIfNeeded()
			frames.append(rail.convert(rail.bounds, to: content))
		}
		#expect(frames.count == 2)
		#expect(frames[0] == frames[1], "the rails are at \(frames)")
		#expect(frames[0].minX == 0, "the rail is not at the left edge: \(frames[0])")
		#expect(frames[0].width == Rail.width)
		cutting.window?.close()
		composing.window?.close()
	}
}
