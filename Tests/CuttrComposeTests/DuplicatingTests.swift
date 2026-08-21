import CuttrKit
import Foundation
import Testing
@testable import CuttrCompose

/// Duplicating an entry with everything hung on it.
///
/// The thing this exists for: somebody has built a shot up with a film look, a
/// bubble, a caption and a sting, and wants the same treatment on a different
/// shot. Copy the entry, then change which clip it points at — rather than
/// writing all of it out again by hand, which is what the file made them do.
///
/// Two things have to be true of every copy. Everything written *inside* the
/// entry comes with it, all the way down a section; and no name is used twice,
/// because two entries answering to one name are not two things a caption picks
/// between — they are one stretch of programme reaching from the first to the
/// last, and a caption hung on that covers everything in between.
@Suite struct DuplicatingTests {

	private func caption(_ text: String, _ span: Overlay.Span? = nil) -> Overlay {
		Overlay(kind: .text(text, style: nil), appearances: span.map { [.init($0)] } ?? [],
		        arrival: .cut, departure: .cut)
	}

	// MARK: - What comes with it

	@Test func theCopyCarriesWhatIsWrittenInsideTheEntry() {
		var project = Project(timeline: [
			TimelineEntry(clip: ClipReference("one"),
			              overlays: [caption("Hello")],
			              sounds: [Sound(file: "sting.wav", span: nil)]),
		])
		let landed = project.duplicateEntry(at: [0])
		#expect(landed == [1])
		#expect(project.timeline.count == 2)
		#expect(project.timeline[1].overlays.map(\.described) == ["the caption “Hello”"])
		#expect(project.timeline[1].sounds.map(\.file) == ["sting.wav"])
	}

	/// A trim and a transition are part of the placement, not of the take, so
	/// they are part of what is being copied.
	@Test func theCopyKeepsTheTrimAndTheTransition() {
		var project = Project(timeline: [
			TimelineEntry(clip: ClipReference("one"), transition: .dissolve(over: 0.5),
			              trim: (head: 0.25, tail: 1)),
		])
		project.duplicateEntry(at: [0])
		#expect(project.timeline[1].trim == (0.25, 1))
		#expect(project.timeline[1].transition == .dissolve(over: 0.5))
	}

