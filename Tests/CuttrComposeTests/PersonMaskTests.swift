import CoreImage
import Foundation
import Testing
@testable import CuttrCompose

/// Bringing a mask up to the frame's size.
///
/// Vision itself needs a person in front of a camera, so what is tested here is
/// the arithmetic around it — which is where the bug was.
@Suite struct PersonMaskTests {

	private func mask(_ width: CGFloat, _ height: CGFloat) -> CIImage {
		CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
	}

	/// The enlarged mask must cover the whole frame. It did not: the scale was
	/// given as the horizontal factor, so a 2016 × 1512 mask became a 1439-pixel
	/// square in a 1920 × 1080 frame — and everything outside it, being outside
	/// the image, read as person.
	@Test func itCoversTheFrame() {
		let frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
		for size in [(2016.0, 1512.0), (512.0, 384.0), (256.0, 192.0), (1920.0, 1080.0)] {
			let out = PersonMask.enlarge(mask(size.0, size.1), to: frame).extent
			#expect(out == frame, "a \(Int(size.0))×\(Int(size.1)) mask covered \(out)")
		}
	}

	/// A mask that arrives small is softened more, because the steps in it are
	/// bigger. One that arrives at frame size is barely touched.
	@Test func theSofteningFollowsHowFarItWasStretched() {
		let frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
		let context = CIContext(options: [.workingColorSpace: NSNull()])

		/// How far a hard edge is spread, in pixels, measured along the middle.
		func spread(_ width: CGFloat, _ height: CGFloat) -> Int {
			// Half white, half nothing: one hard edge down the middle.
			let half = CIImage(color: .white)
				.cropped(to: CGRect(x: 0, y: 0, width: width / 2, height: height))
			let out = PersonMask.enlarge(half, to: frame)
			var bytes = [UInt8](repeating: 0, count: 1920)
			context.render(out, toBitmap: &bytes, rowBytes: 1920,
			               bounds: CGRect(x: 0, y: 540, width: 1920, height: 1),
			               format: .R8, colorSpace: nil)
			return bytes.filter { $0 > 20 && $0 < 235 }.count
		}

		let fromSmall = spread(256, 192)
		let fromLarge = spread(2016, 1512)
		#expect(fromSmall > fromLarge * 3,
		        "small \(fromSmall)px against large \(fromLarge)px")
		#expect(fromLarge < 12, "a mask at frame size should stay crisp: \(fromLarge)px")
	}
}
