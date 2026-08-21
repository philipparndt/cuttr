import Foundation

/// The prose a file carried, and where in it.
///
/// A take and a project are both meant to be opened in an editor, and somebody
/// who opens one writes in it: a paragraph at the top saying what this cut is
/// for, a line above a clip saying why it is a retake, a word at the end of a
/// line. None of that is part of the value — the reader has nowhere to put it
/// and the renderer would not know what to do with it — so a decode into a
/// struct and a re-encode out of one deletes every word of it. That is the same
/// hole ``Take/unknownKeys`` fills for keys, and this fills it for prose.
///
/// A comment is held against an *address*: the path through the file of the
/// thing it was written about. `styles/far-away` is the style of that name
/// wherever it ends up in the block, and a comment above it stays above it when
/// the block is re-ordered. Addressing rather than counting lines is the whole
/// point: a line number is stale the moment anything above it changes, and a
/// note that moves onto the next clip down is worse than one that was lost.
///
/// Four kinds, because there are four places a person writes:
///
/// - `header` — the block at the very top, before anything else. It is about
///   the file, so it has no key to hang off.
/// - `above` — a block on its own lines, belonging to the line under it.
/// - `trailing` — what was at the end of a line, belonging to that line.
/// - `footer` — a block at the bottom with nothing after it to belong to.
///
/// A comment whose address is gone — the clip it was about was deleted — is
/// dropped. There is nowhere honest to put it: the file has no key it is about
/// any more, and the two alternatives are to invent a place for it (which is
/// exactly the migration this addressing exists to prevent) or to keep a
/// growing tail of orphaned prose that no longer says anything true.
public struct FileComments: Sendable, Equatable {

	/// The block at the top of the file. It replaces the emitter's own header
	/// line rather than joining it: somebody who has written their own header
	/// has written it *instead*, and a file whose header is the generated line
	/// stores that line here and gets it back unchanged.
	public var header: [String] = []

	/// Own-line blocks, by the address of the line beneath them. Each line is
	/// held without its indentation and re-indented to whatever the line it
	/// belongs to ends up at.
	///
	/// A block that had a blank line above it in the file carries an empty
	/// first line, because the gap is part of how it reads: a paragraph pushed
	/// up against the key above it is a different-looking file. The gap is only
	/// written where the emitter has not left one already.
	public var above: [String: [String]] = [:]

	/// End-of-line comments, by the address of their own line. Held with the
	/// whitespace that separated them from the value, so a re-save does not
	/// move the column they were lined up in.
	public var trailing: [String: String] = [:]

	/// A block at the end of the file, with no line under it to belong to.
	public var footer: [String] = []

	public init(
		header: [String] = [], above: [String: [String]] = [:],
		trailing: [String: String] = [:], footer: [String] = []
	) {
		self.header = header
		self.above = above
		self.trailing = trailing
		self.footer = footer
	}

	public var isEmpty: Bool {
		header.isEmpty && above.isEmpty && trailing.isEmpty && footer.isEmpty
	}

	/// `text` with these comments put back at the addresses they came from.
	///
	/// A pass over the emitter's output rather than anything the emitter does
	/// itself, which is what keeps the emitter hand-written and its bytes
	/// fixed: it writes the file it has always written, and this reads that
	/// file's structure back to find out where the prose goes. The two agree
	/// because they agree about one function — ``FileScan/addresses(of:)`` —
	/// and not because they were written to match.
	///
	/// Where the emitter has written its own comment on a line, the emitter
	/// wins and the stored one is dropped. Those are generated — a clip's
	/// length, `# LUFS`, the note about which way an offset goes — and a file
	/// the emitter wrote, read and written again must come out byte for byte
	/// the same rather than accumulating a second copy of each of them.
	public func written(into text: String) -> String {
		guard !isEmpty else { return text }
		var lines = text.components(separatedBy: "\n")
		// A trailing newline shows up as a last empty component. Held back so
		// the footer goes before it and the file still ends in one.
		let endsWithNewline = lines.last?.isEmpty == true
		if endsWithNewline { lines.removeLast() }
		let addresses = FileScan.addresses(of: lines)

		var out: [String] = []
		var start = 0
		if !header.isEmpty {
			// The emitter's own header is one comment line at the top; it is
			// replaced, not joined. Blank lines are not skipped, so a file that
			// opens with a key keeps its first line where it was.
			while start < lines.count, FileScan.isComment(lines[start]) { start += 1 }
			out += header
		}

		/// One own-line block, at the indentation of what it is about.
		func put(_ block: [String], at indent: Int) {
			let margin = String(repeating: " ", count: indent)
			for comment in block {
				// The remembered gap, unless there is one there already — the
				// emitter leaves its own blank line between entries and two of
				// them is not what the file said.
				guard !comment.isEmpty else {
					if !(out.last?.isEmpty ?? true) { out.append("") }
					continue
				}
				out.append(margin + comment)
			}
		}

		var placed = Set<String>()
		for index in start..<lines.count {
			let line = lines[index]
			guard let address = addresses[index] else {
				out.append(line)
				continue
			}
			// Only the first line with a given address, so a hand-written file
			// with the same key twice does not get the comment twice.
			if let block = above[address], placed.insert(address).inserted {
				put(block, at: FileScan.indent(of: line))
			}
			if let tail = trailing[address], FileScan.commentStart(in: line) == nil {
				out.append(line + tail)
			} else {
				out.append(line)
			}
		}
		put(footer, at: 0)
		if endsWithNewline { out.append("") }
		return out.joined(separator: "\n")
	}
}

