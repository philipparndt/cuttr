import CuttrKit
import Foundation
import Yams

/// Writing a project back to text.
///
/// Hand-written for the same reason ``CuttrKit/TakeWriter`` is: this file is
/// meant to be opened in an editor and changed, and a general emitter would
/// reorder keys and reflow lines on every save, so a one-word edit would arrive
/// as a rewritten file. Fixed order, aligned columns, one blank line between
/// entries, quoting only where a bare value would be read as something else.
public enum ProjectWriter {

	/// The scenes a project defines: parts, and the keys that move them.
	///
	/// Written in the order the parts are in, and each key on one line, because
	/// a keyframe is a row of numbers and a row of numbers belongs on a line.
	private static func scenes(_ scenes: [String: Scene]) -> String {
		guard !scenes.isEmpty else { return "" }
		var out = "\nscenes:\n"
		for name in scenes.keys.sorted() {
			guard let scene = scenes[name] else { continue }
			out += "  \(name):\n"
			out += "    parts:\n"
			for part in scene.parts {
				switch part.content {
				case .text(let text, let style):
					out += "      - text:  \(scalar(text))\n"
					if let style { out += "        style: \(scalar(style))\n" }
				case .shape(let fill, let corner):
					out += "      - shape: \(scalar(fill.hex))\n"
					if corner != 0 { out += "        corner: \(trim(corner))\n" }
				case .image(let file):
					out += "      - image: \(scalar(file))\n"
				}
				out += "        keys:\n"
				for key in part.keys {
					var fields = ["t: \(trim(key.t))"]
					if let x = key.x { fields.append("x: \(trim(x))") }
					if let y = key.y { fields.append("y: \(trim(y))") }
					if let opacity = key.opacity { fields.append("opacity: \(trim(opacity))") }
					if let scale = key.scale { fields.append("scale: \(trim(scale))") }
					if let rotation = key.rotation { fields.append("rotation: \(trim(rotation))") }
					if let width = key.width { fields.append("width: \(trim(width))") }
					if let height = key.height { fields.append("height: \(trim(height))") }
					if key.ease != .inOut { fields.append("ease: \(key.ease.rawValue)") }
					out += "          - {" + fields.joined(separator: ", ") + "}\n"
				}
			}
		}
		return out
	}

	public static func write(_ project: Project) -> String {
		var out = "# cuttr project — the assembly. Clips are referenced by slug.\n"
		out += "cuttr-project: \(ProjectReader.formatVersion)\n\n"

		if !project.takes.isEmpty {
			out += "takes:\n"
			for take in project.takes { out += "  - \(scalar(take))\n" }
			out += "\n"
		}

		out += "output:\n"
		out += "  size: \(project.output.width)x\(project.output.height)\n"
		out += "  fps:  \(trim(project.output.framesPerSecond))\n"
		if let file = project.output.file { out += "  file: \(scalar(file))\n" }
		if let audio = project.output.audio {
			out += "  audio: {target: \(trim(audio.target)), ceiling: \(trim(audio.ceiling))}"
			out += "   # LUFS, dBFS\n"
		}
		if let reference = project.output.matchReference {
			out += "  match: {reference: \(scalar(reference))}\n"
		}
		out += "\n"

		if !project.profiles.isEmpty {
			out += "profiles:\n"
			for name in project.profiles.keys.sorted() {
				let look = project.profiles[name]!
				out += "  \(scalar(name)):\n"
				if look.exposure != 0 { out += "    exposure:    \(trim(look.exposure))\n" }
				if look.temperature != 0 { out += "    temperature: \(trim(look.temperature))\n" }
				if look.tint != 0 { out += "    tint:        \(trim(look.tint))\n" }
				if look.saturation != 1 { out += "    saturation:  \(trim(look.saturation))\n" }
				if look.contrast != 1 { out += "    contrast:    \(trim(look.contrast))\n" }
			}
			out += "\n"
		}

		if !project.styles.isEmpty {
			out += "styles:\n"
			for name in project.styles.keys.sorted() {
				let style = project.styles[name]!
				out += "  \(scalar(name)):\n"
				out += "    font:     \(scalar(style.font))\n"
				out += "    size:     \(trim(style.size))\n"
				out += "    color:    \(scalar(style.color.hex))\n"
				out += "    background: \(style.background.a == 0 ? "none" : scalar(style.background.hex))\n"
				out += "    padding:  \(trim(style.padding))\n"
				out += "    radius:   \(trim(style.cornerRadius))\n"
				out += "    position: [\(trim(style.position.x)), \(trim(style.position.y))]\n"
				out += "    align:    \(style.alignment.rawValue)\n"
			}
			out += "\n"
		}

		out += "timeline:\n"
		if project.timeline.isEmpty {
			out += "  # nothing yet — add clips by slug:\n"
			out += "  # - take-01/intro\n"
		}
		out += entries(project.timeline, indent: "  ")

		if !project.overlays.isEmpty {
			out += "\noverlays:\n"
			out += overlays(project.overlays)
		}

		if !project.sounds.isEmpty {
			out += "\nsounds:\n"
			out += sounds(project.sounds)
		}

		out += scenes(project.scenes)

		if !project.unknownKeys.isEmpty {
			out += "\n"
			for key in project.unknownKeys.keys.sorted() {
				out += (try? Yams.dump(object: [key: project.unknownKeys[key]!])) ?? ""
			}
		}
		return out
	}

