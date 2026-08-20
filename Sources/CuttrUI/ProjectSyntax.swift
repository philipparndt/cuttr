import AppKit
import CuttrCompose

/// The project file, coloured in four roles.
///
/// The text mode is not a fallback. It is the thing the rest of the window is a
/// way of writing, and somebody reading forty lines of it is looking for one of
/// four things: what a line *is* (a key), what it *points at* (a reference), how
/// much (a number), or what somebody wrote down for later (a comment). Four
/// roles, so four colours, and nothing else coloured at all.
///
/// A reference takes the hue of the kind of thing it names, which is the rule
/// everywhere else in this program — a `@section` is violet in the file for the
/// same reason it is violet in the tree. **A reference that resolves to nothing
/// is red**, and that is the part worth having: a slug with a typo in it is the
/// commonest mistake this format admits, it costs a render to find, and here it
/// is visible while it is being typed.
///
/// Nothing is guessed. Whether a name resolves is asked of the vocabulary the
/// document built from the takes — and when there is no vocabulary yet, nothing
/// is marked wrong, because "this project has not resolved" and "this name is a
/// typo" are different claims.
@MainActor
public enum ProjectSyntax {

	/// What a stretch of the file is.
	public enum Role: Equatable {
		case comment
		case key
		case number
		/// A name that points at something, and whether it found it.
		case reference(Theme.Kind, resolved: Bool)
	}

	public static func colour(_ role: Role) -> NSColor {
		switch role {
		case .comment: return Theme.faintText
		// A key and a number are the same colour and told apart by weight.
		//
		// This started as `heardNotSaid`, which was wrong for exactly the reason
		// the palette rule exists: that green already means `[laughter]` — a
		// thing that was heard and not said — and borrowing it for `0.09` gives
		// one fixed hue a second meaning. Every hue in the palette is spoken
		// for, and a number is not a *kind of thing* anyway; it is a quantity.
		// So it is said in weight, which is what the rest of this program does
		// when it has run out of hues and still has something to say.
		case .key, .number: return Theme.text
		case .reference(_, false): return Theme.playhead
		case .reference(let kind, true): return Theme.color(kind)
		}
	}

	/// Whether this role is set in the heavier weight. Numbers are: they are the
	/// thing somebody is looking for when they open the file to change a value.
	public static func isStrong(_ role: Role) -> Bool { role == .number }

	/// Every stretch worth colouring, as ranges into `text`.
	public static func roles(in text: String,
	                         vocabulary: ComposeDocument.Vocabulary) -> [(NSRange, Role)] {
		var out: [(NSRange, Role)] = []
		// Nothing to check against means nothing is called wrong.
		let known = !(vocabulary.clips.isEmpty && vocabulary.groups.isEmpty
			&& vocabulary.tags.isEmpty && vocabulary.labels.isEmpty
			&& vocabulary.scenes.isEmpty && vocabulary.takeNames.isEmpty)

		let whole = text as NSString
		var start = 0
		while start < whole.length {
			let line = whole.lineRange(for: NSRange(location: start, length: 0))
			defer { start = NSMaxRange(line) }
			var body = whole.substring(with: line)

			// A comment is `#` where a comment can be: first on the line, or
			// after a space, and followed by a space or by nothing. `#b-roll` is
			// a tag and has neither, which is what tells the two apart here.
			//
			// The rest of the line is still read. A trailing comment does not
			// stop the line in front of it from being a line — `query: #b-roll
			// # the wide shots` has a tag on it and a note about it, and losing
			// the tag to the note is exactly the mistake this used to make.
			if let hash = commentStart(in: body) {
				out.append((NSRange(location: line.location + hash,
				                    length: line.length - hash), .comment))
				body = (body as NSString).substring(to: hash)
				if body.isEmpty { continue }
			}

			// `key:` — the structure, and the only thing somebody scans for.
			if let colon = keyEnd(in: body) {
				let from = body.prefix(colon).prefix { $0 == " " || $0 == "\t" || $0 == "-" }.count
				if colon > from {
					out.append((NSRange(location: line.location + from, length: colon - from), .key))
				}
			}

			for (range, role) in tokens(in: body, vocabulary: vocabulary, checking: known) {
				out.append((NSRange(location: line.location + range.location,
				                    length: range.length), role))
			}
		}
		return out
	}

