import CoreGraphics
import CoreImage
import Foundation
import QuartzCore

/// An overlay as pixels, at a moment.
///
/// Normally a caption is a layer, laid over the finished frame by Core
/// Animation — which is cheaper, sharper and exactly what a caption in front of
/// everything wants. But a caption that goes *behind* somebody cannot be laid
/// over anything: the shape of the person is known in the pass that has the
/// pixels, and by the time a layer is drawn that pass is over.
///
/// So an overlay that says `behind: people` is painted here instead, from the
/// same numbers the animations use — the same keyframes, the same easing, the
/// same anchor path — and composited under the person. What it costs is a
/// rasterisation per frame; what it buys is a caption that goes round the back
/// of the person talking.
public enum OverlayPainter {

	/// The overlay as it looks at `time`, in the frame's coordinates, or `nil`
	/// if there is nothing to draw.
	static func image(
		for resolved: ResolvedOverlay, project: Project, baseURL: URL,
		size: CGSize, at time: Double
	) -> CIImage? {
		let opacity = fade(resolved, at: time)
		guard opacity > 0.001 else { return nil }

		switch resolved.overlay.kind {
		case .text(let text, let styleName):
			let style = project.style(named: styleName)
			guard let plateImage = plate(text, style: style, size: size) else { return nil }
			return placed(plateImage.image, plate: plateImage.size,
			              anchor: CGPoint(
				              x: style.alignment == .left ? 0 : style.alignment == .right ? 1 : 0.5,
				              y: 0.5),
			              home: home(resolved, style: style, size: size),
			              resolved: resolved, size: size, opacity: opacity, at: time)

		case .spinner(let spinner):
			let wordStyle = spinner.wordStyle.map { project.style(named: $0) } ?? TextStyle.caption
			guard let drawn = spinnerImage(spinner, words: wordStyle, size: size,
			                               elapsed: time - resolved.start,
			                               span: resolved.duration) else { return nil }
			return placed(drawn.image, plate: drawn.size, anchor: drawn.anchor,
			              home: home(resolved, style: wordStyle, size: size),
			              resolved: resolved, size: size, opacity: opacity, at: time)

		case .scene(let name, let parameters):
			guard let scene = project.scenes[name],
			      let drawn = sceneImage(scene, with: parameters, project: project,
			                             baseURL: baseURL, size: size,
			                             at: time - resolved.start) else { return nil }
			// A scene carries its own positions, so it is already frame-sized.
			return faded(CIImage(cgImage: drawn), by: opacity)

		case .bubble(let bubble):
			guard let drawn = bubbleImage(bubble, resolved: resolved, project: project,
			                              size: size, at: time) else { return nil }
			// Drawn in the frame's own coordinates, like a scene, so there is
			// nothing to place: the tail already reaches where it reaches.
			return faded(CIImage(cgImage: drawn), by: opacity)

		case .effect, .film, .aberration, .tape:
			// All of them are the frame itself rather than something over it,
			// and none of them is drawn here.
			return nil
		}
	}

	// MARK: - A bubble

	/// A bubble at one moment, over the whole frame.
	///
	/// Every number in it comes from ``BubblePlacing`` — where the paper sits,
	/// what the tail points at, which drawing this is — so a bubble that goes
	/// behind somebody is the same bubble as one that does not, and the same
	/// bubble again as the one somebody drags around in the panel's little
	/// picture. One arithmetic, three places it is asked from.
	///
	/// Public because the panel draws a bubble with it. A preview that
	/// approximated this would be a preview somebody could place a bubble
	/// wrongly with.
	public static func bubbleImage(
		_ bubble: Bubble, resolved: ResolvedOverlay, project: Project,
		size: CGSize, at time: Double
	) -> CGImage? {
		BubblePlacing.drawing(bubble, resolved: resolved, project: project,
		                      size: size, at: time).image
	}

	/// Where the overlay's anchor point sits, in the frame.
	private static func home(
		_ resolved: ResolvedOverlay, style: TextStyle, size: CGSize
	) -> CGPoint {
		if let path = resolved.path, let point = path.point(at: resolved.start) {
			return CGPoint(x: point.x * size.width + resolved.overlay.offset.x * size.height,
			               y: point.y * size.height + resolved.overlay.offset.y * size.height)
		}
		if case .spinner = resolved.overlay.kind, resolved.path == nil {
			return CGPoint(x: (0.5 + resolved.overlay.offset.x) * size.width,
			               y: (0.5 + resolved.overlay.offset.y) * size.height)
		}
		return CGPoint(x: style.position.x * size.width, y: style.position.y * size.height)
	}

