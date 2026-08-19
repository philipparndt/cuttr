import CoreGraphics
import CoreImage
import Foundation
import QuartzCore
import Testing
@testable import CuttrCompose

/// The arithmetic the scene editor does, without the editor.
@Suite struct SceneEditingTests {

	private func moving() -> Scene.Part {
		Scene.Part(content: .shape(fill: .white, corner: 0), keys: [
			.init(t: 0, x: 0.2, y: 0.5, opacity: 1, width: 0.1, height: 0.1, ease: .linear),
			.init(t: 2, x: 0.8, ease: .linear),
		])
	}

	/// A key dropped in the middle of a move leaves the part where it was.
	///
	/// The whole point: a key that says nothing inherits from the key *before*
	/// it, so an empty one dropped half way through a move would stop the move
	/// dead at that point.
	@Test func aNewKeyFreezesWhatWasAlreadyHappening() {
		let part = moving()
		let before = Scene.state(of: Scene.filled(part.keys), at: 1)
		let (keys, index) = part.inserting(keyAt: 1)
		#expect(keys.count == 3)
		#expect(index == 1)
		#expect(keys[1].t == 1)
		#expect(keys[1].x == before?.x)
		// …and only what was moving. Nothing else is written down, so the file
		// stays a description of the change rather than of the state.
		#expect(keys[1].y == nil)
		#expect(keys[1].opacity == nil)
		#expect(keys[1].width == nil)
		// The part is still where it was, at that moment and at every other.
		for t in stride(from: 0.0, through: 2.0, by: 0.25) {
			let now = Scene.state(of: Scene.filled(keys), at: t)
			let then = Scene.state(of: Scene.filled(part.keys), at: t)
			#expect(abs((now?.x ?? 0) - (then?.x ?? 0)) < 1e-9, "moved at \(t)")
		}
	}

	/// Dropping one where a key already is finds that key instead of making a
	/// second one at the same moment.
	@Test func aKeyIsNeverMadeTwiceAtTheSameMoment() {
		let (keys, index) = moving().inserting(keyAt: 2.0001)
		#expect(keys.count == 2)
		#expect(index == 1)
	}

	/// Before the first key there is nothing to inherit from, so the new key
	/// says everything the first one said.
	@Test func aKeyBeforeThemAllStandsOnItsOwn() {
		let part = Scene.Part(content: .text("hello", style: nil),
		                      keys: [.init(t: 1, x: 0.3, y: 0.4, opacity: 1)])
		let (keys, index) = part.inserting(keyAt: 0)
		#expect(index == 0)
		#expect(keys[0].x == 0.3)
		#expect(keys[0].y == 0.4)
		#expect(keys[0].opacity == 1)
	}

	/// A key is read and written one field at a time, because that is what a
	/// table of them and a drag on the stage both need.
	@Test func fieldsAreReachedByName() {
		var key = Scene.Key(t: 0)
		#expect(key.isEmpty)
		key[.rotation] = 12
		#expect(key.rotation == 12)
		#expect(key[.rotation] == 12)
		#expect(key[.x] == nil)
		#expect(!key.isEmpty)
		key[.rotation] = nil
		#expect(key.isEmpty)
	}

	/// A part is where the keys put it, and its box is the size the render
	/// draws it at — measured for text, stated for everything else.
	@Test func partsArePlacedWhereTheyAreDrawn() {
		let scene = Scene(parts: [
			.init(content: .background(Scene.Background(from: .black)),
			      keys: [.init(t: 0, opacity: 1)]),
			.init(content: .shape(fill: .white, corner: 0),
			      keys: [.init(t: 0, x: 0.25, y: 0.75, rotation: 90, width: 0.5, height: 0.25)]),
			.init(content: .text("A title", style: "title"), keys: [.init(t: 0, x: 0.5, y: 0.5)]),
		])
		let size = CGSize(width: 1920, height: 1080)
		let placed = SceneLayout.placements(of: scene, project: Project(), size: size, at: 0)
		#expect(placed.count == 3)

		#expect(placed[0].isBackground)
		#expect(placed[0].size == size)

		#expect(placed[1].centre == CGPoint(x: 480, y: 810))
		#expect(placed[1].size == CGSize(width: 960, height: 270))
		// Turned a quarter turn, so a point beyond its unturned edge is on it
		// and a point beyond its turned one is not.
		#expect(placed[1].contains(CGPoint(x: 480, y: 810 + 400)))
		#expect(!placed[1].contains(CGPoint(x: 480 + 400, y: 810)))

		// Text is as wide as the words came out, which is not a number anybody
		// wrote down.
		#expect(placed[2].size.width > 0)
		#expect(placed[2].size.height > 0)
		#expect(placed[2].centre == CGPoint(x: 960, y: 540))
	}

