import AVFoundation
import CoreText
import CuttrKit
import Foundation
import QuartzCore

/// Builds the Core Animation tree the overlays are drawn with.
///
/// **One builder, two hosts.** The tree it returns is attached either over the
/// player for the preview or to an `AVVideoCompositionCoreAnimationTool` for the
/// export, and it is the same tree — so what somebody watches while composing is
/// literally what gets encoded, rather than a second implementation that agrees
/// with the first until it does not. Everything below is declarative for the
/// same reason: a slide is a `CAKeyframeAnimation` on a transform, not a
/// per-frame draw, so both hosts get it for free.
///
/// The only difference between the two is where time zero is, which is what
/// ``Host`` exists for.
public enum OverlayLayers {

	public enum Host {
		/// Attached over an `AVPlayerLayer`, scrubbed by holding the tree at
		/// `speed = 0` and setting `timeOffset` to the playhead.
		case preview
		/// Handed to `AVVideoCompositionCoreAnimationTool`.
		case export

		/// Core Animation reads a `beginTime` of 0 as "now" — during an export
		/// that means "whenever the encoder got here", and in a paused preview
		/// tree it means "whenever this was attached". Either way an overlay
		/// that starts at zero is the one that goes wrong, and it goes wrong
		/// invisibly: everything with a later start behaves.
		///
		/// So zero is never zero. The animation tool's own sentinel for the
		/// beginning of a composition is 1e-100, and it does just as well for a
		/// tree being scrubbed by `timeOffset`.
		func beginTime(_ seconds: Double) -> CFTimeInterval {
			max(seconds, AVCoreAnimationBeginTimeAtZero)
		}
	}

	/// The whole tree, sized to the output frame.
	/// Whether this overlay is one of the ones drawn as layers.
	///
	/// Effects are not: they are geometry with light on it, rendered into the
	/// frame itself, and a layer tree has nothing to say about them.
	///
	/// Public because the panel has to say which of the two passes a row is
	/// drawn in. The order of `overlays:` decides the frame pass; a layer is
	/// over all of it whatever the list says.
	public static func isLayered(_ overlay: Overlay, in project: Project) -> Bool {
		if case .effect = overlay.kind { return false }
		// A scene with a frame sequence in it is painted into the picture, and
		// this is the one place that decides it.
		//
		// Not a preference: Core Animation has to be handed every picture a
		// `contents` animation will ever show, and five hundred frames of
		// 1920×1080 is four gigabytes of bitmap before it keeps its own copy —
		// measured at eight, against forty-seven megabytes for the same card
		// with a shape on it. A layer that fetched each frame as it was asked for
		// was the other answer, and `AVVideoCompositionCoreAnimationTool` never
		// asks a layer to redisplay, so it drew nothing at all.
		//
		// What it costs is z-order: a painted scene is under every layer, so a
		// caption is always over a chart however `overlays:` is arranged. What it
		// buys is that the sequence has *one* implementation — the painter's,
		// which the preview and the export then share exactly — and a peak memory
		// that does not depend on how long the component is.
		if case .scene(let name, _) = overlay.kind,
		   project.scenes[name]?.hasFrames == true { return false }
		// Film mode, the aberration and the tape *are* the picture rather than
		// something laid over it: they are applied in the frame pass with the
		// effects, and a second pass that drew film mode as a layer would
		// letterbox the letterbox.
		if overlay.kind.changesTheFrame { return false }
		// Anything that goes behind somebody is drawn into the frame instead:
		// the mask that knows where they are lives in the pass that has the
		// pixels, and a layer laid over the finished frame is by definition in
		// front of everything in it.
		if overlay.behind == .people { return false }
		return true
	}

	public static func build(_ resolved: ResolvedProject, size: CGSize, host: Host) -> CALayer {
		let root = CALayer()
		root.frame = CGRect(origin: .zero, size: size)
		root.masksToBounds = true
		// No implicit animations anywhere in here: every movement is one this
		// file asked for, and Core Animation's own quarter-second fade on any
		// property change would sit underneath all of them.
		root.isGeometryFlipped = false

		for resolvedOverlay in resolved.overlays
		where isLayered(resolvedOverlay.overlay, in: resolved.project) {
			guard let layer = layer(for: resolvedOverlay, project: resolved.project,
			                        baseURL: resolved.baseURL, size: size, host: host)
			else { continue }
			root.addSublayer(layer)
		}
		return root
	}

	// MARK: - One overlay

	private static func layer(
		for resolved: ResolvedOverlay, project: Project, baseURL: URL, size: CGSize, host: Host
	) -> CALayer? {
		let overlay = resolved.overlay

		// Two layers, and the split is what lets an overlay both follow a face
		// and slide in. The outer one *places* — statically, or along the
		// anchor's path — and the inner one *moves*, in its own coordinates. One
		// layer doing both would need the slide and the tracking added together
		// on the same `position`, which Core Animation will not do: the second
		// animation on a property replaces the first.
		let placer = CALayer()
		let mover = CALayer()

		let content: CALayer
		var contentSize: CGSize
		/// Which point of the content sits on the anchor, in unit coordinates.
		/// `nil` means the middle.
		var contentAnchor: CGPoint?
		switch overlay.kind {
		case .text(let text, let styleName):
			let style = project.style(named: styleName)
			(content, contentSize) = textLayer(text, style: style, size: size)
		case .effect, .film, .aberration, .tape:
			// Drawn into the frame, not over it. Nothing here.
			return placer
		case .scene(let name, let parameters):
			// A scene is its own little tree, laid over the whole frame: its
			// parts carry their own positions, so nothing about the overlay's
			// anchor or style applies to it.
			//
			// What *does* apply is when it is on. Returning the tree bare
			// skipped the envelope every other kind gets, and a scene's own
			// keyframes hold their last value for ever — so the first scene in
			// a programme covered everything after it, and a second card looked
			// as though it had not been rendered at all. It had; it was
			// underneath.
			guard let scene = project.scenes[name] else { return placer }
			let tree = sceneLayer(scene, with: parameters, project: project, baseURL: baseURL,
			                      size: size, resolved: resolved, host: host)
			tree.opacity = 0
			tree.add(opacity(resolved, host: host), forKey: "opacity")
			tree.add(shown(resolved, host: host), forKey: "shown")
			return tree
		case .spinner(let spinner):
			let built = spinnerLayer(
				spinner, style: project.style(named: spinner.wordStyle ?? "caption"),
				size: size, resolved: resolved, host: host)
			content = built.layer
			contentSize = built.size
			contentAnchor = built.anchor
		case .bubble(let bubble):
			// Frame-sized, like a scene, because a bubble's geometry is in the
			// frame's own coordinates: it is clamped to the edges, and its tail
			// reaches a point somewhere else entirely. Placing a small layer and
			// then drawing a tail out of it would mean a layer that has to grow
			// every time somebody walks further away.
			content = bubbleLayer(bubble, project: project, size: size,
			                      resolved: resolved, host: host)
			contentSize = size
			contentAnchor = CGPoint(x: 0.5, y: 0.5)
		}

		mover.frame = CGRect(origin: .zero, size: contentSize)
		mover.addSublayer(content)
		placer.frame = CGRect(origin: .zero, size: contentSize)
		placer.addSublayer(mover)

		// Where it sits, and what the slide is measured against.
		let anchorPoint: CGPoint
		let home: CGPoint
		if case .bubble = overlay.kind {
			// A bubble does not follow its anchor, and that is the one thing
			// about it that is not like every other overlay. It is placed where
			// the face was when it came on and stays there — words that move
			// under the reader cannot be read — and it is the tail, drawn inside
			// this layer, that goes after the face. So no `follow`, and the
			// layer sits over the frame it was drawn in.
			anchorPoint = CGPoint(x: 0.5, y: 0.5)
			home = CGPoint(x: size.width / 2, y: size.height / 2)
		} else if let path = resolved.path {
			// Following something. The point that sits on the anchor is the
			// *spinner*, not the middle of the spinner-and-its-words — a
			// progress spinner over somebody's head should be over their head,
			// and centring the whole block puts it up and to the left by half
			// the width of whatever it happens to be saying. Which also means
			// it moves every time the word changes.
			anchorPoint = contentAnchor ?? CGPoint(x: 0.5, y: 0.5)
			home = position(from: path, at: resolved.start, offset: overlay.offset, size: size)
			placer.add(follow(path, resolved: resolved, offset: overlay.offset, size: size, host: host),
			           forKey: "follow")
		} else if case .text(_, let styleName) = overlay.kind {
			let style = project.style(named: styleName)
			anchorPoint = CGPoint(x: style.alignment == .left ? 0 : style.alignment == .right ? 1 : 0.5, y: 0.5)
			home = CGPoint(x: style.position.x * size.width, y: style.position.y * size.height)
		} else {
			anchorPoint = contentAnchor ?? CGPoint(x: 0.5, y: 0.5)
			home = CGPoint(x: (0.5 + overlay.offset.x) * size.width,
			               y: (0.5 + overlay.offset.y) * size.height)
		}
		placer.anchorPoint = anchorPoint
		// Changing an anchor point moves the layer: Core Animation keeps
		// `position` and shifts the frame by the difference. For the placer that
		// is wanted — its position is set below — but the mover has to stay
		// exactly over it, so it is put back.
		//
		// Left out, the whole block slid right by half the difference, which is
		// nothing when the anchor is the middle and a great deal when it is the
		// spinner at the left end of a spinner-and-its-words. Adding a word
		// moved the spinner off the head it was following.
		mover.anchorPoint = anchorPoint
		mover.position = CGPoint(x: anchorPoint.x * contentSize.width,
		                         y: anchorPoint.y * contentSize.height)
		placer.position = home

		// Hidden unless an animation says otherwise. `fillMode: .both` on the
		// opacity keyframes is what holds it at zero before the overlay's span
		// and after it, so nothing has to be scheduled to take it away.
		placer.opacity = 0
		placer.add(opacity(resolved, host: host), forKey: "opacity")
		placer.add(shown(resolved, host: host), forKey: "shown")

		if let slide = slide(resolved, contentSize: contentSize, frame: size, host: host) {
			mover.add(slide, forKey: "slide")
		}
		return placer
	}

