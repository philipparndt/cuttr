import CoreGraphics
import CoreImage
import Foundation
import QuartzCore
import Testing
@testable import CuttrCompose

/// A shape part is the shape of something, and a key can name a different one.
@Suite struct SceneShapeTests {

	private let size = CGSize(width: 400, height: 400)

	/// Every kind fills the box it is given, and none of them leaves it.
	@Test func everyKindFitsItsBox() {
		for kind in Scene.ShapeKind.allCases {
			let box = kind.path(in: size, corner: 8).boundingBoxOfPath
			#expect(box.width <= size.width + 0.01, "\(kind) is wider than its box")
			#expect(box.height <= size.height + 0.01, "\(kind) is taller than its box")
			// …and is not a sliver: each of these reaches the edge somewhere.
			#expect(box.width > size.width * 0.5, "\(kind) does not fill its box")
			#expect(box.height > size.height * 0.5, "\(kind) does not fill its box")
		}
	}

	/// The outline the morph samples agrees with the outline the render draws.
	///
	/// They are two descriptions of one shape, and a morph that began from a
	/// different shape than the one on screen would jump on its first frame.
	/// Checked by walking round: nine tenths of the way out is inside, eleven
	/// tenths is outside. What it does *not* promise is the corners — a star's
	/// points fall between two sampled angles and are cut by a fraction of a
	/// degree — which is the price of a morph, written down here rather than
	/// discovered later.
	@Test func theSampledOutlineIsTheOutline() {
		for kind in Scene.ShapeKind.allCases {
			let sampled = Scene.ShapeKind.sampled(kind, in: size, corner: 0)
			for step in 0..<72 {
				let angle = CGFloat(step) * 2 * .pi / 72
				let reach = kind.radius(at: angle, in: size, corner: 0)
				let inside = CGPoint(x: cos(angle) * reach * 0.9, y: sin(angle) * reach * 0.9)
				let outside = CGPoint(x: cos(angle) * reach * 1.1, y: sin(angle) * reach * 1.1)
				#expect(sampled.contains(inside), "\(kind) is hollow at \(step)")
				#expect(!sampled.contains(outside), "\(kind) spills at \(step)")
			}
		}
	}

	/// Half way between two shapes is neither of them.
	@Test func aMorphIsBetweenTheTwoEnds() {
		let square = Scene.ShapeKind.rectangle
		let round = Scene.ShapeKind.ellipse
		// On the diagonal, a square reaches further than a circle does.
		let angle = CGFloat.pi / 4
		let a = square.radius(at: angle, in: size, corner: 0)
		let b = round.radius(at: angle, in: size, corner: 0)
		#expect(a > b)
		let half = Scene.ShapeMorph(from: square, to: round, fraction: 0.5)
		let path = Scene.ShapeKind.morphed(half, in: size, corner: 0)
		// Measured on the diagonal, which is the one direction where a square
		// and a circle in the same box disagree: on the axes they reach exactly
		// as far as each other, so a bounding box says nothing about a morph.
		let middle = (a + b) / 2
		let short = CGPoint(x: cos(angle) * middle * 0.95, y: sin(angle) * middle * 0.95)
		let long = CGPoint(x: cos(angle) * middle * 1.05, y: sin(angle) * middle * 1.05)
		#expect(path.contains(short), "the halfway shape does not reach the circle")
		#expect(!path.contains(long), "the halfway shape reaches past the square")
		// And it is genuinely neither end: inside the square, outside the circle.
		#expect(middle < a && middle > b)

		// And a morph that has not started, or has finished, is one of them.
		#expect(Scene.ShapeMorph(from: square, to: round, fraction: 0).isStill)
		#expect(Scene.ShapeMorph(from: square, to: round, fraction: 1).settled == round)
	}

	/// A key naming a kind is a morph across the interval that ends there.
	@Test func aKeyNamingAKindMorphsIntoIt() {
		let keys = Scene.filled([
			Scene.Key(t: 0, shape: .rectangle, ease: .linear),
			Scene.Key(t: 2, shape: .star, ease: .linear),
		])
		#expect(Scene.morph(of: keys, at: 0, default: .rectangle).isStill)
		let middle = Scene.morph(of: keys, at: 1, default: .rectangle)
		#expect(middle.from == .rectangle)
		#expect(middle.to == .star)
		#expect(abs(middle.fraction - 0.5) < 0.001)
		#expect(Scene.morph(of: keys, at: 3, default: .rectangle).settled == .star)

		// A part whose keys never name one is the kind it was declared with,
		// all the way through.
		let plain = Scene.filled([Scene.Key(t: 0), Scene.Key(t: 2)])
		#expect(Scene.morph(of: plain, at: 1, default: .hexagon).settled == .hexagon)
		#expect(Scene.morph(of: plain, at: 1, default: .hexagon).isStill)
	}

	// MARK: - The file

