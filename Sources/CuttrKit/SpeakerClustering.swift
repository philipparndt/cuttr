import Foundation

/// Sorting a take's lines into however many voices there are.
///
/// The arithmetic, and nothing else: what a voice *is* — a handful of numbers
/// off the recogniser, a timbre worked out from the samples, a vector out of a
/// neural network — is somebody else's problem. This takes points and gives
/// back which cluster each belongs to, which is the part with a right answer
/// and the part worth testing on numbers somebody wrote down.
///
/// **Deterministic on purpose.** The usual k-means starts from random centres
/// and gives a different answer every run. Here that would mean the same take
/// proposed as two speakers this morning and the other way round this
/// afternoon, and a suggestion that moves is a suggestion nobody can check.
/// The seeds are the two points furthest apart, which is one pass over the
/// data and has no random number in it.
public enum SpeakerClustering {

	/// How far apart two voices are.
	public enum Distance: Sendable {
		/// Straight-line, for features that have been standardised so that
		/// every dimension counts the same.
		case euclidean
		/// One minus the cosine of the angle. What a speaker embedding is
		/// trained to be compared by — the length of one of those vectors says
		/// how loud the microphone was, not who was talking.
		case cosine
	}

	/// Which cluster each point belongs to, and how well separated they are.
	public struct Grouping: Sendable, Equatable {
		public let labels: [Int]
		/// Mean silhouette, from −1 to 1.
		///
		/// The one number that says whether the split is real. Every clustering
		/// returns *something*; this says whether the points were actually in
		/// two clumps or whether a line was drawn through one. See
		/// ``silhouette(_:labels:distance:)``.
		public let separation: Double

		public init(labels: [Int], separation: Double) {
			self.labels = labels
			self.separation = separation
		}
	}

	// MARK: - Standardising

	/// Every dimension to zero mean and unit spread.
	///
	/// Without this, one feature measured in hertz drowns out twelve measured
	/// in tenths — the distance would be almost entirely about pitch, which is
	/// exactly the thing already known not to separate these two speakers.
	/// A dimension that never varies is left at zero rather than divided by it.
	public static func standardise(_ points: [[Double]]) -> [[Double]] {
		guard let width = points.first?.count, width > 0, points.count > 1 else { return points }
		var out = points
		for column in 0 ..< width {
			let values = points.map { $0.count > column ? $0[column] : 0 }
			let mean = values.reduce(0, +) / Double(values.count)
			let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
			let spread = variance.squareRoot()
			for row in out.indices {
				out[row][column] = spread > 1e-9 ? (values[row] - mean) / spread : 0
			}
		}
		return out
	}

	// MARK: - Clustering

	/// k-means, seeded from the two points furthest apart.
	public static func cluster(
		_ points: [[Double]], into k: Int,
		distance: Distance = .euclidean, rounds: Int = 50
	) -> Grouping {
		guard k >= 1, points.count >= k, let width = points.first?.count, width > 0 else {
			return Grouping(labels: Array(repeating: 0, count: points.count), separation: 0)
		}
		if k == 1 { return Grouping(labels: Array(repeating: 0, count: points.count), separation: 0) }

		var centres = seeds(points, k: k, distance: distance)
		var labels = [Int](repeating: 0, count: points.count)
		for _ in 0 ..< rounds {
			var moved = false
			for (index, point) in points.enumerated() {
				let nearest = nearestCentre(point, centres, distance)
				if labels[index] != nearest { labels[index] = nearest; moved = true }
			}
			// A cluster nobody joined keeps its centre rather than becoming a
			// vector of NaN, which is what dividing by no members gives and
			// what turns every distance afterwards into a comparison that is
			// false both ways round.
			for cluster in 0 ..< k {
				let members = points.indices.filter { labels[$0] == cluster }
				guard !members.isEmpty else { continue }
				var centre = [Double](repeating: 0, count: width)
				for index in members {
					for column in 0 ..< width { centre[column] += points[index][column] }
				}
				for column in 0 ..< width { centre[column] /= Double(members.count) }
				centres[cluster] = centre
			}
			if !moved { break }
		}
		return Grouping(labels: labels,
		                separation: silhouette(points, labels: labels, distance: distance))
	}

