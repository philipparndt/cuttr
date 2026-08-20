import AppKit
import Testing
@testable import CuttrCompose
@testable import CuttrUI

/// Nothing on the capsule or in the panel under it draws over anything else.
///
/// Overlap is a number, so these hold the number. A document's name is somebody
/// else's data and can be any length, so every case here is measured at three
/// window widths with three lengths of name.
@MainActor @Suite struct CapsuleOverlapTests {

	private static let names = [
		"dingsda",
		"Lilly, Annelie, Chris 1",
		"Lilly, Annelie, Chris and the very long afternoon of the second take 2",
	]
	private static let widths: [CGFloat] = [900, 1200, 1600]

	private func bar(in window: NSWindow?) -> DocumentBar? {
		func find(_ view: NSView) -> DocumentBar? {
			if let bar = view as? DocumentBar { return bar }
			for sub in view.subviews { if let hit = find(sub) { return hit } }
			return nil
		}
		return window?.contentView.flatMap(find)
	}

	/// The name stops before the divider, and the branch stops before the
	/// shortcut.
	///
	/// It did neither. The divider was `maxX - branchWidth` with no floor, and
	/// the two strings were drawn from a fixed origin with no limit — so at 900
	/// points, this program's own minimum window width, the divider landed at
	/// x = 1, the project half's rectangle came out with a *negative* width, and
	/// "dingsda" was drawn 62 points past the divider straight over the branch
	/// name, which was itself drawn from x = −6. A 23-character name overran by
	/// 141 points, and a 51-character one by 189.
	@Test func theHalvesOfTheCapsuleNeverDrawOverEachOther() throws {
		_ = NSApplication.shared
		let project = ComposeWindowController(document: ComposeDocument())
		let window = project.windowForTesting
		let bar = try #require(self.bar(in: window))
		let capsule = bar.capsuleForTesting

		for name in Self.names {
			bar.setName(name)
			bar.setBranch("feature/document-switcher")
			for width in Self.widths {
				window.setContentSize(NSSize(width: width, height: 700))
				window.layoutIfNeeded()
				let spans = capsule.spans
				let branch = try #require(spans.branch)
				let where_ = "\(name.count) chars at \(width) points"

				// Each string inside its own span, and the spans in order.
				let over = "\(where_): the name may draw to \(spans.project.upperBound), "
					+ "the branch starts at \(branch.lowerBound)"
				#expect(spans.project.upperBound <= branch.lowerBound, .init(rawValue: over))
				let onto = "\(where_): the branch may draw to \(branch.upperBound), "
					+ "the shortcut starts at \(spans.hint.lowerBound)"
				#expect(branch.upperBound <= spans.hint.lowerBound, .init(rawValue: onto))
				// And all of it inside the capsule.
				#expect(spans.project.lowerBound >= 0,
				        "\(where_): the name starts at \(spans.project.lowerBound)")
				let past = "\(where_): the shortcut ends at \(spans.hint.upperBound), "
					+ "the capsule at \(capsule.bounds.maxX)"
				#expect(spans.hint.upperBound <= capsule.bounds.maxX, .init(rawValue: past))

				// Neither half's rectangle may be empty or backwards — the
				// popover is anchored to one of them, and an empty anchor is a
				// panel that never appears.
				#expect(capsule.projectRect.width > 0 && capsule.projectRect.height > 0,
				        "\(where_): the project half is \(capsule.projectRect)")
				#expect(capsule.branchRect.width > 0,
				        "\(where_): the branch half is \(capsule.branchRect)")
			}
		}
	}

	/// Without a branch — footage on a volume that is no work tree, which is the
	/// ordinary case — the name still stops before the shortcut.
	@Test func withNoBranchTheNameStillClearsTheShortcut() throws {
		_ = NSApplication.shared
		let capsule = DocumentCapsule(frame: NSRect(x: 0, y: 0, width: 220, height: 30))
		for name in Self.names {
			capsule.show(project: name, branch: nil)
			let spans = capsule.spans
			#expect(spans.branch == nil)
			let over = "\(name.count) chars: the name may draw to "
				+ "\(spans.project.upperBound), the shortcut starts at "
				+ "\(spans.hint.lowerBound)"
			#expect(spans.project.upperBound <= spans.hint.lowerBound, .init(rawValue: over))
		}
	}

	/// The anchor the popover is given is never empty, whatever the width.
	@Test func theSwitcherAlwaysHasSomethingToHangFrom() throws {
		_ = NSApplication.shared
		let project = ComposeWindowController(document: ComposeDocument())
		let window = project.windowForTesting
		let bar = try #require(self.bar(in: window))
		bar.setName("Lilly, Annelie, Chris 1")
		bar.setBranch("main")
		for width in Self.widths {
			window.setContentSize(NSSize(width: width, height: 700))
			window.layoutIfNeeded()
			for half in [DocumentCapsule.Half.project, .branch] {
				let (_, rect) = bar.anchor(for: half)
				#expect(rect.width >= 8 && rect.height >= 8,
				        "at \(width) the \(half) anchor is \(rect)")
			}
		}
	}

	/// The filter field's placeholder starts after the magnifier, not on it.
	///
	/// Measured as ink: the field is drawn twice, once with the placeholder and
	/// once without, and the columns that differ are the columns the placeholder
	/// put ink in. It used to start at x = 2 with the glyph occupying 6 to 18 —
	/// the text ran straight through the icon, because an unbezelled search
	/// field reports a text rect at x = 22 and then installs its field editor
	/// over the whole bounds at x = 0. And always, not sometimes: this field is
	/// given the cursor the moment the panel opens.
	@Test func thePlaceholderStartsAfterTheMagnifier() throws {
		_ = NSApplication.shared
		let switcher = DocumentSwitcher.Switcher([
			.init("Open Documents", [.init(name: "a", path: "/b", kind: .take, open: {})]),
		])
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 360),
		                      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
		window.appearance = NSAppearance(named: .darkAqua)
		switcher.loadView()
		window.contentView = switcher.view
		window.makeKeyAndOrderFront(nil)
		window.layoutIfNeeded()
		let field = try #require(switcher.view.subviews.compactMap { $0 as? NSSearchField }.first)
		// As the panel opens it: with the cursor in the field.
		switcher.focus()
		window.layoutIfNeeded()

		let cell = try #require(field.cell as? NSSearchFieldCell)
		let button = cell.searchButtonRect(forBounds: field.bounds)

		// The field editor — what actually draws the text and the placeholder —
		// must sit in the field's text area, not over the button.
		if let editor = field.currentEditor() {
			let frame = editor.convert(editor.bounds, to: field)
			let from = "the text is drawn from \(frame.minX); the magnifier is at \(button)"
			#expect(frame.minX >= button.midX, .init(rawValue: from))
		}

		// And the ink agrees.
		func ink(_ view: NSView) -> Set<Int> {
			guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return [] }
			view.cacheDisplay(in: view.bounds, to: rep)
			var columns = Set<Int>()
			for x in 0..<rep.pixelsWide {
				for y in 0..<rep.pixelsHigh where rep.colorAt(x: x, y: y)
					.map({ $0.brightnessComponent > 0.3 }) == true {
					columns.insert(x)
					break
				}
			}
			return columns
		}
		let scale = field.window?.backingScaleFactor ?? 2
		let withText = ink(field)
		field.placeholderString = ""
		field.needsDisplay = true
		let bare = ink(field)
		let placeholder = withText.subtracting(bare).map { CGFloat($0) / scale }.sorted()
		if let first = placeholder.first {
			let ink = "the placeholder's first ink is at \(first); the magnifier's "
				+ "rectangle is \(button)"
			#expect(first >= button.midX, .init(rawValue: ink))
		}
		// The field is also tall enough for its own text. Unbezelled it laid out
		// 15 points high for a 12-point font.
		#expect(field.frame.height >= 20, "the field is \(field.frame.height) points tall")
	}
}
