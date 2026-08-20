import CoreGraphics
import CoreText
import Foundation

/// Drawing a bubble: the wobbly outline, the tail, the words inside it.
///
/// **One implementation, two hosts**, for the same reason ``OverlayLayers`` and
/// ``OverlayPainter`` draw a spinner from one set of proportions: the export
/// lays a bubble on as Core Animation shape layers, and a bubble that goes
/// `behind: people` is painted into the frame instead. Both ask this file for
/// the paths, so there is nowhere for the two to drift apart.
///
/// **Why it is polar.** The outline is a radius per angle rather than a list of
/// corners, and the tail is a spike added to that radius at the angle the face
/// happens to be in. That is what makes the tail movable: as somebody walks
/// across the shot the spike travels round the loop, and the path still has
/// exactly the same number of points at every moment — which is Core
/// Animation's one condition for interpolating between two paths. A tail built
/// as its own triangle and stuck on the side would have to be a second layer,
/// and the body's own outline would then be drawn straight across its base.
enum Bubbling {

	/// How many angles the outline is sampled at.
	///
	/// Fixed, and fixed for every frame of every shape: it is the number Core
	/// Animation interpolates against. Two hundred and forty is about a point
	/// every pixel and a half round a bubble a fifth of a 1080 frame wide,
	/// which is finer than the wobble it is drawing.
	static let steps = 240

	/// The paths a bubble is made of at one moment.
	struct Paths {
		/// The paper: filled, then stroked. For a speech bubble the tail is
		/// part of it, which is why it has no seam.
		var body: CGPath
		/// The thought bubble's puffs, or the box's arrow — the part that moves
		/// when the face does, for the two shapes whose body does not carry it.
		var tail: CGPath?
		/// Whether the tail is paper (the puffs) or only a line (the arrow).
		var tailIsPaper: Bool
	}

	/// Whether this shape's tail lives inside its body path.
	static func tailIsInTheBody(_ shape: Bubble.Shape) -> Bool { shape == .speech }

	// MARK: - Where the paper goes

	/// The paper's rectangle: big enough for the words, and inside the frame.
	///
	/// `home` is where the bubble was put — the middle of it. Clamped so the
	/// whole bubble stays on screen, which is the other half of not running off
	/// the side: the words wrap to a measure, and then the box that holds them
	/// is pushed back into the picture if it was written too near an edge.
	static func box(words: CGSize, shape: Bubble.Shape, style: TextStyle,
	                home: CGPoint, frame: CGSize) -> CGRect {
		let padding = style.padding * frame.height
		// The outline passes *inside* the corners of the rectangle it is drawn
		// round — that is what a rounded corner is — so the half-extents are
		// opened out by exactly as much as the curve cuts in. For the
		// superellipse below, a shape whose sides sit at `a` and `b` passes
		// through its own corner direction at 2^(-1/n) of the way, so
		// multiplying by 2^(1/n) puts the corner of the words back on the line.
		// Worked out rather than guessed at, so a long word in a round bubble
		// does not poke through the side of it.
		let room = pow(2, 1 / exponent(shape))
		var size = CGSize(width: (words.width / 2 + padding) * room * 2,
		                  height: (words.height / 2 + padding) * room * 2)
		size.width = min(size.width, frame.width - 4)
		size.height = min(size.height, frame.height - 4)
		let margin = 0.01 * frame.height
		let x = min(max(home.x, size.width / 2 + margin), frame.width - size.width / 2 - margin)
		let y = min(max(home.y, size.height / 2 + margin), frame.height - size.height / 2 - margin)
		return CGRect(x: x - size.width / 2, y: y - size.height / 2,
		              width: size.width, height: size.height)
	}

	/// How square the outline is. Two is an ellipse and infinity is a
	/// rectangle; a speech bubble is between the two and a box is nearly one.
	private static func exponent(_ shape: Bubble.Shape) -> Double {
		switch shape {
		case .speech: return 3.2
		case .thought: return 2.4
		case .box: return 9
		}
	}

	// MARK: - The drawing

