import CoreGraphics
import CoreImage
import Foundation
import QuartzCore
import Testing
@testable import CuttrCompose

/// A line that types itself.
///
/// The bug this part was written for does not show up in a value: it is a
/// glyph cut down the middle on one frame in every letter, which is why most of
/// what is measured here is measured on the pixels.
@Suite struct SceneTypingTests {

	private let size = CGSize(width: 640, height: 360)
	private let context = CIContext(options: [.workingColorSpace: NSNull()])
	private let words = "dingsda"

	/// Monospaced, so a test can say where the fourth letter ends without
	/// asking the thing it is testing.
	private func project() -> Project {
		var project = Project()
		project.styles["typewriter"] = TextStyle(
			font: "Menlo-Bold", size: 0.1, color: .white,
			background: RGBA(r: 0, g: 0, b: 0, a: 0), padding: 0,
			cornerRadius: 0, position: CGPoint(x: 0.5, y: 0.5), alignment: .left)
		return project
	}

	private func scene(_ typed: Scene.Typing, over span: Double = 1.4) -> Scene {
		Scene(parts: [
			.init(content: .text(words, style: "typewriter", tracking: 0, typed: typed),
			      keys: [.init(t: 0, x: 0.5, y: 0.5, opacity: 1, scale: 1,
			                   progress: 0, ease: .linear),
			             .init(t: span, progress: 1, ease: .linear)]),
		])
	}

	// MARK: - How far it has got

	/// Even weights, an even line: the seventh letter of seven lands at one.
	@Test func aSteadyLineDividesItselfEvenly() {
		let marks = Scene.Typing(steady: 1).boundaries(of: words)
		#expect(marks.count == 8)
		for index in 0...7 {
			#expect(abs(marks[index] - Double(index) / 7) < 1e-12)
		}
	}

	/// Uneven, but still a list that rises and still ends on exactly one —
	/// which is what the weights are for. A hand that ran past the end would
	/// leave the last letter never typed.
	@Test func aHandIsUnevenButNeverOutOfOrder() {
		let line = "Jahrelang war die Sendung abgesetzt..."
		for steady in [0.0, 0.25, 0.5, 0.75] {
			let marks = Scene.Typing(steady: steady).boundaries(of: line)
			#expect(marks.first == 0)
			#expect(abs((marks.last ?? 0) - 1) < 1e-12, "steady \(steady) does not finish")
			for (before, after) in zip(marks, marks.dropFirst()) {
				#expect(after > before, "steady \(steady) puts a letter before the one in front")
			}
		}
		// And it is actually uneven, or `steady` does nothing.
		let hand = Scene.Typing(steady: 0.2).boundaries(of: line)
		let machine = Scene.Typing(steady: 1).boundaries(of: line)
		#expect(zip(hand, machine).contains { abs($0 - $1) > 0.01 })
	}

	/// The rhythm is arithmetic on the text, so two runs of the same line agree
	/// — which is the whole reason it is not a random number. A render has to
	/// give the same frames today and next year.
	@Test func theSameLineTypesTheSameWayEveryTime() {
		let line = "the thingamajig, in seven letters"
		let once = Scene.Typing(steady: 0.3).boundaries(of: line)
		let again = Scene.Typing(steady: 0.3).boundaries(of: line)
		#expect(once == again)
		// And a different line is a different rhythm rather than the same one
		// stretched, or the wobble is not reading the text at all.
		let other = Scene.Typing(steady: 0.3).boundaries(of: "the thingamajig, in seven letterz")
		#expect(once != other)
	}

	/// A count, never a fraction: one more character, then one more.
	@Test func charactersArriveOneAtATime() {
		let typed = Scene.Typing(steady: 0.4)
		var last = 0
		for step in 0...400 {
			let showing = typed.shown(of: words, at: Double(step) / 400)
			#expect(showing >= last, "the line went backwards")
			#expect(showing - last <= 1, "two characters landed on one step")
			last = showing
		}
		#expect(last == words.count)
		#expect(typed.shown(of: words, at: 0) == 0)
		#expect(typed.shown(of: words, at: 1) == words.count)
	}

	/// No key ever said how far it had got, so it has not been told — and a
	/// line that has not been told is a line, whole. This is what makes
	/// `typed:` safe to add to something already on screen.
	@Test func aLineNeverToldHowFarItHasGotIsWhole() {
		#expect(Scene.Typing().shown(of: words, at: nil) == words.count)
	}

