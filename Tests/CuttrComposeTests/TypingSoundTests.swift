import AVFoundation
import CoreGraphics
import Foundation
import Testing
@testable import CuttrCompose

/// A typed line that clicks.
@Suite struct TypingSoundTests {

	private let words = "dingsda"

	// MARK: - The sound itself

	/// A click is short, loud at the front, and gone.
	@Test func aClickIsATransient() {
		var samples = [Double](repeating: 0, count: Int(0.2 * TypingSound.rate))
		TypingSound.key(into: &samples, at: 0, level: 1)
		let front = samples[0..<Int(0.005 * TypingSound.rate)].map(abs).max() ?? 0
		let middle = samples[Int(0.030 * TypingSound.rate)..<Int(0.045 * TypingSound.rate)]
			.map(abs).max() ?? 0
		let after = samples[Int(0.060 * TypingSound.rate)...].map(abs).max() ?? 0
		#expect(front > 0.3, "there is no click")
		#expect(middle < front * 0.5, "it does not decay")
		#expect(after == 0, "it rings on past its own length")
	}

	/// Every key is the same key. The rhythm carries a typed line; a timbre
	/// that also wanders reads as a fault rather than as a person.
	@Test func everyClickIsTheSameClick() {
		var first = [Double](repeating: 0, count: Int(0.1 * TypingSound.rate))
		var second = first
		TypingSound.key(into: &first, at: 0, level: 1)
		TypingSound.key(into: &second, at: 0, level: 1)
		#expect(first == second)

		// And two in one buffer are the same as each other, so a line does not
		// drift in tone from its first character to its last.
		var line = [Double](repeating: 0, count: Int(1.0 * TypingSound.rate))
		let apart = Int(0.5 * TypingSound.rate)
		TypingSound.key(into: &line, at: 0, level: 1)
		TypingSound.key(into: &line, at: apart, level: 1)
		let opening = Array(line[0..<Int(0.055 * TypingSound.rate)])
		let closing = Array(line[apart..<(apart + Int(0.055 * TypingSound.rate))])
		#expect(opening == closing)
	}

	/// Low rather than bright: most of what it is made of is under a kilohertz,
	/// so forty of them do not rattle over the top of whatever else is playing.
	@Test func theClickIsLow() {
		var samples = [Double](repeating: 0, count: Int(0.1 * TypingSound.rate))
		TypingSound.key(into: &samples, at: 0, level: 1)
		// Crossings of nought are a cheap read on how high something sits: a
		// bright transient crosses far more often than a low knock.
		var crossings = 0
		for (before, after) in zip(samples, samples.dropFirst())
		where (before < 0) != (after < 0) && (abs(before) > 0.005 || abs(after) > 0.005) {
			crossings += 1
		}
		// Over the 55ms the click lasts, a 138 Hz knock is about 16 crossings;
		// something bright and hissy would be in the hundreds.
		#expect(crossings < 120, "\(crossings) crossings — the click is too bright")
	}

