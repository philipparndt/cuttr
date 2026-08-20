import Foundation

/// Moving an overlay from one place in the file to another.
///
/// The tree shows overlays under the entries they are drawn over, so dragging
/// one from a clip to a section — or out to the top-level list — is a thing
/// somebody can do with a mouse. What that has to *write* is not obvious, and
/// getting it wrong is the worst kind of wrong: a caption that quietly moves to
/// a different part of the programme while the row it was dragged to says it
/// did what was asked.
///
/// Here rather than in the panel because it is arithmetic with a right answer,
/// and a window cannot be tested.
extension Project {

	/// Where an overlay lives: the top-level list, or one timeline entry.
	///
	/// `nil` is the top-level list. Not a type of its own, because a home is
	/// exactly an ``OverlayOrigin`` with the index taken off, and a second name
	/// for that would be a second thing to keep in step.
	public typealias OverlayHome = [Int]?

	/// The home an origin is in.
	public static func home(of origin: OverlayOrigin) -> OverlayHome {
		switch origin {
		case .project: return nil
		case .entry(let path, _): return path
		}
	}

	/// Adds one where it will live, and says where it landed.
	@discardableResult
	public mutating func addOverlay(_ overlay: Overlay, into home: OverlayHome) -> OverlayOrigin? {
		guard let path = home else {
			overlays.append(overlay)
			return .project(overlays.count - 1)
		}
		guard entry(at: path) != nil else { return nil }
		var landed: Int?
		modify(at: path) { list, at in
			list[at].overlays.append(overlay)
			landed = list[at].overlays.count - 1
		}
		return landed.map { .entry(path: path, index: $0) }
	}

	/// Moves one to another home, keeping when it is on screen.
	///
	/// Two different things happen, and which is which is the whole of this
	/// function:
	///
	/// **Into an entry**, the overlay comes to cover that placement — its own
	/// range is dropped. That is what putting it there *means*: a caption
	/// dragged onto a shot is somebody saying it belongs to that shot, and
	/// keeping `from: 00:10.000` would make the drag do nothing anybody could
	/// see. Narrowing it again is a field in the properties panel.
	///
	/// **Out to the top level**, it must go on being on screen at exactly the
	/// moments it already is, because nothing about the drag said otherwise.
	/// An overlay that was covering its placement has no range to carry with
	/// it, so it is given one that means the same thing.
	@discardableResult
	public mutating func moveOverlay(
		at origin: OverlayOrigin, into home: OverlayHome, in resolved: ResolvedProject?
	) -> OverlayOrigin? {
		guard var overlay = overlay(at: origin) else { return nil }
		if Self.home(of: origin) == home { return origin }

		if home == nil, overlay.appearances.isEmpty {
			guard let span = spanCovering(Self.home(of: origin), in: resolved) else { return nil }
			overlay.appearances = [Overlay.Appearance(span)]
		} else if home != nil {
			overlay.appearances = []
		}

		removeOverlay(at: origin)
		// Removing from the top-level list shifts everything after it down, and
		// the destination path is a path into the timeline, so it is unaffected
		// either way — an entry's own position does not move when one of its
		// overlays goes.
		return addOverlay(overlay, into: home)
	}

	/// A range that means "exactly what this entry lays down", written the way
	/// the file would write it.
	///
	/// The entry's own name where it has one, because a name is what survives a
	/// re-cut and that is the whole reason spans are bound to marks. Programme
	/// times where it has not — a card with no `as:`, a list, a query — and
	/// also where the name would be *wrong*: `from: intro` finds every use of
	/// `intro`, so a clip that is on the timeline twice cannot be named without
	/// silently widening the caption to cover both.
	///
	/// That last check needs the programme laid out, and there is not always
	/// one: a project whose takes have gone missing still opens, and its tree
	/// can still be dragged about. Without it the name is the best that can be
	/// said, and it is exactly what somebody writing the line by hand would
	/// have written. With neither a name nor a layout there is nothing true to
	/// write, and the move is refused rather than guessed at.
	private func spanCovering(_ home: OverlayHome, in resolved: ResolvedProject?)
		-> Overlay.Span?
	{
		guard let path = home, let entry = entry(at: path) else { return nil }
		let extent = resolved.flatMap { Self.extent(of: path, in: $0) }

		var name: Overlay.Span.Endpoint?
		if let label = entry.label {
			name = .group(label)
		} else if case .group(let group, _) = entry.source {
			name = .group(group)
		} else if case .clip(let reference) = entry.source {
			name = .clip(reference)
		}

		if let name {
			guard let resolved, let extent else { return .marks(from: name, to: name) }
			let where_ = Overlay.Span.extent(of: name, in: resolved)
			if let where_, abs(where_.start - extent.start) < 1e-6,
			   abs(where_.end - extent.end) < 1e-6 {
				return .marks(from: name, to: name)
			}
		}
		guard let extent else { return nil }
		return .times(from: extent.start, to: extent.end)
	}

	/// Where a timeline entry sits on the programme's clock, once it is laid
	/// out — a clip, a card, or a section with everything inside it.
	public static func extent(of path: [Int], in resolved: ResolvedProject)
		-> (start: Double, end: Double)?
	{
		let inside = resolved.clips.filter { $0.entry.starts(with: path) }.map { ($0.start, $0.end) }
			+ resolved.cards.filter { $0.entry.starts(with: path) }.map { ($0.start, $0.end) }
		guard let first = inside.map(\.0).min(), let last = inside.map(\.1).max() else { return nil }
		return (first, last)
	}
}
