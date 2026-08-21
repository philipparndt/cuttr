import CoreGraphics
import CuttrKit
import Foundation

/// End credits, made from what the project already knows.
///
/// The project says which takes it draws on and each take says who talks in it,
/// so "who is in this film" is derivable rather than something to type twice.
/// What this produces is a scene made of a ``Scene/Roll``, a card at the end of
/// the timeline to play it over, and the overlay that joins them — which is
/// exactly the three things somebody would have written by hand, in the same
/// words. Nothing here is a mode the file cannot express: run the command, read
/// the diff, keep editing.
///
/// **The second time is the interesting one.** Three more takes get cut in next
/// week and the roll has to catch up without losing the four lines somebody
/// typed themselves. That is what ``Scene/Roll/Source`` is for, and
/// ``regenerated(_:cast:)`` is the whole of the operation.
public enum Credits {

	/// What the scene editor's `+` menu adds: one block whose names come from
	/// the cast, and one somebody typed.
	///
	/// Two blocks rather than one, because the pair is the thing worth
	/// learning — the first is refilled by "Update Credits", the second never
	/// is, and seeing them side by side says so better than a note would.
	public static let emptyRoll = Scene.Roll(
		entries: [
			Scene.Roll.Entry(role: "Featuring", names: [], source: .cast),
			Scene.Roll.Entry(role: "Filmed by", names: ["Somebody"]),
		],
		style: "credit", roleStyle: "credit-role", titleStyle: "credit-title")

	/// A look for the whole plate. Three, because three is what people ask for.
	///
	/// Each one departs from the others in the only three things that make a
	/// credit sequence what it is: how the lines sit, what they are set in, and
	/// what happens over time. All three are written into the file as ordinary
	/// parts, keys and styles, so a preset is a starting point and never a mode
	/// — change one number and it is no longer any preset, which is the point.
	public enum Preset: String, Sendable, CaseIterable {
		/// A roll up the frame on near-black, roles against names. What a
		/// television programme does, and the one to reach for when there are
		/// more than a handful of names.
		case broadcast
		/// One block at a time, centred, fading through. For a short cast,
		/// where a roll would be over before it had started.
		case cards
		/// Warm, centred, generous with its air, and pushing in very slightly
		/// as it goes. For a film about people rather than about work.
		case family

		public var described: String {
			switch self {
			case .broadcast: return "Roll up the frame, roles against names"
			case .cards: return "One block at a time, centred, fading through"
			case .family: return "Warm and centred, drifting up with a slow push in"
			}
		}

		/// How long one line takes to cross the frame, which is the only number
		/// that decides whether a roll is readable.
		///
		/// Nine tenths of a second is roughly what broadcast rolls run at. The
		/// family one is slower because nobody is in a hurry, and because the
		/// type is bigger.
		var secondsPerLine: Double {
			switch self {
			case .broadcast: return 0.9
			case .family: return 1.15
			case .cards: return 0.9
			}
		}

		/// What the card under the scene is filled with.
		///
		/// On the card and not as a `background:` part in the scene, which is
		/// the house rule for grounds: a scene with a full-frame background
		/// hides anything drawn into the picture under it, and it makes the
		/// same scene unusable over the last shot. The card is the ground; the
		/// scene is the words.
		var fill: Card.Fill {
			switch self {
			case .broadcast, .cards: return .solid(RGBA(hex: "#08090b")!)
			case .family: return .gradient(top: RGBA(hex: "#2b1b12")!,
			                               bottom: RGBA(hex: "#0d0908")!)
			}
		}

		/// The style names this preset's roll refers to.
		///
		/// The broadcast one names the built-ins and writes no `styles:` block
		/// at all — the plainest file that does the job. The other two bring
		/// styles of their own under names of their own, so that making a
		/// family outro in a project that already has a broadcast one changes
		/// nothing about the broadcast one. Presets that shared a style name
		/// would either overwrite each other's look or silently inherit it.
		var faces: (names: String, roles: String, title: String) {
			switch self {
			case .broadcast: return ("credit", "credit-role", "credit-title")
			case .cards: return ("credit-card", "credit-card-role", "credit-card-title")
			case .family: return ("credit-warm", "credit-warm-role", "credit-warm-title")
			}
		}

