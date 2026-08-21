import CoreGraphics
import CuttrKit
import Foundation
import Yams

public enum ProjectError: LocalizedError {
	case notAMapping
	case unsupportedVersion(Int)
	case badValue(key: String, value: String)
	/// A key asks for something to move that cannot move, or cannot move
	/// honestly. Named rather than dropped: an animation that silently does
	/// nothing is worse than one that will not open.
	case cannotAnimate(parameter: String, reason: String)
	/// The file asks for something this format understands perfectly well and
	/// will not do. Its own case, rather than ``badValue``, because "not
	/// something cuttr understands" is the wrong sentence for a word that was
	/// considered and left out: the reason is the whole of what somebody needs.
	case refused(key: String, value: String, reason: String)
	case yaml(String)

	public var errorDescription: String? {
		switch self {
		case .notAMapping:
			return "This is not a cuttr project: the file's top level should be a list of keys."
		case .unsupportedVersion(let v):
			return "This project says `cuttr-project: \(v)`, which this version cannot read."
		case .badValue(let key, let value):
			return "`\(key): \(value)` is not something cuttr understands."
		case .cannotAnimate(let parameter, let reason):
			return "`\(parameter)` cannot be animated: \(reason)"
		case .refused(let key, let value, let reason):
			return "`\(key): \(value)` is not something cuttr will do: \(reason)"
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

		// Scenes: parts, and the keys that move them.
		var scenes: [String: Scene] = [:]
		if let m = root.removeValue(forKey: "scenes").flatMap(mapping) {
			for (name, value) in m {
				guard let fields = mapping(value),
				      let parts = fields["parts"] as? [Any] else { continue }
				scenes[Slug.make(from: name)] = Scene(parts: try parts.map(readPart))
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
					out.append(try entryFromText(text, transition: .cut))
				} else if let m = mapping(entry) {
					let transition = try cutTransition(m["transition"])
					// A name for this placement, and how much of the clip to
					// leave off at each end — both about *this* use of it.
					let label = (m["as"] as? String).flatMap(nonEmpty).map(Slug.make(from:))
					var trim = (head: 0.0, tail: 0.0)
					if let pair = m["trim"] as? [Any], pair.count == 2 {
						trim = (try time(pair[0], key: "trim") ?? 0,
						        try time(pair[1], key: "trim") ?? 0)
					} else if let fields = mapping(m["trim"]) {
						trim = (try time(fields["head"], key: "trim") ?? 0,
						        try time(fields["tail"], key: "trim") ?? 0)
					}
					// What is drawn over this placement. Read by the same
					// function the top-level list uses, and kept even when it
					// says nothing about when it is on — here, that means "all
					// of this entry", which is the point of writing it here.
					let over = try list(m["overlays"]).compactMap(mapping).compactMap(readOverlay)
					let under = try list(m["sounds"]).compactMap(mapping).compactMap(readSound)
					if let group = (m["group"] as? String).flatMap(nonEmpty) {
						out.append(TimelineEntry(
							group: Slug.make(from: group),
							entries: try readEntries(m["clips"]),
							transition: transition, overlays: over, sounds: under))
					} else if let query = (m["query"] as? String).flatMap(nonEmpty) {
						out.append(try TimelineEntry(query: query, transition: transition,
						                             overlays: over, sounds: under))
					} else if let tag = (m["tag"] as? String).flatMap(nonEmpty) {
						// `tag:` is sugar for a one-term query, and the
						// commonest one — worth its own key so the simple case
						// reads simply.
						out.append(try TimelineEntry(query: "#\(tag)", transition: transition,
						                             overlays: over, sounds: under))
					} else if let seconds = try time(m["card"], key: "card") {
						// A length where a slug goes, because a card has no
						// slug: there is no take behind it to name.
						var card = Card(duration: max(0, seconds))
						if let said = fill(m["fill"]) { card.fill = said }
						out.append(TimelineEntry(card: card, transition: transition,
						                         label: label, overlays: over, sounds: under))
					} else if let clips = m["clips"] as? [Any] {
						out.append(TimelineEntry(
							list: clips.compactMap { ($0 as? String).map(ClipReference.init) },
							transition: transition, overlays: over, sounds: under))
					} else if let clip = (m["clip"] as? String).flatMap(nonEmpty) {
						out.append(TimelineEntry(
							clip: ClipReference(clip), transition: transition,
							label: label, trim: trim, overlays: over, sounds: under))
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
			guard let m = mapping(entry), let overlay = try readOverlay(m) else { continue }
			// An overlay at the top level with no range says nothing about when
			// it is on, and there is no placement here to ask.
			guard !overlay.appearances.isEmpty else { continue }
			overlays.append(overlay)
		}

		// Sound that is not from a take: music, an atmosphere, a sting. When it
		// plays is read by the same function an overlay's range is, because it
		// is the same question.
		var sounds: [Sound] = []
		for entry in list(root.removeValue(forKey: "sounds")) {
			guard let m = mapping(entry), let sound = try readSound(m) else { continue }
			// A sound in the top-level list has no placement to take its length
			// from, so one that does not say when it plays is not read.
			guard sound.span != nil else { continue }
			sounds.append(sound)
		}

		var project = Project(takes: takes, output: output, timeline: timeline,
		                      overlays: overlays, sounds: sounds, styles: styles,
		                      profiles: profiles, scenes: scenes, unknownKeys: root)
		// The two things the parse above cannot see: what somebody wrote in the
		// margins, and the order they wrote their named blocks in. Both are
		// facts about the text, so both are read from the text.
		let scan = FileScan(text, ignoring: ProjectWriter.generatedComments)
		project.comments = scan.comments
		// Slugged where the reader slugs the names themselves, or the order
		// would be a list of names the project no longer has.
		project.declaredOrder = [
			"styles": scan.order["styles"] ?? [],
			"scenes": (scan.order["scenes"] ?? []).map { Slug.make(from: $0) },
			"profiles": (scan.order["profiles"] ?? []).map { Slug.make(from: $0) },
		]
		return project
	}

	/// One rule for "what does this string mean", shared with the panel.
	/// How one entry arrives from the one before.
	///
	/// Three spellings, and the oldest still means what it always meant: a bare
	/// number is a dissolve of that many seconds. A bare name is that kind over
	/// its own sensible length. A mapping names the kind, its direction if it
	/// has one, and how long — `{wipe: left, over: 0.6}`, the same shape the
	/// overlays use for theirs.
	/// One overlay, read from the mapping that says it.
	///
	/// A function rather than a stretch of the reader, because there are two
	/// places an overlay can be written now and both have to understand exactly
	/// the same keys. A second implementation is a second dialect.
	///
	/// The appearances may come back empty: an overlay written inside a
	/// timeline entry and given no range covers that entry, and having nothing
	/// to say about when it is on is the honest way to say so. The top-level
	/// list has no placement to cover, so it drops those.
	static func readOverlay(_ m: [String: Any]) throws -> Overlay? {
		let kind: Overlay.Kind
		// Before `text:`, because a bubble's words are on `bubble:` and its
		// `text:` — if it has one — belongs to an appearance under `when:`.
		// A mapping with both at the top level is still a bubble: the key that
		// names the kind wins, as it does for every other kind here.
		if let said = m["bubble"] {
			var bubble = Bubble(text: spoken(said))
			if let named = (m["shape"] as? String).flatMap(nonEmpty) {
				guard let shape = Bubble.Shape(rawValue: named.lowercased()) else {
					throw ProjectError.badValue(key: "shape", value: named)
				}
				bubble.shape = shape
			}
			bubble.style = (m["style"] as? String).flatMap(nonEmpty)
			if let fill = (m["fill"] as? String).flatMap(RGBA.init(hex:)) { bubble.fill = fill }
			if let line = (m["line"] as? String).flatMap(RGBA.init(hex:)) { bubble.line = line }
			if let width = number(m["width"]) { bubble.width = width }
			if let seed = m["seed"] as? Int { bubble.seed = seed }
			// How much the line breathes: one is alive, nought is the still
			// drawing. Clamped rather than refused, because a negative amount of
			// liveliness is a typo and not a question.
			if let breath = number(m["breath"]) { bubble.breath = max(0, breath) }
			// Whether the paper travels with the anchor. It does unless somebody
			// says not to.
			if let follow = m["follow"] as? Bool { bubble.follow = follow }
			// Where the tail's tip goes, from the same origin as `offset:`. The
			// second of the two positions a bubble carries: `offset:` moves the
			// paper, this moves the tip.
			bubble.tail = try point(m["tail"], key: "tail") ?? .zero
			// A spot in the frame to point at, for the things that are not
			// faces — and for a programme with no footage in it at all.
			bubble.at = try point(m["at"], key: "at")
			kind = .bubble(bubble)
		} else if let text = m["text"] as? String {
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
		} else if let scene = (m["scene"] as? String).flatMap(nonEmpty) {
			var parameters: [String: String] = [:]
			if let given = mapping(m["with"]) {
				for (name, value) in given { parameters[name] = "\(value)" }
			}
			kind = .scene(scene, with: parameters)
		} else if let folder = (m["frames"] as? String).flatMap(nonEmpty) {
			// `fps:` is not optional, and that is the one strong opinion in this
			// branch. See ``Frames/framesPerSecond``.
			guard let rate = number(m["fps"]), rate > 0 else {
				throw ProjectError.refused(
					key: "frames", value: folder,
					reason: "a folder of pictures carries no frame rate of its own, so `fps:` "
						+ "has to say what it is. Guessing would show as the animation running "
						+ "at some fraction of the speed it was drawn at, which is the sort of "
						+ "wrongness nobody thinks to look for.")
			}
			var frames = Frames(folder: folder, framesPerSecond: rate)
			// Clamped rather than refused, like a bubble's `breath:`: a sequence
			// of no height is a typo and not a question.
			if let size = number(m["size"]) { frames.size = max(0.001, size) }
			if let said = m["ends"] {
				let text = ((said as? String).flatMap(nonEmpty) ?? describe(said)).lowercased()
				guard let ends = Frames.Ends(rawValue: text) else {
					// `stretch` by name, because it is the thing somebody will
					// reach for and the reason it is absent is not obvious. See
					// ``Frames/Ends``.
					guard text == "stretch" || text == "fit" else {
						throw ProjectError.badValue(key: "ends", value: text)
					}
					throw ProjectError.refused(
						key: "ends", value: text,
						reason: "fitting the sequence's own length to the span would re-time "
							+ "somebody else's animation from a fact about the cut, so trimming "
							+ "two frames off a shot would quietly change the speed of every "
							+ "chart on it. `hold` keeps the last picture up; `loop` starts "
							+ "again. If the length is wrong, render the frames again.")
				}
				frames.ends = ends
			}
			kind = .frames(frames)
		} else if let stock = (m["film"] as? String).flatMap(nonEmpty) {
			// `film: warm`, and the rest only if it is not the usual.
			var film = Film()
			film.tint = Film.Tint(rawValue: stock.lowercased()) ?? .warm
			if let ratio = (m["ratio"] as? String).flatMap(Film.Ratio.init) { film.ratio = ratio }
			else if let ratio = number(m["ratio"]) { film.ratio = Film.Ratio(ratio, 1) }
			if let strength = number(m["strength"]) { film.strength = strength }
			if let grain = number(m["grain"]) { film.grain = grain }
			if let vignette = number(m["vignette"]) { film.vignette = vignette }
			kind = .film(film)
		} else if let value = m["aberration"] {
			// `aberration: radial`, and `aberration: 0.6` for somebody who
			// means the amount and does not care which kind — which is the
			// commoner of the two things to mean.
			var aberration = Aberration()
			if let named = (value as? String).flatMap(nonEmpty) {
				if let kind = Aberration.Kind(rawValue: named.lowercased()) {
					aberration.kind = kind
				} else if let amount = Double(named) {
					aberration.amount = amount
				}
			} else if let amount = number(value) {
				aberration.amount = amount
			}
			if let amount = number(m["amount"]) { aberration.amount = amount }
			if let angle = number(m["angle"]) { aberration.angle = angle }
			kind = .aberration(aberration)
		} else if let condition = (m["tape"] as? String).flatMap(nonEmpty) {
			// `tape: worn`, and then only the knobs that are not what worn
			// means. The condition fills all five in, so a file that names
			// one is a file that has changed its mind about one.
			var tape = Tape(Tape.Condition(rawValue: condition.lowercased()) ?? .worn)
			if let jitter = number(m["jitter"]) { tape.jitter = jitter }
			if let band = number(m["band"]) { tape.band = band }
			if let chroma = number(m["chroma"]) { tape.chroma = chroma }
			if let scanlines = number(m["scanlines"]) { tape.scanlines = scanlines }
			if let dropouts = number(m["dropouts"]) { tape.dropouts = dropouts }
			if let seed = m["seed"] as? Int { tape.seed = seed }
			kind = .tape(tape)
		} else if let named = (m["effect"] as? String).flatMap(nonEmpty) {
			var effect = Effect(style: Effect.Style(rawValue: named.lowercased()) ?? .confetti)
			if let finish = (m["finish"] as? String).flatMap({ Effect.Finish(rawValue: $0) }) {
				effect.finish = finish
			}
			if let density = number(m["density"]) { effect.density = density }
			if let speed = number(m["speed"]) { effect.speed = speed }
			if let size = number(m["size"]) { effect.size = size }
			if let wind = number(m["wind"]) { effect.wind = wind }
			if let seed = m["seed"] as? Int { effect.seed = seed }
			if let palette = m["palette"] as? [Any] {
				effect.palette = palette.compactMap { ($0 as? String).flatMap(RGBA.init(hex:)) }
			}
			kind = .effect(effect)
		} else {
			return nil
		}

		// One range, or several under `when:`. The plural is a list of the
		// singular — the same three keys, in a list — so learning the one
		// teaches the other.

		// What an appearance says, when it says something of its own.
		func said(_ fields: [String: Any]) -> [SpinnerWord]? {
			guard let list = fields["words"] as? [Any] else { return nil }
			return list.compactMap { word in
				if let text = word as? String { return SpinnerWord(text) }
				if let inner = mapping(word), let text = inner["text"] as? String {
					return SpinnerWord(text, duration: number(inner["for"]))
				}
				return nil
			}
		}

		var appearances: [Overlay.Appearance] = []
		if let list = m["when"] as? [Any] {
			appearances = list.compactMap { entry in
				guard let fields = mapping(entry), let span = span(fields) else { return nil }
				return Overlay.Appearance(
					span, text: (fields["text"] as? String).flatMap(nonEmpty),
					words: said(fields))
			}
		} else if let span = span(m) {
			appearances = [Overlay.Appearance(span)]
		}

		// A bubble that says nothing about where it sits stands off from what it
		// points at, rather than being drawn over the face it is about. Filled
		// in here rather than at render time so that the file, once saved, says
		// where the bubble is: the offset is the number somebody will nudge.
		var offset = try point(m["offset"], key: "offset") ?? .zero
		if case .bubble = kind, m["offset"] == nil { offset = Bubble.standoff }

		let arrival = try transition(m["in"], key: "in") ?? kind.arrives
		let departure = try transition(m["out"], key: "out") ?? kind.departs
		return Overlay(
			kind: kind,
			appearances: appearances,
			arrival: arrival,
			departure: departure,
			arrivalPlacement: try placement(m["in"], key: "in", of: arrival, default: .after),
			departurePlacement: try placement(m["out"], key: "out", of: departure, default: .before),
			behind: (m["behind"] as? String).flatMap { Overlay.Occlusion(rawValue: $0) } ?? .nothing,
			anchor: (m["anchor"] as? String).flatMap(nonEmpty),
			offset: offset,
			keys: try overlayKeys(m["keys"], of: kind)
		)
	}

	/// What a `bubble:` says, however it was written.
	///
	/// Nearly always a string. A bubble whose words are a bare number — a
	/// caption reading `1970`, which is the sort of thing a family film is full
	/// of — comes through YAML as an `Int`, and refusing it would be refusing
	/// something perfectly sensible.
	private static func spoken(_ value: Any) -> String {
		if let text = value as? String { return text }
		if value is NSNull { return "" }
		return "\(value)"
	}

	/// One sound, read from the mapping that says it.
	///
	/// The same reason ``readOverlay(_:)`` is a function: there are two places
	/// a sound can be written and both have to understand the same keys.
	static func readSound(_ m: [String: Any]) throws -> Sound? {
		guard let file = (m["file"] as? String).flatMap(nonEmpty) else { return nil }
		// A `when:` list is read as its first range. A second stretch of the
		// same music is a second entry under `sounds:` — a lane is a lane,
		// and repeating four lines is cheaper than a grammar that hides how
		// many of them there are.
		let where_ = span(m) ?? (m["when"] as? [Any])?.compactMap(mapping).compactMap(span).first
		return Sound(
			file: file,
			span: where_,
			gain: number(m["gain"]) ?? 0,
			arrival: try fade(m["in"], key: "in"),
			departure: try fade(m["out"], key: "out"),
			ducks: number(m["ducks"]) ?? 0)
	}

	private static func cutTransition(_ value: Any?) throws -> Transition {
		guard let value else { return .cut }
		// A number, or a timecode: the oldest spelling, and a dissolve.
		if let seconds = (try? time(value, key: "transition")) ?? nil {
			return seconds > 0 ? .dissolve(over: seconds) : .cut
		}
		if let text = value as? String {
			guard let kind = Transition.Kind(written: text) else {
				throw ProjectError.badValue(key: "transition", value: text)
			}
			return Transition(kind, seconds: defaultLength(kind))
		}
		guard let m = mapping(value) else {
			throw ProjectError.badValue(key: "transition", value: "\(value)")
		}
		for kind in Transition.Kind.allCases where kind != .cut {
			guard let said = m[kind.written] ?? m[kind.rawValue] else { continue }
			let edge = (said as? String).flatMap(Transition.Edge.init(rawValue:))
			let over = try time(m["over"], key: "transition") ?? defaultLength(kind)
			return Transition(kind, seconds: over, edge: edge ?? .left)
		}
		// `{over: 0.5}` with no kind named is the kind everybody means.
		if let over = try time(m["over"], key: "transition") {
			return .dissolve(over: over)
		}
		return .cut
	}

	/// How long one of these runs when nobody says.
	///
	/// Different per kind because they are not the same length of thing: a dip
	/// through black has to sit on the black for a moment to read as one, and a
	/// flash that lasts half a second is not a flash.
	private static func defaultLength(_ kind: Transition.Kind) -> Double {
		switch kind {
		case .cut: return 0
		case .flash: return 0.25
		case .dipToBlack, .dipToWhite: return 1
		case .iris, .wipe, .push, .slide: return 0.6
		default: return 0.5
		}
	}

	private static func entryFromText(_ text: String, transition: Transition) throws -> TimelineEntry {
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
	/// One part of a scene: what it is, and where it is at each of its keys.
	///
	/// Refused rather than dropped when it cannot be read, and that is the
	/// whole of this function's history. A part whose `background:` was written
	/// as a list of two colours rather than as `{from:, to:}` used to be
	/// skipped in silence: the scene then rendered without its ground, which on
	/// a black card is a black frame, and nothing anywhere said why. Measured
	/// on a rendered file — thirty-eight of forty pixels at `#000000` — and the
	/// answer was a line the reader had quietly thrown away.
	///
	/// So a part that names none of the kinds, or names one it cannot read, or
	/// has no keys to appear at, is an error with the offending line in it.
	/// That is the rule everywhere else in this format and there is no reason a
	/// scene should be the exception.
	/// The keys an overlay's parameters move on — and a refusal, by name, for
	/// anything they ask for that cannot be honoured.
	///
	/// The precedent is ``readPart(_:)``: a scene part the reader cannot
	/// understand is an error with the offending line in it rather than a line
	/// quietly dropped. An animation is the worse of the two to drop, because a
	/// part that vanishes leaves a hole somebody can see and a key that vanishes
	/// leaves an effect that simply sits still — which looks exactly like an
	/// effect nobody animated.
	///
	/// What is refused and why is written out in ``Overlay/Kind/animatable``.
	/// This function only says it out loud.
	private static func overlayKeys(_ value: Any?, of kind: Overlay.Kind) throws -> [Overlay.Key] {
		guard let value else { return [] }
		guard let entries = value as? [Any] else {
			throw ProjectError.badValue(key: "keys", value: describe(value))
		}
		let allowed = kind.animatable
		guard !allowed.isEmpty else {
			throw ProjectError.cannotAnimate(
				parameter: "keys",
				reason: "\(kind.named) has nothing that moves. A caption, a spinner and "
					+ "a bubble arrive and leave by `in:` and `out:`, a scene's parts "
					+ "carry keys of their own, a bubble's tail is moved by the face "
					+ "it points at, and what a frame sequence does over time is the "
					+ "frames.")
		}
		var keys: [Overlay.Key] = []
		for entry in entries {
			guard let fields = mapping(entry) else {
				throw ProjectError.badValue(key: "keys", value: describe(entry))
			}
			var key = Overlay.Key(t: number(fields["t"]) ?? 0)
			if let named = fields["ease"] {
				guard let ease = (named as? String).flatMap(Scene.Ease.init(rawValue:)) else {
					throw ProjectError.badValue(key: "ease", value: describe(named))
				}
				key.ease = ease
			}
			for (name, written) in fields where name != "t" && name != "ease" {
				guard let parameter = Overlay.Parameter(rawValue: name),
				      allowed.contains(parameter) else {
					throw ProjectError.cannotAnimate(
						parameter: name, reason: cannotAnimate(name, of: kind, allowed: allowed))
				}
				guard let amount = animated(written, parameter) else {
					throw ProjectError.badValue(key: name, value: describe(written))
				}
				key[parameter] = amount
			}
			keys.append(key)
		}
		// Left in the order they were written. They are sorted wherever they are
		// used, and a reader that reorders somebody's file is a reader that makes
		// a diff out of opening it.
		return keys
	}

	/// Why a key cannot have what it asked for, in a sentence.
	private static func cannotAnimate(
		_ name: String, of kind: Overlay.Kind, allowed: [Overlay.Parameter]
	) -> String {
		let list = allowed.map(\.rawValue).joined(separator: ", ")
		switch name {
		case "seed":
			return "the same number gives the same cloud, every render, on every "
				+ "machine, and that is the whole of what a seed is for. One that "
				+ "changed half way through would not be a cloud moving but two "
				+ "clouds cut together. What can move here is \(list)."
		case "film", "tint", "stock", "finish", "style", "palette", "condition",
		     "tape", "aberration", "effect", "kind", "color", "colour":
			return "it is a name rather than a number, and there is nothing half way "
				+ "between two of them. Cross-fade a second overlay over this one "
				+ "instead. What can move here is \(list)."
		default:
			return "\(kind.named) has no such parameter. What can move here is \(list)."
		}
	}

	/// A key's value for one parameter. Numbers, everywhere except the shape a
	/// film overlay closes to — which a key states as the single quantity that
	/// can move, though `w:h` is still read because that is how the overlay
	/// above it writes the same thing.
	private static func animated(_ value: Any, _ parameter: Overlay.Parameter) -> Double? {
		if parameter == .ratio, let text = (value as? String).flatMap(nonEmpty) {
			return Film.Ratio(text)?.value
		}
		return number(value)
	}

	private static func readPart(_ value: Any) throws -> Scene.Part {
		guard let fields = mapping(value) else {
			throw ProjectError.badValue(key: "parts", value: describe(value))
		}
		let content: Scene.Part.Content
		if let text = fields["text"] as? String {
			content = .text(text, style: (fields["style"] as? String).flatMap(nonEmpty),
			                tracking: number(fields["tracking"]) ?? 0)
		} else if let shape = fields["shape"] {
			guard let fill = (shape as? String).flatMap(RGBA.init(hex:)) else {
				throw ProjectError.badValue(key: "shape", value: describe(shape))
			}
			var kind = Scene.ShapeKind.rectangle
			if let named = fields["kind"] {
				guard let read = (named as? String).flatMap(Scene.ShapeKind.init(rawValue:)) else {
					throw ProjectError.badValue(key: "kind", value: describe(named))
				}
				kind = read
			}
			content = .shape(fill: fill, corner: number(fields["corner"]) ?? 0, kind: kind)
		} else if let value = fields["bar"] {
			guard let fill = (value as? String).flatMap(RGBA.init(hex:)) else {
				throw ProjectError.badValue(key: "bar", value: describe(value))
			}
			var direction = Scene.Bar.Direction.right
			if let named = fields["direction"] {
				guard let read = (named as? String)
					.flatMap(Scene.Bar.Direction.init(rawValue:)) else {
					throw ProjectError.badValue(key: "direction", value: describe(named))
				}
				direction = read
			}
			var track = RGBA(r: 1, g: 1, b: 1, a: 0.2)
			if let named = fields["track"] as? String {
				// `none` for a bar with no groove behind it, the same word the
				// styles use for a caption with no plate.
				track = named == "none" ? RGBA(r: 0, g: 0, b: 0, a: 0) : (RGBA(hex: named) ?? track)
			}
			content = .bar(Scene.Bar(fill: fill, track: track,
			                         corner: number(fields["corner"]) ?? 0,
			                         direction: direction))
		} else if let value = fields["spinner"] {
			guard let style = (value as? String).flatMap(Spinner.Style.init(rawValue:)) else {
				throw ProjectError.badValue(key: "spinner", value: describe(value))
			}
			content = .spinner(Spinner(
				style: style,
				size: number(fields["size"]) ?? 0.09,
				speed: number(fields["speed"]) ?? 1,
				color: (fields["color"] as? String).flatMap(RGBA.init(hex:)) ?? .white))
		} else if let entries = fields["roll"] {
			content = .roll(try readRoll(entries, fields))
		} else if let image = fields["image"] {
			guard let file = (image as? String).flatMap(nonEmpty) else {
				throw ProjectError.badValue(key: "image", value: describe(image))
			}
			content = .image(file)
		} else if let value = fields["frames"] {
			guard let pattern = (value as? String).flatMap(nonEmpty) else {
				throw ProjectError.badValue(key: "frames", value: describe(value))
			}
			// The rate is required rather than taken from the output. A sequence
			// somebody rendered at 25 and dropped into a 50 fps project would
			// otherwise play at double speed and read as a mistake in the
			// animation, which is a bad half hour.
			guard let fps = number(fields["fps"]), fps > 0 else {
				throw ProjectError.badValue(key: "fps", value: describe(fields["fps"] ?? "none"))
			}
			content = .frames(FrameSequence(pattern: pattern, fps: fps))
		} else if let value = fields["component"] {
			guard let file = (value as? String).flatMap(nonEmpty) else {
				throw ProjectError.badValue(key: "component", value: describe(value))
			}
			// Likewise required: how long a component draws for is the one thing
			// it is not allowed to decide for itself, and a default would be a
			// number nobody chose deciding how many frames get baked.
			guard let duration = number(fields["duration"]), duration > 0 else {
				throw ProjectError.badValue(key: "duration",
				                            value: describe(fields["duration"] ?? "none"))
			}
			var props: [String: String] = [:]
			if let given = fields["props"] {
				guard let mapped = mapping(given) else {
					throw ProjectError.badValue(key: "props", value: describe(given))
				}
				// Strings, however they were written, the same way a scene's
				// `with:` reads its parameters — so `year: 2025` and
				// `year: "2025"` are one prop and one bake, not two.
				for (name, value) in mapped { props[name] = "\(value)" }
			}
			content = .component(Component(file: file, duration: duration, props: props))
		} else if let background = fields["background"] {
			guard let read = readBackground(background) else {
				throw ProjectError.badValue(key: "background", value: describe(background))
			}
			content = .background(read)
		} else {
			throw ProjectError.badValue(
				key: "parts", value: fields.keys.sorted().joined(separator: ", "))
		}

		let keys = (fields["keys"] as? [Any] ?? []).compactMap { entry -> Scene.Key? in
			guard let key = mapping(entry) else { return nil }
			return Scene.Key(
				t: number(key["t"]) ?? 0,
				x: number(key["x"]), y: number(key["y"]),
				opacity: number(key["opacity"]), scale: number(key["scale"]),
				rotation: number(key["rotation"]),
				width: number(key["width"]), height: number(key["height"]),
				progress: number(key["progress"]),
				shape: (key["shape"] as? String).flatMap(Scene.ShapeKind.init(rawValue:)),
				color: (key["color"] as? String).flatMap(RGBA.init(hex:)),
				// A background's ramp, stated at a key: the far stop and the
				// direction, beside the `color` that is the near stop.
				to: (key["to"] as? String).flatMap(RGBA.init(hex:)),
				angle: number(key["angle"]),
				ease: (key["ease"] as? String).flatMap(Scene.Ease.init(rawValue:)) ?? .inOut)
		}
		guard !keys.isEmpty else {
			// A part with no keys is a part that is never anywhere, so it can
			// never be drawn. Said out loud, because it looks like a part.
			throw ProjectError.badValue(key: "keys", value: "none")
		}
		return Scene.Part(content: content, keys: keys)
	}

	/// A credit roll: the blocks, and how the column is set.
	///
	/// `roll:` is the list of blocks, because the blocks are the thing; the
	/// typography sits beside it under the part, exactly as a text part's
	/// `style:` and `tracking:` do.
	///
	/// A block that names no role is read, and so is one that names no names —
	/// a heading with nothing under it yet is a roll being written. A block that
	/// is neither is not a block, and it is dropped rather than refused: `roll:`
	/// with a stray blank list item in it is a file somebody is in the middle of
	/// typing, not a file that is wrong.
	private static func readRoll(_ entries: Any, _ fields: [String: Any]) throws -> Scene.Roll {
		var read: [Scene.Roll.Entry] = []
		for entry in list(entries) {
			// One name and nothing else is the commonest block there is, and
			// `- Camera: Wren Halloway` is not it — a mapping of one pair would
			// have to guess which half is which. `{role: …, names: …}` always.
			guard let m = mapping(entry) else {
				throw ProjectError.badValue(key: "roll", value: describe(entry))
			}
			let role = (m["role"] as? String).flatMap(nonEmpty) ?? ""
			// A list, or one name written bare — which is what somebody types
			// for `{role: Music, names: Otto Kestrel}`.
			let names = stringList(m["names"]).compactMap(nonEmpty)
			guard !role.isEmpty || !names.isEmpty else { continue }
			var source: Scene.Roll.Source?
			if let said = m["from"] {
				guard let known = (said as? String).flatMap(Scene.Roll.Source.init(rawValue:)) else {
					throw ProjectError.badValue(key: "from", value: describe(said))
				}
				source = known
			}
			read.append(Scene.Roll.Entry(role: role, names: names, source: source))
		}
		var align = Scene.Roll.Align.columns
		if let named = fields["align"] {
			// `center` too, because the styles read both spellings and a format
			// that accepts one word here and two there is a format that catches
			// somebody out.
			let text = (named as? String).map { $0 == "center" ? "centre" : $0 }
			guard let read = text.flatMap(Scene.Roll.Align.init(rawValue:)) else {
				throw ProjectError.badValue(key: "align", value: describe(named))
			}
			align = read
		}
		let plain = Scene.Roll()
		return Scene.Roll(
			entries: read,
			title: (fields["title"] as? String).flatMap(nonEmpty),
			style: (fields["style"] as? String).flatMap(nonEmpty),
			roleStyle: (fields["role-style"] as? String).flatMap(nonEmpty),
			titleStyle: (fields["title-style"] as? String).flatMap(nonEmpty),
			line: number(fields["line"]) ?? plain.line,
			gap: number(fields["gap"]) ?? plain.gap,
			column: number(fields["column"]) ?? plain.column,
			align: align,
			tracking: number(fields["tracking"]) ?? 0,
			tilt: number(fields["tilt"]) ?? 0)
	}

	/// A value from the file, as near to the way it was written as matters for
	/// an error message.
	private static func describe(_ value: Any) -> String {
		if let text = value as? String { return text }
		if let list = value as? [Any] {
			return "[" + list.map(describe).joined(separator: ", ") + "]"
		}
		if let m = mapping(value) {
			return "{" + m.keys.sorted().joined(separator: ", ") + "}"
		}
		return String(describing: value)
	}

	/// `background: "#101418"`, or `background: {from: …, to: …, angle: 90}`.
	///
	/// One colour is the common case and stays one word. Anything else — a list
	/// of two colours, a `to` with no `from` — comes back `nil` and the caller
	/// refuses the part by name. Losing it quietly was the bug.
	private static func readBackground(_ value: Any) -> Scene.Background? {
		if let hex = (value as? String).flatMap(RGBA.init(hex:)) {
			return Scene.Background(from: hex)
		}
		guard let fields = mapping(value),
		      let from = (fields["from"] as? String).flatMap(RGBA.init(hex:))
		else { return nil }
		return Scene.Background(
			from: from,
			to: (fields["to"] as? String).flatMap(RGBA.init(hex:)),
			angle: number(fields["angle"]) ?? 90)
	}

	private static func transition(_ value: Any?, key: String) throws -> Overlay.Transition? {
		guard let value else { return nil }
		if let text = value as? String {
			switch text.lowercased() {
			case "cut", "none": return .cut
			case "fade": return .fade(over: 0.4)
			case "fall": return .fall(over: 1.5)
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
		// `{fade: false}` is somebody saying *no* fade, and it used to read as a
		// fade of the default length — the value was noticed and never looked
		// at. `{fade: 0}` says the same thing with a number.
		if let asked = m["fade"] {
			if let wanted = asked as? Bool { return wanted ? .fade(over: number(m["over"]) ?? 0.4) : .cut }
			if let seconds = number(asked) { return seconds > 0 ? .fade(over: seconds) : .cut }
			return .fade(over: over)
		}
		// A shower that runs out rather than one somebody switched off.
		if m["fall"] != nil { return .fall(over: number(m["over"]) ?? 1.5) }
		return .cut
	}

	/// Where the movement sits against the mark: `in: {fade: true, over: 0.4,
	/// at: before}`.
	///
	/// Three short keys, one question each — `in:` says how, `over:` says how
	/// long, `at:` says where — and the three words read against the mark, so
	/// the same one means the same thing at either end. See
	/// ``Overlay/Transition/Placement``.
	///
	/// Nothing to place on a cut, which has no length, so `at:` on one is read
	/// and dropped rather than kept as a value that could never be seen. That
	/// also keeps the file it writes back the file it would have written: a cut
	/// is spelt `cut`, and always was.
	private static func placement(
		_ value: Any?, key: String, of transition: Overlay.Transition,
		default fallback: Overlay.Transition.Placement
	) throws -> Overlay.Transition.Placement {
		guard transition.duration > 0, let m = mapping(value), let said = m["at"] else {
			return fallback
		}
		guard let text = said as? String,
		      let placement = Overlay.Transition.Placement(rawValue: text.lowercased())
		else { throw ProjectError.badValue(key: "\(key).at", value: describe(said)) }
		return placement
	}

	/// When something is on: `within:` a clip, over a `group:`, between two
	/// marks, or between two times.
	///
	/// One function, because overlays and sounds ask the same question and the
	/// answer has to mean the same thing. A second grammar for "when does this
	/// happen" would be a second thing to learn and a second thing to get
	/// wrong.
	static func span(_ fields: [String: Any]) -> Overlay.Span? {
		// A stretch of one clip, timed from where that clip starts —
		// which is what makes it survive the clip being moved.
		if let mark = (fields["within"] as? String).flatMap(nonEmpty) {
			let from = (fields["from"] as? String).flatMap(Timecode.parse)
				?? (try? time(fields["from"], key: "from")) as? Double ?? 0
			let to = (fields["to"] as? String).flatMap(Timecode.parse)
				?? (try? time(fields["to"], key: "to")) as? Double ?? 0
			return .within(.init(mark), from: from, to: max(from, to))
		}
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

	/// How a sound starts or stops.
	///
	/// Only a fade means anything to a sound — it cannot slide in from the left
	/// — so this reads the fade spellings and nothing else: `{fade: true, over:
	/// 0.5}`, a bare number of seconds, the word `fade`, and nothing at all for
	/// a hard start.
	private static func fade(_ value: Any?, key: String) throws -> Overlay.Transition {
		guard let value else { return .cut }
		// The mapping first, because a mapping is not a time and asking for one
		// throws rather than falling through.
		if let m = mapping(value) {
			// `{fade: false}` means no fade, the same as it does for an overlay.
			if let wanted = m["fade"] as? Bool, !wanted { return .cut }
			guard m["fade"] != nil || m["over"] != nil else { return .cut }
			return .fade(over: number(m["over"]) ?? number(m["fade"]) ?? 0.5)
		}
		if let text = value as? String {
			switch text.lowercased() {
			case "fade": return .fade(over: 0.5)
			case "cut", "none": return .cut
			default: break   // a number or a timecode, or an error from `time`
			}
		}
		guard let seconds = try time(value, key: key) else { return .cut }
		return seconds > 0 ? .fade(over: seconds) : .cut
	}

	/// What a card is made of: one colour, or two read down the page.
	///
	/// `fill: "#101014"` and `fill: ["#202030", "#050508"]`, top first — which
	/// is the order somebody looking at the card would name them in.
	private static func fill(_ value: Any?) -> Card.Fill? {
		if let text = (value as? String).flatMap(RGBA.init(hex:)) { return .solid(text) }
		if let pair = value as? [Any], pair.count == 2,
		   let top = (pair[0] as? String).flatMap(RGBA.init(hex:)),
		   let bottom = (pair[1] as? String).flatMap(RGBA.init(hex:)) {
			return .gradient(top: top, bottom: bottom)
		}
		return nil
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
