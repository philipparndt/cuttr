import Foundation

/// Merging two people's edits to one take.
///
/// **Why not git's own merge.** Git merges lines. Two clips written next to each
/// other in the file are adjacent lines, so two people cutting two different
/// shots collide over nothing at all — and when git does give up it writes
/// conflict markers into the file, which a `.cuttr` reader cannot parse. The
/// person is then looking at a broken project, having done nothing wrong.
///
/// So the merge happens up here, on values. A clip carries a slug, the slug is a
/// *reference* and not a label, and that makes it the key: two edits are the
/// same edit only when they are to the same slug. Everything else composes
/// without anybody being asked anything.
///
/// **This returns a value and never text.** `TakeWriter` stays the only thing
/// that writes a take — it is what fixes key order, column alignment and
/// quoting, and a merge that emitted its own text would be a second emitter to
/// keep in step. `aMergedTakeReSavesUnchanged` holds that down.
///
/// Nothing here touches ``Take/comments`` or a document's manual slugs. A
/// comment is addressed by what its line says and is spliced in by the writer;
/// a manual slug is a fact about the session and is not in the file.
public enum TakeMerge {

	/// One thing the two sides disagree about, and the only kind of thing
	/// anybody is asked about.
	public struct Conflict: Sendable, Equatable, Identifiable {

		/// What is being disagreed over.
		public enum Subject: Sendable, Equatable {
			/// Both changed the same clip, differently. `nil` on a side means
			/// that side removed it.
			case clip(slug: String, mine: Clip?, theirs: Clip?)
			/// Both pointed the take at a different recording.
			case video(mine: String?, theirs: String?)
			/// Both aligned the separate recorder differently. The offset is
			/// the only thing relating the two clocks, so this one matters more
			/// than its size suggests.
			case audio(mine: AudioTrack?, theirs: AudioTrack?)
			/// Both named a different transcript sidecar.
			case words(mine: Words?, theirs: Words?)
		}

		public var subject: Subject

		/// A stable handle for the row in the chooser.
		public var id: String {
			switch subject {
			case .clip(let slug, _, _): return "clip:\(slug)"
			case .video: return "video"
			case .audio: return "audio"
			case .words: return "words"
			}
		}

		/// What to call it, in the words the program uses. A clip is named by
		/// its name where it has one and by its slug otherwise, because a slug
		/// alone is a usable clip and reads perfectly well.
		public var title: String {
			switch subject {
			case .clip(let slug, let mine, let theirs):
				let name = mine?.name.isEmpty == false ? mine?.name
					: (theirs?.name.isEmpty == false ? theirs?.name : nil)
				return name ?? slug
			case .video: return "the video"
			case .audio: return "the recorder's alignment"
			case .words: return "the transcript"
			}
		}
	}

	/// Which side to keep, for a conflict somebody has answered.
	public enum Side: Sendable, Equatable { case mine, theirs }

	/// What came of merging.
	///
	/// `take` is always usable: everything that merged cleanly is in it, and
	/// each conflict is left holding *my* side until somebody says otherwise.
	/// That is deliberate — a half-merged file must never be worse than the one
	/// the person already had.
	public struct Merged: Sendable {
		public var take: Take
		public var conflicts: [Conflict]
		public var isClean: Bool { conflicts.isEmpty }
	}

	// MARK: - Merging

	/// Three-way merge. `base` is the last version both sides had; `nil` when
	/// there is none, which makes every difference a conflict rather than a
	/// guess about who added what.
	public static func merge(base: Take?, mine: Take, theirs: Take) -> Merged {
		var out = mine
		var conflicts: [Conflict] = []

		// --- The clips, by slug ------------------------------------------
		let (clips, clipConflicts) = mergeClips(base: base, mine: mine, theirs: theirs)
		out.clips = clips
		conflicts += clipConflicts

		// --- The take-level keys, each on its own -------------------------
		//
		// Separately, and this is the point of doing it at all: one person
		// re-aligning the recorder while another re-cuts a clip is two edits to
		// two different things, and merging the take as one block would call
		// that a conflict.
		switch pick(base?.video, mine.video, theirs.video) {
		case .settled(let value): out.video = value
		case .disputed: conflicts.append(.init(subject: .video(mine: mine.video,
		                                                       theirs: theirs.video)))
		}
		switch pick(base?.audio, mine.audio, theirs.audio) {
		case .settled(let value): out.audio = value
		case .disputed: conflicts.append(.init(subject: .audio(mine: mine.audio,
		                                                       theirs: theirs.audio)))
		}
		switch pick(base?.words, mine.words, theirs.words) {
		case .settled(let value): out.words = value
		case .disputed: conflicts.append(.init(subject: .words(mine: mine.words,
		                                                       theirs: theirs.words)))
		}

		// --- The rest ------------------------------------------------------
		//
		// Lists nobody edits concurrently in practice, taken whole from
		// whichever side moved. Not conflicted when both did: the last of these
		// to be a real collision is worth less than an alert somebody cannot
		// act on, and the version branch has the way back.
		out.anchors = takeWhicheverMoved(base?.anchors, mine.anchors, theirs.anchors)
		out.speakers = takeWhicheverMoved(base?.speakers, mine.speakers, theirs.speakers)
		out.sounds = takeWhicheverMoved(base?.sounds, mine.sounds, theirs.sounds)
		out.levels = takeWhicheverMoved(base?.levels, mine.levels, theirs.levels)
		out.gain = pick(base?.gain, mine.gain, theirs.gain).value ?? mine.gain
		out.source = pick(base?.source, mine.source, theirs.source).value ?? mine.source
		out.look = pick(base?.look, mine.look, theirs.look).value ?? mine.look
		out.measured = pick(base?.measured, mine.measured, theirs.measured).value ?? mine.measured

		// --- What neither build understands ---------------------------------
		//
		// The house rule: a file written by a later version has to survive being
		// opened and saved by an older one. A key only one side carries is kept;
		// mine wins a collision, because a collision means both sides wrote it
		// and there is nothing here that could read either.
		var unknown = theirs.unknownKeys
		for (key, value) in mine.unknownKeys { unknown[key] = value }
		out.unknownKeys = unknown

		return Merged(take: out, conflicts: conflicts)
	}

