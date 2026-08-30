import CuttrKit
import Foundation

/// Which clips an entry means.
///
/// A programme is rarely a list of every shot by name. Half of it is "the
/// interview, in order" and "then all the b-roll" — statements about *kinds* of
/// clip, which stay true when a thirteenth b-roll shot is cut next week. So the
/// timeline takes a query as well as a name, and the query is over the tags the
/// cutting window puts on clips.
///
/// The language is four atoms and three operators, and it is deliberately no
/// bigger:
///
///     #b-roll                every clip tagged b-roll
///     take-01/#interview     …in that take only
///     take-01/*              every clip in that take
///     "Mia 1"/#interview     …in a take whose name has a space in it
///     intro                  the clip with that slug
///     #b-roll and not #reject
///     #a-roll or #b-roll
///
/// Juxtaposition is `and`, so `#interview #keep` reads the way somebody would
/// write it. There is no ordering in the language on purpose: the order comes
/// from the clips themselves, which is what ``CuttrKit/Clip/order`` is for.
///
/// A take is named by its file name, and file names have spaces in them — but
/// a space is how this language separates two terms, so `Mia 1/#interview` is
/// two terms and matches nothing. Quote the name and it is one term again.
/// Most people meet this the other way round, by dragging a clip out of such a
/// take, and that path no longer produces a query at all — see
/// ``CuttrCompose/ClipReference/init(reference:)``.
public indirect enum ClipQuery: Sendable, Equatable {
	case tag(take: String?, String)
	case slug(take: String?, String)
	case everything(take: String?)
	case and(ClipQuery, ClipQuery)
	case or(ClipQuery, ClipQuery)
	case not(ClipQuery)

	public func matches(takeName: String, clip: Clip) -> Bool {
		switch self {
		case .tag(let take, let tag):
			return (take == nil || take == takeName) && clip.tags.contains(tag)
		case .slug(let take, let slug):
			return (take == nil || take == takeName) && clip.slug == slug
		case .everything(let take):
			return take == nil || take == takeName
		case .and(let a, let b):
			return a.matches(takeName: takeName, clip: clip) && b.matches(takeName: takeName, clip: clip)
		case .or(let a, let b):
			return a.matches(takeName: takeName, clip: clip) || b.matches(takeName: takeName, clip: clip)
		case .not(let inner):
			return !inner.matches(takeName: takeName, clip: clip)
		}
	}
}

public enum QueryError: LocalizedError {
	case empty
	case unexpected(String)
	case unclosed

	public var errorDescription: String? {
		switch self {
		case .empty: return "Empty query."
		case .unexpected(let token): return "Did not expect `\(token)` in this query."
		case .unclosed: return "A `(` in this query is never closed."
		}
	}
}

public enum QueryParser {

	public static func parse(_ text: String) throws -> ClipQuery {
		var tokens = tokenize(text)
		guard !tokens.isEmpty else { throw QueryError.empty }
		let query = try expression(&tokens)
		guard tokens.isEmpty else { throw QueryError.unexpected(tokens[0]) }
		return query
	}

	/// Everything is one token except the operators and the brackets, so an
	/// atom keeps its `/`, `#` and `*` and is picked apart afterwards.
	///
	/// Quotes suppress every one of those rules for as long as they are open,
	/// which is the only way to name a take called `Mia 1` in a language whose
	/// separator is the space. They are taken off here rather than in ``atom``,
	/// so that by the time anything is picked apart a quoted name is an
	/// ordinary run of characters and nothing downstream has to know.
	static func tokenize(_ text: String) -> [String] {
		var tokens: [String] = []
		var current = ""
		// Non-nil while inside quotes, holding the mark that will close them —
		// so a name may contain the other kind without escaping it.
		var quote: Character?
		// Set by the quotes themselves: `""` is an empty take name, which is
		// not the same as no token at all, and `current` alone cannot tell
		// those apart.
		var quoted = false
		for character in text {
			if let open = quote {
				if character == open { quote = nil } else { current.append(character) }
			} else if character == "\"" || character == "'" {
				quote = character
				quoted = true
			} else if character == "(" || character == ")" {
				if !current.isEmpty || quoted { tokens.append(current); current = ""; quoted = false }
				tokens.append(String(character))
			} else if character.isWhitespace {
				if !current.isEmpty || quoted { tokens.append(current); current = ""; quoted = false }
			} else {
				current.append(character)
			}
		}
		// An unclosed quote runs to the end of the line rather than throwing:
		// the term it makes is the one somebody was in the middle of typing,
		// and refusing to read it would empty the field they are typing into.
		if !current.isEmpty || quoted { tokens.append(current) }
		return tokens
	}

	private static func expression(_ tokens: inout [String]) throws -> ClipQuery {
		var left = try term(&tokens)
		while let next = tokens.first, next.lowercased() == "or" || next == "|" {
			tokens.removeFirst()
			left = .or(left, try term(&tokens))
		}
		return left
	}

	private static func term(_ tokens: inout [String]) throws -> ClipQuery {
		var left = try factor(&tokens)
		while let next = tokens.first {
			if next.lowercased() == "and" || next == "&" {
				tokens.removeFirst()
				left = .and(left, try factor(&tokens))
			} else if next.lowercased() == "or" || next == "|" || next == ")" {
				break
			} else {
				// Juxtaposition. `#interview #keep` is an `and`, because that
				// is how anybody would read two labels side by side.
				left = .and(left, try factor(&tokens))
			}
		}
		return left
	}

	private static func factor(_ tokens: inout [String]) throws -> ClipQuery {
		guard let token = tokens.first else { throw QueryError.empty }
		if token.lowercased() == "not" || token == "!" {
			tokens.removeFirst()
			return .not(try factor(&tokens))
		}
		if token == "(" {
			tokens.removeFirst()
			let inner = try expression(&tokens)
			guard tokens.first == ")" else { throw QueryError.unclosed }
			tokens.removeFirst()
			return inner
		}
		if token == ")" { throw QueryError.unexpected(token) }
		tokens.removeFirst()
		return atom(token)
	}

	static func atom(_ token: String) -> ClipQuery {
		var take: String?
		var rest = token
		if let slash = token.firstIndex(of: "/") {
			take = String(token[token.startIndex ..< slash])
			rest = String(token[token.index(after: slash)...])
		}
		if rest == "*" { return .everything(take: take) }
		if rest.hasPrefix("#") {
			return .tag(take: take, Slug.make(from: String(rest.dropFirst())))
		}
		return .slug(take: take, Slug.make(from: rest))
	}
}
