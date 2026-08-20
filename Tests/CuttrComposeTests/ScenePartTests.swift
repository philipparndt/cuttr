import CoreGraphics
import CoreImage
import Foundation
import QuartzCore
import Testing
@testable import CuttrCompose

/// Parts that are things rather than shapes: a bar that fills, a spinner that
/// goes round or says how far it has got.
@Suite struct ScenePartTests {

	private let size = CGSize(width: 400, height: 200)
	private let context = CIContext(options: [.workingColorSpace: NSNull()])

	private func bar(_ direction: Scene.Bar.Direction = .right) -> Scene {
		Scene(parts: [
			.init(content: .bar(Scene.Bar(fill: .white,
			                              track: RGBA(r: 1, g: 1, b: 1, a: 0.2),
			                              corner: 0, direction: direction)),
			      keys: [.init(t: 0, x: 0.5, y: 0.5, opacity: 1,
			                   width: 0.8, height: 0.2, progress: 0, ease: .linear),
			             .init(t: 3, progress: 1, ease: .linear)]),
		])
	}

	/// A bar a third of the way through is a third full.
	@Test func aBarFillsWithTheEasingItsKeysCarry() {
		let keys = Scene.filled(bar().parts[0].keys)
		#expect(Scene.state(of: keys, at: 0)?.progress == 0)
		#expect(abs((Scene.state(of: keys, at: 1)?.progress ?? 0) - 1.0 / 3) < 0.001)
		#expect(Scene.state(of: keys, at: 3)?.progress == 1)
		// And past the end it stays full rather than starting again.
		#expect(Scene.state(of: keys, at: 9)?.progress == 1)
	}

