import AVFoundation
import Foundation
import Testing
@testable import CuttrKit

/// A stretch of a file written out as a file of its own — checked by reading
/// the copy back and looking at the samples, because "it wrote something" is
/// not the claim. The claim is that it is *that part*, and that the original
/// is as it was.
@Suite struct AudioTrimTests {

	private static let rate = 8000

	/// Two seconds in which every sample says where it is: sample `n` is `n`
	/// (mod a number that fits), so a copy that begins anywhere can be told
	/// from one that begins anywhere else.
	private func ramp() throws -> (folder: URL, file: URL) {
		let folder = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("cuttr-trim-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		let count = Self.rate * 2
		var data = Data()
		func put(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
		func put32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
		func put16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
		put("RIFF"); put32(UInt32(36 + count * 2)); put("WAVE")
		put("fmt "); put32(16); put16(1); put16(1)
		put32(UInt32(Self.rate)); put32(UInt32(Self.rate * 2)); put16(2); put16(16)
		put("data"); put32(UInt32(count * 2))
		for sample in 0..<count { put16(UInt16(bitPattern: Int16(sample % 20000))) }
		let file = folder.appendingPathComponent("song.wav")
		try data.write(to: file)
		return (folder, file)
	}

	private func samples(_ url: URL) throws -> [Int16] {
		let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: false)
		let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
		                                            frameCapacity: AVAudioFrameCount(file.length)))
		try file.read(into: buffer)
		let channel = try #require(buffer.int16ChannelData?[0])
		return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
	}

	@Test func theCopyIsThatStretchAndTheOriginalIsAsItWas() throws {
		let (folder, file) = try ramp()
		defer { try? FileManager.default.removeItem(at: folder) }
		let before = try Data(contentsOf: file)
		let copy = folder.appendingPathComponent("chorus.wav")

		let seconds = try AudioTrim.write(file, from: 0.5, to: 1.5, at: copy)
		#expect(seconds == 1)
		let heard = try samples(copy)
		#expect(heard.count == Self.rate)
		// It begins where it was asked to and runs on from there.
		#expect(heard.first == Int16(Self.rate / 2))
		#expect(heard.last == Int16(Self.rate / 2 + Self.rate - 1))
		#expect(try Data(contentsOf: file) == before)
	}

	@Test func withNoEndItRunsToTheEndOfTheFile() throws {
		let (folder, file) = try ramp()
		defer { try? FileManager.default.removeItem(at: folder) }
		let copy = folder.appendingPathComponent("tail.wav")
		#expect(try AudioTrim.write(file, from: 1.75, at: copy) == 0.25)
		// And an end past the end is the end.
		let long = folder.appendingPathComponent("long.wav")
		#expect(try AudioTrim.write(file, from: 1, to: 60, at: long) == 1)
	}

	@Test func nothingIsOverwrittenAndNothingIsWrittenForNothing() throws {
		let (folder, file) = try ramp()
		defer { try? FileManager.default.removeItem(at: folder) }
		let copy = folder.appendingPathComponent("chorus.wav")
		try AudioTrim.write(file, from: 0, to: 1, at: copy)
		let first = try Data(contentsOf: copy)

		#expect(throws: AudioTrim.Failure.exists(copy.path)) {
			try AudioTrim.write(file, from: 1, to: 2, at: copy)
		}
		#expect(try Data(contentsOf: copy) == first)
		#expect(throws: AudioTrim.Failure.sameFile) { try AudioTrim.write(file, from: 0, at: file) }

		// The file is two seconds long; a stretch that begins after that is
		// refused, and leaves no empty file with a plausible name behind.
		let past = folder.appendingPathComponent("past.wav")
		#expect(throws: AudioTrim.Failure.nothingThere(length: 2)) {
			try AudioTrim.write(file, from: 5, at: past)
		}
		#expect(!FileManager.default.fileExists(atPath: past.path))
	}

	/// A compressed copy when that is what was asked for: shorter, and audio.
	@Test func aCopyCanBeWrittenCompressed() throws {
		let (folder, file) = try ramp()
		defer { try? FileManager.default.removeItem(at: folder) }
		let copy = folder.appendingPathComponent("chorus.m4a")
		try AudioTrim.write(file, from: 0.5, to: 1.5, at: copy)
		let read = try AVAudioFile(forReading: copy)
		#expect(abs(Double(read.length) / read.processingFormat.sampleRate - 1) < 0.2)

		#expect(AudioTrim.kind(for: URL(fileURLWithPath: "/x/song.mp3")) == "m4a")
		#expect(AudioTrim.kind(for: URL(fileURLWithPath: "/x/song.WAV")) == "wav")
	}
}
