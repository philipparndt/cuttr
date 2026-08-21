import CoreGraphics
import CuttrKit
import Foundation
import Testing
@testable import CuttrCompose

/// The arithmetic of a credit column, with the measuring stubbed out.
///
/// A width is the one thing here that needs a font; everything else is adding
/// up, and adding up is what goes wrong. So the layout takes its measurement as
/// a function and these tests hand it one that counts characters — which makes
/// every offset below an exact number rather than something to compare against
/// a screenshot.
@Suite struct CreditRollLayoutTests {

	/// Ten pixels a character, whatever it says and whatever it is set in.
	private let ruler: Scene.Roll.Measuring = { text, _, _ in
		CGSize(width: Double(text.count) * 10, height: 0)
	}

	private let frame = CGSize(width: 1920, height: 1080)

	private func roll(_ align: Scene.Roll.Align = .columns) -> Scene.Roll {
		Scene.Roll(
			entries: [
				Scene.Roll.Entry(role: "R", names: ["aa", "b"]),
				Scene.Roll.Entry(role: "S", names: ["ccc"]),
			],
			title: "T", line: 0.1, gap: 0.5, column: 0.1, align: align)
	}

	/// Four rows of names, a title, and two gaps: 108 pixels a line at this
	/// size, so the column comes to exactly half the frame.
	@Test func blocksStackByTheLineHeight() {
		let laid = roll().laidOut(in: frame, project: Project(), measure: ruler)
		// Rounded, because seven line heights of a tenth of 1080 add up through
		// a tenth that is not a tenth. A thousandth of a pixel is not a layout
		// question and asserting on it is how a test becomes weather.
		#expect(laid.size.height.rounded() == 540)
		// Title, then the role and its first name on one row, then the rest.
		let ys = laid.lines.map { $0.offset.y.rounded() }
		#expect(ys == [216, 54, 54, -54, -216, -216])
	}

	/// The height needs no font at all, which is what lets the generator write
	/// a scroll that carries the whole column past the frame.
	@Test func theHeightNeedsNoMeasuring() {
		#expect(abs(roll().height(in: frame, project: Project()) - 0.5) < 0.0001)
	}

