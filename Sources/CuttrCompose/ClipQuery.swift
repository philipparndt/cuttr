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
///     intro                  the clip with that slug
///     #b-roll and not #reject
///     #a-roll or #b-roll
///
/// Juxtaposition is `and`, so `#interview #keep` reads the way somebody would
/// write it. There is no ordering in the language on purpose: the order comes
/// from the clips themselves, which is what ``CuttrKit/Clip/order`` is for.
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
	static func tokenize(_ text: String) -> [String] {
		var tokens: [String] = []
		var current = ""
		for character in text {
			if character == "(" || character == ")" {
				if !current.isEmpty { tokens.append(current); current = "" }
				tokens.append(String(character))
			} else if character.isWhitespace {
				if !current.isEmpty { tokens.append(current); current = "" }
			} else {
				current.append(character)
			}
		}
		if !current.isEmpty { tokens.append(current) }
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
