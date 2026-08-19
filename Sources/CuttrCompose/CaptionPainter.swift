import CoreGraphics
import CoreImage
import Foundation
import QuartzCore

/// A caption as pixels, at a moment.
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
enum CaptionPainter {

	/// The overlay as it looks at `time`, in the frame's coordinates, or `nil`
	/// if there is nothing to draw.
	static func image(
		for resolved: ResolvedOverlay, project: Project, size: CGSize, at time: Double
	) -> CIImage? {
		guard case .text(let text, let styleName) = resolved.overlay.kind else { return nil }
		let style = project.style(named: styleName)
		let (layer, plate) = OverlayLayers.textLayer(text, style: style, size: size)
		guard let picture = layer.contents, CFGetTypeID(picture as CFTypeRef) == CGImage.typeID
		else { return nil }
		// swiftlint:disable:next force_cast
		let image = CIImage(cgImage: picture as! CGImage)

		let opacity = fade(resolved, at: time)
		guard opacity > 0.001 else { return nil }

		// Which point of the caption sits on the position, exactly as the layer
		// path decides it.
		let anchor: CGPoint
		let home: CGPoint
		if let path = resolved.path, let point = path.point(at: time) {
			anchor = CGPoint(x: 0.5, y: 0.5)
			home = CGPoint(x: point.x * size.width + resolved.overlay.offset.x * size.height,
			               y: point.y * size.height + resolved.overlay.offset.y * size.height)
		} else {
			anchor = CGPoint(x: style.alignment == .left ? 0 : style.alignment == .right ? 1 : 0.5,
			                 y: 0.5)
			home = CGPoint(x: style.position.x * size.width, y: style.position.y * size.height)
		}

		let slide = slide(resolved, plate: plate, frame: size, at: time)
		let origin = CGPoint(x: home.x - anchor.x * plate.width + slide.x,
		                     y: home.y - anchor.y * plate.height + slide.y)

		var drawn = image
			.transformed(by: CGAffineTransform(
				scaleX: plate.width / image.extent.width,
				y: plate.height / image.extent.height))
			.transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y))
		if opacity < 0.999 {
			drawn = drawn.applyingFilter("CIColorMatrix", parameters: [
				"inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity),
			])
		}
		return drawn
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
