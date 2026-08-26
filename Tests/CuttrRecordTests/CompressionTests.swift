@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import CuttrRecord

/// How a screencast is encoded, and how big that makes it.
///
/// A screen recording is not footage and compresses nothing like it: flat
/// colour, hard edges, and long stretches where nothing moves at all. The
/// settings are chosen for that, and this suite is the record of what was
/// chosen — including the numbers, because a bit-rate that drifts is a file
/// that quietly triples and nobody notices until a project will not fit on a
/// disk.
@Suite struct CompressionTests {

	private func settings(_ width: Int, _ height: Int, _ fps: Double = 30) -> [String: Any] {
		WindowRecorder.settings(
			size: CGSize(width: width, height: height), framesPerSecond: fps)
	}

	/// HEVC, always. h.264 spends its bit-rate worst on exactly what a
	/// screencast is made of, and shows it as rings around type.
	@Test func itIsAlwaysHevc() {
		#expect(settings(1280, 720)[AVVideoCodecKey] as? AVVideoCodecType == .hevc)
	}

	/// **Per pixel rather than a number.** One figure would be starvation at
	/// 2560×1440 and waste at 640×360.
	@Test func theBitRateFollowsThePixels() throws {
		func bits(_ width: Int, _ height: Int) throws -> Int {
			let properties = try #require(
				settings(width, height)[AVVideoCompressionPropertiesKey] as? [String: Any])
			return try #require(properties[AVVideoAverageBitRateKey] as? Int)
		}
		let small = try bits(1280, 720)
		let large = try bits(2560, 1440)
		#expect(large == small * 4, "four times the pixels, four times the bits")
	}

	/// And it is a figure somebody can hold in their head: about two megabits
	/// at 720p, which is around fifteen megabytes a minute.
	@Test func aScreencastIsAboutFifteenMegabytesAMinute() throws {
		let properties = try #require(
			settings(1280, 720)[AVVideoCompressionPropertiesKey] as? [String: Any])
		let bits = try #require(properties[AVVideoAverageBitRateKey] as? Int)
		let megabytesPerMinute = Double(bits) * 60 / 8 / 1_000_000
		#expect(megabytesPerMinute > 8 && megabytesPerMinute < 25,
		        "\(Int(megabytesPerMinute)) MB a minute is not what the panel says")
	}

	/// The rate follows the frame rate too, because bits are per frame.
	@Test func theBitRateFollowsTheFrameRate() throws {
		func bits(_ fps: Double) throws -> Int {
			let properties = try #require(
				settings(1280, 720, fps)[AVVideoCompressionPropertiesKey] as? [String: Any])
			return try #require(properties[AVVideoAverageBitRateKey] as? Int)
		}
		#expect(try bits(60) == (try bits(30)) * 2)
	}

	/// **Keyframes every four seconds, not every one.** A keyframe is a whole
	/// picture and a screencast is mostly one picture, so they are the largest
	/// single thing in the file — and four seconds is still close enough to
	/// scrub without decoding half the recording.
	@Test func keyframesAreFourSecondsApart() throws {
		let properties = try #require(
			settings(1280, 720)[AVVideoCompressionPropertiesKey] as? [String: Any])
		let gap = try #require(properties[AVVideoMaxKeyFrameIntervalDurationKey] as? Double)
		#expect(gap == 4)
	}

	/// The settings are settings AVFoundation will take. A dictionary that is
	/// wrong is refused at `canAdd`, which is a failure at record time and a
	/// recording nobody made.
	@Test func theyAreSettingsAWriterAccepts() throws {
		let at = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
			.appendingPathComponent("cuttr-compression-\(UUID().uuidString).mov")
		defer { try? FileManager.default.removeItem(at: at) }
		let writer = try AVAssetWriter(outputURL: at, fileType: .mov)
		let input = AVAssetWriterInput(mediaType: .video,
		                               outputSettings: settings(1280, 720))
		#expect(writer.canAdd(input))
	}
}