	// MARK: - Fragments, for showing somebody what they just wrote
	//
	// The same functions the file is written with, called on one piece. That is
	// the point: a panel that teaches the format by showing a *rendering* of it
	// teaches a format that does not exist. These are the bytes that will be on
	// disk.

	public static func fragment(for entry: TimelineEntry) -> String {
		"timeline:\n" + entries([entry], indent: "  ")
	}

	public static func fragment(for overlay: Overlay) -> String {
		"overlays:\n" + overlays([overlay])
	}

	public static func fragment(for sound: Sound) -> String {
		"sounds:\n" + sounds([sound])
	}

	public static func fragment(for output: Output) -> String {
		var out = "output:\n"
		out += "  size: \(output.width)x\(output.height)\n"
		out += "  fps:  \(trim(output.framesPerSecond))\n"
		if let file = output.file { out += "  file: \(scalar(file))\n" }
		if let audio = output.audio {
			out += "  audio: {target: \(trim(audio.target)), ceiling: \(trim(audio.ceiling))}"
			out += "   # LUFS, dBFS\n"
		}
		if let reference = output.matchReference {
			out += "  match: {reference: \(scalar(reference))}\n"
		}
		return out
	}

	/// The timeline, which nests: a group's clips are entries like any other.
	private static func entries(_ list: [TimelineEntry], indent: String) -> String {
		var out = ""
		for entry in list {
			switch entry.source {
			case .group(let name, let inner):
				out += "\(indent)- group: \(scalar(name))\n"
				out += "\(indent)  clips:\n"
				out += entries(inner, indent: indent + "    ")
				if entry.transition.duration > 0 {
					out += "\(indent)  transition: \(transition(entry.transition))\n"
				}
			case .list(let references):
				out += "\(indent)- clips: [\(references.map(\.description).joined(separator: ", "))]\n"
				if entry.transition.duration > 0 {
					out += "\(indent)  transition: \(transition(entry.transition))\n"
				}
			case .card(let card):
				out += cardEntry(card, entry.transition, indent, label: entry.label)
			case .clip(let reference):
				out += scalarEntry("clip", reference.description, entry.transition, indent,
				                   label: entry.label, ends: entry.trim)
			case .query(_, let source):
				out += scalarEntry("query", source, entry.transition, indent)
			}
		}
		return out
	}

	/// A card: a length where a slug would be, and a colour only when it is not
	/// black.
	///
	/// Its own writer rather than ``scalarEntry``'s, because a card has a
	/// second key of its own and the column its values line up in is the width
	/// of the widest key the entry actually has — `card:` on its own, and
	/// `transition:` when there is one.
	private static func cardEntry(
		_ card: Card, _ how: Transition, _ indent: String, label: String?
	) -> String {
		let column = how.duration > 0 ? 12 : 7
		func key(_ name: String) -> String {
			(name + ":").padding(toLength: column, withPad: " ", startingAt: 0)
		}
		var out = "\(indent)- \(key("card"))\(Timecode.string(card.duration))\n"
		// Black is what a card is when nobody says, so a black card says
		// nothing — the commonest one is one line.
		if card.fill != Card.black {
			out += "\(indent)  \(key("fill"))\(fill(card.fill))\n"
		}
		if let label { out += "\(indent)  \(key("as"))\(scalar(label))\n" }
		if how.duration > 0 { out += "\(indent)  \(key("transition"))\(transition(how))\n" }
		return out
	}

	/// One colour, or two read down the page.
	private static func fill(_ value: Card.Fill) -> String {
		switch value {
		case .solid(let colour):
			return scalar(colour.hex)
		case .gradient(let top, let bottom):
			return "[\(scalar(top.hex)), \(scalar(bottom.hex))]"
		}
	}

