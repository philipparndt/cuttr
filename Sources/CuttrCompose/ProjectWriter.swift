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
	private static func scenes(_ scenes: [String: Scene], order: [String]?) -> String {
		guard !scenes.isEmpty else { return "" }
		var out = "\nscenes:\n"
		for name in ordered(scenes.keys, order) {
			guard let scene = scenes[name] else { continue }
			out += "  \(name):\n"
			out += "    parts:\n"
			for part in scene.parts {
				switch part.content {
				case .text(let text, let style, let tracking):
					out += "      - text:  \(scalar(text))\n"
					if let style { out += "        style: \(scalar(style))\n" }
					if tracking != 0 { out += "        tracking: \(trim(tracking))\n" }
				case .shape(let fill, let corner, let kind):
					out += "      - shape: \(scalar(fill.hex))\n"
					// Left out when it is a rectangle, which is what a shape
					// part was before there were kinds — so a project written
					// then comes back out exactly as it went in.
					if kind != .rectangle { out += "        kind:   \(kind.rawValue)\n" }
					if corner != 0 { out += "        corner: \(trim(corner))\n" }
				case .bar(let bar):
					out += "      - bar:   \(scalar(bar.fill.hex))\n"
					out += "        track: \(bar.track.a == 0 ? "none" : scalar(bar.track.hex))\n"
					if bar.corner != 0 { out += "        corner: \(trim(bar.corner))\n" }
					if bar.direction != .right {
						out += "        direction: \(bar.direction.rawValue)\n"
					}
				case .spinner(let spinner):
					out += "      - spinner: \(spinner.style.rawValue)\n"
					out += "        size:  \(trim(spinner.size))\n"
					if spinner.speed != 1 { out += "        speed: \(trim(spinner.speed))\n" }
					out += "        color: \(scalar(spinner.color.hex))\n"
				case .roll(let column):
					out += credits(column)
				case .image(let file):
					out += "      - image: \(scalar(file))\n"
				case .frames(let sequence):
					out += "      - frames: \(scalar(sequence.pattern))\n"
					out += "        fps:    \(trim(sequence.fps))\n"
				case .component(let component):
					out += "      - component: \(scalar(component.file))\n"
					out += "        duration:  \(trim(component.duration))\n"
					// The props on one line, in the same flow mapping and the
					// same sorted order a scene's `with:` uses — and left out
					// entirely when there are none, so a component that takes
					// nothing is the two lines it was written as.
					if !component.props.isEmpty {
						let pairs = component.props.keys.sorted().map {
							"\(flow($0)): \(flow(component.props[$0] ?? ""))"
						}
						out += "        props:     {" + pairs.joined(separator: ", ") + "}\n"
					}
				case .background(let background):
					// A flat colour stays the one word it was written as; the
					// ramp says all three things or none of them.
					if let to = background.to {
						out += "      - background: {from: \(scalar(background.from.hex))"
							+ ", to: \(scalar(to.hex)), angle: \(trim(background.angle))}\n"
					} else {
						out += "      - background: \(scalar(background.from.hex))\n"
					}
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
					if let progress = key.progress { fields.append("progress: \(trim(progress))") }
					if let shape = key.shape { fields.append("shape: \(shape.rawValue)") }
					if let color = key.color { fields.append("color: \(scalar(color.hex))") }
					// The far stop and the angle sit with the colour, which is
					// the near one: a background's three gradient words in the
					// order the part declares them.
					if let to = key.to { fields.append("to: \(scalar(to.hex))") }
					if let angle = key.angle { fields.append("angle: \(trim(angle))") }
					if key.ease != .inOut { fields.append("ease: \(key.ease.rawValue)") }
					out += "          - {" + fields.joined(separator: ", ") + "}\n"
				}
			}
		}
		return out
	}

	/// A credit roll: the blocks, then how the column is set.
	///
	/// A block on one line while one line reads as a line — which is nearly
	/// always, because nearly every block is a role and a name. Eight names in
	/// a flow list is not a line anybody wants to edit, so that one goes to the
	/// block form, which is what a person would have written for it too. The
	/// choice is made from the value and nothing else, so a roll written twice
	/// is written the same way twice.
	///
	/// `line`, `gap`, `column` and `align` are always written, even at their
	/// defaults. They are the four numbers somebody tunes when a roll is nearly
	/// right, and a default nobody can see is a default nobody can nudge.
	private static func credits(_ roll: Scene.Roll) -> String {
		// An empty list said out loud, because a roll with no blocks is a real
		// thing — a card that carries only its title — and `roll:` with nothing
		// after it reads as a key somebody forgot to finish.
		guard roll.entries.contains(where: { !$0.role.isEmpty || !$0.names.isEmpty }) else {
			return "      - roll:   []\n" + settings(roll)
		}
		var out = "      - roll:\n"
		for entry in roll.entries {
			// The same blocks the reader keeps. A block with neither a role nor
			// a name is not one, and writing it would produce a file that reads
			// back as a different value.
			guard !entry.role.isEmpty || !entry.names.isEmpty else { continue }
			var fields: [String] = []
			if !entry.role.isEmpty { fields.append("role: \(flow(entry.role))") }
			// Beside the role, because that is what it qualifies: where the
			// names under this one came from.
			if let source = entry.source { fields.append("from: \(source.rawValue)") }
			if !entry.names.isEmpty {
				fields.append("names: [" + entry.names.map(flow).joined(separator: ", ") + "]")
			}
			let inline = "          - {" + fields.joined(separator: ", ") + "}\n"
			if inline.count <= 90 {
				out += inline
				continue
			}
			var first = true
			func key(_ name: String) -> String {
				defer { first = false }
				return (first ? "          - " : "            ")
					+ (name + ":").padding(toLength: 7, withPad: " ", startingAt: 0)
			}
			if !entry.role.isEmpty { out += "\(key("role"))\(scalar(entry.role))\n" }
			if let source = entry.source { out += "\(key("from"))\(source.rawValue)\n" }
			if !entry.names.isEmpty {
				out += (first ? "          - names:\n" : "            names:\n")
				first = false
				for name in entry.names { out += "              - \(scalar(name))\n" }
			}
		}
		return out + settings(roll)
	}

	/// How the column is set, under the blocks it applies to.
	private static func settings(_ roll: Scene.Roll) -> String {
		func field(_ name: String, _ value: String) -> String {
			"        " + (name + ":").padding(toLength: 8, withPad: " ", startingAt: 0) + value + "\n"
		}
		var out = ""
		if let title = roll.title { out += field("title", scalar(title)) }
		if let style = roll.style { out += field("style", scalar(style)) }
		if let style = roll.roleStyle { out += "        role-style: \(scalar(style))\n" }
		if let style = roll.titleStyle { out += "        title-style: \(scalar(style))\n" }
		out += field("line", trim(roll.line))
		out += field("gap", trim(roll.gap))
		out += field("column", trim(roll.column))
		out += field("align", roll.align.rawValue)
		if roll.tracking != 0 { out += "        tracking: \(trim(roll.tracking))\n" }
		// Nought is a flat column, which is what a credit roll is, so it is left
		// out — see ``CuttrCompose/Scene/Roll/tilt``.
		if roll.tilt != 0 { out += "        tilt:     \(trim(roll.tilt))\n" }
		return out
	}

	/// The own-line comments this emitter writes itself — see
	/// ``CuttrKit/TakeWriter/generatedComments`` for why they are named.
	static let generatedComments: Set<String> = [
		"# nothing yet — add clips by slug:",
		"# - take-01/intro",
	]

	/// Names in the order the file had them, with anything the file did not
	/// have after them, sorted.
	///
	/// Sorting was never the point; determinism was. This is deterministic for
	/// the same project and keeps the arrangement somebody chose, which sorting
	/// threw away — a file whose styles read far, near, nearer came back
	/// alphabetical and every save was a diff.
	private static func ordered(_ names: some Sequence<String>, _ declared: [String]?) -> [String] {
		let all = Set(names)
		var out: [String] = []
		for name in declared ?? [] where all.contains(name) && !out.contains(name) {
			out.append(name)
		}
		return out + all.subtracting(out).sorted()
	}

	/// The project as text, with whatever prose the file carried put back.
	///
	/// The emitter is the function below and knows nothing about comments; this
	/// puts them back at the addresses they were read from. See
	/// ``CuttrKit/FileComments``.
	public static func write(_ project: Project) -> String {
		project.comments.written(into: body(project))
	}

	private static func body(_ project: Project) -> String {
		var out = "# cuttr project — the assembly. Clips are referenced by slug.\n"
		out += "cuttr-project: \(ProjectReader.formatVersion)\n\n"

		if !project.takes.isEmpty {
			out += "takes:\n"
			for take in project.takes { out += "  - \(scalar(take))\n" }
			out += "\n"
		}

		// The arrangement, when there is one. A project that has never made a
		// folder writes no block at all, so nothing changes in a file nobody
		// has arranged — and an empty folder is written as `takes: []` rather
		// than omitted, because it has to survive the save that follows making
		// it.
		if !project.folders.isEmpty {
			out += "folders:\n"
			for folder in project.folders {
				out += "  - name:  \(scalar(folder.name))\n"
				if folder.takes.isEmpty {
					out += "    takes: []\n"
				} else {
					out += "    takes:\n"
					for take in folder.takes { out += "      - \(scalar(take))\n" }
				}
			}
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
			for name in ordered(project.profiles.keys, project.declaredOrder["profiles"]) {
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
			for name in ordered(project.styles.keys, project.declaredOrder["styles"]) {
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

		out += scenes(project.scenes, order: project.declaredOrder["scenes"])

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
			// Last, after everything the entry says about itself, and in the
			// same shape the top-level list uses — one list to learn, written
			// two levels in. An entry with none of them writes nothing, which
			// is what keeps every project that predates this byte-identical.
			if !entry.overlays.isEmpty {
				out += "\(indent)  overlays:\n"
				out += overlays(entry.overlays, indent: indent + "    ")
			}
			if !entry.sounds.isEmpty {
				out += "\(indent)  sounds:\n"
				out += sounds(entry.sounds, indent: indent + "    ")
			}
			if !entry.presentations.isEmpty {
				out += "\(indent)  presentations:\n"
				out += presentations(entry.presentations, indent: indent + "    ")
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
			word.duration.map { "{text: \(flow(word.text)), for: \(trim($0))}" }
				?? flow(word.text)
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
	private static func sounds(_ list: [Sound], indent: String = "  ") -> String {
		var out = ""
		for (index, sound) in list.enumerated() {
			if index > 0 { out += "\n" }
			out += "\(indent)- file:  \(scalar(sound.file))\n"
			// No range at all is a sound written inside an entry to play for as
			// long as that entry is on, and the point of that spelling is that
			// there is nothing to write.
			if let span = sound.span { out += range(span, indent: indent + "  ", column: 7) }
			if sound.gain != 0 { out += "\(indent)  gain:  \(trim(sound.gain))\n" }
			if case .fade(let over) = sound.arrival {
				out += "\(indent)  in:    {fade: true, over: \(trim(over))}\n"
			}
			if case .fade(let over) = sound.departure {
				out += "\(indent)  out:   {fade: true, over: \(trim(over))}\n"
			}
			if sound.ducks != 0 {
				out += "\(indent)  ducks: \(trim(sound.ducks))   # dB off the programme's own sound\n"
			}
		}
		return out
	}

	/// The treatments on a placement.
	///
	/// `at:` first because when it happens is what somebody scans the block
	/// for, then where the picture goes and how long it stays, then the scene
	/// and what fills it. Only `at:` and `into:` and `scene:` are always
	/// written; the rest are left out when they are what a treatment is
	/// without them, so a plain one stays three lines.
	///
	/// The column the values line up in is the width of the widest key the
	/// treatment actually has — `scene:` for nearly all of them, and `reveal:`
	/// for one that spreads its lines across the hold. The same rule
	/// ``cardEntry(_:_:_:label:)`` follows, and for the same reason: a column
	/// wide enough for a key that is not there is a space on every line paying
	/// for nothing.
	private static func presentations(_ list: [Presentation], indent: String = "  ") -> String {
		var out = ""
		for (index, shown) in list.enumerated() {
			if index > 0 { out += "\n" }
			let column = shown.reveal == .together ? 7 : 8
			func key(_ name: String) -> String {
				(name + ":").padding(toLength: column, withPad: " ", startingAt: 0)
			}
			out += "\(indent)- \(key("at"))\(Timecode.string(shown.at))\n"
			out += "\(indent)  \(key("into"))[" + [shown.into.x, shown.into.y,
			                                        shown.into.width, shown.into.height]
				.map(trim).joined(separator: ", ") + "]\n"
			if shown.hold > 0 { out += "\(indent)  \(key("hold"))\(trim(shown.hold))\n" }
			if shown.ramp != 0.6 { out += "\(indent)  \(key("ramp"))\(trim(shown.ramp))\n" }
			out += "\(indent)  \(key("scene"))\(scalar(shown.scene))\n"
			if !shown.parameters.isEmpty {
				let pairs = shown.parameters.keys.sorted()
					.map { "\(flow($0)): \(flow(shown.parameters[$0] ?? ""))" }
				out += "\(indent)  \(key("with")){" + pairs.joined(separator: ", ") + "}\n"
			}
			if shown.reveal != .together {
				out += "\(indent)  \(key("reveal"))\(shown.reveal.rawValue)\n"
			}
		}
		return out
	}

	private static func overlays(_ list: [Overlay], indent: String = "  ") -> String {
		var out = ""
		for (index, overlay) in list.enumerated() {
				if index > 0 { out += "\n" }
				switch overlay.kind {
				case .text(let text, let style):
					out += "\(indent)- text:   \(scalar(text))\n"
					if let style { out += "\(indent)  style:  \(scalar(style))\n" }
				case .scene(let name, let parameters):
					out += "\(indent)- scene:   \(scalar(name))\n"
					if !parameters.isEmpty {
						let pairs = parameters.keys.sorted().map { "\(flow($0)): \(flow(parameters[$0] ?? ""))" }
						out += "\(indent)  with:    {" + pairs.joined(separator: ", ") + "}\n"
					}
				case .effect(let effect):
					out += "\(indent)- effect:  \(effect.style.rawValue)\n"
					if effect.finish != .matte { out += "\(indent)  finish:  \(effect.finish.rawValue)\n" }
					if effect.density != 1 { out += "\(indent)  density: \(trim(effect.density))\n" }
					if effect.speed != 1 { out += "\(indent)  speed:   \(trim(effect.speed))\n" }
					if effect.size != 1 { out += "\(indent)  size:    \(trim(effect.size))\n" }
					if effect.wind != 0 { out += "\(indent)  wind:    \(trim(effect.wind))\n" }
					if effect.seed != 1 { out += "\(indent)  seed:    \(effect.seed)\n" }
					if !effect.palette.isEmpty {
						out += "\(indent)  palette: ["
							+ effect.palette.map { scalar($0.hex) }.joined(separator: ", ") + "]\n"
					}
				case .film(let film):
					// The stock is the thing, so it is the key. Everything else
					// is written only when it is not what a film overlay is
					// without it.
					let plain = Film()
					out += "\(indent)- film:    \(film.tint.rawValue)\n"
					if film.ratio != plain.ratio { out += "\(indent)  ratio:   \(scalar(film.ratio.written))\n" }
					if film.strength != plain.strength { out += "\(indent)  strength: \(trim(film.strength))\n" }
					if film.grain != plain.grain { out += "\(indent)  grain:   \(trim(film.grain))\n" }
					if film.vignette != plain.vignette { out += "\(indent)  vignette: \(trim(film.vignette))\n" }
				case .aberration(let aberration):
					let plain = Aberration()
					out += "\(indent)- aberration: \(aberration.kind.rawValue)\n"
					if aberration.amount != plain.amount {
						out += "\(indent)  amount:  \(trim(aberration.amount))\n"
					}
					// Only the linear kind has one, and nought is straight to
					// the right, so a radial aberration never writes it.
					if aberration.kind == .linear, aberration.angle != plain.angle {
						out += "\(indent)  angle:   \(trim(aberration.angle))\n"
					}
				case .tape(let tape):
					// The condition is the thing, so it is the key, and each
					// knob is written only where it is no longer what the
					// condition means by it.
					let plain = Tape(tape.condition)
					out += "\(indent)- tape:    \(tape.condition.rawValue)\n"
					if tape.jitter != plain.jitter { out += "\(indent)  jitter:  \(trim(tape.jitter))\n" }
					if tape.band != plain.band { out += "\(indent)  band:    \(trim(tape.band))\n" }
					if tape.chroma != plain.chroma { out += "\(indent)  chroma:  \(trim(tape.chroma))\n" }
					if tape.scanlines != plain.scanlines {
						out += "\(indent)  scanlines: \(trim(tape.scanlines))\n"
					}
					if tape.dropouts != plain.dropouts {
						out += "\(indent)  dropouts: \(trim(tape.dropouts))\n"
					}
					if tape.seed != plain.seed { out += "\(indent)  seed:    \(tape.seed)\n" }
				case .bubble(let bubble):
					// The words are the thing, so they are the value; everything
					// else is written only where it is no longer what a bubble is
					// without it. Which is what makes the ordinary one — somebody
					// saying something, pointing at a face — two lines.
					let plain = Bubble()
					out += "\(indent)- bubble: \(scalar(bubble.text))\n"
					if bubble.shape != plain.shape {
						out += "\(indent)  shape:  \(bubble.shape.rawValue)\n"
					}
					if let style = bubble.style { out += "\(indent)  style:  \(scalar(style))\n" }
					if bubble.fill != plain.fill { out += "\(indent)  fill:   \(scalar(bubble.fill.hex))\n" }
					if bubble.line != plain.line { out += "\(indent)  line:   \(scalar(bubble.line.hex))\n" }
					if bubble.width != plain.width { out += "\(indent)  width:  \(trim(bubble.width))\n" }
					if bubble.seed != plain.seed { out += "\(indent)  seed:   \(bubble.seed)\n" }
					if bubble.breath != plain.breath {
						out += "\(indent)  breath: \(trim(bubble.breath))\n"
					}
					if bubble.follow != plain.follow {
						out += "\(indent)  follow: \(bubble.follow)\n"
					}
					if let at = bubble.at {
						out += "\(indent)  at:     [\(trim(at.x)), \(trim(at.y))]\n"
					}
					if bubble.tail != plain.tail {
						out += "\(indent)  tail:   [\(trim(bubble.tail.x)), \(trim(bubble.tail.y))]\n"
					}
				case .frames(let frames):
					// The folder is the thing, so it is the key. `fps:` is always
					// written because the reader always requires it — a sequence
					// with no rate is a sequence whose timing nobody stated — and
					// the other two only where they are not what a sequence is
					// without them.
					out += "\(indent)- frames: \(scalar(frames.folder))\n"
					out += "\(indent)  fps:    \(trim(frames.framesPerSecond))\n"
					if frames.size != 1 { out += "\(indent)  size:   \(trim(frames.size))\n" }
					if frames.ends != .hold { out += "\(indent)  ends:   \(frames.ends.rawValue)\n" }
				case .spinner(let spinner):
					out += "\(indent)- spinner: \(spinner.style.rawValue)\n"
					if spinner.size != Spinner().size { out += "\(indent)  size:    \(trim(spinner.size))\n" }
					if spinner.speed != Spinner().speed { out += "\(indent)  speed:   \(trim(spinner.speed))\n" }
					if spinner.color != Spinner().color { out += "\(indent)  color:   \(scalar(spinner.color.hex))\n" }
					if let wordStyle = spinner.wordStyle { out += "\(indent)  word-style: \(scalar(wordStyle))\n" }
					if !spinner.words.isEmpty {
						out += "\(indent)  words:\n"
						for word in spinner.words {
							if let duration = word.duration {
								out += "\(indent)    - {text: \(flow(word.text)), for: \(trim(duration))}\n"
							} else {
								out += "\(indent)    - \(scalar(word.text))\n"
							}
						}
					}
				}
				// The keys, if anything moves, straight after the knobs they
				// move — so a reader's eye goes from `amount: 0.2` to the list
				// of what happens to it. An overlay with none writes nothing at
				// all here, which is what every project already on disk is.
				out += keys(overlay)
				// One range that says nothing of its own keeps the shape every
				// project already has; anything else goes under `when:`, which
				// is the same keys in a list. No appearances at all is an
				// overlay written inside an entry to cover it, and the whole
				// point of that spelling is that there is nothing to write.
				if overlay.appearances.isEmpty {
					// nothing
				} else if overlay.appearances.count == 1, !overlay.appearances[0].says {
					out += range(overlay.appearances[0].span, indent: indent + "  ")
				} else {
					out += "\(indent)  when:\n"
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
						if let text = appearance.text { fields.append("text: \(flow(text))") }
						if let said = appearance.words { fields.append("words: \(words(said))") }
						out += "\(indent)    - {" + fields.joined(separator: ", ") + "}\n"
					}
				}
				if overlay.behind != .nothing {
					out += "\(indent)  behind: \(overlay.behind.rawValue)\n"
				}
				if let anchor = overlay.anchor {
					out += "\(indent)  anchor: \(scalar(anchor))\n"
				}
				// A bubble always writes where it sits, whether or not it points
				// at a tracked face: the reader gives a bubble that says nothing
				// a standoff from the thing it is about, and a default nobody can
				// see is a default nobody can nudge.
				//
				// And anything with an offset writes it, anchor or no anchor. An
				// offset without an anchor is measured from the middle of the
				// frame, which is how a spinner and a frame sequence are placed
				// when they follow nothing — so the old rule dropped a nudge on
				// the way back to disk. No file on disk changes: an offset that
				// was not written was not read either.
				var placed = overlay.anchor != nil || overlay.offset != .zero
				if case .bubble = overlay.kind { placed = true }
				if placed {
					out += "\(indent)  offset: [\(trim(overlay.offset.x)), \(trim(overlay.offset.y))]\n"
				}
				out += "\(indent)  in:     "
					+ transition(overlay.arrival, at: overlay.arrivalPlacement, default: .after) + "\n"
				out += "\(indent)  out:    "
					+ transition(overlay.departure, at: overlay.departurePlacement,
					             default: .before) + "\n"
			}
		return out
	}

	/// What an overlay's parameters do over its span.
	///
	/// The same flow form a scene's keys are written in, for the same reason:
	/// a key is three or four short things and reads as one line. Fields go in
	/// ``Overlay/Parameter``'s own order rather than the order somebody typed
	/// them, so a file written twice is the same file twice.
	private static func keys(_ overlay: Overlay) -> String {
		guard !overlay.keys.isEmpty else { return "" }
		let allowed = overlay.kind.animatable
		var out = "    keys:\n"
		for key in overlay.keys {
			var fields = ["t: \(trim(key.t))"]
			for parameter in allowed {
				guard let value = key[parameter] else { continue }
				fields.append("\(parameter.rawValue): \(trim(value))")
			}
			if key.ease != .inOut { fields.append("ease: \(key.ease.rawValue)") }
			out += "      - {" + fields.joined(separator: ", ") + "}\n"
		}
		return out
	}

	/// `in:` and `out:`, in the shape they are read in.
	///
	/// `at:` goes last and only when there is something to say: a placement that
	/// is the default is what the file has always meant, and a cut has no length
	/// to put anywhere. Both of those write exactly the line this wrote before
	/// placements existed, which is the whole of what a project that does not
	/// use one is entitled to.
	private static func transition(
		_ value: Overlay.Transition, at placement: Overlay.Transition.Placement,
		default fallback: Overlay.Transition.Placement
	) -> String {
		let sits = placement == fallback ? "" : ", at: \(placement.rawValue)"
		switch value {
		case .cut: return "cut"
		case .fade(let over): return "{fade: true, over: \(trim(over))\(sits)}"
		case .fall(let over): return "{fall: true, over: \(trim(over))\(sits)}"
		case .slide(let edge, let over):
			return "{slide: \(edge.rawValue), over: \(trim(over))\(sits)}"
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

	/// The same, for a value going inside `{…}` or `[…]`.
	///
	/// A comma ends an entry in a flow collection and a brace ends the
	/// collection, so a caption reading `clips are named, never timed` written
	/// bare into one comes back as two entries and the second half of the
	/// sentence becomes a key with no value. Found by writing the examples out
	/// twice and comparing: the first pass produced it, the second read it as
	/// two things. The block form has no such characters to worry about, which
	/// is why this is a second function and not a change to the first.
	private static func flow(_ value: String) -> String {
		let quoted = scalar(value)
		guard quoted == value else { return quoted }
		return value.contains(where: { ",{}[]".contains($0) })
			? "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
				.replacingOccurrences(of: "\"", with: "\\\"") + "\""
			: value
	}
}
