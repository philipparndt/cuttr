@preconcurrency import AVFoundation
import CuttrKit
import Foundation
import Testing
@testable import CuttrCompose

/// What a build must survive.
///
/// A preview is built from every clip on the programme, and the window has one
/// composition or none. So anything in here that throws does not spoil a clip —
/// it takes down the play button, the quick look and the picture together, and
/// leaves an AVFoundation code in the corner as the only explanation.
///
/// This suite is about the ordinary programme staying built when something about
/// one recording is awkward.
@Suite struct BuildSurvivalTests {

	private func fixture(seconds: Double = 2) async throws -> URL {
		let at = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
			.appendingPathComponent("cuttr-build-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(
			at: at.appendingPathComponent("takes"), withIntermediateDirectories: true)
		let media = at.appendingPathComponent("shot.mov")
		let writer = try AVAssetWriter(outputURL: media, fileType: .mov)
		let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
			AVVideoCodecKey: AVVideoCodecType.h264,
			AVVideoWidthKey: 64, AVVideoHeightKey: 36,
		])
		input.expectsMediaDataInRealTime = false
		let adaptor = AVAssetWriterInputPixelBufferAdaptor(
			assetWriterInput: input, sourcePixelBufferAttributes: [
				kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
		writer.add(input)
		writer.startWriting()
		writer.startSession(atSourceTime: .zero)
		var buffer: CVPixelBuffer?
		CVPixelBufferCreate(nil, 64, 36, kCVPixelFormatType_32BGRA, nil, &buffer)
		if let buffer {
			for frame in 0..<Int(seconds * 25) {
				while !input.isReadyForMoreMediaData {
					try? await Task.sleep(nanoseconds: 1_000_000)
				}
				adaptor.append(buffer,
				               withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 25))
			}
		}
		input.markAsFinished()
		writer.endSession(atSourceTime: CMTime(value: CMTimeValue(seconds * 25), timescale: 25))
		await writer.finishWriting()

		try TakeWriter.write(Take(video: "../shot.mov", clips: [
			Clip(slug: "one", start: 0, end: seconds),
		])).write(to: at.appendingPathComponent("takes/take.cuttr"),
		          atomically: true, encoding: .utf8)
		return at
	}

	/// **The ordinary programme.** A clip, an overlay, no treatments — the
	/// commonest project there is, and the one whose preview must never depend
	/// on machinery it does not use.
	@Test func aPlainProgrammeBuilds() async throws {
		let at = try await fixture()
		defer { try? FileManager.default.removeItem(at: at) }
		let project = try ProjectReader.read("""
		takes: [takes/take.cuttr]
		output:
		  size: 640x360
		  fps:  25
		timeline:
		  - clip: one
		overlays:
		  - text: hello
		    from: 00:00.500
		    to:   00:01.500
		""")
		let resolved = try Resolver.resolve(project, baseURL: at)
		let built = try await Renderer.build(resolved, host: .preview)
		let track = try #require(built.composition.tracks(withMediaType: .video).first)
		#expect(track.timeRange.duration.seconds > 1.9)
		#expect(built.composition.duration.seconds > 1.9)
	}

	/// And it builds without ever asking a track anything a hold would need.
	///
	/// The regression this is about: the time range of every clip's source was
	/// loaded on the way past, with a bare `try`, for a number only a held
	/// picture uses. One recording that would not answer took the whole build
	/// with it — no picture, no play, no look — for a programme that had no
	/// holds in it at all.
	@Test func aProgrammeWithNoHoldsAsksNothingOfTheSource() async throws {
		let at = try await fixture()
		defer { try? FileManager.default.removeItem(at: at) }
		let project = try ProjectReader.read("""
		takes: [takes/take.cuttr]
		output: {size: 640x360, fps: 25}
		timeline: [one]
		""")
		let resolved = try Resolver.resolve(project, baseURL: at)
		#expect(resolved.clips.allSatisfy { $0.presentations.isEmpty })
		// Nothing is held, so `playing` is one stretch and the filler's
		// arithmetic is never reached.
		#expect(resolved.clips.first?.playing.count == 1)
		#expect(resolved.clips.first?.playing.first?.isHeld == false)
		_ = try await Renderer.build(resolved, host: .preview)
	}

	/// A treatment still builds, which is the other half: making the load
	/// conditional must not stop a hold from getting its filler.
	@Test func aProgrammeWithAHoldStillBuilds() async throws {
		let at = try await fixture(seconds: 4)
		defer { try? FileManager.default.removeItem(at: at) }
		let project = try ProjectReader.read("""
		takes: [takes/take.cuttr]
		output: {size: 640x360, fps: 25}
		timeline:
		  - clip: one
		    presentations:
		      - at:    00:01.000
		        into:  [0.04, 0.2, 0.44, 0.6]
		        hold:  2
		        scene: bullets
		        with:  {one: "held"}
		""")
		let resolved = try Resolver.resolve(project, baseURL: at)
		#expect(abs(resolved.duration - 6) < 0.01)
		let built = try await Renderer.build(resolved, host: .preview)
		let track = try #require(built.composition.tracks(withMediaType: .video).first)
		#expect(abs(track.timeRange.duration.seconds - 6) < 0.1,
		        "the hold lost its filler: \(track.timeRange.duration.seconds)")
	}
}