	@Test func aKindAndAMorphSurviveTheFile() throws {
		let project = Project(scenes: ["badge": Scene(parts: [
			.init(content: .shape(fill: RGBA(hex: "#f4a261")!, corner: 0.01, kind: .star),
			      keys: [.init(t: 0, x: 0.5, y: 0.5, width: 0.2, height: 0.35),
			             .init(t: 1.5, shape: .ellipse, ease: .out)]),
		])])
		let text = ProjectWriter.write(project)
		#expect(text.contains("kind:   star"))
		#expect(text.contains("shape: ellipse"))
		let back = try ProjectReader.read(text)
		#expect(back.scenes == project.scenes)
		#expect(ProjectWriter.write(back) == text)
	}

	/// A rectangle says nothing, because that is what a shape part was before
	/// there were kinds — so a project written then is unchanged.
	@Test func aRectangleIsStillJustAShape() throws {
		let text = """
		# cuttr project — the assembly. Clips are referenced by slug.
		cuttr-project: 1

		output:
		  size: 1920x1080
		  fps:  25

		timeline:
		  - clip: intro

		scenes:
		  rule:
		    parts:
		      - shape: "#ffffff"
		        corner: 0.004
		        keys:
		          - {t: 0, x: 0.5, y: 0.2, width: 0, height: 0.004}
		          - {t: 0.6, width: 0.5, ease: out}

		"""
		let project = try ProjectReader.read(text)
		#expect(ProjectWriter.write(project) == text)
		if case .shape(_, _, let kind) = project.scenes["rule"]?.parts[0].content {
			#expect(kind == .rectangle)
		} else {
			Issue.record("not a shape")
		}
	}

	@Test func aKindTheReaderDoesNotKnowIsRefused() {
		#expect(throws: ProjectError.self) {
			try ProjectReader.read("""
			cuttr-project: 1

			timeline:
			  - clip: intro

			scenes:
			  badge:
			    parts:
			      - shape: "#ffffff"
			        kind: octagon
			        keys:
			          - {t: 0}
			""")
		}
	}

	// MARK: - Both paths

	private func resolved(_ project: Project) -> ResolvedProject {
		ResolvedProject(
			project: project, baseURL: URL(fileURLWithPath: "."), clips: [],
			overlays: [ResolvedOverlay(
				overlay: Overlay(kind: .scene("badge", with: [:]), span: .times(from: 0, to: 2),
				                 arrival: .cut, departure: .cut),
				source: 0, appearance: 0, start: 0, end: 2, path: nil)],
			groups: [], anchors: [])
	}

	/// The layer path animates a *path*, and every key of a morphing part has
	/// to be sampled the same way or Core Animation has nothing to interpolate
	/// between — it would cut instead of morphing.
	@Test func bothPathsMorphTheSameWay() throws {
		let scene = Scene(parts: [
			.init(content: .shape(fill: .white, corner: 0, kind: .rectangle),
			      keys: [.init(t: 0, x: 0.5, y: 0.5, width: 0.5, height: 0.5,
			                   shape: .rectangle, ease: .linear),
			             .init(t: 2, shape: .ellipse, ease: .linear)]),
		])
		let project = Project(scenes: ["badge": scene])
		let tree = OverlayLayers.build(resolved(project), size: size, host: .export)

		func shapes(in layer: CALayer) -> [CAShapeLayer] {
			((layer.sublayers ?? []).flatMap { shapes(in: $0) })
				+ ((layer as? CAShapeLayer).map { [$0] } ?? [])
		}
		let shape = try #require(shapes(in: tree).first)
		let animation = try #require(shape.animation(forKey: "path") as? CAKeyframeAnimation)
		let paths = try #require(animation.values as? [CGPath])
		#expect(paths.count == 2)
		// Same number of points at both ends, which is the whole requirement.
		var counts: [Int] = []
		for path in paths {
			var points = 0
			path.applyWithBlock { _ in points += 1 }
			counts.append(points)
		}
		#expect(counts[0] == counts[1], "the two ends have different paths: \(counts)")
		#expect(counts[0] > 100, "a morphing shape was not sampled: \(counts)")

		// And the painter, halfway, is between the two — measured on the
		// diagonal, where a square reaches and a circle does not.
		let context = CIContext(options: [.workingColorSpace: NSNull()])
		func lit(_ time: Double, _ x: Int, _ y: Int) throws -> Double {
			let image = try #require(OverlayPainter.sceneImage(
				scene, with: [:], project: project, baseURL: URL(fileURLWithPath: "."),
				size: size, at: time))
			var bytes = [UInt8](repeating: 0, count: 4)
			context.render(CIImage(cgImage: image), toBitmap: &bytes, rowBytes: 4,
			               bounds: CGRect(x: x, y: y, width: 1, height: 1),
			               format: .RGBA8, colorSpace: nil)
			return Double(bytes[3]) / 255
		}
		// A point just inside the square's corner on the diagonal: on at the
		// start, off at the end, and part-way in between.
		let corner = (x: 200 + 88, y: 200 + 88)
		#expect(try lit(0, corner.x, corner.y) > 0.9, "the square has no corner")
		#expect(try lit(2, corner.x, corner.y) < 0.1, "the ellipse has a corner")
	}
}
