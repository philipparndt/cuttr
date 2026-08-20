import CuttrCompose
import CuttrKit
import Foundation

// The renderer without a window.
//
// Rendering is minutes of encoding and the machine doing it does not need a
// screen — this is what a build machine, a `make` rule or an overnight run
// reaches for. It reads exactly the same project file the composing window
// writes, and produces exactly the same frames, because both go through
// `Renderer.build`.

let arguments = Array(CommandLine.arguments.dropFirst())

func usage() -> Never {
	FileHandle.standardError.write("""
	usage: cuttr-render <project.cuttrproj> [-o output.mov] [--solve] [--quiet]
	       cuttr-render --faces <video.mov> [--at seconds]

	  -o        where to write; defaults to the project's own `output.file`
	  --solve   re-solve every anchor's path before rendering, rather than
	            using the sidecars the composing window wrote
	  --describe
	            print what the project resolves to — every clip and card with its
	            times, every sound with its level, every overlay with when it is
	            on, what it says then and whether its anchor was found — and
	            render nothing. The first question
	            when something is missing from a render is whether it was ever
	            in the programme.
	  --quiet   no progress

	  --analyse measure every take's loudness and colour, and write the numbers
	            back into the take files. Do this once per recording; every
	            project that uses it then levels and matches for free.

	  --speaking <take.cuttr> --from s --to s
	            who, of the take's tracked people, is talking over that span.
	            An anchor is a person: rename one to `mia` and clips she speaks
	            in are named after her.

	  --faces   what Vision can see in one frame, and where. Answers "is there
	            a face here for an anchor to lock on to?" before spending a
	            minute finding out, and prints the coordinates an anchor's
	            `point:` wants.

	""".data(using: .utf8)!)
	exit(2)
}

var projectPath: String?
var outputPath: String?
var solve = false
var describe = false
var quiet = false
var facesOf: String?
var facesAt = 0.0
var analyse = false
var speakingIn: String?
var spanFrom = 0.0
var spanTo = 0.0
var index = 0
while index < arguments.count {
	switch arguments[index] {
	case "-o", "--output":
		index += 1
		guard index < arguments.count else { usage() }
		outputPath = arguments[index]
	case "--describe":
		describe = true
	case "--faces":
		index += 1
		guard index < arguments.count else { usage() }
		facesOf = arguments[index]
	case "--speaking":
		index += 1
		guard index < arguments.count else { usage() }
		speakingIn = arguments[index]
	case "--from":
		index += 1
		guard index < arguments.count, let value = Double(arguments[index]) else { usage() }
		spanFrom = value
	case "--to":
		index += 1
		guard index < arguments.count, let value = Double(arguments[index]) else { usage() }
		spanTo = value
	case "--at":
		index += 1
		guard index < arguments.count, let value = Double(arguments[index]) else { usage() }
		facesAt = value
	case "--analyse", "--analyze": analyse = true
	case "--solve": solve = true
	case "--quiet": quiet = true
	case "-h", "--help": usage()
	default:
		guard projectPath == nil else { usage() }
		projectPath = arguments[index]
	}
	index += 1
}
func fail(_ message: String) -> Never {
	FileHandle.standardError.write("cuttr-render: \(message)\n".data(using: .utf8)!)
	exit(1)
}

if let speakingIn {
	let takeURL = URL(fileURLWithPath: speakingIn).standardizedFileURL
	let directory = takeURL.deletingLastPathComponent()
	do {
		let take = try TakeReader.read(try String(contentsOf: takeURL, encoding: .utf8))
		guard let videoPath = take.video else { fail("that take has no video") }
		let video = URL(fileURLWithPath: videoPath, relativeTo: directory).standardizedFileURL
		let candidates = take.anchors.compactMap { anchor -> SpeakerDetector.Candidate? in
			guard let sidecar = anchor.path,
			      let text = try? String(
				      contentsOf: URL(fileURLWithPath: sidecar, relativeTo: directory), encoding: .utf8)
			else { return nil }
			return SpeakerDetector.Candidate(name: anchor.name, path: AnchorPath.read(text))
		}
		guard !candidates.isEmpty else { fail("that take has no solved anchors to tell apart") }
		let finding = try await SpeakerDetector.speaking(
			videoURL: video, among: candidates, from: spanFrom, to: spanTo)
		if let finding {
			print(String(format: "%@ — mouth moved %.4f per sample, %@ ahead of the next",
			             finding.name, finding.movement,
			             finding.margin.isFinite ? String(format: "%.2f\u{d7}", finding.margin) : "alone"))
		} else {
			print("nobody clearly talking between \(spanFrom)s and \(spanTo)s")
		}
	} catch {
		fail(error.localizedDescription)
	}
	exit(0)
}