	/// Everything the bubble is, at one position of the thing it points at.
	///
	/// `target` is in frame coordinates, or `nil` for a bubble pointing at
	/// nothing — which is what a bubble whose anchor has no tracking at this
	/// moment gets. It keeps its words and loses its tail, rather than pointing
	/// confidently at wherever the face last was: a tail frozen on a doorway
	/// somebody left through looks exactly like a tracker that has failed, and
	/// this program says so elsewhere too.
	static func paths(
		_ bubble: Bubble, box: CGRect, pointingAt target: CGPoint?,
		frame: CGSize, pass: Int
	) -> Paths {
		let wobble = Wobble(seed: bubble.seed, pass: pass)
		let centre = CGPoint(x: box.midX, y: box.midY)
		let half = CGSize(width: box.width / 2, height: box.height / 2)
		let amplitude = max(0.005 * frame.height, 0.05 * min(half.width, half.height))
		let aimed = target.map { clamped($0, in: frame) }

		var spike: (angle: Double, reach: Double)?
		if bubble.shape == .speech, let aimed {
			let angle = atan2(aimed.y - centre.y, aimed.x - centre.x)
			let distance = hypot(aimed.x - centre.x, aimed.y - centre.y)
			let edge = radius(at: angle, half: half, exponent: exponent(bubble.shape))
			// Stopping a little short of the mouth rather than touching it, and
			// nothing at all when the face is under the bubble: a tail turned
			// inside out is a dent, not a tail.
			let reach = distance - 0.014 * frame.height
			if reach > edge * 1.15 { spike = (angle, reach) }
		}

		let body = outline(bubble, centre: centre, half: half, wobble: wobble,
		                   amplitude: amplitude, spike: spike)

		guard let aimed else { return Paths(body: body, tail: nil, tailIsPaper: false) }
		switch bubble.shape {
		case .speech:
			return Paths(body: body, tail: nil, tailIsPaper: false)
		case .thought:
			return Paths(body: body,
			             tail: puffs(bubble, centre: centre, half: half, at: aimed,
			                         wobble: wobble, frame: frame),
			             tailIsPaper: true)
		case .box:
			return Paths(body: body,
			             tail: arrow(bubble, centre: centre, half: half, at: aimed,
			                         wobble: wobble, frame: frame),
			             tailIsPaper: false)
		}
	}

	/// A point pulled back inside the frame.
	///
	/// What happens when the face walks out of shot: the tail lies along the
	/// edge it left by and goes on pointing that way, which is the true thing
	/// to say. Letting it run off would say the same thing invisibly, since the
	/// tree is masked to the frame.
	private static func clamped(_ point: CGPoint, in frame: CGSize) -> CGPoint {
		CGPoint(x: min(max(point.x, 2), frame.width - 2),
		        y: min(max(point.y, 2), frame.height - 2))
	}

	/// The closed outline, sampled by angle, with the tail spike in it.
	private static func outline(
		_ bubble: Bubble, centre: CGPoint, half: CGSize, wobble: Wobble,
		amplitude: Double, spike: (angle: Double, reach: Double)?
	) -> CGPath {
		let path = CGMutablePath()
		let power = exponent(bubble.shape)
		// Which way the tail leans. A tail that is the same on both sides reads
		// as a machine-made cone; every hand draws one side longer.
		let lean = wobble.lean
		for step in 0 ..< steps {
			let angle = 2 * Double.pi * Double(step) / Double(steps)
			var r = radius(at: angle, half: half, exponent: power)
			if bubble.shape == .thought {
				// The scallops, multiplied in rather than added, so a wide
				// cloud's puffs are as deep at the ends as at the sides. Nine
				// humps of a rectified sine rather than a plain one: the cusp
				// between two humps is what makes it read as a cloud instead of
				// a wavy ellipse.
				r *= 1 + 0.15 * abs(sin(4.5 * angle + wobble.puffPhase))
			}
			r += amplitude * wobble.at(angle)
			if let spike {
				let width = 0.3 * (turn(angle - spike.angle) < 0 ? lean : 2 - lean)
				let away = abs(turn(angle - spike.angle))
				if away < width {
					let taper = pow(cos(Double.pi / 2 * away / width), 1.9)
					r += (spike.reach - radius(at: spike.angle, half: half, exponent: power)) * taper
				}
			}
			let point = CGPoint(x: centre.x + cos(angle) * r, y: centre.y + sin(angle) * r)
			if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
		}
		path.closeSubpath()
		return path
	}

	/// The radius of a superellipse at an angle: two is an ellipse, a large
	/// exponent is a rectangle, and everything between is a rounded corner.
	private static func radius(at angle: Double, half: CGSize, exponent n: Double) -> Double {
		let x = abs(cos(angle)) / max(half.width, 0.001)
		let y = abs(sin(angle)) / max(half.height, 0.001)
		return pow(pow(x, n) + pow(y, n), -1 / n)
	}

