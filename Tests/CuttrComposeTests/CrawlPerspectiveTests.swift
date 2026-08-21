import CuttrKit
import Foundation
import Testing
@testable import CuttrCompose

/// A column laid on a plane tilted away from the viewer.
///
/// A key on `scale` shrinks a whole column about its middle: every line gets
/// smaller by the same factor and every gap closes by the same factor, so it
/// recedes without ever converging. A crawl converges — the lines nearer the
/// horizon are smaller *and* closer together than the ones below them — and
/// that is a projection rather than a scale.
@Suite struct CrawlPerspectiveTests {

	private let frame = CGSize(width: 1920, height: 1080)

	/// Six lines of one size, so the flat column is a plain grid and anything
	/// that changes between rows is the perspective.
	private func roll(tilt: Double) -> Scene.Roll {
		Scene.Roll(
			entries: [Scene.Roll.Entry(role: "", names: (1 ... 6).map { "line \($0)" })],
			line: 0.05, align: .centre, tilt: tilt)
	}

	private func project() -> Project {
		Project(timeline: [TimelineEntry(source: .card(Card(duration: 1)))],
		        styles: ["": TextStyle(size: 0.05)])
	}

	/// Every line is measured the same width, so the only thing the assertions
	/// can be reading is the layout.
	private func laid(_ tilt: Double) -> Scene.Roll.Layout {
		roll(tilt: tilt).laidOut(in: frame, project: project(),
		                        measure: { _, _, _ in CGSize(width: 400, height: 54) })
	}

	/// Rows top to bottom, so `pitch[0]` is the gap nearest the horizon.
	private func pitches(_ layout: Scene.Roll.Layout) -> [Double] {
		let ys = layout.lines.map(\.offset.y).sorted(by: >)
		return zip(ys, ys.dropFirst()).map { $0 - $1 }
	}

	@Test func flatIsWhatItAlwaysWas() {
		let gaps = pitches(laid(0))
		#expect(gaps.count == 5)
		// A plain grid: every gap the same.
		#expect(gaps.allSatisfy { abs($0 - gaps[0]) < 1e-9 })
		// And every line the same size.
		#expect(Set(laid(0).lines.map(\.style.size)).count == 1)
	}

	/// The whole complaint: the lines have to close up towards the top, not all
	/// shrink together.
	@Test func theLinesCloseUpTowardsTheHorizon() {
		let gaps = pitches(laid(0.35))
		#expect(gaps.count == 5)
		// Strictly increasing downwards: the gap nearest the horizon is the
		// smallest, every one below it is bigger than the one above.
		#expect(zip(gaps, gaps.dropFirst()).allSatisfy { $0 < $1 })
		// And by a real amount, not a rounding: the near gap is at least twice
		// the far one on this tilt.
		#expect(gaps.last! > gaps.first! * 2)
	}

	/// And they shrink as they go, which a uniform scale also does — so this is
	/// the half of it that was already possible, asserted so a change to the
	/// arithmetic cannot lose it.
	@Test func theLinesShrinkTowardsTheHorizon() {
		let byHeight = laid(0.35).lines.sorted { $0.offset.y > $1.offset.y }
		let sizes = byHeight.map(\.style.size)
		#expect(zip(sizes, sizes.dropFirst()).allSatisfy { $0 < $1 })
	}

	/// The far end comes to about the ratio it was asked for. That is what the
	/// number means, and it is why it is a ratio and not an angle.
	@Test func theFarEndIsTheRatioItWasAskedFor() {
		for tilt in [0.2, 0.35, 0.6] {
			let byHeight = laid(tilt).lines.sorted { $0.offset.y > $1.offset.y }
			guard let top = byHeight.first, let bottom = byHeight.last else { return }
			// Measured between the middles of the first and last row rather than
			// the very edges of the column, so it is near the ratio rather than
			// exactly it.
			let ratio = top.style.size / bottom.style.size
			#expect(ratio < 1)
			#expect(abs(ratio - tilt) < 0.25)
		}
	}

	/// The column comes back shorter, and that is load-bearing: a scroll is
	/// written from `height(in:project:)`, so the keys that carry a crawl past
	/// the frame have to be worked out against the height it is drawn at.
	@Test func theProjectedHeightIsWhatAScrollIsWrittenAgainst() {
		let flat = roll(tilt: 0).height(in: frame, project: project())
		let tilted = roll(tilt: 0.35).height(in: frame, project: project())
		#expect(tilted < flat)
		#expect(abs(tilted - flat * 0.35) < 1e-6)
	}

	/// Nonsense is flat rather than an exception or a division by nothing.
	@Test func aTiltThatIsNotOneIsFlat() {
		for tilt in [-1.0, 0, 1, 2] {
			let gaps = pitches(laid(tilt))
			#expect(gaps.allSatisfy { abs($0 - gaps[0]) < 1e-9 })
		}
	}

	@Test func aTiltSurvivesTheFile() throws {
		var project = self.project()
		project.scenes["crawl"] = Scene(parts: [
			Scene.Part(content: .roll(roll(tilt: 0.35)), keys: [Scene.Key(t: 0, x: 0.5, y: 0.5, opacity: 1)]),
		])
		let written = ProjectWriter.write(project)
		#expect(written.contains("tilt:"))
		let read = try ProjectReader.read(written)
		guard case .roll(let back)? = read.scenes["crawl"]?.parts.first?.content else {
			Issue.record("the roll did not come back")
			return
		}
		#expect(back.tilt == 0.35)
		#expect(ProjectWriter.write(read) == written)
	}

	/// A flat roll does not grow the key, so no existing file changes.
	@Test func aFlatRollDoesNotWriteATilt() {
		var project = self.project()
		project.scenes["credits"] = Scene(parts: [
			Scene.Part(content: .roll(roll(tilt: 0)), keys: [Scene.Key(t: 0, x: 0.5, y: 0.5, opacity: 1)]),
		])
		#expect(!ProjectWriter.write(project).contains("tilt:"))
	}
}