		/// The styles this preset wants written into the project.
		///
		/// Empty for the broadcast one, whose names are already built in.
		public var styles: [String: TextStyle] {
			let plate = RGBA(r: 0, g: 0, b: 0, a: 0)
			switch self {
			case .broadcast:
				return [:]
			case .cards:
				// Bigger, because a card has one block on it and the whole
				// frame to say it in.
				return [
					faces.names: TextStyle(
						font: "Helvetica Neue Medium", size: 0.058, color: .white,
						background: plate, padding: 0, cornerRadius: 0, alignment: .centre),
					faces.roles: TextStyle(
						font: "Helvetica Neue", size: 0.034,
						color: RGBA(hex: "#8b97a8")!,
						background: plate, padding: 0, cornerRadius: 0, alignment: .centre),
					faces.title: TextStyle(
						font: "Helvetica Neue Bold", size: 0.084, color: .white,
						background: plate, padding: 0, cornerRadius: 0, alignment: .centre),
				]
			case .family:
				return [
					faces.names: TextStyle(
						font: "Avenir Next Medium", size: 0.050,
						color: RGBA(hex: "#fff3e2")!,
						background: plate, padding: 0, cornerRadius: 0, alignment: .centre),
					faces.roles: TextStyle(
						font: "Avenir Next Italic", size: 0.034,
						color: RGBA(hex: "#e8a33d")!,
						background: plate, padding: 0, cornerRadius: 0, alignment: .centre),
					faces.title: TextStyle(
						font: "Avenir Next Demi Bold", size: 0.078,
						color: RGBA(hex: "#fff3e2")!,
						background: plate, padding: 0, cornerRadius: 0, alignment: .centre),
				]
			}
		}
	}

	// MARK: - Who is in the film

	/// The cast, in the order the film introduces them.
	///
	/// One line per person, and a person is a slug: somebody who talks in three
	/// takes is credited once. The order is the order the project lists its
	/// takes, then the order each take lists its speakers — chosen because it
	/// is *stable*, which matters more here than any ranking would. A derived
	/// order that changed between two runs would make re-generating an
	/// unchanged project rewrite the file, and a tool whose files churn is
	/// worthless.
	///
	/// `used` is the takes the timeline actually plays, so cutting a take out of
	/// the programme takes its people out of the credits. Empty means "no
	/// answer to that question" — a project that has not resolved, or one made
	/// entirely of cards — and then every take counts, because the alternative
	/// is silently crediting nobody.
	///
	/// What is shown is ``CuttrKit/Speaker/title``: the name where there is one
	/// and the slug otherwise, which is a cast of `mia` and `papa` being
	/// perfectly usable before anybody types the names out. The place to correct
	/// a spelling is the take — these lines are a view of it, and this is why
	/// the roll's derived names are refilled rather than edited in place.
	public static func cast(
		of takes: [(name: String, speakers: [Speaker])], used: Set<String> = []
	) -> [String] {
		var seen = Set<String>()
		var out: [String] = []
		for take in takes where used.isEmpty || used.contains(take.name) {
			for speaker in take.speakers where speaker.slug != Speaker.unknown {
				guard seen.insert(speaker.slug).inserted else { continue }
				out.append(speaker.title)
			}
		}
		return out
	}

	// MARK: - Making one

	/// A number as somebody would write it: three places, which is a thousandth
	/// of the frame and finer than anybody can see.
	///
	/// Rounded because these are *derived* numbers that land in a file people
	/// read, and because re-deriving a rounded number gives the rounded number
	/// back — which is what makes re-generating an unchanged roll rewrite
	/// nothing.
	static func rounded(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }

	/// A length, to the nearest half second.
	static func half(_ value: Double) -> Double { (value * 2).rounded() / 2 }

	/// The roll a preset starts from: the title over one block filled in from
	/// the cast.
	///
	/// One derived block and nothing else, on purpose. Everything a real end
	/// plate says beyond who was in it — who filmed it, whose music it is, the
	/// year — is something only a person knows, and inventing headings for them
	/// would fill the file with blanks somebody then has to delete. There is
	/// one block, it is right, and adding to it is typing a line.
	public static func roll(
		_ preset: Preset, title: String?, cast: [String], role: String = "Featuring"
	) -> Scene.Roll {
		let faces = preset.faces
		switch preset {
		case .broadcast:
			return Scene.Roll(
				entries: [Scene.Roll.Entry(role: role, names: cast, source: .cast)],
				title: title, style: faces.names, roleStyle: faces.roles,
				titleStyle: faces.title,
				line: 0.062, gap: 0.7, column: 0.028, align: .columns)
		case .cards:
			return Scene.Roll(
				entries: [Scene.Roll.Entry(role: role, names: cast, source: .cast)],
				title: title, style: faces.names, roleStyle: faces.roles,
				titleStyle: faces.title,
				line: 0.082, gap: 0.8, column: 0.028, align: .centre)
		case .family:
			return Scene.Roll(
				entries: [Scene.Roll.Entry(role: role, names: cast, source: .cast)],
				title: title, style: faces.names, roleStyle: faces.roles,
				titleStyle: faces.title,
				line: 0.078, gap: 1, column: 0.028, align: .centre, tracking: 0.02)
		}
	}