	/// The thought bubble's trail: three puffs, shrinking towards the face.
	///
	/// One path holding three closed loops of the same length, because that is
	/// what Core Animation can interpolate — the puffs then slide and shrink as
	/// somebody walks rather than jumping between two arrangements.
	private static func puffs(
		_ bubble: Bubble, centre: CGPoint, half: CGSize, at target: CGPoint,
		wobble: Wobble, frame: CGSize
	) -> CGPath? {
		let angle = atan2(target.y - centre.y, target.x - centre.x)
		let edge = radius(at: angle, half: half, exponent: exponent(bubble.shape)) * 1.17
		let start = CGPoint(x: centre.x + cos(angle) * edge, y: centre.y + sin(angle) * edge)
		let span = hypot(target.x - start.x, target.y - start.y)
		guard span > 0.03 * frame.height else { return nil }

		let path = CGMutablePath()
		let biggest = min(half.width, half.height)
		for (index, along) in [0.16, 0.48, 0.8].enumerated() {
			let size = max(0.008 * frame.height, biggest * [0.3, 0.2, 0.125][index])
			let middle = CGPoint(x: start.x + (target.x - start.x) * along,
			                     y: start.y + (target.y - start.y) * along)
			// Each puff off the line by a little, alternating, so the trail
			// meanders the way a drawn one does.
			let sideways = wobble.drift(index) * size
			let across = CGPoint(x: -sin(angle) * sideways, y: cos(angle) * sideways)
			for step in 0 ..< 28 {
				let round = 2 * Double.pi * Double(step) / 28
				let r = size * (1 + 0.1 * wobble.at(round + Double(index) * 2.1))
				let point = CGPoint(x: middle.x + across.x + cos(round) * r,
				                    y: middle.y + across.y + sin(round) * r)
				if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
			}
			path.closeSubpath()
		}
		return path
	}

	/// The box's arrow: a bent shaft with a two-stroke head, all one open line.
	///
	/// Drawn as a single polyline that runs out to the point, back up one barb,
	/// down to the point again and out along the other — which is how a hand
	/// draws an arrowhead and, not by coincidence, keeps the number of points
	/// the same however far away the thing being pointed at is.
	private static func arrow(
		_ bubble: Bubble, centre: CGPoint, half: CGSize, at target: CGPoint,
		wobble: Wobble, frame: CGSize
	) -> CGPath? {
		let angle = atan2(target.y - centre.y, target.x - centre.x)
		let edge = radius(at: angle, half: half, exponent: exponent(bubble.shape))
		let start = CGPoint(x: centre.x + cos(angle) * (edge + 0.012 * frame.height),
		                    y: centre.y + sin(angle) * (edge + 0.012 * frame.height))
		let tip = CGPoint(x: target.x - cos(angle) * 0.012 * frame.height,
		                  y: target.y - sin(angle) * 0.012 * frame.height)
		let span = hypot(tip.x - start.x, tip.y - start.y)
		guard span > 0.04 * frame.height else { return nil }

		// A quadratic, bent to one side: an arrow drawn with a ruler is the one
		// thing a hand-drawn callout must not look like.
		let bend = (wobble.lean - 1) * 0.22 * span
		let control = CGPoint(x: (start.x + tip.x) / 2 - sin(angle) * bend,
		                      y: (start.y + tip.y) / 2 + cos(angle) * bend)
		let path = CGMutablePath()
		let shaft = 24
		var last = start
		for step in 0 ..< shaft {
			let t = Double(step) / Double(shaft - 1)
			let inverse = 1 - t
			var point = CGPoint(
				x: inverse * inverse * start.x + 2 * inverse * t * control.x + t * t * tip.x,
				y: inverse * inverse * start.y + 2 * inverse * t * control.y + t * t * tip.y)
			// The shaft shakes as well, and least at its two ends, where a hand
			// is steadied by where it is going.
			let shake = sin(Double.pi * t) * 0.004 * frame.height * wobble.at(t * 5.3)
			point = CGPoint(x: point.x - sin(angle) * shake, y: point.y + cos(angle) * shake)
			if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
			last = point
		}
		// The head sits on the direction the shaft actually arrives from, not
		// on the straight line to the target, or a bent arrow's head points
		// somewhere the arrow does not.
		let arriving = atan2(last.y - control.y, last.x - control.x)
		let barb = min(0.05 * frame.height, span * 0.32)
		for side in [1.0, -1.0] {
			let away = arriving + Double.pi + side * 0.42
			path.addLine(to: CGPoint(x: last.x + cos(away) * barb, y: last.y + sin(away) * barb))
			path.addLine(to: last)
		}
		return path
	}