	/// Written where it can be read back, at the length asked for, and the same
	/// line writes the same file rather than a new one each render.
	@Test func aLineIsWrittenOnceAndReadBack() throws {
		let folder = FileManager.default.temporaryDirectory
			.appendingPathComponent("cuttr-typing-test-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: folder) }

		let moments = [0.1, 0.28, 0.5, 0.62, 0.9]
		let url = try #require(TypingSound.file(clicking: moments, level: 1, into: folder))
		#expect(FileManager.default.fileExists(atPath: url.path))

		// Asked again, it is the same file and not a second one.
		let again = try #require(TypingSound.file(clicking: moments, level: 1, into: folder))
		#expect(again == url)
		let written = try FileManager.default.contentsOfDirectory(atPath: folder.path)
		#expect(written.count == 1, "a second file was written for the same line")

		// And it is a sound something can actually play, of about the right length.
		let asset = AVURLAsset(url: url)
		let track = try #require(asset.tracks(withMediaType: .audio).first, "not readable as audio")
		_ = track
		let seconds = CMTimeGetSeconds(asset.duration)
		#expect(abs(seconds - (moments.last! + 0.25)) < 0.05, "it is \(seconds) long")
	}

	/// Silence is silence: no file, and nothing to lay on a lane.
	@Test func noClickMeansNoFile() {
		let folder = FileManager.default.temporaryDirectory
			.appendingPathComponent("cuttr-typing-test-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: folder) }
		#expect(TypingSound.file(clicking: [0.1, 0.2], level: 0, into: folder) == nil)
		#expect(TypingSound.file(clicking: [], level: 1, into: folder) == nil)
	}

	// MARK: - In the file

	private func read(_ said: String) throws -> Scene.Typing? {
		let text = """
		cuttr-project: 1

		output:
		  size: 1920x1080
		  fps:  25
		  file: out.mov

		scenes:
		  card:
		    parts:
		      - text:  dingsda
		        \(said)
		        keys:
		          - {t: 0, x: 0.5, y: 0.5, opacity: 1, progress: 0}
		          - {t: 2, progress: 1, ease: linear}
		"""
		let project = try ProjectReader.read(text)
		guard case .text(_, _, _, let typed) = try #require(project.scenes["card"]?.parts.first)
			.content else { return nil }
		return typed
	}

	@Test func theClickIsReadAndWritten() throws {
		#expect(try read("typed: true")?.click == 0)
		#expect(try read("typed: {click: true}")?.click == 1)
		#expect(try read("typed: {click: 0.4}")?.click == 0.4)

		for said in ["typed: {click: true}", "typed: {click: 0.4}"] {
			let once = try #require(try read(said))
			var project = Project()
			project.scenes["card"] = Scene(parts: [
				.init(content: .text("dingsda", style: nil, tracking: 0, typed: once),
				      keys: [.init(t: 0, progress: 0), .init(t: 2, progress: 1)]),
			])
			let written = ProjectWriter.write(project)
			#expect(written.contains(said), "\(said) was not written the way it was said")
			#expect(try ProjectReader.read(written) == project, "\(said) did not survive")
		}
	}

	/// A click that is not a number is refused rather than read as silence.
	@Test func aClickThatIsNotALevelIsRefused() {
		#expect(throws: (any Error).self) { try read("typed: {click: loud}") }
	}

	// MARK: - On the programme

	/// One click track per typed line, starting where the scene does, and only
	/// for the lines that ask for one.
	@Test func aTypedSceneClicksOnTheProgramme() throws {
		var project = Project(
			output: Output(width: 1920, height: 1080, framesPerSecond: 25, file: "out.mov"))
		project.scenes["card"] = Scene(parts: [
			.init(content: .text(words, style: nil, tracking: 0,
			                     typed: Scene.Typing(steady: 1, click: 1)),
			      keys: [.init(t: 0, x: 0.5, y: 0.5, opacity: 1, progress: 0, ease: .linear),
			             .init(t: 1.4, progress: 1, ease: .linear)]),
			.init(content: .text("quiet", style: nil, tracking: 0,
			                     typed: Scene.Typing(steady: 1, click: 0)),
			      keys: [.init(t: 0, x: 0.5, y: 0.7, opacity: 1, progress: 0, ease: .linear),
			             .init(t: 1.4, progress: 1, ease: .linear)]),
		])
		let shown = ResolvedOverlay(
			overlay: Overlay(kind: .scene("card", with: [:]), span: .times(from: 4, to: 9),
			                 arrival: .cut, departure: .cut),
			origin: .project(0), appearance: 0, start: 4, end: 9, path: nil)
		let work = ResolvedProject(project: project, baseURL: URL(fileURLWithPath: "."),
		                           clips: [], overlays: [shown], groups: [], anchors: [])

		let clicks = Renderer.typingClicks(work)
		#expect(clicks.count == 1, "\(clicks.count) click tracks — the silent line clicks too")
		let track = try #require(clicks.first)
		#expect(track.start == 4, "the clicks do not start where the scene does")
		#expect(track.end > 4 && track.end <= 9)

		// Seven characters, so seven clicks: audible bursts in the file, not one
		// long noise.
		let asset = AVURLAsset(url: track.url)
		#expect(CMTimeGetSeconds(asset.duration) > 1, "the track is shorter than the line takes")
	}
}
