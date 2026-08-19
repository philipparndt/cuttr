import CoreGraphics
import Foundation

/// Where each part of a scene is, at a moment, in the frame's own pixels.
///
/// The editor needs this and nothing else does: to know what somebody clicked
/// on it has to know where the parts are, and a title's box is whatever size
/// the words came out — which only the thing that measures type can say.
///
/// Computed from the same keys and the same text measurement the render uses,
/// rather than from a second guess about where a part probably is. A handle
/// drawn anywhere but on the thing it moves is worse than no handle.
public struct ScenePlacement: Sendable, Equatable {
	/// Which part of the scene, by its place in the list.
	public var part: Int
	/// The middle of the part, in frame pixels, origin bottom-left.
	public var centre: CGPoint
	/// Its size before ``scale`` and ``rotation`` are applied.
	public var size: CGSize
	public var scale: Double
	/// Degrees, anticlockwise.
	public var rotation: Double
	public var opacity: Double
	/// A background is the whole frame and has nowhere to be dragged to.
	public var isBackground: Bool

	public init(
		part: Int, centre: CGPoint, size: CGSize, scale: Double, rotation: Double,
		opacity: Double, isBackground: Bool
	) {
		self.part = part
		self.centre = centre
		self.size = size
		self.scale = scale
		self.rotation = rotation
		self.opacity = opacity
		self.isBackground = isBackground
	}

	/// Whether a point in frame pixels is on this part — its box, turned back
	/// by however far the part is turned.
	public func contains(_ point: CGPoint) -> Bool {
		let radians = -rotation * .pi / 180
		let dx = point.x - centre.x, dy = point.y - centre.y
		let x = dx * cos(radians) - dy * sin(radians)
		let y = dx * sin(radians) + dy * cos(radians)
		let half = CGSize(width: max(size.width * scale, 8) / 2,
		                  height: max(size.height * scale, 8) / 2)
		return abs(x) <= half.width && abs(y) <= half.height
	}

	/// A corner of the box, in frame pixels, turned with the part.
	///
	/// `sx` and `sy` are −1 or 1: which corner.
	public func corner(_ sx: Double, _ sy: Double) -> CGPoint {
		let radians = rotation * .pi / 180
		let x = sx * size.width * scale / 2, y = sy * size.height * scale / 2
		return CGPoint(x: centre.x + x * cos(radians) - y * sin(radians),
		               y: centre.y + x * sin(radians) + y * cos(radians))
	}

	/// Where the handle that turns the part sits: above the top of the box,
	/// far enough out not to be mistaken for the corner beside it.
	public func handle(above gap: Double) -> CGPoint {
		let radians = rotation * .pi / 180
		let y = size.height * scale / 2 + gap
		return CGPoint(x: centre.x - y * sin(radians), y: centre.y + y * cos(radians))
	}
}

public enum SceneLayout {

	/// Every part of the scene, placed, at `elapsed` seconds from its start.
	///
	/// Parts with nothing left of them — a key says `opacity: 0` — are placed
	/// all the same. Something invisible at this moment is still the thing
	/// somebody is editing, and a part that cannot be selected while it is
	/// fading in cannot be given the key that stops it fading in.
	public static func placements(
		of scene: Scene, with parameters: [String: String] = [:],
		project: Project, size: CGSize, at elapsed: Double
	) -> [ScenePlacement] {
		scene.parts.enumerated().compactMap { index, part in
			guard let key = Scene.state(of: Scene.filled(part.keys), at: elapsed) else { return nil }
			if case .background = part.content {
				return ScenePlacement(
					part: index, centre: CGPoint(x: size.width / 2, y: size.height / 2),
					size: size, scale: 1, rotation: 0, opacity: key.opacity ?? 1,
					isBackground: true)
			}
			let box: CGSize
			switch part.content {
			case .text(let text, let styleName, let tracking):
				let style = project.style(named: styleName)
				box = OverlayLayers.textLayer(Scene.fill(text, with: parameters),
				                              style: style, size: size, tracking: tracking).1
			case .shape, .image, .bar:
				box = CGSize(width: (key.width ?? 0.2) * size.width,
				             height: (key.height ?? 0.02) * size.height)
			case .spinner(let spinner):
				// A spinner is as wide as it is tall and says so itself; the
				// key's width and height mean nothing to it.
				let diameter = spinner.size * size.height
				box = CGSize(width: diameter, height: diameter)
			case .background:
				box = size
			}
			return ScenePlacement(
				part: index,
				centre: CGPoint(x: (key.x ?? 0.5) * size.width, y: (key.y ?? 0.5) * size.height),
				size: box, scale: key.scale ?? 1, rotation: key.rotation ?? 0,
				opacity: key.opacity ?? 1, isBackground: false)
		}
	}
}
