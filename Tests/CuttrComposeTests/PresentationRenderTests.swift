@preconcurrency import AVFoundation
import CoreGraphics
import CuttrKit
import Foundation
import Testing
@testable import CuttrCompose

/// The hold, rendered.
///
/// Everything else about this feature is arithmetic and is tested as
/// arithmetic. This one cannot be: a composition has no "freeze", the way to
/// ask for one is a single frame scaled to the length of the hold, and whether
/// that produces the frame the recording stopped on is a question about
/// AVFoundation rather than about this program. So the footage is a colour that
/// changes on a known schedule, the programme is rendered, and the frames are
/// read back and looked at.
@Suite struct PresentationRenderTests {

	/// Five seconds, a different flat colour each second.
	private func video(at url: URL) async throws {
		let size = CGSize(width: 64, height: 36)
		let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
		let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
			AVVideoCodecKey: AVVideoCodecType.h264,
			AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
		])
		input.expectsMediaDataInRealTime = false
		let adaptor = AVAssetWriterInputPixelBufferAdaptor(
			assetWriterInput: input,
			sourcePixelBufferAttributes: [
				kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
			])
		writer.add(input)
		writer.startWriting()
		writer.startSession(atSourceTime: .zero)
		let frames = 125   // five seconds at 25
		for frame in 0..<frames {
			while !input.isReadyForMoreMediaData {
				try? await Task.sleep(nanoseconds: 1_000_000)
			}
			var buffer: CVPixelBuffer?
			CVPixelBufferCreate(nil, Int(size.width), Int(size.height),
			                    kCVPixelFormatType_32BGRA, nil, &buffer)
			guard let buffer else { continue }
			CVPixelBufferLockBaseAddress(buffer, [])
			if let base = CVPixelBufferGetBaseAddress(buffer) {
				let bytes = base.assumingMemoryBound(to: UInt8.self)
				let stride = CVPixelBufferGetBytesPerRow(buffer)
				let colour = Self.schedule[min(4, frame / 25)]
				for y in 0..<Int(size.height) {
					for x in 0..<Int(size.width) {
						let at = y * stride + x * 4
						bytes[at] = colour.b       // BGRA
						bytes[at + 1] = colour.g
						bytes[at + 2] = colour.r
						bytes[at + 3] = 255
					}
				}
			}
			CVPixelBufferUnlockBaseAddress(buffer, [])
			adaptor.append(buffer,
			               withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 25))
		}
		input.markAsFinished()
		writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frames), timescale: 25))
		await writer.finishWriting()
	}

	/// One second each. Far apart on purpose: h.264 and a re-encode move a
	/// value by a few levels and these have to survive that without the test
	/// becoming a measurement.
	private static let schedule: [(r: UInt8, g: UInt8, b: UInt8)] = [
		(220, 30, 30),    // 0–1  red
		(30, 200, 30),    // 1–2  green
		(40, 60, 220),    // 2–3  blue
		(230, 210, 40),   // 3–4  yellow
		(240, 240, 240),  // 4–5  white
	]

	private func fixture() async throws -> URL {
		let directory = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("cuttr-hold-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		try await video(at: directory.appendingPathComponent("screen.mov"))
		try TakeWriter.write(Take(video: "screen.mov", clips: [
			Clip(slug: "demo", start: 0, end: 5),
		])).write(to: directory.appendingPathComponent("take.cuttr"),
		          atomically: true, encoding: .utf8)
		return directory
	}

	/// Which of the five it is, by nearest — or `nil` if it is nothing like any
	/// of them, which is what a letterboxed or half-blended frame would be.
	private func colour(_ image: CGImage) -> Int? {
		let width = image.width, height = image.height
		var pixels = [UInt8](repeating: 0, count: width * height * 4)
		guard let context = CGContext(
			data: &pixels, width: width, height: height, bitsPerComponent: 8,
			bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
			bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
		context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
		let middle = (height / 2) * width * 4 + (width / 2) * 4
		let found = (r: Double(pixels[middle]), g: Double(pixels[middle + 1]),
		             b: Double(pixels[middle + 2]))
		var best: (index: Int, distance: Double)?
		for (index, want) in Self.schedule.enumerated() {
			let distance = abs(found.r - Double(want.r)) + abs(found.g - Double(want.g))
				+ abs(found.b - Double(want.b))
			if best == nil || distance < best!.distance { best = (index, distance) }
		}
		guard let best, best.distance < 90 else { return nil }
		return best.index
	}

	/// The whole of it: the recording stops on the frame it had reached, stands
	/// there for the hold, and carries on with the frame that followed.
	///
	/// The discriminating assertion is the one in the middle. Without the hold,
	/// four seconds into this programme is the fourth second of the recording —
	/// yellow. With it, the recording is still standing on the blue frame it
	/// stopped on, and the programme is two seconds behind itself.
	@Test func theHoldFreezesThePictureAndThenCarriesOn() async throws {
		let directory = try await fixture()
		defer { try? FileManager.default.removeItem(at: directory) }
		let project = try ProjectReader.read("""
		takes: [take.cuttr]
		output:
		  size: 64x36
		  fps:  25
		timeline:
		  - clip: demo
		    presentations:
		      - at:    00:02.900
		        into:  [0, 0, 1, 1]
		        hold:  3
		        ramp:  0
		        scene: bullets
		        with:  {one: "Held here"}
		""")
		let resolved = try Resolver.resolve(project, baseURL: directory)
		#expect(resolved.duration == 8, "the programme did not get longer by the hold")

		let built = try await Renderer.build(resolved, host: .export)
		let generator = AVAssetImageGenerator(asset: built.composition)
		generator.videoComposition = built.videoComposition
		generator.requestedTimeToleranceBefore = .zero
		generator.requestedTimeToleranceAfter = .zero
		generator.appliesPreferredTrackTransform = true

		func frame(at seconds: Double) async throws -> Int? {
			let (image, _) = try await generator.image(
				at: CMTime(seconds: seconds, preferredTimescale: 600))
			return colour(image)
		}

		// Before it: the recording, playing.
		#expect(try await frame(at: 1.5) == 1, "green")
		// Inside it: the frame it stopped on, not the one the recording would
		// have reached.
		#expect(try await frame(at: 4.0) == 2, "blue — the held frame")
		// And out the far side, with the recording picking up where it left
		// off: a tenth of a second past the mark is still blue, and the second
		// after it is the yellow that followed.
		#expect(try await frame(at: 6.5) == 3, "yellow — the frame after the hold")
	}

	/// A programme with a hold in it comes out of a *whole export* with its
	/// frames and its overlays.
	///
	/// The one test here that runs the real thing end to end, and it exists
	/// because two plausible ways of holding a picture both pass everything
	/// else and fail this.
	///
	/// One frame `scaleTimeRange`d to the length of the hold builds a correct
	/// composition, renders a correct first pass, and then breaks the second:
	/// the file has the right duration and only the frames that were in the
	/// footage, spread out, and `AVVideoCompositionCoreAnimationTool` over an
	/// asset timed like that draws nothing at all — a programme with its hold
	/// and none of its captions. Laying the same frame down once per frame of
	/// the hold builds a composition of several hundred one-frame segments, and
	/// the export then loses two frames in three of them.
	///
	/// So: the count of frames that came out, and whether the caption is on
	/// them. Both were wrong, and neither showed anywhere else.
	@Test func aWholeExportKeepsItsFramesAndItsOverlays() async throws {
		let directory = try await fixture()
		defer { try? FileManager.default.removeItem(at: directory) }
		let project = try ProjectReader.read("""
		takes: [take.cuttr]
		output:
		  size: 64x36
		  fps:  25
		timeline:
		  - clip: demo
		    presentations:
		      - at:    00:01.000
		        into:  [0.02, 0.25, 0.46, 0.5]
		        hold:  2
		        ramp:  0
		        scene: boxes
		        with:  {one: "beside it"}
		""")
		let resolved = try Resolver.resolve(project, baseURL: directory)
		let out = directory.appendingPathComponent("out.mov")
		try await Renderer.export(resolved, to: out)

		let asset = AVURLAsset(url: out)
		#expect(abs(try await asset.load(.duration).seconds - 7) < 0.05)

		// Every frame of the film, not only the ones that were in the footage.
		let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
		let reader = try AVAssetReader(asset: asset)
		let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
		reader.add(output)
		reader.startReading()
		var frames = 0
		while output.copyNextSampleBuffer() != nil { frames += 1 }
		#expect(frames > 165, "\(frames) frames for seven seconds at 25 — the hold lost its own")

		// And the scene beside the held picture is on it. Sampled on the right,
		// where the picture is not: the recording is over on the left, so
		// anything bright here came from the second pass.
		let generator = AVAssetImageGenerator(asset: asset)
		generator.requestedTimeToleranceBefore = .zero
		generator.requestedTimeToleranceAfter = .zero
		let (frame, _) = try await generator.image(
			at: CMTime(seconds: 2, preferredTimescale: 600))
		var pixels = [UInt8](repeating: 0, count: frame.width * frame.height * 4)
		let context = try #require(CGContext(
			data: &pixels, width: frame.width, height: frame.height, bitsPerComponent: 8,
			bytesPerRow: frame.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
			bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
		context.draw(frame, in: CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
		var brightest = 0
		for y in 0..<frame.height {
			for x in (frame.width / 2)..<frame.width {
				brightest = max(brightest, Int(pixels[y * frame.width * 4 + x * 4]))
			}
		}
		#expect(brightest > 60, "nothing was drawn beside the held picture")
	}

	/// Nothing in the composition is time-scaled, which is the cheaper half of
	/// the test above and says which of the two failures it is when it goes
	/// red.
	@Test func nothingInTheCompositionIsTimeScaled() async throws {
		let directory = try await fixture()
		defer { try? FileManager.default.removeItem(at: directory) }
		let project = try ProjectReader.read("""
		takes: [take.cuttr]
		output:
		  size: 64x36
		  fps:  25
		timeline:
		  - clip: demo
		    presentations:
		      - at:    00:02.000
		        into:  [0.04, 0.2, 0.44, 0.6]
		        hold:  2
		        scene: bullets
		        with:  {one: "Held here"}
		overlays:
		  - text: over the hold
		    from: 00:02.500
		    to:   00:03.500
		""")
		let resolved = try Resolver.resolve(project, baseURL: directory)
		let built = try await Renderer.build(resolved, host: .export)
		let track = try #require(built.composition.tracks(withMediaType: .video).first)
		for segment in track.segments where !segment.isEmpty {
			#expect(segment.timeMapping.source.duration == segment.timeMapping.target.duration,
			        "a time-scaled segment: the overlay pass will draw nothing over it")
		}
		#expect(track.timeRange.duration.seconds == 7)
	}
}