/// Reading the shape of a file out of its text: where the comments were, and
/// the order the named blocks came in.
///
/// Not a YAML parser. Yams does the reading; this walks the same text a second
/// time counting indentation, because the two things it is after are the two
/// things a parse into a value throws away. It has to understand only what this
/// program's two emitters and a person editing their output actually write:
/// block mappings, block sequences, and flow collections on one line.
public struct FileScan: Sendable {

	/// The prose, addressed.
	public var comments = FileComments()

	/// For each container, the keys under it in the order the file had them —
	/// `styles` before the styles, `scenes` before the scenes. A dictionary has
	/// no order and a file does, and re-sorting somebody's blocks on save is
	/// the same churn as re-quoting their strings.
	public var order: [String: [String]] = [:]

	/// Reads `text`, ignoring any own-line comment whose text is in
	/// `generated`.
	///
	/// The emitter writes a few comments of its own on their own lines — the
	/// placeholder block that says where clips go in a file that has none. Kept
	/// here they would be stored as somebody's prose and then written a second
	/// time under the emitter's copy, so they are recognised and dropped. The
	/// header is not in that set: it is handled by
	/// ``FileComments/header`` replacing it.
	public init(_ text: String, ignoring generated: Set<String> = []) {
		let lines = text.components(separatedBy: "\n")
		let addresses = Self.addresses(of: lines)

		var pending: [String] = []
		var seenContent = false
		var gap = false
		for (index, line) in lines.enumerated() {
			let body = line.trimmingCharacters(in: .whitespaces)
			if body.isEmpty {
				if pending.isEmpty { gap = seenContent }
				continue
			}
			if body.hasPrefix("#") {
				guard !generated.contains(body) else { continue }
				// A blank line does not break a block — a paragraph with a gap
				// in it still reads as one — but a blank line above the block
				// is remembered, because the gap is part of how it looks.
				if pending.isEmpty, gap { pending.append("") }
				pending.append(body)
				continue
			}
			gap = false
			if !pending.isEmpty {
				if !seenContent {
					comments.header = pending
				} else if let address = addresses[index] {
					comments.above[address] = pending
				}
				pending = []
			}
			seenContent = true
			if let address = addresses[index], let start = Self.commentStart(in: line) {
				// From the end of the value rather than from the `#`, so the
				// column somebody lined a note up in survives the save.
				var from = start
				while from > line.startIndex {
					let before = line.index(before: from)
					guard line[before] == " " || line[before] == "\t" else { break }
					from = before
				}
				comments.trailing[address] = String(line[from...])
			}
		}
		// Whatever was still open at the end has nothing under it to be about.
		// A file that is only comments is a header, not a footer.
		if !pending.isEmpty {
			if seenContent { comments.footer = pending } else { comments.header = pending }
		}

		// The declared order, from the same walk: an address's last component
		// is the key, and everything before it is the container it is in.
		for address in addresses.compactMap({ $0 }) {
			guard let cut = address.lastIndex(of: "/") else {
				order["", default: []].append(address)
				continue
			}
			let container = String(address[address.startIndex..<cut])
			let key = String(address[address.index(after: cut)...])
			guard !key.hasSuffix(":"), !key.contains(": ") else { continue }
			if order[container]?.contains(key) != true { order[container, default: []].append(key) }
		}
	}

	// MARK: - Addressing

	/// A container being walked: where its children start, and what to call
	/// them.
	private struct Frame {
		var indent: Int
		var path: String
		var isList: Bool
		/// Identifying tokens used in this list, so two items that read the
		/// same are still two addresses.
		var used: [String: Int] = [:]
		/// The last key here that had a block under it — the path any deeper
		/// container belongs to.
		var pending: String = ""
	}

