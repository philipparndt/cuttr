import Foundation

/// Moving a span on the programme's clock, and writing it back the way it was
/// written.
///
/// A drag on a timeline produces two numbers: where the bar starts and ends now.
/// What goes in the file is not those numbers — it is whatever the span was
/// already saying, moved: a range bound to a clip is bound to whichever clip it
/// now covers, a stretch of a clip keeps its "so many seconds in", and only a
/// range that asked for programme times gets programme times. Anything else
/// would quietly convert somebody's re-cut-proof caption into one that is not.
///
/// Here rather than in the window because it is arithmetic with a right answer,
/// and a window cannot be tested.
extension Overlay.Span {

	public func moved(start: Double, end: Double, in resolved: ResolvedProject) -> Overlay.Span {
		switch self {
		case .times:
			return .times(from: start, to: end)

		case .within(let mark, _, _):
			// The use of the clip the drag landed in, not whichever came first.
			let where_ = mark.place(in: resolved, nearest: start)?.start ?? 0
			return .within(mark, from: max(0, start - where_), to: max(0, end - where_))
				.clamped(in: resolved, nearest: start)

		case .marks:
			// Snapped to the clips it now covers: a caption that belonged to a
			// clip should still belong to a clip afterwards rather than to 4.28
			// seconds.
			let clips = resolved.clips
			guard let first = clips.last(where: { $0.start <= start + 0.001 }) ?? clips.first,
			      let last = clips.last(where: { $0.start < end - 0.001 }) ?? clips.first
			else { return self }
			return .marks(from: .clip(first.reference), to: .clip(last.reference))
		}
	}

	/// A range that cannot be outside the thing it is written inside.
	///
	/// A `within:` is "so many seconds into that shot", so a `to:` past the
	/// shot's own end is not a long overlay — it is a number the programme has
	/// nowhere to put. The panel let one be typed, dragged and copied: `+
	/// range` moved the last range along by its own length whether or not the
	/// clip had another length to give.
	///
	/// `moment` says which use of the clip this is about when a clip is in the
	/// programme more than once. Anything but a `within:` is returned as it is:
	/// programme times mean what they say, and a mark-bound range takes its
	/// length from the marks.
	public func clamped(in resolved: ResolvedProject, nearest moment: Double? = nil) -> Overlay.Span {
		guard case .within(let mark, let from, let to) = self,
		      let place = mark.place(in: resolved, nearest: moment) else { return self }
		let length = max(0, place.end - place.start)
		let start = min(max(0, from), length)
		return .within(mark, from: start, to: min(max(start, to), length))
	}
}

extension Overlay.Span {

	/// What to write for an overlay that lives **inside** a timeline entry,
	/// after a drag put its ends here.
	///
	/// Absolute programme times are the wrong answer for one of these, and it
	/// has already cost a real project its placements. An overlay written inside
	/// a clip with no range *covers* that clip and follows it through every
	/// re-cut. Dragging its bar used to convert that into `from:`/`to:` on the
	/// programme's clock — after which the first change anywhere upstream moved
	/// the clip and left the overlay behind. Three spinners ended up five
	/// seconds early, playing over the shot before the one they were written
	/// on, and because the file was perfectly intact there was nothing to see.
	///
	/// So a drag on one of these is written *relative to the clip it is inside*,
	/// which is the same drag and survives the re-cut. `nil` when the entry has
	/// no clip to be relative to — a card, or a section — and then the caller's
	/// ordinary arithmetic stands and the resolver's warning is the safety net.
	public static func inside(
		_ entry: TimelineEntry, start: Double, end: Double, in resolved: ResolvedProject
	) -> Overlay.Span? {
		guard case .clip(let reference) = entry.source,
		      let place = Endpoint.clip(reference).place(in: resolved, nearest: start)
		else { return nil }
		return Overlay.Span
			.within(.clip(reference), from: start - place.start, to: end - place.start)
			.clamped(in: resolved, nearest: start)
	}
}

extension Overlay.Span.Endpoint {

	/// Where this mark is on the programme's clock — once for each time it is
	/// there.
	///
	/// **A clip used twice is two places, not one long one.** Answering with
	/// the first start and the last end covers everything in between, which for
	/// a shot used in the opening and again at the end is most of the film: a
	/// bubble written inside a four-second clip was offered ninety-six seconds
	/// of programme to aim at, and its `to:` could be written past the clip
	/// altogether.
	///
	/// ``Resolver`` has always had this right — it puts such an overlay on once
	/// per use — and it calls this. Which is the point of it being here: the
	/// panel, the drag and the render were three functions answering the same
	/// question, and two of them were wrong.
	public func places(
		in clips: [ResolvedClip], group: (String) -> (start: Double, end: Double)?
	) -> [(start: Double, end: Double)] {
		switch self {
		case .clip(let reference):
			return clips
				.filter {
					$0.reference.slug == reference.slug
						&& (reference.take == nil || $0.takeName == reference.take)
				}
				.map { ($0.start, $0.end) }
		case .group(let name):
			return group(name).map { [$0] } ?? []
		}
	}

	public func places(in resolved: ResolvedProject) -> [(start: Double, end: Double)] {
		places(in: resolved.clips) { name in
			resolved.groups.first { $0.name == name }.map { ($0.start, $0.end) }
		}
	}

	/// The one use of this mark that a moment is inside — or the first, when
	/// there is no moment to go on.
	///
	/// Which use a `within:` is about is decided by where the overlay is, not
	/// by which use came first: an overlay written inside the second placement
	/// of a clip is about that placement.
	public func place(
		in resolved: ResolvedProject, nearest moment: Double? = nil
	) -> (start: Double, end: Double)? {
		let all = places(in: resolved)
		guard let moment else { return all.first }
		return all.first { moment >= $0.start - 0.001 && moment <= $0.end + 0.001 }
			?? all.min { abs($0.start - moment) < abs($1.start - moment) }
	}
}