	/// The scene, and how long it wants to be.
	///
	/// The length comes back rather than going in because it is not a free
	/// choice: a roll is as long as it takes to read, which is the height of the
	/// column at a readable speed. Stating one anyway is allowed — somebody
	/// cutting to music has a bar to land on — and then the speed is whatever
	/// that implies.
	///
	/// `size` is the output size, because the column is measured in it: a style
	/// says its type size as a fraction of the frame height, so how tall the
	/// column comes to depends on the frame it is laid out in. `project` is
	/// wanted for its styles, and must already have the preset's own in it —
	/// see ``outro(of:named:preset:title:cast:over:)``.
	public static func scene(
		_ preset: Preset, title: String? = nil, cast: [String],
		over stated: Double? = nil, in project: Project, size: CGSize
	) -> (scene: Scene, seconds: Double) {
		let column = roll(preset, title: title, cast: cast)
		switch preset {
		case .broadcast, .family:
			// How far it travels: its own height plus the frame, which is what
			// carries the first line on from below the bottom edge and the last
			// line off past the top one.
			let tall = column.height(in: size, project: project)
			// To the nearest half second, which is how anybody says how long a
			// thing runs. The reading speed it comes from is a rule of thumb, so
			// carrying three decimals of it into the file would be a precision
			// the number does not have — and `card: 00:20.321` looks like the
			// answer to a question nobody asked.
			let seconds = half(stated
				?? max(4, preset.secondsPerLine * (tall + 1) / max(column.line, 0.001)))
			var first = Scene.Key(t: 0, x: 0.5, y: rounded(-tall / 2), opacity: 1,
			                      scale: 1, ease: .linear)
			var last = Scene.Key(t: seconds, y: rounded(1 + tall / 2), ease: .linear)
			if preset == .family {
				// A push in over the whole run: two more numbers on keys that
				// were there anyway, and the difference between a roll and a
				// roll somebody made.
				first.scale = 1
				last.scale = 1.04
			}
			return (Scene(parts: [Scene.Part(content: .roll(column), keys: [first, last])]),
			        seconds)

		case .cards:
			// One roll per block, each held still and faded through. A card is a
			// column of one, which is why this needs no second mechanism: what
			// scrolls a roll is its keys, and these keys do not scroll.
			let fade = 0.5, hold = 1.8
			let each = fade * 2 + hold
			var blocks: [Scene.Roll] = []
			if let title, !title.isEmpty {
				var plate = column
				plate.entries = []
				plate.title = title
				blocks.append(plate)
			}
			for entry in column.entries {
				var plate = column
				plate.title = nil
				plate.entries = [entry]
				blocks.append(plate)
			}
			let parts = blocks.enumerated().map { index, block in
				let start = Double(index) * each
				return Scene.Part(content: .roll(block), keys: [
					Scene.Key(t: rounded(start), x: 0.5, y: 0.5, opacity: 0, scale: 1),
					Scene.Key(t: rounded(start + fade), opacity: 1, ease: .out),
					Scene.Key(t: rounded(start + fade + hold), opacity: 1, ease: .linear),
					Scene.Key(t: rounded(start + each), opacity: 0, ease: .in),
				])
			}
			// Not to the nearest half second like a roll's, because this one is
			// not a reading speed rounded off: it is the sum of the times the
			// keys above already say, and a card half a second shorter would cut
			// the last fade in two.
			let seconds = rounded(stated ?? max(each, Double(blocks.count) * each))
			return (Scene(parts: parts), seconds)
		}
	}