	private static func scalarEntry(
		_ key: String, _ value: String, _ how: Transition, _ indent: String,
		label: String? = nil, ends: (head: Double, tail: Double) = (0, 0)
	) -> String {
		// The short form for a straight cut of the whole clip, which is nearly
		// all of them.
		if how.duration == 0, label == nil, ends == (0, 0) {
			return "\(indent)- \(key): \(scalar(value))\n"
		}
		if how.duration == 0 {
			var out = "\(indent)- \(key): \(scalar(value))\n"
			if let label { out += "\(indent)  as:   \(scalar(label))\n" }
			if ends != (0, 0) {
				out += "\(indent)  trim: [\(Timecode.string(ends.head)), \(Timecode.string(ends.tail))]\n"
			}
			return out
		}
		var out = "\(indent)- \(key):       \(scalar(value))\n"
		if let label { out += "\(indent)  as:         \(scalar(label))\n" }
		if ends != (0, 0) {
			out += "\(indent)  trim:       "
				+ "[\(Timecode.string(ends.head)), \(Timecode.string(ends.tail))]\n"
		}
		out += "\(indent)  transition: \(transition(how))\n"
		return out
	}

	/// A dissolve is still a bare number.
	///
	/// It is what the format has always written and what most transitions are,
	/// so a project full of dissolves comes out of a newer version of this
	/// program byte for byte as it went into an older one. Everything else says
	/// which kind it is, and the directional ones say which way.
	private static func transition(_ value: Transition) -> String {
		switch value.kind {
		case .cut: return "0"
		case .dissolve: return trim(value.seconds)
		default:
			let what = value.kind.directional ? value.edge.rawValue : "true"
			return "{\(value.kind.written): \(what), over: \(trim(value.seconds))}"
		}
	}

	/// What a spinner says at one appearance, in the flow form the `when:` list
	/// uses.
	private static func words(_ words: [SpinnerWord]) -> String {
		"[" + words.map { word in
			word.duration.map { "{text: \(scalar(word.text)), for: \(trim($0))}" }
				?? scalar(word.text)
		}.joined(separator: ", ") + "]"
	}

	/// When an overlay or a sound is on, as the file says it.
	///
	/// `column` is where the values line up, which differs between the two only
	/// because the widest key differs: an overlay's block has `spinner:` and a
	/// sound's has `ducks:`.
	private static func range(_ span: Overlay.Span, indent: String, column: Int = 8) -> String {
		func key(_ name: String) -> String {
			indent + (name + ":").padding(toLength: column, withPad: " ", startingAt: 0)
		}
		switch span {
		case .within(let mark, let from, let to):
			return "\(key("within"))\(scalar(mark.description))\n"
				+ "\(key("from"))\(Timecode.string(from))\n"
				+ "\(key("to"))\(Timecode.string(to))\n"
		case .marks(let from, let to):
			var out = "\(key("from"))\(scalar(from.description))\n"
			if to != from { out += "\(key("to"))\(scalar(to.description))\n" }
			return out
		case .times(let from, let to):
			return "\(key("from"))\(Timecode.string(from))\n"
				+ "\(key("to"))\(Timecode.string(to))\n"
		}
	}

	/// The sounds laid under the programme.
	///
	/// The same shape as an overlay and for the same reason: what a thing is on
	/// the first line, when it is on under that, and how it arrives and leaves
	/// at the bottom. Anything that is what a sound is without it — no gain, no
	/// fades, no ducking — is left out.
	private static func sounds(_ list: [Sound]) -> String {
		var out = ""
		for (index, sound) in list.enumerated() {
			if index > 0 { out += "\n" }
			out += "  - file:  \(scalar(sound.file))\n"
			out += range(sound.span, indent: "    ", column: 7)
			if sound.gain != 0 { out += "    gain:  \(trim(sound.gain))\n" }
			if case .fade(let over) = sound.arrival {
				out += "    in:    {fade: true, over: \(trim(over))}\n"
			}
			if case .fade(let over) = sound.departure {
				out += "    out:   {fade: true, over: \(trim(over))}\n"
			}
			if sound.ducks != 0 {
				out += "    ducks: \(trim(sound.ducks))   # dB off the programme's own sound\n"
			}
		}
		return out
	}

