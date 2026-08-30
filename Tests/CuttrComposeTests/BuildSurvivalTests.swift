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

	/// **The report.** A project whose media is not on this machine — cloned
	/// without it, or with one card still unread — used to resolve perfectly
	/// and then die in the build on AVFoundation's own account of it: "The
	/// operation could not be completed", and no preview of the hundred and
	/// nineteen clips that *were* there.
	///
	/// Now the resolver names the file, and the shot that cannot play plays as
	/// a pink card saying so — in a preview. An export is the other half of
	/// this and is below.
	@Test func aRecordingThatIsNotThereIsNamedAndPlaysAsPink() async throws {
		let at = try await fixture()
		defer { try? FileManager.default.removeItem(at: at) }
		try TakeWriter.write(Take(video: "../gone.mov", clips: [
			Clip(slug: "hole", start: 0, end: 2),
		])).write(to: at.appendingPathComponent("takes/gone.cuttr"),
		          atomically: true, encoding: .utf8)
		let project = try ProjectReader.read(Self.withAHole)
		let resolved = try Resolver.resolve(project, baseURL: at)
		// Named where somebody can act on it, and once however many placements
		// play it.
		#expect(resolved.warnings.contains { $0.contains("gone.mov") },
		        "nothing said which recording is missing: \(resolved.warnings)")
		#expect(resolved.warnings.count == 1)

		let built = try await Renderer.build(resolved, host: .preview)
		#expect(abs(resolved.duration - 6) < 0.01)
		let generator = AVAssetImageGenerator(asset: built.composition)
		generator.videoComposition = built.videoComposition
		generator.requestedTimeToleranceBefore = .zero
		generator.requestedTimeToleranceAfter = .zero
		// A corner of the frame rather than the middle of it, which is where
		// the words are.
		let image = try await generator.image(
			at: CMTime(seconds: 3, preferredTimescale: 600)).image
		var bytes = [UInt8](repeating: 0, count: 4)
		let context = try #require(CGContext(
			data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
			space: CGColorSpaceCreateDeviceRGB(),
			bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
		context.draw(image, in: CGRect(x: -20, y: -20,
		                               width: image.width, height: image.height))
		let (red, green, blue) = (Double(bytes[0]) / 255, Double(bytes[1]) / 255,
		                          Double(bytes[2]) / 255)
		#expect(red > 0.6 && green < 0.45 && blue > green,
		        "the hole is not pink: \(red), \(green), \(blue)")
	}

	/// And an export refuses, naming the file. A render is minutes of encoding
	/// and then a file to hand somebody: a hole in it is not something to find
	/// out about afterwards, and "there is a pink card at 00:02" is not what
	/// anybody meant to ask for.
	@Test func anExportRefusesAndNamesTheRecording() async throws {
		let at = try await fixture()
		defer { try? FileManager.default.removeItem(at: at) }
		try TakeWriter.write(Take(video: "../gone.mov", clips: [
			Clip(slug: "hole", start: 0, end: 2),
		])).write(to: at.appendingPathComponent("takes/gone.cuttr"),
		          atomically: true, encoding: .utf8)
		let resolved = try Resolver.resolve(try ProjectReader.read(Self.withAHole), baseURL: at)
		do {
			_ = try await Renderer.build(resolved, host: .export)
			Issue.record("the export built a programme with a hole in it")
		} catch let error as RenderError {
			#expect(error.localizedDescription.contains("gone.mov"),
			        "it did not say which file: \(error.localizedDescription)")
		}
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

	/// A shot, a shot whose recording is not there, and a shot.
	private static let withAHole = """
	takes: [takes/take.cuttr, takes/gone.cuttr]
	output: {size: 640x360, fps: 25}
	timeline: [one, hole, one]
	"""
}