	// MARK: - The animations

	/// On screen for as long as it is drawn, and not one frame longer.
	///
	/// The opacity envelope takes an overlay away at the end only when it
	/// *fades* away; one that leaves by sliding is off the edge of the frame,
	/// and one that leaves by cutting is at full opacity with nowhere to be —
	/// so it stayed. A discrete animation on `isHidden` says the plain thing
	/// the other one only implies, whatever the transitions are.
	///
	/// The preview honours this; `AVVideoCompositionCoreAnimationTool` does
	/// not, which is why the opacity envelope below now brackets itself with
	/// zeroes and does the same work a second time. Both are kept: this one is
	/// the plainer statement, and neither costs anything.
	///
	/// **The window is the drawn one, not the span.** Those were the same thing
	/// until a movement could be placed outside the span; an overlay whose
	/// arrival is placed before its first mark is on screen before that mark,
	/// and bracketing it at the mark would hide exactly the frames the placement
	/// was asked for. ``OverlayTiming`` is where the two are told apart.
	private static func shown(_ resolved: ResolvedOverlay, host: Host) -> CAKeyframeAnimation {
		let timing = resolved.timing
		let animation = CAKeyframeAnimation(keyPath: "hidden")
		animation.values = [true, false, true]
		animation.keyTimes = [0, 0, 1]
		animation.calculationMode = .discrete
		animation.beginTime = host.beginTime(timing.drawnFrom)
		animation.duration = timing.drawnSpan
		animation.fillMode = .both
		animation.isRemovedOnCompletion = false
		return animation
	}

	/// In, hold, out — as one keyframe animation over everything the overlay is
	/// drawn for.
	///
	/// One animation rather than three, because the three would have to be kept
	/// in step by hand and the interesting case is when they meet: an overlay
	/// ending exactly where the next begins gives one fading out while the other
	/// fades in, with nothing to arrange.
	private static func opacity(_ resolved: ResolvedOverlay, host: Host) -> CAKeyframeAnimation {
		let animation = CAKeyframeAnimation(keyPath: "opacity")
		let timing = resolved.timing
		// A slide arrives at full opacity — it is the movement that shows it —
		// while a fade is the opacity. A cut is neither and simply appears.
		let arrivesByFading = timing.arrivesByFading
		let departsByFading = timing.departsByFading
		// Zero at each end, held there by `fillMode: .both`, is what keeps the
		// overlay off screen outside the window it is drawn for — whatever its
		// transitions are.
		//
		// This used to be left to a discrete animation on `hidden`, which the
		// preview honours and the export tool quietly does not. An overlay with
		// `in: cut, out: cut` was on for the whole film: the one spelling with
		// no fade to hide the mistake, and so the one nobody could see was
		// wrong until it was measured.
		//
		// The keyframes are placed by asking ``OverlayTiming`` where each moment
		// falls in the drawn window rather than by dividing by the span. That is
		// the same arithmetic while a movement is taken from inside the span,
		// and the only arithmetic that survives one that is not: an arrival
		// placed before the first mark starts the window early, and the ramp has
		// to start with it.
		//
		// A cut is a step rather than a movement, but it cannot be written as
		// two keyframes at the same instant — Core Animation renders a span of
		// zero length as no span at all, which is how the bug survived a first
		// attempt at this. So a cut takes `step`: a thousandth of the overlay's
		// time on screen, under a millisecond for anything short enough to
		// notice and well inside one frame. The same goes for the last pair:
		// a step written as two keyframes at the end is no step at all, and the
		// overlay stayed up.
		let step = 0.001
		var times: [Double] = []
		var values: [Double] = []
		func at(_ time: Double, _ value: Double) {
			times.append(min(1, max(times.last ?? 0, time)))
			values.append(value)
		}
		at(0, 0)
		if !arrivesByFading { at(step, 1) }
		at(max(timing.fraction(at: timing.arriveTo), arrivesByFading ? 0 : step), 1)
		at(departsByFading ? timing.fraction(at: timing.departFrom) : 1 - step, 1)
		at(1, 0)
		animation.values = values
		animation.keyTimes = times.map(NSNumber.init(value:))
		animation.timingFunctions = (1..<values.count).map { index in
			// Ease only where something is actually moving: the arrival is the
			// second segment of a fade, the departure the second to last.
			if arrivesByFading, index == 1 { return CAMediaTimingFunction(name: .easeOut) }
			if departsByFading, index == values.count - 1 { return CAMediaTimingFunction(name: .easeIn) }
			return CAMediaTimingFunction(name: .linear)
		}
		animation.beginTime = host.beginTime(timing.drawnFrom)
		animation.duration = timing.drawnSpan
		animation.fillMode = .both
		animation.isRemovedOnCompletion = false
		return animation
	}

	/// The horizontal or vertical movement, if either end asks for one.
	private static func slide(
		_ resolved: ResolvedOverlay, contentSize: CGSize, frame: CGSize, host: Host
	) -> CAKeyframeAnimation? {
		let arrival = resolved.overlay.arrival
		let departure = resolved.overlay.departure
		guard case .slide = arrival, true else {
			if case .slide = departure {} else { return nil }
			return slideAnimation(resolved, contentSize: contentSize, frame: frame, host: host)
		}
		return slideAnimation(resolved, contentSize: contentSize, frame: frame, host: host)
	}

	private static func slideAnimation(
		_ resolved: ResolvedOverlay, contentSize: CGSize, frame: CGSize, host: Host
	) -> CAKeyframeAnimation {
		let timing = resolved.timing

		func offscreen(_ transition: Overlay.Transition) -> CGPoint {
			guard case .slide(let edge, _) = transition else { return .zero }
			// Far enough that the whole thing is outside the frame whatever its
			// size — the frame's own dimension plus the content's, so a wide
			// caption does not leave a corner showing while it waits.
			switch edge {
			case .left: return CGPoint(x: -(frame.width + contentSize.width), y: 0)
			case .right: return CGPoint(x: frame.width + contentSize.width, y: 0)
			case .up: return CGPoint(x: 0, y: frame.height + contentSize.height)
			case .down: return CGPoint(x: 0, y: -(frame.height + contentSize.height))
			}
		}

		let from = offscreen(resolved.overlay.arrival)
		let to = offscreen(resolved.overlay.departure)
		let animation = CAKeyframeAnimation(keyPath: "transform.translation")
		animation.values = [
			NSValue(point: NSPoint(x: from.x, y: from.y)),
			NSValue(point: .zero),
			NSValue(point: .zero),
			NSValue(point: NSPoint(x: to.x, y: to.y)),
		]
		// Over the drawn window, so a slide placed before the mark travels in the
		// seconds leading up to it and is home for the clip's first frame —
		// which is what "finished when the clip starts" means for a movement
		// that is a movement rather than a fade.
		animation.keyTimes = [
			0,
			NSNumber(value: timing.fraction(at: timing.arriveTo)),
			NSNumber(value: timing.fraction(at: timing.departFrom)),
			1,
		]
		// Eased at both ends: a caption that arrives at constant speed and stops
		// dead reads as a bug in the render rather than as a move.
		animation.timingFunctions = [
			CAMediaTimingFunction(name: .easeOut),
			CAMediaTimingFunction(name: .linear),
			CAMediaTimingFunction(name: .easeIn),
		]
		animation.beginTime = host.beginTime(timing.drawnFrom)
		animation.duration = timing.drawnSpan
		animation.fillMode = .both
		animation.isRemovedOnCompletion = false
		return animation
	}

