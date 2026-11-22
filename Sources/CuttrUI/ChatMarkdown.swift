import AppKit

/// An answer's Markdown, as text somebody reads rather than as typed.
///
/// A small renderer of our own, over Foundation's parser for what is inside a
/// line. What a model writes is paragraphs, lists, the odd heading and code —
/// a take's slug, a line of YAML — and those are all this draws. The fixed dark
/// palette is the reason it is not left to a system view: an attributed string
/// made by the system's Markdown initialiser carries no colours, and every
/// default it would pick is tuned for a white page.
///
/// Half an answer has to render too, because it is shown while it is being
/// written. Nothing here can fail on that: an unclosed `**` is shown as typed
/// until its other half arrives, and an unclosed fence is a code block so far.
enum ChatMarkdown {

	static let body = NSFont.systemFont(ofSize: 12.5, weight: .regular)
	static let code = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)

	static func render(_ text: String) -> NSAttributedString {
		let out = NSMutableAttributedString()
		var fenced = false
		var first = true
		func add(_ piece: NSAttributedString) {
			if !first { out.append(NSAttributedString(string: "\n")) }
			first = false
			out.append(piece)
		}
		for line in text.components(separatedBy: "\n") {
			if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
				fenced.toggle()
				continue
			}
			if fenced {
				add(NSAttributedString(string: line.isEmpty ? " " : line, attributes: [
					.font: code, .foregroundColor: Theme.text,
					.backgroundColor: Theme.background, .paragraphStyle: paragraph(indent: 8),
				]))
				continue
			}
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			let depth = CGFloat(line.prefix { $0 == " " || $0 == "\t" }.count / 2)
			if trimmed.hasPrefix("#") {
				let title = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
				add(inline(title, font: .systemFont(ofSize: 13, weight: .semibold)))
			} else if let item = bullet(trimmed) {
				let piece = NSMutableAttributedString(
					string: "\(item.mark)\t", attributes: [.font: body, .foregroundColor: Theme.dimText])
				piece.append(inline(item.text, font: body))
				piece.addAttribute(.paragraphStyle, value: paragraph(indent: 16 + depth * 14, hanging: true),
				                   range: NSRange(location: 0, length: piece.length))
				add(piece)
			} else if trimmed.hasPrefix(">") {
				let quoted = inline(trimmed.dropFirst().trimmingCharacters(in: .whitespaces), font: body)
				let piece = NSMutableAttributedString(attributedString: quoted)
				let whole = NSRange(location: 0, length: piece.length)
				piece.addAttribute(.foregroundColor, value: Theme.dimText, range: whole)
				piece.addAttribute(.paragraphStyle, value: paragraph(indent: 12), range: whole)
				add(piece)
			} else {
				add(inline(trimmed, font: body))
			}
		}
		return out
	}

	/// `- x`, `* x`, `1. x` — the mark as it should be shown, and the rest.
	private static func bullet(_ line: String) -> (mark: String, text: String)? {
		for mark in ["- ", "* ", "• "] where line.hasPrefix(mark) {
			return ("•", String(line.dropFirst(2)))
		}
		let digits = line.prefix { $0.isNumber }
		if !digits.isEmpty, digits.count <= 3, line.dropFirst(digits.count).hasPrefix(". ") {
			return ("\(digits).", String(line.dropFirst(digits.count + 2)))
		}
		return nil
	}

	private static func paragraph(indent: CGFloat, hanging: Bool = false) -> NSParagraphStyle {
		let style = NSMutableParagraphStyle()
		style.lineSpacing = 2
		style.headIndent = indent
		style.firstLineHeadIndent = hanging ? max(0, indent - 14) : indent
		if hanging { style.tabStops = [NSTextTab(textAlignment: .left, location: indent)] }
		return style
	}

	/// Bold, italic, code and links inside one line.
	private static func inline(_ text: String, font: NSFont) -> NSAttributedString {
		let plain: [NSAttributedString.Key: Any] = [
			.font: font, .foregroundColor: Theme.text, .paragraphStyle: paragraph(indent: 0),
		]
		guard let parsed = try? AttributedString(
			markdown: text,
			options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace,
			               failurePolicy: .returnPartiallyParsedIfPossible))
		else { return NSAttributedString(string: text, attributes: plain) }
		let out = NSMutableAttributedString()
		for run in parsed.runs {
			var attributes = plain
			let intent = run.inlinePresentationIntent ?? []
			if intent.contains(.code) {
				attributes[.font] = code
				attributes[.backgroundColor] = Theme.cardHigh
			} else {
				var traits: NSFontDescriptor.SymbolicTraits = []
				if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
				if intent.contains(.emphasized) { traits.insert(.italic) }
				if !traits.isEmpty {
					let descriptor = font.fontDescriptor.withSymbolicTraits(traits)
					attributes[.font] = NSFont(descriptor: descriptor, size: font.pointSize) ?? font
				}
			}
			if intent.contains(.strikethrough) {
				attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
			}
			if let link = run.link {
				attributes[.link] = link
				attributes[.foregroundColor] = Theme.cameraWave
			}
			out.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
		}
		return out
	}
}
