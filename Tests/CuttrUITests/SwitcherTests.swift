import AppKit
import CuttrCompose
import CuttrKit
import Testing
@testable import CuttrUI

/// The switcher, and the three ways it did not work.
///
/// It listed documents correctly and then did nothing when one was chosen,
/// which is the whole point of the control. None of these failures is the sort
/// a test asserting on *contents* can see.
@Suite @MainActor struct SwitcherTests {

	private func groups() -> [DocumentSwitcher.Group] {
		[
			.init("Open Documents", [
				.init(name: "dingsda", path: "/Volumes/500G", kind: .scene, open: {}),
				.init(name: "mia-take-1", path: "/Volumes/500G/takes", kind: .take,
				      indented: true, isCurrent: true, open: {}),
			]),
			.init("Recent Documents", [
				.init(name: "gone", path: "/Volumes/gone", kind: .take, missing: true, open: nil),
			]),
		]
	}

	/// A single click opens a row. It was wired to `doubleAction` only, so
	/// pointing at a row and clicking it did nothing at all — and clicking is
	/// what somebody does in a list that drops out of a button.
	///
	/// Necessary and nowhere near sufficient, which is worth saying here: this
	/// watches a closure run, and a closure running was never the problem. The
	/// switcher was reported fixed twice on the strength of this test while
	/// choosing a document still went nowhere, because the window it ordered
	/// front was ordered back again as the popover closed. What the control
	/// actually *does* is held by `DocumentPlaceTests`, which asks which
	/// document is in front afterwards.
	@Test func oneClickChoosesARow() throws {
		_ = NSApplication.shared
		let switcher = DocumentSwitcher.Switcher(groups())
		switcher.loadView()
		let table = try #require(switcher.tableForTesting)
		#expect(table.action != nil, "a click on a row does nothing")

		var opened: [String] = []
		let listening = DocumentSwitcher.Switcher([
			.init("Open Documents", [
				.init(name: "dingsda", path: "/Volumes/500G", kind: .scene) {
					opened.append("dingsda")
				},
				.init(name: "mia-take-1", path: "/Volumes/500G", kind: .take) {
					opened.append("mia")
				},
			]),
		])
		listening.loadView()
		// Row 0 is the heading, so the second document is row 2.
		listening.selectForTesting(2)
		listening.chooseForTesting()
		#expect(opened == ["mia"], "choosing the second row opened \(opened)")
	}

	/// A row whose file has gone offers nothing, and choosing it does nothing
	/// rather than something wrong.
	@Test func aMissingDocumentCannotBeChosen() {
		_ = NSApplication.shared
		let switcher = DocumentSwitcher.Switcher(groups())
		switcher.loadView()
		switcher.selectForTesting(switcher.shownForTesting.count - 1)
		switcher.chooseForTesting()
		#expect(switcher.shownForTesting.last == "gone")
	}