	/// Following the anchor: the solved path, as keyframes on `position`.
	private static func follow(
		_ path: AnchorPath, resolved: ResolvedOverlay, offset: CGPoint, size: CGSize, host: Host
	) -> CAKeyframeAnimation {
		let timing = resolved.timing
		// Only the samples inside the window the overlay is drawn for, with the
		// ends pinned so the first and last keyframe land exactly on its edges.
		// The drawn window rather than the span, because an overlay arriving
		// before its first mark is following a face over those frames too, and
		// holding the position it will have at the mark puts it beside where the
		// head is going to be rather than where it is.
		var times: [Double] = [timing.drawnFrom]
		times += path.samples.map(\.time)
			.filter { $0 > timing.drawnFrom && $0 < timing.drawnUntil }
		times.append(timing.drawnUntil)

		let animation = CAKeyframeAnimation(keyPath: "position")
		animation.values = times.map { time in
			NSValue(point: position(from: path, at: time, offset: offset, size: size))
		}
		animation.keyTimes = times.map { NSNumber(value: timing.fraction(at: $0)) }
		animation.calculationMode = .linear
		animation.beginTime = host.beginTime(timing.drawnFrom)
		animation.duration = timing.drawnSpan
		animation.fillMode = .both
		animation.isRemovedOnCompletion = false
		return animation
	}

	/// Where an anchored overlay sits at a moment.
	///
	/// The offset is in fractions of the frame **height** on both axes, so a
	/// spinner stays the same distance above a head whatever the aspect ratio —
	/// using each axis's own dimension would squash the offset on a wide frame.
	private static func position(
		from path: AnchorPath, at time: Double, offset: CGPoint, size: CGSize
	) -> CGPoint {
		let point = path.point(at: time) ?? CGPoint(x: 0.5, y: 0.5)
		return CGPoint(x: point.x * size.width + offset.x * size.height,
		               y: point.y * size.height + offset.y * size.height)
	}

	// MARK: - The content

	/// A caption, drawn once into an image.
	///
	/// Not a `CATextLayer`, which is the obvious choice and does not work here.
	/// A `CATextLayer` draws its string in a `display()` pass, and
	/// `AVVideoCompositionCoreAnimationTool` renders the tree without giving one
	/// — so the plate behind the text (a `backgroundColor`, which the render
	/// server handles) came out, the text did not, and every caption exported as
	/// an empty box. It looked right in a window and wrong in the file, which is
	/// the exact failure this design exists to avoid.
	///
	/// CoreText into a bitmap has no such pass: the image is `contents` before
	/// anybody renders anything, and the preview and the export show the same
	/// pixels because they are the same pixels.
	/// `tracking` opens the letters out, as a fraction of the type size, and
	/// `ink` overrides the style's colour for the moment being drawn. Both are
	/// what a scene's parts ask for and no caption ever does, so both default
	/// to "as the style says".
	/// One line of type, set: the line itself and the plate it needs.
	///
	/// Its own function because there are two callers that must agree to the
	/// pixel — the layer that draws the words, and ``Scene/Roll`` laying a
	/// column of them out — and a second measurement written beside the first
	/// is a measurement that eventually disagrees. A credit roll whose lines
	/// were measured a little differently from the way they are drawn is a roll
	/// whose right-hand column does not line up, and nobody would guess why.
	static func typeset(
		_ text: String, style: TextStyle, size: CGSize, tracking: Double = 0,
		ink: RGBA? = nil
	) -> (line: CTLine, plate: CGSize, descent: CGFloat, scale: CGFloat) {
		// Twice the output resolution. Type is the thing people notice, and a
		// caption drawn at 1× and scaled is soft in a way a plate is not.
		let scale: CGFloat = 2
		let pointSize = style.size * size.height * scale
		let font = CTFontCreateWithName(style.font as CFString, pointSize, nil)
		var attributes: [NSAttributedString.Key: Any] = [
			kCTFontAttributeName as NSAttributedString.Key: font,
			kCTForegroundColorAttributeName as NSAttributedString.Key: cgColor(ink ?? style.color),
		]
		// CoreText adds the tracking after the last glyph as well, so a tracked
		// line measures one space wider than it looks. Left in rather than
		// trimmed: the line is then centred on its own middle, and taking it
		// off shifts a centred title half a letter to the left of where the
		// same words untracked would sit.
		if tracking != 0 {
			attributes[kCTKernAttributeName as NSAttributedString.Key] = tracking * pointSize
		}
		let attributed = NSAttributedString(string: text, attributes: attributes)
		let line = CTLineCreateWithAttributedString(attributed)
		var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
		let textWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
		let padding = style.padding * size.height * scale
		let pixelSize = CGSize(width: (textWidth + padding * 2).rounded(.up),
		                       height: (ascent + descent + padding * 2).rounded(.up))
		return (line, CGSize(width: pixelSize.width / scale, height: pixelSize.height / scale),
		        descent, scale)
	}

	/// The plate one line of type comes to, without drawing it.
	static func measured(
		_ text: String, style: TextStyle, size: CGSize, tracking: Double = 0
	) -> CGSize {
		typeset(text, style: style, size: size, tracking: tracking).plate
	}