	private static func overlays(_ list: [Overlay]) -> String {
		var out = ""
		for (index, overlay) in list.enumerated() {
				if index > 0 { out += "\n" }
				switch overlay.kind {
				case .text(let text, let style):
					out += "  - text:   \(scalar(text))\n"
					if let style { out += "    style:  \(scalar(style))\n" }
				case .scene(let name, let parameters):
					out += "  - scene:   \(scalar(name))\n"
					if !parameters.isEmpty {
						let pairs = parameters.keys.sorted().map { "\($0): \(scalar(parameters[$0] ?? ""))" }
						out += "    with:    {" + pairs.joined(separator: ", ") + "}\n"
					}
				case .effect(let effect):
					out += "  - effect:  \(effect.style.rawValue)\n"
					if effect.finish != .matte { out += "    finish:  \(effect.finish.rawValue)\n" }
					if effect.density != 1 { out += "    density: \(trim(effect.density))\n" }
					if effect.speed != 1 { out += "    speed:   \(trim(effect.speed))\n" }
					if effect.size != 1 { out += "    size:    \(trim(effect.size))\n" }
					if effect.seed != 1 { out += "    seed:    \(effect.seed)\n" }
					if !effect.palette.isEmpty {
						out += "    palette: ["
							+ effect.palette.map { scalar($0.hex) }.joined(separator: ", ") + "]\n"
					}
				case .film(let film):
					// The stock is the thing, so it is the key. Everything else
					// is written only when it is not what a film overlay is
					// without it.
					let plain = Film()
					out += "  - film:    \(film.tint.rawValue)\n"
					if film.ratio != plain.ratio { out += "    ratio:   \(scalar(film.ratio.written))\n" }
					if film.strength != plain.strength { out += "    strength: \(trim(film.strength))\n" }
					if film.grain != plain.grain { out += "    grain:   \(trim(film.grain))\n" }
					if film.vignette != plain.vignette { out += "    vignette: \(trim(film.vignette))\n" }
				case .spinner(let spinner):
					out += "  - spinner: \(spinner.style.rawValue)\n"
					if spinner.size != Spinner().size { out += "    size:    \(trim(spinner.size))\n" }
					if spinner.speed != Spinner().speed { out += "    speed:   \(trim(spinner.speed))\n" }
					if spinner.color != Spinner().color { out += "    color:   \(scalar(spinner.color.hex))\n" }
					if let wordStyle = spinner.wordStyle { out += "    word-style: \(scalar(wordStyle))\n" }
					if !spinner.words.isEmpty {
						out += "    words:\n"
						for word in spinner.words {
							if let duration = word.duration {
								out += "      - {text: \(scalar(word.text)), for: \(trim(duration))}\n"
							} else {
								out += "      - \(scalar(word.text))\n"
							}
						}
					}
				}
				// One range that says nothing of its own keeps the shape every
				// project already has; anything else goes under `when:`, which
				// is the same keys in a list.
				if overlay.appearances.count == 1, !overlay.appearances[0].says {
					out += range(overlay.appearances[0].span, indent: "    ")
				} else {
					out += "    when:\n"
					for appearance in overlay.appearances {
						// The block form aligns its values in a column; the flow
						// form has no column to align to, so the padding goes.
						var fields = range(appearance.span, indent: "").split(separator: "\n")
							.map { line -> String in
								let parts = line.split(separator: ":", maxSplits: 1)
								guard parts.count == 2 else {
									return line.trimmingCharacters(in: .whitespaces)
								}
								return parts[0].trimmingCharacters(in: .whitespaces) + ": "
									+ parts[1].trimmingCharacters(in: .whitespaces)
							}
						if let text = appearance.text { fields.append("text: \(scalar(text))") }
						if let said = appearance.words { fields.append("words: \(words(said))") }
						out += "      - {" + fields.joined(separator: ", ") + "}\n"
					}
				}
				if overlay.behind != .nothing {
					out += "    behind: \(overlay.behind.rawValue)\n"
				}
				if let anchor = overlay.anchor {
					out += "    anchor: \(scalar(anchor))\n"
					out += "    offset: [\(trim(overlay.offset.x)), \(trim(overlay.offset.y))]\n"
				}
				out += "    in:     \(transition(overlay.arrival))\n"
				out += "    out:    \(transition(overlay.departure))\n"
			}
		return out
	}

	private static func transition(_ value: Overlay.Transition) -> String {
		switch value {
		case .cut: return "cut"
		case .fade(let over): return "{fade: true, over: \(trim(over))}"
		case .fall(let over): return "{fall: true, over: \(trim(over))}"
		case .slide(let edge, let over): return "{slide: \(edge.rawValue), over: \(trim(over))}"
		}
	}

	/// A number without a trailing `.0`, because `fps: 25.0` is not how anybody
	/// writes twenty-five.
	private static func trim(_ value: Double) -> String {
		if value == value.rounded(), abs(value) < 1e9 { return String(Int(value)) }
		return String(format: "%g", value)
	}

	private static func trim(_ value: CGFloat) -> String { trim(Double(value)) }

	private static func scalar(_ value: String) -> String { TakeWriter.scalar(value) }
}