	/// The panel stays inside the window it belongs to.
	///
	/// A popover is centred on its anchor and clamped to the *screen*, not the
	/// window — so one hung under a capsule eighty points in went off the left
	/// edge and sat on the desktop.
	@Test func theAnchorIsNudgedSoThePanelStaysInTheWindow() {
		_ = NSApplication.shared
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
		                      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
		let capsule = DocumentCapsule(frame: NSRect(x: 79, y: 0, width: 300, height: 30))
		let content = NSView(frame: NSRect(x: 0, y: 0, width: 1400, height: 900))
		content.addSubview(capsule)
		window.contentView = content
		capsule.show(project: "dingsda", branch: "ui")
		window.layoutIfNeeded()

		let half = capsule.projectRect
		let anchor = DocumentSwitcher.inside(half, of: capsule)
		let midInWindow = capsule.convert(NSPoint(x: anchor.midX, y: 0), to: nil).x
		#expect(midInWindow - DocumentSwitcher.Switcher.width / 2 >= 0,
		        "the panel starts at \(midInWindow - DocumentSwitcher.Switcher.width / 2)")
		// And the beak is still on the half that opened it.
		#expect(anchor.midX >= half.minX && anchor.midX <= half.maxX,
		        "the beak left the project half: \(anchor.midX) against \(half)")

		// A capsule with room to spare is not moved at all.
		let roomy = NSRect(x: 700, y: 0, width: 120, height: 30)
		#expect(DocumentSwitcher.inside(roomy, of: capsule) == roomy)
	}

	/// Every document gets its own hue, derived from its name and stable across
	/// launches — `hashValue` is seeded per process and would make a project
	/// violet this morning and green this afternoon.
	@Test func eachDocumentHasItsOwnColour() {
		let names = ["dingsda", "mia-take-1", "walter-take-2", "intro", "b-roll", "outro"]
		let hues = names.map { name in
			DocumentSwitcher.Entry(name: name, path: "", kind: .take, open: {}).hue
		}
		#expect(Set(hues.map { $0.description }).count > 1, "every row is the same colour")

		for name in names {
			let once = DocumentSwitcher.Entry(name: name, path: "", kind: .take, open: {}).hue
			// The kind does not decide it — two documents of one kind must still
			// differ, which is what a per-kind colour could not do.
			let twice = DocumentSwitcher.Entry(name: name, path: "", kind: .scene, open: {}).hue
			#expect(once == twice, "\(name) changed colour with its kind")
			// And it is the derivation speakers already use, rather than a
			// second palette that could drift from it.
			#expect(once == Theme.base(Speaker.color(of: name)))
		}
	}

	/// The folder is on every row. It is the column that tells two takes called
	/// `take-1` apart, and the list shipped without it.
	@Test func everyRowCarriesItsFolder() {
		for group in groups() {
			for entry in group.entries {
				#expect(!entry.path.isEmpty, "\(entry.name) says nothing about where it is")
			}
		}
	}

	/// A row is one line of text and a little — not two.
	@Test func rowsAreTheHeightOfALine() {
		#expect(DocumentSwitcher.Switcher.rowHeight <= 28,
		        "a row is \(DocumentSwitcher.Switcher.rowHeight) points tall")
		// And the panel is narrow enough to sit inside a window beside a capsule
		// that starts eighty points in.
		#expect(DocumentSwitcher.Switcher.width <= 420)
	}

	/// The panel is as tall as what is in it, and every row of it is whole.
	///
	/// "The dropdown is too short. About two hundred points: one heading, one
	/// project, and the second row clipped mid-line with a scroller." Both halves
	/// of that were real. The room the field and the margins take was the
	/// constant 44 and is 41 on its own at a rounded bezel, so a panel sized to
	/// its content was three points short of it — the last row lost its
	/// descenders and a scroller appeared over a list that fitted. And the cap
	/// was 560 whatever screen it was on, which is a third of a large one.
	@Test func theHeightFollowsWhatIsInIt() {
		_ = NSApplication.shared
		var heights: [CGFloat] = []
		for count in [1, 3, 8, 20, 60] {
			let entries = (1...count).map {
				DocumentSwitcher.Entry(name: "take-\($0)", path: "~/dev", kind: .take, open: {})
			}
			let switcher = DocumentSwitcher.Switcher([.init("Open Documents", entries)])
			switcher.loadView()
			let height = switcher.preferredContentSize.height
			heights.append(height)

			// Never a sliver, and never taller than a good fraction of the
			// screen. The floor is snapped down to whole rows, so it is the
			// floor less at most one row.
			#expect(height > DocumentSwitcher.Switcher.floorHeight
				- DocumentSwitcher.Switcher.rowHeight,
			        "\(count) rows gave a panel \(height) points tall")
			#expect(height <= DocumentSwitcher.Switcher.ceilingHeight(on: nil),
			        "\(count) rows gave a panel \(height) points tall")

			// And whatever it is, a whole number of rows fits in the room left
			// for the list — at the floor, at the cap and everywhere between.
			// This is the assertion the old constant failed: it is not about the
			// cap, it is about no row ever being cut through its own text.
			let list = height - switcher.chromeForTesting
			let rows = list / DocumentSwitcher.Switcher.rowHeight
			#expect(abs(rows.rounded() - rows) < 0.01, .init(rawValue:
				"\(count) rows leaves \(list) points of list, which is "
					+ "\(rows) rows — the last one is cut through"))
		}
		// It grows with the content, up to the cap, and then stops.
		#expect(heights == heights.sorted(), "the panel does not follow its content")
		let cap = DocumentSwitcher.Switcher.ceilingHeight(on: nil)
		#expect(heights.last ?? 0 > cap - DocumentSwitcher.Switcher.rowHeight,
		        "sixty rows did not reach the cap: \(heights) against \(cap)")
		#expect(heights.first ?? 0 > DocumentSwitcher.Switcher.floorHeight
			- DocumentSwitcher.Switcher.rowHeight,
		        "one row did not sit on the floor: \(heights)")
	}

	/// And the cap is a fraction of the screen rather than a number chosen for
	/// no screen in particular.
	@Test func theCapIsAFractionOfTheScreen() throws {
		_ = NSApplication.shared
		let screen = try #require(NSScreen.main)
		let cap = DocumentSwitcher.Switcher.ceilingHeight(on: screen)
		#expect(cap < screen.visibleFrame.height,
		        "the panel may take the whole screen: \(cap) of \(screen.visibleFrame.height)")
		#expect(cap > screen.visibleFrame.height / 2,
		        "the cap is \(cap) on a screen \(screen.visibleFrame.height) tall")
	}
}

