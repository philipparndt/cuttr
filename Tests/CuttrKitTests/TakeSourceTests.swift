import Foundation
import Testing
@testable import CuttrKit

/// Where a take came from, through the file and back.
///
/// The block is small and it is the whole difference between a project
/// somebody can publish and one they cannot, so it is held to the same two
/// rules as the rest of the file: what goes in comes out, and an unchanged
/// take writes an unchanged file.
@Suite struct TakeSourceTests {

	private func meme() -> Take {
		Take(
			video: "../memes/cat-typing.mp4",
			clips: [Clip(slug: "cat-typing", name: "Cat typing", start: 0, end: 2.48)],
			source: TakeSource(
				provider: "giphy", id: "l0HlvtIPzPdt2usKs",
				page: "https://giphy.com/gifs/cat-typing-l0HlvtIPzPdt2usKs",
				title: "Cat typing", attribution: "Powered By GIPHY"))
	}

	@Test func roundTrips() throws {
		let back = try TakeReader.read(TakeWriter.write(meme()))
		#expect(back == meme())
		#expect(back.source?.provider == "giphy")
		#expect(back.source?.attribution == "Powered By GIPHY")
	}

	@Test func writingIsStableForTheSameTake() {
		#expect(TakeWriter.write(meme()) == TakeWriter.write(meme()))
	}

	@Test func aTakeWithNoSourceSaysNothingAboutOne() {
		// A recording somebody made has nothing to declare, and a block of
		// empty keys would read as though it had.
		let plain = Take(video: "a.mov", clips: [Clip(slug: "intro", start: 0, end: 1)])
		#expect(!TakeWriter.write(plain).contains("source:"))
	}

	@Test func keysInsideTheBlockThatThisVersionDoesNotKnowSurvive() throws {
		// The same promise the take makes at the top level, one level down: a
		// later version that records the licence must not have it deleted by
		// an older build re-saving the file.
		let take = try TakeReader.read("""
		video: ../memes/x.mp4
		source:
		  provider: tenor
		  id: "12345"
		  licence: CC-BY
		clips:
		  - slug: x
		    start: 0
		    end: 1
		""")
		#expect(take.source?.extra["licence"] == "CC-BY")
		#expect(TakeWriter.write(take).contains("licence: CC-BY"))
	}

	@Test func aBlockWithNoProviderIsNotASource() throws {
		// Somebody's note to themselves under a key this program happens to
		// use. Worth carrying, not worth refusing the file over.
		let take = try TakeReader.read("""
		video: a.mov
		source: "shot on the roof"
		clips: []
		""")
		#expect(take.source == nil)
	}

	@Test func theProviderIsASlug() throws {
		// It is matched against a known list, and `GIPHY` typed by hand is the
		// same service as `giphy`.
		let take = try TakeReader.read("""
		video: a.mov
		source:
		  provider: GIPHY
		  id: abc
		clips: []
		""")
		#expect(take.source?.provider == "giphy")
	}
}