	static func textLayer(
		_ text: String, style: TextStyle, size: CGSize,
		tracking: Double = 0, ink: RGBA? = nil
	) -> (CALayer, CGSize) {
		let (line, plateSize, descent, scale) = typeset(
			text, style: style, size: size, tracking: tracking, ink: ink ?? style.color)
		let padding = style.padding * size.height * scale
		// Back up from the plate, which is the rounded pixels divided by the
		// scale: multiplying by two what was divided by two is exact.
		let pixelSize = CGSize(width: plateSize.width * scale,
		                       height: plateSize.height * scale)

		let layer = CALayer()
		layer.frame = CGRect(origin: .zero, size: plateSize)
		layer.contentsScale = scale

		guard pixelSize.width > 0, pixelSize.height > 0,
		      let context = CGContext(
				data: nil,
				width: Int(pixelSize.width), height: Int(pixelSize.height),
				bitsPerComponent: 8, bytesPerRow: 0,
				space: CGColorSpace(name: CGColorSpace.sRGB)!,
				bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
		else { return (layer, plateSize) }

		if style.background.a > 0 {
			context.setFillColor(cgColor(style.background))
			let radius = min(style.cornerRadius * size.height * scale, pixelSize.height / 2)
			context.addPath(CGPath(
				roundedRect: CGRect(origin: .zero, size: pixelSize),
				cornerWidth: radius, cornerHeight: radius, transform: nil))
			context.fillPath()
		}
		// CoreText draws from the baseline up, and a bitmap context is already
		// bottom-left origin, so nothing is flipped: the baseline sits one
		// descent above the padding.
		context.textPosition = CGPoint(x: padding, y: padding + descent)
		CTLineDraw(line, context)

		layer.contents = context.makeImage()
		layer.contentsGravity = .resize
		return (layer, plateSize)
	}

	// MARK: - A bubble

	/// A bubble, as shape layers over the frame.
	///
	/// The paper and the words are drawn once. The tail is keyframed, at the
	/// anchor's own sample times, from the same ``Bubbling/paths(_:box:pointingAt:frame:pass:)``
	/// the painter calls — so what somebody watches in the window is what the
	/// export encodes, which is the rule this whole file exists to keep.
	///
	/// For a speech bubble the tail is *in* the outline, so it is the body path
	/// that is keyframed; the body's own points do not change, so nothing but
	/// the tail moves. The other two shapes keep their tail in a second path,
	/// which is what lets a thought bubble's puffs be paper and a box's arrow be
	/// only a line.
	private static func bubbleLayer(
		_ bubble: Bubble, project: Project, size: CGSize,
		resolved: ResolvedOverlay, host: Host
	) -> CALayer {
		let container = CALayer()
		container.frame = CGRect(origin: .zero, size: size)
		let style = project.style(named: bubble.style ?? "bubble")
		let drawn = Bubbling.words(bubble.text, style: style, frame: size, width: bubble.width)
		// Where the paper is at a moment. The words are measured once — a bubble
		// says the same thing all the way through, so it is the same size all the
		// way through — but where that rectangle *sits* is a question per moment
		// now that it travels with the face.
		let travelling = bubble.follow && resolved.path != nil
		func box(at time: Double) -> CGRect {
			Bubbling.box(words: drawn?.size ?? .zero, shape: bubble.shape, style: style,
			             home: bubbleHome(bubble, resolved: resolved, style: style,
			                              size: size, at: time),
			             frame: size, give: travelling ? Bubbling.give * size.height : 0)
		}

		// When the tail is redrawn: at every sample the anchor has inside the
		// window this bubble is drawn for, with the ends pinned — the same list
		// ``follow(_:…)`` uses, and for the same reason. A bubble finished
		// arriving before the clip starts is a bubble whose words can be read
		// from the clip's first frame, which is the reason somebody would ask
		// for it; a tail frozen on the mark's position over those frames would
		// be pointing at where the face is about to be.
		let (moments, held) = bubbleMoments(resolved)
		func target(at time: Double) -> CGPoint? {
			bubbleTarget(bubble, resolved: resolved, at: time, size: size)
		}
		let timing = resolved.timing

		/// One property of one layer, over this bubble's moments.
		func keyframed(_ key: String, _ value: (Double) -> Any) -> CAKeyframeAnimation {
			let animation = CAKeyframeAnimation(keyPath: key)
			animation.values = moments.map(value)
			animation.keyTimes = moments.map { NSNumber(value: timing.fraction(at: $0)) }
			if held {
				// Discrete wants one key time more than it has values: each pair
				// of them is when one drawing is up, so the last one closes the
				// final drawing's turn rather than opening another. Given the
				// same count as the values, Core Animation drops the last
				// drawing — and given no key times at all it would space them
				// evenly and lose the beat.
				animation.keyTimes?.append(NSNumber(value: 1))
				animation.calculationMode = .discrete
			} else {
				animation.calculationMode = .linear
			}
			animation.beginTime = host.beginTime(timing.drawnFrom)
			animation.duration = timing.drawnSpan
			animation.fillMode = .both
			animation.isRemovedOnCompletion = false
			return animation
		}

		func animate(_ layer: CAShapeLayer, _ path: @escaping (Double) -> CGPath?) {
			guard moments.count > 1 else {
				layer.path = path(moments[0])
				return
			}
			let animation = keyframed("path") { path($0) ?? CGMutablePath() }
			layer.path = animation.values?.first as! CGPath?
			layer.add(animation, forKey: "path")
		}

		let weight = Bubbling.lineWidth(for: size)
		for pass in 0 ..< 2 {
			func made() -> CAShapeLayer {
				let layer = CAShapeLayer()
				layer.frame = container.bounds
				layer.strokeColor = Bubbling.cg(bubble.line, alpha: pass == 0 ? 1 : 0.5)
				layer.lineWidth = weight * (pass == 0 ? 1 : 0.72)
				layer.lineJoin = .round
				layer.lineCap = .round
				layer.fillColor = nil
				return layer
			}
			// The tail first, so the puffs of a thought bubble sit under the
			// paper rather than over it — the same order the painter draws in.
			if !Bubbling.tailIsInTheBody(bubble.shape) {
				let tail = made()
				let paths = Bubbling.paths(bubble, box: box(at: moments[0]),
				                           pointingAt: target(at: moments[0]),
				                           frame: size, pass: pass, at: moments[0])
				if paths.tailIsPaper, pass == 0 { tail.fillColor = Bubbling.cg(bubble.fill) }
				animate(tail) { time in
					Bubbling.paths(bubble, box: box(at: time), pointingAt: target(at: time),
					               frame: size, pass: pass, at: time).tail
				}
				container.addSublayer(tail)
			}
			let body = made()
			if pass == 0 { body.fillColor = Bubbling.cg(bubble.fill) }
			if Bubbling.tailIsInTheBody(bubble.shape) {
				animate(body) { time in
					Bubbling.paths(bubble, box: box(at: time), pointingAt: target(at: time),
					               frame: size, pass: pass, at: time).body
				}
			} else if held || travelling {
				// The outline moves whether or not its tail is part of it: the
				// hand redraws it, and the paper travels. So a thought bubble's
				// cloud and a box's rectangle get a keyframe a moment as well.
				// Only when one of those is true: a still bubble pinned to a spot
				// is the same paper all the way through, and keyframing one
				// drawing sixteen times is sixteen copies of a path to no end.
				animate(body) { time in
					Bubbling.paths(bubble, box: box(at: time), pointingAt: nil,
					               frame: size, pass: pass, at: time).body
				}
			} else {
				body.path = Bubbling.paths(bubble, box: box(at: moments[0]), pointingAt: nil,
				                           frame: size, pass: pass, at: moments[0]).body
			}
			container.addSublayer(body)
		}

		if let drawn {
			let words = CALayer()
			let middle = box(at: moments[0])
			words.frame = CGRect(x: middle.midX - drawn.size.width / 2,
			                     y: middle.midY - drawn.size.height / 2,
			                     width: drawn.size.width, height: drawn.size.height)
			words.contents = drawn.image
			words.contentsGravity = .resize
			words.contentsScale = 2
			// The type is one image, moved — never redrawn, never re-wrapped, and
			// never scaled. What travels with the face is where the sentence is,
			// not what it is made of, so there is nothing here for the following
			// to smear. And it moves exactly as the paper does, on the same
			// moments and by the same rule: held where the drawing is held, and
			// interpolated where it is not. Words gliding under an outline that
			// steps would be the type and the paper coming apart.
			if travelling, moments.count > 1 {
				words.add(keyframed("position") { time in
					let at = box(at: time)
					return NSValue(point: CGPoint(x: at.midX, y: at.midY))
				}, forKey: "position")
			}
			container.addSublayer(words)
		}
		return container
	}

	/// The moments a bubble is redrawn at, and whether each drawing is *held*.
	///
	/// Two answers, because a bubble has two reasons to be redrawn and they do
	/// not want the same treatment:
	///
	/// - **The face moved.** The anchor's own samples, ten a second, which is
	///   how finely it was solved. Interpolated, so the tail sweeps round
	///   smoothly as somebody walks.
	/// - **The hand redrew it.** The programme's drawing beats,
	///   ``Bubbling/drawingsPerSecond`` of them a second. *Held*, because a
	///   drawing that slides into the next one is a rubber line rather than a
	///   second drawing.
	///
	/// **A breathing bubble takes the second answer for both**, and that is the
	/// only interesting decision in here. The tail's position is part of the
	/// drawing: when the whole cel is redrawn eight times a second, so is where
	/// the tail points, and a tail sliding smoothly under an outline that is
	/// stepping is two different hands. What it costs is that the tail lags the
	/// face by up to an eighth of a second — which is what a drawn tail does,
	/// and which is smaller than the anchor's own sample spacing was already.
	///
	/// A still bubble is exactly what it was: the anchor's samples, interpolated,
	/// or a single drawing where there is nothing to follow.
	static func bubbleMoments(_ resolved: ResolvedOverlay) -> (times: [Double], held: Bool) {
		let timing = resolved.timing
		if case .bubble(let bubble) = resolved.overlay.kind, bubble.breath > 0 {
			return (Bubbling.drawings(from: timing.drawnFrom, to: timing.drawnUntil), true)
		}
		guard let path = resolved.path, !path.isEmpty else { return ([timing.drawnFrom], false) }
		var times: [Double] = [timing.drawnFrom]
		times += path.samples.map(\.time)
			.filter { $0 > timing.drawnFrom && $0 < timing.drawnUntil }
		times.append(timing.drawnUntil)
		return (times, false)
	}

	/// What the bubble points at, at one moment, in frame coordinates.
	///
	/// The anchor's own point plus the bubble's ``Bubble/tail`` — the second of
	/// the two positions a bubble carries, and the reason an arrow can land on a
	/// head while the thing being tracked is an eye. Added to the tracked point
	/// rather than to the frame, so it goes on being her head as she walks.
	///
	/// The *raw* anchor, not the smoothed one the paper uses. A tail is allowed
	/// to be lively — it is a line, not a sentence — and a tail that lagged the
	/// face by the width of the smoothing would visibly miss the mouth it is
	/// meant to be coming out of.
	///
	/// `nil` where there is nothing to point at: outside the stretch the anchor
	/// was actually solved over, and for a bubble with no anchor and no `at:`.
	/// The bubble keeps its words and loses its tail, which is the honest thing
	/// — a tail held on the last place a face was seen says the tracking is
	/// still working when it is not.
	static func bubbleTarget(
		_ bubble: Bubble, resolved: ResolvedOverlay, at time: Double, size: CGSize
	) -> CGPoint? {
		// In fractions of the frame height on both axes, as every offset in this
		// format is — so a tail asked for the top of a head is the same tail in a
		// 4:3 frame and a 21:9 one.
		let tail = CGPoint(x: bubble.tail.x * size.height, y: bubble.tail.y * size.height)
		if let path = resolved.path, !path.isEmpty {
			guard path.covers(time), let point = path.point(at: time) else { return nil }
			return CGPoint(x: point.x * size.width + tail.x, y: point.y * size.height + tail.y)
		}
		return bubble.at.map {
			CGPoint(x: $0.x * size.width + tail.x, y: $0.y * size.height + tail.y)
		}
	}

	/// How long the anchor is averaged over to place a travelling bubble, in
	/// seconds.
	///
	/// A tracker's answer jitters by a pixel or two from one sample to the next.
	/// It is a fresh measurement each time and not a physical object with
	/// momentum, so the jitter is at the sample rate — and type that jitters is
	/// type nobody can read. A face crossing a shot, on the other hand, takes
	/// seconds. Six tenths of a second sits comfortably between the two: it
	/// averages nine of the anchor's ten-a-second samples, which flattens the
	/// jitter to nothing and lets the walk through.
	static let settling = 0.6

	/// Where the anchor is, slowly.
	///
	/// A cosine-weighted average of the path over ``settling`` seconds, centred
	/// on the moment. Three things about it are the reasons it is this and not
	/// something else:
	///
	/// - **Centred, so it costs no lag at all.** A live filter can only look
	///   backwards and therefore always trails. The path is solved before
	///   anything is drawn, so this can look forward as well — and a symmetric
	///   average reproduces movement at a constant speed *exactly*. Only changes
	///   of speed are softened. What it costs instead is three tenths of a second
	///   of anticipation: the paper begins to drift a moment before the face
	///   does, which on a walk is invisible, and is the better trade, because a
	///   bubble that trails a face looks dragged along behind it.
	/// - **Weighted rather than flat.** With a plain average, a sample entering
	///   or leaving the window steps the answer by a ninth of the jitter the
	///   window was put there to remove. A weight that goes to nothing at both
	///   ends means nothing enters or leaves except at nothing.
	/// - **No state between frames.** It is an average over a path that is
	///   already entirely known, so a preview scrubbed backwards draws exactly
	///   what playing forwards drew, and a render agrees with both.
	static func settled(_ path: AnchorPath, at time: Double) -> CGPoint? {
		guard !path.isEmpty else { return nil }
		let taps = 8
		let step = settling / 2 / Double(taps)
		var total = 0.0, x = 0.0, y = 0.0
		for tap in -taps ... taps {
			// Hann: one in the middle, nothing at either end.
			let weight = 0.5 * (1 + cos(Double.pi * Double(tap) / Double(taps)))
			guard weight > 0, let point = path.point(at: time + Double(tap) * step) else { continue }
			x += point.x * weight
			y += point.y * weight
			total += weight
		}
		guard total > 0 else { return path.point(at: time) }
		return CGPoint(x: x / total, y: y / total)
	}

	/// Where the middle of the paper goes at a moment: beside the thing it points
	/// at, or where the style says for a bubble that points at nothing.
	static func bubbleHome(
		_ bubble: Bubble, resolved: ResolvedOverlay, style: TextStyle, size: CGSize,
		at time: Double
	) -> CGPoint {
		let offset = resolved.overlay.offset
		// Travelling with the face, or placed once where the face was when the
		// bubble came on — clamped rather than covered, because placing it is a
		// different question from pointing at it, and a bubble that refuses to
		// appear because the tracking has a hole at that exact instant is no use
		// to anybody.
		//
		// "Came on" is the first frame it is *drawn*, not its first mark. For
		// everything written before placements existed those are the same
		// instant; for a bubble whose arrival is placed before the mark, the
		// first frame is the one somebody sees it appear on, and that is the
		// frame its paper should be beside the face on.
		if let path = resolved.path,
		   let point = bubble.follow ? settled(path, at: time)
			   : path.point(at: resolved.timing.drawnFrom) {
			return CGPoint(x: point.x * size.width + offset.x * size.height,
			               y: point.y * size.height + offset.y * size.height)
		}
		if let at = bubble.at {
			return CGPoint(x: at.x * size.width + offset.x * size.height,
			               y: at.y * size.height + offset.y * size.height)
		}
		return CGPoint(x: style.position.x * size.width, y: style.position.y * size.height)
	}

	private static func spinnerLayer(
		_ spinner: Spinner, style: TextStyle, size: CGSize,
		resolved: ResolvedOverlay, host: Host
	) -> (layer: CALayer, size: CGSize, anchor: CGPoint) {
		let diameter = spinner.size * size.height
		var box = CGSize(width: diameter, height: diameter)
		let container = CALayer()

		// The words, if there are any: measured first, because the container has
		// to be wide enough for the longest of them or the whole thing shifts
		// under the anchor every time the text changes.
		let schedule = spinner.schedule(over: resolved.duration)
		var wordLayers: [(CALayer, CGSize)] = []
		if !schedule.isEmpty {
			let gap = diameter * 0.45
			for (word, _) in schedule {
				wordLayers.append(textLayer(word.text, style: style, size: size))
			}
			let widest = wordLayers.map(\.1.width).max() ?? 0
			let tallest = wordLayers.map(\.1.height).max() ?? 0
			box = CGSize(width: diameter + gap + widest, height: max(diameter, tallest))
		}
		container.frame = CGRect(origin: .zero, size: box)

		let spin = CABasicAnimation(keyPath: "transform.rotation.z")
		spin.fromValue = 0
		// Clockwise, which is what a spinner does. Core Animation's z rotation
		// is counter-clockwise in an unflipped layer, hence the sign.
		spin.toValue = -2 * Double.pi
		spin.duration = max(0.05, 1 / max(spinner.speed, 0.01))
		spin.repeatCount = .greatestFiniteMagnitude
		spin.isRemovedOnCompletion = false
		// From the start of the composition rather than "now": under the
		// animation tool there is no now.
		spin.beginTime = host.beginTime(0)

		switch spinner.style {
		case .dots:
			// A replicator: one dot, copied round the circle, each a step
			// further through the same fade. Twelve layers instead of twelve
			// animations, and the phase falls out of `instanceDelay`.
			let count = 12
			let replicator = CAReplicatorLayer()
			replicator.frame = CGRect(x: 0, y: (box.height - diameter) / 2,
			                          width: diameter, height: diameter)
			replicator.instanceCount = count
			replicator.instanceDelay = spin.duration / Double(count)
			replicator.instanceTransform = CATransform3DMakeRotation(-2 * .pi / Double(count), 0, 0, 1)

			let dotDiameter = diameter * 0.16
			let dot = CALayer()
			dot.frame = CGRect(x: (diameter - dotDiameter) / 2, y: diameter - dotDiameter * 1.4,
			                   width: dotDiameter, height: dotDiameter)
			dot.cornerRadius = dotDiameter / 2
			dot.backgroundColor = cgColor(spinner.color)

			let pulse = CABasicAnimation(keyPath: "opacity")
			pulse.fromValue = 1
			pulse.toValue = 0.12
			pulse.duration = spin.duration
			pulse.repeatCount = .greatestFiniteMagnitude
			pulse.isRemovedOnCompletion = false
			pulse.beginTime = host.beginTime(0)
			dot.add(pulse, forKey: "pulse")
			replicator.addSublayer(dot)
			container.addSublayer(replicator)
			// The spin goes on the spinner, not on the container. On the
			// container it turned the words with it — they rendered at an angle
			// and, half a second later, upside down.
			replicator.add(spin, forKey: "spin")

		case .bars:
			// The same replicator idea as the dots, with a tapered spoke that
			// reaches the rim. Rounded ends, because a square-ended spoke at
			// this size reads as a scratch on the lens.
			let count = 12
			let replicator = CAReplicatorLayer()
			replicator.frame = CGRect(x: 0, y: (box.height - diameter) / 2,
			                          width: diameter, height: diameter)
			replicator.instanceCount = count
			replicator.instanceDelay = spin.duration / Double(count)
			replicator.instanceTransform = CATransform3DMakeRotation(-2 * .pi / Double(count), 0, 0, 1)

			let barWidth = diameter * 0.09
			let barHeight = diameter * 0.28
			let bar = CALayer()
			bar.frame = CGRect(x: (diameter - barWidth) / 2, y: diameter - barHeight - diameter * 0.04,
			                   width: barWidth, height: barHeight)
			bar.cornerRadius = barWidth / 2
			bar.backgroundColor = cgColor(spinner.color)

			let fade = CABasicAnimation(keyPath: "opacity")
			fade.fromValue = 1
			fade.toValue = 0.1
			fade.duration = spin.duration
			fade.repeatCount = .greatestFiniteMagnitude
			fade.isRemovedOnCompletion = false
			fade.beginTime = host.beginTime(0)
			bar.add(fade, forKey: "fade")
			replicator.addSublayer(bar)
			container.addSublayer(replicator)
			replicator.add(spin, forKey: "spin")

		case .orbit:
			// A track that does not move and a dot that does, so the eye has
			// something to measure the movement against.
			let track = CAShapeLayer()
			let trackBox = CGRect(x: 0, y: (box.height - diameter) / 2, width: diameter, height: diameter)
			let inset = diameter * 0.12
			track.frame = trackBox
			track.path = CGPath(
				ellipseIn: CGRect(origin: .zero, size: trackBox.size).insetBy(dx: inset, dy: inset),
				transform: nil)
			track.fillColor = nil
			track.strokeColor = cgColor(spinner.color, alpha: 0.25)
			track.lineWidth = diameter * 0.07
			container.addSublayer(track)

			let carrier = CALayer()
			carrier.frame = trackBox
			let dotDiameter = diameter * 0.2
			let dot = CALayer()
			dot.frame = CGRect(x: (diameter - dotDiameter) / 2, y: diameter - inset - dotDiameter / 2 - diameter * 0.035,
			                   width: dotDiameter, height: dotDiameter)
			dot.cornerRadius = dotDiameter / 2
			dot.backgroundColor = cgColor(spinner.color)
			carrier.addSublayer(dot)
			carrier.anchorPoint = CGPoint(x: 0.5, y: 0.5)
			carrier.frame = trackBox
			container.addSublayer(carrier)
			carrier.add(spin, forKey: "spin")

		case .pulse:
			// Scale and opacity in step, and no rotation at all: it is not
			// going round anything.
			let ring = CAShapeLayer()
			let ringBox = CGRect(x: 0, y: (box.height - diameter) / 2, width: diameter, height: diameter)
			ring.frame = ringBox
			let ringInset = diameter * 0.14
			ring.path = CGPath(
				ellipseIn: CGRect(origin: .zero, size: ringBox.size).insetBy(dx: ringInset, dy: ringInset),
				transform: nil)
			ring.fillColor = cgColor(spinner.color, alpha: 0.18)
			ring.strokeColor = cgColor(spinner.color)
			ring.lineWidth = diameter * 0.08
			ring.anchorPoint = CGPoint(x: 0.5, y: 0.5)
			ring.frame = ringBox
			container.addSublayer(ring)

			let breathe = CABasicAnimation(keyPath: "transform.scale")
			breathe.fromValue = 0.72
			breathe.toValue = 1
			breathe.duration = spin.duration
			breathe.autoreverses = true
			breathe.repeatCount = .greatestFiniteMagnitude
			breathe.isRemovedOnCompletion = false
			breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
			breathe.beginTime = host.beginTime(0)
			ring.add(breathe, forKey: "breathe")

			let dim = CABasicAnimation(keyPath: "opacity")
			dim.fromValue = 0.45
			dim.toValue = 1
			dim.duration = spin.duration
			dim.autoreverses = true
			dim.repeatCount = .greatestFiniteMagnitude
			dim.isRemovedOnCompletion = false
			dim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
			dim.beginTime = host.beginTime(0)
			ring.add(dim, forKey: "dim")

		case .bounce:
			// Three dots in a row, each rising a third of a cycle after the
			// one before — the terminal's way of saying it is thinking, and the
			// only one of these that is wider than it is tall.
			let dots = 3
			let dotDiameter = diameter * 0.26
			let gap = (diameter - dotDiameter * CGFloat(dots)) / CGFloat(dots - 1)
			let replicator = CAReplicatorLayer()
			replicator.frame = CGRect(x: 0, y: (box.height - diameter) / 2,
			                          width: diameter, height: diameter)
			replicator.instanceCount = dots
			replicator.instanceDelay = spin.duration / Double(dots)
			replicator.instanceTransform = CATransform3DMakeTranslation(dotDiameter + gap, 0, 0)

			let dot = CALayer()
			dot.frame = CGRect(x: 0, y: (diameter - dotDiameter) / 2 - diameter * 0.1,
			                   width: dotDiameter, height: dotDiameter)
			dot.cornerRadius = dotDiameter / 2
			dot.backgroundColor = cgColor(spinner.color)

			let hop = CABasicAnimation(keyPath: "transform.translation.y")
			hop.fromValue = 0
			hop.toValue = diameter * 0.28
			hop.duration = spin.duration / 2
			hop.autoreverses = true
			hop.repeatCount = .greatestFiniteMagnitude
			hop.isRemovedOnCompletion = false
			hop.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
			hop.beginTime = host.beginTime(0)
			dot.add(hop, forKey: "hop")
			replicator.addSublayer(dot)
			container.addSublayer(replicator)

		case .ring, .arc:
			let ring = CAShapeLayer()
			let ringBox = CGRect(x: 0, y: (box.height - diameter) / 2, width: diameter, height: diameter)
			ring.frame = ringBox
			let inset = diameter * 0.12
			ring.path = CGPath(
				ellipseIn: CGRect(origin: .zero, size: ringBox.size).insetBy(dx: inset, dy: inset),
				transform: nil)
			ring.fillColor = nil
			ring.strokeColor = cgColor(spinner.color)
			ring.lineWidth = diameter * 0.10
			ring.lineCap = .round
			ring.strokeStart = 0
			ring.strokeEnd = spinner.style == .ring ? 0.75 : 0.28
			container.addSublayer(ring)
			// The ring is what turns, so the animation goes on it and its
			// anchor point has to be the middle of the box rather than a corner.
			ring.anchorPoint = CGPoint(x: 0.5, y: 0.5)
			ring.frame = ringBox
			ring.add(spin, forKey: "spin")
			addWords(wordLayers, schedule: schedule, to: container, spinnerDiameter: diameter,
			         box: box, resolved: resolved, host: host)
			return (container, box, spinnerAnchor(diameter: diameter, box: box))
		}

		addWords(wordLayers, schedule: schedule, to: container, spinnerDiameter: diameter,
		         box: box, resolved: resolved, host: host)
		return (container, box, spinnerAnchor(diameter: diameter, box: box))
	}

	// MARK: - Scenes

	/// A scene: every part, with its keys as animations.
	///
	/// One layer per part and one keyframe animation per property, all on the
	/// composition's own clock — so the export and the preview run the same
	/// tree, and a scene scrubs frame by frame like everything else here.
	private static func sceneLayer(
		_ scene: Scene, with parameters: [String: String], project: Project, baseURL: URL,
		size: CGSize, resolved: ResolvedOverlay, host: Host
	) -> CALayer {
		let root = CALayer()
		root.frame = CGRect(origin: .zero, size: size)
		root.anchorPoint = CGPoint(x: 0.5, y: 0.5)
		root.position = CGPoint(x: size.width / 2, y: size.height / 2)

		for part in scene.parts {
			let keys = Scene.filled(part.keys)
			guard let first = keys.first else { continue }
			// A colour stated at any key means the colour moves, and a moving
			// colour is built differently from a fixed one — text especially,
			// whose ink is otherwise baked into a bitmap.
			let coloured = keys.contains { $0.color != nil }

			let layer: CALayer
			/// Where a colour animation goes, and under which key path.
			var ink: (layer: CALayer, path: String)?
			/// A bar's two halves, so its groove and its fill can be animated
			/// once the keys are in hand.
			var bars: (track: CAShapeLayer, fill: CAShapeLayer, bar: Scene.Bar, radius: Double)?
			/// A determinate spinner's arc, whose `strokeEnd` is the progress.
			var sweep: CAShapeLayer?
			/// A roll's lines, each with its own tint to animate and its own
			/// colour to fall back to. The one part whose ink lives in more
			/// than one layer, because its lines are set in more than one
			/// style.
			var rollInks: [(layer: CALayer, fallback: RGBA)] = []
			/// Whether any key names a different shape from another — which is
			/// what decides between an exact outline and a sampled one, because
			/// the two cannot be interpolated between.
			let morphing = Set(keys.compactMap(\.shape)).count > 1
			/// Whether any key says how far this has got.
			let determinate = part.keys.contains { $0.progress != nil }
			var natural = CGSize(
				width: (first.width ?? 0.2) * size.width,
				height: (first.height ?? 0.02) * size.height)
			switch part.content {
			case .text(let text, let styleName, let tracking):
				let style = project.style(named: styleName)
				let words = Scene.fill(text, with: parameters)
				if coloured {
					let built = tintable(words, style: style, size: size, tracking: tracking,
					                     ink: first.color ?? style.color)
					layer = built.layer
					natural = built.size
					ink = (built.ink, "backgroundColor")
				} else {
					let built = textLayer(words, style: style, size: size, tracking: tracking)
					layer = built.0
					natural = built.1
				}
			case .roll(let column):
				// One layer per line inside a holder the size of the whole
				// column, each placed at the offset the layout gives it. The
				// holder is what the keys move, so a roll scrolls by being
				// carried — every line keeps its place in the column, which is
				// the whole reason the column is a value and not forty parts.
				let laid = column.laidOut(in: size, project: project, with: parameters)
				let holder = CALayer()
				holder.frame = CGRect(origin: .zero, size: laid.size)
				var tints: [(layer: CALayer, fallback: RGBA)] = []
				for line in laid.lines {
					let built: (layer: CALayer, size: CGSize)
					if coloured {
						let tinted = tintable(line.text, style: line.style, size: size,
						                      tracking: line.tracking,
						                      ink: first.color ?? line.style.color)
						built = (tinted.layer, tinted.size)
						tints.append((tinted.ink, line.style.color))
					} else {
						let plain = textLayer(line.text, style: line.style, size: size,
						                      tracking: line.tracking)
						built = (plain.0, plain.1)
					}
					built.layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
					built.layer.frame = CGRect(origin: .zero, size: built.size)
					built.layer.position = CGPoint(x: laid.size.width / 2 + line.offset.x,
					                               y: laid.size.height / 2 + line.offset.y)
					holder.addSublayer(built.layer)
				}
				layer = holder
				natural = laid.size
				// Every line's ink, animated together: a roll is one thing that
				// happens to be many lines, so it changes colour all at once or
				// not at all.
				rollInks = tints
			case .shape(let fill, let corner, let kind):
				// A real path rather than a rounded rectangle standing in for
				// one. It costs nothing for the shape that was always here and
				// it is the only way a shape can become another shape: Core
				// Animation interpolates one path into another when the two
				// have the same points in the same order, which is exactly what
				// the sampled outline gives it.
				let shape = CAShapeLayer()
				shape.fillColor = cgColor(first.color ?? fill)
				shape.path = shapePath(for: first, kind: kind, corner: corner,
				                       morphing: morphing, frame: size)
				layer = shape
				// The layer is the whole frame and the outline is drawn in the
				// middle of it, because a path does not scale with its layer's
				// bounds: sizing the layer to the shape put the outline in the
				// corner of it, which is a square in the top right of the frame
				// on the first render anybody looks at.
				natural = size
				ink = (shape, "fillColor")

			case .bar(let bar):
				let holder = CALayer()
				let radius = bar.corner * size.height
				let track = CAShapeLayer()
				track.fillColor = cgColor(bar.track)
				let filling = CAShapeLayer()
				filling.fillColor = cgColor(first.color ?? bar.fill)
				for part in [track, filling] {
					part.frame = CGRect(origin: .zero, size: size)
					part.anchorPoint = CGPoint(x: 0.5, y: 0.5)
					part.position = CGPoint(x: size.width / 2, y: size.height / 2)
					holder.addSublayer(part)
				}
				track.path = barPath(first, bar: bar, radius: radius, filled: false, frame: size)
				filling.path = barPath(first, bar: bar, radius: radius, filled: true, frame: size)
				bars = (track, filling, bar, radius)
				layer = holder
				natural = size
				ink = (filling, "fillColor")

			case .spinner(let spinner):
				if determinate {
					// A spinner that knows how far it has got is a ring that
					// fills to that fraction, drawn as the same arc the painter
					// draws — same centre, same radius, same start at twelve
					// o'clock, same way round — with `strokeEnd` doing the
					// filling. The styles are for the case where there is
					// nothing to show but that it is still going.
					let holder = CALayer()
					let diameter = max(4, spinner.size * size.height)
					let inset = diameter * SpinnerLook.ringInset
					let ring = CGRect(x: -diameter / 2 + inset, y: -diameter / 2 + inset,
					                  width: diameter - inset * 2, height: diameter - inset * 2)
					let circle = CGMutablePath()
					circle.addArc(center: .zero, radius: ring.width / 2, startAngle: .pi / 2,
					              endAngle: .pi / 2 - 2 * .pi, clockwise: true)
					for (colour, isTrack) in [(spinner.color, true), (first.color ?? spinner.color, false)] {
						let arc = CAShapeLayer()
						arc.frame = CGRect(x: -diameter / 2, y: -diameter / 2,
						                   width: diameter, height: diameter)
						arc.anchorPoint = CGPoint(x: 0.5, y: 0.5)
						arc.position = .zero
						arc.path = circle
						arc.fillColor = nil
						arc.lineWidth = diameter * SpinnerLook.ringWidth
						arc.lineCap = .round
						arc.strokeColor = cgColor(colour, alpha: isTrack ? colour.a * 0.25 : colour.a)
						arc.strokeEnd = isTrack ? 1 : CGFloat(first.progress ?? 0)
						holder.addSublayer(arc)
						if !isTrack { sweep = arc }
					}
					layer = holder
					natural = CGSize(width: diameter, height: diameter)
					ink = sweep.map { ($0, "strokeColor") }
				} else {
					// The spinner this program already has, on the scene's own
					// clock. A second implementation of a spinner is a spinner
					// that eventually disagrees with itself.
					let standing = ResolvedOverlay(
						overlay: Overlay(kind: .spinner(spinner),
						                 span: .times(from: resolved.start, to: resolved.end),
						                 arrival: .cut, departure: .cut),
						origin: resolved.origin, appearance: resolved.appearance,
						start: resolved.start, end: resolved.end, path: nil)
					let built = spinnerLayer(spinner, style: TextStyle.caption, size: size,
					                         resolved: standing, host: host)
					layer = built.layer
					natural = built.size
				}
			case .image(let file):
				let picture = CALayer()
				let url = URL(fileURLWithPath: file, relativeTo: baseURL)
				if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
				   let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
					picture.contents = image
					picture.contentsGravity = .resizeAspect
				}
				layer = picture
			case .frames, .component:
				// Unreachable, and left as nothing rather than as a picture.
				//
				// A scene with a sequence in it never gets here: `isLayered`
				// sends the whole scene to the painter, for the reasons written
				// there. An empty layer is what this should be if that ever
				// changes — a still of frame nought would be a plausible-looking
				// wrong answer, which is worse than a hole.
				layer = CALayer()
			case .background(let background):
				natural = size
				// The background as the first key has it. For one whose keys
				// only tint it that is the declared ramp with `color` at the
				// near stop, which is what this always built; for one whose
				// keys state the gradient it is a ramp either way, because a
				// flat fill is a gradient whose stops are the same colour.
				let start = background.at(first.t, keys: keys)
				if let to = start.to {
					let ramp = CAGradientLayer()
					ramp.colors = [cgColor(start.from), cgColor(to)]
					let ends = start.ends(in: CGSize(width: 1, height: 1))
					// A gradient layer's unit space is the layer's own, which on
					// this platform is bottom-left up — the same way round as
					// everything else in a scene. Flipping it here, which is
					// what an iOS habit says to do, put `from` at the top of the
					// export and at the bottom of the preview.
					ramp.startPoint = ends.start
					ramp.endPoint = ends.end
					layer = ramp
					ink = (ramp, "colors")
				} else {
					let flat = CALayer()
					flat.backgroundColor = cgColor(start.from)
					layer = flat
					ink = (flat, "backgroundColor")
				}
			}

			layer.frame = CGRect(origin: .zero, size: natural)
			layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
			layer.position = CGPoint(x: (first.x ?? 0.5) * size.width,
			                         y: (first.y ?? 0.5) * size.height)
			layer.opacity = Float(first.opacity ?? 1)

			// The span, not the drawn window — and this is the other half of the
			// rule the envelope above follows. What is drawn *for* is the drawn
			// window; what a keyframe's `t` is measured *from* is the span, here
			// as in ``Frame`` and in a spinner's cycling words below. A scene's
			// part whose keys moved with the drawing would be re-timed by
			// somebody adding `at: before` to the overlay's `in:`, which is a
			// one-word edit quietly rewriting an animation. So the parts hold
			// their first key over the frames before the mark and start moving
			// on it, and `fillMode: .both` is what holds them.
			let span = max(resolved.duration, 0.0001)
			func animate(_ path: String, _ values: [Any], on target: CALayer = layer) {
				let animation = CAKeyframeAnimation(keyPath: path)
				animation.values = values
				animation.keyTimes = keys.map { NSNumber(value: min(1, max(0, $0.t / span))) }
				animation.timingFunctions = keys.dropFirst().map { timing($0.ease) }
				animation.beginTime = host.beginTime(resolved.start)
				animation.duration = span
				animation.fillMode = .both
				animation.isRemovedOnCompletion = false
				target.add(animation, forKey: path)
			}
			animate("opacity", keys.map { $0.opacity ?? 1 })

			// A background is the frame. Moving it, scaling it or turning it
			// would show what is behind it at the edges, which is the one thing
			// a background must never do — so it is placed and left alone.
			if case .background(let background) = part.content {
				layer.position = CGPoint(x: size.width / 2, y: size.height / 2)
				if Scene.movesTheGradient(keys), let ramp = layer as? CAGradientLayer {
					turning(background, on: ramp, keys: keys, over: span, host: host,
					        from: resolved.start)
				} else if coloured, let ink {
					if let to = background.to {
						animate(ink.path, keys.map {
							[cgColor($0.color ?? background.from), cgColor(to)]
						}, on: ink.layer)
					} else {
						animate(ink.path, keys.map { cgColor($0.color ?? background.from) },
						        on: ink.layer)
					}
				}
				root.addSublayer(layer)
				continue
			}

			animate("position", keys.map {
				NSValue(point: NSPoint(x: ($0.x ?? 0.5) * size.width,
				                       y: ($0.y ?? 0.5) * size.height))
			})
			animate("transform.scale", keys.map { $0.scale ?? 1 })
			animate("transform.rotation.z", keys.map { ($0.rotation ?? 0) * .pi / 180 })
			// The parts whose size is their bounds: an image and the two that
			// arrive as pixels. A shape and a bar carry theirs in their paths —
			// which is what lets a shape change size and kind at once — and a
			// spinner's is its own.
			switch part.content {
			case .image, .frames, .component:
				animate("bounds.size", keys.map {
					NSValue(size: NSSize(width: ($0.width ?? 0.2) * size.width,
					                     height: ($0.height ?? 0.02) * size.height))
				})
			case .text, .shape, .bar, .spinner, .roll, .background:
				break
			}

			if case .shape(_, let corner, let kind) = part.content, let shape = layer as? CAShapeLayer {
				animate("path", keys.map {
					shapePath(for: $0, kind: kind, corner: corner,
					          morphing: morphing, frame: size)
				}, on: shape)
			}
			if let bars {
				animate("path", keys.map {
					barPath($0, bar: bars.bar, radius: bars.radius, filled: false, frame: size)
				}, on: bars.track)
				animate("path", keys.map {
					barPath($0, bar: bars.bar, radius: bars.radius, filled: true, frame: size)
				}, on: bars.fill)
			}
			if let sweep {
				animate("strokeEnd", keys.map { max(0, min(1, $0.progress ?? 0)) }, on: sweep)
			}
			for (tint, fallback) in rollInks {
				animate("backgroundColor", keys.map { cgColor($0.color ?? fallback) }, on: tint)
			}
			if coloured, let ink {
				let fallback: RGBA
				switch part.content {
				case .text(_, let styleName, _): fallback = project.style(named: styleName).color
				case .shape(let fill, _, _): fallback = fill
				case .bar(let bar): fallback = bar.fill
				case .spinner(let spinner): fallback = spinner.color
				default: fallback = .white
				}
				animate(ink.path, keys.map { cgColor($0.color ?? fallback) }, on: ink.layer)
			}
			root.addSublayer(layer)
		}
		return root
	}

