import CuttrKit
import Foundation
import Testing
@testable import CuttrCompose

/// A clip's own level, on the programme.
///
/// Two questions that look like one. The take's measured loudness brings the
/// *recording* to a target; a clip's trim is a correction between clips of the
/// same recording, which no take-wide measurement can make.
@Suite struct ClipGainTests {

	private func fixture(_ gains: [Double], loudness: Double? = nil) throws -> URL {
		let directory = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("cuttr-gain-\(UUID().uuidString)")
		try FileManager.default.createDirectory(
			at: directory.appendingPathComponent("takes"), withIntermediateDirectories: true)
		try Data().write(to: directory.appendingPathComponent("a.mov"))
		var take = Take(video: "../a.mov", clips: gains.enumerated().map { index, gain in
			Clip(slug: "c\(index)", start: Double(index), end: Double(index) + 1, gain: gain)
		})
		take.measured.loudness = loudness
		take.measured.peak = -3
		try TakeWriter.write(take).write(
			to: directory.appendingPathComponent("takes/t.cuttr"),
			atomically: true, encoding: .utf8)
		return directory
	}

	private func gains(_ text: String, in directory: URL) throws -> [Double] {
		let project = try ProjectReader.read("takes: [takes/t.cuttr]\n" + text)
		return try Resolver.resolve(project, baseURL: directory).clips.map(\.gain)
	}

	/// With no target to match, a clip's trim is the whole of its level.
	@Test func aTrimIsHonouredWithNoTargetToMatch() throws {
		let directory = try fixture([-3, 0, 6])
		defer { try? FileManager.default.removeItem(at: directory) }
		#expect(try gains("timeline: [c0, c1, c2]\n", in: directory) == [-3, 0, 6])
	}

	/// With one, the two are added: the match brings the recording to the
	/// target and the trim is the difference between clips of it.
	@Test func aTrimIsAddedToTheMatch() throws {
		// -30 LUFS toward a -16 target is +14, and the peak at -3 does not stop
		// it — so each clip is 14 plus its own trim.
		let directory = try fixture([-3, 0, 6], loudness: -30)
        defer { try? FileManager.default.removeItem(at: directory) }
		let out = try gains(
			"output: {audio: {target: -16, ceiling: 1}}\ntimeline: [c0, c1, c2]\n",
			in: directory)
		#expect(out.count == 3)
		guard out.count == 3 else { return }
		#expect(abs(out[0] - (out[1] - 3)) < 1e-9)
		#expect(abs(out[2] - (out[1] + 6)) < 1e-9)
		// And the match itself is still doing its job.
		#expect(out[1] > 0)
	}

	/// A take nobody has levelled resolves to exactly what it did before.
	@Test func aTakeWithNoTrimsIsUnchanged() throws {
		let directory = try fixture([0, 0, 0])
		defer { try? FileManager.default.removeItem(at: directory) }
		#expect(try gains("timeline: [c0, c1, c2]\n", in: directory) == [0, 0, 0])
	}
}
