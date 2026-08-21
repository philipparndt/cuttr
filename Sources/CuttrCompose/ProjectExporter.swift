import CuttrKit
import Foundation

/// Copies a project and everything it depends on into one folder.
///
/// A project is a set of relative paths, and the paths reach outward: takes in
/// one place, recordings on a card somewhere else, tracking sidecars beside the
/// takes. That is right while you are working — nothing is duplicated and a
/// re-cut take is instantly current everywhere — and wrong the moment the work
/// has to go to another machine, an archive, or somebody else.
///
/// So: one folder, everything inside it, every path rewritten to point within
/// it. What comes out can be zipped, copied to a disk, and opened on a machine
/// that has never seen the originals.
///
///     programme.cuttrproj
///     takes/
///       take-01.cuttr
///       anchors/take-01/mia.path
///     media/
///       IMG_1800.mov
///       mia.wav
///
/// It copies whole recordings, not the parts in use. Trimming to the cut would
/// make a smaller folder and a worse one: the clips are named ranges of a
/// recording, and a recording that has been cut down is no longer the thing
/// those ranges are ranges of. Re-cutting an exported project would be
/// impossible.
public enum ProjectExporter {

	public struct Report: Sendable {
		public var takes: [String] = []
		public var media: [String] = []
		public var sidecars: [String] = []
		/// Files the project named that are not there. Reported rather than
		/// thrown: one missing recording should not stop the other nine being
		/// exported, and the take still points at where it *should* be, so
		/// fixing it later is dropping the file in.
		public var missing: [String] = []
		/// Names that had to change because something else already had them.
		public var renamed: [(from: String, to: String)] = []
		/// Components whose source and whose baked frames both came along.
		public var components: [String] = []

		public var summary: String {
			var parts = ["\(takes.count) takes", "\(media.count) media"]
			if !sidecars.isEmpty { parts.append("\(sidecars.count) tracking") }
			if !components.isEmpty { parts.append("\(components.count) components") }
			if !renamed.isEmpty { parts.append("\(renamed.count) renamed") }
			if !missing.isEmpty { parts.append("\(missing.count) missing") }
			return parts.joined(separator: ", ")
		}
	}

	public enum ExportError: LocalizedError {
		case notEmpty(URL)
		case cannotCreate(URL, String)

		public var errorDescription: String? {
			switch self {
			case .notEmpty(let url):
				return "\(url.lastPathComponent) already has something in it. "
					+ "Export into a new, empty folder."
			case .cannotCreate(let url, let why):
				return "Could not create \(url.lastPathComponent): \(why)"
			}
		}
	}

