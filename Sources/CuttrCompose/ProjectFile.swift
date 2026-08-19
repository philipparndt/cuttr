import CoreGraphics
import CuttrKit
import Foundation
import Yams

public enum ProjectError: LocalizedError {
	case notAMapping
	case unsupportedVersion(Int)
	case badValue(key: String, value: String)
	case yaml(String)

	public var errorDescription: String? {
		switch self {
		case .notAMapping:
			return "This is not a cuttr project: the file's top level should be a list of keys."
		case .unsupportedVersion(let v):
			return "This project says `cuttr-project: \(v)`, which this version cannot read."
		case .badValue(let key, let value):
			return "`\(key): \(value)` is not something cuttr understands."
		case .yaml(let message):
			return "This file is not valid YAML: \(message)"
		}
	}
}

public enum ProjectReader {

	public static let formatVersion = 1

	public static func read(_ text: String) throws -> Project {
		let object: Any?
		do { object = try Yams.load(yaml: text) }
		catch { throw ProjectError.yaml(error.localizedDescription) }
		// An empty file is an empty project. A project is created before it has
		// anything in it — that is the point of creating one — and a format
		// that refuses to hold nothing cannot be saved until it is finished.
		guard let object else { return Project() }
		guard var root = mapping(object) else { throw ProjectError.notAMapping }

		if let version = root.removeValue(forKey: "cuttr-project") {
			let n = (version as? Int) ?? Int((version as? String) ?? "") ?? 0
			guard n > 0, n <= formatVersion else { throw ProjectError.unsupportedVersion(n) }
		}

		let takes = stringList(root.removeValue(forKey: "takes"))

		var output = Output()
		if let m = root.removeValue(forKey: "output").flatMap(mapping) {
			// `1920x1080`, because that is how a frame size is written down.
			if let size = m["size"] as? String {
				let parts = size.lowercased().split(separator: "x")
				guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]), w > 0, h > 0 else {
					throw ProjectError.badValue(key: "size", value: size)
				}
				output.width = w
				output.height = h
			}
			if let fps = number(m["fps"]) { output.framesPerSecond = fps }
			output.file = (m["file"] as? String).flatMap(nonEmpty)
			// `audio: {target: -16, ceiling: -1}`, or `audio: -16` for the
			// common case where only the target matters.
			if let value = m["audio"] {
				var audio = AudioTarget()
				if let level = number(value) {
					audio.target = level
				} else if let fields = mapping(value) {
					audio.target = number(fields["target"]) ?? audio.target
					audio.ceiling = number(fields["ceiling"]) ?? audio.ceiling
				}
				output.audio = audio
			}
			if let value = m["match"] {
				if let slug = (value as? String).flatMap(nonEmpty) {
					output.matchReference = Slug.make(from: slug)
				} else if let fields = mapping(value),
				          let slug = (fields["reference"] as? String).flatMap(nonEmpty) {
					output.matchReference = Slug.make(from: slug)
				}
			}
		}

		// Named colour looks a take's `look: {profile: …}` can refer to.
		var profiles: [String: Look] = [:]
		if let m = root.removeValue(forKey: "profiles").flatMap(mapping) {
			for (name, value) in m {
				guard let fields = mapping(value) else { continue }
				var look = Look.none
				look.exposure = number(fields["exposure"]) ?? 0
				look.temperature = number(fields["temperature"]) ?? 0
				look.tint = number(fields["tint"]) ?? 0
				look.saturation = number(fields["saturation"]) ?? 1
				look.contrast = number(fields["contrast"]) ?? 1
				profiles[Slug.make(from: name)] = look
			}
		}

		var styles: [String: TextStyle] = [:]
		if let m = root.removeValue(forKey: "styles").flatMap(mapping) {
			for (name, value) in m {
				guard let fields = mapping(value) else { continue }
				// Layered on the built-in of the same name where there is one,
				// so overriding a style means changing the line you care about
				// rather than restating all nine.
				styles[name] = try readStyle(fields, base: TextStyle.builtIn[name] ?? .lowerThird)
			}
		}

		// Anchors used to be here. They live in the take now — where somebody's
		// eye is in a recording is a fact about the recording — so an `anchors:`
		// block in a project is read and kept as an unknown key rather than
		// silently dropped, and does nothing.
		// The timeline nests: a group's `clips:` are entries like any other, so
		// reading one is the same function again.
		func readEntries(_ value: Any?) throws -> [TimelineEntry] {
			var out: [TimelineEntry] = []
			for entry in list(value) {
				if let text = entry as? String {
					out.append(try entryFromText(text, transition: 0))
				} else if let m = mapping(entry) {
					let transition = try time(m["transition"], key: "transition") ?? 0
					if let group = (m["group"] as? String).flatMap(nonEmpty) {
						out.append(TimelineEntry(
							group: Slug.make(from: group),
							entries: try readEntries(m["clips"]),
							transition: transition))
					} else if let query = (m["query"] as? String).flatMap(nonEmpty) {
						out.append(try TimelineEntry(query: query, transition: transition))
					} else if let tag = (m["tag"] as? String).flatMap(nonEmpty) {
						// `tag:` is sugar for a one-term query, and the
						// commonest one — worth its own key so the simple case
						// reads simply.
						out.append(try TimelineEntry(query: "#\(tag)", transition: transition))
					} else if let clips = m["clips"] as? [Any] {
						out.append(TimelineEntry(
							list: clips.compactMap { ($0 as? String).map(ClipReference.init) },
							transition: transition))
					} else if let clip = (m["clip"] as? String).flatMap(nonEmpty) {
						out.append(TimelineEntry(clip: ClipReference(clip), transition: transition))
					}
				}
			}
			return out
		}
		// No `timeline:` at all, or an empty one, is a project with nothing on
		// it yet rather than a broken file. Whether there is anything to
		// *render* is the resolver's question, and it asks it where the answer
		// matters.
		let timeline = try readEntries(root.removeValue(forKey: "timeline"))
		var overlays: [Overlay] = []
		for entry in list(root.removeValue(forKey: "overlays")) {
			guard let m = mapping(entry) else { continue }
			let kind: Overlay.Kind
			if let text = m["text"] as? String {
				kind = .text(text, style: (m["style"] as? String).flatMap(nonEmpty))
			} else if let spinnerValue = m["spinner"] {
				var spinner = Spinner()
				// `spinner: dots` and `spinner: {style: dots, size: 0.1}` both.
				if let name = spinnerValue as? String {
					spinner.style = Spinner.Style(rawValue: name) ?? .dots
				} else if let fields = mapping(spinnerValue) {
					spinner.style = (fields["style"] as? String).flatMap(Spinner.Style.init(rawValue:)) ?? .dots
					if let size = number(fields["size"]) { spinner.size = size }
					if let speed = number(fields["speed"]) { spinner.speed = speed }
					if let color = (fields["color"] as? String).flatMap(RGBA.init(hex:)) { spinner.color = color }
				}
				if let size = number(m["size"]) { spinner.size = size }
				if let speed = number(m["speed"]) { spinner.speed = speed }
				if let color = (m["color"] as? String).flatMap(RGBA.init(hex:)) { spinner.color = color }
				spinner.wordStyle = (m["word-style"] as? String).flatMap(nonEmpty)
				// `words: [a, b]` for the even case, or a list of
				// `{text:, for:}` when the timings matter.
				for word in list(m["words"]) {
					if let text = word as? String {
						spinner.words.append(SpinnerWord(text))
					} else if let fields = mapping(word), let text = fields["text"] as? String {
						spinner.words.append(SpinnerWord(text, duration: number(fields["for"])))
					}
				}
				kind = .spinner(spinner)
			} else {
				continue
			}

			// One range, or several under `when:`. The plural is a list of the
			// singular — the same three keys, in a list — so learning the one
			// teaches the other.
			func range(_ fields: [String: Any]) -> Overlay.Span? {
				// `group: introduction` is the same as `from: @introduction`,
				// and is worth its own key because hanging a caption on a whole
				// section is the commonest thing anybody wants to do with one.
				if let group = (fields["group"] as? String).flatMap(nonEmpty) {
					let endpoint = Overlay.Span.Endpoint.group(Slug.make(from: group))
					return .marks(from: endpoint, to: endpoint)
				}
				if let from = fields["from"] as? String,
				   let to = (fields["to"] as? String) ?? (fields["from"] as? String) {
					// A time written where a clip goes is a time. `00:05.000` is
					// not a slug and a slug is not a timecode, so there is
					// nothing to disambiguate.
					if let a = Timecode.parse(from), let b = Timecode.parse(to), from.contains(":") {
						return .times(from: a, to: b)
					}
					return .marks(from: .init(from), to: .init(to))
				}
				if let a = (try? time(fields["from"], key: "from")) ?? nil,
				   let b = (try? time(fields["to"], key: "to")) ?? nil {
					return .times(from: a, to: b)
				}
				return nil
			}

			var spans: [Overlay.Span] = []
			if let list = m["when"] as? [Any] {
				spans = list.compactMap { mapping($0).flatMap(range) }
			} else if let span = range(m) {
				spans = [span]
			}
			guard !spans.isEmpty else { continue }

			overlays.append(Overlay(
				kind: kind,
				spans: spans,
				arrival: try transition(m["in"], key: "in") ?? .slide(.left, over: 0.4),
				departure: try transition(m["out"], key: "out") ?? .slide(.right, over: 0.4),
				anchor: (m["anchor"] as? String).flatMap(nonEmpty),
				offset: try point(m["offset"], key: "offset") ?? .zero
			))
		}

		return Project(takes: takes, output: output, timeline: timeline,
		               overlays: overlays, styles: styles, profiles: profiles,
		               unknownKeys: root)
	}

	/// One rule for "what does this string mean", shared with the panel.
	private static func entryFromText(_ text: String, transition: Double) throws -> TimelineEntry {
		try TimelineEntry(text: text, transition: transition)
	}

	// MARK: - Pieces

	private static func readStyle(_ m: [String: Any], base: TextStyle) throws -> TextStyle {
		var style = base
		if let font = (m["font"] as? String).flatMap(nonEmpty) { style.font = font }
		if let size = number(m["size"]) { style.size = size }
		if let color = (m["color"] as? String).flatMap(RGBA.init(hex:)) { style.color = color }
		if let background = m["background"] as? String {
			// `background: none` for no plate, which is what somebody writes
			// before they think to write `#00000000`.
			style.background = background.lowercased() == "none"
				? RGBA(r: 0, g: 0, b: 0, a: 0)
				: (RGBA(hex: background) ?? style.background)
		}
		if let padding = number(m["padding"]) { style.padding = padding }
		if let radius = number(m["radius"]) { style.cornerRadius = radius }
		if let position = try point(m["position"], key: "position") { style.position = position }
		if let align = (m["align"] as? String).flatMap(TextStyle.Alignment.init(rawValue:)) {
			style.alignment = align
		}
		return style
	}

	/// `{slide: left, over: 0.4}`, `{fade: 0.3}`, or `cut`.
	private static func transition(_ value: Any?, key: String) throws -> Overlay.Transition? {
		guard let value else { return nil }
		if let text = value as? String {
			switch text.lowercased() {
			case "cut", "none": return .cut
			case "fade": return .fade(over: 0.4)
			case "left", "right", "up", "down":
				return .slide(Overlay.Transition.Edge(rawValue: text.lowercased()) ?? .left, over: 0.4)
			default: throw ProjectError.badValue(key: key, value: text)
			}
		}
		guard let m = mapping(value) else { throw ProjectError.badValue(key: key, value: "\(value)") }
		let over = number(m["over"]) ?? number(m["fade"]) ?? 0.4
		if let edge = (m["slide"] as? String).flatMap(Overlay.Transition.Edge.init(rawValue:)) {
			return .slide(edge, over: over)
		}
		if m["fade"] != nil { return .fade(over: over) }
		return .cut
	}

	private static func point(_ value: Any?, key: String) throws -> CGPoint? {
		guard let value else { return nil }
		guard let pair = value as? [Any], pair.count == 2,
		      let x = number(pair[0]), let y = number(pair[1])
		else { throw ProjectError.badValue(key: key, value: "\(value)") }
		return CGPoint(x: x, y: y)
	}

	private static func time(_ value: Any?, key: String) throws -> Double? {
		guard let value else { return nil }
		if let d = number(value) { return d }
		if let s = value as? String, let parsed = Timecode.parse(s) { return parsed }
		throw ProjectError.badValue(key: key, value: "\(value)")
	}

	private static func number(_ value: Any?) -> Double? {
		if let d = value as? Double { return d }
		if let i = value as? Int { return Double(i) }
		if let s = value as? String { return Double(s) }
		return nil
	}

	private static func list(_ value: Any?) -> [Any] { (value as? [Any]) ?? [] }

	private static func stringList(_ value: Any?) -> [String] {
		if let one = value as? String { return [one] }
		return list(value).compactMap { $0 as? String }
	}

	private static func mapping(_ value: Any) -> [String: Any]? {
		if let m = value as? [String: Any] { return m }
		if let m = value as? [AnyHashable: Any] {
			return Dictionary(uniqueKeysWithValues: m.map { (String(describing: $0.key), $0.value) })
		}
		return nil
	}

	private static func nonEmpty(_ s: String) -> String? {
		let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
		return t.isEmpty ? nil : t
	}
}