	// MARK: - When

	/// Undoing an ease is the ease undone, for each of the four.
	@Test func aneaseIsUndoneExactly() {
		for ease in Scene.Ease.allCases {
			for step in 0...100 {
				let fraction = Double(step) / 100
				let there = Scene.eased(ease, fraction)
				#expect(abs(Scene.uneased(ease, there) - fraction) < 1e-9,
				        "\(ease) does not invert at \(fraction)")
			}
		}
	}

	/// One moment per character, in order, each one character further on.
	@Test func everyCharacterHasAMomentItLandsOn() {
		let typed = Scene.Typing(steady: 0.5)
		let part = scene(typed).parts[0]
		let moments = typed.moments(of: words, keys: part.keys)
		#expect(moments.count == words.count + 1, "not one moment per character")
		#expect(moments.first?.shown == 0)
		#expect(moments.last?.shown == words.count)
		for (before, after) in zip(moments, moments.dropFirst()) {
			#expect(after.t > before.t)
			#expect(after.shown == before.shown + 1)
		}
	}

	/// The moment the layer path steps is the moment the painter's count flips.
	/// Two render paths that disagree by a frame is the class of bug that
	/// makes an export not look like the preview.
	@Test func bothPathsAgreeOnWhenACharacterLands() {
		let typed = Scene.Typing(steady: 0.35)
		let keys = scene(typed).parts[0].keys
		for moment in typed.moments(of: words, keys: keys) {
			let progress = Scene.state(of: Scene.filled(keys), at: moment.t)?.progress
			#expect(typed.shown(of: words, at: progress) == moment.shown,
			        "at \(moment.t) the painter says something else")
		}
	}

	// MARK: - The caret

	/// Still while the characters land, blinking either side of it.
	@Test func theCaretIsStillWhileItIsTypingAndBlinksAfter() {
		let typed = Scene.Typing(steady: 1, caret: .white, blink: 1)
		let keys = scene(typed, over: 1.4).parts[0].keys
		// Typing runs from the first character to the last.
		let (began, ended) = typed.span(of: words, keys: keys)
		let start = try! #require(began)
		let stop = try! #require(ended)
		for step in 0...20 {
			let moment = start + (stop - start) * Double(step) / 20
			#expect(typed.lit(at: moment, of: words, keys: keys), "it blinked mid-word")
		}
		// And after: lit on the frame the last character lands, out half a
		// cycle later, back again a cycle on.
		#expect(typed.lit(at: stop, of: words, keys: keys))
		#expect(!typed.lit(at: stop + 0.6, of: words, keys: keys))
		#expect(typed.lit(at: stop + 1.05, of: words, keys: keys))
	}

	/// A line with no caret asked for has none, whatever the blink says.
	@Test func aLineWithNoCaretHasNoCaret() {
		let typed = Scene.Typing(steady: 1, caret: nil, blink: 1)
		#expect(!typed.lit(at: 0, of: words, keys: scene(typed).parts[0].keys))
	}

	// MARK: - The export path

	private func resolved(_ project: Project, over span: Double) -> ResolvedProject {
		ResolvedProject(
			project: project, baseURL: URL(fileURLWithPath: "."), clips: [],
			overlays: [ResolvedOverlay(
				overlay: Overlay(kind: .scene("s", with: [:]), span: .times(from: 0, to: span),
				                 arrival: .cut, departure: .cut),
				origin: .project(0), appearance: 0, start: 0, end: span, path: nil)],
			groups: [], anchors: [])
	}

	private func layers(in layer: CALayer) -> [CALayer] {
		[layer] + (layer.sublayers ?? []).flatMap { layers(in: $0) }
			+ (layer.mask.map { layers(in: $0) } ?? [])
	}

	/// **The same defect, on the other render path.** The export does not go
	/// through the painter: it builds a layer tree and hands it to Core
	/// Animation. A reveal animated `.linear` there would interpolate the mask
	/// between two letters and cut a glyph exactly as a hand-keyed rectangle
	/// did, so what is asserted is the calculation mode itself.
	@Test func theExportStepsTheRevealRatherThanSlidingIt() throws {
		let typed = Scene.Typing(steady: 1, caret: .white)
		let tree = OverlayLayers.build(
			resolved(Project(styles: ["typewriter": project().styles["typewriter"]!],
			                 scenes: ["s": scene(typed, over: 1.4)]),
			         over: 1.4),
			size: size, host: .export)

		let stepped = layers(in: tree).compactMap {
			$0.animation(forKey: "bounds") as? CAKeyframeAnimation
		}
		let reveal = try #require(stepped.first, "the reveal is not animated at all")
		#expect(reveal.calculationMode == .discrete, "the reveal slides between letters")
		// One more key time than values: a discrete animation is a list of
		// intervals, and written one-to-one it is ignored outright. The same
		// rule `framesLayer` is held to.
		#expect(reveal.keyTimes?.count == (reveal.values?.count ?? 0) + 1)
		#expect(reveal.keyTimes?.first == 0)
		#expect(reveal.keyTimes?.last == 1)

		// The widths only grow, and there is one for each letter.
		let widths = try #require(reveal.values as? [NSValue]).map(\.rectValue.width)
		#expect(widths == widths.sorted(), "the reveal goes backwards")
		#expect(Set(widths).count == words.count + 1,
		        "\(Set(widths).count) widths for \(words.count) letters")
	}

	/// The caret is stepped too, and it is not inside the mask — a caret under
	/// the reveal is a caret that is never drawn, because it stands exactly
	/// where the reveal has not reached.
	@Test func theExportsCaretStepsAndIsNotMasked() throws {
		let typed = Scene.Typing(steady: 1, caret: .white, blink: 1)
		// Typed out in the first second and a half of a four-second card, so
		// there is time on the end for the caret to be caught blinking.
		let tree = OverlayLayers.build(
			resolved(Project(styles: ["typewriter": project().styles["typewriter"]!],
			                 scenes: ["s": scene(typed, over: 1.4)]),
			         over: 4),
			size: size, host: .export)

		// The words are the layer wearing the reveal as a mask; the caret is
		// what is beside them in the holder, which is the whole point of there
		// being a holder.
		let plate = try #require(layers(in: tree).first { $0.mask != nil }, "nothing is revealed")
		let holder = try #require(plate.superlayer, "the words have no holder")
		#expect(holder.mask == nil, "the holder is masked, so the caret is masked with it")
		let caret = try #require((holder.sublayers ?? []).first { $0 !== plate },
		                         "there is no caret beside the words")

		let walk = try #require(caret.animation(forKey: "position") as? CAKeyframeAnimation)
		#expect(walk.calculationMode == .discrete, "the caret slides across the letters")
		let xs = try #require(walk.values as? [NSValue]).map(\.pointValue.x)
		#expect(xs == xs.sorted(), "the caret goes backwards")
		#expect(Set(xs).count == words.count + 1,
		        "\(Set(xs).count) caret places for \(words.count) letters")

		// And it blinks, on the same list of moments, held rather than faded.
		let blink = try #require(caret.animation(forKey: "opacity") as? CAKeyframeAnimation)
		#expect(blink.calculationMode == .discrete, "the caret fades instead of blinking")
		#expect(Set(try #require(blink.values as? [Double])) == [0, 1])
	}

	// MARK: - In the file

	private func read(_ typed: String) throws -> Scene.Typing? {
		let text = """
		cuttr-project: 1

		output:
		  size: 1920x1080
		  fps:  25
		  file: out.mov

		scenes:
		  card:
		    parts:
		      - text:  dingsda
		        style: typewriter
		        \(typed)
		        keys:
		          - {t: 0, x: 0.5, y: 0.5, opacity: 1, progress: 0}
		          - {t: 2, progress: 1, ease: linear}
		"""
		let project = try ProjectReader.read(text)
		guard case .text(_, _, _, let typed) = try #require(project.scenes["card"]?.parts.first)
			.content else { return nil }
		return typed
	}

	/// The short form is the whole of it for most lines.
	@Test func theBareWordIsAPlainMachine() throws {
		let typed = try #require(try read("typed: true"))
		#expect(typed.steady == 1)
		#expect(typed.caret == nil)
	}

	/// And `false` says so, rather than the line having to be rewritten.
	@Test func turningItOffIsOneWord() throws {
		#expect(try read("typed: false") == nil)
	}

	@Test func theMappingFormSaysWhatItChanges() throws {
		let typed = try #require(try read(##"typed: {steady: 0.55, caret: "#4bd5ee", blink: 0.8}"##))
		#expect(typed.steady == 0.55)
		#expect(typed.caret == RGBA(hex: "#4bd5ee"))
		#expect(typed.blink == 0.8)
	}

	/// Written back as it was written down. A file that said `typed: true` and
	/// came back out as a mapping of the defaults it already had would churn
	/// every time somebody opened it.
	@Test func typingRoundTripsThroughTheFile() throws {
		for said in ["typed: true", ##"typed: {steady: 0.55, caret: "#4bd5ee"}"##] {
			let once = try #require(try read(said))
			var project = Project()
			project.scenes["card"] = Scene(parts: [
				.init(content: .text("dingsda", style: "typewriter", tracking: 0, typed: once),
				      keys: [.init(t: 0, progress: 0), .init(t: 2, progress: 1)]),
			])
			let back = try ProjectReader.read(ProjectWriter.write(project))
			#expect(back == project, "\(said) did not survive being written")
			#expect(ProjectWriter.write(project).contains(said),
			        "\(said) was not written the way it was said")
		}
	}

	/// A colour that is not one is an error rather than a silent black caret.
	@Test func aCaretThatIsNotAColourIsRefused() {
		#expect(throws: (any Error).self) { try read("typed: {caret: \"lilac\"}") }
	}

	// MARK: - On the pixels

	/// The rightmost column with any ink in it, or nil for an empty picture.
	private func inkReaches(_ scene: Scene, at time: Double) throws -> Int? {
		let image = try #require(OverlayPainter.sceneImage(
			scene, with: [:], project: project(), baseURL: URL(fileURLWithPath: "."),
			size: size, at: time))
		let width = Int(size.width), height = Int(size.height)
		var bytes = [UInt8](repeating: 0, count: width * height * 4)
		context.render(CIImage(cgImage: image), toBitmap: &bytes, rowBytes: width * 4,
		               bounds: CGRect(origin: .zero, size: size), format: .RGBA8,
		               colorSpace: nil)
		var reach: Int?
		for y in 0..<height {
			for x in 0..<width where bytes[(y * width + x) * 4 + 3] > 40 {
				reach = max(reach ?? 0, x)
			}
		}
		return reach
	}

	/// **The bug, on the pixels.** Rendered at every frame of a second and a
	/// half at 25 fps, the ink stops at one of only a handful of places.
	///
	/// This is the whole defect stated as a number. A reveal that *slides* —
	/// a rectangle on its own keys, which is how this was done before — stops
	/// somewhere different on nearly every frame, because on the frames between
	/// two letters its edge is inside a glyph. A reveal that *steps* can only
	/// ever stop where a character ends, so seven letters over thirty-eight
	/// frames give at most eight distinct edges and not thirty-eight.
	///
	/// Measured on the drawn pixels rather than on the numbers that drew them,
	/// because a half-covered letter is the one thing that does not show up in
	/// the arithmetic — it is exactly where the arithmetic was right and the
	/// sampling was not.
	@Test func theRevealOnlyEverStopsAtALetterBoundary() throws {
		let scene = scene(Scene.Typing(steady: 1), over: 1.4)
		var edges: [Int] = []
		for frame in 0...37 {
			guard let reach = try inkReaches(scene, at: Double(frame) / 25) else { continue }
			edges.append(reach)
		}
		let distinct = Set(edges)
		#expect(distinct.count <= words.count + 1,
		        "the ink stopped in \(distinct.count) places for \(words.count) letters, so it slides")
		// And it did type, rather than standing still for the whole second.
		#expect(distinct.count >= 5, "the line did not type: \(distinct.sorted())")
		// Forwards only — a reveal that went back would be a letter unwritten.
		#expect(edges == edges.sorted(), "the reveal went backwards: \(edges)")
	}

	/// Half typed is the left half inked and the right half empty — the reveal
	/// is a reveal and not a fade.
	@Test func whatIsNotTypedYetIsNotThereAtAll() throws {
		let scene = scene(Scene.Typing(steady: 1), over: 1.4)
		let cell = 36 * 0.60205
		let left = 320 - cell * 7 / 2
		let reach = try #require(try inkReaches(scene, at: 0.7))
		#expect(Double(reach) > left, "nothing was drawn")
		#expect(Double(reach) < left + cell * 5, "more than half the line is showing")
	}
}
