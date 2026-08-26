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

	/// **The one that matters.** A file that is there and cannot be played is
	/// written again rather than used.
	@Test func aBrokenCarrierIsWrittenAgainRatherThanUsed() async throws {
		let at = url(0.6)
		try? FileManager.default.removeItem(at: at)
		// A whole one first, so what is being tested is the *replacing* of a
		// bad one and not the writing of a missing one.
		_ = try await Renderer.carrier(size: size, seconds: 0.6, framesPerSecond: 25)
		let whole = try #require(try? Data(contentsOf: at))
		#expect(whole.count > 0)

		// And now a half-written one, which is what a killed render leaves.
		try whole.prefix(whole.count / 3).write(to: at)
		let made = try await Renderer.carrier(size: size, seconds: 0.6, framesPerSecond: 25)
		let track = try #require(made?.track, "a broken carrier was handed back")
		#expect(abs(try await track.load(.timeRange).duration.seconds - 0.6) < 0.05)
		// Rewritten, not patched: the file on disk is a whole movie again.
		let now = try #require(try? Data(contentsOf: at))
		#expect(now.count > whole.count / 2)
	}

	/// Nothing at all where a carrier should be is a file that is written, not
	/// an error — that half always worked and must go on working.
	@Test func rubbishWhereACarrierShouldBeIsReplaced() async throws {
		let at = url(0.5)
		try Data("not a movie at all".utf8).write(to: at)
		let made = try await Renderer.carrier(size: size, seconds: 0.5, framesPerSecond: 25)
		#expect(made?.track != nil)
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