	/// The shortest way round from one angle to another, in `(-π, π]`.
	private static func turn(_ angle: Double) -> Double {
		var a = angle.truncatingRemainder(dividingBy: 2 * Double.pi)
		if a > Double.pi { a -= 2 * Double.pi }
		if a <= -Double.pi { a += 2 * Double.pi }
		return a
	}

	// MARK: - The wobble

	/// A shaky line that is the same shaky line every time.
	///
	/// Five harmonics with seeded amplitudes and phases, which is a smooth
	/// closed curve rather than noise: a hand wanders, it does not buzz. And
	/// because it is a function of the angle rather than of the frame, the body
	/// of the bubble is drawn identically at every moment while the tail sweeps
	/// through it — the words do not shimmer.
	///
	/// `pass` is which of the two strokes this is. The look of a drawn line is
	/// two passes that nearly agree, so the second pass is the same seed one
	/// turn further on.
	struct Wobble {
		private var amplitudes: [Double] = []
		private var phases: [Double] = []
		/// Which side of the tail is the long one, between 0.7 and 1.3.
		let lean: Double
		/// Where the thought bubble's scallops start.
		let puffPhase: Double
		private var drifts: [Double] = []

		init(seed: Int, pass: Int) {
			// The seed alone decides the line. The second pass is the *same*
			// line drawn again slightly off — a nudge in phase and a little less
			// of it — rather than an independent one off a second seed.
			//
			// Which is the difference between a sketch and a mistake, and it was
			// measured by looking: two independent wobbles round a wide thought
			// bubble came out as two different ellipses with a gap between them,
			// and read as a printing error rather than as a drawn line.
			var random = Seeded(seed &* 2_654_435_761)
			var total = 0.0
			let nudge = Double(pass) * 0.42
			for harmonic in 1 ... 5 {
				// A one-over-frequency falloff: the big wanders are slow ones.
				let amount = Double.random(in: 0.35 ... 1, using: &random) / Double(harmonic)
				amplitudes.append(amount * (pass == 0 ? 1 : 0.85))
				phases.append(Double.random(in: 0 ..< (2 * Double.pi), using: &random) + nudge)
				total += amount
			}
			amplitudes = amplitudes.map { $0 / total }
			// The shape's own facts — which way the tail leans, where the
			// scallops fall — belong to the bubble and not to one stroke of it,
			// so both passes get the same ones.
			lean = Double.random(in: 0.7 ... 1.3, using: &random)
			puffPhase = Double.random(in: 0 ..< (2 * Double.pi), using: &random)
			drifts = (0 ..< 4).map { _ in Double.random(in: -0.5 ... 0.5, using: &random) }
		}

		/// How far off the true line the hand is, at an angle, in `-1 ... 1`.
		func at(_ angle: Double) -> Double {
			var sum = 0.0
			for harmonic in 1 ... 5 {
				sum += amplitudes[harmonic - 1] * sin(Double(harmonic) * angle + phases[harmonic - 1])
			}
			return sum
		}

		/// How far the nth puff sits off the line to the face.
		func drift(_ index: Int) -> Double { drifts[index % drifts.count] }
	}

	// MARK: - The words

