import CoreGraphics
import Foundation

/// Changing a scene: the arithmetic an editor needs, kept out of the window.
///
/// All of it is on values and none of it knows about AppKit, so what the stage
/// does when somebody drags a title is the same thing a test can do without a
/// screen. The editor is then the part that reads mouse events, which is the
/// part that cannot be tested anyway.
public extension Scene {

	/// The numbers on a key that an editor sets one at a time.
	///
	/// A list rather than seven functions, because the key table draws one row
	/// per field and the stage writes one field per drag — and both of them
	/// would otherwise be a switch that has to be kept in step with the format.
	enum Field: String, Sendable, CaseIterable {
		case x, y, opacity, scale, rotation, width, height, progress
		/// Which way a background's ramp runs. Not every part has one, which is
		/// why ``fields(for:)`` and not ``allCases`` is what the form asks.
		case angle

		/// What moving this by one unit means on screen, for a drag.
		public var unit: String {
			switch self {
			case .x, .y, .width, .height: return "of the frame"
			case .opacity, .scale, .progress: return "×"
			case .rotation, .angle: return "°"
			}
		}
	}

	/// Whether this part is drawn at a size of its own — a shape and an image
	/// are, and text is whatever size the words come out.
	static func hasSize(_ content: Part.Content) -> Bool {
		switch content {
		// A sequence and a component are boxed for the same reason an image is:
		// the pixels arrived at whatever size they arrived at, and the keys say
		// how big they are on the picture.
		case .shape, .image, .bar, .frames, .component: return true
		// A roll is whatever size the column came to, like text and for the
		// same reason: it is measured, not stated.
		case .text, .background, .spinner, .roll: return false
		}
	}

	/// The fields worth showing for a part: a background does not move, and
	/// text has no width and height of its own.
	static func fields(for content: Part.Content) -> [Field] {
		switch content {
		case .background: return [.opacity, .angle]
		// A roll takes exactly what text takes. `y` is the one that matters —
		// a credit roll is that field moved from below the frame to above it.
		case .text, .roll: return [.x, .y, .opacity, .scale, .rotation]
		case .shape, .image, .frames, .component:
			return [.x, .y, .opacity, .scale, .rotation, .width, .height]
		// Everything a shape has, and how full it is. Spelt out rather than
		// ``allCases``, which would hand a bar the gradient's angle.
		case .bar: return [.x, .y, .opacity, .scale, .rotation, .width, .height, .progress]
		case .spinner: return [.x, .y, .opacity, .scale, .rotation, .progress]
		}
	}

	/// Whether a key on this part can name a shape kind — which only a shape
	/// part can, and which is why the inspector shows that row for one part and
	/// not for the others.
	static func morphs(_ content: Part.Content) -> Bool {
		if case .shape = content { return true }
		return false
	}
}

public extension Scene.Key {

	/// The field, if this key states it. `nil` means inherited from the key
	/// before, which is the distinction the whole format turns on.
	subscript(field: Scene.Field) -> Double? {
		get {
			switch field {
			case .x: return x
			case .y: return y
			case .opacity: return opacity
			case .scale: return scale
			case .rotation: return rotation
			case .width: return width
			case .height: return height
			case .progress: return progress
			case .angle: return angle
			}
		}
		set {
			switch field {
			case .x: x = newValue
			case .y: y = newValue
			case .opacity: opacity = newValue
			case .scale: scale = newValue
			case .rotation: rotation = newValue
			case .width: width = newValue
			case .height: height = newValue
			case .progress: progress = newValue
			case .angle: angle = newValue
			}
		}
	}

	/// Whether this key says anything beyond when it is.
	var isEmpty: Bool {
		Scene.Field.allCases.allSatisfy { self[$0] == nil }
			&& color == nil && to == nil && shape == nil
	}
}

public extension Scene.Part {

	/// This part's keys with one more at `t`, and which one that is.
	///
	/// The new key freezes whatever was already happening at that moment, and
	/// only that. A key stating nothing would inherit from the key *before* it
	/// rather than from the curve running through it — insert one half way
	/// through a move and the move stops dead there, which is not what anybody
	/// dropping a key means. So each field is written down when it is part-way
	/// between two others, and left out when it is not, which is the smallest
	/// key that leaves the part where it was at that moment.
	///
	/// Where it was at that moment, not the whole of the curve either side of
	/// it: the easing is applied again over each half, so a key dropped into
	/// the middle of an ease-out arrives at the same place at the same time and
	/// takes a slightly different route to it. Splitting the curve properly is
	/// not arithmetic these easings have, and the difference is a few pixels
	/// for a moment.
	func inserting(keyAt t: Double) -> (keys: [Scene.Key], index: Int) {
		let sorted = keys.sorted { $0.t < $1.t }
		if let existing = sorted.firstIndex(where: { abs($0.t - t) < 0.0005 }) {
			return (sorted, existing)
		}
		let filled = Scene.filled(sorted)
		guard let now = Scene.state(of: filled, at: t) else {
			return (sorted + [Scene.Key(t: t)], sorted.count)
		}
		// What it would be at `t` with no key here at all: the last stated
		// value before it. Anything that differs is mid-move and has to be
		// written down. Before the first key there is no such value, and a key
		// that inherits from nothing inherits from the format's defaults — so
		// that one says everything.
		let previous = filled.last { $0.t <= t }
		var key = Scene.Key(t: t)
		for field in Scene.Field.allCases where previous == nil || now[field] != previous?[field] {
			key[field] = now[field]
		}
		if previous == nil || now.color != previous?.color { key.color = now.color }
		if previous == nil || now.to != previous?.to { key.to = now.to }
		// The kind is not a number and does not slide, so a key dropped inside
		// a morph takes the kind it is coming *from*: the morph then runs from
		// here to the same place it was going, and the shape at this instant is
		// a little different from what it was. Said out loud because it is the
		// one field where dropping a key is not free.
		if previous == nil || now.shape != previous?.shape { key.shape = now.shape }
		// The ease belongs to the key it arrives at, so a key dropped inside a
		// move keeps the curve that move was using.
		key.ease = filled.first { $0.t > t }?.ease ?? .inOut

		var out = sorted
		let index = out.firstIndex { $0.t > t } ?? out.count
		out.insert(key, at: index)
		return (out, index)
	}
}