	/// The furthest-apart pair, then whatever is furthest from what is chosen.
	///
	/// The deterministic cousin of k-means++. O(n²) for the first pair, which
	/// for sixty-eight lines of an interview is four thousand distances and not
	/// worth being clever about.
	private static func seeds(_ points: [[Double]], k: Int, distance: Distance) -> [[Double]] {
		var best = (0, 1, -Double.infinity)
		for a in points.indices {
			for b in (a + 1) ..< points.count {
				let apart = measure(points[a], points[b], distance)
				if apart > best.2 { best = (a, b, apart) }
			}
		}
		var chosen = [points[best.0], points[best.1]]
		while chosen.count < k {
			var furthest = (0, -Double.infinity)
			for (index, point) in points.enumerated() {
				let nearest = chosen.map { measure(point, $0, distance) }.min() ?? 0
				if nearest > furthest.1 { furthest = (index, nearest) }
			}
			chosen.append(points[furthest.0])
		}
		return chosen
	}

	private static func nearestCentre(
		_ point: [Double], _ centres: [[Double]], _ distance: Distance
	) -> Int {
		var best = (0, Double.infinity)
		for (index, centre) in centres.enumerated() {
			let apart = measure(point, centre, distance)
			if apart < best.1 { best = (index, apart) }
		}
		return best.0
	}

	public static func measure(_ a: [Double], _ b: [Double], _ distance: Distance) -> Double {
		switch distance {
		case .euclidean:
			var total = 0.0
			for index in 0 ..< Swift.min(a.count, b.count) {
				let step = a[index] - b[index]
				total += step * step
			}
			return total.squareRoot()
		case .cosine:
			var dot = 0.0, left = 0.0, right = 0.0
			for index in 0 ..< Swift.min(a.count, b.count) {
				dot += a[index] * b[index]
				left += a[index] * a[index]
				right += b[index] * b[index]
			}
			guard left > 1e-12, right > 1e-12 else { return 1 }
			return 1 - dot / (left.squareRoot() * right.squareRoot())
		}
	}

	// MARK: - Whether the split is real

	/// The mean silhouette: for each point, how much nearer its own cluster is
	/// than the next one, scaled to −1…1.
	///
	/// This is the number that decides whether anything is offered at all. A
	/// clustering always produces labels — hand it one blob and it will draw a
	/// line through the middle of it and report two speakers with great
	/// confidence. The silhouette is what tells the difference: around zero
	/// means the line was drawn through a blob, and a colour that is wrong a
	/// third of the time is worse than no colour.
	public static func silhouette(
		_ points: [[Double]], labels: [Int], distance: Distance = .euclidean
	) -> Double {
		guard points.count > 1, points.count == labels.count,
		      Set(labels).count > 1 else { return 0 }
		var total = 0.0
		for (index, point) in points.enumerated() {
			var sums: [Int: (Double, Int)] = [:]
			for (other, otherPoint) in points.enumerated() where other != index {
				let apart = measure(point, otherPoint, distance)
				let entry = sums[labels[other]] ?? (0, 0)
				sums[labels[other]] = (entry.0 + apart, entry.1 + 1)
			}
			guard let own = sums[labels[index]], own.1 > 0 else { continue }
			let inside = own.0 / Double(own.1)
			let outside = sums
				.filter { $0.key != labels[index] && $0.value.1 > 0 }
				.map { $0.value.0 / Double($0.value.1) }
				.min()
			guard let outside else { continue }
			let worst = Swift.max(inside, outside)
			total += worst > 1e-12 ? (outside - inside) / worst : 0
		}
		return total / Double(points.count)
	}
}
