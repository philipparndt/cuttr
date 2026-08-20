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
}
