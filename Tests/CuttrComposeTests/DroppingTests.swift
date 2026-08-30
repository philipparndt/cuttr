import CoreGraphics
import CoreImage
import Foundation
import QuartzCore
import Testing
@testable import CuttrCompose

/// A caption that falls in, lands, and knocks up dust.
@Suite struct DroppingTests {

	private let frame = CGSize(width: 640, height: 360)

	// MARK: - The fall

	/// Off the top at the start, home at the end, and it only ever comes down.
	@Test func itFallsFromOffTheTopAndArrivesHome() {
		let fell = 400.0
		#expect(Dropping.lift(at: 0, fell: fell, judder: 8) == fell)
		#expect(abs(Dropping.lift(at: Dropping.lands, fell: fell, judder: 8)) < 1e-9)

		var last = fell
		for step in 0...100 {
			let at = Double(step) / 100 * Dropping.lands
			let here = Dropping.lift(at: at, fell: fell, judder: 8)
			#expect(here <= last + 1e-9, "the caption went back up at \(at)")
			last = here
		}
	}

	/// It accelerates. Half way through the fall it has come less than half of
	/// the way down — which is the difference between a drop and a lift being
	/// lowered, and the whole reason this is not an ease.
	@Test func itAcceleratesRatherThanEasing() {
		let fell = 400.0
		let half = Dropping.lift(at: Dropping.lands / 2, fell: fell, judder: 0)
		#expect(half > fell * 0.7, "half way through the fall it is already most of the way down")
	}

	/// After landing it rattles: above home, never below it, and settling.
	@Test func itRattlesAndSettles() {
		let judder = 20.0
		var peaks: [Double] = []
		var previous = 0.0
		var rising = false
		for step in 0...400 {
			let at = Dropping.lands + Double(step) / 400 * (1 - Dropping.lands)
			let here = Dropping.lift(at: at, fell: 400, judder: judder)
			#expect(here >= -1e-9, "it went below what it landed on")
			#expect(here <= judder + 1e-9, "the judder is bigger than it was told to be")
			if here > previous { rising = true } else if rising { peaks.append(previous); rising = false }
			previous = here
		}
		#expect(peaks.count >= 2, "it does not bounce, it stops dead")
		#expect(peaks[1] < peaks[0], "the second bounce is not smaller than the first")
		// And it has finished by the end of the arrival.
		#expect(Dropping.lift(at: 1, fell: 400, judder: judder) < judder * 0.02)
	}

	// MARK: - The dust

	private var foot: CGRect { CGRect(x: 200, y: 100, width: 240, height: 40) }

