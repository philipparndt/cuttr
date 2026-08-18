import CoreGraphics
import Foundation

/// A point in the picture that something is pinned to.
///
/// **In the take, not the project.** Where somebody's eye is in a recording is a
/// fact about the recording: it is the same fact in every programme that uses
/// the clip, and it is discovered while looking at the footage — which is what
/// the cutting window is for. Anchors used to live in the project, which meant
/// re-marking and re-solving the same face for every programme it appeared in,
/// and it showed: the anchor already had to name the take clip it belonged to.
///
/// Marked once — click an eye, at a moment — and then followed through the clip
/// by ``AnchorSolver``. The solved path is a lot of numbers and does not belong
/// in the take file, so it goes in a sidecar the take names; the take keeps only
/// what a person wrote.
public struct Anchor: Sendable, Equatable {
	public var name: String
	/// The span of the take it was solved over, on the take's own clock.
	///
	/// **Not a clip.** An anchor used to belong to one subclip, which meant the
	/// same face had to be marked and solved again for every clip it appeared
	/// in, and re-cutting a clip invalidated its tracking. A face is in the
	/// footage for as long as it is in the footage; where the cuts fall is a
	/// separate decision, made later and changed often.
	///
	/// So the range is the *shot* — however long the tracker could follow the
	/// face from where it was marked — and any subclip overlapping it gets to
	/// use it, however many of them there are.
	public var from: Double
	public var to: Double
	/// When it was marked, on the take's clock.
	public var markedAt: Double
	/// Where it was marked, normalised, origin bottom-left.
	public var point: CGPoint
	public var method: Method
	/// The sidecar holding the solved path, relative to the take file.
	public var path: String?

	public enum Method: String, Sendable, CaseIterable {
		/// Vision finds the face and locks to the eye landmark nearest the
		/// click, then follows that landmark. What heads are for.
		case faceLandmark = "face-landmark"
		/// A box round whatever was clicked, followed by the general tracker.
		/// For things that are not faces, and for faces Vision loses.
		case point
	}

	public var range: ClosedRange<Double> { from ... Swift.max(to, from) }

	public func covers(_ time: Double) -> Bool { range.contains(time) }

	public init(
		name: String, from: Double, to: Double, markedAt: Double,
		point: CGPoint, method: Method = .faceLandmark, path: String? = nil
	) {
		self.name = name
		self.from = from
		self.to = to
		self.markedAt = markedAt
		self.point = point
		self.method = method
		self.path = path
	}
}

/// Where an anchor is, moment by moment.
///
/// Sampled rather than per-frame, and interpolated in between. A head does not
/// move at 25 Hz worth of detail, Vision costs tens of milliseconds a frame, and
/// a path sampled at 10 Hz over a two-minute clip is 1,200 lines — a file
/// somebody can open, read, and correct a bad frame in by hand. Per-frame it
/// would be 3,000 lines of the same curve.
public struct AnchorPath: Sendable, Equatable {
	/// Times on the take's clock, ascending, and the point at each.
	public var samples: [(time: Double, point: CGPoint)]

	/// The spans this path actually has data for.
	///
	/// One span for a path straight out of the solver — a shot is continuous.
	/// Several once a path has been laid onto a programme, where the same shot
	/// may appear as three subclips with other material between them: the
	/// samples are still one ascending list, but the stretches in between are
	/// not covered and a marker must not be drawn there.
	public var covered: [ClosedRange<Double>]

	public init(samples: [(time: Double, point: CGPoint)] = [],
	            covered: [ClosedRange<Double>]? = nil) {
		let sorted = samples.sorted { $0.time < $1.time }
		self.samples = sorted
		if let covered {
			self.covered = covered
		} else if let first = sorted.first, let last = sorted.last, first.time <= last.time {
			self.covered = [first.time ... last.time]
		} else {
			self.covered = []
		}
	}

	public static func == (a: AnchorPath, b: AnchorPath) -> Bool {
		a.covered == b.covered && a.samples.count == b.samples.count
			&& zip(a.samples, b.samples).allSatisfy { $0.time == $1.time && $0.point == $1.point }
	}

	public var isEmpty: Bool { samples.isEmpty }

	/// The whole extent, ends included.
	public var timeRange: ClosedRange<Double>? {
		guard let first = covered.first, let last = covered.last else { return nil }
		return first.lowerBound ... last.upperBound
	}