	/// Exports `project` — read from `baseURL` — into `target`.
	///
	/// Blocking: it is file copies, and on a big shoot it is a lot of them.
	/// Call it off the main thread.
	public static func export(
		_ project: Project, named name: String, from baseURL: URL, to target: URL
	) throws -> Report {
		let manager = FileManager.default
		if let existing = try? manager.contentsOfDirectory(atPath: target.path), !existing.isEmpty {
			// Refusing rather than merging. Writing into a folder that already
			// has files in it is how somebody loses the other project that was
			// already there.
			throw ExportError.notEmpty(target)
		}
		let takesFolder = target.appendingPathComponent("takes", isDirectory: true)
		let mediaFolder = target.appendingPathComponent("media", isDirectory: true)
		for folder in [target, takesFolder, mediaFolder] {
			do { try manager.createDirectory(at: folder, withIntermediateDirectories: true) }
			catch { throw ExportError.cannotCreate(folder, error.localizedDescription) }
		}

		var report = Report()
		var usedTakeNames = Set<String>()
		var usedMediaNames = Set<String>()
		/// The same recording referenced by two takes is copied once, and both
		/// takes point at the one copy.
		var mediaBySource: [String: String] = [:]
		var exportedTakePaths: [String] = []

		for path in project.takes {
			let source = URL(fileURLWithPath: path, relativeTo: baseURL).standardizedFileURL
			guard let text = try? String(contentsOf: source, encoding: .utf8),
			      var take = try? TakeReader.read(text)
			else {
				report.missing.append(path)
				continue
			}
			let sourceFolder = source.deletingLastPathComponent()

			let takeName = unique(source.deletingPathExtension().lastPathComponent, in: &usedTakeNames)
			if takeName != source.deletingPathExtension().lastPathComponent {
				report.renamed.append((source.lastPathComponent, takeName + ".cuttr"))
			}

			/// Copies one recording into `media/` and answers with the path the
			/// take should use — which is relative to the take, one level down.
			func bring(_ relative: String) -> String? {
				let from = URL(fileURLWithPath: relative, relativeTo: sourceFolder).standardizedFileURL
				if let already = mediaBySource[from.path] { return already }
				guard manager.fileExists(atPath: from.path) else {
					report.missing.append(from.path)
					return nil
				}
				let base = from.deletingPathExtension().lastPathComponent
				let name = unique(base, in: &usedMediaNames)
				if name != base { report.renamed.append((from.lastPathComponent, name + "." + from.pathExtension)) }
				let to = mediaFolder.appendingPathComponent(name).appendingPathExtension(from.pathExtension)
				do { try manager.copyItem(at: from, to: to) } catch {
					report.missing.append(from.path)
					return nil
				}
				let inTake = "../media/" + to.lastPathComponent
				mediaBySource[from.path] = inTake
				report.media.append(to.lastPathComponent)
				return inTake
			}

			if let video = take.video { take.video = bring(video) ?? video }
			if let audio = take.audio?.file { take.audio?.file = bring(audio) ?? audio }

			// Sidecars go under the take's own name, because two takes may both
			// have an anchor called `mia` and both would otherwise want
			// `anchors/mia.path`.
			for index in take.anchors.indices {
				guard let sidecar = take.anchors[index].path else { continue }
				let from = URL(fileURLWithPath: sidecar, relativeTo: sourceFolder).standardizedFileURL
				let inTake = "anchors/\(takeName)/\(from.lastPathComponent)"
				let to = takesFolder.appendingPathComponent(inTake)
				guard manager.fileExists(atPath: from.path) else {
					// The anchor keeps its new path: re-solving writes it there.
					take.anchors[index].path = inTake
					report.missing.append(from.path)
					continue
				}
				try? manager.createDirectory(
					at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
				try? manager.copyItem(at: from, to: to)
				take.anchors[index].path = inTake
				report.sidecars.append(inTake)
			}

			let takeURL = takesFolder.appendingPathComponent(takeName).appendingPathExtension("cuttr")
			try TakeWriter.write(take).write(to: takeURL, atomically: true, encoding: .utf8)
			report.takes.append(takeName + ".cuttr")
			exportedTakePaths.append("takes/" + takeURL.lastPathComponent)
		}

		// A component and its bake, both, and neither renamed.
		//
		// The frames are material rather than a scene — `docs/remotion.md` makes
		// that argument and it is the reason they are cached beside the project
		// in the first place. The picture a component produces depends on the
		// WebKit that drew it, so a folder exported without its bake would render
		// *differently* on the machine it was opened on, which is precisely the
		// failure exporting exists to prevent. They go across unchanged, at the
		// paths the project already names, because those paths are what
		// `component:` and `.cuttr/components/` mean and rewriting them would be
		// rewriting the cache key.
		for component in ComponentBaker.components(in: project) {
			let source = URL(fileURLWithPath: component.file, relativeTo: baseURL)
			let to = target.appendingPathComponent(component.file)
			guard manager.fileExists(atPath: source.path) else {
				report.missing.append(source.path)
				continue
			}
			try? manager.createDirectory(at: to.deletingLastPathComponent(),
			                             withIntermediateDirectories: true)
			try? manager.copyItem(at: source, to: to)
			// The bake may not be there, and that is not an error: the project
			// still says what to draw and rendering it will draw it. Only a
			// *stale* bake is a problem, and this is not the place that says so.
			let bake = URL(fileURLWithPath: component.folder, relativeTo: baseURL)
			if manager.fileExists(atPath: bake.path) {
				let landing = target.appendingPathComponent(component.folder)
				try? manager.createDirectory(at: landing.deletingLastPathComponent(),
				                             withIntermediateDirectories: true)
				try? manager.copyItem(at: bake, to: landing)
			}
			report.components.append(component.file)
		}

		var exported = project
		exported.takes = exportedTakePaths
		// The render lands inside the folder too, so an exported project is
		// self-contained in both directions.
		if let file = project.output.file {
			exported.output.file = URL(fileURLWithPath: file).lastPathComponent
		}
		try ProjectWriter.write(exported).write(
			to: target.appendingPathComponent(name).appendingPathExtension("cuttrproj"),
			atomically: true, encoding: .utf8)
		return report
	}

	/// A name nothing else in this folder has: `mia`, `mia-2`, `mia-3`.
	private static func unique(_ name: String, in taken: inout Set<String>) -> String {
		let base = name.isEmpty ? "untitled" : name
		if taken.insert(base).inserted { return base }
		var n = 2
		while !taken.insert("\(base)-\(n)").inserted { n += 1 }
		return "\(base)-\(n)"
	}
}