if let facesOf {
	let url = URL(fileURLWithPath: facesOf).standardizedFileURL
	do {
		let faces = try await AnchorSolver.faces(videoURL: url, at: facesAt)
		if faces.isEmpty {
			print("no faces at \(facesAt)s")
		}
		for (index, face) in faces.enumerated() {
			func show(_ name: String, _ point: CGPoint?) -> String {
				guard let point else { return "\(name): —" }
				return String(format: "%@: [%.4f, %.4f]", name, point.x, point.y)
			}
			print(String(format: "face %d  box [%.3f %.3f %.3f %.3f]  %@  %@  %@",
			             index, face.boundingBox.minX, face.boundingBox.minY,
			             face.boundingBox.width, face.boundingBox.height,
			             show("left-eye", face.leftEye), show("right-eye", face.rightEye),
			             show("nose", face.nose)))
		}
	} catch {
		fail(error.localizedDescription)
	}
	exit(0)
}

guard let projectPath else { usage() }

let projectURL = URL(fileURLWithPath: projectPath).standardizedFileURL
let baseURL = projectURL.deletingLastPathComponent()

let project: Project
do {
	project = try ProjectReader.read(try String(contentsOf: projectURL, encoding: .utf8))
} catch {
	fail(error.localizedDescription)
}

// Measuring before resolving, because resolving compares what the takes measured
// against what the project is aiming at.
//
// Per recording, not per clip: how loud a take is and what colour it is are
// facts about the recording, so one pass serves every programme that uses it —
// which is why the numbers are written back into the take rather than kept here.
if analyse {
	do {
		for path in project.takes {
			let takeURL = URL(fileURLWithPath: path, relativeTo: baseURL).standardizedFileURL
			var take = try TakeReader.read(try String(contentsOf: takeURL, encoding: .utf8))
			let directory = takeURL.deletingLastPathComponent()
			if !quiet { print("==> measuring \(takeURL.lastPathComponent)") }

			// The audio somebody will actually hear: the separate recorder when
			// there is one, because that is the reason it was recorded.
			let audioURL = take.audio.map { URL(fileURLWithPath: $0.file, relativeTo: directory) }
				?? take.video.map { URL(fileURLWithPath: $0, relativeTo: directory) }
			if let audioURL {
				// Only the spans this take contributes. Clip times are on the
				// video's clock; a separate recorder has a clock of its own, and
				// the take's offset is what relates them — the same number the
				// renderer uses to line the two up.
				let offset = take.audio.map { _ in take.audio!.offset } ?? 0
				let ranges = take.clips.map { clip in
					(clip.start - offset) ... (clip.end - offset)
				}
				let loudness = try await LoudnessMeter.measure(
					url: audioURL.standardizedFileURL, ranges: ranges)
				take.measured.loudness = loudness.integrated
				take.measured.peak = loudness.peak
				if !quiet {
					let level = loudness.integrated.map { String(format: "%.1f LUFS", $0) } ?? "silent"
					print(String(format: "    %@, peak %.1f dBFS", level, loudness.peak))
				}
			}

			if let videoPath = take.video {
				let video = URL(fileURLWithPath: videoPath, relativeTo: directory).standardizedFileURL
				// The same argument as the loudness: sampled across what the
				// take actually contributes, not across footage nobody will see.
				let duration = (try? await MediaProbe.probe(video).duration) ?? 0
				let from = take.clips.map(\.start).min() ?? 0
				let to = take.clips.map(\.end).max() ?? duration
				let cast = try await ColourAnalysis.measure(videoURL: video, from: from, to: to)
				take.measured.cast = cast
				if !quiet {
					print("    cast [" + cast.map { String(format: "%.4f", $0) }.joined(separator: ", ") + "]")
				}
			}

			try TakeWriter.write(take).write(to: takeURL, atomically: true, encoding: .utf8)
		}
	} catch {
		fail("measuring: \(error.localizedDescription)")
	}
}

