import CoreGraphics
import CuttrKit
import Foundation

/// Where a bubble's two numbers put it, and which numbers would put it
/// somewhere else.
///
/// **Why this exists.** `offset: [-0.08, 0.3]` is a coordinate somebody has to
/// guess, render, look at and guess again. The way out is to drag the thing
/// against a picture — and a drag is only honest if the arithmetic runs both
/// ways: forwards to draw the bubble where the file says, and backwards to say
/// what the file would have to say for the bubble to be *there*. Both directions
/// belong together, in one file, because a preview whose inverse disagreed with
/// the renderer's forward map by a hair would put a bubble on somebody's ear in
/// the window and on their shoulder in the render.
///
/// So this is the whole of it, and it is deliberately the only public door on
/// the subject: ``placement(_:resolved:project:size:at:)`` says where the paper
/// and the tip are now, ``offset(forPaper:origins:size:)`` and
/// ``tail(forTip:origins:size:)`` say what to write to move them, and
/// ``drawing(_:resolved:project:size:at:)`` draws the bubble — the same call
/// ``OverlayPainter`` makes for a bubble that goes behind somebody. There is no
/// second drawing of a bubble anywhere for a panel to get out of step with.
///
/// **What the two numbers are measured from is not the same point**, which is
/// the one thing in here that will surprise a reader. `offset:` stands the paper
/// off from the *smoothed* anchor, because words that move under the reader
/// cannot be read; `tail:` aims the tip from the *raw* one, because a tail may
/// be lively. See ``Bubble/follow`` and ``OverlayLayers/settling``. A drag
/// therefore has to undo the smoothing on the way back — which is exactly what
/// ``Origins`` is: the two points, already worked out, ready to subtract.
public enum BubblePlacing {

	/// How many steps a dragged number is written in to the whole frame height.
	///
	/// Written as the count rather than only as the size of one, because the
	/// rounding has to land on the *same* double the file's own text reads back
	/// as: dividing by a thousand does, multiplying by a thousandth does not,
	/// and the difference between the two is a number that comes back slightly
	/// different every time it is written and read.
	private static let perWhole = 1000.0

	/// The finest a dragged number is written to.
	///
	/// A thousandth of the frame's height: one pixel at 1080, two at 4K, and
	/// about a seventh of what one point of mouse movement is worth in a panel's
	/// little picture — so nothing a hand can do is lost to it.
	///
	/// Rounded at all because a drag is a measurement and a file is read by
	/// people. `offset: [-0.082, 0.294]` is a number somebody can nudge, copy,
	/// or recognise on a second bubble; `offset: [-0.0824561, 0.2941176]` is a
	/// number that says a mouse was involved. And it is what makes a drag that
	/// lands where it started write *nothing*: the inverse of the forward map is
	/// then the identity on any value that could have come out of it, rather
	/// than the same value with a bit flipped in the last place.
	public static let step = 1 / perWhole

	/// The two points a bubble's numbers are measured from, in frame
	/// coordinates.
	///
	/// `nil` for either one means there is nothing to be relative to and no
	/// number could move it:
	///
	/// - **The tip, outside the solved range.** A tracked anchor answers "where
	///   it last was" past the end of what was solved, and the tail refuses that
	///   answer on purpose — see ``OverlayLayers/bubbleTarget(_:resolved:at:size:)``.
	///   There is no tail drawn at that moment, so there is no tip to place, and
	///   a `tail:` written against the last place a face was seen would land
	///   somewhere else in the render. Scrub into the anchor's range and aim it
	///   there.
	/// - **Both, for a bubble about nothing.** No `anchor:` and no `at:` means
	///   the paper sits where its style says and `offset:` is not read at all.
	///   Give it one or the other and both handles come alive.
	public struct Origins: Equatable, Sendable {
		/// What `offset:` is measured from: the smoothed anchor, or `at:`.
		public var paper: CGPoint?
		/// What `tail:` is measured from: the anchor's own point at this moment,
		/// or `at:`.
		public var tip: CGPoint?

		public init(paper: CGPoint?, tip: CGPoint?) {
			self.paper = paper
			self.tip = tip
		}
	}

	/// Everything about where one bubble is at one moment, in frame
	/// coordinates.
	public struct Placement {
		/// The paper's rectangle, as drawn. What to grab it by.
		public var box: CGRect
		/// The middle of the paper, as drawn.
		public var paper: CGPoint { CGPoint(x: box.midX, y: box.midY) }
		/// Where `offset:` put the middle of the paper *before the edge of the
		/// frame had its say*.
		///
		/// The same point as ``paper`` anywhere but up against an edge, where
		/// ``Bubbling/box(words:shape:style:home:frame:give:)`` pushes the paper
		/// back inside the picture. This is the one a drag writes from: a paper
		/// held off the margin whose number was read back off the margin would
		/// creep inward every time anybody touched it.
		public var home: CGPoint
		/// Where the tail is aimed, or `nil` for a bubble with nothing to point
		/// at — which draws no tail.
		public var tip: CGPoint?
		public var origins: Origins
		/// The moment this drawing was made, which for a breathing bubble is the
		/// beat it began on rather than the frame it is seen on. Every question
		/// above was asked at this moment; ask the next one at it too.
		public var moment: Double
		/// The words, already typeset. Kept so that drawing the bubble and
		/// placing its handles are one pass rather than two typesettings.
		var words: (image: CGImage, size: CGSize)?
	}