	/// A section whose contents did not come would make the word a lie.
	@Test func duplicatingASectionBringsEverythingInside() {
		var project = Project(timeline: [
			TimelineEntry(group: "build", entries: [
				TimelineEntry(clip: ClipReference("two"), overlays: [caption("First")]),
				TimelineEntry(group: "inner", entries: [
					TimelineEntry(clip: ClipReference("three")),
				]),
			], overlays: [caption("On the section")]),
		])
		let landed = project.duplicateEntry(at: [0])
		#expect(landed == [1])
		guard case .group(let name, let inner) = project.timeline[1].source else {
			Issue.record("the copy is not a section")
			return
		}
		#expect(name == "build-2")
		#expect(inner.count == 2)
		#expect(inner[0].overlays.map(\.described) == ["the caption “First”"])
		#expect(project.timeline[1].overlays.count == 1)
		#expect(project.rows.map(\.entry.source.description)
			== ["@build", "two", "@inner", "three",
			    "@build-2", "two", "@inner-2", "three"])
	}

	// MARK: - Names

	@Test func theCopyOfANamedPlacementIsNamedSomethingFree() {
		var project = Project(timeline: [
			TimelineEntry(clip: ClipReference("one"), label: "shot"),
		])
		project.duplicateEntry(at: [0])
		#expect(project.timeline.map(\.label) == ["shot", "shot-2"])
	}

	/// The names inside a section are the same namespace as the section's own —
	/// an overlay hangs on `@name` without caring which put it there — so all of
	/// them have to be freed, however deep they are.
	@Test func everyNameInsideACopiedSectionIsFreedToo() {
		var project = Project(timeline: [
			TimelineEntry(group: "build", entries: [
				TimelineEntry(clip: ClipReference("two"), label: "shot"),
				TimelineEntry(group: "inner", entries: [
					TimelineEntry(card: Card(duration: 2), label: "card"),
				]),
			]),
		])
		project.duplicateEntry(at: [0])
		let names = project.entryNames
		#expect(names == ["build", "shot", "inner", "card",
		                  "build-2", "shot-2", "inner-2", "card-2"])
	}

	/// Two copies of one section are two sections, not one name written twice.
	@Test func aSecondCopyGetsTheNextNameAlong() {
		var project = Project(timeline: [
			TimelineEntry(group: "shot", entries: [TimelineEntry(clip: ClipReference("two"))]),
		])
		project.duplicateEntry(at: [0])
		project.duplicateEntry(at: [0])
		#expect(project.rows.map(\.entry.source.description)
			== ["@shot", "two", "@shot-3", "two", "@shot-2", "two"])
	}

	/// Pasting into a project that has never heard the name keeps it: the point
	/// of freeing a name is the collision, and there is not one here.
	@Test func aNameNothingElseUsesIsLeftAlone() {
		let project = Project(timeline: [TimelineEntry(clip: ClipReference("one"))])
		let copy = project.copy(of: TimelineEntry(clip: ClipReference("two"), label: "shot"))
		#expect(copy.label == "shot")
	}

	// MARK: - References

	/// A caption inside the copy that hung on the copied section's name has to
	/// follow it, or the copy's own caption comes on over the original.
	@Test func aReferenceInsideTheCopyPointsAtTheCopy() {
		var project = Project(timeline: [
			TimelineEntry(group: "shot", entries: [
				TimelineEntry(clip: ClipReference("two"),
				              overlays: [caption("Inside", .within(.group("shot"), from: 1, to: 2))]),
			], sounds: [Sound(file: "hum.wav", span: .marks(from: .group("shot"), to: .group("shot")))]),
		])
		project.duplicateEntry(at: [0])
		guard case .group(_, let inner) = project.timeline[1].source else { return }
		#expect(inner[0].overlays[0].span == .within(.group("shot-2"), from: 1, to: 2))
		#expect(project.timeline[1].sounds[0].span
			== .marks(from: .group("shot-2"), to: .group("shot-2")))
		// And the original still says what it said.
		guard case .group(_, let first) = project.timeline[0].source else { return }
		#expect(first[0].overlays[0].span == .within(.group("shot"), from: 1, to: 2))
	}

	/// A span bound to a **clip** is left alone. It names material rather than
	/// a placement, the copy plays the same material, and re-pointing it would
	/// be inventing a reference nobody wrote.
	@Test func aReferenceToAClipIsLeftAsItIs() {
		var project = Project(timeline: [
			TimelineEntry(clip: ClipReference("one"),
			              overlays: [caption("On the clip",
			                                 .marks(from: .clip(ClipReference("one")),
			                                        to: .clip(ClipReference("one"))))]),
		])
		project.duplicateEntry(at: [0])
		#expect(project.timeline[1].overlays[0].span
			== .marks(from: .clip(ClipReference("one")), to: .clip(ClipReference("one"))))
	}

	/// A name from outside the copy is a reference to something outside the
	/// copy, and stays one.
	@Test func aReferenceOutOfTheCopyStillPointsOut() {
		var project = Project(timeline: [
			TimelineEntry(group: "titles", entries: [TimelineEntry(card: Card(duration: 2))]),
			TimelineEntry(clip: ClipReference("one"),
			              overlays: [caption("Later",
			                                 .marks(from: .group("titles"), to: .group("titles")))]),
		])
		project.duplicateEntry(at: [1])
		#expect(project.timeline[2].overlays[0].span
			== .marks(from: .group("titles"), to: .group("titles")))
	}

	/// The one worth a sentence in the doc comment: the project's own overlay
	/// list is not part of the entry, so it is not touched and goes on covering
	/// what it covered — the original.
	@Test func aTopLevelOverlayGoesOnCoveringTheOriginal() {
		var project = Project(
			timeline: [TimelineEntry(clip: ClipReference("one"), label: "shot")],
			overlays: [caption("Loose", .marks(from: .group("shot"), to: .group("shot")))])
		project.duplicateEntry(at: [0])
		#expect(project.overlays.count == 1)
		#expect(project.overlays[0].span == .marks(from: .group("shot"), to: .group("shot")))
		#expect(project.timeline[1].label == "shot-2")
	}

	// MARK: - Where it lands

	@Test func aCopyCanGoIntoAnotherSection() {
		var project = Project(timeline: [
			TimelineEntry(clip: ClipReference("one"), label: "shot"),
			TimelineEntry(group: "end", entries: [TimelineEntry(clip: ClipReference("four"))]),
		])
		let landed = project.duplicateEntries(at: [[0]], toParent: [1], index: 0)
		#expect(landed == [[1, 0]])
		#expect(project.rows.map(\.entry.source.description) == ["one", "@end", "one", "four"])
		#expect(project.entry(at: [1, 0])?.label == "shot-2")
		// And the original is still there, which is the whole difference
		// between this and a move.
		#expect(project.timeline.count == 2)
	}

	@Test func droppingPastTheEndOfASectionAppends() {
		var project = Project(timeline: [
			TimelineEntry(clip: ClipReference("one")),
			TimelineEntry(group: "end", entries: [TimelineEntry(clip: ClipReference("four"))]),
		])
		#expect(project.duplicateEntries(at: [[0]], toParent: [1], index: -1) == [[1, 1]])
		#expect(project.rows.map(\.entry.source.description) == ["one", "@end", "four", "one"])
	}

	@Test func twoCopiesArriveInTheOrderTheyWereIn() {
		var project = Project(timeline: [
			TimelineEntry(clip: ClipReference("a"), label: "first"),
			TimelineEntry(clip: ClipReference("b")),
			TimelineEntry(clip: ClipReference("c"), label: "last"),
		])
		let landed = project.duplicateEntries(at: [[2], [0]], toParent: [], index: 0)
		#expect(landed == [[0], [1]])
		#expect(project.timeline.map { $0.source.description } == ["a", "c", "a", "b", "c"])
		#expect(project.timeline.compactMap(\.label) == ["first-2", "last-2", "first", "last"])
	}

	/// A section and one of its own clips is one thing being copied. A second
	/// copy of the clip beside the section would be one more than was dragged.
	@Test func aSectionAndItsOwnClipIsOneCopy() {
		var project = Project(timeline: [
			TimelineEntry(group: "build", entries: [TimelineEntry(clip: ClipReference("two"))]),
		])
		project.duplicateEntries(at: [[0], [0, 0]], toParent: [], index: 1)
		#expect(project.rows.map(\.entry.source.description)
			== ["@build", "two", "@build-2", "two"])
	}

	/// A section *can* be copied into itself. The copy is taken before anything
	/// is put back, so it is a plain nesting rather than the paradox the same
	/// move would be.
	@Test func aSectionCanBeCopiedIntoItself() {
		var project = Project(timeline: [
			TimelineEntry(group: "build", entries: [TimelineEntry(clip: ClipReference("two"))]),
		])
		#expect(project.duplicateEntries(at: [[0]], toParent: [0], index: 0) == [[0, 0]])
		#expect(project.rows.map(\.entry.source.description)
			== ["@build", "@build-2", "two", "two"])
	}

	@Test func duplicatingSomethingThatIsNotThereDoesNothing() {
		var project = Project(timeline: [TimelineEntry(clip: ClipReference("one"))])
		#expect(project.duplicateEntry(at: [9]) == nil)
		#expect(project.duplicateEntries(at: [[0, 0]], toParent: [], index: 0) == [])
		#expect(project.timeline.count == 1)
	}

	// MARK: - The file

	@Test func theCopySurvivesTheFile() throws {
		var project = Project(timeline: [
			TimelineEntry(group: "shot", entries: [
				TimelineEntry(clip: ClipReference("two"), label: "middle",
				              overlays: [caption("Inside", .within(.group("shot"), from: 1, to: 2))]),
			]),
		])
		project.duplicateEntry(at: [0])
		let written = ProjectWriter.write(project)
		let back = try ProjectReader.read(written)
		#expect(back == project)
		#expect(ProjectWriter.write(back) == written)
		#expect(written.contains("@shot-2"))
	}
}