	/// A background whose gradient moves: both stops and the direction, as one
	/// sampled track.
	///
	/// Sampled rather than keyframed at the keys, which is what every other
	/// property here is, and for one reason: Core Animation interpolates a
	/// gradient's ends as *points*. Two directions forty degrees apart are two
	/// points on a circle, and the straight line between them is a chord — so
	/// half way through a turn the ramp is aimed correctly and reaches less far
	/// than it should, which shows as the gradient tightening and loosening as
	/// it goes round. Asking ``Scene/Background/at(_:keys:)`` for the answer
	/// often enough that the chord *is* the arc costs a few hundred numbers and
	/// makes the export the picture the preview draws. The same trick a bubble's
	/// tail uses.
	///
	/// The easing is in the samples, so the segments between them are linear.
	private static func turning(
		_ background: Scene.Background, on ramp: CAGradientLayer, keys: [Scene.Key],
		over span: Double, host: Host, from start: Double
	) {
		// Thirty a second, which is finer than any frame rate this renders at,
		// and never more than a scene's worth of them.
		let steps = min(300, max(2, Int((span * 30).rounded(.up))))
		let moments = (0 ... steps).map { Double($0) / Double(steps) }
		let states = moments.map { background.at($0 * span, keys: keys) }

		func track(_ path: String, _ values: [Any]) {
			let animation = CAKeyframeAnimation(keyPath: path)
			animation.values = values
			animation.keyTimes = moments.map { NSNumber(value: $0) }
			animation.calculationMode = .linear
			animation.beginTime = host.beginTime(start)
			animation.duration = span
			animation.fillMode = .both
			animation.isRemovedOnCompletion = false
			ramp.add(animation, forKey: path)
		}
		track("colors", states.map { [cgColor($0.from), cgColor($0.to ?? $0.from)] })
		let ends = states.map { $0.ends(in: CGSize(width: 1, height: 1)) }
		track("startPoint", ends.map { NSValue(point: NSPoint(x: $0.start.x, y: $0.start.y)) })
		track("endPoint", ends.map { NSValue(point: NSPoint(x: $0.end.x, y: $0.end.y)) })
	}