	/// The groove and the fill, in the frame, for each direction.
	@Test func aBarFillsFromTheEndItIsToldTo() {
		let box = CGRect(x: -100, y: -10, width: 200, height: 20)
		let half = 0.5
		#expect(Scene.Bar(direction: .right).rects(in: box, progress: half).fill
			== CGRect(x: -100, y: -10, width: 100, height: 20))
		#expect(Scene.Bar(direction: .left).rects(in: box, progress: half).fill
			== CGRect(x: 0, y: -10, width: 100, height: 20))
		#expect(Scene.Bar(direction: .up).rects(in: box, progress: half).fill
			== CGRect(x: -100, y: -10, width: 200, height: 10))
		#expect(Scene.Bar(direction: .down).rects(in: box, progress: half).fill
			== CGRect(x: -100, y: 0, width: 200, height: 10))
		// The groove is the whole of it whatever the fill is doing.
		#expect(Scene.Bar().rects(in: box, progress: 0.1).track == box)
	}

	private func alpha(_ scene: Scene, at time: Double, x: Int, y: Int) throws -> Double {
		let image = try #require(OverlayPainter.sceneImage(
			scene, with: [:], project: Project(), baseURL: URL(fileURLWithPath: "."),
			size: size, at: time))
		var bytes = [UInt8](repeating: 0, count: 4)
		context.render(CIImage(cgImage: image), toBitmap: &bytes, rowBytes: 4,
		               bounds: CGRect(x: x, y: y, width: 1, height: 1),
		               format: .RGBA8, colorSpace: nil)
		return Double(bytes[0]) / 255
	}

	/// Measured on the pixels: a third of the way along, the left third of the
	/// bar is bright and the right two thirds are the groove.
	@Test func theBarThatIsDrawnIsTheBarThatIsFull() throws {
		let scene = bar()
		// The bar spans 0.8 of 400 = 320 wide, centred: x from 40 to 360.
		#expect(try alpha(scene, at: 1, x: 60, y: 100) > 0.9, "the filled end is not full")
		#expect(try alpha(scene, at: 1, x: 140, y: 100) > 0.9, "a third along is not filled")
		#expect(try alpha(scene, at: 1, x: 160, y: 100) < 0.35, "past a third is filled")
		#expect(try alpha(scene, at: 1, x: 340, y: 100) < 0.35, "the far end is filled")
		// Full at the end, empty at the start.
		#expect(try alpha(scene, at: 3, x: 340, y: 100) > 0.9)
		#expect(try alpha(scene, at: 0, x: 60, y: 100) < 0.35)
	}

	// MARK: - Both paths

	private func resolved(_ project: Project) -> ResolvedProject {
		ResolvedProject(
			project: project, baseURL: URL(fileURLWithPath: "."), clips: [],
			overlays: [ResolvedOverlay(
				overlay: Overlay(kind: .scene("s", with: [:]), span: .times(from: 0, to: 3),
				                 arrival: .cut, departure: .cut),
				origin: .project(0), appearance: 0, start: 0, end: 3, path: nil)],
			groups: [], anchors: [])
	}

	private func shapes(in layer: CALayer) -> [CAShapeLayer] {
		((layer.sublayers ?? []).flatMap { shapes(in: $0) })
			+ ((layer as? CAShapeLayer).map { [$0] } ?? [])
	}

	/// The layer path fills the bar by animating the filled part's own path, so
	/// the two ends have to be paths of the same shape — and the one at the
	/// start has to be the empty one.
	@Test func theLayerPathFillsTheSameBar() throws {
		let tree = OverlayLayers.build(resolved(Project(scenes: ["s": bar()])),
		                               size: size, host: .export)
		let animated = shapes(in: tree).compactMap { layer in
			(layer.animation(forKey: "path") as? CAKeyframeAnimation)
				.flatMap { $0.values as? [CGPath] }
		}
		// Two: the groove, which never changes, and the fill, which does.
		#expect(animated.count == 2)
		let widths = animated.map { $0.map(\.boundingBoxOfPath.width) }
		let fill = try #require(widths.first { $0[0] < $0[1] })
		#expect(fill[0] < 1, "the bar does not start empty")
		#expect(abs(fill[1] - size.width * 0.8) < 1, "the bar does not end full")
	}

	/// A spinner with `progress` on a key is a ring that fills to it, and the
	/// layer path fills it with `strokeEnd` — the same arc the painter strokes.
	@Test func aDeterminateSpinnerFillsItsRing() throws {
		let scene = Scene(parts: [
			.init(content: .spinner(Spinner(style: .ring, size: 0.5, color: .white)),
			      keys: [.init(t: 0, x: 0.5, y: 0.5, opacity: 1, progress: 0, ease: .linear),
			             .init(t: 3, progress: 1, ease: .linear)]),
		])
		let tree = OverlayLayers.build(resolved(Project(scenes: ["s": scene])),
		                               size: size, host: .export)
		let sweeping = shapes(in: tree).compactMap {
			$0.animation(forKey: "strokeEnd") as? CAKeyframeAnimation
		}
		#expect(sweeping.count == 1)
		#expect(sweeping.first?.values as? [Double] == [0, 1])

		// And the painter draws an arc that grows: the top of the ring is lit
		// from the start, the left of it only later. Twelve o'clock, clockwise.
		// The ring is half the frame height across, inset by an eighth of that,
		// so it sits thirty-eight pixels out from the middle.
		let top = (x: 200, y: 100 + 38)
		let left = (x: 200 - 38, y: 100)
		#expect(try alpha(scene, at: 0.2, x: top.x, y: top.y) > 0.5, "it does not start at the top")
		#expect(try alpha(scene, at: 0.2, x: left.x, y: left.y) < 0.35, "it is already round")
		#expect(try alpha(scene, at: 2.9, x: left.x, y: left.y) > 0.5, "it never gets round")
	}

	/// A spinner with no `progress` anywhere is the one this program already
	/// has, going round on the scene's own clock.
	@Test func anIndeterminateSpinnerIsTheOneWeAlreadyHad() throws {
		let scene = Scene(parts: [
			.init(content: .spinner(Spinner(style: .bars, size: 0.5)),
			      keys: [.init(t: 0, x: 0.5, y: 0.5, opacity: 1)]),
		])
		let tree = OverlayLayers.build(resolved(Project(scenes: ["s": scene])),
		                               size: size, host: .export)
		// A replicator is how the bars and the dots are built, and only they
		// build one — so finding it is finding the shared spinner.
		func replicators(in layer: CALayer) -> Int {
			(layer.sublayers ?? []).reduce(layer is CAReplicatorLayer ? 1 : 0) {
				$0 + replicators(in: $1)
			}
		}
		#expect(replicators(in: tree) == 1)
		// Nothing sweeps, because nothing said how far it had got.
		#expect(shapes(in: tree).allSatisfy { $0.animation(forKey: "strokeEnd") == nil })
		// And it is drawn: something is on the frame where the spinner is.
		#expect(try alpha(scene, at: 0.5, x: 200, y: 100 + 45) > 0.2)
	}

	// MARK: - The file

	@Test func aBarAndASpinnerSurviveTheFile() throws {
		let project = Project(scenes: ["hud": Scene(parts: [
			.init(content: .bar(Scene.Bar(fill: RGBA(hex: "#2a9d8f")!,
			                              track: RGBA(hex: "#ffffff33")!,
			                              corner: 0.006, direction: .up)),
			      keys: [.init(t: 0, x: 0.2, y: 0.5, width: 0.02, height: 0.4, progress: 0),
			             .init(t: 2, progress: 0.65, ease: .out)]),
			.init(content: .spinner(Spinner(style: .arc, size: 0.12, speed: 1.5,
			                                color: RGBA(hex: "#e76f51")!)),
			      keys: [.init(t: 0, x: 0.8, y: 0.5, opacity: 1)]),
		])])
		let text = ProjectWriter.write(project)
		#expect(text.contains("- bar:   \"#2a9d8f\""))
		#expect(text.contains("direction: up"))
		#expect(text.contains("- spinner: arc"))
		#expect(text.contains("progress: 0.65"))
		let back = try ProjectReader.read(text)
		#expect(back.scenes == project.scenes)
		#expect(ProjectWriter.write(back) == text)
	}

	@Test func aBarWithNoGrooveSaysNone() throws {
		let project = Project(scenes: ["hud": Scene(parts: [
			.init(content: .bar(Scene.Bar(fill: .white, track: RGBA(r: 0, g: 0, b: 0, a: 0))),
			      keys: [.init(t: 0, progress: 0)]),
		])])
		let text = ProjectWriter.write(project)
		#expect(text.contains("track: none"))
		#expect(try ProjectReader.read(text).scenes == project.scenes)
	}

	@Test func aSpinnerStyleTheReaderDoesNotKnowIsRefused() {
		#expect(throws: ProjectError.self) {
			try ProjectReader.read("""
			cuttr-project: 1

			timeline:
			  - clip: intro

			scenes:
			  hud:
			    parts:
			      - spinner: helix
			        keys:
			          - {t: 0}
			""")
		}
	}
}
