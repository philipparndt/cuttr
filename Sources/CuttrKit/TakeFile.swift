import CoreGraphics
import Foundation
import Yams

/// What went wrong reading a take file.
///
/// The messages are written for somebody who has just hand-edited the file and
/// is looking at it, which is the only situation this error occurs in. They
/// name the key.
public enum TakeError: LocalizedError {
	case notAMapping
	case unsupportedVersion(Int)
	case missingMedia
	case badTime(key: String, value: String)
	case badClip(index: Int, reason: String)
	case yaml(String)

	public var errorDescription: String? {
		switch self {
		case .notAMapping:
			return "This is not a cuttr take: the file's top level should be a list of keys."
		case .unsupportedVersion(let v):
			return "This take says `cuttr: \(v)`, which this version does not know how to read."
		case .missingMedia:
			return "A take needs a `video:` or an `audio:` to cut."
		case .badTime(let key, let value):
			return "`\(key): \(value)` is not a time. Write MM:SS.mmm, HH:MM:SS.mmm, or seconds."
		case .badClip(let index, let reason):
			return "Clip \(index + 1): \(reason)"
		case .yaml(let message):
			return "This file is not valid YAML: \(message)"
		}
	}
}

/// Reading a take from text.
public enum TakeReader {

	/// The only version this program writes, and the only one it reads.
	public static let formatVersion = 1

