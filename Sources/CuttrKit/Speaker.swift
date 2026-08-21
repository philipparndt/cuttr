import Foundation

/// Somebody who talks in a take.
///
/// A slug and a name, for the same reason a clip has both: the slug is what
/// the sidecar's thousands of lines point at, and the name is prose somebody
/// may rewrite at any time. Renaming a speaker is therefore one line changed
/// in the take file and nothing at all in the transcript beside it — which is
/// what "renaming a speaker renames them everywhere" has to mean if it is not
/// to be four hundred edits.
///
/// **Where they live.** In the take file, under `speakers:`, because a take is
/// one recording and the people in it are a fact about that recording. Not in
/// the sidecar: the sidecar is a measurement that a recogniser wrote and that
/// somebody may ask for again, and the cast should survive that.
///
/// **A speaker is not an anchor**, though they may be the same person. An
/// ``Anchor`` is a face followed through the picture, and the person asking the
/// questions is usually behind the camera and has no face to follow. Where a
/// speaker's slug and an anchor's name agree, they are the same person and
/// nothing has to be said twice; where they do not, neither list is wrong.
public struct Speaker: Sendable, Equatable {

	/// What the sidecar refers to them by. Lower-case, hyphenated.
	public var slug: String

	/// What a person reads. May be empty, in which case the slug is shown —
	/// a cast of `mia` and `papa` is perfectly usable without anybody typing
	/// the names out.
	public var name: String

	public init(slug: String, name: String = "") {
		self.slug = Slug.make(from: slug)
		self.name = name
	}

	/// What to show. The name when there is one, and the slug otherwise.
	public var title: String { name.isEmpty ? slug : name }

	/// The slug for a voice nobody has put a name to.
	///
	/// Reserved, and not the same thing as a line nobody has answered. An
	/// unanswered line is a question still open; `unknown` is an answer —
	/// somebody off camera, a voice from the next room, a child who is not in
	/// the cast and is not going to be. Keeping the two apart is what lets the
	/// pane say what is left to label, and it is why this is a slug in the
	/// words rather than a blank.
	///
	/// It is not in the take's cast and takes no colour from the palette: a
	/// colour says "this person", and the whole point of this one is that
	/// nobody knows who it is.
	public static let unknown = "unknown"

	// MARK: - Colour

	/// The palette, in the order speakers take it.
	///
	/// Not ``ClipColor/allCases``, which starts green and puts rose beside
	/// amber. Two speakers is the ordinary case and blue against amber is the
	/// one pair on this palette that survives every kind of colour blindness;
	/// teal and rose are next, and green is last for three reasons: it is the
	/// clip default, it is the hardest to tell from amber for a deuteranope,
	/// and the sound events in the same pane are already drawn in a green of
	/// their own. Six speakers in one take is where those collide, and by then
	/// the names in the margin are doing the work anyway.
	///
	/// Hue is never the only thing marking a speaker in any case: the pane puts
	/// their name at the head of every line. Colour is what makes a page of
	/// text scannable, not what makes it readable.
	public static let palette: [ClipColor] = [.blue, .amber, .teal, .rose, .violet, .green]

	/// What colour a speaker is drawn in, given who else is in the take.
	///
	/// Derived rather than stored, and this is the whole reason the file has no
	/// `color:` under a speaker: a colour in the file is one more thing to keep
	/// in step, and the first time somebody hand-edits the cast it is out of
	/// step. The hash of the slug picks a colour, and the cast order settles a
	/// tie — so the answer is the same in every session and on every machine,
	/// and it changes only when the cast does.
	public static func colors(for cast: [String]) -> [String: ClipColor] {
		var taken = Set<ClipColor>()
		var out: [String: ClipColor] = [:]
		for slug in cast where out[slug] == nil && slug != unknown {
			let first = Int(hash(slug) % UInt64(palette.count))
			var chosen = palette[first]
			for step in 0 ..< palette.count {
				let candidate = palette[(first + step) % palette.count]
				if !taken.contains(candidate) { chosen = candidate; break }
			}
			taken.insert(chosen)
			out[slug] = chosen
		}
		return out
	}

	/// One speaker's colour with nobody else to consider.
	public static func color(of slug: String) -> ClipColor {
		palette[Int(hash(slug) % UInt64(palette.count))]
	}

	/// FNV-1a, written out rather than `hashValue`.
	///
	/// Swift seeds `Hashable` per process, so `hashValue` gives a different
	/// answer every launch — a speaker would be blue this morning and rose
	/// this afternoon, which is exactly the sort of thing that makes somebody
	/// stop trusting the colours.
	static func hash(_ text: String) -> UInt64 {
		var h: UInt64 = 0xcbf2_9ce4_8422_2325
		for byte in text.utf8 {
			h ^= UInt64(byte)
			h = h &* 0x0000_0100_0000_01b3
		}
		return h
	}
}
