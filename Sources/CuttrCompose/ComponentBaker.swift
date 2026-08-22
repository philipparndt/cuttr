import AppKit
import CoreGraphics
import Foundation
import WebKit

/// Draws a `component:` to a folder of PNGs, once, in the browser macOS already
/// has.
///
/// ## Why this can exist at all
///
/// `docs/remotion.md` costed the obvious version of this — bundle Node and
/// Chromium — at half a gigabyte, JIT entitlements and a notarisation surface,
/// and the alternative at "install a JavaScript toolchain, then open the app".
/// Neither was worth it. What makes the third answer work is that the machine
/// already has a browser and it is a framework: a `WKWebView` that is never in a
/// window, driven to frame *n* and photographed, costs about seven milliseconds
/// a frame at 1920×1080 and nothing at all in the bundle beyond React.
///
/// So a ten-second overlay at 25 fps is two hundred and fifty frames and a few
/// seconds of baking, and the result is on disk as PNGs — which is where the
/// argument in `docs/remotion.md` wanted them anyway, because then both render
/// paths only composite and there is no third way of drawing.
///
/// ## What is reproducible, and what is not
///
/// The frames are. The browser is not, and pretending otherwise would be the
/// dishonest part of this: WebKit's text rasterisation and its Skia-equivalent
/// change between macOS releases, so the same component on next year's macOS
/// will not be quite the same pixels. That is why **the baked frames are the
/// artefact**, cached beside the project, travelling with an exported project,
/// and never re-derived unless something the project says has changed. A bake
/// from today keeps rendering exactly what it rendered today, on any machine,
/// for as long as the folder is kept — including after a macOS upgrade, which
/// changes nothing because nothing is re-baked. Deleting the folder is what asks
/// for today's browser's opinion, and it is the only thing that does.
///
/// Which leaves one honest gap, and it is worth stating rather than hiding:
/// after a macOS upgrade, *editing* a component re-bakes it against the new
/// WebKit, so its frames may not sit pixel-for-pixel on top of the ones before
/// the edit. For a chart nobody will see it. For a title that has to match a
/// title baked last year, the answer is the one that has always been true of a
/// title — put it in `scenes:`, where the drawing is this program's own and
/// therefore does not move.
@MainActor
public enum ComponentBaker {

	public struct Report: Sendable {
		/// Baked now, and how long each took.
		public var baked: [(component: String, frames: Int, seconds: Double)] = []
		/// Already there and still current.
		public var reused: [String] = []

		public init() {}

		public var summary: String {
			var parts: [String] = []
			if !baked.isEmpty {
				let frames = baked.reduce(0) { $0 + $1.frames }
				let seconds = baked.reduce(0) { $0 + $1.seconds }
				parts.append(String(format: "%d baked (%d frames, %.1fs)",
				                    baked.count, frames, seconds))
			}
			if !reused.isEmpty { parts.append("\(reused.count) already current") }
			return parts.isEmpty ? "no components" : parts.joined(separator: ", ")
		}
	}

	public enum BakeError: LocalizedError {
		/// The file the project named is not there.
		case noSource(String)
		/// JavaScript threw. The line is the component's own, when one can be
		/// had — see `trouble` in `cuttr-component.js` for when it cannot.
		case script(file: String, line: Int?, message: String)
		/// A family the component asks for is not installed.
		case missingFonts(file: String, [String])
		/// The frame came back empty, which means WebKit refused to draw.
		case noFrame(file: String, index: Int, why: String)
		case cannotWrite(URL, String)
		/// The bundled runtime is not in the bundle.
		case noRuntime(String)

		public var errorDescription: String? {
			switch self {
			case .noSource(let file):
				return "There is no component at \(file)."
			case .script(let file, let line, let message):
				// The file and the line first, because that is what somebody
				// does something with. The same shape a compiler uses.
				let place = line.map { "\(file):\($0)" } ?? file
				return "\(place): \(message)"
			case .missingFonts(let file, let families):
				let named = families.map { "“\($0)”" }.joined(separator: ", ")
				return "\(file) asks for \(named), which this machine has not got. "
					+ "A browser would substitute something and say nothing, and the "
					+ "render would be wrong in a way nobody was told about — so this "
					+ "is refused instead. Install the family, or name one that is here."
			case .noFrame(let file, let index, let why):
				return "\(file): WebKit would not draw frame \(index) — \(why)"
			case .cannotWrite(let url, let why):
				return "Could not write \(url.lastPathComponent): \(why)"
			case .noRuntime(let name):
				return "\(name) is missing from the app bundle, so no component can be "
					+ "drawn. This is a broken build rather than anything about the project."
			}
		}
	}