	/// Where the paper and the tip are, at one moment.
	///
	/// `size` is the frame, in whatever units the caller is drawing in: a panel
	/// asking about a picture 240 points wide passes that, because every number
	/// a bubble carries is a fraction of the frame and none of them is a pixel.
	public static func placement(
		_ bubble: Bubble, resolved: ResolvedOverlay, project: Project,
		size: CGSize, at time: Double
	) -> Placement {
		let style = project.style(named: bubble.style ?? "bubble")
		// Asked at the drawing's own moment and not at this frame's, so that a
		// handle sits on the bubble that is on screen rather than on the one the
		// face has moved on to since the hand last redrew it.
		let moment = Bubbling.drawn(at: time, from: resolved.timing.drawnFrom,
		                            breath: bubble.breath)
		let words = Bubbling.words(bubble.text, style: style, frame: size, width: bubble.width)
		let home = OverlayLayers.bubbleHome(bubble, resolved: resolved, style: style,
		                                    size: size, at: moment)
		let box = Bubbling.box(
			words: words?.size ?? .zero, shape: bubble.shape, style: style,
			home: home, frame: size,
			give: bubble.follow && resolved.path != nil ? Bubbling.give * size.height : 0)
		return Placement(
			box: box, home: home,
			tip: OverlayLayers.bubbleTarget(bubble, resolved: resolved, at: moment, size: size),
			origins: origins(bubble, resolved: resolved, size: size, at: moment),
			moment: moment, words: words)
	}

	/// The bubble as pixels, and where its handles are, in one call.
	///
	/// One call because a preview needs both and they have to agree: a handle is
	/// on the drawing, not beside it. It is also the call ``OverlayPainter``
	/// makes, so the picture somebody drags a bubble around in is the render's
	/// own drawing at the render's own numbers, at whatever size the picture
	/// happens to be.
	public static func drawing(
		_ bubble: Bubble, resolved: ResolvedOverlay, project: Project,
		size: CGSize, at time: Double
	) -> (image: CGImage?, at: Placement) {
		let placed = placement(bubble, resolved: resolved, project: project,
		                       size: size, at: time)
		guard size.width >= 1, size.height >= 1, let context = CGContext(
			data: nil, width: Int(size.width), height: Int(size.height),
			bitsPerComponent: 8, bytesPerRow: 0,
			space: CGColorSpace(name: CGColorSpace.sRGB)!,
			bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
		else { return (nil, placed) }
		Bubbling.draw(
			bubble, box: placed.box, words: placed.words?.image,
			wordSize: placed.words?.size ?? .zero, pointingAt: placed.tip,
			frame: size, at: placed.moment, into: context)
		return (context.makeImage(), placed)
	}

	/// The two points the bubble's numbers hang off, at one moment.
	///
	/// The branches are ``OverlayLayers/bubbleHome(_:resolved:style:size:at:)``
	/// and ``OverlayLayers/bubbleTarget(_:resolved:at:size:)`` read backwards,
	/// and they have to stay that way — the whole claim of a draggable preview
	/// is that these two functions and those two are one arithmetic.
	public static func origins(
		_ bubble: Bubble, resolved: ResolvedOverlay, size: CGSize, at moment: Double
	) -> Origins {
		func framed(_ unit: CGPoint) -> CGPoint {
			CGPoint(x: unit.x * size.width, y: unit.y * size.height)
		}
		if let path = resolved.path,
		   let paper = bubble.follow ? OverlayLayers.settled(path, at: moment)
			   : path.point(at: resolved.timing.drawnFrom) {
			// The tail asks for the raw point and refuses to guess outside the
			// stretch that was actually solved. So does this: there is nothing
			// to place a tip against at a moment where no tail is drawn.
			let tip = path.covers(moment) ? path.point(at: moment) : nil
			return Origins(paper: framed(paper), tip: tip.map(framed))
		}
		if let at = bubble.at {
			let point = framed(at)
			return Origins(paper: point, tip: point)
		}
		// The style's position, and nothing relative to anything: a bubble with
		// no anchor and no `at:` does not read `offset:` at all.
		return Origins(paper: nil, tip: nil)
	}

	/// The `offset:` that would put the middle of the paper at a point.
	///
	/// The point is a ``Placement/home``, not a ``Placement/paper``: give it
	/// back what was dragged, before the frame's edge pushed the paper inside
	/// the picture. `nil` where there is nothing to be relative to.
	public static func offset(
		forPaper point: CGPoint, origins: Origins, size: CGSize
	) -> CGPoint? {
		guard let origin = origins.paper else { return nil }
		return fraction(point, from: origin, size: size)
	}

	/// The `tail:` that would put the tail's tip at a point. `nil` outside the
	/// stretch the anchor was solved over — see ``Origins``.
	public static func tail(
		forTip point: CGPoint, origins: Origins, size: CGSize
	) -> CGPoint? {
		guard let origin = origins.tip else { return nil }
		return fraction(point, from: origin, size: size)
	}

	/// A distance in the frame, as the file says distances: fractions of the
	/// frame **height** on both axes, so the same number is the same distance
	/// above a head in a 16:9 render and a 4:3 one.
	private static func fraction(_ point: CGPoint, from origin: CGPoint, size: CGSize) -> CGPoint? {
		guard size.height > 0 else { return nil }
		return CGPoint(x: rounded((point.x - origin.x) / size.height),
		               y: rounded((point.y - origin.y) / size.height))
	}

	private static func rounded(_ value: Double) -> Double {
		(value * perWhole).rounded() / perWhole
	}
}
