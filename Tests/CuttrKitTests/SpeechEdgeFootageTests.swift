import Foundation
import Testing
@testable import CuttrKit

/// The edges, on the recording somebody actually complained about.
///
/// Run with the take:
///
///     CUTTR_FOOTAGE=/Volumes/500G/DorisWalter70/mia-take-1.cuttr \
///         xcrun swift test --filter SpeechEdgeFootageTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CUTTR_FOOTAGE"] != nil))
struct SpeechEdgeFootageTests {

	/// The two things that were wrong: a mark in the silence before a burst,
	/// and no mark at all where a sentence plainly ends. The second is the one
	/// with a number attached — 4:01.000 on the programme's clock, where the
	/// user put their playhead and found nothing to snap to.
	@Test func theEndOfASentenceIsAnEdge() async throws {
		let takeURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CUTTR_FOOTAGE"]!)
		let take = try TakeReader.read(try String(contentsOf: takeURL, encoding: .utf8))
		guard let audio = take.audio else {
			Issue.record("this take has no separate recording, so it is not the one this is about")
			return
		}
		let url = URL(fileURLWithPath: audio.file, relativeTo: takeURL.deletingLastPathComponent())
		let wave = try await WaveformExtractor.extract(url: url)
		let edges = SpeechEdges.edges(in: wave, shift: audio.offset)

		// One every second and a half or so over five minutes: the shape of a
		// conversation, not a mark per word and not a mark per sentence.
		#expect(edges.count > 100)
		#expect(edges.count < 400)

		let asked = 241.0
		let nearest = edges.min { abs($0 - asked) < abs($1 - asked) }
		guard let nearest else {
			Issue.record("no edges at all")
			return
		}
		// Within a tenth of a second, which is what a dozen points comes to at
		// the zoom somebody trims at.
		#expect(abs(nearest - asked) < 0.12)

		// And they are on the programme's clock: the recorder rolled eleven
		// seconds before the camera, so an edge at its very start is negative.
		#expect(edges.allSatisfy { $0 > audio.offset - 1 })
	}
}