	/// Where a comment starts on this line, if it does.
	private static func commentStart(in line: String) -> Int? {
		let characters = Array(line)
		for (index, character) in characters.enumerated() where character == "#" {
			let before = index == 0 ? nil : characters[index - 1]
			let after = index + 1 < characters.count ? characters[index + 1] : nil
			let opens = before == nil || before == " " || before == "\t"
			// A hash that begins a *word* is a tag; one followed by a space or
			// by nothing is a comment.
			guard opens, after == nil || after == " " || after == "#" else { continue }
			// Everything before it must be blank for a whole-line comment; a
			// trailing comment is fine either way.
			return index
		}
		return nil
	}

	/// Where the key on this line ends, if the line has one.
	private static func keyEnd(in line: String) -> Int? {
		let characters = Array(line)
		for (index, character) in characters.enumerated() {
			if character == ":" {
				// `00:12.345` is a time, not a key. A key's colon is followed by
				// a space or by the end of the line.
				let after = index + 1 < characters.count ? characters[index + 1] : nil
				guard after == nil || after == " " || after == "\n" else { return nil }
				return index
			}
			// A key is one word. Anything that is not part of one, before a
			// colon, means this line is a value rather than a key.
			guard character.isLetter || character.isNumber || character == "_"
				|| character == "-" || character == "." || character == " "
				|| character == "\t" || character == "\""
			else { return nil }
		}
		return nil
	}

	/// The references and the numbers on one line.
	private static func tokens(in line: String, vocabulary: ComposeDocument.Vocabulary,
	                           checking: Bool) -> [(NSRange, Role)] {
		var out: [(NSRange, Role)] = []
		let text = line as NSString
		// The number is fenced on both sides. Without that, `question1` gave up
		// a `1` — a name with a digit at the end is not a number, and half of
		// the slugs anybody writes end in one.
		let pattern = "(@[A-Za-z0-9_.\\-]+)|(#[A-Za-z0-9_./*\\-]+)"
			+ "|([A-Za-z0-9_\\-]+/[A-Za-z0-9_.#*\\-]+)"
			+ "|((?<![A-Za-z0-9_@#/.\\-])-?[0-9]+(:[0-9.]+)*(\\.[0-9]+)?(?![A-Za-z0-9_]))"
		guard let expression = try? NSRegularExpression(pattern: pattern) else { return out }
		for match in expression.matches(in: line, range: NSRange(location: 0, length: text.length)) {
			let token = text.substring(with: match.range)
			guard let first = token.first else { continue }
			switch first {
			case "@":
				let name = String(token.dropFirst())
				let found = vocabulary.groups.contains(name) || vocabulary.labels.contains(name)
					|| vocabulary.scenes.contains(name) || vocabulary.anchors.contains(name)
				out.append((match.range, .reference(.section, resolved: !checking || found)))
			case "#":
				let name = String(token.dropFirst()).split(separator: "/").last.map(String.init) ?? ""
				// A trailing `*` is a wildcard over the tags rather than one of
				// them, so it is right by construction.
				let found = name == "*" || name.hasSuffix("*")
					|| vocabulary.tags.contains(name)
				out.append((match.range, .reference(.query, resolved: !checking || found)))
			default:
				if token.contains("/") {
					let parts = token.split(separator: "/", maxSplits: 1)
					let take = String(parts.first ?? "")
					let slug = parts.count > 1 ? String(parts[1]) : ""
					// A path to a file — `takes/mia.cuttr`, `music.wav` — is not
					// a reference to a name, and marking it red would be wrong.
					guard !slug.contains("."), !take.contains(".") else { continue }
					let found = vocabulary.takeNames.contains(take)
						&& (slug == "*" || slug.hasPrefix("#") || vocabulary.clips.contains(slug))
					out.append((match.range, .reference(.clip, resolved: !checking || found)))
				} else if first.isNumber || first == "-" {
					out.append((match.range, .number))
				}
			}
		}
		return out
	}
}