	/// A line set half again as large takes half again as much room. Leading in
	/// proportion to the type, which is how anybody sets it.
	@Test func biggerTypeTakesProportionallyMoreRoom() {
		var project = Project()
		project.styles = [
			"small": TextStyle(size: 0.04, background: RGBA(r: 0, g: 0, b: 0, a: 0), padding: 0),
			"big": TextStyle(size: 0.08, background: RGBA(r: 0, g: 0, b: 0, a: 0), padding: 0),
		]
		let column = Scene.Roll(
			entries: [Scene.Roll.Entry(role: "R", names: ["a"])],
			title: "T", style: "small", roleStyle: "small", titleStyle: "big",
			line: 0.1, gap: 0, align: .centre)
		// One small role, one small name and one title at twice the size:
		// 108 + 108 + 216.
		#expect(column.laidOut(in: frame, project: project, measure: ruler)
			.size.height.rounded() == 432)
	}

	/// The whole point of `columns`: every role ends on one line and every name
	/// begins on another, a stated distance apart.
	@Test func aRoleIsSetAgainstItsNames() {
		let laid = roll().laidOut(in: frame, project: Project(), measure: ruler)
		let roles = laid.lines.filter { $0.text == "R" || $0.text == "S" }
		let names = laid.lines.filter { ["aa", "b", "ccc"].contains($0.text) }
		#expect(roles.count == 2)
		#expect(names.count == 3)
		let rightOfRoles = Set(roles.map { ($0.offset.x + $0.size.width / 2).rounded() })
		let leftOfNames = Set(names.map { ($0.offset.x - $0.size.width / 2).rounded() })
		#expect(rightOfRoles.count == 1)
		#expect(leftOfNames.count == 1)
		// Exactly `column` of the frame height between the two edges.
		#expect((leftOfNames.first! - rightOfRoles.first!) == 0.1 * 1080)
	}

	/// The column is centred on its own middle, because `x` on a key means the
	/// middle of the part for every other part too.
	@Test func theColumnIsCentredOnItself() {
		let laid = roll().laidOut(in: frame, project: Project(), measure: ruler)
		let low = laid.lines.map { $0.offset.x - $0.size.width / 2 }.min()!
		let high = laid.lines.map { $0.offset.x + $0.size.width / 2 }.max()!
		#expect(low == -laid.size.width / 2)
		#expect(high == laid.size.width / 2)
	}

	/// A title centred on the rule between the columns sits visibly off the
	/// column when the names are longer than the roles, which they always are.
	@Test func theTitleIsCentredOnTheColumnAndNotOnTheRule() {
		let laid = roll().laidOut(in: frame, project: Project(), measure: ruler)
		let title = laid.lines.first { $0.text == "T" }!
		let sides = laid.lines.filter { $0.text != "T" }
		let low = sides.map { $0.offset.x - $0.size.width / 2 }.min()!
		let high = sides.map { $0.offset.x + $0.size.width / 2 }.max()!
		// On the middle of the column the entries made, which is the middle of
		// the part.
		#expect(title.offset.x == (low + high) / 2)
		#expect(title.offset.x == 0)
		// And the rule is not there — it is left of the middle, because the
		// names are longer than the roles. Centring the title on it, which is
		// the answer that falls out of placing the two columns, would put the
		// title visibly off the column.
		let rule = laid.lines.first { $0.text == "R" }!
		#expect(rule.offset.x + rule.size.width / 2 < -1)
	}

	@Test func aCentredRollPutsEveryLineOnTheMiddle() {
		let laid = roll(.centre).laidOut(in: frame, project: Project(), measure: ruler)
		#expect(laid.lines.allSatisfy { $0.offset.x == 0 })
		// The widest line is the column: "ccc" at ten pixels a character.
		#expect(laid.size.width == 30)
		// And a centred roll gives every role a row of its own, where `columns`
		// sets it beside the first name — so two roles make it two lines taller
		// than the same blocks in columns: 540 and 216.
		#expect(laid.size.height.rounded() == 756)
	}

	@Test func aLeftRollRangesEveryLineFromOneEdge() {
		let laid = roll(.left).laidOut(in: frame, project: Project(), measure: ruler)
		let edges = Set(laid.lines.map { $0.offset.x - $0.size.width / 2 })
		#expect(edges.count == 1)
	}

	/// `{{name}}` is filled in before the column is measured, not after: a roll
	/// laid out on the placeholder and drawn on the answer lines up on neither.
	@Test func parametersAreFilledInBeforeMeasuring() {
		let column = Scene.Roll(entries: [Scene.Roll.Entry(role: "", names: ["{{year}}"])],
		                        line: 0.1, align: .centre)
		let laid = column.laidOut(in: frame, project: Project(), with: ["year": "1975"],
		                          measure: ruler)
		#expect(laid.lines.map(\.text) == ["1975"])
		#expect(laid.size.width == 40)
	}

	/// An empty roll is a roll being written, not a broken one.
	@Test func anEmptyRollLaysOutToNothing() {
		let laid = Scene.Roll().laidOut(in: frame, project: Project(), measure: ruler)
		#expect(laid.lines.isEmpty)
		#expect(laid.size == .zero)
	}
}

/// A roll through the file, which is the part that has to survive everything.
@Suite struct CreditRollFileTests {

	private func project(_ roll: Scene.Roll) -> Project {
		Project(
			timeline: [TimelineEntry(card: Card(duration: 20), transition: .cut, label: "credits")],
			overlays: [Overlay(kind: .scene("credits", with: [:]),
			                   span: .marks(from: .group("credits"), to: .group("credits")),
			                   arrival: .cut, departure: .cut)],
			scenes: ["credits": Scene(parts: [Scene.Part(content: .roll(roll), keys: [
				Scene.Key(t: 0, x: 0.5, y: -0.75, opacity: 1, scale: 1, ease: .linear),
				Scene.Key(t: 20, y: 1.75, ease: .linear),
			])])])
	}

	private func sample() -> Scene.Roll {
		Scene.Roll(
			entries: [
				Scene.Roll.Entry(role: "Featuring", names: ["Wren Halloway", "Mira Vance"],
				                 source: .cast),
				Scene.Roll.Entry(role: "Filmed by", names: ["Otto Kestrel"]),
			],
			title: "The Long Way Round", style: "credit", roleStyle: "credit-role",
			titleStyle: "credit-title", line: 0.062, gap: 0.7, column: 0.028,
			align: .columns, tracking: 0.02)
	}

	@Test func aRollSurvivesTheFile() throws {
		let written = ProjectWriter.write(project(sample()))
		#expect(written.contains("      - roll:"))
		#expect(written.contains("from: cast"))
		let back = try ProjectReader.read(written)
		#expect(back.scenes == project(sample()).scenes)
		#expect(ProjectWriter.write(back) == written)
	}

	@Test func writingIsStableForTheSameRoll() {
		#expect(ProjectWriter.write(project(sample())) == ProjectWriter.write(project(sample())))
	}

