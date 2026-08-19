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
enum OverlayPainter {

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
			guard let drawn = spinnerImage(spinner, words: wordStyle, resolved: resolved,
			                               size: size, at: time) else { return nil }
			return placed(drawn.image, plate: drawn.size, anchor: drawn.anchor,
			              home: home(resolved, style: wordStyle, size: size),
			              resolved: resolved, size: size, opacity: opacity, at: time)

		case .scene(let name, let parameters):
			guard let scene = project.scenes[name],
			      let drawn = sceneImage(scene, with: parameters, project: project,
			                             baseURL: baseURL, resolved: resolved,
			                             size: size, at: time) else { return nil }
			// A scene carries its own positions, so it is already frame-sized.
			return faded(CIImage(cgImage: drawn), by: opacity)

		case .effect:
			// Effects are drawn by their own renderer, not here.
			return nil
		}
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
		_ text: String, style: TextStyle, size: CGSize
	) -> (image: CGImage, size: CGSize)? {
		let (layer, plate) = OverlayLayers.textLayer(text, style: style, size: size)
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
	private static func spinnerImage(
		_ spinner: Spinner, words style: TextStyle, resolved: ResolvedOverlay,
		size: CGSize, at time: Double
	) -> (image: CGImage, size: CGSize, anchor: CGPoint)? {
		let diameter = max(4, spinner.size * size.height)
		let scale: CGFloat = 2

		// The word it is on, and how wide the block has to be for it.
		var word: String?
		let schedule = spinner.schedule(over: resolved.duration)
		if !schedule.isEmpty {
			var left = time - resolved.start
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
		let turn = -2 * CGFloat.pi * CGFloat(spinner.speed) * CGFloat(time - resolved.start)

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
			let breath = 0.72 + 0.28 * (0.5 + 0.5 * sin(2 * .pi * spinner.speed * (time - resolved.start)))
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
				let phase = (time - resolved.start) * spinner.speed - Double(step) / Double(SpinnerLook.bounce)
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
	private static func sceneImage(
		_ scene: Scene, with parameters: [String: String], project: Project, baseURL: URL,
		resolved: ResolvedOverlay, size: CGSize, at time: Double
	) -> CGImage? {
		guard let context = CGContext(
			data: nil, width: Int(size.width), height: Int(size.height),
			bitsPerComponent: 8, bytesPerRow: 0,
			space: CGColorSpace(name: CGColorSpace.sRGB)!,
			bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
		else { return nil }

		let elapsed = time - resolved.start
		for part in scene.parts {
			let keys = Scene.filled(part.keys)
			guard let key = value(of: keys, at: elapsed) else { continue }
			let opacity = key.opacity ?? 1
			guard opacity > 0.001 else { continue }

			context.saveGState()
			context.setAlpha(CGFloat(opacity))
			let centre = CGPoint(x: (key.x ?? 0.5) * size.width, y: (key.y ?? 0.5) * size.height)
			context.translateBy(x: centre.x, y: centre.y)
			context.rotate(by: CGFloat((key.rotation ?? 0) * .pi / 180))
			context.scaleBy(x: CGFloat(key.scale ?? 1), y: CGFloat(key.scale ?? 1))

			switch part.content {
			case .text(let text, let styleName):
				let style = project.style(named: styleName)
				if let plate = plate(Scene.fill(text, with: parameters), style: style, size: size) {
					context.draw(plate.image, in: CGRect(
						x: -plate.size.width / 2, y: -plate.size.height / 2,
						width: plate.size.width, height: plate.size.height))
				}
			case .shape(let fill, let corner):
				let box = CGRect(
					x: -(key.width ?? 0.2) * size.width / 2,
					y: -(key.height ?? 0.02) * size.height / 2,
					width: (key.width ?? 0.2) * size.width,
					height: (key.height ?? 0.02) * size.height)
				context.setFillColor(CGColor(srgbRed: fill.r, green: fill.g, blue: fill.b, alpha: fill.a))
				context.addPath(CGPath(
					roundedRect: box, cornerWidth: corner * size.height,
					cornerHeight: corner * size.height, transform: nil))
				context.fillPath()
			case .image(let file):
				let url = URL(fileURLWithPath: file, relativeTo: baseURL)
				if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
				   let picture = CGImageSourceCreateImageAtIndex(source, 0, nil) {
					let width = (key.width ?? 0.2) * size.width
					let height = (key.height ?? 0.2) * size.height
					context.draw(picture, in: CGRect(
						x: -width / 2, y: -height / 2, width: width, height: height))
				}
			}
			context.restoreGState()
		}
		return context.makeImage()
	}

	/// The part's values at a moment: the two keys either side of it, eased
	/// between. Before the first key it is the first, after the last it is the
	/// last — which is what `fillMode: .both` does for the layer version.
	private static func value(of keys: [Scene.Key], at time: Double) -> Scene.Key? {
		guard let first = keys.first, let last = keys.last else { return nil }
		if time <= first.t { return first }
		if time >= last.t { return last }
		guard let next = keys.firstIndex(where: { $0.t > time }), next > 0 else { return last }
		let before = keys[next - 1], after = keys[next]
		let span = max(after.t - before.t, 0.0001)
		let fraction = eased(after.ease, (time - before.t) / span)

		func between(_ a: Double?, _ b: Double?) -> Double? {
			guard let a, let b else { return b ?? a }
			return a + (b - a) * fraction
		}
		return Scene.Key(
			t: time,
			x: between(before.x, after.x), y: between(before.y, after.y),
			opacity: between(before.opacity, after.opacity),
			scale: between(before.scale, after.scale),
			rotation: between(before.rotation, after.rotation),
			width: between(before.width, after.width),
			height: between(before.height, after.height),
			ease: after.ease)
	}

	private static func eased(_ ease: Scene.Ease, _ t: Double) -> Double {
		let t = max(0, min(1, t))
		switch ease {
		case .linear: return t
		case .in: return t * t
		case .out: return 1 - pow(1 - t, 2)
		case .inOut: return t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
		}
	}

	/// In and out, as the keyframes would have it — a fade fades, and anything
	/// else is either a slide or simply there.
	private static func fade(_ resolved: ResolvedOverlay, at time: Double) -> Double {
		let span = max(resolved.duration, 0.0001)
		let arrive = min(resolved.overlay.arrival.duration, span / 2)
		let depart = min(resolved.overlay.departure.duration, span / 2)
		var opacity = 1.0
		if case .fade = resolved.overlay.arrival, arrive > 0, time < resolved.start + arrive {
			opacity = min(opacity, ease(.out, (time - resolved.start) / arrive))
		}
		if case .fade = resolved.overlay.departure, depart > 0, time > resolved.end - depart {
			opacity = min(opacity, ease(.in, (resolved.end - time) / depart))
		}
		return max(0, min(1, opacity))
	}

	/// How far off its home it is, for an overlay that slides.
	private static func slide(
		_ resolved: ResolvedOverlay, plate: CGSize, frame: CGSize, at time: Double
	) -> CGPoint {
		let span = max(resolved.duration, 0.0001)
		let arrive = min(resolved.overlay.arrival.duration, span / 2)
		let depart = min(resolved.overlay.departure.duration, span / 2)

		func offscreen(_ transition: Overlay.Transition) -> CGPoint {
			guard case .slide(let edge, _) = transition else { return .zero }
			switch edge {
			case .left: return CGPoint(x: -(frame.width + plate.width), y: 0)
			case .right: return CGPoint(x: frame.width + plate.width, y: 0)
			case .up: return CGPoint(x: 0, y: frame.height + plate.height)
			case .down: return CGPoint(x: 0, y: -(frame.height + plate.height))
			}
		}

		if arrive > 0, time < resolved.start + arrive {
			let from = offscreen(resolved.overlay.arrival)
			let progress = ease(.out, (time - resolved.start) / arrive)
			return CGPoint(x: from.x * (1 - progress), y: from.y * (1 - progress))
		}
		if depart > 0, time > resolved.end - depart {
			let to = offscreen(resolved.overlay.departure)
			let progress = ease(.in, 1 - (resolved.end - time) / depart)
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
