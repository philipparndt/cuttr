import CoreGraphics
import ImageIO
import QuartzCore
import UniformTypeIdentifiers
import CuttrKit
import Foundation
import Testing
@testable import CuttrCompose

/// A background made of a picture.
///
/// A background was one colour or a ramp between two, which covers a title card
/// and nothing else: a photograph behind the words, a paper texture, a still
/// drawn somewhere else — all of those were an `image:` part sized to the frame
/// by hand, which is the same thing said less well and gets the aspect wrong the
/// moment the output changes shape.
@Suite struct BackgroundImageTests {

	private func read(_ background: String) throws -> Scene.Background {
		let project = try ProjectReader.read("""
		timeline: [one]
		scenes:
		  card:
		    parts:
		      - background: \(background)
		        keys: [{t: 0, opacity: 1}]
		""")
		let part = try #require(project.scenes["card"]?.parts.first)
		guard case .background(let read) = part.content else {
			Issue.record("not a background")
			throw ProjectError.badValue(key: "background", value: background)
		}
		return read
	}

	@Test func aBackgroundCanBeAPicture() throws {
		let background = try read("{from: \"#101418\", image: backdrop.png}")
		#expect(background.image == "backdrop.png")
		#expect(background.from.hex == "#101418")
		#expect(background.to == nil)
	}

	/// A background of nothing but a picture says nothing about colour, and
	/// what is behind something that covers the frame is not a decision
	/// anybody should have to make.
	@Test func aPictureAloneNeedsNoColour() throws {
		let background = try read("{image: backdrop.png}")
		#expect(background.image == "backdrop.png")
		#expect(background.from == .black)
	}

	/// And the picture goes over the ramp rather than instead of it, which is
	/// what makes a PNG with transparency in it sit on the colour.
	@Test func aPictureAndARampAreBoth() throws {
		let background = try read("{from: \"#101418\", to: \"#1d3557\", angle: 45, image: b.png}")
		#expect(background.image == "b.png")
		#expect(background.to?.hex == "#1d3557")
		#expect(background.angle == 45)
	}

	/// The rule the whole emitter exists for: a background nobody has given a
	/// picture writes exactly what it always wrote — one word for a flat
	/// colour.
	@Test func aBackgroundWithNoPictureIsUnchanged() throws {
		let project = try ProjectReader.read("""
		timeline: [one]
		scenes:
		  card:
		    parts:
		      - background: "#101418"
		        keys: [{t: 0, opacity: 1}]
		""")
		let written = ProjectWriter.write(project)
		#expect(written.contains("- background: \"#101418\"\n"))
		#expect(!written.contains("image"))
	}

