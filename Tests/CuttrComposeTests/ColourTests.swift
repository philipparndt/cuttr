@preconcurrency import AVFoundation
import CuttrKit
import Foundation
import Testing
@testable import CuttrCompose

/// What colour the film is.
///
/// Left unsaid, AVFoundation infers it from the footage: one iPhone clip in a
/// project of twenty exported the whole programme as HLG BT.2020, every player
/// that is not HDR-aware showed all of it washed out, and the Rec. 709 clips in
/// it were flattened into HLG's range on the way in — a highlight the footage
/// put at 247 came out at 185. Adding a single card to that same project moved
/// the render onto the compositor, which *does* say 709, and the same footage
/// came out a different colour again.
///
/// So this is not about one path being right. It is about the three of them
/// giving the same answer, whatever features a project happens to use, because
/// "which colour is this film" cannot depend on whether somebody added a title
/// card.
@Suite struct ColourTests {

	/// Two seconds of black, so the composition is built from media
	/// AVFoundation has actually read. A zero-byte `.mov` resolves and does not
	/// build.
	private func video(at url: URL, seconds: Double) async throws {
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
		var buffer: CVPixelBuffer?
		CVPixelBufferCreate(nil, Int(size.width), Int(size.height),
		                    kCVPixelFormatType_32BGRA, nil, &buffer)
		let frames = Int(seconds * 25)
		if let buffer {
			for frame in 0..<frames {
				while !input.isReadyForMoreMediaData {
					try? await Task.sleep(nanoseconds: 1_000_000)
				}
				adaptor.append(buffer,
				               withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 25))
			}
		}
		input.markAsFinished()
		writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frames), timescale: 25))
		await writer.finishWriting()
	}

	/// A folder with a shot in it, and a take that cuts two clips out of it.
	private func fixture(look: Look = .none) async throws -> URL {
		let directory = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("cuttr-colour-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		try await video(at: directory.appendingPathComponent("shot.mov"), seconds: 2)
		try TakeWriter.write(Take(video: "shot.mov", clips: [
			Clip(slug: "one", start: 0, end: 1),
			Clip(slug: "two", start: 1, end: 2),
		], look: look)).write(to: directory.appendingPathComponent("take.cuttr"),
		          atomically: true, encoding: .utf8)
		return directory
	}

	private func built(_ text: String, in directory: URL) async throws -> Renderer.Built {
		let project = try ProjectReader.read("takes: [take.cuttr]\n" + text)
		return try await Renderer.build(try Resolver.resolve(project, baseURL: directory),
		                                host: .export)
	}

	/// What every path has to say.
	private func declares709(_ built: Renderer.Built) -> Bool {
		let video = built.videoComposition
		return video.colorPrimaries == AVVideoColorPrimaries_ITU_R_709_2
			&& video.colorTransferFunction == AVVideoTransferFunction_ITU_R_709_2
			&& video.colorYCbCrMatrix == AVVideoYCbCrMatrix_ITU_R_709_2
	}

	/// Straight cuts and nothing else: the path that hands AVFoundation's own
	/// frames back untouched. It still has to say what colour they are, because
	/// a composition that says nothing is a composition whose colour is decided
	/// by whatever the widest piece of footage in it happens to be.
	@Test func theExactPathSaysWhatColourTheFilmIs() async throws {
		let directory = try await fixture()
		defer { try? FileManager.default.removeItem(at: directory) }
		let built = try await built("timeline: [one, two]\n", in: directory)
		// The exact path: no compositor of ours, AVFoundation's frames.
		#expect(built.videoComposition.customVideoCompositorClass == nil)
		#expect(declares709(built))
	}

	/// A graded shot goes through Core Image instead. Same answer.
	@Test func theFilteredPathSaysTheSame() async throws {
		let directory = try await fixture(look: Look(saturation: 1.1))
		defer { try? FileManager.default.removeItem(at: directory) }
		let built = try await built("timeline: [one, two]\n", in: directory)
		#expect(declares709(built))
	}

	/// A card has no footage behind it, so only the compositor can make its
	/// frames. Same answer again.
	@Test func theCompositorPathSaysTheSame() async throws {
		let directory = try await fixture()
		defer { try? FileManager.default.removeItem(at: directory) }
		let built = try await built(
			"timeline:\n  - one\n  - card: 00:01.000\n    fill: \"#101010\"\n", in: directory)
		#expect(built.videoComposition.customVideoCompositorClass != nil)
		#expect(declares709(built))
	}

	/// A dissolve needs two frames at once, which is the compositor as well.
	@Test func aDissolveSaysTheSame() async throws {
		let directory = try await fixture()
		defer { try? FileManager.default.removeItem(at: directory) }
		let built = try await built(
			"timeline:\n  - one\n  - clip: two\n    over: 0.5\n", in: directory)
		#expect(declares709(built))
	}

	/// And the point of all of it: adding a card to a project does not change
	/// what colour its footage comes out.
	@Test func addingACardDoesNotChangeTheColourOfTheFilm() async throws {
		let directory = try await fixture()
		defer { try? FileManager.default.removeItem(at: directory) }
		let plain = try await built("timeline: [one, two]\n", in: directory)
		let carded = try await built(
			"timeline:\n  - one\n  - card: 00:01.000\n    fill: \"#101010\"\n  - two\n",
			in: directory)
		#expect(plain.videoComposition.colorPrimaries == carded.videoComposition.colorPrimaries)
		#expect(plain.videoComposition.colorTransferFunction
			== carded.videoComposition.colorTransferFunction)
		#expect(plain.videoComposition.colorYCbCrMatrix
			== carded.videoComposition.colorYCbCrMatrix)
	}
}