	public static func read(_ text: String) throws -> Take {
		let object: Any?
		do { object = try Yams.load(yaml: text) }
		catch { throw TakeError.yaml(error.localizedDescription) }

		// An empty file is an empty take rather than an error: `touch a.cuttr`
		// and dropping a video on the window is a reasonable way to start.
		guard let object else { return Take() }
		guard var root = mapping(object) else { throw TakeError.notAMapping }

		if let version = root.removeValue(forKey: "cuttr") {
			let n = (version as? Int) ?? Int((version as? String) ?? "") ?? 0
			guard n <= formatVersion, n > 0 else { throw TakeError.unsupportedVersion(n) }
		}

		let video = (root.removeValue(forKey: "video") as? String).flatMap(nonEmpty)

		var audio: AudioTrack?
		if let raw = root.removeValue(forKey: "audio") {
			// Two spellings, because both get written by hand. `audio: x.wav`
			// is the whole thing when the offset is zero, which it is until
			// somebody aligns it.
			if let file = nonEmpty(raw as? String ?? "") {
				audio = AudioTrack(file: file)
			} else if let m = mapping(raw), let file = nonEmpty(m["file"] as? String ?? "") {
				let offset = try m["offset"].map { try time($0, key: "offset") } ?? 0
				audio = AudioTrack(file: file, offset: offset)
			}
		}

		guard video != nil || audio != nil else { throw TakeError.missingMedia }

		// Where it came from, when it came from anywhere. Read leniently — a
		// block with no `provider:` is somebody's note to themselves rather
		// than a fault worth refusing the whole file over.
		var source: TakeSource?
		if var m = root.removeValue(forKey: "source").flatMap(mapping),
		   let provider = nonEmpty(m.removeValue(forKey: "provider") as? String ?? "") {
			let id = nonEmpty(m.removeValue(forKey: "id") as? String ?? "") ?? ""
			let page = nonEmpty(m.removeValue(forKey: "page") as? String ?? "")
			let title = nonEmpty(m.removeValue(forKey: "title") as? String ?? "")
			let attribution = nonEmpty(m.removeValue(forKey: "attribution") as? String ?? "")
			// Whatever else the block held, kept as it was written.
			var extra: [String: String] = [:]
			for (key, value) in m { extra[key] = String(describing: value) }
			source = TakeSource(provider: Slug.make(from: provider), id: id, page: page,
			                    title: title, attribution: attribution, extra: extra)
		}

		var clips: [Clip] = []
		var seen = Set<String>()
		if let list = root.removeValue(forKey: "clips") as? [Any] {
			for (index, entry) in list.enumerated() {
				guard let m = mapping(entry) else {
					throw TakeError.badClip(index: index, reason: "expected a list of keys")
				}
				guard let start = try m["start"].map({ try time($0, key: "start") }) else {
					throw TakeError.badClip(index: index, reason: "no `start:`")
				}
				guard let end = try m["end"].map({ try time($0, key: "end") }) else {
					throw TakeError.badClip(index: index, reason: "no `end:`")
				}
				let name = (m["name"] as? String) ?? ""
				// A slug is required in principle and derived in practice: a
				// file somebody sketched by hand, with names and no slugs, is
				// worth opening. Uniquing here rather than at save keeps the
				// references stable from the moment the file is read.
				let requested = nonEmpty(m["slug"] as? String ?? "") ?? Slug.make(from: name)
				let slug = Slug.unique(Slug.make(from: requested), taken: seen)
				seen.insert(slug)
				clips.append(Clip(
					slug: slug,
					name: name,
					start: start,
					end: end,
					note: nonEmpty(m["note"] as? String ?? ""),
					// An unknown colour name falls back to the default rather
					// than failing the read. A palette can lose a name between
					// versions, and a take is worth more than its colouring.
					color: (m["color"] as? String).flatMap(ClipColor.named) ?? .default,
					// `tags: [a, b]` and `tags: a` both, because a single tag
					// written without brackets is what somebody types.
					tags: (m["tags"] as? [Any])?.compactMap { $0 as? String }
						?? (m["tags"] as? String).map { [$0] } ?? [],
					order: (m["order"] as? Int) ?? Int((m["order"] as? String) ?? "") ?? Clip.defaultOrder
				))
			}
		}

		// Anchors: what was marked, not what was solved. The path is a sidecar.
		var anchors: [Anchor] = []
		for entry in (root.removeValue(forKey: "anchors") as? [Any]) ?? [] {
			guard let m = mapping(entry), let name = nonEmpty(m["name"] as? String ?? "")
			else { continue }
			let point = (m["point"] as? [Any])?.compactMap { number($0) } ?? []
			let markedAt = try time(m["at"] ?? 0, key: "at")
			anchors.append(Anchor(
				name: Slug.make(from: name),
				// The shot it was solved over. A file that only says `at:` is a
				// point nobody has solved yet, which is a zero-length range —
				// the solver replaces it with what it managed to follow.
				from: try m["from"].map { try time($0, key: "from") } ?? markedAt,
				to: try m["to"].map { try time($0, key: "to") } ?? markedAt,
				markedAt: markedAt,
				point: CGPoint(x: point.count == 2 ? point[0] : 0.5,
				               y: point.count == 2 ? point[1] : 0.5),
				method: (m["method"] as? String).flatMap(Anchor.Method.init(rawValue:)) ?? .faceLandmark,
				path: nonEmpty(m["path"] as? String ?? "")))
		}

		var measured = Measured()
		if let m = root.removeValue(forKey: "measured").flatMap(mapping) {
			measured.loudness = number(m["loudness"])
			measured.peak = number(m["peak"])
			if let cast = (m["cast"] as? [Any])?.compactMap({ number($0) }), cast.count == 3 {
				measured.cast = cast
			}
		}

		var look = Look.none
		if let m = root.removeValue(forKey: "look").flatMap(mapping) {
			look.profile = (m["profile"] as? String).flatMap(nonEmpty).map { Slug.make(from: $0) }
			look.exposure = number(m["exposure"]) ?? 0
			look.temperature = number(m["temperature"]) ?? 0
			look.tint = number(m["tint"]) ?? 0
			look.saturation = number(m["saturation"]) ?? 1
			look.contrast = number(m["contrast"]) ?? 1
			if let gain = (m["gain"] as? [Any])?.compactMap({ number($0) }), gain.count == 3 {
				look.gain = gain
			}
		}

		return Take(video: video, audio: audio, clips: clips, anchors: anchors,
		            measured: measured, look: look, source: source, unknownKeys: root)
	}

	static func number(_ value: Any?) -> Double? {
		if let d = value as? Double { return d }
		if let i = value as? Int { return Double(i) }
		if let s = value as? String { return Double(s) }
		return nil
	}

	/// A time is a string (`00:12.300`) or a plain number of seconds. YAML
	/// gives back whichever the file used, and both are meant.
	private static func time(_ value: Any, key: String) throws -> Double {
		if let d = value as? Double { return d }
		if let i = value as? Int { return Double(i) }
		if let s = value as? String, let parsed = Timecode.parse(s) { return parsed }
		throw TakeError.badTime(key: key, value: String(describing: value))
	}