	// MARK: - Baking a project

	/// Bakes every `component:` part in `project` that needs it.
	///
	/// **When this is called, and when it is not.** Not on save: a twenty-second
	/// bake on ⌘S is a program nobody can type in. Not on the fly while drawing:
	/// that is the mistake `docs/remotion.md` names first, and it would put a
	/// browser in the preview's redraw and in the compositor's frame request.
	/// On render, and on demand — and in between, the resolver says out loud
	/// that the cache is stale rather than showing last week's chart as though
	/// it were the picture. The one thing that must never happen is a stale
	/// frame presented as the truth, and the way to guarantee it is that nothing
	/// bakes implicitly.
	public static func bake(
		_ project: Project, from baseURL: URL, force: Bool = false,
		progress: (@Sendable (String, Int, Int) -> Void)? = nil
	) async throws -> Report {
		var report = Report()
		let wanted = components(in: project)
		guard !wanted.isEmpty else { return report }

		let runtime = try Runtime.load()
		var host: Page?

		for component in wanted {
			let source = URL(fileURLWithPath: component.file, relativeTo: baseURL)
			guard let text = try? String(contentsOf: source, encoding: .utf8) else {
				throw BakeError.noSource(component.file)
			}
			let frames = component.frames(at: project.output.framesPerSecond)
			let asked = Component.Bake(
				runtime: runtime.fingerprint, source: component.file,
				digest: fingerprint(text), width: project.output.width,
				height: project.output.height, fps: project.output.framesPerSecond,
				frames: frames, props: component.props)

			let folder = URL(fileURLWithPath: component.folder, relativeTo: baseURL)
			if !force, let record = try? String(contentsOf: component.record(relativeTo: baseURL),
			                                    encoding: .utf8),
			   let had = Component.Bake(record), had.differs(from: asked) == nil,
			   component.sequence(at: asked.fps).count(relativeTo: baseURL) == frames {
				report.reused.append(component.file)
				continue
			}

			// One page for the whole project rather than one per component. It
			// is the same runtime every time, and loading React is most of the
			// cost of an empty bake.
			let page: Page
			if let already = host { page = already } else {
				page = try await Page(runtime: runtime)
				host = page
			}

			let start = Date()
			try await page.draw(
				text, named: component.file, props: component.props,
				size: project.output.size, fps: asked.fps, frames: frames,
				into: folder, progress: { done in
					progress?(component.file, done, frames)
				})
			try write(asked, beside: folder)
			report.baked.append((component.file, frames, Date().timeIntervalSince(start)))
		}
		// The frames at those paths are different frames now.
		Reel.shared.empty()
		return report
	}

	/// Every `component:` part in the project, once each.
	///
	/// Once, because two overlays using the same scene ask for the same bake and
	/// baking it twice would be the same pixels for twice the wait.
	public nonisolated static func components(in project: Project) -> [Component] {
		var found: [Component] = []
		for name in project.scenes.keys.sorted() {
			for part in project.scenes[name]?.parts ?? [] {
				guard case .component(let component) = part.content else { continue }
				if !found.contains(component) { found.append(component) }
			}
		}
		return found
	}

	/// What the resolver says beside the picture when a bake is not current.
	///
	/// Nothing here bakes. A warning that the preview is showing yesterday's
	/// chart is honest; drawing yesterday's chart silently is not, and neither
	/// is a black rectangle where a chart was.
	public nonisolated static func staleness(_ project: Project, from baseURL: URL) -> [String] {
		var said: [String] = []
		guard let runtime = try? Runtime.load() else { return said }
		for component in components(in: project) {
			let source = URL(fileURLWithPath: component.file, relativeTo: baseURL)
			guard let text = try? String(contentsOf: source, encoding: .utf8) else {
				said.append("The component `\(component.file)` is not there.")
				continue
			}
			let frames = component.frames(at: project.output.framesPerSecond)
			let asked = Component.Bake(
				runtime: runtime.fingerprint, source: component.file,
				digest: fingerprint(text), width: project.output.width,
				height: project.output.height, fps: project.output.framesPerSecond,
				frames: frames, props: component.props)
			guard let record = try? String(contentsOf: component.record(relativeTo: baseURL),
			                              encoding: .utf8),
			      let had = Component.Bake(record) else {
				said.append("The component `\(component.file)` has never been baked, "
					+ "so there is nothing to show for it yet.")
				continue
			}
			if let why = had.differs(from: asked) {
				said.append("The component `\(component.file)` has not been baked since "
					+ "\(why) — what you are looking at is the last bake.")
			} else if component.sequence(at: asked.fps).count(relativeTo: baseURL) < frames {
				said.append("The component `\(component.file)` is missing frames from "
					+ "its bake; it holds its last one instead.")
			}
		}
		return said
	}

