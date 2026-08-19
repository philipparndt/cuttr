import CoreImage
import CoreVideo
import Foundation
import Metal
import AppKit
import SceneKit

/// An effect, as pixels, at a moment.
///
/// A scene graph with lights in it, rendered offscreen. The pieces are real
/// geometry — thin slips of card with two sides and a chamfer — so the key
/// light catches them as they turn and they go dark as they turn away. That
/// tumble is the whole difference between confetti and coloured rectangles
/// falling down a screen.
///
/// Everything about a frame is computed *from the time*, not stepped from the
/// frame before: no physics simulation, no state carried between renders. So
/// any moment can be asked for in any order, which is what a scrubbing preview
/// does, and the same second of the same seed comes out the same on every
/// machine and every render.
final class EffectRenderer: @unchecked Sendable {

	private struct Piece {
		let node: SCNNode
		/// Where it starts, how fast it falls, and how it turns.
		let x: Float, z: Float, phase: Float
		let fall: Float, sway: Float, swayRate: Float
		let spinX: Float, spinY: Float, spinZ: Float
		let lift: Float
		let size: Float
	}

	private let renderer: SCNRenderer
	private let scene = SCNScene()
	private let camera = SCNNode()
	private let pieces: [Piece]
	private let effect: Effect
	private let size: CGSize
	private let device: MTLDevice
	private let queue: MTLCommandQueue
	private let depth: MTLTexture
	/// One scene, one renderer: frames go through here in turn. Core Image asks
	/// from more than one thread and a scene graph is not two things.
	private let lock = NSLock()

	/// The world is two units tall at the camera's distance, whatever the
	/// frame's shape — so `size` and speeds mean the same thing at any output.
	private static let worldHeight: Float = 10

	init?(_ effect: Effect, size: CGSize) {
		guard size.width >= 16, size.height >= 16,
		      let device = MTLCreateSystemDefaultDevice(),
		      let queue = device.makeCommandQueue() else { return nil }
		self.device = device
		self.queue = queue
		self.effect = effect
		self.size = size

		let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(
			pixelFormat: .depth32Float, width: Int(size.width), height: Int(size.height),
			mipmapped: false)
		depthDescriptor.usage = [.renderTarget]
		depthDescriptor.storageMode = .private
		guard let depth = device.makeTexture(descriptor: depthDescriptor) else { return nil }
		self.depth = depth

		renderer = SCNRenderer(device: device, options: nil)
		scene.background.contents = NSNull()

		let world = Self.worldHeight
		let aspect = Float(size.width / size.height)
		camera.camera = SCNCamera()
		camera.camera?.usesOrthographicProjection = true
		camera.camera?.orthographicScale = Double(world / 2)
		camera.camera?.zNear = 0.1
		camera.camera?.zFar = 100
		camera.position = SCNVector3(0, 0, 20)
		scene.rootNode.addChildNode(camera)

		// A key light to catch the faces of the pieces as they turn, and enough
		// ambient that the ones turned away are dark rather than black.
		let key = SCNNode()
		key.light = SCNLight()
		key.light?.type = .directional
		key.light?.intensity = effect.finish == .matte ? 1500 : 2400
		key.eulerAngles = SCNVector3(-0.5, 0.6, 0)
		scene.rootNode.addChildNode(key)

		let rim = SCNNode()
		rim.light = SCNLight()
		rim.light?.type = .directional
		rim.light?.intensity = effect.finish == .matte ? 600 : 1100
		rim.eulerAngles = SCNVector3(0.7, -0.9, 0)
		scene.rootNode.addChildNode(rim)

		let ambient = SCNNode()
		ambient.light = SCNLight()
		ambient.light?.type = .ambient
		ambient.light?.intensity = effect.finish == .matte ? 380 : 500
		scene.rootNode.addChildNode(ambient)

		if effect.finish != .matte {
			// A sky to be a mirror of: bright above, dark below, so a piece
			// turning through the light goes from a flare to nothing the way
			// foil does.
			scene.lightingEnvironment.contents = Self.sky()
			scene.lightingEnvironment.intensity = effect.finish == .glitter ? 4.0 : 3.2
		}

		var random = Seeded(effect.seed)
		let colours = effect.colours
		var pieces: [Piece] = []
		for index in 0..<effect.count {
			let colour = colours[index % colours.count]
			let piece = Piece(
				node: Self.node(for: effect, colour: colour, random: &random),
				x: Float(random.value(-1...1)) * world * aspect / 2 * 1.1,
				z: Float(random.value(-3...3)),
				phase: Float(random.value(0...(2 * .pi))),
				fall: Float(random.value(Self.fall(effect))),
				sway: Float(random.value(Self.sway(effect))),
				swayRate: Float(random.value(0.6...2.2)),
				spinX: Float(random.value(-2.5...2.5)),
				spinY: Float(random.value(-3...3)),
				spinZ: Float(random.value(-1.5...1.5)),
				lift: Float(random.value(Self.lift(effect))),
				size: Float(random.value(0.75...1.35)))
			scene.rootNode.addChildNode(piece.node)
			pieces.append(piece)
		}
		self.pieces = pieces
		renderer.scene = scene
		renderer.pointOfView = camera
		renderer.autoenablesDefaultLighting = false
		renderer.prepare(scene, shouldAbortBlock: nil)
	}

