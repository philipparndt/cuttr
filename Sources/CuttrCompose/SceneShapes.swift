import CoreGraphics
import Foundation

public extension Scene {

	/// What a shape part is the shape of.
	///
	/// Six, and each one is a thing somebody asks for by name on a title card.
	/// They are all *star-shaped about their middle* — a ray from the centre
	/// crosses the outline exactly once — which is not a coincidence: it is
	/// what makes one shape able to become another, and a seventh that was not
	/// would need a rule this one does not have.
	enum ShapeKind: String, Sendable, CaseIterable {
		/// What every shape part was before there were kinds, and what one
		/// still is when the file does not say. Rounded by `corner:`.
		case rectangle
		case ellipse
		/// Apex up, base along the bottom of the box.
		case triangle
		case diamond
		/// Five points, the usual proportions.
		case star
		/// Flat top and bottom, points at the sides.
		case hexagon
	}

	/// Two shapes, and how far along it is between them.
	///
	/// `from == to` is the ordinary case — a part whose kind never changes —
	/// and the drawing code takes a short cut for it.
	struct ShapeMorph: Sendable, Equatable {
		public var from: ShapeKind
		public var to: ShapeKind
		public var fraction: Double

		public init(from: ShapeKind, to: ShapeKind, fraction: Double) {
			self.from = from
			self.to = to
			self.fraction = fraction
		}

		public var isStill: Bool { from == to || fraction <= 0 || fraction >= 1 }

		/// The one kind this is, when it is only one.
		public var settled: ShapeKind { fraction >= 1 ? to : from }
	}

	/// Which shape a part is at a moment, and what it is turning into.
	///
	/// Read off the same filled keys everything else is: a key that names a
	/// kind different from the one before it morphs between them over that
	/// interval, with the easing the key already carries. A key that names none
	/// is the kind it already was, which is why a shape that never changes says
	/// its kind once or not at all.
	static func morph(of keys: [Key], at time: Double, default fallback: ShapeKind) -> ShapeMorph {
		guard let first = keys.first, let last = keys.last else {
			return ShapeMorph(from: fallback, to: fallback, fraction: 0)
		}
		if time <= first.t {
			let kind = first.shape ?? fallback
			return ShapeMorph(from: kind, to: kind, fraction: 0)
		}
		if time >= last.t {
			let kind = last.shape ?? fallback
			return ShapeMorph(from: kind, to: kind, fraction: 1)
		}
		guard let next = keys.firstIndex(where: { $0.t > time }), next > 0 else {
			let kind = last.shape ?? fallback
			return ShapeMorph(from: kind, to: kind, fraction: 1)
		}
		let before = keys[next - 1], after = keys[next]
		let span = max(after.t - before.t, 0.0001)
		return ShapeMorph(
			from: before.shape ?? fallback,
			to: after.shape ?? before.shape ?? fallback,
			fraction: eased(after.ease, (time - before.t) / span))
	}
}

public extension Scene.ShapeKind {