	private static func write(_ bake: Component.Bake, beside folder: URL) throws {
		let url = folder.appendingPathComponent("bake")
		do { try bake.written.write(to: url, atomically: true, encoding: .utf8) }
		catch { throw BakeError.cannotWrite(url, error.localizedDescription) }
	}

	// MARK: - The runtime, out of the bundle

	/// The three files that are the runtime, and a fingerprint of them together.
	struct Runtime: Sendable {
		let react: String
		let reactDOM: String
		let cuttr: String
		/// What goes in a bake record. Derived from the three files rather than
		/// being a number somebody bumps, because the version nobody bumped is
		/// the one that keeps every stale bake.
		let fingerprint: String

		static func load() throws -> Runtime {
			func read(_ name: String, _ ext: String) throws -> String {
				// `Runtime/` is copied whole rather than processed, so the
				// folder is part of the path in the bundle too.
				guard let url = Bundle.module.url(forResource: name, withExtension: ext,
				                                  subdirectory: "Runtime"),
				      let text = try? String(contentsOf: url, encoding: .utf8) else {
					throw BakeError.noRuntime("\(name).\(ext)")
				}
				return text
			}
			let react = try read("react.min", "js")
			let reactDOM = try read("react-dom.min", "js")
			let cuttr = try read("cuttr-component", "js")
			return Runtime(react: react, reactDOM: reactDOM, cuttr: cuttr,
			               fingerprint: CuttrCompose.fingerprint(react + reactDOM + cuttr))
		}

		/// The page, with everything in it.
		///
		/// Everything inline, which is not a shortcut: a page with no
		/// subresources is a page that needs no loads at all, which is what
		/// makes "nothing may be fetched" a fact about the page rather than a
		/// promise about the component.
		///
		/// **The order of the three scripts matters.** `cuttr-component.js` is
		/// what takes `Math.random` away, and `react-dom.min.js` calls it twice
		/// while it is being evaluated — for the suffixes of its own expando
		/// property names, which reach neither the DOM nor a pixel. React has to
		/// finish loading first or nothing bakes at all.
		var page: String {
			"""
			<!doctype html>
			<html><head><meta charset="utf-8"><style>
			html, body { margin: 0; padding: 0; width: 100%; height: 100%;
			             background: transparent; }
			#cuttr-stage { position: absolute; left: 0; top: 0;
			               width: 100%; height: 100%; overflow: hidden; }
			</style></head>
			<body><div id="cuttr-stage"></div>
			<script>\(react)</script>
			<script>\(reactDOM)</script>
			<script>\(cuttr)</script>
			</body></html>
			"""
		}
	}

	// MARK: - The page

	/// A `WKWebView` that is never in a window, and never shown.
	///
	/// No window at all, not a hidden one: `takeSnapshot` works on a view with no
	/// window and the frames come out byte-identical either way, which was worth
	/// checking because the documentation does not say so. A window would be one
	/// more thing that could come to the front while somebody was working.
	final class Page: NSObject, WKNavigationDelegate {
		private let view: WKWebView
		private var loaded: (@MainActor () -> Void)?