	/// Is there data here?
	///
	/// Worth asking rather than inferring from ``point(at:)``, which clamps:
	/// outside the solved range it answers "where it last was", which is the
	/// right answer for a renderer and a misleading one for a marker on screen.
	/// A ring frozen over somebody's shoulder three minutes before the shot
	/// begins looks exactly like a tracker that has failed.
	public func covers(_ time: Double) -> Bool {
		covered.contains { $0.contains(time) }
	}

	/// The point at a time, linearly between samples and clamped at the ends.
	///
	/// Clamped rather than extrapolated: past the end of what was solved, the
	/// honest answer is "where it last was", and a line continued off the edge
	/// of the frame is a spinner that flies away.
	public func point(at time: Double) -> CGPoint? {
		guard let first = samples.first, let last = samples.last else { return nil }
		if time <= first.time { return first.point }
		if time >= last.time { return last.point }
		// Binary search: this is asked once per rendered frame per overlay.
		var low = 0, high = samples.count - 1
		while high - low > 1 {
			let mid = (low + high) / 2
			if samples[mid].time <= time { low = mid } else { high = mid }
		}
		let (a, b) = (samples[low], samples[high])
		let span = b.time - a.time
		guard span > 0 else { return a.point }
		let t = (time - a.time) / span
		return CGPoint(x: a.point.x + (b.point.x - a.point.x) * t,
		               y: a.point.y + (b.point.y - a.point.y) * t)
	}

	/// This path with another laid into it.
	///
	/// What "continue from here" produces. A tracker that loses a face — she
	/// turns away, somebody walks in front, the shot goes wide — stops, and the
	/// honest record of that is a path with a hole in it rather than a path
	/// that pretends. Marking her again further on solves a second stretch and
	/// merges it in: one anchor, one name, two spans of truth and a gap in
	/// between that nothing is drawn over.
	///
	/// Where the two overlap, the newer samples win: the later solve was made
	/// from a mark somebody placed while looking at that part of the picture.
	public func merging(_ other: AnchorPath) -> AnchorPath {
		guard !other.isEmpty else { return self }
		guard !isEmpty else { return other }

		let incoming = other.covered
		func replaced(_ time: Double) -> Bool { incoming.contains { $0.contains(time) } }
		let combined = (samples.filter { !replaced($0.time) } + other.samples)
			.sorted { $0.time < $1.time }
		return AnchorPath(samples: combined, covered: AnchorPath.union(covered + other.covered))
	}

	/// Overlapping or touching spans, joined.
	static func union(_ ranges: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
		let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
		var out: [ClosedRange<Double>] = []
		for range in sorted {
			// A hair of slack, so two stretches that meet at a sample boundary
			// come out as one span rather than two abutting ones.
			if let last = out.last, range.lowerBound <= last.upperBound + 1e-6 {
				out[out.count - 1] = last.lowerBound ... Swift.max(last.upperBound, range.upperBound)
			} else {
				out.append(range)
			}
		}
		return out
	}

	// MARK: - The sidecar

	/// Three columns of text, because that is a file somebody can fix.
	///
	/// A tracker loses a face for half a second and puts the spinner on a lamp.
	/// In this format that is four lines to delete or two numbers to correct,
	/// in an editor, with no tool needed. In a binary blob it is a re-solve and
	/// a hope.
	public func write(name: String, over: String, framesPerSecond: Double) -> String {
		var out = "# cuttr anchor path — \(name)\n"
		out += "# \(over), sampled, normalised frame coordinates, origin bottom-left\n"
		out += "# time      x       y\n"
		for sample in samples {
			out += String(format: "%-10.3f %.5f %.5f\n", sample.time, sample.point.x, sample.point.y)
		}
		return out
	}

	public static func read(_ text: String) -> AnchorPath {
		var samples: [(time: Double, point: CGPoint)] = []
		for line in text.components(separatedBy: .newlines) {
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
			let fields = trimmed.split(separator: " ", omittingEmptySubsequences: true)
			guard fields.count >= 3,
			      let time = Double(fields[0]), let x = Double(fields[1]), let y = Double(fields[2])
			else { continue }
			samples.append((time, CGPoint(x: x, y: y)))
		}
		return AnchorPath(samples: samples)
	}
}