	/// Nothing before it lands, a cloud after, nothing once it has settled.
	@Test func theDustIsThrownAndThenIsGone() {
		let dust = Dust(amount: 1)
		#expect(dust.puffs(0, foot: foot, frame: frame, seed: 7).isEmpty,
		        "there is dust on the frame it lands")
		#expect(!dust.puffs(0.25, foot: foot, frame: frame, seed: 7).isEmpty,
		        "nothing was thrown")
		#expect(dust.puffs(Dust.settles, foot: foot, frame: frame, seed: 7).isEmpty,
		        "the dust never settles")
	}

	/// It spreads sideways along the foot of the words, both ways, and it grows
	/// and thins as it goes.
	@Test func itSpreadsAlongTheFootAndThins() {
		let dust = Dust(amount: 1)
		let early = dust.puffs(0.15, foot: foot, frame: frame, seed: 7)
		let later = dust.puffs(0.5, foot: foot, frame: frame, seed: 7)
		#expect(!early.isEmpty && !later.isEmpty)

		func width(_ puffs: [Dust.Puff]) -> Double {
			let xs = puffs.map(\.centre.x)
			return Double((xs.max() ?? 0) - (xs.min() ?? 0))
		}
		#expect(width(later) > width(early), "the cloud does not spread")
		#expect(width(later) > foot.width * 0.6, "the cloud is narrower than the words")
		// Both sides of the middle, or it is a puff rather than a cloud.
		let middle = foot.midX
		#expect(later.contains { $0.centre.x < middle } && later.contains { $0.centre.x > middle })

		let averageRadius = { (p: [Dust.Puff]) in p.map(\.radius).reduce(0, +) / Double(p.count) }
		#expect(averageRadius(later) > averageRadius(early), "the puffs do not grow")
	}

	/// The same landing throws the same cloud, every render; two different
	/// captions do not throw the same one.
	@Test func theSameLandingThrowsTheSameCloud() {
		let dust = Dust(amount: 1)
		let once = dust.puffs(0.3, foot: foot, frame: frame, seed: 7)
		let again = dust.puffs(0.3, foot: foot, frame: frame, seed: 7)
		#expect(once == again)
		#expect(once != dust.puffs(0.3, foot: foot, frame: frame, seed: 8))
		#expect(Dropping.seed(from: "Wie sieht Oma aus?") != Dropping.seed(from: "Wie sieht Opa aus?"))
	}

	/// `dust: 0` is a landing with no cloud at all.
	@Test func noDustMeansNoDust() {
		#expect(Dust(amount: 0).count == 0)
		#expect(Dust(amount: 0).puffs(0.3, foot: foot, frame: frame, seed: 7).isEmpty)
	}

	// MARK: - In the file

	private func read(_ said: String, key: String = "in") throws -> Overlay.Transition {
		let text = """
		cuttr-project: 1

		output:
		  size: 1920x1080
		  fps:  25
		  file: out.mov

		overlays:
		  - text:  Wie sieht Oma aus?
		    from:  00:01.000
		    to:    00:05.000
		    \(key):    \(said)
		"""
		let project = try ProjectReader.read(text)
		let overlay = try #require(project.overlays.first)
		return key == "in" ? overlay.arrival : overlay.departure
	}

	@Test func theBareWordIsADrop() throws {
		guard case .drop(let over, let dust) = try read("drop") else {
			Issue.record("not a drop"); return
		}
		#expect(over == 0.7)
		#expect(dust == 1)
	}

	@Test func theMappingFormSaysHowLongAndHowMuch() throws {
		guard case .drop(let over, let dust) = try read("{drop: true, over: 0.9, dust: 2}") else {
			Issue.record("not a drop"); return
		}
		#expect(over == 0.9)
		#expect(dust == 2)
	}

	/// A drop is how something arrives. Refused on the other end rather than
	/// quietly read as a slide off the top.
	@Test func aDropIsRefusedAsADeparture() {
		#expect(throws: (any Error).self) { try read("drop", key: "out") }
		#expect(throws: (any Error).self) { try read("{drop: true, over: 0.7}", key: "out") }
	}

	@Test func aDropRoundTripsThroughTheFile() throws {
		for said in ["{drop: true, over: 0.7}", "{drop: true, over: 0.9, dust: 2}"] {
			let read = try read(said)
			let project = Project(
				output: Output(width: 1920, height: 1080, framesPerSecond: 25, file: "out.mov"),
				overlays: [Overlay(kind: .text("Wie sieht Oma aus?", style: nil),
				                   span: .times(from: 1, to: 5),
				                   arrival: read, departure: .cut)])
			let written = ProjectWriter.write(project)
			#expect(written.contains(said), "\(said) was not written the way it was said")
			#expect(try ProjectReader.read(written) == project, "\(said) did not survive")
		}
	}

	// MARK: - Both render paths

	private func project() -> Project {
		var project = Project(
			output: Output(width: 640, height: 360, framesPerSecond: 25, file: "out.mov"),
			overlays: [Overlay(kind: .text("Wie sieht Oma aus?", style: "caption"),
			                   span: .times(from: 1, to: 5),
			                   arrival: .drop(over: 0.8, dust: 1), departure: .cut)])
		project.styles["caption"] = TextStyle(
			font: "Helvetica Neue Bold", size: 0.09, color: .white,
			background: RGBA(r: 0, g: 0, b: 0, a: 0), padding: 0.01,
			cornerRadius: 0, position: CGPoint(x: 0.5, y: 0.5), alignment: .centre)
		return project
	}

	/// Built by hand rather than resolved, because what is being measured is
	/// the arrival and not the timeline: a project with one overlay and no
	/// clips has nothing to lay it on.
	private func shown() -> ResolvedOverlay {
		ResolvedOverlay(
			overlay: project().overlays[0], origin: .project(0), appearance: 0,
			start: 1, end: 5, path: nil)
	}

	private func resolved() -> ResolvedProject {
		ResolvedProject(project: project(), baseURL: URL(fileURLWithPath: "."),
		                clips: [], overlays: [shown()], groups: [], anchors: [])
	}

	/// The painter puts the words off the top at the start and home once the
	/// arrival is over.
	@Test func thePainterDropsTheWordsIn() throws {
		let shown = shown()
		let context = CIContext(options: [.workingColorSpace: NSNull()])

		/// The lowest row with any ink in it, or nil for an empty frame.
		func lowest(at time: Double) throws -> Int? {
			guard let drawn = OverlayPainter.image(
				for: shown, project: project(), baseURL: URL(fileURLWithPath: "."),
				size: frame, at: time) else { return nil }
			let w = Int(frame.width), h = Int(frame.height)
			var bytes = [UInt8](repeating: 0, count: w * h * 4)
			context.render(drawn, toBitmap: &bytes, rowBytes: w * 4,
			               bounds: CGRect(origin: .zero, size: frame),
			               format: .RGBA8, colorSpace: nil)
			var found: Int?
			for y in 0..<h {
				for x in 0..<w where bytes[(y * w + x) * 4 + 3] > 60 {
					found = min(found ?? h, y); break
				}
			}
			return found
		}

		// It comes down: the ink is higher in the frame early than late. The
		// bitmap's origin is at the bottom, so "lower in the frame" is a
		// smaller row number.
		let early = try lowest(at: 1.1)
		let landed = try #require(try lowest(at: 1.6), "nothing is on screen once it has landed")
		if let early { #expect(early > landed, "it did not come down") }
	}

	/// **The dust is drawn, and only around the landing.**
	///
	/// Measured as the spread of the ink rather than as ink in a named corner
	/// of the frame: a cloud thrown along the foot of the words reaches well
	/// past both ends of them, so the drawn thing is *wider* in the second
	/// after it lands than the words are, and back to the width of the words
	/// once it has settled. Which is true whichever way up the buffer is.
	@Test func thePainterDrawsDustWhenItLands() throws {
		let shown = shown()
		let context = CIContext(options: [.workingColorSpace: NSNull()])

		/// How wide the drawn ink is, in pixels.
		func spread(at time: Double) throws -> Int {
			guard let drawn = OverlayPainter.image(
				for: shown, project: project(), baseURL: URL(fileURLWithPath: "."),
				size: frame, at: time) else { return 0 }
			let w = Int(frame.width), h = Int(frame.height)
			var bytes = [UInt8](repeating: 0, count: w * h * 4)
			context.render(drawn, toBitmap: &bytes, rowBytes: w * 4,
			               bounds: CGRect(origin: .zero, size: frame),
			               format: .RGBA8, colorSpace: nil)
			var least = w, most = -1
			for y in 0..<h {
				for x in 0..<w where bytes[(y * w + x) * 4 + 3] > 10 {
					least = min(least, x)
					most = max(most, x)
				}
			}
			return most < least ? 0 : most - least + 1
		}

		let landed = 1 + 0.8 * Dropping.lands
		// Long settled: the words, and nothing else. The measuring stick.
		let words = try spread(at: landed + Dust.settles + 0.1)
		#expect(words > 40, "the words are not on screen at all")

		// Landed: the cloud reaches past both ends of them.
		let cloud = try spread(at: landed + 0.3)
		#expect(cloud > Int(Double(words) * 1.25),
		        "the ink is \(cloud) wide where the words are \(words) — no dust was thrown")

		// And the frame before it lands there is none of it. Late enough in the
		// fall that the words are down off the top and on screen to be measured.
		let before = try spread(at: landed - 0.06)
		#expect(before <= words + 4, "there is dust before it lands: \(before) wide")
	}

	/// The export path drops and dusts too, and the dust is not carried by the
	/// movement that is doing the rattling.
	@Test func theExportDropsAndDusts() throws {
		let tree = OverlayLayers.build(resolved(), size: frame, host: .export)

		func layers(in layer: CALayer) -> [CALayer] {
			[layer] + (layer.sublayers ?? []).flatMap { layers(in: $0) }
		}
		let all = layers(in: tree)

		// The fall, sampled rather than eased: many values, and coming down.
		let travelling = try #require(all.compactMap {
			$0.animation(forKey: "slide") as? CAKeyframeAnimation
		}.first, "nothing moves")
		let ys = try #require(travelling.values as? [NSValue]).map(\.pointValue.y)
		#expect(ys.count > 20, "the fall is eased between two values rather than sampled")
		#expect(ys.first ?? 0 > frame.height, "it does not start off the top")
		#expect(abs(ys.last ?? 99) < 1, "it does not finish home")

		// The dust: a layer per puff, each with the soft disc on it.
		let puffs = all.filter { $0.contents != nil && $0.animation(forKey: "bounds") != nil }
		#expect(puffs.count >= 20, "only \(puffs.count) puffs of dust")

		// Not under the layer that is moving, or the cloud would rattle with
		// the words instead of lying on the floor.
		for puff in puffs {
			var walker = puff.superlayer
			var carried = false
			while let here = walker {
				if here.animation(forKey: "slide") != nil { carried = true }
				walker = here.superlayer
			}
			#expect(!carried, "the dust is carried by the movement")
		}
	}
}
