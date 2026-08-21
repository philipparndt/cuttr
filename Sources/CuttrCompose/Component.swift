import CryptoKit
import Foundation

/// A React component beside the project, baked to frames and composited like any
/// other picture.
///
/// **It is not Remotion.** Remotion is a Node toolchain that drives a headless
/// Chromium; this is a subset of its *shape*, rendered in the WebKit that is
/// already on the machine, with nothing to install. Calling the key `remotion:`
/// would be a lie in the format — somebody would reasonably write
/// `@remotion/shapes` in the file and find out by render that it was never
/// there — so the key says what it is. `docs/remotion.md` describes the real
/// Remotion path, which still exists and is still the answer for anything this
/// does not cover.
///
///     - component: charts/walks.js
///       duration:  8
///       props:     {year: "2025", unit: km}
///       keys:
///         - {t: 0, x: 0.5, y: 0.5, width: 1, height: 1}
///
/// ## What is implemented
///
/// The component's file is plain JavaScript — no JSX, no TypeScript, no modules
/// — and is handed these, as arguments rather than as globals:
///
/// - `component(fn)`, which is how the file says which function it is. Remotion
///   has `registerRoot`; this is the same idea with one name.
/// - `useCurrentFrame()`, `useVideoConfig()` → `{width, height, fps,
///   durationInFrames}`.
/// - `useProps()`, which is what the project file's `props:` said. Not
///   Remotion's `getInputProps`, because these are per *use* of the component
///   and Remotion's are per render.
/// - `<Sequence from durationInFrames layout>`, shifting its children's clock.
/// - `interpolate(input, inputRange, outputRange, options)` with
///   `extrapolateLeft`, `extrapolateRight` and `easing`, and the same defaults
///   Remotion has.
/// - `spring({frame, fps, config, from, to})`, the same oscillator with the same
///   default config, so a number tuned there means the same here.
/// - `Easing`: `linear`, `quad`, `cubic`, `sin`, `circle`, `ease`, `bezier`, and
///   `in`/`out`/`inOut` around any of them.
/// - `random(seed)`, which is the only randomness there is.
/// - `React`, `h` (which is `React.createElement`) and `Fragment`.
///
/// ## What is not
///
/// `<Composition>` and `registerRoot` — a project file already says how big the
/// picture is and how long the part is on, and two places to say it is one place
/// to get it wrong. `<Video>`, `<Audio>`, `<Img>` and `staticFile` — nothing may
/// be loaded, see below. `<Freeze>`, `<Loop>`, `<Series>`, `delayRender` and
/// `continueRender` — the last two exist to make an *asynchronous* frame work,
/// and there is nothing asynchronous here. Every `@remotion/*` package. JSX and
/// TypeScript, which need a compiler; `Sources/CuttrCompose/Runtime/LICENCES.md`
/// argues why there is not one in the bundle.
///
/// ## What it cannot do, on purpose
///
/// Nothing is fetched and no file is read — not an image, not a webfont, not a
/// map tile. A `WKContentRuleList` blocks every load and `fetch`, `XMLHttpRequest`,
/// `WebSocket` and `EventSource` throw. A component that reaches the network
/// renders something different next year, and a project whose frames depend on
/// a server is not a project that renders next year at all. Data comes in as
/// `props:` or is written into the file, where a diff can see it.
///
/// The clock reads 1 January 1970 and `Math.random()` throws. A component wanting
/// today's date takes it as a prop, which puts it in the bake's fingerprint where
/// it belongs.
///
/// Fonts are whatever is installed on this machine, named by their macOS family
/// name — the same names `styles:` uses, which is the point: a component and a
/// caption over the same shot should not be two typography systems. A family that
/// is not there is refused by name rather than substituted, because a browser
/// substituting silently is a wrong render nobody is told about.
public struct Component: Sendable, Equatable {

	/// The file, relative to the project.
	public var file: String

	/// How long it draws for, in seconds. This times the output rate is
	/// `durationInFrames`, and it is the one thing the component is not allowed
	/// to decide for itself.
	public var duration: Double

	/// What this use of it is handed. Strings, exactly as a scene's parameters
	/// are and for the same reason: the file is the product, and a project file
	/// that could hold arbitrary structure would be a project file holding a
	/// program.
	public var props: [String: String]

	public init(file: String, duration: Double, props: [String: String] = [:]) {
		self.file = file
		self.duration = duration
		self.props = props
	}

	/// Where the frames go, relative to the project file.
	///
	/// Named after the component rather than after its fingerprint. A hash makes
	/// a better cache — two variants of the same file both stay warm — and a
	/// worse folder: `.cuttr/components/9f3a1c4e…/` tells nobody anything, and
	/// this program's whole argument is that what is on disk should be readable.
	/// So the folder is the name and the fingerprint is one line inside it. The
	/// cost is that switching between two variants re-bakes; the benefit is that
	/// somebody can look at the folder, and that the draw path never hashes
	/// anything.
	///
	/// Separators become dashes so that `charts/walks.js` and `titles/walks.js`
	/// are two folders rather than one.
	public var folder: String {
		let stem = (file as NSString).deletingPathExtension
		let flat = stem.split(whereSeparator: { $0 == "/" || $0 == "\\" })
			.joined(separator: "-")
		return ".cuttr/components/" + (flat.isEmpty ? "component" : flat)
	}

	/// The frames, as the part the render paths actually draw.
	///
	/// A `component:` and a `frames:` are the same part by the time anything
	/// looks at pixels, which is the whole design: there is one implementation
	/// of putting a sequence on the picture, and neither render path knows that
	/// a browser was ever involved.
	public func sequence(at fps: Double) -> FrameSequence {
		FrameSequence(pattern: folder + "/%05d.png", fps: fps)
	}

