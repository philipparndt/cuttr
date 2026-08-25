import CoreGraphics
import Foundation

/// The two scenes that come with the program: `bullets` and `boxes`.
///
/// **Why built in at all.** The point of a presentation treatment is that
/// somebody making a screencast can say "stop here and put these three lines up
/// beside it" without authoring a scene. A scene is a list of parts with
/// keyframes on them, which is the right thing to be when a title card is being
/// designed and much too much when three sentences want to appear in order.
///
/// **Why they are scenes and not a new kind of thing.** They are made here and
/// then go through the compositor, the layer pass and the preview exactly as an
/// authored scene does. Nothing downstream knows the difference — and, because
/// they are resolved by name, a project that defines its own `bullets` wins.
/// The same rule ``TextStyle/builtIn`` already follows.
extension Scene {

	/// The names this program knows without being told.
	public static let builtInNames = ["bullets", "boxes"]

	/// A built-in scene, laid out for the parameters it was given, or `nil` if
	/// the name is not one of ours.
	///
	/// `with:` carries the snippets — `one:` through `five:` — and what the
	/// treatment knows that the scene cannot work out for itself: how long it
	/// is up, whether the lines arrive together, and which part of the frame
	/// the picture has left free.
	public static func builtIn(_ name: String, with parameters: [String: String]) -> Scene? {
		guard builtInNames.contains(name) else { return nil }
		let snippets = Self.snippets(in: parameters)
		guard !snippets.isEmpty else { return Scene() }

		let hold = parameters["hold"].flatMap(Double.init) ?? 4
		let together = parameters["reveal"] != "one-by-one"
		let left = parameters["column-x"].flatMap(Double.init) ?? 0.5
		let width = parameters["column-width"].flatMap(Double.init) ?? 0.5

		// Inside the free column, with a margin, and a row height that closes
		// up as the lines multiply so that five fit where two were comfortable.
		let margin = min(0.04, width / 6)
		let column = (x: left + margin, width: max(0.05, width - margin * 2))
		let centre = column.x + column.width / 2
		let step = snippets.count > 3 ? 0.115 : 0.145
		let top = 0.5 + Double(snippets.count - 1) * step / 2

		var parts: [Part] = []
		for (index, text) in snippets.enumerated() {
			let y = top - Double(index) * step
			// Together is not quite together: a tenth of a second between them
			// is the difference between a list appearing and a list being put
			// up, and it is far too quick to read as a sequence.
			let arrives = together
				? Double(index) * 0.08
				: Double(index) * (hold / Double(snippets.count))
			parts.append(contentsOf: row(name, text: text, at: y, in: column,
			                             centre: centre, from: arrives))
		}
		return Scene(parts: parts)
	}

	/// One line: a plate or a dot, and the words.
	private static func row(_ name: String, text: String, at y: Double,
	                        in column: (x: Double, width: Double),
	                        centre: Double, from arrives: Double) -> [Part] {
		// Rising a little as it fades in. The distance is small on purpose: a
		// line that travels reads as an animation, and what this wants is for
		// the line to have been there all along.
		func keys(x: Double, y: Double, width: Double? = nil, height: Double? = nil) -> [Key] {
			[
				Key(t: arrives, x: x, y: y - 0.012, opacity: 0, width: width, height: height),
				Key(t: arrives + 0.35, x: x, y: y, opacity: 1,
				    width: width, height: height, ease: .out),
			]
		}

		switch name {
		case "boxes":
			return [
				Part(content: .shape(fill: RGBA(r: 1, g: 1, b: 1, a: 0.1), corner: 0.012),
				     keys: keys(x: centre, y: y, width: column.width, height: 0.085)),
				Part(content: .text(text, style: "caption"), keys: keys(x: centre, y: y)),
			]
		default:
			// The mark is in the words rather than beside them, and that is a
			// concession: a scene part is placed by its middle, nothing here
			// can measure a line of type before it is drawn, and a dot on a
			// rail down the left of the column would sit an unknown distance
			// from the words it belongs to. Carried in the string, it is always
			// against them.
			//
			// A list ranged left is what somebody wants and what this cannot
			// give them. It is also two dozen lines of authored scene, and the
			// example beside this shows one — a project's own `bullets` beats
			// this, by the same rule the built-in text styles follow.
			return [
				Part(content: .text("•  " + text, style: "caption"),
				     keys: keys(x: centre, y: y)),
			]
		}
	}

	/// The snippets given, in order, with the gaps closed up.
	///
	/// A file that says `one:` and `three:` gets two lines and no space kept
	/// for the missing one — the names are how they are ordered, not where they
	/// sit.
	public static func snippets(in parameters: [String: String]) -> [String] {
		["one", "two", "three", "four", "five"].compactMap {
			guard let said = parameters[$0], !said.isEmpty else { return nil }
			return said
		}
	}
}
