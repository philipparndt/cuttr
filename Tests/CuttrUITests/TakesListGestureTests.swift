import AppKit
import Testing
@testable import CuttrCompose
@testable import CuttrKit
@testable import CuttrUI

/// A double-click anywhere along a row of the takes list opens that take.
///
/// This is the "only sometimes" half of the fault, and the condition nobody
/// intended: the columns are `NSTextField`s, an `NSTextField` is an `NSControl`,
/// and a control answers the mouse itself. The table never saw the click, so
/// `clickedRow` stayed at −1 and `doubleAction` did not fire. Driven on a real
/// project this showed as the take's *name* — the obvious place to aim — doing
/// nothing at all, while the same gesture on the clip count beside it opened
/// the take. A list whose answer depends on which column you hit is a list
/// nobody can learn.
@MainActor @Suite struct TakesListGestureTests {

	private func list() throws -> (TakesTable, NSTableView, URL) {
		_ = NSApplication.shared
		let folder = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("cuttr-gesture-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		let take = folder.appendingPathComponent("mia-take-1.cuttr")
		try DocumentPlaceTests.takeFile.write(to: take, atomically: true, encoding: .utf8)
		var project = Project(takes: ["mia-take-1.cuttr"], output: Output(file: "out.mov"))
		// A scene with something in it: an empty one is not written out.
		project.scenes = ["intro": SceneDocument.starter]
		let projectFile = folder.appendingPathComponent("programme.cuttrproj")
		try ProjectWriter.write(project).write(to: projectFile, atomically: true, encoding: .utf8)
		let document = ComposeDocument()
		try document.read(from: projectFile)

		let list = TakesTable(frame: NSRect(x: 0, y: 0, width: 520, height: 240))
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 240),
		                      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
		window.contentView = list
		list.reload(document.takes, scenes: document.project.scenes)
		window.layoutIfNeeded()
		let table = list.tableForTesting
		table.layoutSubtreeIfNeeded()
		return (list, table, take)
	}

	/// Every column of every row hands the mouse to the table.
	@Test func aClickAnywhereInARowReachesTheTable() throws {
		let (_, table, _) = try list()
		#expect(table.numberOfRows == 2, "the list has \(table.numberOfRows) rows")
		#expect(table.doubleAction != nil && table.target != nil)

		for row in 0..<table.numberOfRows {
			let rowRect = table.rect(ofRow: row)
			guard rowRect.height > 0 else { continue }
			for column in 0..<table.numberOfColumns {
				let cellRect = table.frameOfCell(atColumn: column, row: row)
				guard cellRect.width > 2 else { continue }
				let name = table.tableColumns[column].identifier.rawValue
				// Well inside the cell's text, which is where somebody aims.
				let point = NSPoint(x: cellRect.midX, y: cellRect.midY)
				let hit = table.hitTest(table.convert(point, to: table.superview))
				let landed = "row \(row), column \(name): the click lands on "
					+ "\(type(of: hit as Any)), which answers the mouse itself — "
					+ "the table never sees it and `clickedRow` stays at −1"
				#expect(!(hit is NSControl), .init(rawValue: landed))
				// And the table agrees on which row that point is.
				let said = "row \(row), column \(name): the table says "
					+ "\(table.row(at: point))"
				#expect(table.row(at: point) == row, .init(rawValue: said))
			}
		}
	}

	/// And while a name is being typed into, the field *does* take the mouse —
	/// otherwise the caret could not be put anywhere in it.
	@Test func theNameTakesTheMouseWhileItIsBeingRenamed() throws {
		let (list, table, _) = try list()
		list.beginRenaming("mia-take-1.cuttr")
		table.layoutSubtreeIfNeeded()
		let cellRect = table.frameOfCell(atColumn: 0, row: 0)
		let point = NSPoint(x: cellRect.midX, y: cellRect.midY)
		let hit = table.hitTest(table.convert(point, to: table.superview))
		#expect(hit is NSTextField || hit is NSTextView,
		        "the name being renamed does not take the caret: \(type(of: hit as Any))")
	}

	/// The gesture arrives at the take's own file, and at nothing else.
	@Test func theGestureOpensTheTakeItLandedOn() throws {
		let (list, table, take) = try list()
		var opened: [URL] = []
		var aside: [Bool] = []
		var scenes: [String?] = []
		list.onOpen = { url, sideways in
			opened.append(url)
			aside.append(sideways)
		}
		list.onScene = { scenes.append($0) }

		// The row is chosen and the table's own double-click handler run, which
		// is the method `doubleAction` names.
		table.selectRowIndexes([0], byExtendingSelection: false)
		list.chooseRowForTesting(0)
		#expect(opened.map(\.standardizedFileURL) == [take.standardizedFileURL],
		        "the take opened was \(opened)")
		#expect(scenes.isEmpty)

		// And a scene row goes to the scene editor rather than to a file.
		list.chooseRowForTesting(1)
		#expect(scenes == ["intro"], "the scene chosen was \(scenes)")
		#expect(opened.count == 1)

		// The ordinary gesture swaps the document in place; ⌥ asks for a window
		// of its own, and the list says which was meant rather than deciding.
		#expect(aside == [false], "the plain double-click asked for a new window")
		list.chooseRowForTesting(0, aside: true)
		#expect(aside == [false, true], "⌥ on the row did not ask for a new window")
	}
}