	/// How many frames a bake of this is, at the output's rate.
	public func frames(at fps: Double) -> Int {
		max(1, Int((duration * fps).rounded()))
	}

	/// Where the record of the last bake lives.
	public func record(relativeTo base: URL) -> URL {
		URL(fileURLWithPath: folder + "/bake", relativeTo: base)
	}
}

public extension Component {

	/// What a folder of frames was baked from.
	///
	/// Written beside the frames as text, and read back to answer the only
	/// question that matters about a cache: is this still the thing the project
	/// asks for? Every field is one of the inputs — so when the answer is no,
	/// the *reason* is a field comparison rather than a hash that changed for
	/// unknowable reasons, and ``differs(from:)`` can say which.
	///
	/// The digest is of the source text, not of its path or its modification
	/// date. A date would make an exported project re-bake the moment it was
	/// copied, which is the opposite of what the cache travelling with the
	/// project is for.
	struct Bake: Sendable, Equatable {
		/// A fingerprint of the runtime that drew these — `cuttr-component.js`
		/// and the two React files, together. Derived rather than a number
		/// somebody remembers to raise, because the number nobody raised is the
		/// bug: a runtime change that silently kept every stale bake.
		public var runtime: String
		public var source: String
		public var digest: String
		public var width: Int
		public var height: Int
		public var fps: Double
		public var frames: Int
		public var props: [String: String]

		public init(runtime: String, source: String, digest: String, width: Int,
		            height: Int, fps: Double, frames: Int, props: [String: String]) {
			self.runtime = runtime
			self.source = source
			self.digest = digest
			self.width = width
			self.height = height
			self.fps = fps
			self.frames = frames
			self.props = props
		}

		/// Why these frames are not what the project is now asking for, in a
		/// sentence, or `nil` if they are.
		///
		/// One reason, the first that differs, because "the size changed" is
		/// what somebody needs and a list of five differences is what they get
		/// when the runtime changed and everything is measured differently.
		public func differs(from wanted: Bake) -> String? {
			if runtime != wanted.runtime { return "cuttr's component runtime has changed" }
			if source != wanted.source { return "it is a different file now" }
			if digest != wanted.digest { return "the file has been edited" }
			if width != wanted.width || height != wanted.height {
				return "the output is \(wanted.width)×\(wanted.height) now, "
					+ "not \(width)×\(height)"
			}
			if fps != wanted.fps {
				return "the output is \(trimmed(wanted.fps)) fps now, not \(trimmed(fps))"
			}
			if frames != wanted.frames {
				return "it is on for \(wanted.frames) frames now, not \(frames)"
			}
			if props != wanted.props { return "its props have changed" }
			return nil
		}

		/// The record as it is written. Fixed order, fixed spelling, so that
		/// baking the same component twice writes the same file — the rule the
		/// project's own emitter follows, for the same reason.
		public var written: String {
			var out = "# What these frames were baked from. cuttr bakes again when\n"
			out += "# this no longer matches what the project asks for.\n"
			out += "runtime: \(runtime)\n"
			out += "source:  \(source)\n"
			out += "digest:  \(digest)\n"
			out += "size:    \(width)x\(height)\n"
			out += "fps:     \(trimmed(fps))\n"
			out += "frames:  \(frames)\n"
			for name in props.keys.sorted() {
				out += "prop:    \(name)=\(props[name] ?? "")\n"
			}
			return out
		}

		/// A record read back. `nil` for anything that is not one, which is
		/// treated as no cache at all — a bake nobody can account for is a bake
		/// worth doing again.
		public init?(_ text: String) {
			var fields: [String: String] = [:]
			var props: [String: String] = [:]
			for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
				let row = line.trimmingCharacters(in: .whitespaces)
				if row.hasPrefix("#") || row.isEmpty { continue }
				guard let colon = row.firstIndex(of: ":") else { continue }
				let key = String(row[row.startIndex ..< colon])
				let value = String(row[row.index(after: colon)...])
					.trimmingCharacters(in: .whitespaces)
				if key == "prop" {
					guard let equals = value.firstIndex(of: "=") else { continue }
					props[String(value[value.startIndex ..< equals])] =
						String(value[value.index(after: equals)...])
				} else {
					fields[key] = value
				}
			}
			let size = (fields["size"] ?? "").split(separator: "x")
			guard let runtime = fields["runtime"], let source = fields["source"],
			      let digest = fields["digest"], size.count == 2,
			      let width = Int(size[0]), let height = Int(size[1]),
			      let fps = Double(fields["fps"] ?? ""),
			      let frames = Int(fields["frames"] ?? "") else { return nil }
			self.init(runtime: runtime, source: source, digest: digest, width: width,
			          height: height, fps: fps, frames: frames, props: props)
		}
	}
}

/// A number written the way the project file writes one: no trailing zeroes on
/// a whole number, because `25` is what somebody typed.
private func trimmed(_ value: Double) -> String {
	value == value.rounded() && abs(value) < 1e15
		? String(Int(value))
		: String(format: "%g", value)
}

/// The digest of a piece of text, short enough to read and long enough not to
/// collide.
///
/// Sixteen hex digits — sixty-four bits. A cache key, not a signature: nobody is
/// trying to forge a bake, and a line somebody can compare by eye when they are
/// working out why something re-baked is worth more than the other forty-eight.
func fingerprint(_ text: String) -> String {
	SHA256.hash(data: Data(text.utf8)).prefix(8)
		.map { String(format: "%02x", $0) }.joined()
}