/// And what a duplicate does once the programme is laid out, which is the only
/// question that matters in the end.
@Suite struct DuplicatedTimingTests {

	private func fixture() throws -> URL {
		let directory = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("cuttr-duplicate-\(UUID().uuidString)")
		try FileManager.default.createDirectory(
			at: directory.appendingPathComponent("takes"), withIntermediateDirectories: true)
		try Data().write(to: directory.appendingPathComponent("a.mov"))
		let take = Take(video: "../a.mov", clips: [
			Clip(slug: "one", start: 0, end: 2),
			Clip(slug: "two", start: 2, end: 5),
		])
		try TakeWriter.write(take).write(
			to: directory.appendingPathComponent("takes/take-01.cuttr"),
			atomically: true, encoding: .utf8)
		return directory
	}

	private func project(_ timeline: [TimelineEntry]) -> Project {
		Project(takes: ["takes/take-01.cuttr"], timeline: timeline)
	}

	/// The caption written inside the entry is on twice afterwards, over the
	/// two placements and nowhere else.
	@Test func theCopyIsOnOverItsOwnPlacement() throws {
		let directory = try fixture()
		defer { try? FileManager.default.removeItem(at: directory) }
		var project = self.project([
			TimelineEntry(clip: ClipReference("two"),
			              overlays: [Overlay(kind: .text("Hello", style: nil), appearances: [],
			                                 arrival: .cut, departure: .cut)]),
		])
		project.duplicateEntry(at: [0])

		let resolved = try Resolver.resolve(project, baseURL: directory)
		// `two` runs three seconds, and it is on the programme twice.
		#expect(resolved.duration == 6)
		#expect(resolved.overlays.count == 2)
		let times = resolved.overlays.map { ($0.start, $0.end) }.sorted { $0.0 < $1.0 }
		#expect(times[0] == (0, 3))
		#expect(times[1] == (3, 6))
	}

	/// And the one the renaming is for: a caption inside a copied section that
	/// hangs on the section's *name*. Without the new name both copies of the
	/// caption would come on over the first section — and worse, `@shot` would
	/// be one section covering both, so both would cover the whole six seconds.
	@Test func aCopiedSectionsCaptionIsOnOverTheCopy() throws {
		let directory = try fixture()
		defer { try? FileManager.default.removeItem(at: directory) }
		var project = self.project([
			TimelineEntry(group: "shot", entries: [
				TimelineEntry(clip: ClipReference("two")),
			], overlays: [Overlay(kind: .text("Hello", style: nil),
			                      span: .marks(from: .group("shot"), to: .group("shot")),
			                      arrival: .cut, departure: .cut)]),
		])
		project.duplicateEntry(at: [0])

		let resolved = try Resolver.resolve(project, baseURL: directory)
		#expect(resolved.overlays.count == 2)
		let times = resolved.overlays.map { ($0.start, $0.end) }.sorted { $0.0 < $1.0 }
		#expect(times[0] == (0, 3))
		#expect(times[1] == (3, 6))
	}
}
