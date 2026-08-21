import CuttrKit
import Foundation
import Testing
@testable import CuttrCompose

/// Where a mark is on the programme, and how long a range written inside one
/// is allowed to be.
///
/// A clip used twice is two places and not one long one. Three functions were
/// answering that question — the resolver, the drag, and the properties panel —
/// and two of them answered with the first start and the last end, which for a
/// shot used in the opening and again at the end is most of the film. A bubble
/// written inside a four-second clip was offered ninety-six seconds of
/// programme to aim at, and its `to:` could be written past the clip
/// altogether. Now there is one function, and this is what it says.
@Suite struct SpanPlaceTests {

	private func fixture() throws -> URL {
		let directory = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("cuttr-places-\(UUID().uuidString)")
		try FileManager.default.createDirectory(
			at: directory.appendingPathComponent("takes"), withIntermediateDirectories: true)
		try Data().write(to: directory.appendingPathComponent("a.mov"))
		try TakeWriter.write(Take(video: "../a.mov", clips: [
			Clip(slug: "one", start: 0, end: 2),
			Clip(slug: "two", start: 2, end: 5),
			Clip(slug: "three", start: 5, end: 9),
		])).write(to: directory.appendingPathComponent("takes/take-01.cuttr"),
		          atomically: true, encoding: .utf8)
		return directory
	}

	/// `one` at the top and `one` again at the end: two places, each two
	/// seconds long — 0 to 2 and 9 to 11 — and nothing said about the seven
	/// seconds of other shots between them.
	private func programme(_ directory: URL) throws -> ResolvedProject {
		try Resolver.resolve(try ProjectReader.read("""
		takes: [takes/take-01.cuttr]
		timeline:
		  - clip: one
		  - clip: two
		  - clip: three
		  - clip: one
		"""), baseURL: directory)
	}

	@Test func aClipUsedTwiceIsTwoPlacesAndNotOneLongOne() throws {
		let directory = try fixture()
		defer { try? FileManager.default.removeItem(at: directory) }
		let resolved = try programme(directory)
		let places = Overlay.Span.Endpoint.clip(ClipReference("one")).places(in: resolved)
		#expect(places.count == 2)
		#expect(places[0].start == 0)
		#expect(places[0].end == 2)
		#expect(places[1].start == 9)
		#expect(places[1].end == 11)
		// Which is the whole point: neither of them is the seven seconds in
		// between, and no answer spans both.
		#expect(places.allSatisfy { $0.end - $0.start == 2 })
	}

	/// Which use a range is about is decided by where the thing editing it is,
	/// not by which use came first.
	@Test func thePlaceIsTheOneTheMomentIsIn() throws {
		let directory = try fixture()
		defer { try? FileManager.default.removeItem(at: directory) }
		let resolved = try programme(directory)
		let mark = Overlay.Span.Endpoint.clip(ClipReference("one"))
		#expect(mark.place(in: resolved, nearest: 9.5)?.start == 9)
		#expect(mark.place(in: resolved, nearest: 0.5)?.start == 0)
		// Nothing to go on is the first one, which is at least the same answer
		// every time.
		#expect(mark.place(in: resolved)?.start == 0)
		// A moment in neither takes the nearer of them rather than nothing.
		#expect(mark.place(in: resolved, nearest: 6)?.start == 9)
	}

	/// A `within:` is "so many seconds into that shot", so a `to:` past the
	/// shot's own end is not a long overlay — it is a number the programme has
	/// nowhere to put.
	@Test func aRangeCannotBeWrittenPastTheClipItIsInside() throws {
		let directory = try fixture()
		defer { try? FileManager.default.removeItem(at: directory) }
		let resolved = try programme(directory)
		let mark = Overlay.Span.Endpoint.clip(ClipReference("one"))
		let held = Overlay.Span.within(mark, from: 0.5, to: 40).clamped(in: resolved)
		#expect(held == .within(mark, from: 0.5, to: 2))
		// From the other end too, and never inside out.
		#expect(Overlay.Span.within(mark, from: -3, to: 1).clamped(in: resolved)
			== .within(mark, from: 0, to: 1))
		#expect(Overlay.Span.within(mark, from: 5, to: 1).clamped(in: resolved)
			== .within(mark, from: 2, to: 2))
	}

	/// Programme times mean what they say and a mark-bound range takes its
	/// length from the marks, so neither is held to anything.
	@Test func onlyAWithinIsHeldToItsClip() throws {
		let directory = try fixture()
		defer { try? FileManager.default.removeItem(at: directory) }
		let resolved = try programme(directory)
		let times = Overlay.Span.times(from: 0, to: 400)
		#expect(times.clamped(in: resolved) == times)
		let marks = Overlay.Span.marks(from: .clip(ClipReference("one")),
		                               to: .clip(ClipReference("three")))
		#expect(marks.clamped(in: resolved) == marks)
	}

	/// A drag is written back against the use it landed in — and still cannot
	/// leave it.
	@Test func aDragLandsInTheUseItWasDroppedOn() throws {
		let directory = try fixture()
		defer { try? FileManager.default.removeItem(at: directory) }
		let resolved = try programme(directory)
		let mark = Overlay.Span.Endpoint.clip(ClipReference("one"))
		let span = Overlay.Span.within(mark, from: 0, to: 1)
		// Dropped on the second use, half a second in.
		#expect(span.moved(start: 9.5, end: 10.5, in: resolved)
			== .within(mark, from: 0.5, to: 1.5))
		// And dragged off the end of it, held at the end.
		#expect(span.moved(start: 10.5, end: 14, in: resolved)
			== .within(mark, from: 1.5, to: 2))
	}
}