	/// An outro scene, the card to play it over, and the overlay that joins
	/// them — added to the project.
	///
	/// All three, because one of them alone does nothing: a scene nobody uses is
	/// not in the film, and a card with nothing on it is a hole in it. The card
	/// goes on the end of the timeline and is named with `as:`, so the overlay
	/// hangs on `@credits` rather than on a time — which keeps it right when
	/// three more shots go in front of it.
	///
	/// Cut in and cut out, not faded: the roll arrives from below the frame and
	/// leaves above it, so it fades itself, and the card presets do it with
	/// their own keys. A fade on top of either would be a second fade nobody
	/// asked for.
	@discardableResult
	public static func outro(
		of project: Project, named requested: String = "credits",
		preset: Preset = .broadcast, title: String? = nil, cast: [String],
		over stated: Double? = nil
	) -> (project: Project, scene: String, seconds: Double) {
		var next = project
		// Never over the top of a style the project already defines. Somebody
		// who has tuned `credit` has tuned it, and a command that quietly reset
		// it is a command nobody presses twice.
		for (name, style) in preset.styles where next.styles[name] == nil {
			next.styles[name] = style
		}
		let name = Slug.unique(Slug.make(from: requested),
		                       taken: taken(in: next).union(next.scenes.keys))
		let made = scene(preset, title: title, cast: cast, over: stated,
		                 in: next, size: project.output.size)
		next.scenes[name] = made.scene
		next.timeline.append(TimelineEntry(
			card: Card(duration: made.seconds, fill: preset.fill),
			transition: .cut, label: name))
		next.overlays.append(Overlay(
			kind: .scene(name, with: [:]),
			span: .marks(from: .group(name), to: .group(name)),
			arrival: .cut, departure: .cut))
		return (next, name, made.seconds)
	}

	/// Every name the timeline already answers to, so a new card's `as:` does
	/// not collide with a section or another placement.
	private static func taken(in project: Project) -> Set<String> {
		func walk(_ entries: [TimelineEntry]) -> [String] {
			entries.flatMap { entry -> [String] in
				var found = entry.label.map { [$0] } ?? []
				if case .group(let name, let inner) = entry.source {
					found += [name] + walk(inner)
				}
				return found
			}
		}
		return Set(walk(project.timeline))
	}

	// MARK: - Doing it again

	/// Whether anything in this project was derived, which is whether there is
	/// anything for an update to do.
	public static func derives(from project: Project) -> Bool {
		project.scenes.values.contains { scene in
			scene.parts.contains { part in
				if case .roll(let roll) = part.content { return roll.derives }
				return false
			}
		}
	}

	/// The project with every derived block brought up to date.
	///
	/// Two things change and nothing else does. The names under a block that
	/// says `from: cast` are replaced — the role above them is not, so a role
	/// somebody rewrote stays rewritten. And where such a roll *scrolls*, the
	/// first and last `y` are re-derived from the column's new height.
	///
	/// That second one is not a liberty: those two numbers are "just below the
	/// bottom edge" and "just past the top edge", which is the only pair that
	/// makes sense for a roll and is a consequence of how tall the column is.
	/// Leaving them alone after three names were added means the first lines are
	/// already on screen at the cut and the last ones never reach the top — a
	/// roll that is subtly wrong in a way nobody would connect to having added a
	/// take. Everything else about the keys is untouched: the times, the easing,
	/// the opacity, the scale. A roll whose `y` does not move — a card, held
	/// still — is not touched at all.
	///
	/// With an unchanged cast this rewrites nothing whatsoever, because the
	/// cast is derived in a fixed order and the derived numbers are rounded to
	/// where re-deriving them lands on the same value.
	public static func regenerated(_ project: Project, cast: [String]) -> Project {
		var next = project
		let size = project.output.size
		for (name, scene) in project.scenes {
			var changed = scene
			for index in changed.parts.indices {
				guard case .roll(let roll) = changed.parts[index].content, roll.derives
				else { continue }
				let updated = roll.regenerated(cast: cast)
				changed.parts[index].content = .roll(updated)
				changed.parts[index].keys = rescrolled(
					changed.parts[index].keys,
					to: updated.height(in: size, project: project))
			}
			if changed != scene { next.scenes[name] = changed }
		}
		return next
	}

	/// The keys of a roll that scrolls, with its ends put back where the column
	/// now reaches. Keys that do not move in `y` come back exactly as they were.
	private static func rescrolled(_ keys: [Scene.Key], to tall: Double) -> [Scene.Key] {
		let sorted = keys.sorted { $0.t < $1.t }
		guard sorted.count >= 2, let first = sorted.first?.y, let last = sorted.last?.y,
		      first != last
		else { return keys }
		var out = sorted
		// Whichever way round it runs. Up the frame is what a roll does; a
		// project that scrolls one downwards means it, and gets the same two
		// numbers the other way about.
		let bottom = rounded(-tall / 2), top = rounded(1 + tall / 2)
		out[0].y = first < last ? bottom : top
		out[out.count - 1].y = first < last ? top : bottom
		return out
	}
}
