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
	public static func isLayered(_ overlay: Overlay) -> Bool {
		if case .effect = overlay.kind { return false }
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

		for resolvedOverlay in resolved.overlays where isLayered(resolvedOverlay.overlay) {
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
			guard let scene = project.scenes[name] else { return placer }
			return sceneLayer(scene, with: parameters, project: project, baseURL: baseURL,
			                  size: size, resolved: resolved, host: host)
		case .spinner(let spinner):
			let built = spinnerLayer(
				spinner, style: project.style(named: spinner.wordStyle ?? "caption"),
				size: size, resolved: resolved, host: host)
			content = built.layer
			contentSize = built.size
			contentAnchor = built.anchor
		}

		mover.frame = CGRect(origin: .zero, size: contentSize)
		mover.addSublayer(content)
		placer.frame = CGRect(origin: .zero, size: contentSize)
		placer.addSublayer(mover)

		// Where it sits, and what the slide is measured against.
		let anchorPoint: CGPoint
		let home: CGPoint
		if let path = resolved.path {
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

		if let slide = slide(resolved, contentSize: contentSize, frame: size, host: host) {
			mover.add(slide, forKey: "slide")
		}
		return placer
	}

	// MARK: - The animations

	/// In, hold, out — as one keyframe animation over the overlay's whole span.
	///
	/// One animation rather than three, because the three would have to be kept
	/// in step by hand and the interesting case is when they meet: an overlay
	/// ending exactly where the next begins gives one fading out while the other
	/// fades in, with nothing to arrange.
	private static func opacity(_ resolved: ResolvedOverlay, host: Host) -> CAKeyframeAnimation {
		let animation = CAKeyframeAnimation(keyPath: "opacity")
		let span = max(resolved.duration, 0.0001)
		let arrive = min(resolved.overlay.arrival.duration, span / 2)
		let depart = min(resolved.overlay.departure.duration, span / 2)
		// A slide arrives at full opacity — it is the movement that shows it —
		// while a fade is the opacity. A cut is neither and simply appears.
		let arrivesByFading = isFade(resolved.overlay.arrival)
		let departsByFading = isFade(resolved.overlay.departure)
		animation.values = [
			arrivesByFading ? 0 : 1,
			1, 1,
			departsByFading ? 0 : 1,
		]
		animation.keyTimes = [0, NSNumber(value: arrive / span), NSNumber(value: 1 - depart / span), 1]
		animation.timingFunctions = [
			CAMediaTimingFunction(name: .easeOut),
			CAMediaTimingFunction(name: .linear),
			CAMediaTimingFunction(name: .easeIn),
		]
		animation.beginTime = host.beginTime(resolved.start)
		animation.duration = span
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
		let span = max(resolved.duration, 0.0001)
		let arrive = min(resolved.overlay.arrival.duration, span / 2)
		let depart = min(resolved.overlay.departure.duration, span / 2)

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
		animation.keyTimes = [0, NSNumber(value: arrive / span), NSNumber(value: 1 - depart / span), 1]
		// Eased at both ends: a caption that arrives at constant speed and stops
		// dead reads as a bug in the render rather than as a move.
		animation.timingFunctions = [
			CAMediaTimingFunction(name: .easeOut),
			CAMediaTimingFunction(name: .linear),
			CAMediaTimingFunction(name: .easeIn),
		]
		animation.beginTime = host.beginTime(resolved.start)
		animation.duration = span
		animation.fillMode = .both
		animation.isRemovedOnCompletion = false
		return animation
	}

	/// Following the anchor: the solved path, as keyframes on `position`.
	private static func follow(
		_ path: AnchorPath, resolved: ResolvedOverlay, offset: CGPoint, size: CGSize, host: Host
	) -> CAKeyframeAnimation {
		let span = max(resolved.duration, 0.0001)
		// Only the samples inside the overlay's span, with the ends pinned so
		// the first and last keyframe land exactly on the span's edges.
		var times: [Double] = [resolved.start]
		times += path.samples.map(\.time).filter { $0 > resolved.start && $0 < resolved.end }
		times.append(resolved.end)

		let animation = CAKeyframeAnimation(keyPath: "position")
		animation.values = times.map { time in
			NSValue(point: position(from: path, at: time, offset: offset, size: size))
		}
		animation.keyTimes = times.map { NSNumber(value: ($0 - resolved.start) / span) }
		animation.calculationMode = .linear
		animation.beginTime = host.beginTime(resolved.start)
		animation.duration = span
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

	private static func isFade(_ transition: Overlay.Transition) -> Bool {
		if case .fade = transition { return true }
		return false
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
	static func textLayer(
		_ text: String, style: TextStyle, size: CGSize,
		tracking: Double = 0, ink: RGBA? = nil
	) -> (CALayer, CGSize) {
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
		let plateSize = CGSize(width: pixelSize.width / scale, height: pixelSize.height / scale)

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
						source: resolved.source, appearance: resolved.appearance,
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
			case .background(let background):
				natural = size
				if let to = background.to {
					let ramp = CAGradientLayer()
					ramp.colors = [cgColor(first.color ?? background.from), cgColor(to)]
					let ends = background.ends(in: CGSize(width: 1, height: 1))
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
					flat.backgroundColor = cgColor(first.color ?? background.from)
					layer = flat
					ink = (flat, "backgroundColor")
				}
			}

			layer.frame = CGRect(origin: .zero, size: natural)
			layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
			layer.position = CGPoint(x: (first.x ?? 0.5) * size.width,
			                         y: (first.y ?? 0.5) * size.height)
			layer.opacity = Float(first.opacity ?? 1)

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
				if coloured, let ink {
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
			// An image is the one part left whose size is its bounds. A shape
			// and a bar carry theirs in their paths — which is what lets a
			// shape change size and kind at once — and a spinner's is its own.
			if case .image = part.content {
				animate("bounds.size", keys.map {
					NSValue(size: NSSize(width: ($0.width ?? 0.2) * size.width,
					                     height: ($0.height ?? 0.02) * size.height))
				})
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