	/// The outline of a shape part at one key, in the frame's coordinates.
	///
	/// Every key of a part that morphs gets a *sampled* outline, even the ones
	/// whose kind never changes, because Core Animation can only interpolate
	/// two paths with the same points in the same order. A part that does not
	/// morph gets the exact outline — real arcs on a rounded rectangle, a real
	/// ellipse — so a project written before there were kinds renders exactly
	/// as it did.
	private static func shapePath(
		for key: Scene.Key, kind: Scene.ShapeKind, corner: Double,
		morphing: Bool, frame: CGSize
	) -> CGPath {
		let box = CGSize(width: (key.width ?? 0.2) * frame.width,
		                 height: (key.height ?? 0.02) * frame.height)
		let radius = corner * frame.height
		let shape = key.shape ?? kind
		let outline = morphing
			? Scene.ShapeKind.sampled(shape, in: box, corner: radius)
			: shape.path(in: box, corner: radius)
		var move = CGAffineTransform(translationX: frame.width / 2, y: frame.height / 2)
		return outline.copy(using: &move) ?? outline
	}

	/// A bar's groove, or the filled part of it, at one key.
	private static func barPath(
		_ key: Scene.Key, bar: Scene.Bar, radius: Double, filled: Bool, frame: CGSize
	) -> CGPath {
		let width = (key.width ?? 0.4) * frame.width
		let height = (key.height ?? 0.02) * frame.height
		let box = CGRect(x: -width / 2, y: -height / 2, width: width, height: height)
		let rects = bar.rects(in: box, progress: key.progress ?? 0)
		let rect = filled ? rects.fill : rects.track
		guard rect.width > 0.01, rect.height > 0.01 else {
			// An empty bar is still a path with the same shape, or Core
			// Animation has nothing to interpolate from. A rectangle of no
			// width at the end it grows from is that path.
			let seed = CGRect(x: rect.minX, y: rect.minY, width: 0.01, height: max(rect.height, 0.01))
			return CGPath(roundedRect: seed.offsetBy(dx: frame.width / 2, dy: frame.height / 2),
			              cornerWidth: 0, cornerHeight: 0, transform: nil)
		}
		let end = min(radius, rect.width / 2, rect.height / 2)
		return CGPath(roundedRect: rect.offsetBy(dx: frame.width / 2, dy: frame.height / 2),
		              cornerWidth: end, cornerHeight: end, transform: nil)
	}

