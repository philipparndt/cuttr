@preconcurrency import AVFoundation
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import CuttrKit

/// A file macOS will hand over and cannot decode.
///
/// The case this is about is WebM, and what makes it worth a suite is that
/// nothing about it looks wrong until the end. macOS knows the extension, gives
/// it a type, and says that type conforms to `public.movie` — so every open
/// panel in this program offers it and accepts it. AVFoundation then cannot open
/// it, because it has no VP8, no VP9 and no Matroska.
///
/// What that produced was a take that resolved, appeared in the material tree,
/// and had no picture, no waveform and no render.
@Suite struct UnreadableMediaTests {

	/// The trap, stated: this is *why* a `.webm` gets as far as it does.
	@Test func macOSSaysAWebmIsAMovie() throws {
		let type = try #require(UTType(filenameExtension: "webm"))
		// If this ever stops being true, the open panels stop offering webm and
		// half of this suite is about a problem nobody has.
		#expect(type.conforms(to: .movie))
	}

	/// And the refusal names it, says what nothing on the Mac can do, and says
	/// what to do instead.
	@Test func theRefusalNamesTheFormatAndWhatToDo() {
		let said = Unreadable(url: URL(fileURLWithPath: "/films/demo.webm"), format: "WebM")
			.errorDescription ?? ""
		#expect(said.contains("WebM"))
		#expect(said.contains("demo.webm"))
		#expect(said.contains(".mov"), "nothing said what to do about it")
	}

	/// A format nobody would recognise by name says the file instead, because
	/// the extension is what somebody can act on.
	@Test func anUnnamedFormatSaysTheFile() {
		let said = Unreadable(url: URL(fileURLWithPath: "/films/demo.xyz"), format: nil)
			.errorDescription ?? ""
		#expect(said.contains("demo.xyz"))
		#expect(said.contains(".mov"))
	}

	/// The names are for wording only, and are looked up *after* a file has
	/// failed — guessing from an extension whether something will work is how a
	/// format that starts being supported goes on being refused.
	@Test func theNamesAreTheOnesSomebodyWouldUse() {
		#expect(Unreadable.named(URL(fileURLWithPath: "a.webm")) == "WebM")
		#expect(Unreadable.named(URL(fileURLWithPath: "a.WEBM")) == "WebM")
		#expect(Unreadable.named(URL(fileURLWithPath: "a.mkv")) == "Matroska")
		#expect(Unreadable.named(URL(fileURLWithPath: "a.mov")) == nil)
	}

	// MARK: - Against a real file

	/// **The one that matters.** A real WebM, made here, refused by name.
	@Test func aWebmIsRefusedByName() async throws {
		let at = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
			.appendingPathComponent("cuttr-webm-\(UUID().uuidString).webm")
		defer { try? FileManager.default.removeItem(at: at) }
		// Not a real WebM — a real one cannot be made without an encoder this
		// program does not have. What is being tested is the path a file takes
		// when AVFoundation will not open it, and bytes that are not a movie
		// take exactly that path.
		try Data("not a movie".utf8).write(to: at)

		await #expect(throws: Unreadable.self) {
			_ = try await MediaProbe.probe(at)
		}
		do {
			_ = try await MediaProbe.probe(at)
		} catch let trouble as Unreadable {
			#expect(trouble.errorDescription?.contains("WebM") == true)
		}
	}

	/// A file that is not there is *missing*, which is a different thing and
	/// already has its own answer — saying "convert it to .mov" about a path
	/// somebody mistyped would be worse than the error it replaced.
	@Test func aMissingFileIsNotAnUnreadableOne() async {
		let nowhere = URL(fileURLWithPath: "/nowhere/at/all/demo.webm")
		do {
			_ = try await MediaProbe.probe(nowhere)
			Issue.record("a missing file probed")
		} catch is Unreadable {
			Issue.record("a missing file was called unreadable")
		} catch {
			// Whatever AVFoundation says about a file that is not there.
		}
	}

	/// And something cuttr *can* read still reads.
	@Test func aRealMovieStillProbes() async throws {
		let at = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
			.appendingPathComponent("cuttr-ok-\(UUID().uuidString).mov")
		defer { try? FileManager.default.removeItem(at: at) }
		let writer = try AVAssetWriter(outputURL: at, fileType: .mov)
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
			for frame in 0..<25 {
				while !input.isReadyForMoreMediaData {
					try? await Task.sleep(nanoseconds: 1_000_000)
				}
				adaptor.append(buffer,
				               withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 25))
			}
		}
		input.markAsFinished()
		writer.endSession(atSourceTime: CMTime(value: 25, timescale: 25))
		await writer.finishWriting()

		let info = try await MediaProbe.probe(at)
		#expect(info.hasVideo)
		#expect(abs(info.duration - 1) < 0.1)
	}
}