	/// The handles are on the corners of the box, wherever the box has been
	/// turned to.
	@Test func theHandlesFollowTheTurn() {
		let placement = ScenePlacement(
			part: 0, centre: CGPoint(x: 100, y: 100), size: CGSize(width: 100, height: 40),
			scale: 2, rotation: 0, opacity: 1, isBackground: false)
		#expect(placement.corner(1, 1) == CGPoint(x: 200, y: 140))
		let turned = ScenePlacement(
			part: 0, centre: CGPoint(x: 100, y: 100), size: CGSize(width: 100, height: 40),
			scale: 1, rotation: 180, opacity: 1, isBackground: false)
		let corner = turned.corner(1, 1)
		#expect(abs(corner.x - 50) < 0.001)
		#expect(abs(corner.y - 80) < 0.001)
	}
}

/// The two ways a scene reaches the screen have to agree.
///
/// They are drawn by different code — Core Animation lays the layers over the
/// picture, and the painter rasterises the same scene when it has to go
/// *behind* somebody. The editor's stage is the painter, so a disagreement
/// between them is a preview that lies about the export, which is the one thing
/// this program is built not to do.
@Suite struct SceneRenderAgreementTests {

	private func resolved(_ project: Project) -> ResolvedProject {
		ResolvedProject(
			project: project, baseURL: URL(fileURLWithPath: "."), clips: [],
			overlays: [ResolvedOverlay(
				overlay: Overlay(kind: .scene("intro", with: [:]), span: .times(from: 0, to: 4),
				                 arrival: .cut, departure: .cut),
				source: 0, appearance: 0, start: 0, end: 4, path: nil)],
			groups: [], anchors: [])
	}

	private func layers(in layer: CALayer) -> [CALayer] {
		(layer.sublayers ?? []).flatMap { [$0] + layers(in: $0) }
	}

	/// The bug this is here for: a gradient layer's unit space is the layer's
	/// own, bottom-left up, and flipping it — which is what an iOS habit says to
	/// do — put `from` at the top of the export and at the bottom of the
	/// preview. Found by rendering a file and looking at it.
	@Test func aGradientRunsTheSameWayInBothPaths() throws {
		let project = Project(scenes: ["intro": Scene(parts: [
			.init(content: .background(Scene.Background(from: .black, to: .white, angle: 90)),
			      keys: [.init(t: 0, opacity: 1)]),
		])])
		let size = CGSize(width: 640, height: 360)

		// The layer path: `from` at the bottom of the frame.
		let tree = OverlayLayers.build(resolved(project), size: size, host: .export)
		let ramp = try #require(layers(in: tree).compactMap { $0 as? CAGradientLayer }.first)
		#expect(abs(ramp.startPoint.y) < 0.001)
		#expect(abs(ramp.endPoint.y - 1) < 0.001)

		// The painter: the same way up. Black at the bottom, white at the top.
		let scene = try #require(project.scenes["intro"])
		let image = try #require(OverlayPainter.sceneImage(
			scene, with: [:], project: project,
			baseURL: URL(fileURLWithPath: "."), size: size, at: 0))
		let context = CIContext(options: [.workingColorSpace: NSNull()])
		func pixel(_ x: Int, _ y: Int) -> Double {
			var bytes = [UInt8](repeating: 0, count: 4)
			context.render(CIImage(cgImage: image), toBitmap: &bytes, rowBytes: 4,
			               bounds: CGRect(x: x, y: y, width: 1, height: 1),
			               format: .RGBA8, colorSpace: nil)
			return Double(bytes[0]) / 255
		}
		#expect(pixel(320, 4) < 0.1, "the painter puts `from` at the top")
		#expect(pixel(320, 355) > 0.9)
	}
}
