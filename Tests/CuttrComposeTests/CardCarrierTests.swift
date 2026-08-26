@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import CuttrCompose

/// The black movie a card is carried on, and the way it went wrong.
///
/// A card is a stretch of programme with no footage under it, so the renderer
/// writes a few seconds of black for the compositor to paint over and keeps it
/// between renders — one per shape and length, named for both.
///
/// It was kept on the strength of the file *existing*. A render killed part way
/// through left a half-written movie behind, and every later render of that
/// shape and length picked it up and failed with `Cannot Decode` — permanently,
/// with nothing on screen to say a cached file was involved. The one that did it
/// here read as a perfectly good two-second h.264 movie to every tool that
/// looked at its headers.
@Suite struct CardCarrierTests {

	private let size = CGSize(width: 480, height: 270)

	private func url(_ seconds: Double, rate: Double = 25) -> URL {
		Renderer.carrierURL(size: size, frames: Int((seconds * rate).rounded(.up)), rate: rate)
	}

	@Test func aCarrierIsWrittenAndPlays() async throws {
		let at = url(0.4)
		try? FileManager.default.removeItem(at: at)
		let made = try await Renderer.carrier(size: size, seconds: 0.4, framesPerSecond: 25)
		let track = try #require(made?.track)
		#expect(abs(try await track.load(.timeRange).duration.seconds - 0.4) < 0.05)
		#expect(FileManager.default.fileExists(atPath: at.path))
	}

	/// **The one that matters.** The folder is this launch's, so nothing another
	/// process left behind is ever consulted.
	///
	/// The bug was a carrier kept under a fixed name in the temporary directory
	/// and reused by every later run. A file left there by a render that did not
	/// finish made every later render of that shape fail with `Cannot Decode`,
	/// for ever, with nothing in the failure naming a cached file. Putting a
	/// bad one where the old name was must now do nothing at all.
	@Test func nothingFromAnotherRunIsConsulted() async throws {
		let old = FileManager.default.temporaryDirectory
			.appendingPathComponent("cuttr-card-480x270-15@25.mov")
		try Data("not a movie at all".utf8).write(to: old)
		defer { try? FileManager.default.removeItem(at: old) }

		let made = try await Renderer.carrier(size: size, seconds: 0.6, framesPerSecond: 25)
		let track = try #require(made?.track, "a carrier from another run was used")
		#expect(abs(try await track.load(.timeRange).duration.seconds - 0.6) < 0.05)
		// And what it wrote is not where the old one was.
		#expect(url(0.6).path != old.path)
	}

	/// The folder is named for this launch and nothing else is in it, which is
	/// the whole of why existence is enough to trust.
	@Test func theFolderBelongsToThisRun() {
		let at = url(0.6).deletingLastPathComponent()
		#expect(at.lastPathComponent.hasPrefix("cuttr-cards-"))
		#expect(at.lastPathComponent.count > "cuttr-cards-".count + 30,
		        "the folder is not unique to this launch")
	}

	/// While it is being written it is under a name nothing looks for, so a
	/// process that dies mid-write leaves a stray temporary file rather than a
	/// poisoned one. Checked by what is left behind when it is done: the
	/// carrier, and nothing beside it.
	@Test func itIsMovedIntoPlaceRatherThanWrittenInPlace() async throws {
		let at = url(0.3)
		try? FileManager.default.removeItem(at: at)
		_ = try await Renderer.carrier(size: size, seconds: 0.3, framesPerSecond: 25)
		let beside = try FileManager.default.contentsOfDirectory(
			atPath: at.deletingLastPathComponent().path)
		#expect(!beside.contains { $0.hasPrefix(".\(at.lastPathComponent)") },
		        "a half-written carrier was left behind")
	}

	/// A whole one is kept. Writing a second of black again for every card of
	/// the same shape is work nobody sees, which is the reason the cache is
	/// there at all.
	@Test func aWholeCarrierIsKept() async throws {
		let at = url(0.7)
		try? FileManager.default.removeItem(at: at)
		_ = try await Renderer.carrier(size: size, seconds: 0.7, framesPerSecond: 25)
		let first = try #require(try? FileManager.default.attributesOfItem(atPath: at.path))
		let stamp = first[.modificationDate] as? Date
        try? await Task.sleep(nanoseconds: 1_100_000_000)
		_ = try await Renderer.carrier(size: size, seconds: 0.7, framesPerSecond: 25)
		let again = try #require(try? FileManager.default.attributesOfItem(atPath: at.path))
		#expect((again[.modificationDate] as? Date) == stamp, "it was written again")
	}
}
