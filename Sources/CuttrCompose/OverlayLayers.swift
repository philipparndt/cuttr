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
	/// Public because the panel has to be able to say which of the two passes a
	/// row is drawn in — the ordering in `overlays:` decides the frame pass,
	/// and a layer is always over all of it.
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
	static func textLayer(_ text: String, style: TextStyle, size: CGSize) -> (CALayer, CGSize) {
		// Twice the output resolution. Type is the thing people notice, and a
		// caption drawn at 1× and scaled is soft in a way a plate is not.
		let scale: CGFloat = 2
		let pointSize = style.size * size.height * scale
		let font = CTFontCreateWithName(style.font as CFString, pointSize, nil)
		let attributed = NSAttributedString(string: text, attributes: [
			kCTFontAttributeName as NSAttributedString.Key: font,
			kCTForegroundColorAttributeName as NSAttributedString.Key: cgColor(style.color),
		])
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

			let layer: CALayer
			var natural = CGSize(
				width: (first.width ?? 0.2) * size.width,
				height: (first.height ?? 0.02) * size.height)
			switch part.content {
			case .text(let text, let styleName):
				let style = project.style(named: styleName)
				let built = textLayer(Scene.fill(text, with: parameters), style: style, size: size)
				layer = built.0
				natural = built.1
			case .shape(let fill, let corner):
				let shape = CALayer()
				shape.backgroundColor = cgColor(fill)
				shape.cornerRadius = corner * size.height
				layer = shape
			case .image(let file):
				let picture = CALayer()
				let url = URL(fileURLWithPath: file, relativeTo: baseURL)
				if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
				   let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
					picture.contents = image
					picture.contentsGravity = .resizeAspect
				}
				layer = picture
			}

			layer.frame = CGRect(origin: .zero, size: natural)
			layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
			layer.position = CGPoint(x: (first.x ?? 0.5) * size.width,
			                         y: (first.y ?? 0.5) * size.height)
			layer.opacity = Float(first.opacity ?? 1)

			let span = max(resolved.duration, 0.0001)
			func animate(_ path: String, _ values: [Any]) {
				let animation = CAKeyframeAnimation(keyPath: path)
				animation.values = values
				animation.keyTimes = keys.map { NSNumber(value: min(1, max(0, $0.t / span))) }
				animation.timingFunctions = keys.dropFirst().map { timing($0.ease) }
				animation.beginTime = host.beginTime(resolved.start)
				animation.duration = span
				animation.fillMode = .both
				animation.isRemovedOnCompletion = false
				layer.add(animation, forKey: path)
			}
			animate("position", keys.map {
				NSValue(point: NSPoint(x: ($0.x ?? 0.5) * size.width,
				                       y: ($0.y ?? 0.5) * size.height))
			})
			animate("opacity", keys.map { $0.opacity ?? 1 })
			animate("transform.scale", keys.map { $0.scale ?? 1 })
			animate("transform.rotation.z", keys.map { ($0.rotation ?? 0) * .pi / 180 })
			// A shape's size is its own, and animating bounds is how a rule
			// draws itself across the screen.
			if case .text = part.content {} else {
				animate("bounds.size", keys.map {
					NSValue(size: NSSize(width: ($0.width ?? 0.2) * size.width,
					                     height: ($0.height ?? 0.02) * size.height))
				})
			}
			root.addSublayer(layer)
		}
		return root
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