	/// The address of the thing each line introduces, or `nil` for a line that
	/// introduces nothing — a blank, a comment, the continuation of something.
	///
	/// The one function the reader and the writer share, and the reason they
	/// agree about where a comment goes. A key is addressed by name, so it is
	/// found again wherever the emitter chooses to put it. An item in a list is
	/// addressed by what it says — `overlays/scene: crawl`, not `overlays/1` —
	/// because a list is re-ordered by moving things in the app, and an index
	/// would hand a note about one overlay to whichever one landed in its slot.
	static func addresses(of lines: [String]) -> [String?] {
		var out = [String?](repeating: nil, count: lines.count)
		var stack: [Frame] = []

		for (number, raw) in lines.enumerated() {
			let line = stripped(raw)
			var indent = indent(of: line)
			var body = line.dropFirst(indent)
			if body.isEmpty || body.hasPrefix("#") { continue }

			// Every dash on the line: `- - a` is two lists, and a list item's
			// own keys start two columns in from its dash.
			while body == "-" || body.hasPrefix("- ") {
				while let top = stack.last, top.indent > indent { stack.removeLast() }
				if stack.last?.isList != true || stack.last?.indent != indent {
					let owner = stack.last?.pending ?? ""
					stack.append(Frame(indent: indent, path: owner, isList: true))
				}
				let rest = body.dropFirst(body == "-" ? 1 : 2)
				let token = token(of: rest)
				let count = stack[stack.count - 1].used[token, default: 0]
				stack[stack.count - 1].used[token] = count + 1
				let path = join(stack[stack.count - 1].path,
				                count == 0 ? token : "\(token)#\(count + 1)")
				out[number] = path
				stack.append(Frame(indent: indent + 2, path: path, isList: false))
				indent += 2
				body = rest
			}

			guard let (key, value) = keyed(body) else { continue }
			// A key at the same column as a list closes the list: `overlays:`
			// after a timeline's entries is not one of them.
			while let top = stack.last, top.indent > indent || (top.indent == indent && top.isList) {
				stack.removeLast()
			}
			if stack.last == nil || stack.last!.indent < indent {
				stack.append(Frame(indent: indent, path: stack.last?.pending ?? "",
				                   isList: false))
			}
			let path = join(stack[stack.count - 1].path, key)
			out[number] = path
			// An empty value means a block follows, and this is what it hangs
			// off. A value means this key is a leaf and has no children.
			stack[stack.count - 1].pending = value.isEmpty ? path : ""
		}
		return out
	}

	private static func join(_ container: String, _ name: String) -> String {
		container.isEmpty ? name : container + "/" + name
	}

	/// What a list item is called, for addressing: its first line, with the
	/// padding the emitter lines its values up with taken out.
	///
	/// `- scene:  crawl` and `- scene:   crawl` are the same item written by two
	/// versions of the same emitter, so the columns cannot be part of the name.
	/// The value itself is, which is the trade: renaming the scene loses the
	/// comment about it, and moving it does not.
	private static func token(of body: Substring) -> String {
		let text = body.trimmingCharacters(in: .whitespaces)
		guard let (key, value) = keyed(body) else { return text }
		return value.isEmpty ? "\(key):" : "\(key): \(value)"
	}

	/// `key: value`, when the line is that. A flow collection, a quoted scalar
	/// or a bare one is not.
	private static func keyed(_ body: Substring) -> (key: String, value: String)? {
		let text = body.trimmingCharacters(in: .whitespaces)
		guard let first = text.first, !"{[\"'-#".contains(first) else { return nil }
		// The first colon that ends a word: `size: 1920x1080` has one and
		// `- 16:9` in a list has none.
		var index = text.startIndex
		while index < text.endIndex {
			if text[index] == ":" {
				let next = text.index(after: index)
				if next == text.endIndex || text[next] == " " {
					let key = String(text[text.startIndex..<index])
					guard !key.isEmpty, !key.contains(" #") else { return nil }
					let value = String(text[next...]).trimmingCharacters(in: .whitespaces)
					return (key, value)
				}
			}
			index = text.index(after: index)
		}
		return nil
	}

	// MARK: - Lines

	static func indent(of line: String) -> Int {
		line.prefix(while: { $0 == " " }).count
	}

	static func isComment(_ line: String) -> Bool {
		line.trimmingCharacters(in: .whitespaces).hasPrefix("#")
	}

	/// The line without its comment, for reading structure out of it.
	private static func stripped(_ line: String) -> String {
		guard let start = commentStart(in: line) else { return line }
		return String(line[line.startIndex..<start])
	}

	/// Where a comment starts on this line, if it has one.
	///
	/// A `#` is only a comment where YAML says it is: outside quotes, and at
	/// the start of a word. `color: "#4bd5ee"` is a colour and `#ffd54a` inside
	/// a flow list is too, and taking either for a comment would cut the value
	/// off the line.
	static func commentStart(in line: String) -> String.Index? {
		var quote: Character?
		var previous: Character?
		var index = line.startIndex
		while index < line.endIndex {
			let ch = line[index]
			if let open = quote {
				if ch == "\\", open == "\"" {
					// An escape inside double quotes hides the next character,
					// including a closing quote.
					index = line.index(after: index)
					previous = nil
					if index < line.endIndex { index = line.index(after: index) }
					continue
				}
				if ch == open { quote = nil }
			} else if ch == "\"" || ch == "'" {
				quote = ch
			} else if ch == "#", previous == nil || previous == " " || previous == "\t" {
				return index
			}
			previous = ch
			index = line.index(after: index)
		}
		return nil
	}
}
