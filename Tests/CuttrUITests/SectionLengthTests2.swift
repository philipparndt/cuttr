import AppKit
import CuttrKit
import Testing
@testable import CuttrCompose
@testable import CuttrUI

/// How long a section runs, on its row.
///
/// It is the thing a section row is *for* — a section is the unit somebody plans
/// a film in, and "five entries" does not say whether that is thirty seconds or
/// four minutes. It was drawn after the name and the count, left to right, at
/// whatever point the name had reached, and nothing looked at the width of the
/// row. A section with a long name pushed it past the edge and it was simply not
/// there, with nothing to say so.
@MainActor @Suite struct SectionLengthTests2 {

	private func row(name: String, count: Int, length: Double?,
	                 width: CGFloat) -> ProgrammePanel.EntryRow {
		_ = NSApplication.shared
		let made = ProgrammePanel.EntryRow(frame: NSRect(x: 0, y: 0, width: width, height: 26))
		made.entry = TimelineEntry(group: name, entries: [])
		made.count = count
		made.length = length
		return made
	}

	/// Where the length landed, having drawn the row.
	private func lengthOf(_ view: ProgrammePanel.EntryRow) -> NSRect? {
		guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
		view.cacheDisplay(in: view.bounds, to: rep)
		return view.lengthDrawnAt
	}

	/// **The one that matters.** A long name must not push the length off the
	/// row — it is against the right edge now, so there is nothing to push.
	@Test func aLongNameDoesNotPushTheLengthOff() throws {
		let narrow = row(name: "the-very-long-section-name-somebody-actually-used",
		                 count: 12, length: 183.4, width: 320)
		let at = try #require(lengthOf(narrow), "no length was drawn at all")
		#expect(at.maxX <= narrow.bounds.width,
		        "the length runs off the row: ends at \(at.maxX) of \(narrow.bounds.width)")
		#expect(at.minX >= 0)
	}

	/// And a short name still shows it, in the place it has always been read.
	@Test func aShortNameShowsTheLength() throws {
		let wide = row(name: "intro", count: 3, length: 3.2, width: 520)
		let at = try #require(lengthOf(wide))
		#expect(at.maxX <= wide.bounds.width)
	}

	/// A row too narrow for both keeps the length and drops the count: of the
	/// two, the length is the one that cannot be worked out by looking.
	@Test func aVeryNarrowRowKeepsTheLength() throws {
		let tiny = row(name: "a-section-with-a-name-far-too-long-for-this",
		               count: 9, length: 61, width: 200)
		let at = try #require(lengthOf(tiny))
		#expect(at.maxX <= tiny.bounds.width)
	}

	/// A section with no length — one with nothing in it — draws no length and
	/// does not fall over doing it.
	@Test func aSectionWithNothingInItDrawsNoLength() {
		let empty = row(name: "made-and-not-filled", count: 0, length: nil, width: 320)
		#expect(lengthOf(empty) == nil)
	}
}