	/// The outline, centred on the origin, in a box of this size.
	///
	/// Exact: a rectangle is a rounded rectangle with real arcs and an ellipse
	/// is a real ellipse, so a project written before there were kinds renders
	/// exactly as it did. The sampled version below is only used when a part is
	/// actually turning into something else.
	func path(in size: CGSize, corner: CGFloat) -> CGPath {
		let box = CGRect(x: -size.width / 2, y: -size.height / 2,
		                 width: size.width, height: size.height)
		switch self {
		case .rectangle:
			let radius = min(corner, size.width / 2, size.height / 2)
			return CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius,
			              transform: nil)
		case .ellipse:
			return CGPath(ellipseIn: box, transform: nil)
		case .triangle, .diamond, .star, .hexagon:
			let points = corners(in: size)
			let path = CGMutablePath()
			path.addLines(between: points)
			path.closeSubpath()
			return path
		}
	}

	/// The corners, anticlockwise from the top, for the kinds that have them.
	func corners(in size: CGSize) -> [CGPoint] {
		let a = size.width / 2, b = size.height / 2
		func around(_ count: Int, start: CGFloat, radius: (Int) -> CGFloat) -> [CGPoint] {
			(0..<count).map { step in
				let angle = start + CGFloat(step) * 2 * .pi / CGFloat(count)
				return CGPoint(x: cos(angle) * a * radius(step), y: sin(angle) * b * radius(step))
			}
		}
		switch self {
		case .triangle:
			return [CGPoint(x: 0, y: b), CGPoint(x: -a, y: -b), CGPoint(x: a, y: -b)]
		case .diamond:
			return [CGPoint(x: 0, y: b), CGPoint(x: -a, y: 0),
			        CGPoint(x: 0, y: -b), CGPoint(x: a, y: 0)]
		case .hexagon:
			// Points at the sides and flats top and bottom, which is the one
			// people draw when they say hexagon.
			return around(6, start: 0) { _ in 1 }
		case .star:
			// Ten corners, every other one pulled in. 0.42 is the ratio that
			// reads as a star rather than as a cog or a splash.
			return (0..<10).map { step in
				let angle = .pi / 2 + CGFloat(step) * .pi / 5
				let reach: CGFloat = step % 2 == 0 ? 1 : 0.42
				return CGPoint(x: cos(angle) * a * reach, y: sin(angle) * b * reach)
			}
		case .rectangle, .ellipse:
			return []
		}
	}

	/// How far the outline is from the middle, in the direction `angle`.
	///
	/// The one thing a morph needs. Every kind here is star-shaped about its
	/// middle, so this is a single well-defined number for every direction.
	func radius(at angle: CGFloat, in size: CGSize, corner: CGFloat) -> CGFloat {
		let a = max(size.width / 2, 0.0001), b = max(size.height / 2, 0.0001)
		let direction = CGPoint(x: cos(angle), y: sin(angle))
		switch self {
		case .ellipse:
			let x = direction.x / a, y = direction.y / b
			return 1 / max(sqrt(x * x + y * y), 0.0001)
		case .rectangle:
			let radius = min(corner, a, b)
			guard radius > 0.0001 else {
				// A plain rectangle is two divisions and no searching.
				let byWidth = abs(direction.x) > 0.0001 ? a / abs(direction.x) : .greatestFiniteMagnitude
				let byHeight = abs(direction.y) > 0.0001 ? b / abs(direction.y) : .greatestFiniteMagnitude
				return min(byWidth, byHeight)
			}
			// A rounded box is a smaller box grown by a disc, and its signed
			// distance is standard. Walking in on the ray until that reaches
			// nought is thirty divisions and needs no algebra that could be
			// got subtly wrong — which matters, because the pixel path and the
			// layer path both depend on this being the same number.
			func outside(_ t: CGFloat) -> CGFloat {
				let p = CGPoint(x: abs(direction.x * t) - (a - radius),
				                y: abs(direction.y * t) - (b - radius))
				let corner = CGPoint(x: max(p.x, 0), y: max(p.y, 0))
				return sqrt(corner.x * corner.x + corner.y * corner.y)
					+ min(max(p.x, p.y), 0) - radius
			}
			var low: CGFloat = 0, high = sqrt(a * a + b * b) * 1.5
			for _ in 0..<30 {
				let middle = (low + high) / 2
				if outside(middle) < 0 { low = middle } else { high = middle }
			}
			return (low + high) / 2
		case .triangle, .diamond, .star, .hexagon:
			let points = corners(in: size)
			var found: CGFloat = 0
			for index in points.indices {
				let p = points[index], q = points[(index + 1) % points.count]
				// Where the ray from the middle crosses this edge, if it does.
				let edge = CGPoint(x: q.x - p.x, y: q.y - p.y)
				let denominator = direction.x * edge.y - direction.y * edge.x
				guard abs(denominator) > 1e-9 else { continue }
				let t = (p.x * edge.y - p.y * edge.x) / denominator
				let u = (p.x * direction.y - p.y * direction.x) / denominator
				guard t > 0, u >= -1e-6, u <= 1 + 1e-6 else { continue }
				found = max(found, t)
			}
			return found
		}
	}

	/// How many points a morphing outline is cut into.
	///
	/// One number, used by both render paths and by nothing else. Core
	/// Animation interpolates one path into another only when the two have the
	/// same points in the same order, so this is not a quality setting that can
	/// be turned up on one side.
	static let morphPoints = 144

	/// One shape part of the way into another.
	///
	/// Both outlines are cut into the same number of points, at the same angles
	/// round the middle, and point *k* of one is matched with point *k* of the
	/// other. What that means when the two disagree — a triangle becoming a
	/// star — is that the corners slide round the outline rather than the
	/// nearest corner finding the nearest corner: the shape stays closed and
	/// convincing throughout, and no vertex of either end is preserved exactly
	/// except where the angles happen to land on one. It is the rule a path
	/// animation needs anyway, and it is honest about what it can do.
	static func morphed(
		_ morph: Scene.ShapeMorph, in size: CGSize, corner: CGFloat
	) -> CGPath {
		guard !morph.isStill else {
			return morph.settled.path(in: size, corner: corner)
		}
		return sampled(morph.from, morph.to, morph.fraction, in: size, corner: corner)
	}

	/// One outline, cut into the same points a morph uses.
	///
	/// Needed on its own for the layer path: every key of a morphing part has
	/// to be a path of this shape, or Core Animation has nothing to interpolate
	/// between.
	static func sampled(_ kind: Scene.ShapeKind, in size: CGSize, corner: CGFloat) -> CGPath {
		sampled(kind, kind, 0, in: size, corner: corner)
	}

	private static func sampled(
		_ from: Scene.ShapeKind, _ to: Scene.ShapeKind, _ fraction: CGFloat,
		in size: CGSize, corner: CGFloat
	) -> CGPath {
		var points: [CGPoint] = []
		points.reserveCapacity(morphPoints)
		for step in 0..<morphPoints {
			let angle = CGFloat(step) * 2 * .pi / CGFloat(morphPoints)
			let a = from.radius(at: angle, in: size, corner: corner)
			let b = to.radius(at: angle, in: size, corner: corner)
			let radius = a + (b - a) * fraction
			points.append(CGPoint(x: cos(angle) * radius, y: sin(angle) * radius))
		}
		let path = CGMutablePath()
		path.addLines(between: points)
		path.closeSubpath()
		return path
	}
}
