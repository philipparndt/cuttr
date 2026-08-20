import AVFoundation
import CoreImage
import Foundation
import Testing
@testable import CuttrCompose

/// When an overlay is on screen, measured in the file that comes out.
///
/// Every other test of an overlay's timing asks the model what it thinks. These
/// two render, decode and look, because the bug they guard against lived in the
/// gap between the two: the preview took a hard-cut caption away on time and
/// the export left it up for the whole film.
@Suite struct OverlayTimingTests {

	/// A three-second card with one caption, said however the caller likes.
	private func rendered(_ transitions: String) async throws -> URL {
		let directory = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("cuttr-timing-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let project = try ProjectReader.read("""
			output:
			  size: 640x360
			  fps:  25
			  file: timing.mov

			timeline:
			  - card: 00:03.000
			    fill: "#000000"

			overlays:
			  - text:  hard
			    style: title
			    from:  00:01.000
			    to:    00:02.000
			\(transitions)
			""")
		let resolved = try Resolver.resolve(project, baseURL: directory)
		let url = directory.appendingPathComponent("timing.mov")
		try await Renderer.export(resolved, to: url)
		return url
	}

	/// How much of the frame is bright enough to be lettering on black.
	private func ink(in url: URL, at seconds: Double) async throws -> Int {
		let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
		generator.requestedTimeToleranceBefore = .zero
		generator.requestedTimeToleranceAfter = .zero
		let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
		let width = image.width, height = image.height
		var pixels = [UInt8](repeating: 0, count: width * height * 4)
		let context = CGContext(data: &pixels, width: width, height: height,
		                        bitsPerComponent: 8, bytesPerRow: width * 4,
		                        space: CGColorSpaceCreateDeviceRGB(),
		                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
		context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
		return stride(from: 0, to: pixels.count, by: 4).count { pixels[$0] > 140 }
	}

	/// The spelling with nothing to hide behind: on at its first mark, off at
	/// its second, and nothing either side.
	@Test func aCaptionThatCutsInAndOutObeysItsMarks() async throws {
		let url = try await rendered("""
			    in:    cut
			    out:   cut
			""")
		defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
		#expect(try await ink(in: url, at: 0.4) == 0)
		#expect(try await ink(in: url, at: 0.96) == 0)
		#expect(try await ink(in: url, at: 1.4) > 100)
		#expect(try await ink(in: url, at: 1.96) > 100)
		#expect(try await ink(in: url, at: 2.4) == 0)
	}

	/// The same take on it, with fades — which worked all along, and has to go
	/// on working now that the envelope is written differently.
	@Test func aCaptionThatFadesIsStillGoneEitherSideOfItsSpan() async throws {
		let url = try await rendered("""
			    in:    {fade: true, over: 0.3}
			    out:   {fade: true, over: 0.3}
			""")
		defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
		#expect(try await ink(in: url, at: 0.6) == 0)
		#expect(try await ink(in: url, at: 1.5) > 100)
		#expect(try await ink(in: url, at: 2.4) == 0)
	}

	/// An arrival placed before the first mark, in the encoded file.
	///
	/// The claim placements make is that an overlay can be on screen *before*
	/// its span, and the export is where such a claim has failed before: the
	/// preview honours the discrete `hidden` animation and
	/// `AVVideoCompositionCoreAnimationTool` does not, so the opacity envelope
	/// has to bracket the drawn window rather than the span. Bracketed at the
	/// span, this caption would be invisible for the whole of its fade and would
	/// snap on at the mark — which is exactly what it is not allowed to do.
	@Test func aCaptionPlacedBeforeTheMarkIsUpBeforeItsSpan() async throws {
		let url = try await rendered("""
			    in:    {fade: true, over: 0.4, at: before}
			    out:   cut
			""")
		defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
		// The movement runs from 0.6 to the mark at 1.0.
		#expect(try await ink(in: url, at: 0.4) == 0, "nothing before the movement starts")
		#expect(try await ink(in: url, at: 0.9) > 0, "three quarters of the way up, early")
		#expect(try await ink(in: url, at: 1) > 100, "fully on for the mark itself")
		#expect(try await ink(in: url, at: 1.96) > 100)
		#expect(try await ink(in: url, at: 2.04) == 0, "and cut away at its last mark")
	}

	/// A departure placed after the last mark, likewise: still up when the span
	/// ends, and gone a fraction of a second later.
	@Test func aCaptionPlacedAfterTheMarkIsStillUpWhenItsSpanEnds() async throws {
		let url = try await rendered("""
			    in:    cut
			    out:   {fade: true, over: 0.4, at: after}
			""")
		defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
		#expect(try await ink(in: url, at: 0.96) == 0, "nothing before its first mark")
		#expect(try await ink(in: url, at: 2) > 100, "still fully on at the last mark")
		#expect(try await ink(in: url, at: 2.1) > 0, "on its way out, past the span")
		#expect(try await ink(in: url, at: 2.44) == 0, "and gone")
	}
}
