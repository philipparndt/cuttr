import AppKit
import Testing
@testable import CuttrUI

/// What a recent project is called in a menu.
///
/// The whole of this type is the naming, and the naming exists for one
/// situation: two projects with the same name in two different folders. The
/// Dock draws its own Recent Documents section as bare display names, so those
/// two are two rows saying the same word — which is the question somebody is
/// asking when they open that menu, left unanswered.
///
/// The list is handed in rather than read from `NSDocumentController`, which in
/// a test process will not take a URL at all.
@Suite @MainActor struct RecentProjectsTests {

	private func urls(_ paths: [String]) -> [URL] { paths.map { URL(fileURLWithPath: $0) } }

	// MARK: - Naming

	/// The situation this exists for.
	@Test func twoProjectsWithOneNameEachSayTheirFolder() {
		let titles = RecentProjects.entries(from: urls([
			"/Volumes/500G/dingsda-cuttr/film.cuttrproj",
			"/Volumes/500G/dingsda/film.cuttrproj",
		])).map(\.title).sorted()
		#expect(titles == ["film  —  dingsda", "film  —  dingsda-cuttr"])
	}

	/// And a name nothing else shares stays short. A folder on every row is a
	/// column of noise that says nothing on the rows that did not need it.
	@Test func aNameNothingSharesStaysShort() {
		let titles = Set(RecentProjects.entries(from: urls([
			"/Volumes/500G/dingsda/film.cuttrproj",
			"/Volumes/500G/other/wedding.cuttrproj",
		])).map(\.title))
		#expect(titles == ["film", "wedding"])
	}

	/// Counted over the whole list rather than over what a caller shows: a name
	/// is ambiguous whether or not its twin fits in the rows on screen.
	@Test func aCollisionOutsideTheLimitStillNamesTheFolder() {
		let shown = RecentProjects.entries(from: urls([
			"/Volumes/500G/late/film.cuttrproj",
			"/Volumes/500G/p1/one.cuttrproj",
			"/Volumes/500G/early/film.cuttrproj",
		]), limit: 2)
		#expect(shown.count == 2)
		#expect(shown[0].title == "film  —  late",
		        "a colliding name lost its folder because its twin was out of view")
	}

	/// Only projects are ever remembered, and only projects come out.
	@Test func takesAreNotInTheList() {
		let titles = RecentProjects.entries(from: urls([
			"/Volumes/500G/dingsda/film.cuttrproj",
			"/Volumes/500G/dingsda/mia-take-1.cuttr",
		])).map(\.title)
		#expect(titles == ["film"])
	}

	@Test func aProjectThatIsNotThereIsListedAndSaysSo() {
		let entries = RecentProjects.entries(from: urls([
			"/Volumes/nowhere-\(UUID().uuidString)/film.cuttrproj",
		]))
		#expect(entries.count == 1)
		#expect(!entries[0].exists)
	}

	// MARK: - The rows

	@Test func aRowCarriesTheProjectAndItsWholePath() {
		let path = "/Volumes/500G/dingsda/film.cuttrproj"
		let entry = RecentProjects.entries(from: urls([path]))[0]
		let item = RecentProjects.item(for: entry, action: #selector(NSMenu.cancelTracking),
		                               target: nil)
		#expect(item.representedObject as? URL == URL(fileURLWithPath: path))
		// The folder alone tells two rows apart and is not always enough to say
		// where either one is.
		#expect(item.toolTip == path)
		#expect(item.image != nil)
	}

	// MARK: - The Dock

	@Test func theDockMenuListsRecentProjects() throws {
		let folder = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("cuttr-dock-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: folder) }
		let one = folder.appendingPathComponent("film.cuttrproj")
		try "cuttr-project: 1\n".write(to: one, atomically: true, encoding: .utf8)

		let entries = RecentProjects.entries(from: [one])
		let menu = try #require(RecentProjects.dockMenu(
			for: entries, action: #selector(NSMenu.cancelTracking), target: nil))
		#expect(menu.items.count == 1)
		#expect(menu.items[0].title == "film")
		#expect(menu.items[0].representedObject as? URL == one)
	}

	/// A menu with nothing in it is worse than none: the Dock would show an
	/// empty section above its own.
	@Test func thereIsNoDockMenuWithNothingToPutInIt() {
		#expect(RecentProjects.dockMenu(for: [], action: #selector(NSMenu.cancelTracking),
		                                target: nil) == nil)
	}

	/// A project that has moved is left out of the Dock menu rather than listed
	/// dead. Open Recent can afford to say "this is gone"; a Dock menu is a
	/// shortcut and a row that cannot be pressed is not one.
	@Test func theDockMenuLeavesOutWhatIsNotThere() {
		let entries = RecentProjects.entries(from: urls([
			"/Volumes/nowhere-\(UUID().uuidString)/film.cuttrproj",
		]))
		#expect(RecentProjects.dockMenu(for: entries, action: #selector(NSMenu.cancelTracking),
		                                target: nil) == nil)
	}
}
