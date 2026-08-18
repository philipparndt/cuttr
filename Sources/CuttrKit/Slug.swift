import Foundation

/// The name a clip is referenced by from the assembly file.
///
/// This is the part of a clip that another file depends on, so it is the part
/// that has to be stable, unambiguous and typeable: lower-case ASCII, digits
/// and single hyphens. A clip's *name* is prose and may say anything; the slug
/// is an identifier and is treated like one.
public enum Slug {

	/// Derives a slug from a display name.
	///
	/// Accents are folded rather than dropped — `Präzision` becomes
	/// `praezision` via the locale-aware fold, not `przision`, which is what a
	/// plain strip of non-ASCII would leave and is unreadable in a reference.
	public static func make(from text: String) -> String {
		// German first, because these four are the ones that occur here and
		// `folding` maps ä to a rather than to ae. Applied before folding, so
		// the rest of the world's diacritics still get the general treatment.
		var s = text.lowercased()
		for (from, to) in [("ä", "ae"), ("ö", "oe"), ("ü", "ue"), ("ß", "ss")] {
			s = s.replacingOccurrences(of: from, with: to)
		}
		s = s.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US"))

		var out = ""
		var pendingHyphen = false
		for ch in s.unicodeScalars {
			if allowed.contains(ch) {
				if pendingHyphen && !out.isEmpty { out.append("-") }
				pendingHyphen = false
				out.unicodeScalars.append(ch)
			} else {
				// Runs of anything else collapse to one hyphen, and a run at
				// either end produces none: the hyphen is only written once a
				// character follows it.
				pendingHyphen = true
			}
		}
		return out
	}

	private static let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")

	/// Is this something the assembly file can reference?
	public static func isValid(_ slug: String) -> Bool {
		!slug.isEmpty && slug == make(from: slug)
	}

	/// The slug a clip gets when it has no name yet: `clip-1`, `clip-2`, …
	///
	/// Numbered from one, and numbered *always* — not `clip`, `clip-2`, which is
	/// what ``unique(_:taken:)`` would give and which reads as though the first
	/// one were special. These are placeholders in a list somebody is about to
	/// work through, and a list that starts at one is a list you can count.
	///
	/// The number is the lowest free one rather than a running count, so
	/// deleting `clip-2` and marking another gives `clip-2` back instead of
	/// leaving a hole and reaching for `clip-9`.
	public static func numbered(_ prefix: String = "clip", taken: Set<String>) -> String {
		var n = 1
		while taken.contains("\(prefix)-\(n)") { n += 1 }
		return "\(prefix)-\(n)"
	}

	/// Makes `slug` unique against `taken`, by suffixing `-2`, `-3`, …
	///
	/// Starting at 2 rather than 1 because the first one has no suffix: the
	/// pair reads `intro`, `intro-2`, which is how anybody would number them by
	/// hand.
	public static func unique(_ slug: String, taken: Set<String>) -> String {
		let base = slug.isEmpty ? "clip" : slug
		guard taken.contains(base) else { return base }
		var n = 2
		while taken.contains("\(base)-\(n)") { n += 1 }
		return "\(base)-\(n)"
	}
}
