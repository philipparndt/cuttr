import Foundation

/// Sorting a take's lines into however many voices there are.
///
/// The arithmetic, and nothing else: what a voice *is* — a handful of numbers
/// off the recogniser, a timbre worked out from the samples, a vector out of a
/// neural network — is somebody else's problem. This takes points and gives
/// back which cluster each belongs to, which is the part with a right answer
/// and the part worth testing on numbers somebody wrote down.
///
/// **Two questions, and the second is much easier.** ``cluster(_:into:distance:rounds:)``
/// is handed unnamed points and has to find the clumps; ``place(_:as:rounds:prior:shrink:trust:)``
/// is handed a few points somebody has already named and only has to say which
/// of *those* each remaining point resembles. Measured on real footage the
/// second is worth twenty points of accuracy over the first, which is the whole
/// reason it exists: answering two lines by hand is cheap and it turns the
/// problem into one with a right answer to aim at. See `docs/speakers.md`.
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

	// MARK: - Placing lines against voices somebody has named

	/// A voice, as the spread of the measurements that belong to it.
	///
	/// A mean and a variance per dimension and no covariance between them.
	/// That is not a shortcut taken for speed: a full covariance over
	/// twenty-four dimensions has three hundred numbers in it and needs
	/// hundreds of examples to estimate, and the whole point here is to work
	/// from the two lines somebody could be bothered to answer.
	public struct Voice: Sendable, Equatable {
		public let mean: [Double]
		public let variance: [Double]
		/// How many measurements went into it. What decides how much of the
		/// mean is believed and how much is borrowed.
		public let count: Int

		public init(mean: [Double], variance: [Double], count: Int) {
			self.mean = mean
			self.variance = variance
			self.count = count
		}

		/// The mean and variance of these points, per dimension.
		public static func fit(_ points: [[Double]], width: Int) -> Voice {
			var mean = [Double](repeating: 0, count: width)
			guard !points.isEmpty else {
				return Voice(mean: mean, variance: [Double](repeating: 1, count: width), count: 0)
			}
			for point in points {
				for column in 0 ..< Swift.min(width, point.count) { mean[column] += point[column] }
			}
			for column in 0 ..< width { mean[column] /= Double(points.count) }
			var variance = [Double](repeating: 0, count: width)
			for point in points {
				for column in 0 ..< Swift.min(width, point.count) {
					let step = point[column] - mean[column]
					variance[column] += step * step
				}
			}
			for column in 0 ..< width { variance[column] /= Double(points.count) }
			return Voice(mean: mean, variance: variance, count: points.count)
		}

		/// This voice pulled towards the take's own average.
		///
		/// Two lines do not know the shape of a voice. They know a little about
		/// where it sits, and nothing at all about how much it moves — one line
		/// has a variance of exactly zero, which as a likelihood says every
		/// other line in the take is impossible. So the variance is mostly
		/// borrowed from the take as a whole, and the mean is pulled towards it
		/// by a fixed weight: with `prior` at a fifth of a line, two answered
		/// lines are believed nearly outright and one is held at arm's length.
		///
		/// This is the relevance factor every speaker system since the
		/// nineties has had in it, under one name or another.
		public func tempered(towards world: Voice, prior: Double, shrink: Double) -> Voice {
			let weight = Double(count)
			var mean = self.mean
			var variance = self.variance
			for column in mean.indices {
				mean[column] = (weight * self.mean[column] + prior * world.mean[column])
					/ (weight + prior)
				variance[column] = Swift.max(
					shrink * world.variance[column] + (1 - shrink) * self.variance[column], 1e-9)
			}
			return Voice(mean: mean, variance: variance, count: count)
		}

		/// How likely this voice is to have produced that measurement, as a
		/// logarithm. Only differences between voices are ever read off it, so
		/// the constant term is kept for tidiness rather than for use.
		public func likelihood(of point: [Double]) -> Double {
			var total = 0.0
			for column in 0 ..< Swift.min(mean.count, point.count) {
				let step = point[column] - mean[column]
				total -= 0.5 * (Foundation.log(2 * Double.pi * variance[column])
					+ step * step / variance[column])
			}
			return total
		}
	}

	/// Which named voice each point sounds most like.
	public struct Placing: Sendable, Equatable {
		/// The voices, in the order the names sort.
		public let names: [String]
		/// Per point, an index into ``names``.
		public let chosen: [Int]
		/// Per point, how much likelier the chosen voice is than the next one,
		/// as a difference of logarithms. Zero is a coin toss.
		public let margin: [Double]
		/// The silhouette of the arrangement it settled on — a remark rather
		/// than a gate. Where the voices are given, a low figure says the two
		/// people sound alike, not that a line was drawn through one blob.
		public let separation: Double

		public init(names: [String], chosen: [Int], margin: [Double], separation: Double) {
			self.names = names
			self.chosen = chosen
			self.margin = margin
			self.separation = separation
		}
	}

	/// Which of the named voices each point belongs to.
	///
	/// `named` says who some of the points are, by index. Everything else is
	/// placed with whichever of those voices makes it likeliest — a
	/// nearest-neighbour question with the variance of the take in it, which is
	/// a far easier question than "how many voices are there and where".
	///
	/// `rounds` is self-training: after the first pass, the points that were
	/// sure of themselves join their voice and everything is asked again. One
	/// round measured better than none and better than four — more data per
	/// voice helps, and a model taught by its own guesses eventually only
	/// believes itself.
	public static func place(
		_ points: [[Double]], as named: [Int: String],
		rounds: Int = 1, prior: Double = 0.2, shrink: Double = 0.5, trust: Double = 1
	) -> Placing {
		let names = Set(named.values).sorted()
		guard let width = points.first?.count, width > 0, names.count >= 2 else {
			return Placing(names: names, chosen: [], margin: [], separation: 0)
		}
		let world = Voice.fit(points, width: width)

		// In index order, not dictionary order. Swift seeds its hashing per
		// process, so summing a voice's points in the order a dictionary
		// happens to hold them gives a slightly different mean every launch —
		// and a line near the boundary between two voices then changes its
		// answer between one run and the next. A suggestion that moves is a
		// suggestion nobody can check.
		func voices(_ owners: [Int: String]) -> [Voice] {
			names.map { name in
				let mine = points.indices.filter { owners[$0] == name }.map { points[$0] }
				return Voice.fit(mine, width: width)
					.tempered(towards: world, prior: prior, shrink: shrink)
			}
		}
		func place(_ voices: [Voice]) -> (chosen: [Int], margin: [Double]) {
			var chosen = [Int](repeating: 0, count: points.count)
			var margin = [Double](repeating: 0, count: points.count)
			for (index, point) in points.enumerated() {
				let scores = voices.map { $0.likelihood(of: point) }
				var best = (0, -Double.infinity), second = -Double.infinity
				for (voice, score) in scores.enumerated() {
					if score > best.1 { second = best.1; best = (voice, score) }
					else if score > second { second = score }
				}
				chosen[index] = best.0
				margin[index] = second.isFinite ? best.1 - second : 0
			}
			return (chosen, margin)
		}

		var answer = place(voices(named))
		for _ in 0 ..< Swift.max(rounds, 0) {
			var owners = named
			for index in points.indices where named[index] == nil {
				guard answer.margin[index] >= trust else { continue }
				owners[index] = names[answer.chosen[index]]
			}
			answer = place(voices(owners))
		}
		// The lines somebody answered are what they said they were, whatever the
		// arithmetic makes of them. Anything else would quietly contradict the
		// person who is being helped.
		for (index, name) in named {
			guard let voice = names.firstIndex(of: name) else { continue }
			answer.chosen[index] = voice
			answer.margin[index] = .infinity
		}
		return Placing(
			names: names, chosen: answer.chosen, margin: answer.margin,
			separation: silhouette(points, labels: answer.chosen))
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