	/// Text whose colour can move: the glyphs as a mask, over a plain layer
	/// whose `backgroundColor` is the ink.
	///
	/// The ordinary text layer bakes the colour into a bitmap, which is right —
	/// it is the reason captions export at all — but a baked colour cannot be
	/// animated. Cutting the same bitmap into a mask keeps the glyphs identical
	/// to the ones the painter draws, and moves the colour out where Core
	/// Animation can get at it.
	private static func tintable(
		_ text: String, style: TextStyle, size: CGSize, tracking: Double, ink: RGBA
	) -> (layer: CALayer, size: CGSize, ink: CALayer) {
		// Drawn white on nothing: the mask uses the alpha channel, so the plate
		// behind the words would mask the whole rectangle in if it were left in
		// the same bitmap. It goes into a layer of its own instead, and the
		// metrics are unchanged because the padding still applies.
		var plain = style
		plain.background = RGBA(r: 0, g: 0, b: 0, a: 0)
		let (glyphs, plate) = textLayer(text, style: plain, size: size,
		                                tracking: tracking, ink: .white)

		let container = CALayer()
		container.frame = CGRect(origin: .zero, size: plate)
		if style.background.a > 0 {
			let behind = CALayer()
			behind.frame = container.bounds
			behind.backgroundColor = cgColor(style.background)
			behind.cornerRadius = min(style.cornerRadius * size.height, plate.height / 2)
			container.addSublayer(behind)
		}
		let tint = CALayer()
		tint.frame = container.bounds
		tint.backgroundColor = cgColor(ink)
		glyphs.frame = container.bounds
		tint.mask = glyphs
		container.addSublayer(tint)
		return (container, plate, tint)
	}