	@Test func aPictureRoundTrips() throws {
		let project = try ProjectReader.read("""
		timeline: [one]
		scenes:
		  card:
		    parts:
		      - background: {from: "#101418", to: "#1d3557", angle: 90, image: backdrop.png}
		        keys: [{t: 0, opacity: 1}]
		""")
		let written = ProjectWriter.write(project)
		#expect(written.contains(
			"- background: {from: \"#101418\", to: \"#1d3557\", angle: 90, image: backdrop.png}"))
		let back = try ProjectReader.read(written)
		#expect(back == project)
		#expect(ProjectWriter.write(back) == written)
	}

	/// A picture with no ramp writes the flow form too, because there is now
	/// something to say beyond the one colour.
	@Test func aPictureWithNoRampStillWritesItsPath() throws {
		let project = try ProjectReader.read("""
		timeline: [one]
		scenes:
		  card:
		    parts:
		      - background: {from: "#101418", image: backdrop.png}
		        keys: [{t: 0, opacity: 1}]
		""")
		let written = ProjectWriter.write(project)
		#expect(written.contains("- background: {from: \"#101418\", image: backdrop.png}"))
		#expect(try ProjectReader.read(written) == project)
	}

	// MARK: - Drawn

	/// One frame of a scene, painted, so that what the picture does to the
	/// pixels can be looked at rather than argued about.
	private func painted(_ background: String, in directory: URL) throws -> CGImage {
		let project = try ProjectReader.read("""
		timeline: [one]
		scenes:
		  card:
		    parts:
		      - background: \(background)
		        keys: [{t: 0, opacity: 1}]
		""")
		let scene = try #require(project.scenes["card"])
		return try #require(OverlayPainter.sceneImage(
			scene, with: [:], project: project, baseURL: directory,
			size: CGSize(width: 64, height: 36), at: 0))
	}

	private func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
		var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
		let context = CGContext(
			data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8,
			bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
			bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
		context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
		let at = y * image.width * 4 + x * 4
		return (Int(pixels[at]), Int(pixels[at + 1]), Int(pixels[at + 2]))
	}

	/// A tall red picture on a 16:9 frame is *filled*, not fitted: a background
	/// is the ground, and ground with a margin round it is not ground. So the
	/// corners are red too, and the colour underneath is nowhere to be seen.
	@Test func aPictureFillsTheFrameRatherThanFittingInIt() throws {
		// A directory URL, with the trailing slash that makes it one: the app's
		// `baseURL` is a project file's `deletingLastPathComponent()`, and a
		// path resolved against a URL that is not marked as a directory lands
		// beside it rather than inside it.
		let directory = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("cuttr-background-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }

		// Sixteen by ninety-six: far taller than the frame it is going into.
		let context = try #require(CGContext(
			data: nil, width: 16, height: 96, bitsPerComponent: 8, bytesPerRow: 0,
			space: CGColorSpace(name: CGColorSpace.sRGB)!,
			bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
		context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
		context.fill(CGRect(x: 0, y: 0, width: 16, height: 96))
		let made = try #require(context.makeImage())
		let file = directory.appendingPathComponent("tall.png")
		let destination = try #require(CGImageDestinationCreateWithURL(
			file as CFURL, "public.png" as CFString, 1, nil))
		CGImageDestinationAddImage(destination, made, nil)
		#expect(CGImageDestinationFinalize(destination))

		let drawn = try painted("{from: \"#0000ff\", image: tall.png}", in: directory)
		// The middle, and a corner: both red, because the picture covers it all.
		let middle = pixel(drawn, x: 32, y: 18)
		#expect(middle.r > 200 && middle.b < 60, "the middle is \(middle)")
		let corner = pixel(drawn, x: 1, y: 1)
		#expect(corner.r > 200 && corner.b < 60, "the corner is \(corner) — fitted, not filled")
	}

	/// And the *other* draw path has it too.
	///
	/// A scene over a card is drawn as a tree of Core Animation layers and laid
	/// over the finished picture in a second pass, which is a different piece
	/// of code from the painter above. A background image that appeared in the
	/// preview and not in the render would be the worst possible way to find
	/// that out.
	@Test func theLayerPathDrawsItToo() throws {
		let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
		let picture = directory.appendingPathComponent("cuttr-bg-\(UUID().uuidString).png")
		defer { try? FileManager.default.removeItem(at: picture) }
		let context = try #require(CGContext(
			data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
			space: CGColorSpace(name: CGColorSpace.sRGB)!,
			bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
		context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
		context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
		let made = try #require(context.makeImage())
		let destination = try #require(CGImageDestinationCreateWithURL(
			picture as CFURL, "public.png" as CFString, 1, nil))
		CGImageDestinationAddImage(destination, made, nil)
		#expect(CGImageDestinationFinalize(destination))

		let project = try ProjectReader.read("""
		timeline:
		  - card: 00:02.000
		    as:   intro
		overlays:
		  - scene: card
		    from:  "@intro"
		scenes:
		  card:
		    parts:
		      - background: {from: "#101418", image: \(picture.lastPathComponent)}
		        keys: [{t: 0, opacity: 1}]
		""")
		let resolved = try Resolver.resolve(project, baseURL: directory)
		let tree = OverlayLayers.build(resolved, size: CGSize(width: 64, height: 36), host: .export)
		// The scene's tree, its background layer, and the picture over it.
		let pictures = layers(under: tree).filter { $0.contents != nil }
		#expect(!pictures.isEmpty, "the layer path drew no picture")
		#expect(pictures.contains { $0.contentsGravity == .resizeAspectFill },
		        "the picture was fitted rather than filled")
	}

	private func layers(under layer: CALayer) -> [CALayer] {
		(layer.sublayers ?? []).flatMap { [$0] + layers(under: $0) }
	}

	/// A path that names nothing keeps the colours and renders. A background
	/// whose picture has been moved should look wrong in one obvious way, not
	/// refuse to render the film.
	@Test func aMissingPictureLeavesTheColoursAlone() throws {
		let directory = URL(fileURLWithPath: NSTemporaryDirectory())
		let drawn = try painted("{from: \"#0000ff\", image: nowhere.png}", in: directory)
		let middle = pixel(drawn, x: 32, y: 18)
		#expect(middle.b > 200 && middle.r < 60, "the middle is \(middle)")
	}
}