	/// Applies somebody's answers. Anything unanswered keeps my side, which is
	/// what ``Merged/take`` already holds.
	public static func resolve(_ merged: Merged, choosing choices: [String: Side]) -> Take {
		var take = merged.take
		for conflict in merged.conflicts {
			guard choices[conflict.id] == .theirs else { continue }
			switch conflict.subject {
			case .clip(let slug, _, let theirs):
				// In place. Removing and appending would move the clip to the
				// end of the file, and a merge that reorders lines nobody
				// touched is the churn the emitter exists to prevent.
				if let at = take.clips.firstIndex(where: { $0.slug == slug }) {
					if let theirs { take.clips[at] = theirs } else { take.clips.remove(at: at) }
				} else if let theirs {
					// I had removed it and they had not, so it comes back — and
					// the end is the only honest place for it.
					take.clips.append(theirs)
				}
			case .video(_, let theirs):
				take.video = theirs
			case .audio(_, let theirs):
				take.audio = theirs
			case .words(_, let theirs):
				take.words = theirs
			}
		}
		return take
	}

	// MARK: - The clip list

	private static func mergeClips(base: Take?, mine: Take,
	                               theirs: Take) -> ([Clip], [Conflict]) {
		func indexed(_ clips: [Clip]) -> [String: Clip] {
			Dictionary(clips.map { ($0.slug, $0) }, uniquingKeysWith: { a, _ in a })
		}
		let b = base.map { indexed($0.clips) } ?? [:]
		let m = indexed(mine.clips), t = indexed(theirs.clips)

		// Mine first, in the order the file has them, then whatever they added,
		// in theirs. A merge that reordered the file would churn every diff.
		var order = mine.clips.map(\.slug)
		order += theirs.clips.map(\.slug).filter { m[$0] == nil }

		var clips: [Clip] = []
		var conflicts: [Conflict] = []
		for slug in order {
			switch pick(base == nil ? nil : b[slug], m[slug], t[slug]) {
			case .settled(let clip):
				if let clip { clips.append(clip) }
			case .disputed:
				// Mine is kept in the file until somebody chooses, so the take
				// on disk is never worse than the one they had.
				if let mine = m[slug] { clips.append(mine) }
				conflicts.append(.init(subject: .clip(slug: slug, mine: m[slug],
				                                      theirs: t[slug])))
			}
		}
		return (clips, conflicts)
	}

	// MARK: - The rule, once

	private enum Choice<T> {
		case settled(T)
		case disputed

		var value: T? {
			if case .settled(let v) = self { return v }
			return nil
		}
	}

	/// The whole of three-way merging, for one value.
	///
	/// Agreeing is not a conflict even when both sides changed it — two people
	/// trimming a clip to the same frame have not disagreed about anything. And
	/// with no base, anything the two sides differ over is disputed: there is
	/// no way to tell an addition from a removal without one, and guessing is
	/// how a merge silently drops somebody's work.
	private static func pick<T: Equatable>(_ base: T?, _ mine: T, _ theirs: T) -> Choice<T> {
		if mine == theirs { return .settled(mine) }
		guard let base else { return .disputed }
		if base == mine { return .settled(theirs) }
		if base == theirs { return .settled(mine) }
		return .disputed
	}

	/// For the lists that are taken whole rather than merged element by element.
	private static func takeWhicheverMoved<T: Equatable>(_ base: T?, _ mine: T, _ theirs: T) -> T {
		if mine == theirs { return mine }
		guard let base else { return mine }
		if base == mine { return theirs }
		return mine
	}
}