	// MARK: - What each style is made of

	private static func fall(_ effect: Effect) -> ClosedRange<Double> {
		switch effect.style {
		case .confetti: return 1.4...3.2
		case .snow: return 0.5...1.2
		case .sparkle: return 2.2...4.5
		}
	}

	private static func sway(_ effect: Effect) -> ClosedRange<Double> {
		switch effect.style {
		case .confetti: return 0.3...1.1
		case .snow: return 0.15...0.5
		case .sparkle: return 0.05...0.3
		}
	}

	/// How hard a piece is thrown *up* before gravity has it — nothing for
	/// things that fall, a good shove for a burst.
	private static func lift(_ effect: Effect) -> ClosedRange<Double> {
		switch effect.style {
		case .confetti, .snow: return 0...0
		case .sparkle: return 3...7
		}
	}

	private static func node(for effect: Effect, colour: RGBA, random: inout Seeded) -> SCNNode {
		let geometry: SCNGeometry
		let small: CGFloat = effect.finish == .glitter ? 0.45 : 1
		switch effect.style {
		case .confetti:
			// A slip of card: wider than it is tall, and thin enough to vanish
			// edge-on, which is what makes the tumble read. Glitter is the same
			// slip cut small, and there is more of it.
			geometry = SCNBox(width: 0.34 * small, height: 0.5 * small,
			                  length: 0.012 * small, chamferRadius: 0.006 * small)
		case .snow:
			geometry = SCNSphere(radius: 0.075)
		case .sparkle:
			geometry = SCNBox(width: 0.12, height: 0.34, length: 0.012, chamferRadius: 0.05)
		}

		let material = geometry.firstMaterial ?? SCNMaterial()
		material.lightingModel = .physicallyBased
		material.diffuse.contents = CGColor(
			srgbRed: colour.r, green: colour.g, blue: colour.b, alpha: 1)
		// Foil is a coloured mirror, so it needs something to reflect: without
		// a lighting environment a metal is simply black, which is the usual
		// way a first attempt at metallic confetti goes wrong.
		switch effect.finish {
		case .matte:
			material.metalness.contents = effect.style == .snow ? 0.0 : 0.15
			material.roughness.contents = effect.style == .snow ? 0.9 : Double(random.value(0.5...0.8))
		case .metallic:
			// Not a pure mirror: a piece at metalness one has no colour of its
			// own at all — it is whatever it reflects, and against a sky that
			// is mostly not the sun, that reads as dark grey confetti. Leaving
			// a fifth of the diffuse keeps the colour in it.
			material.metalness.contents = 0.8
			material.roughness.contents = Double(random.value(0.1...0.22))
		case .glitter:
			// Every piece polished differently: the catches come and go one at
			// a time rather than the whole cloud flashing together.
			material.metalness.contents = 0.85
			material.roughness.contents = Double(random.value(0.02...0.14))
		}
		material.isDoubleSided = true
		geometry.materials = [material]
		return SCNNode(geometry: geometry)
	}

	/// Where every piece is, as the scene stands. For tests: an effect that
	/// cannot be repeated is one nobody can approve.
	/// How many pieces are in the air, for the test that says a fall-out empties
	/// the frame.
	var showing: Int { pieces.filter { !$0.node.isHidden }.count }

	var positions: [Double] {
		pieces.flatMap { piece in
			[Double(piece.node.position.x), Double(piece.node.position.y),
			 Double(piece.node.eulerAngles.y)]
		}
	}

	/// A gradient for the foil to reflect. Made rather than shipped: it is four
	/// stops of grey, and a file on disk is a file to lose.
	private static func sky() -> NSImage {
		let size = NSSize(width: 64, height: 64)
		let image = NSImage(size: size)
		image.lockFocus()
		NSGradient(colors: [
			NSColor(calibratedWhite: 1.0, alpha: 1),
			NSColor(calibratedWhite: 0.92, alpha: 1),
			NSColor(calibratedWhite: 0.7, alpha: 1),
			NSColor(calibratedWhite: 0.45, alpha: 1),
		])?.draw(in: NSRect(origin: .zero, size: size), angle: -90)
		image.unlockFocus()
		return image
	}

	// MARK: - A frame

