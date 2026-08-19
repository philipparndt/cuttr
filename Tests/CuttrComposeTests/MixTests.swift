@preconcurrency import AVFoundation
import CuttrKit
import Foundation
import Testing
@testable import CuttrCompose

/// What the composition comes out as: which lanes exist, what is on them, and
/// where the holes are.
///
/// Built with real files rather than empty ones, because everything this is
/// about — a track with no audio in it, a lane with a hole in it — is a fact
/// about media that AVFoundation has actually read. A zero-byte `.mov` is
/// enough to resolve a project and not nearly enough to build one.
@Suite struct MixTests {

	// MARK: - Media, made here

	/// A few seconds of black, with no audio track at all. The silent b-roll
	/// case, which used to refuse to export.
	private func silentVideo(at url: URL, seconds: Double) async throws {
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
				adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 25))
			}
		}
		input.markAsFinished()
		writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frames), timescale: 25))
		await writer.finishWriting()
	}

	/// A tone, as a WAV. Written by hand because a header and some samples is
	/// less machinery than an encoder, and this only has to be something with
	/// audio in it.
	private func tone(at url: URL, seconds: Double) throws {
		let rate = 44100
		let count = Int(Double(rate) * seconds)
		var data = Data()
		func put(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
		func put32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
		func put16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
		put("RIFF"); put32(UInt32(36 + count * 2)); put("WAVE")
		put("fmt "); put32(16); put16(1); put16(1)
		put32(UInt32(rate)); put32(UInt32(rate * 2)); put16(2); put16(16)
		put("data"); put32(UInt32(count * 2))
		for sample in 0..<count {
			let value = Int16(sin(2 * .pi * 440 * Double(sample) / Double(rate)) * 8000)
			put16(UInt16(bitPattern: value))
		}
		try data.write(to: url)
	}

	/// A folder with a silent shot, a tone to lay under it, and whatever takes
	/// the test asks for.
	private func fixture(sound: Bool = false) async throws -> URL {
		let directory = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("cuttr-mix-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		try await silentVideo(at: directory.appendingPathComponent("silent.mov"), seconds: 2)
		try tone(at: directory.appendingPathComponent("tone.wav"), seconds: 2)
		try tone(at: directory.appendingPathComponent("music.wav"), seconds: 8)

		// One take with no sound at all, and one whose recorder track is the
		// tone — which is how a project gets a shot that can be heard.
		try TakeWriter.write(Take(video: "silent.mov", clips: [
			Clip(slug: "quiet", start: 0, end: 2),
		])).write(to: directory.appendingPathComponent("quiet.cuttr"),
		          atomically: true, encoding: .utf8)
		try TakeWriter.write(Take(video: "silent.mov",
		                          audio: AudioTrack(file: "tone.wav", offset: 0),
		                          clips: [Clip(slug: "loud", start: 0, end: 2)]))
			.write(to: directory.appendingPathComponent("loud.cuttr"),
			       atomically: true, encoding: .utf8)
		_ = sound
		return directory
	}

	private func build(_ text: String, in directory: URL) async throws -> Renderer.Built {
		let project = try ProjectReader.read("takes: [quiet.cuttr, loud.cuttr]\n" + text)
		let resolved = try Resolver.resolve(project, baseURL: directory)
		return try await Renderer.build(resolved, host: .export)
	}

	// MARK: - Lanes

	@Test func aSilentShotLeavesNoEmptyAudioTrackBehind() async throws {
		let directory = try await fixture()
		defer { try? FileManager.default.removeItem(at: directory) }
		let built = try await build("timeline: [quiet]\n", in: directory)
		// The export refuses a composition carrying a track with nothing on it,
		// and says only "Operation Stopped" while it does. A take whose video
		// has no audio is exactly how that happens.
		#expect(built.composition.tracks(withMediaType: .audio).isEmpty)
		#expect(built.composition.tracks(withMediaType: .video).count == 1)
	}

	@Test func aSilentShotBesideOneWithSoundKeepsTheSoundWhereItIs() async throws {
		let directory = try await fixture()
		defer { try? FileManager.default.removeItem(at: directory) }
		let built = try await build("timeline: [quiet, loud, quiet]\n", in: directory)
		let audio = built.composition.tracks(withMediaType: .audio)
		#expect(audio.count == 1)
		// A hole where the silent shot is, and the tone at two seconds — not
		// slid up to the top, which is what dropping the hole would do.
		let filled = audio[0].segments.filter { !$0.isEmpty }.map { $0.timeMapping.target }
		#expect(filled.count == 1)
		#expect(filled.first?.start.seconds == 2)
		#expect(filled.first?.duration.seconds == 2)
		// And a mix, because the hole has to be *heard* as silence rather than
		// left to whatever a player makes of an empty edit.
		#expect(built.audioMix != nil)
	}

	@Test func aProgrammeWithNothingMissingIsLeftAlone() async throws {
		let directory = try await fixture()
		defer { try? FileManager.default.removeItem(at: directory) }
		let built = try await build("timeline: [loud, loud]\n", in: directory)
		#expect(built.composition.tracks(withMediaType: .audio).count == 1)
		// Nothing to say: every level is one, there are no holes and no sounds.
		#expect(built.audioMix == nil)
	}

	@Test func aCardLeavesAHoleInTheSound() async throws {
		let directory = try await fixture()
		defer { try? FileManager.default.removeItem(at: directory) }
		let built = try await build("""
		timeline:
		  - loud
		  - card: 00:02.000
		  - loud
		""", in: directory)
		let audio = built.composition.tracks(withMediaType: .audio)
		#expect(audio.count == 1)
		#expect(audio[0].segments.contains { $0.isEmpty })
		#expect(built.audioMix != nil)
		// And a lane for the card's carrier, which is what keeps a programme
		// that ends on one the length it says it is.
		#expect(built.composition.tracks(withMediaType: .video).count == 2)
	}

	@Test func aSoundGetsALaneOfItsOwn() async throws {
		let directory = try await fixture()
		defer { try? FileManager.default.removeItem(at: directory) }
		let built = try await build("""
		timeline: [loud]
		sounds:
		  - file: music.wav
		    from: loud
		    gain: -6
		""", in: directory)
		// The shot's own sound, and the music beside it.
		#expect(built.composition.tracks(withMediaType: .audio).count == 2)
		#expect(built.audioMix?.inputParameters.count == 2)
	}

	@Test func soundsThatDoNotOverlapShareOneLane() async throws {
		let directory = try await fixture()
		defer { try? FileManager.default.removeItem(at: directory) }
		let built = try await build("""
		timeline: [loud, loud]
		sounds:
		  - file: music.wav
		    from: 00:00.000
		    to:   00:02.000
		  - file: music.wav
		    from: 00:02.000
		    to:   00:04.000
		""", in: directory)
		// One lane holds any number of sounds that are not on at once.
		#expect(built.composition.tracks(withMediaType: .audio).count == 2)
	}

	@Test func soundsThatOverlapGetALaneEach() async throws {
		let directory = try await fixture()
		defer { try? FileManager.default.removeItem(at: directory) }
		let built = try await build("""
		timeline: [loud, loud]
		sounds:
		  - file: music.wav
		    from: 00:00.000
		    to:   00:03.000
		  - file: music.wav
		    from: 00:02.000
		    to:   00:04.000
		""", in: directory)
		// A track can only play one thing at a time.
		#expect(built.composition.tracks(withMediaType: .audio).count == 3)
	}

	@Test func aSoundOverASilentProgrammeIsStillHeard() async throws {
		let directory = try await fixture()
		defer { try? FileManager.default.removeItem(at: directory) }
		let built = try await build("""
		timeline: [quiet]
		sounds:
		  - file: music.wav
		    from: quiet
		""", in: directory)
		// No lane for the shot, because there is nothing on it; one for the
		// music, because there is.
		#expect(built.composition.tracks(withMediaType: .audio).count == 1)
		#expect(built.audioMix?.inputParameters.count == 1)
	}
}
