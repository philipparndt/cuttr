import Foundation
import Testing
@testable import CuttrKit

/// Where the silences are, and what they make of the text.
@MainActor @Suite struct TranscriptShapeTests {

	/// Four words, then half a second, then two, then three seconds, then one.
	private let said = Transcript(words: [
		Word(start: 0.0, end: 0.4, text: "eins"),
		Word(start: 0.4, end: 0.8, text: "zwei"),
		Word(start: 1.4, end: 1.8, text: "drei"),
		Word(start: 4.9, end: 5.3, text: "vier"),
	])

	@Test func aPauseIsAsLongAsItIs() {
		#expect(said.silence(after: 0) == .none)
		#expect(said.silence(after: 1) == .beat)
		#expect(said.silence(after: 2) == .rest)
		// Nothing follows the last word, and nothing is what it says.
		#expect(said.silence(after: 3) == .none)
		#expect(said.silence(after: 9) == .none)
	}

	/// The unit somebody means when they point at a line.
	@Test func aLineIsWhatIsBetweenTwoSilences() {
		#expect(said.segment(around: 0) == 0..<2)
		#expect(said.segment(around: 1) == 0..<2)
		#expect(said.segment(around: 2) == 2..<3)
		#expect(said.segment(around: 3) == 3..<4)
		// Out of range is answered rather than crashed: a click lands where it
		// lands.
		#expect(said.segment(around: 99) == 3..<4)
	}

	/// One long take is one paragraph, which is the thing this replaced.
	@Test func wordsWithNoSilenceInThemAreOneLine() {
		let solid = Transcript(words: (0..<20).map {
			Word(start: Double($0) * 0.3, end: Double($0) * 0.3 + 0.3, text: "w\($0)")
		})
		#expect(solid.segment(around: 10) == 0..<20)
		#expect((0..<19).allSatisfy { solid.silence(after: $0) == .none })
	}
}

/// The moments a trim can be aimed at.
@MainActor @Suite struct TranscriptEdgeTests {

	@Test func theEdgesAreWhereTheTalkingStartsAndStops() {
		let said = Transcript(words: [
			Word(start: 1.0, end: 1.4, text: "eins"),
			Word(start: 1.4, end: 1.8, text: "zwei"),
			Word(start: 4.0, end: 4.4, text: "drei"),
		])
		// The head of the take, both sides of the silence, and the tail —
		// and *not* the boundary between "eins" and "zwei", which is in the
		// middle of a breath.
		#expect(said.edges == [1.0, 1.8, 4.0, 4.4])
	}

	@Test func nothingSaidHasNoEdges() {
		#expect(Transcript().edges.isEmpty)
	}
}