	/// Where every piece is at `time` seconds into the effect, and the picture
	/// of it.
	/// `spawningUntil` is when the last piece may be let go: after that the
	/// cloud thins out as what is already falling leaves the frame, which is
	/// what "fall out" means and what a fade cannot do.
	func image(at time: Double, spawningUntil: Double = .infinity) -> CIImage? {
		lock.lock()
		defer { lock.unlock() }

		place(at: time, spawningUntil: spawningUntil)

		guard let buffer = makeBuffer(), let texture = makeTexture(for: buffer) else { return nil }
		let pass = MTLRenderPassDescriptor()
		pass.colorAttachments[0].texture = texture
		pass.colorAttachments[0].loadAction = .clear
		pass.colorAttachments[0].storeAction = .store
		pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
		pass.depthAttachment.texture = depth
		pass.depthAttachment.loadAction = .clear
		pass.depthAttachment.storeAction = .dontCare
		pass.depthAttachment.clearDepth = 1

		guard let commands = queue.makeCommandBuffer() else { return nil }
		renderer.render(atTime: 0, viewport: CGRect(origin: .zero, size: size),
		                commandBuffer: commands, passDescriptor: pass)
		commands.commit()
		// Waited for: the pixels are read on this side of the fence.
		commands.waitUntilCompleted()

		return CIImage(cvPixelBuffer: buffer)
	}

	/// Every piece put where the arithmetic says it is at this moment.
	///
	/// Inside a transaction with actions off, because SceneKit animates a change
	/// to a node's position by default — and a scene with no view has no clock
	/// to run that animation on, so every piece stayed where it was first put:
	/// all of them at the origin, which renders as one rectangle that never
	/// moves.
	private func place(at time: Double, spawningUntil: Double = .infinity) {
		SCNTransaction.begin()
		SCNTransaction.animationDuration = 0
		SCNTransaction.disableActions = true
		defer { SCNTransaction.commit() }

		let t = Float(max(0, time)) * Float(max(0.05, effect.speed))
		let world = Self.worldHeight
		let ceiling = world / 2 + 1.5
		let floor = -world / 2 - 1.5
		let height = ceiling - floor

		for piece in pieces {
			let y: Float
			if effect.style == .sparkle {
				// Thrown up from below the frame and pulled back down: one
				// flight, not a loop, because a burst that repeats is a fountain.
				y = floor + piece.lift * t - 4.9 * t * t / 2
			} else {
				// It falls in from above rather than being there already: at
				// zero every piece is over the top of the frame, spread out, so
				// the first of them arrive within a moment and the rest follow.
				// Starting the frame full and fading it up is the thing that
				// looks like a screensaver.
				let entry = piece.phase / (2 * .pi) * height * 1.6
				let fallen = piece.fall * t - entry
				let lap = height + entry
				let wrapped = fallen.truncatingRemainder(dividingBy: lap)
				y = ceiling - (fallen < 0 ? fallen : wrapped)

				// Which time this piece was last let go. Past the cut-off it is
				// not let go again, so the cloud empties from the top down.
				if fallen > 0 {
					let laps = (fallen / lap).rounded(.down)
					let released = (laps * lap + entry) / piece.fall
					piece.node.isHidden = Double(released) > spawningUntil
				} else {
					piece.node.isHidden = false
				}
			}
			let sway: Float = piece.sway * sin(piece.swayRate * t + piece.phase)
			let x: Float = piece.x + sway
			if effect.style == .sparkle { piece.node.isHidden = false }
			piece.node.position = SCNVector3(x, y, piece.z)
			let pitch: Float = piece.spinX * t + piece.phase
			let yaw: Float = piece.spinY * t + piece.phase
			let roll: Float = piece.spinZ * t
			piece.node.eulerAngles = SCNVector3(pitch, yaw, roll)
			let scale = piece.size * Float(max(0.05, effect.size))
			piece.node.scale = SCNVector3(scale, scale, scale)
		}
	}

	private func makeBuffer() -> CVPixelBuffer? {
		var buffer: CVPixelBuffer?
		let attributes: [CFString: Any] = [
			kCVPixelBufferMetalCompatibilityKey: true,
			kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
		]
		guard CVPixelBufferCreate(
			kCFAllocatorDefault, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA,
			attributes as CFDictionary, &buffer) == kCVReturnSuccess else { return nil }
		return buffer
	}

	private func makeTexture(for buffer: CVPixelBuffer) -> MTLTexture? {
		var cache: CVMetalTextureCache?
		guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
		      let cache else { return nil }
		var wrapped: CVMetalTexture?
		guard CVMetalTextureCacheCreateTextureFromImage(
			kCFAllocatorDefault, cache, buffer, nil, .bgra8Unorm,
			Int(size.width), Int(size.height), 0, &wrapped) == kCVReturnSuccess,
			let wrapped else { return nil }
		return CVMetalTextureGetTexture(wrapped)
	}
}