		init(runtime: Runtime) async throws {
			let configuration = WKWebViewConfiguration()
			if let rules = await Self.blockEverything() {
				configuration.userContentController.add(rules)
			}
			// Deliberately not persistent: a component with no network has
			// nothing to store, and a bake that depended on what the last bake
			// left in local storage would not be a bake of one file any more.
			configuration.websiteDataStore = .nonPersistent()
			view = WKWebView(frame: CGRect(x: 0, y: 0, width: 16, height: 16),
			                 configuration: configuration)
			// So that what is not drawn comes back transparent rather than
			// white. There is no public spelling of this on macOS;
			// `underPageBackgroundColor` alone leaves the snapshot opaque.
			view.setValue(false, forKey: "drawsBackground")
			view.underPageBackgroundColor = .clear
			super.init()
			view.navigationDelegate = self

			await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
				loaded = { k.resume() }
				view.loadHTMLString(runtime.page, baseURL: nil)
			}
		}

		func webView(_ view: WKWebView, didFinish navigation: WKNavigation!) {
			let done = loaded
			loaded = nil
			done?()
		}

		func webView(_ view: WKWebView, didFail navigation: WKNavigation!, withError: Error) {
			let done = loaded
			loaded = nil
			done?()
		}

		/// Nothing may load. Every URL, blocked.
		///
		/// The JavaScript guards in the runtime catch `fetch` and give a good
		/// error; this catches what they cannot — an `<img src="https://…">`, a
		/// `@font-face`, a stylesheet — where overwriting a function would do
		/// nothing at all. `loadHTMLString` is unaffected, because a page loaded
		/// from a string is not a load.
		private static func blockEverything() async -> WKContentRuleList? {
			let rules = #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]"#
			return await withCheckedContinuation {
				(k: CheckedContinuation<WKContentRuleList?, Never>) in
				guard let store = WKContentRuleListStore.default() else {
					return k.resume(returning: nil)
				}
				store.compileContentRuleList(forIdentifier: "cuttr-nothing-loads",
				                             encodedContentRuleList: rules) { list, _ in
					k.resume(returning: list)
				}
			}
		}

		/// Mounts the component and writes every frame.
		func draw(
			_ source: String, named name: String, props: [String: String],
			size: CGSize, fps: Double, frames: Int, into folder: URL,
			progress: (Int) -> Void
		) async throws {
			view.setFrameSize(size)
			view.layoutSubtreeIfNeeded()

			let config = "{width: \(Int(size.width)), height: \(Int(size.height)), "
				+ "fps: \(fps), durationInFrames: \(frames)}"
			if let trouble = await call(
				"JSON.stringify(cuttr.mount(\(quoted(source)), \(quoted(name)), "
				+ "\(config), \(object(props))))") {
				throw BakeError.script(file: name, line: trouble.line, message: trouble.message)
			}

			let manager = FileManager.default
			// Emptied rather than written over. A bake that got shorter would
			// otherwise leave the tail of the last one behind, and those frames
			// would go on being drawn.
			try? manager.removeItem(at: folder)
			do { try manager.createDirectory(at: folder, withIntermediateDirectories: true) }
			catch { throw BakeError.cannotWrite(folder, error.localizedDescription) }

			for index in 0 ..< frames {
				if let trouble = await call("JSON.stringify(cuttr.draw(\(index)))") {
					throw BakeError.script(file: name, line: trouble.line,
					                       message: trouble.message)
				}
				// Checked on the first frame only. Every frame is the same
				// stylesheet, and measuring a font on all three hundred would
				// double the bake to say the same thing three hundred times.
				if index == 0 {
					let missing = await families()
					if !missing.isEmpty { throw BakeError.missingFonts(file: name, missing) }
				}
				let image = try await snapshot(size, named: name, index: index)
				try write(image, to: folder.appendingPathComponent(
					String(format: "%05d.png", index)))
				progress(index + 1)
			}
		}