	private static func timing(_ ease: Scene.Ease) -> CAMediaTimingFunction {
		switch ease {
		case .linear: return CAMediaTimingFunction(name: .linear)
		case .in: return CAMediaTimingFunction(name: .easeIn)
		case .out: return CAMediaTimingFunction(name: .easeOut)
		case .inOut: return CAMediaTimingFunction(name: .easeInEaseOut)
		}
	}

	/// The middle of the spinner, in the container's unit coordinates.
	private static func spinnerAnchor(diameter: CGFloat, box: CGSize) -> CGPoint {
		CGPoint(x: box.width > 0 ? (diameter / 2) / box.width : 0.5, y: 0.5)
	}

	/// The changing words beside the spinner.
	///
	/// Each word is its own layer with its own opacity animation, all sharing
	/// one cycle and repeating for as long as the overlay is up. One layer per
	/// word rather than one `CATextLayer` whose string changes, because a string
	/// is not an animatable property — under the animation tool there is no
	/// point in time at which anybody could set it.
	private static func addWords(
		_ layers: [(CALayer, CGSize)], schedule: [(word: SpinnerWord, duration: Double)],
		to container: CALayer, spinnerDiameter: CGFloat, box: CGSize,
		resolved: ResolvedOverlay, host: Host
	) {
		guard !layers.isEmpty else { return }
		let cycle = max(schedule.reduce(0) { $0 + $1.duration }, 0.001)
		// A short crossfade rather than a hard swap: a caption that changes on
		// one frame reads as a glitch in the encode, where a hundred and fifty
		// milliseconds reads as a change.
		let ramp = min(0.15, cycle / Double(schedule.count) / 3)

		var elapsed = 0.0
		for (index, entry) in schedule.enumerated() {
			let (layer, layerSize) = layers[index]
			layer.frame = CGRect(
				x: spinnerDiameter + spinnerDiameter * 0.45,
				y: (box.height - layerSize.height) / 2,
				width: layerSize.width, height: layerSize.height)
			layer.opacity = 0

			let start = elapsed, end = elapsed + entry.duration
			let animation = CAKeyframeAnimation(keyPath: "opacity")
			animation.values = [0, 0, 1, 1, 0, 0]
			animation.keyTimes = [
				0,
				NSNumber(value: max(0, start - ramp) / cycle),
				NSNumber(value: start / cycle),
				NSNumber(value: max(start, end - ramp) / cycle),
				NSNumber(value: end / cycle),
				1,
			]
			animation.duration = cycle
			// Repeats for the whole span, so three words over thirty seconds is
			// three words cycling rather than three words and then nothing.
			animation.repeatDuration = resolved.duration
			animation.beginTime = host.beginTime(resolved.start)
			animation.fillMode = .both
			animation.isRemovedOnCompletion = false
			layer.add(animation, forKey: "word")
			container.addSublayer(layer)
			elapsed = end
		}
	}

	private static func cgColor(_ color: RGBA) -> CGColor {
		CGColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: color.a)
	}

	/// The same colour, fainter — for the parts of a spinner that stay put
	/// while another part moves over them.
	private static func cgColor(_ color: RGBA, alpha: Double) -> CGColor {
		CGColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: color.a * alpha)
	}
}
