@preconcurrency import AVFoundation
import CuttrKit
import Foundation
import Testing
@testable import CuttrCompose
@testable import CuttrRecord

/// What a recording leaves behind.
///
/// Nothing here records anything — that needs a screen, a permission and a
/// browser, none of which a test may assume. What it does check is the part
/// that goes wrong quietly: what is written when a recording stops, and whether
/// recording the same thing twice keeps both.
@MainActor @Suite struct ScreencastTests {

	private func folder() throws -> URL {
		let at = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
			.appendingPathComponent("cuttr-record-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: at, withIntermediateDirectories: true)
		return at
	}

	/// A movie of a known length, so the take written for it can be checked
	/// against something.
	private func movie(at url: URL, seconds: Double) async throws {
		let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
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

	private func cast(_ project: URL) -> Screencast {
		Screencast(
			recording: Recording(name: "install-demo", url: "https://example.com"),
			project: project)
	}

	/// A recording arrives as *material*: the media beside the project and a
	/// take for it, so it is in the material tree without anybody importing
	/// anything.
	@Test func aRecordingLandsAsATake() async throws {
		let project = try folder()
		defer { try? FileManager.default.removeItem(at: project) }
		let media = project.appendingPathComponent("install-demo.mov")
		try await movie(at: media, seconds: 2)

		let written = try cast(project).writeTake(for: media)
		#expect(written.lastPathComponent == "install-demo.cuttr")
		let take = try TakeReader.read(String(contentsOf: written, encoding: .utf8))
		#expect(take.video == "../install-demo.mov")
		#expect(take.clips.count == 1)
		#expect(take.clips.first?.slug == "install-demo")
	}

	/// The clock starts at nought at the first frame, so the time somebody
	/// reads off the window while recording is the time they can cut to
	/// afterwards.
	@Test func theClipCoversTheWholeRecordingFromNought() async throws {
		let project = try folder()
		defer { try? FileManager.default.removeItem(at: project) }
		let media = project.appendingPathComponent("install-demo.mov")
		try await movie(at: media, seconds: 2)

		let written = try cast(project).writeTake(for: media)
		let take = try TakeReader.read(String(contentsOf: written, encoding: .utf8))
		let clip = try #require(take.clips.first)
		#expect(clip.start == 0)
		#expect(abs(clip.end - 2) < 0.1, "the clip is \(clip.end) long")
	}

	/// **A second recording is a second take.** The reason to record something
	/// again is nearly always to compare the two, and overwriting the first
	/// makes that impossible with no way back.
	@Test func recordingItAgainKeepsBoth() async throws {
		let project = try folder()
		defer { try? FileManager.default.removeItem(at: project) }
		let screencast = cast(project)

		let first = screencast.unused(project.appendingPathComponent("install-demo.mov"))
		try await movie(at: first, seconds: 1)
		_ = try screencast.writeTake(for: first)

		let second = screencast.unused(project.appendingPathComponent("install-demo.mov"))
		#expect(second.lastPathComponent == "install-demo-2.mov",
		        "the second recording would have written over the first")
		try await movie(at: second, seconds: 1)
		let take = try screencast.writeTake(for: second)
		#expect(take.lastPathComponent == "install-demo-2.cuttr")

		#expect(FileManager.default.fileExists(atPath: first.path))
		#expect(FileManager.default.fileExists(
			atPath: project.appendingPathComponent("takes/install-demo.cuttr").path))
	}

	/// Every refusal says which of the things that can be wrong is wrong, by
	/// name, because "recording failed" is a sentence nobody can act on.
	@Test func everyRefusalSaysWhatToDo() {
		#expect(Screencast.Trouble.nothingToDrive(Browser.missing).described
			.contains("Google Chrome"))
		// And the sentence belongs to whatever was being recorded: somebody who
		// uses Ghostty should not be told about Chrome.
		let terminal = Recording(name: "the-build", terminal: .ghostty)
		#expect(Sitters.missing(for: terminal).contains("Ghostty"))
		#expect(!Sitters.missing(for: terminal).contains("Chrome"))
		#expect(Screencast.Trouble.noConsent(.refused).described.contains("Screen Recording"))
		let sized = Screencast.Trouble.wrongSize(
			got: CGSize(width: 1280, height: 788), wanted: CGSize(width: 1280, height: 720))
		#expect(sized.described.contains("1280×788"))
		#expect(sized.described.contains("1280×720"))
		#expect(Screencast.Trouble.cannotWrite("the disk is full").described
			.contains("the disk is full"))
	}
}