		/// The frame, as pixels.
		private func snapshot(_ size: CGSize, named name: String, index: Int) async throws -> CGImage {
			let configuration = WKSnapshotConfiguration()
			configuration.rect = CGRect(origin: .zero, size: size)
			// In points, and the view is sized in points, so this is one pixel
			// per point whatever the screen the machine happens to have. A bake
			// that came out at twice the size on a Retina display and once on a
			// projector would be a bake that depended on the machine.
			configuration.snapshotWidth = NSNumber(value: Int(size.width))
			configuration.afterScreenUpdates = true
			let taken: (image: NSImage?, error: Error?) = await withCheckedContinuation {
				(k: CheckedContinuation<(NSImage?, Error?), Never>) in
				view.takeSnapshot(with: configuration) { image, error in
					k.resume(returning: (image, error))
				}
			}
			guard let image = taken.image,
			      let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
				throw BakeError.noFrame(
					file: name, index: index,
					why: taken.error?.localizedDescription ?? "it handed back nothing")
			}
			return try Self.onePixelPerPoint(cgImage, size, named: name, index: index)
		}

		/// The snapshot at one pixel per point, whatever the machine handed back.
		///
		/// `snapshotWidth` is a width in *points*, and asking for it is not the
		/// same as getting it: on a Retina display WebKit satisfies the request
		/// with a bitmap of twice as many pixels, so a project asking for
		/// 1920×1080 baked to 3840×2160 on a laptop and to 1920×1080 on a
		/// machine plugged into a projector. The frames are the artefact — kept
		/// beside the project and exported with it — so which Mac drew them is
		/// not allowed to decide what they are.
		///
		/// Resampled rather than asked for again, because there is no way to ask
		/// WebKit for a backing scale the screen has not got. Down, and in
		/// premultiplied alpha, which is the only space a soft edge averages
		/// correctly in: blending the ink with what is transparent beside it
		/// unassociated is how an edge picks up the dark fringe that
		/// ``whatWasNotDrawnIsTransparent`` exists to catch.
		private static func onePixelPerPoint(_ image: CGImage, _ size: CGSize,
		                                     named name: String, index: Int) throws -> CGImage {
			let width = Int(size.width), height = Int(size.height)
			guard image.width != width || image.height != height else { return image }
			guard let context = CGContext(
				data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
				space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
				bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
			else {
				throw BakeError.noFrame(
					file: name, index: index,
					why: "a frame of \(image.width)×\(image.height) would not "
						+ "resample to \(width)×\(height)")
			}
			context.interpolationQuality = .high
			context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
			guard let scaled = context.makeImage() else {
				throw BakeError.noFrame(file: name, index: index,
				                        why: "the resampled frame would not come back")
			}
			return scaled
		}

		private func write(_ image: CGImage, to url: URL) throws {
			let rep = NSBitmapImageRep(cgImage: image)
			// PNG, and PNG stores alpha unassociated — which is what makes these
			// frames composite over the picture instead of over black. A format
			// with premultiplied alpha would darken every soft edge, and the
			// test that measures the edge of a circle is there because that is
			// exactly the mistake that does not show in a thumbnail.
			guard let data = rep.representation(using: .png, properties: [:]) else {
				throw BakeError.cannotWrite(url, "the frame would not encode as a PNG")
			}
			do { try data.write(to: url, options: .atomic) }
			catch { throw BakeError.cannotWrite(url, error.localizedDescription) }
		}

		/// Families the frame asks for that this machine has not got.
		private func families() async -> [String] {
			let answer = await evaluate("JSON.stringify(cuttr.missingFonts())")
			guard let text = answer as? String, let data = text.data(using: .utf8),
			      let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
			return list
		}

		/// A call into the page that answers either nothing or what went wrong.
		private func call(_ javaScript: String) async -> (message: String, line: Int?)? {
			let answer = await evaluate(javaScript)
			guard let text = answer as? String, text != "null",
			      let data = text.data(using: .utf8),
			      let trouble = try? JSONDecoder().decode(Trouble.self, from: data) else {
				return nil
			}
			return (trouble.message, trouble.line)
		}

		private struct Trouble: Decodable {
			var message: String
			var line: Int?
		}

		private func evaluate(_ javaScript: String) async -> Any? {
			await withCheckedContinuation { (k: CheckedContinuation<Any?, Never>) in
				view.evaluateJavaScript(javaScript) { value, _ in k.resume(returning: value) }
			}
		}

		/// A Swift string as a JavaScript one.
		///
		/// `<` is escaped as well as what JSON escapes, so that a component
		/// containing the characters `</script` cannot end the script element it
		/// is being handed to. That is not a hypothetical for a component that
		/// draws markup.
		private func quoted(_ text: String) -> String {
			guard let data = try? JSONEncoder().encode(text),
			      let json = String(data: data, encoding: .utf8) else { return "\"\"" }
			return json.replacingOccurrences(of: "<", with: "\\u003c")
		}

		private func object(_ values: [String: String]) -> String {
			"{" + values.keys.sorted().map {
				"\(quoted($0)): \(quoted(values[$0] ?? ""))"
			}.joined(separator: ", ") + "}"
		}
	}
}