	/// A block of one name is a line. A block of eight is not, and a person
	/// would not have written it as one either.
	@Test func aLongBlockGoesToTheBlockForm() throws {
		var roll = sample()
		roll.entries[0].names = ["Wren Halloway", "Mira Vance", "Otto Kestrel",
		                         "Bo Fairweather", "Ines Calloway", "Rafe Winterbourne"]
		let written = ProjectWriter.write(project(roll))
		#expect(written.contains("          - role:  Featuring\n"))
		#expect(written.contains("            names:\n"))
		#expect(written.contains("              - Wren Halloway\n"))
		// The short block beside it is still one line.
		#expect(written.contains("{role: Filmed by, names: [Otto Kestrel]}"))
		let back = try ProjectReader.read(written)
		#expect(back.scenes == project(roll).scenes)
		#expect(ProjectWriter.write(back) == written)
	}

	@Test func readsWhatSomebodyWouldTypeByHand() throws {
		let text = """
		cuttr-project: 1

		timeline:
		  - card: 20
		    as:   credits

		scenes:
		  credits:
		    parts:
		      - roll:
		          - {role: Featuring, from: cast, names: [Wren Halloway]}
		          - role: Music
		            names: Otto Kestrel
		        title: The Long Way Round
		        align: center
		        keys:
		          - {t: 0, y: -0.8}
		          - {t: 20, y: 1.8, ease: linear}
		"""
		let project = try ProjectReader.read(text)
		guard case .roll(let roll) = project.scenes["credits"]?.parts.first?.content else {
			Issue.record("no roll read")
			return
		}
		#expect(roll.entries.count == 2)
		#expect(roll.entries[0].source == .cast)
		// A name written bare rather than as a list, which is what somebody
		// types for a block of one.
		#expect(roll.entries[1].names == ["Otto Kestrel"])
		#expect(roll.entries[1].source == nil)
		// Both spellings of the same word, as everywhere else in the format.
		#expect(roll.align == .centre)
		#expect(roll.title == "The Long Way Round")
	}

	/// A word the reader does not know is refused rather than quietly meaning
	/// something else, which is the rule the whole reader follows.
	@Test func aWordTheReaderDoesNotKnowIsRefused() {
		func read(_ align: String, _ from: String) -> Bool {
			(try? ProjectReader.read("""
			cuttr-project: 1
			scenes:
			  credits:
			    parts:
			      - roll:
			          - {role: Featuring, from: \(from), names: [Wren Halloway]}
			        align: \(align)
			        keys:
			          - {t: 0}
			""")) != nil
		}
		#expect(read("columns", "cast"))
		#expect(!read("sideways", "cast"))
		#expect(!read("columns", "the-take"))
	}

	/// A block with neither a role nor a name is not a block. Dropped rather
	/// than refused: it is a file somebody is in the middle of typing.
	@Test func anEmptyBlockIsNotABlock() throws {
		let project = try ProjectReader.read("""
		cuttr-project: 1
		scenes:
		  credits:
		    parts:
		      - roll:
		          - {role: Featuring, names: [Wren Halloway]}
		          - {}
		        keys:
		          - {t: 0}
		""")
		guard case .roll(let roll) = project.scenes["credits"]?.parts.first?.content else {
			Issue.record("no roll read")
			return
		}
		#expect(roll.entries.count == 1)
	}
}

/// Making an outro, and making it again next week.
@Suite struct CreditsTests {

	private func takes() -> [(name: String, speakers: [Speaker])] {
		[
			("take-01", [Speaker(slug: "wren", name: "Wren Halloway"),
			             Speaker(slug: "mira", name: "Mira Vance")]),
			("take-02", [Speaker(slug: "mira", name: "Mira Vance"),
			             Speaker(slug: Speaker.unknown),
			             Speaker(slug: "otto", name: "Otto Kestrel")]),
			("take-03", [Speaker(slug: "bo", name: "Bo Fairweather")]),
		]
	}