	/// The words, wrapped, as an image and the size to draw it at.
	///
	/// A framesetter rather than the single line ``OverlayLayers/textLayer(_:style:size:tracking:ink:)``
	/// draws, because a bubble is the one overlay whose text is a paragraph:
	/// somebody writing a long joke should get a taller bubble, and a caption's
	/// one line would get a bubble the width of the frame and then some.
	///
	/// No plate is drawn — the bubble *is* the plate — so a style with a
	/// background on it loses only that.
	static func words(
		_ text: String, style: TextStyle, frame: CGSize, width: Double
	) -> (image: CGImage, size: CGSize)? {
		guard !text.isEmpty else { return nil }
		let scale: CGFloat = 2
		let pointSize = max(1, style.size * frame.height * scale)
		let font = CTFontCreateWithName(style.font as CFString, pointSize, nil)

		var alignment: CTTextAlignment
		switch style.alignment {
		case .left: alignment = .left
		case .right: alignment = .right
		case .centre: alignment = .center
		}
		var spacing = CGFloat(0.12) * pointSize
		var settings: [CTParagraphStyleSetting] = []
		withUnsafeBytes(of: &alignment) { bytes in
			settings.append(CTParagraphStyleSetting(
				spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size,
				value: bytes.baseAddress!))
		}
		withUnsafeBytes(of: &spacing) { bytes in
			settings.append(CTParagraphStyleSetting(
				spec: .lineSpacingAdjustment, valueSize: MemoryLayout<CGFloat>.size,
				value: bytes.baseAddress!))
		}
		let paragraph = CTParagraphStyleCreate(settings, settings.count)

		let attributed = NSAttributedString(string: text, attributes: [
			kCTFontAttributeName as NSAttributedString.Key: font,
			kCTForegroundColorAttributeName as NSAttributedString.Key: cg(style.color),
			kCTParagraphStyleAttributeName as NSAttributedString.Key: paragraph,
		])
		let setter = CTFramesetterCreateWithAttributedString(attributed)
		let limit = CGSize(width: max(8, width * frame.width * scale),
		                   height: CGFloat.greatestFiniteMagnitude)
		var fitted = CFRange()
		let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
			setter, CFRange(location: 0, length: 0), nil, limit, &fitted)
		// A point of slack at each edge: the suggested size is the ink, and a
		// descender or an accent right on the boundary would otherwise be shaved
		// off by the bitmap.
		let pixels = CGSize(width: ceil(suggested.width) + 2, height: ceil(suggested.height) + 4)

		guard pixels.width >= 1, pixels.height >= 1, let context = CGContext(
			data: nil, width: Int(pixels.width), height: Int(pixels.height),
			bitsPerComponent: 8, bytesPerRow: 0,
			space: CGColorSpace(name: CGColorSpace.sRGB)!,
			bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
		else { return nil }
		let region = CGPath(rect: CGRect(origin: .zero, size: pixels), transform: nil)
		let typeset = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), region, nil)
		CTFrameDraw(typeset, context)
		guard let image = context.makeImage() else { return nil }
		return (image, CGSize(width: pixels.width / scale, height: pixels.height / scale))
	}

	/// The whole bubble, drawn into a context in frame coordinates.
	///
	/// What the painter uses, and what the tests measure. The layer path builds
	/// the same paths as shape layers instead, so that the export gets vectors;
	/// the paths themselves come from the one function above.
	static func draw(
		_ bubble: Bubble, box: CGRect, words: CGImage?, wordSize: CGSize,
		pointingAt target: CGPoint?, frame: CGSize, into context: CGContext
	) {
		let weight = lineWidth(for: frame)
		context.setLineJoin(.round)
		context.setLineCap(.round)
		for pass in 0 ..< 2 {
			let drawing = paths(bubble, box: box, pointingAt: target, frame: frame, pass: pass)
			// The paper goes down once, on the first pass. Twice would double
			// the alpha of a translucent fill and leave a rim where the two
			// outlines disagree.
			if pass == 0 {
				context.setFillColor(cg(bubble.fill))
				// The tail first, then the paper over it — the order the layer
				// path adds its sublayers in, so the two agree wherever a puff
				// happens to touch the body.
				if let tail = drawing.tail, drawing.tailIsPaper {
					context.addPath(tail)
					context.fillPath()
				}
				context.addPath(drawing.body)
				context.fillPath()
			}
			context.setStrokeColor(cg(bubble.line, alpha: pass == 0 ? 1 : 0.5))
			context.setLineWidth(weight * (pass == 0 ? 1 : 0.72))
			context.addPath(drawing.body)
			if let tail = drawing.tail { context.addPath(tail) }
			context.strokePath()
		}
		if let words {
			context.draw(words, in: CGRect(x: box.midX - wordSize.width / 2,
			                               y: box.midY - wordSize.height / 2,
			                               width: wordSize.width, height: wordSize.height))
		}
	}

	/// How heavy the drawn line is. A fraction of the frame, like everything
	/// else here, so a bubble looks the same at 720 and at 4K.
	static func lineWidth(for frame: CGSize) -> Double { max(1, 0.0045 * frame.height) }

	static func cg(_ colour: RGBA, alpha: Double = 1) -> CGColor {
		CGColor(srgbRed: colour.r, green: colour.g, blue: colour.b, alpha: colour.a * alpha)
	}
}
