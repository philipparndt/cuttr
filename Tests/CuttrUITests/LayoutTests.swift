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
		for selection: ProjectSelection in [.output, .entry([0]), .entry([1]), .overlay(0), .overlay(1)] {
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
		panel.reload(project(), vocabulary: ComposeDocument.Vocabulary(), selection: .overlay(1))

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

		for selection: ProjectSelection in [.output, .overlay(0), .overlay(1), .entry([1])] {
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
/// The toolbar has three places, and things stay in theirs.
@Suite @MainActor struct ComposeBarTests {

	@Test func whereYouAreIsLeftWhatYouCanDoIsRight() {
		_ = NSApplication.shared
		let bar = ComposeBar()
		bar.setStatus("00:12.345")
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 38),
		                      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
		window.contentView = bar
		bar.frame = NSRect(x: 0, y: 0, width: 1200, height: 38)
		bar.layoutSubtreeIfNeeded()

		func find<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
			view.subviews.flatMap { subview -> [T] in
				((subview as? T).map { [$0] } ?? []) + find(type, in: subview)
			}
		}
		let render = find(NSButton.self, in: bar).first { $0.title == "Render…" }
		let modes = find(NSSegmentedControl.self, in: bar).first
		let clock = find(NSTextField.self, in: bar).first { $0.stringValue == "00:12.345" }

		let renderFrame = try! #require(render).convert(render!.bounds, to: bar)
		let modesFrame = try! #require(modes).convert(modes!.bounds, to: bar)
		let clockFrame = try! #require(clock).convert(clock!.bounds, to: bar)

		#expect(modesFrame.minX < 20, "the modes are not on the left: \(modesFrame)")
		#expect(renderFrame.maxX > bar.bounds.width - 120,
		        "render is not on the right: \(renderFrame)")
		#expect(abs(clockFrame.midX - bar.bounds.midX) < 12,
		        "the clock is not centred: \(clockFrame.midX) against \(bar.bounds.midX)")
		#expect(clockFrame.minX > modesFrame.maxX)
		#expect(clockFrame.maxX < renderFrame.minX)
	}
}

/// The anchors switch belongs to the picture.
@Suite @MainActor struct AnchorSwitchTests {

	@Test func itIsOnlyThereOnThePreview() {
		_ = NSApplication.shared
		let bar = ComposeBar()
		func anchors(in view: NSView) -> NSButton? {
			for subview in view.subviews {
				if let button = subview as? NSButton, button.title == "Anchors" { return button }
				if let found = anchors(in: subview) { return found }
			}
			return nil
		}
		let button = anchors(in: bar)
		#expect(button != nil)
		bar.setMode(0)
		#expect(button?.isHidden == true, "the editor has no picture to put markers on")
		bar.setMode(2)
		#expect(button?.isHidden == false)
		bar.setMode(1)
		#expect(button?.isHidden == true)
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