	private static func mapping(_ value: Any) -> [String: Any]? {
		if let m = value as? [String: Any] { return m }
		// Yams keys a mapping by `AnyHashable` when any key is not a string —
		// `1: x` in a hand-written file is enough to do it.
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

/// Writing a take back to text.
///
/// Hand-written rather than `Yams.dump`, and the reason is `git diff`. A
/// general emitter is free to reorder keys, re-wrap a long line, change how it
/// quotes, and fold a short mapping onto one line — all of which are valid YAML
/// and all of which turn "I renamed one clip" into a rewritten file. This one
/// writes the same bytes for the same take, every time: fixed key order,
/// aligned values, one blank line between clips, and quoting only where the
/// value would otherwise be read as something else.
public enum TakeWriter {

	public static func write(_ take: Take) -> String {
		var out = ""
		out += "# cuttr take — a plain-text cut list. Edit it here or in the app.\n"
		out += "cuttr: \(TakeReader.formatVersion)\n\n"

		if let video = take.video {
			out += "video: \(scalar(video))\n"
		}
		if let audio = take.audio {
			// The short form when there is nothing to say beyond the file, so
			// that a take nobody has aligned yet does not carry `offset: 0`
			// around looking like a decision somebody made.
			if audio.offset == 0 {
				out += "audio: \(scalar(audio.file))\n"
			} else {
				out += "audio:\n"
				out += "  file:   \(scalar(audio.file))\n"
				out += "  offset: \(Timecode.offsetString(audio.offset))"
				out += "   # audio + offset = video clock\n"
			}
		}

		// Where it came from. Directly under the media, because it is a fact
		// about the media and not about the cut — and above everything else,
		// because a person opening a take they did not record wants to know
		// whose it is before they read what was done to it.
		if let source = take.source {
			out += "\nsource:\n"
			out += "  provider:    \(scalar(source.provider))\n"
			if !source.id.isEmpty { out += "  id:          \(scalar(source.id))\n" }
			if let title = source.title { out += "  title:       \(scalar(title))\n" }
			if let page = source.page { out += "  page:        \(scalar(page))\n" }
			if let attribution = source.attribution {
				out += "  attribution: \(scalar(attribution))"
				out += "   # the service's terms ask for this to be shown\n"
			}
			// Sorted, because the order of a dictionary is not the order of a
			// file: unsorted, re-saving an untouched take would shuffle these
			// and every save would be a diff.
			for key in source.extra.keys.sorted() {
				out += "  \(key): \(scalar(source.extra[key]!))\n"
			}
		}

		// Unknown keys from a newer version, kept so that opening a file in an
		// older build and saving it does not delete what it did not understand.
		if !take.unknownKeys.isEmpty {
			out += "\n"
			for key in take.unknownKeys.keys.sorted() {
				let node = try? Yams.dump(object: [key: take.unknownKeys[key]!])
				out += node ?? ""
			}
		}

		// What was measured, and what to do about it. Both left out entirely when
		// there is nothing to say, so a take nobody has analysed does not carry
		// a block of defaults that look like decisions.
		if !take.measured.isEmpty {
			out += "\nmeasured:\n"
			if let loudness = take.measured.loudness {
				out += "  loudness: \(number(loudness, places: 1))   # LUFS\n"
			}
			if let peak = take.measured.peak {
				out += "  peak:     \(number(peak, places: 1))   # dBFS\n"
			}
			if let cast = take.measured.cast {
				out += "  cast:     [\(cast.map { number($0, places: 4) }.joined(separator: ", "))]"
				out += "   # mean linear RGB\n"
			}
		}

		if !take.look.isEmpty {
			out += "\nlook:\n"
			if let profile = take.look.profile { out += "  profile:    \(scalar(profile))\n" }
			if take.look.exposure != 0 { out += "  exposure:   \(number(take.look.exposure, places: 3))\n" }
			if take.look.temperature != 0 { out += "  temperature: \(number(take.look.temperature, places: 0))\n" }
			if take.look.tint != 0 { out += "  tint:       \(number(take.look.tint, places: 3))\n" }
			if take.look.saturation != 1 { out += "  saturation: \(number(take.look.saturation, places: 3))\n" }
			if take.look.contrast != 1 { out += "  contrast:   \(number(take.look.contrast, places: 3))\n" }
			if let gain = take.look.gain {
				out += "  gain:       [\(gain.map { number($0, places: 4) }.joined(separator: ", "))]"
				out += "   # matched to the reference\n"
			}
		}

		if !take.anchors.isEmpty {
			out += "\nanchors:\n"
			for (index, anchor) in take.anchors.enumerated() {
				if index > 0 { out += "\n" }
				out += "  - name:   \(scalar(anchor.name))\n"
				out += "    from:   \(Timecode.string(anchor.from))\n"
				out += "    to:     \(Timecode.string(anchor.to))\n"
				out += "    at:     \(Timecode.string(anchor.markedAt))\n"
				out += "    point:  [\(String(format: "%.4f", anchor.point.x)), "
					+ "\(String(format: "%.4f", anchor.point.y))]\n"
				out += "    method: \(anchor.method.rawValue)\n"
				if let path = anchor.path { out += "    path:   \(scalar(path))\n" }
			}
		}

		out += "\nclips:\n"
		if take.clips.isEmpty {
			// A file with no clips still says where they go, so that the next
			// person to open it in an editor has somewhere to type.
			out += "  # none yet — cut some in the app, or add them here:\n"
			out += "  # - slug:  intro\n"
			out += "  #   name:  Intro\n"
			out += "  #   start: 00:00.000\n"
			out += "  #   end:   00:10.000\n"
			return out
		}

		for (index, clip) in take.clips.enumerated() {
			if index > 0 { out += "\n" }
			out += "  - slug:  \(scalar(clip.slug))\n"
			out += "    name:  \(scalar(clip.name))\n"
			out += "    start: \(Timecode.string(clip.start))\n"
			out += "    end:   \(Timecode.string(clip.end))"
			// The duration is a comment rather than a key, because it is not
			// an input: it is `end - start`, and a key would be a second place
			// for it to be wrong. As a comment it is there when somebody is
			// reading the file and cannot contradict the times above it.
			out += "   # \(Timecode.string(clip.duration))\n"
			if clip.color != .default {
				out += "    color: \(clip.color.rawValue)\n"
			}
			if !clip.tags.isEmpty {
				out += "    tags:  [\(clip.tags.joined(separator: ", "))]\n"
			}
			// The default is left out, so a take nobody has re-ordered does not
			// carry `order: 1000` on every clip looking like a decision.
			if clip.order != Clip.defaultOrder {
				out += "    order: \(clip.order)\n"
			}
			if let note = clip.note, !note.isEmpty {
				out += "    note:  \(scalar(note))\n"
			}
		}
		return out
	}

	/// Quotes a value only when leaving it bare would change what it means.
	///
	/// Bare is the goal: `name: Installing the driver` is what makes the file
	/// worth reading, and a program that quotes everything has written JSON
	/// with extra steps.
	/// Public because the project writer quotes by exactly the same rules, and
	/// two implementations of "when does YAML need quotes" is one too many.
	public static func scalar(_ value: String) -> String {
		if value.isEmpty { return "\"\"" }
		// Leading or trailing space survives quoting and nothing else.
		if value != value.trimmingCharacters(in: .whitespaces) { return quoted(value) }
		// The characters YAML gives a meaning to at the start of a scalar.
		if let first = value.first, "-?:,[]{}#&*!|>'\"%@`".contains(first) { return quoted(value) }
		// `: ` starts a mapping and ` #` starts a comment, anywhere in the line.
		if value.contains(": ") || value.contains(" #") || value.hasSuffix(":") { return quoted(value) }
		if value.contains("\n") { return quoted(value) }
		// Words YAML reads as something other than a string. A clip called
		// `no` or `off` is the sort of thing that happens once and is baffling.
		let lower = value.lowercased()
		if ["true", "false", "yes", "no", "on", "off", "null", "~"].contains(lower) { return quoted(value) }
		// A name that is only digits would come back as a number.
		if Double(value) != nil { return quoted(value) }
		return value
	}

	/// A number without a trailing run of zeroes, because `1.040000` is not how
	/// anybody writes it. Public because the project panel shows the same
	/// numbers in its fields as the file has in it.
	public static func number(_ value: Double, places: Int) -> String {
		var text = String(format: "%.\(places)f", value)
		if text.contains(".") {
			while text.hasSuffix("0") { text.removeLast() }
			if text.hasSuffix(".") { text.removeLast() }
		}
		return text
	}

	private static func quoted(_ value: String) -> String {
		var s = "\""
		for ch in value.unicodeScalars {
			switch ch {
			case "\"": s += "\\\""
			case "\\": s += "\\\\"
			case "\n": s += "\\n"
			case "\t": s += "\\t"
			default: s.unicodeScalars.append(ch)
			}
		}
		return s + "\""
	}
}