	/// The plate for a caption, as an image and the size it is drawn at.
	private static func plate(
		_ text: String, style: TextStyle, size: CGSize,
		tracking: Double = 0, ink: RGBA? = nil
	) -> (image: CGImage, size: CGSize)? {
		let (layer, plate) = OverlayLayers.textLayer(text, style: style, size: size,
		                                             tracking: tracking, ink: ink)
		guard let contents = layer.contents, CFGetTypeID(contents as CFTypeRef) == CGImage.typeID
		else { return nil }
		// swiftlint:disable:next force_cast
		return (contents as! CGImage, plate)
	}

	private static func faded(_ image: CIImage, by opacity: Double) -> CIImage {
		guard opacity < 0.999 else { return image }
		return image.applyingFilter("CIColorMatrix", parameters: [
			"inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity),
		])
	}

	/// A drawn thing, put where the overlay says, with its slide and its fade.
	private static func placed(
		_ image: CGImage, plate: CGSize, anchor: CGPoint, home: CGPoint,
		resolved: ResolvedOverlay, size: CGSize, opacity: Double, at time: Double
	) -> CIImage? {
		let follow: CGPoint
		if let path = resolved.path, let point = path.point(at: time) {
			follow = CGPoint(x: point.x * size.width + resolved.overlay.offset.x * size.height,
			                 y: point.y * size.height + resolved.overlay.offset.y * size.height)
		} else {
			follow = home
		}
		let slide = slide(resolved, plate: plate, frame: size, at: time)
		let origin = CGPoint(x: follow.x - anchor.x * plate.width + slide.x,
		                     y: follow.y - anchor.y * plate.height + slide.y)

		let drawn = CIImage(cgImage: image)
		return faded(drawn
			.transformed(by: CGAffineTransform(
				scaleX: plate.width / drawn.extent.width,
				y: plate.height / drawn.extent.height))
			.transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y)), by: opacity)
	}

	// MARK: - A spinner

	/// The spinner and its word, drawn at the moment asked for.
	///
	/// The same proportions as the layer version — they come from `SpinnerLook`
	/// so there is one spinner and not two — turned by however far it has got:
	/// `speed` turns a second, clockwise, from the moment it appeared.
	/// Timed from when the spinner appeared rather than from the programme,
	/// because a spinner in a scene has no overlay start to subtract — the
	/// scene's own clock is the only one it knows.
	private static func spinnerImage(
		_ spinner: Spinner, words style: TextStyle,
		size: CGSize, elapsed: Double, span: Double
	) -> (image: CGImage, size: CGSize, anchor: CGPoint)? {
		let diameter = max(4, spinner.size * size.height)
		let scale: CGFloat = 2

		// The word it is on, and how wide the block has to be for it.
		var word: String?
		let schedule = spinner.schedule(over: span)
		if !schedule.isEmpty {
			var left = elapsed
			let cycle = schedule.reduce(0) { $0 + $1.duration }
			if cycle > 0 { left = left.truncatingRemainder(dividingBy: cycle) }
			for entry in schedule {
				if left < entry.duration { word = entry.word.text; break }
				left -= entry.duration
			}
			word = word ?? schedule.last?.word.text
		}

		var plate: (image: CGImage, size: CGSize)?
		if let word, !word.isEmpty { plate = self.plate(word, style: style, size: size) }
		let gap = diameter * SpinnerLook.wordGap
		let box = CGSize(
			width: diameter + (plate.map { gap + $0.size.width } ?? 0),
			height: max(diameter, plate?.size.height ?? 0))

		guard let context = CGContext(
			data: nil, width: Int(box.width * scale), height: Int(box.height * scale),
			bitsPerComponent: 8, bytesPerRow: 0,
			space: CGColorSpace(name: CGColorSpace.sRGB)!,
			bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
		else { return nil }
		context.scaleBy(x: scale, y: scale)

		let centre = CGPoint(x: diameter / 2, y: box.height / 2)
		let ink = CGColor(srgbRed: spinner.color.r, green: spinner.color.g,
		                  blue: spinner.color.b, alpha: spinner.color.a)
		// Clockwise, from where it started.
		let turn = -2 * CGFloat.pi * CGFloat(spinner.speed) * CGFloat(elapsed)

		context.saveGState()
		context.translateBy(x: centre.x, y: centre.y)
		context.rotate(by: turn)
		context.setFillColor(ink)
		context.setStrokeColor(ink)

		switch spinner.style {
		case .dots:
			let dot = diameter * SpinnerLook.dot
			for step in 0..<SpinnerLook.dots {
				let angle = CGFloat(step) / CGFloat(SpinnerLook.dots) * 2 * .pi
				let radius = (diameter - dot) / 2
				context.setAlpha(max(0.12, 1 - Double(step) / Double(SpinnerLook.dots)))
				context.fillEllipse(in: CGRect(
					x: sin(angle) * radius - dot / 2, y: cos(angle) * radius - dot / 2,
					width: dot, height: dot))
			}
			context.setAlpha(1)

		case .bars:
			let width = diameter * SpinnerLook.barWidth
			let length = diameter * SpinnerLook.barLength
			for step in 0..<SpinnerLook.bars {
				let angle = CGFloat(step) / CGFloat(SpinnerLook.bars) * 2 * .pi
				context.saveGState()
				context.rotate(by: -angle)
				context.setAlpha(max(0.1, 1 - Double(step) / Double(SpinnerLook.bars)))
				context.addPath(CGPath(
					roundedRect: CGRect(x: -width / 2, y: diameter / 2 - length - diameter * 0.04,
					                    width: width, height: length),
					cornerWidth: width / 2, cornerHeight: width / 2, transform: nil))
				context.fillPath()
				context.restoreGState()
			}
			context.setAlpha(1)

		case .ring, .arc:
			let inset = diameter * SpinnerLook.ringInset
			let sweep = spinner.style == .ring ? SpinnerLook.ringSweep : SpinnerLook.arcSweep
			context.setLineWidth(diameter * SpinnerLook.ringWidth)
			context.setLineCap(.round)
			context.addArc(center: .zero, radius: (diameter - inset * 2) / 2,
			               startAngle: .pi / 2, endAngle: .pi / 2 - sweep * 2 * .pi,
			               clockwise: true)
			context.strokePath()

		case .orbit:
			let inset = diameter * SpinnerLook.ringInset
			context.setLineWidth(diameter * 0.07)
			context.setAlpha(0.25)
			context.addArc(center: .zero, radius: (diameter - inset * 2) / 2,
			               startAngle: 0, endAngle: 2 * .pi, clockwise: false)
			context.strokePath()
			context.setAlpha(1)
			let dot = diameter * SpinnerLook.orbitDot
			context.fillEllipse(in: CGRect(
				x: -dot / 2, y: (diameter - inset * 2) / 2 - dot / 2, width: dot, height: dot))

		case .pulse:
			// It breathes rather than turns, so the rotation above means
			// nothing to it: the size does the work.
			let inset = diameter * SpinnerLook.pulseInset
			let breath = 0.72 + 0.28 * (0.5 + 0.5 * sin(2 * .pi * spinner.speed * elapsed))
			let radius = (diameter - inset * 2) / 2 * breath
			context.setLineWidth(diameter * SpinnerLook.pulseWidth)
			context.setAlpha(0.18)
			context.fillEllipse(in: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2))
			context.setAlpha(1)
			context.strokeEllipse(in: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2))

		case .bounce:
			context.rotate(by: -turn)   // three dots in a row do not go round
			let dot = diameter * SpinnerLook.bounceDot
			let gapBetween = (diameter - dot * CGFloat(SpinnerLook.bounce)) / CGFloat(SpinnerLook.bounce - 1)
			for step in 0..<SpinnerLook.bounce {
				let phase = elapsed * spinner.speed - Double(step) / Double(SpinnerLook.bounce)
				let rise = max(0, sin(2 * .pi * phase)) * Double(diameter * SpinnerLook.bounceRise)
				context.fillEllipse(in: CGRect(
					x: -diameter / 2 + CGFloat(step) * (dot + gapBetween),
					y: -dot / 2 + CGFloat(rise), width: dot, height: dot))
			}
		}
		context.restoreGState()

		if let plate {
			context.draw(plate.image, in: CGRect(
				x: diameter + gap, y: box.height / 2 - plate.size.height / 2,
				width: plate.size.width, height: plate.size.height))
		}

		guard let image = context.makeImage() else { return nil }
		// The *spinner* sits on the anchor, not the middle of the block: a
		// spinner over somebody's head should be over their head, whatever it
		// happens to be saying.
		return (image, box, CGPoint(x: (diameter / 2) / box.width, y: 0.5))
	}

	// MARK: - A scene

	/// Every part of a scene, at the values its keys give for this moment.
	///
	/// Public, and timed from the start of the scene rather than from the
	/// overlay that uses it, because the scene editor draws its stage with
	/// this. That is the point of exposing it: the editor is not allowed a
	/// third way of drawing a scene, and now there is nowhere for one to
	/// appear.
	public static func sceneImage(
		_ scene: Scene, with parameters: [String: String], project: Project, baseURL: URL,
		size: CGSize, at elapsed: Double
	) -> CGImage? {
		guard size.width >= 1, size.height >= 1, let context = CGContext(
			data: nil, width: Int(size.width), height: Int(size.height),
			bitsPerComponent: 8, bytesPerRow: 0,
			space: CGColorSpace(name: CGColorSpace.sRGB)!,
			bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
		else { return nil }

		for part in scene.parts {
			let keys = Scene.filled(part.keys)
			guard let key = Scene.state(of: keys, at: elapsed) else { continue }
			let opacity = key.opacity ?? 1
			guard opacity > 0.001 else { continue }

			context.saveGState()
			context.setAlpha(CGFloat(opacity))

			// A background is the frame, so it is not moved, scaled or turned:
			// its keys say when it is there and how solid, and nothing else.
			if case .background(let background) = part.content {
				paint(background.at(elapsed, keys: keys), in: context, size: size)
				context.restoreGState()
				continue
			}

			let centre = CGPoint(x: (key.x ?? 0.5) * size.width, y: (key.y ?? 0.5) * size.height)
			context.translateBy(x: centre.x, y: centre.y)
			context.rotate(by: CGFloat((key.rotation ?? 0) * .pi / 180))
			context.scaleBy(x: CGFloat(key.scale ?? 1), y: CGFloat(key.scale ?? 1))

			switch part.content {
			case .text(let text, let styleName, let tracking):
				let style = project.style(named: styleName)
				if let plate = plate(Scene.fill(text, with: parameters), style: style, size: size,
				                     tracking: tracking, ink: key.color) {
					context.draw(plate.image, in: CGRect(
						x: -plate.size.width / 2, y: -plate.size.height / 2,
						width: plate.size.width, height: plate.size.height))
				}
			case .roll(let roll):
				// One plate per line, each at the offset the layout gives it —
				// the same layout the export lays out, and the same `plate` a
				// text part is drawn with. A roll is not a second kind of type.
				for line in roll.laidOut(in: size, project: project).lines {
					guard let plate = plate(Scene.fill(line.text, with: parameters),
					                        style: line.style, size: size,
					                        tracking: line.tracking, ink: key.color)
					else { continue }
					context.draw(plate.image, in: CGRect(
						x: line.offset.x - plate.size.width / 2,
						y: line.offset.y - plate.size.height / 2,
						width: plate.size.width, height: plate.size.height))
				}
			case .shape(let fill, let corner, let kind):
				let box = CGSize(width: (key.width ?? 0.2) * size.width,
				                 height: (key.height ?? 0.02) * size.height)
				let ink = key.color ?? fill
				context.setFillColor(cg(ink))
				let morph = Scene.morph(of: keys, at: elapsed, default: kind)
				context.addPath(Scene.ShapeKind.morphed(
					morph, in: box, corner: corner * size.height))
				context.fillPath()

			case .bar(let bar):
				let box = CGRect(
					x: -(key.width ?? 0.4) * size.width / 2,
					y: -(key.height ?? 0.02) * size.height / 2,
					width: (key.width ?? 0.4) * size.width,
					height: (key.height ?? 0.02) * size.height)
				let rects = bar.rects(in: box, progress: key.progress ?? 0)
				let radius = min(bar.corner * size.height, box.width / 2, box.height / 2)
				if bar.track.a > 0 {
					context.setFillColor(cg(bar.track))
					context.addPath(CGPath(roundedRect: rects.track, cornerWidth: radius,
					                       cornerHeight: radius, transform: nil))
					context.fillPath()
				}
				if rects.fill.width > 0.01, rects.fill.height > 0.01 {
					context.setFillColor(cg(key.color ?? bar.fill))
					// The filled part is rounded by the same radius, clamped to
					// itself: a pill an eighth full is a short pill, not a
					// rectangle with one rounded end.
					let end = min(radius, rects.fill.width / 2, rects.fill.height / 2)
					context.addPath(CGPath(roundedRect: rects.fill, cornerWidth: end,
					                       cornerHeight: end, transform: nil))
					context.fillPath()
				}

			case .spinner(var spinner):
				if let colour = key.color { spinner.color = colour }
				if let progress = key.progress {
					paint(spinner, filledTo: progress, in: context, frame: size)
				} else if let drawn = spinnerImage(
					spinner, words: TextStyle.caption, size: size,
					elapsed: elapsed, span: max(elapsed, 1)) {
					context.draw(drawn.image, in: CGRect(
						x: -drawn.size.width / 2 + drawn.size.width * (0.5 - drawn.anchor.x),
						y: -drawn.size.height / 2,
						width: drawn.size.width, height: drawn.size.height))
				}
			case .image(let file):
				let url = URL(fileURLWithPath: file, relativeTo: baseURL)
				if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
				   let picture = CGImageSourceCreateImageAtIndex(source, 0, nil) {
					// Fitted inside the box rather than stretched to it, which
					// is what the layer path has always done — a logo came out
					// squashed here and correct in the export, and the two are
					// meant to be the same picture.
					let box = CGSize(width: (key.width ?? 0.2) * size.width,
					                 height: (key.height ?? 0.2) * size.height)
					let fit = min(box.width / CGFloat(picture.width),
					              box.height / CGFloat(picture.height))
					let drawn = CGSize(width: CGFloat(picture.width) * fit,
					                   height: CGFloat(picture.height) * fit)
					context.draw(picture, in: CGRect(
						x: -drawn.width / 2, y: -drawn.height / 2,
						width: drawn.width, height: drawn.height))
				}
			case .frames, .component:
				// One implementation for both keys, because by here they are
				// the same part: a folder of frames with a rate. Boxed and
				// fitted exactly as an image is — the same `min` of the two
				// scales — so a sequence and a still of the same picture land
				// in the same rectangle.
				guard let sequence = part.content.sequence(
					at: project.output.framesPerSecond) else { break }
				let count = sequence.count(relativeTo: baseURL)
				guard let picture = sequence.image(
					at: elapsed, relativeTo: baseURL, frames: count) else { break }
				let box = CGSize(width: (key.width ?? 0.2) * size.width,
				                 height: (key.height ?? 0.2) * size.height)
				let fit = min(box.width / CGFloat(picture.width),
				              box.height / CGFloat(picture.height))
				let drawn = CGSize(width: CGFloat(picture.width) * fit,
				                   height: CGFloat(picture.height) * fit)
				context.draw(picture, in: CGRect(
					x: -drawn.width / 2, y: -drawn.height / 2,
					width: drawn.width, height: drawn.height))
			case .background:
				break   // dealt with above, before the transform
			}
			context.restoreGState()
		}
		return context.makeImage()
	}

	private static func cg(_ colour: RGBA) -> CGColor {
		CGColor(srgbRed: colour.r, green: colour.g, blue: colour.b, alpha: colour.a)
	}

	/// A spinner that knows how far it has got: a ring filled to `progress`.
	///
	/// Drawn here and, in the layer path, as the same arc with `strokeEnd` —
	/// same centre, same radius, same thickness, same start at twelve o'clock,
	/// same way round. The styles are for the indeterminate case, where there
	/// is nothing to show but that it is still going; a spinner that knows the
	/// fraction has something better to say and says it the one way.
	private static func paint(
		_ spinner: Spinner, filledTo progress: Double, in context: CGContext, frame: CGSize
	) {
		let diameter = max(4, spinner.size * frame.height)
		let inset = diameter * SpinnerLook.ringInset
		let radius = (diameter - inset * 2) / 2
		context.setLineWidth(diameter * SpinnerLook.ringWidth)
		context.setLineCap(.round)
		context.setStrokeColor(cg(RGBA(r: spinner.color.r, g: spinner.color.g,
		                               b: spinner.color.b, a: spinner.color.a * 0.25)))
		context.addArc(center: .zero, radius: radius, startAngle: 0, endAngle: 2 * .pi,
		               clockwise: false)
		context.strokePath()

		let along = max(0, min(1, progress))
		guard along > 0.0005 else { return }
		context.setStrokeColor(cg(spinner.color))
		context.addArc(center: .zero, radius: radius, startAngle: .pi / 2,
		               endAngle: .pi / 2 - along * 2 * .pi, clockwise: true)
		context.strokePath()
	}

	/// A background across the whole frame: one colour, or a ramp between two.
	///
	/// Given the background as it is at this moment — both stops and the angle,
	/// with the keys already applied by ``Scene/Background/at(_:keys:)``.
	private static func paint(
		_ background: Scene.Background, in context: CGContext, size: CGSize
	) {
		let from = background.from
		guard let to = background.to else {
			context.setFillColor(CGColor(srgbRed: from.r, green: from.g, blue: from.b, alpha: from.a))
			context.fill(CGRect(origin: .zero, size: size))
			return
		}
		let colors = [
			CGColor(srgbRed: from.r, green: from.g, blue: from.b, alpha: from.a),
			CGColor(srgbRed: to.r, green: to.g, blue: to.b, alpha: to.a),
		] as CFArray
		guard let space = CGColorSpace(name: CGColorSpace.sRGB),
		      let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1])
		else { return }
		let ends = background.ends(in: size)
		// Clamped at both ends, so the corners a diagonal ramp does not reach
		// are the nearest stop rather than nothing at all.
		context.drawLinearGradient(gradient, start: ends.start, end: ends.end,
		                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
	}

	/// In and out, as the keyframes would have it — a fade fades, and anything
	/// else is either a slide or simply there.
	///
	/// Eased where the layer path's own envelope is eased, and told when each
	/// movement happens by ``OverlayTiming``, which is the same answer the
	/// keyframes are built from. The two used to work it out separately and
	/// would have disagreed about an overlay drawn before its span: this one is
	/// asked for a frame at a time and would have gone on ramping up from
	/// nothing after the mark.
	private static func fade(_ resolved: ResolvedOverlay, at time: Double) -> Double {
		let timing = resolved.timing
		guard timing.drawn(at: time) else { return 0 }
		var opacity = 1.0
		if timing.arrivesByFading { opacity = min(opacity, ease(.out, timing.arriving(at: time))) }
		if timing.departsByFading { opacity = min(opacity, ease(.in, 1 - timing.departing(at: time))) }
		return max(0, min(1, opacity))
	}

	/// How far off its home it is, for an overlay that slides.
	private static func slide(
		_ resolved: ResolvedOverlay, plate: CGSize, frame: CGSize, at time: Double
	) -> CGPoint {
		let timing = resolved.timing

		func offscreen(_ transition: Overlay.Transition) -> CGPoint {
			guard case .slide(let edge, _) = transition else { return .zero }
			switch edge {
			case .left: return CGPoint(x: -(frame.width + plate.width), y: 0)
			case .right: return CGPoint(x: frame.width + plate.width, y: 0)
			case .up: return CGPoint(x: 0, y: frame.height + plate.height)
			case .down: return CGPoint(x: 0, y: -(frame.height + plate.height))
			}
		}

		if time < timing.arriveTo {
			let from = offscreen(resolved.overlay.arrival)
			let progress = ease(.out, timing.arriving(at: time))
			return CGPoint(x: from.x * (1 - progress), y: from.y * (1 - progress))
		}
		if time > timing.departFrom {
			let to = offscreen(resolved.overlay.departure)
			let progress = ease(.in, timing.departing(at: time))
			return CGPoint(x: to.x * progress, y: to.y * progress)
		}
		return .zero
	}

	private enum Curve { case `in`, out }

	/// Core Animation's own ease-in and ease-out, near enough to the eye: the
	/// standard curves are cubic béziers, and this is the same shape.
	private static func ease(_ curve: Curve, _ t: Double) -> Double {
		let t = max(0, min(1, t))
		switch curve {
		case .out: return 1 - pow(1 - t, 2)
		case .in: return t * t
		}
	}
}
