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
			let where_ = Self.extent(of: mark, in: resolved)?.start ?? 0
			return .within(mark, from: max(0, start - where_), to: max(0, end - where_))

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

	/// Where a mark sits on the programme's clock.
	public static func extent(
		of mark: Overlay.Span.Endpoint, in resolved: ResolvedProject
	) -> (start: Double, end: Double)? {
		switch mark {
		case .clip(let reference):
			let matching = resolved.clips.filter { $0.reference.slug == reference.slug }
			guard let first = matching.first, let last = matching.last else { return nil }
			return (first.start, last.end)
		case .group(let name):
			guard let group = resolved.groups.first(where: { $0.name == name }) else { return nil }
			return (group.start, group.end)
		}
	}
}
