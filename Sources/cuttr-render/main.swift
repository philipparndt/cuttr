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
	  --quiet   no progress

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
var quiet = false
var facesOf: String?
var facesAt = 0.0
var index = 0
while index < arguments.count {
	switch arguments[index] {
	case "-o", "--output":
		index += 1
		guard index < arguments.count else { usage() }
		outputPath = arguments[index]
	case "--faces":
		index += 1
		guard index < arguments.count else { usage() }
		facesOf = arguments[index]
	case "--at":
		index += 1
		guard index < arguments.count, let value = Double(arguments[index]) else { usage() }
		facesAt = value
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