// Solving before resolving, because resolving reads the sidecars.
//
// Anchors belong to the takes, so a re-solve rewrites sidecars beside the take
// files rather than beside the project — which is what makes a take carry its
// tracking into every programme that uses it.
if solve {
	do {
		for path in project.takes {
			let takeURL = URL(fileURLWithPath: path, relativeTo: baseURL).standardizedFileURL
			let take = try TakeReader.read(try String(contentsOf: takeURL, encoding: .utf8))
			let takeDirectory = takeURL.deletingLastPathComponent()
			guard let videoPath = take.video else { continue }
			let video = URL(fileURLWithPath: videoPath, relativeTo: takeDirectory).standardizedFileURL
			var updated = take
			var changed = false
			for (index, anchor) in take.anchors.enumerated() {
				guard let sidecar = anchor.path else { continue }
				if !quiet { print("==> following \(anchor.name) in \(takeURL.lastPathComponent)") }
				// Follows the shot outward from the mark, the same as the
				// cutting window does, rather than trusting a range that may
				// have been written before the tracker had an opinion.
				let solved = try await AnchorSolver.solveShot(
					videoURL: video, method: anchor.method,
					markedAt: anchor.markedAt, point: anchor.point,
					// The whole recording, not the cut region: a shot reaches as
					// far as it reaches, and bounding it by where the clips
					// happen to be today is the coupling this change removed.
					within: 0 ... max((try? await MediaProbe.probe(video).duration) ?? 0, anchor.markedAt))
				let url = URL(fileURLWithPath: sidecar, relativeTo: takeDirectory)
				try FileManager.default.createDirectory(
					at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
				if let range = solved.timeRange {
					updated.anchors[index].from = range.lowerBound
					updated.anchors[index].to = range.upperBound
					changed = true
					if !quiet {
						print("    \(Timecode.string(range.lowerBound)) to "
							+ "\(Timecode.string(range.upperBound)), \(solved.samples.count) samples")
					}
				}
				try solved.write(
					name: anchor.name,
					over: "\(Timecode.string(updated.anchors[index].from))–"
						+ "\(Timecode.string(updated.anchors[index].to))",
					framesPerSecond: project.output.framesPerSecond)
					.write(to: url, atomically: true, encoding: .utf8)
			}
			// The range the tracker found goes back into the take, so the next
			// run and the cutting window both know how far the shot reaches.
			if changed {
				try TakeWriter.write(updated).write(to: takeURL, atomically: true, encoding: .utf8)
			}
		}
	} catch {
		fail("solving: \(error.localizedDescription)")
	}
}

let resolved: ResolvedProject
do {
	resolved = try Resolver.resolve(project, baseURL: baseURL)
} catch {
	fail(error.localizedDescription)
}

if describe {
	// What was skipped, before what was kept: a warning after two hundred lines
	// of programme is a warning nobody reads.
	for warning in resolved.warnings {
		FileHandle.standardError.write("warning: \(warning)\n".data(using: .utf8)!)
	}
	print("clips")
	for clip in resolved.clips {
		print(String(format: "  %-28@ %7.3f → %7.3f  %@",
		             clip.reference.description as NSString, clip.start, clip.end,
		             clip.takeName as NSString))
	}
	if !resolved.cards.isEmpty {
		print("cards")
		for card in resolved.cards {
			let fill: String
			switch card.card.fill {
			case .solid(let colour): fill = colour.hex
			case .gradient(let top, let bottom): fill = "\(top.hex) → \(bottom.hex)"
			}
			print(String(format: "  %-28@ %7.3f → %7.3f", fill as NSString, card.start, card.end))
		}
	}
	if !resolved.sounds.isEmpty {
		print("sounds")
		for sound in resolved.sounds {
			var says = String(format: "%.1f dB", sound.sound.gain)
			if sound.sound.fadeIn > 0 { says += String(format: ", in %.2fs", sound.sound.fadeIn) }
			if sound.sound.fadeOut > 0 { says += String(format: ", out %.2fs", sound.sound.fadeOut) }
			if sound.sound.ducks != 0 { says += String(format: ", ducks %.1f dB", sound.sound.ducks) }
			print(String(format: "  %7.3f → %7.3f  %@  (%@)", sound.start, sound.end,
			             sound.sound.file as NSString, says as NSString))
		}
	}
	print("anchors")
	for entry in resolved.anchors {
		let samples = entry.path?.samples.count ?? 0
		print("  \(entry.anchor.name): \(samples) samples"
			+ (entry.path == nil ? "  — NO PATH: nothing will follow it" : ""))
	}
	print("overlays")
	for shown in resolved.overlays {
		let what: String
		switch shown.overlay.kind {
		case .scene(let name, let parameters):
			what = "scene \(name)" + (parameters.isEmpty ? "" : " \(parameters)")
		case .effect(let effect):
			what = "effect \(effect.style.rawValue) ×\(effect.count) seed \(effect.seed)"
		case .film(let film):
			what = "film \(film.tint.rawValue) \(film.ratio.written)"
				+ " grain \(film.grain) vignette \(film.vignette)"
		case .aberration(let aberration):
			what = "aberration \(aberration.kind.rawValue) amount \(aberration.amount)"
				+ (aberration.kind == .linear ? " angle \(aberration.angle)" : "")
		case .tape(let tape):
			what = "tape \(tape.condition.rawValue) jitter \(tape.jitter) band \(tape.band)"
				+ " chroma \(tape.chroma) scanlines \(tape.scanlines)"
				+ " dropouts \(tape.dropouts) seed \(tape.seed)"
		case .text(let text, let style):
			what = "text \(text.debugDescription) style \(style ?? "lower-third")"
		case .spinner(let spinner):
			what = "spinner \(spinner.style.rawValue) size \(spinner.size)"
				+ (spinner.words.isEmpty ? " (no words)"
					: " words \(spinner.words.map(\.text).joined(separator: " · "))")
		}
		print(String(format: "  %7.3f → %7.3f  %@", shown.start, shown.end, what as NSString))
		// Where it is written, when that is not the top-level list. Two
		// captions with the same words over two uses of one clip are told apart
		// by nothing else, and "why is this one on here" is exactly the
		// question `--describe` is asked.
		if case .entry(let path, let index) = shown.origin {
			let entry = project.entry(at: path)
			print("           written in `\(entry?.source.description ?? "?")`"
				+ " at timeline \(path.map(String.init).joined(separator: "."))"
				+ ", overlay \(index + 1) of \(entry?.overlays.count ?? 0)"
				+ (entry?.overlays[index].appearances.isEmpty == true
					? " — covering that placement" : ""))
		}
		print("           anchor \(shown.overlay.anchor ?? "none")"
			+ (shown.overlay.anchor != nil && shown.path == nil
				? "  — NOT FOUND: it will sit where its style says" : "")
			+ "  in \(shown.overlay.arrival)  out \(shown.overlay.departure)")
	}
	exit(0)
}

// `-o`, then the project's own `output.file`, then the project's name. A
// project that says where it goes should render with no arguments at all.
let outputURL: URL = {
	if let outputPath { return URL(fileURLWithPath: outputPath).standardizedFileURL }
	if let file = project.output.file {
		return URL(fileURLWithPath: file, relativeTo: baseURL).standardizedFileURL
	}
	return projectURL.deletingPathExtension().appendingPathExtension("mov")
}()

if !quiet {
	print("==> \(resolved.clips.count) clips, \(String(format: "%.1f", resolved.duration))s, "
		+ "\(resolved.overlays.count) overlays → \(outputURL.lastPathComponent)")
}

// A progress line that rewrites itself, and only when somebody is watching:
// piped into a log, `\r` would produce one enormous line.
let interactive = isatty(STDERR_FILENO) == 1 && !quiet
do {
	try await Renderer.export(resolved, to: outputURL) { fraction in
		guard interactive else { return }
		let width = 40
		let filled = Int(fraction * Double(width))
		let bar = String(repeating: "█", count: filled) + String(repeating: "·", count: width - filled)
		FileHandle.standardError.write(
			"\r    \(bar) \(Int(fraction * 100))%".data(using: .utf8)!)
	}
} catch {
	if interactive { FileHandle.standardError.write("\n".data(using: .utf8)!) }
	fail(error.localizedDescription)
}
if interactive { FileHandle.standardError.write("\n".data(using: .utf8)!) }
if !quiet { print("==> wrote \(outputURL.path)") }