/// What the filter field matches, and what it must not.
@MainActor @Suite struct SwitcherFilterTests {

	/// Typing `mia` kept the whole list. Letters-in-order is right for a name —
	/// `mt1` should find `mia-take-1` — and wrong for a path: every document on
	/// the machine sits under something like `/Volumes/500G/dingsda`, which has
	/// an m, an i and an a in that order.
	@Test func aPathIsNotMatchedByItsLettersInOrder() {
		let path = "/Volumes/500G/dingsda/takes/Lilly, Annelie, Chris 1.cuttr"
		#expect(DocumentSwitcher.matches("mia", in: "Mia 1"))
		#expect(!DocumentSwitcher.contains("mia", in: path))
		// The name of that take does not contain the letters either, so the row
		// goes — which is the whole point.
		#expect(!DocumentSwitcher.matches("mia", in: "Lilly, Annelie, Chris 1"))
	}

	/// And a name still matches loosely, which is what the field is for.
	@Test func aNameMatchesItsLettersInOrder() {
		#expect(DocumentSwitcher.matches("mt1", in: "mia-take-1"))
		#expect(DocumentSwitcher.matches("jem", in: "Jonas Emilia 2"))
		#expect(!DocumentSwitcher.matches("zz", in: "Mia 1"))
	}

	/// A path matches when somebody types a folder, because that is what typing
	/// a folder means.
	@Test func aPathMatchesWhatItReads() {
		let path = "/Volumes/500G/dingsda/takes/Mia 1.cuttr"
		#expect(DocumentSwitcher.contains("dingsda", in: path))
		#expect(DocumentSwitcher.contains("500G", in: path))
		#expect(DocumentSwitcher.contains("", in: path))
		#expect(!DocumentSwitcher.contains("nowhere", in: path))
	}
}

/// The width of a row, which is what leaves room for the path.
@MainActor @Suite struct SwitcherRowWidthTests {

	/// A single column starts at a hundred points and only redistributes when
	/// the table is *resized* — and a table given its size by Auto Layout never
	/// is. So a cell drawing its path against `bounds.maxX` had a hundred
	/// points in a pane of three hundred and eighty: most rows showed no path
	/// at all and a couple showed four characters of one.
	@Test func aRowIsAsWideAsTheList() throws {
		let switcher = DocumentSwitcher.Switcher([
			.init("In dingsda", [
				.init(name: "Mia 1", path: "/Volumes/500G/dingsda/takes/Mia 1.cuttr",
				      kind: .take, indented: true, open: {}),
			]),
		])
		switcher.loadView()
		switcher.view.frame = NSRect(x: 0, y: 0,
		                             width: DocumentSwitcher.Switcher.width, height: 400)
		switcher.view.layoutSubtreeIfNeeded()

		func find<T: NSView>(_ kind: T.Type, in view: NSView) -> T? {
			if let hit = view as? T { return hit }
			for sub in view.subviews { if let hit = find(kind, in: sub) { return hit } }
			return nil
		}
		guard let clip = find(NSClipView.self, in: switcher.view),
		      let table = find(NSTableView.self, in: switcher.view)
		else {
			Issue.record("no list in the panel")
			return
		}
		#expect(table.tableColumns.count == 1)
		// The column fills what the clip view shows, so a cell has the whole
		// width to place a right-aligned path in.
		#expect(abs(table.tableColumns[0].width - clip.bounds.width) < 1)
		#expect(table.tableColumns[0].width > 300)
	}
}
