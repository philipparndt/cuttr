import AppKit
import Foundation
import Testing
@testable import CuttrKit
@testable import CuttrUI

/// Trimming against the speech rather than against the grid.
@MainActor @Suite struct SpeechSnapTests {

	/// Where the talking starts and stops, as the timeline would have worked it
	/// out from the shape it draws.
	private let edges = [1.0, 1.8, 4.0, 4.4]

	private func timeline() -> TimelineView {
		let view = TimelineView(frame: NSRect(x: 0, y: 0, width: 800, height: 200))
		view.setZoom(0.01)   // a hundredth of a second per point
		return view
	}

	/// Within a dozen or so points of a mark, that is what was meant.
	@Test func aMarkNearTheEndOfASentenceGoesToIt() {
		let view = timeline()
		#expect(view.speechEdge(near: 1.85, in: edges) == 1.8)
		#expect(view.speechEdge(near: 3.95, in: edges) == 4.0)
	}

	/// Further away than that, nobody pointed at it.
	@Test func aMarkNowhereNearOneIsLeftAlone() {
		#expect(timeline().speechEdge(near: 2.6, in: edges) == nil)
	}

	/// "Near" is in points rather than in seconds, so it means the same thing
	/// at every zoom: zoomed right in, a mark a fifth of a second away is a
	/// long way across the screen and is not what was meant.
	@Test func nearMeansNearOnScreenRatherThanInTime() {
		let view = timeline()
		view.setZoom(0.001)
		#expect(view.speechEdge(near: 1.85, in: edges) == nil)
		view.setZoom(0.05)
		#expect(view.speechEdge(near: 1.85, in: edges) == 1.8)
	}

	/// A take with no sound decoded has nothing to aim at, and the trim behaves
	/// as it always did.
	@Test func withNoRecordingThereIsNothingToSnapTo() {
		#expect(timeline().speechEdge(near: 1.85, in: []) == nil)
		#expect(timeline().speechEdges.isEmpty)
	}
}

/// A pane's heading and the controls in it.
@MainActor @Suite struct FoldingHeadTests {

	/// The words pane grew a language pop-up and its provenance label started
	/// printing itself over the heading, because an accessory pinned only by
	/// its trailing edge grows leftwards for ever.
	@Test func theAccessoryDoesNotCrossTheHeading() {
		let wide = NSTextField(labelWithString: String(repeating: "long ", count: 30))
		let pane = FoldingPane("words", content: NSView(), accessory: wide)
		pane.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
		pane.layoutSubtreeIfNeeded()
		guard let head = wide.superview,
		      let title = head.subviews.compactMap({ $0 as? NSTextField })
			      .first(where: { $0.stringValue == "WORDS" })
		else {
			Issue.record("the heading is not where this test thought it was")
			return
		}
		#expect(wide.frame.minX >= title.frame.maxX)
		#expect(wide.frame.maxX <= head.frame.width)
	}
}