	@Test func theCastIsEverybodyOnce() {
		#expect(Credits.cast(of: takes()) ==
			["Wren Halloway", "Mira Vance", "Otto Kestrel", "Bo Fairweather"])
	}

	/// A take that is not on the timeline is not in the film, so nobody in it
	/// is in the credits.
	@Test func onlyTheTakesTheFilmUsesAreCredited() {
		#expect(Credits.cast(of: takes(), used: ["take-01", "take-02"]) ==
			["Wren Halloway", "Mira Vance", "Otto Kestrel"])
	}

	/// A voice nobody has put a name to is an answer, not a person.
	@Test func theUnknownVoiceIsNotCredited() {
		#expect(!Credits.cast(of: takes()).contains(Speaker.unknown))
	}

	/// Somebody with no name typed against their slug is still creditable —
	/// a cast of `mia` and `papa` is a usable cast.
	@Test func aSpeakerWithNoNameIsCreditedBySlug() {
		#expect(Credits.cast(of: [("take-01", [Speaker(slug: "papa")])]) == ["papa"])
	}

	private func outro(_ preset: Credits.Preset = .broadcast) -> (Project, String) {
		let made = Credits.outro(
			of: Project(timeline: [TimelineEntry(clip: ClipReference("intro"))]),
			preset: preset, title: "The Long Way Round",
			cast: ["Wren Halloway", "Mira Vance", "Otto Kestrel"])
		return (made.project, made.scene)
	}

	/// All three or none: a scene nobody uses is not in the film, and a card
	/// with nothing on it is a hole in it.
	@Test func anOutroBringsItsCardAndItsOverlay() {
		let (project, name) = outro()
		#expect(project.scenes[name] != nil)
		#expect(project.timeline.count == 2)
		#expect(project.timeline.last?.label == name)
		guard case .card(let card) = project.timeline.last?.source else {
			Issue.record("no card at the end of the timeline")
			return
		}
		#expect(card.duration > 4)
		#expect(project.overlays.count == 1)
		#expect(project.overlays[0].kind == .scene(name, with: [:]))
		// Hung on the card's own name rather than on a time, so three more
		// shots in front of it leave the credits where they belong.
		#expect(project.overlays[0].span == .marks(from: .group(name), to: .group(name)))
	}

	/// The roll starts below the bottom of the frame and ends above the top of
	/// it, so every line is read and none is half on at a cut.
	@Test func theRollCarriesTheWholeColumnPastTheFrame() {
		let (project, name) = outro()
		let part = project.scenes[name]!.parts[0]
		guard case .roll(let roll) = part.content else {
			Issue.record("not a roll")
			return
		}
		let tall = roll.height(in: project.output.size, project: project)
		#expect(part.keys.count == 2)
		#expect(part.keys[0].y == Credits.rounded(-tall / 2))
		#expect(part.keys[1].y == Credits.rounded(1 + tall / 2))
		// Which is to say: the top of the column is on the bottom edge at the
		// start, and its bottom is on the top edge at the end.
		#expect(abs((part.keys[0].y! + tall / 2)) < 0.001)
		#expect(abs((part.keys[1].y! - tall / 2) - 1) < 0.001)
	}

	@Test func everyPresetSurvivesTheFile() throws {
		for preset in Credits.Preset.allCases {
			let (project, _) = outro(preset)
			let written = ProjectWriter.write(project)
			let back = try ProjectReader.read(written)
			#expect(back.scenes == project.scenes, "\(preset)")
			#expect(back.styles == project.styles, "\(preset)")
			#expect(ProjectWriter.write(back) == written, "\(preset)")
		}
	}

	/// The plainest file that does the job: a broadcast roll names the built-in
	/// styles, so it writes no `styles:` block at all.
	@Test func theBroadcastPresetNeedsNoStyles() {
		let (project, _) = outro(.broadcast)
		#expect(project.styles.isEmpty)
		#expect(!ProjectWriter.write(project).contains("styles:"))
	}

	/// Two presets that shared a style name would overwrite each other's look.
	@Test func presetsDoNotShareStyleNames() {
		var seen = Set<String>()
		for preset in Credits.Preset.allCases {
			for name in preset.styles.keys {
				#expect(seen.insert(name).inserted, "\(name) is claimed twice")
			}
		}
	}

	/// Somebody who has tuned `credit` has tuned it.
	@Test func aStyleSomebodyTunedIsNotOverwritten() {
		var project = Project(timeline: [TimelineEntry(clip: ClipReference("intro"))])
		let mine = TextStyle(font: "Futura", size: 0.09)
		project.styles["credit-warm"] = mine
		let made = Credits.outro(of: project, preset: .family, cast: ["Wren Halloway"])
		#expect(made.project.styles["credit-warm"] == mine)
	}

	/// Two outros in one project are two scenes, not one overwritten.
	@Test func aSecondOutroTakesAName() {
		let (first, name) = outro()
		let second = Credits.outro(of: first, cast: ["Bo Fairweather"])
		#expect(second.scene != name)
		#expect(second.project.scenes.count == 2)
	}

	// MARK: - Doing it again

	/// A roll with one block from the cast and one somebody typed. The whole
	/// question this feature exists to answer.
	private func mixed() -> Project {
		let (project, name) = outro()
		var next = project
		var scene = next.scenes[name]!
		guard case .roll(var roll) = scene.parts[0].content else { return next }
		roll.entries[0].role = "Mit dabei"
		roll.entries.append(Scene.Roll.Entry(role: "Music", names: ["Ines Calloway"]))
		scene.parts[0].content = .roll(roll)
		next.scenes[name] = scene
		return next
	}

	private func rollOf(_ project: Project) -> Scene.Roll {
		for scene in project.scenes.values {
			for part in scene.parts {
				if case .roll(let roll) = part.content { return roll }
			}
		}
		return Scene.Roll()
	}

	@Test func regenerationRefillsTheDerivedBlockOnly() {
		let updated = Credits.regenerated(
			mixed(), cast: ["Wren Halloway", "Mira Vance", "Otto Kestrel", "Bo Fairweather"])
		let roll = rollOf(updated)
		#expect(roll.entries.count == 2)
		#expect(roll.entries[0].names.count == 4)
		// The role above a derived block is prose and stays whatever somebody
		// made it.
		#expect(roll.entries[0].role == "Mit dabei")
		// And the block nobody derived is untouched, in place.
		#expect(roll.entries[1] == Scene.Roll.Entry(role: "Music", names: ["Ines Calloway"]))
	}

	/// The one that matters: a file that churns on a no-op is a file nobody can
	/// review.
	@Test func regeneratingAnUnchangedProjectRewritesNothing() {
		let (project, _) = outro()
		let same = Credits.regenerated(
			project, cast: ["Wren Halloway", "Mira Vance", "Otto Kestrel"])
		#expect(ProjectWriter.write(same) == ProjectWriter.write(project))
	}

	/// And it settles: whatever somebody has done to the roll by hand, the
	/// second update in a row is a no-op.
	///
	/// Which is the same statement as the one above with the hand edits put
	/// back in — `mixed()` adds a block after the keys were written, so the
	/// first update legitimately puts the scroll back where the taller column
	/// now reaches. The second has nothing left to do.
	@Test func updatingTwiceIsUpdatingOnce() {
		let cast = ["Wren Halloway", "Mira Vance", "Otto Kestrel"]
		let once = Credits.regenerated(mixed(), cast: cast)
		let twice = Credits.regenerated(once, cast: cast)
		#expect(ProjectWriter.write(twice) == ProjectWriter.write(once))
	}

	/// Three more names make a taller column, and a taller column needs longer
	/// to get past the frame — otherwise the first lines are already on screen
	/// at the cut and the last never reach the top.
	@Test func aTallerColumnStillScrollsAllTheWayPast() {
		let project = mixed()
		let before = rollOf(project).height(in: project.output.size, project: project)
		let updated = Credits.regenerated(project, cast: [
			"Wren Halloway", "Mira Vance", "Otto Kestrel", "Bo Fairweather",
			"Ines Calloway", "Rafe Winterbourne",
		])
		let after = rollOf(updated).height(in: updated.output.size, project: updated)
		#expect(after > before)
		let keys = updated.scenes.values.first!.parts[0].keys
		#expect(keys[0].y == Credits.rounded(-after / 2))
		#expect(keys.last?.y == Credits.rounded(1 + after / 2))
		// The times are not touched: how long the roll runs is somebody's
		// decision and the card on the timeline already agrees with it.
		#expect(keys.map(\.t) == project.scenes.values.first!.parts[0].keys.map(\.t))
	}

	/// A roll held still is not a roll, and its `y` is a placement rather than
	/// a scroll. Nothing to re-derive.
	@Test func aRollThatIsHeldStillIsLeftAlone() {
		let (project, name) = outro(.cards)
		let updated = Credits.regenerated(project, cast: ["Wren Halloway", "Bo Fairweather"])
		for part in updated.scenes[name]!.parts {
			#expect(part.keys.allSatisfy { $0.y == nil || $0.y == 0.5 })
		}
	}

	@Test func aProjectWithNothingDerivedHasNothingToUpdate() {
		var project = Project(timeline: [TimelineEntry(clip: ClipReference("intro"))])
		project.scenes["outro"] = Scene(parts: [Scene.Part(
			content: .roll(Scene.Roll(entries: [
				Scene.Roll.Entry(role: "Filmed by", names: ["Otto Kestrel"]),
			])),
			keys: [Scene.Key(t: 0, x: 0.5, y: 0.5, opacity: 1)])])
		#expect(!Credits.derives(from: project))
		#expect(Credits.regenerated(project, cast: ["Wren Halloway"]) == project)
	}

	@Test func anOutroDerivesFromTheCast() {
		let (project, _) = outro()
		#expect(Credits.derives(from: project))
	}
}
