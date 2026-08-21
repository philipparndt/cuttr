import AVFoundation
import CoreImage
import CuttrKit
import Foundation
import Testing
@testable import CuttrCompose

/// What happens to a frame *inside* a Core Image pass.
///
/// ``ColourTests`` is about the three render paths agreeing on what colour the
/// film is. This is the question underneath it: given a frame that is already
/// Rec. 709, does a pass hand back the numbers it was given?
///
/// It exists because the answer was believed to be no. Every pass in this
/// program runs with colour management off, and the comment above every one of
/// them said the same thing — that a managed pass came back seven or eight
/// levels lifted, which is what "washed out" meant. That was measured and it
/// was true, and the conclusion drawn from it was wrong: the pass was landing
/// in the wrong Rec. 709. There are two of them on this machine and they have
/// different curves.
///
/// So these tests are the numbers, kept where the next person to try turning
/// management on will find them before spending an afternoon re-deriving the
/// eight levels. Nothing here renders a film; a pass over a ramp answers the
/// question exactly, where a rendered file answers it plus an HEVC encode.
@Suite struct ColourPassTests {

	/// The space a frame from AVFoundation is in: built from the same three
	/// words the renderer stamps on every composition.
	static let arrivesIn = CVImageBufferCreateColorSpaceFromAttachments([
		kCVImageBufferColorPrimariesKey as String: kCVImageBufferColorPrimaries_ITU_R_709_2,
		kCVImageBufferTransferFunctionKey as String: kCVImageBufferTransferFunction_ITU_R_709_2,
		kCVImageBufferYCbCrMatrixKey as String: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
	] as CFDictionary)?.takeRetainedValue()

	static let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
	static let named709 = CGColorSpace(name: CGColorSpace.itur_709)!
	static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

	/// A 256-pixel-wide buffer tagged the way the renderer tags a composition.
	private func buffer() -> CVPixelBuffer {
		var made: CVPixelBuffer?
		CVPixelBufferCreate(nil, 256, 2, kCVPixelFormatType_32BGRA,
		                    [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &made)
		let buffer = made!
		CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey,
		                      kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
		CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey,
		                      kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
		CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
		                      kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
		return buffer
	}

	/// Every level from 0 to 255, once, so that "does it come home" is answered
	/// for the whole range rather than for whatever grey was to hand. Grey
	/// rather than a colour: a transfer function is the thing under test and it
	/// is the same on all three channels.
	private func ramp() -> CVPixelBuffer {
		let buffer = self.buffer()
		CVPixelBufferLockBaseAddress(buffer, [])
		let stride = CVPixelBufferGetBytesPerRow(buffer)
		let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
		for y in 0..<2 {
			for x in 0..<256 {
				let pixel = base + y * stride + x * 4
				pixel[0] = UInt8(x); pixel[1] = UInt8(x); pixel[2] = UInt8(x); pixel[3] = 255
			}
		}
		CVPixelBufferUnlockBaseAddress(buffer, [])
		return buffer
	}

	private func levels(_ buffer: CVPixelBuffer) -> [Int] {
		CVPixelBufferLockBaseAddress(buffer, .readOnly)
		let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
		let read = (0..<256).map { Int((base + $0 * 4)[1]) }
		CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
		return read
	}

	/// One pass over the ramp, and the worst level it is out by.
	private func worstError(working: Any, destination: CGColorSpace?) -> Int {
		let source = CIImage(cvPixelBuffer: ramp())
		let out = buffer()
		let context = CIContext(options: destination.map {
			[.workingColorSpace: working, .outputColorSpace: $0]
		} ?? [.workingColorSpace: working])
		context.render(source, to: out, bounds: CGRect(x: 0, y: 0, width: 256, height: 2),
		               colorSpace: destination)
		return zip(levels(out), 0..<256).map { abs($0 - $1) }.max() ?? 0
	}

	/// A flat colour of our own — a card's fill — through the same pass.
	private func painted(working: Any, destination: CGColorSpace?) -> Int {
		let out = buffer()
		let context = CIContext(options: destination.map {
			[.workingColorSpace: working, .outputColorSpace: $0]
		} ?? [.workingColorSpace: working])
		let card = Card.Fill.solid(RGBA(r: 128.0 / 255, g: 128.0 / 255, b: 128.0 / 255))
		context.render(card.image(size: CGSize(width: 256, height: 2)), to: out,
		               bounds: CGRect(x: 0, y: 0, width: 256, height: 2), colorSpace: destination)
		return levels(out)[10]
	}

	/// The trap, and the whole reason the eight levels were misdiagnosed.
	///
	/// `CGColorSpace(name: .itur_709)` is the constant anybody reaches for and
	/// it is not the space a 709 frame arrives in. Core Video builds that one
	/// from the buffer's attachments and calls it HDTV; the named constant is a
	/// second profile with a different curve. If this ever goes green the other
	/// way round, the numbers in the tests below are stale.
	@Test func theSpaceAFrameArrivesInIsNotTheOneCalledItur709() throws {
		let arrivesIn = try #require(Self.arrivesIn)
		#expect(CIImage(cvPixelBuffer: buffer()).colorSpace == arrivesIn)
		#expect(arrivesIn != Self.named709)
	}

	/// What the program does today: management off, and the ramp comes home.
	///
	/// Not a tautology — it is the claim the whole unmanaged pipeline rests on,
	/// which is that with no space named nothing is converted anywhere, so a
	/// pass over footage is arithmetic on the code values that were shot.
	@Test func theUnmanagedPassLeavesEveryLevelWhereItWas() {
		#expect(worstError(working: NSNull(), destination: nil) == 0)
	}

	/// The contradiction that stood in the compositor for as long as the pass
	/// did: a destination space handed to a context that has management off.
	///
	/// It is ignored — the same ramp, the same zero, whichever of the two 709s
	/// is named or none at all. Harmless, and exactly the sort of harmless that
	/// becomes the bug on the day somebody turns the working space on and
	/// believes the argument beside it was measured.
	@Test func theDestinationIsIgnoredWhileManagementIsOff() {
		#expect(worstError(working: NSNull(), destination: Self.named709) == 0)
		#expect(worstError(working: NSNull(), destination: Self.sRGB) == 0)
	}

	/// Management on, landing where the frame came from: exact, every level.
	///
	/// This is the finding. A managed pass was believed to cost seven or eight
	/// levels and it costs nothing, in either of the two arrangements that name
	/// the right destination — Core Image's own linear working space, or the
	/// film's space used as its own working space.
	@Test func aManagedPassIsExactWhenItLandsWhereTheFrameCameFrom() throws {
		let arrivesIn = try #require(Self.arrivesIn)
		#expect(worstError(working: Self.linear, destination: arrivesIn) == 0)
		#expect(worstError(working: arrivesIn, destination: arrivesIn) == 0)
	}

	/// And where the seven or eight levels came from.
	///
	/// Both of these are what a person writes when they turn management on and
	/// reach for a name: sRGB, because that is what a colour space usually
	/// means, or `itur_709`, because the film is Rec. 709. Neither is the space
	/// the frame is in, and each lifts the picture — eleven levels and nineteen
	/// levels at worst, against zero for naming the right one. The eight levels
	/// somebody measured were this, not the cost of being managed.
	@Test func namingTheWrongSpaceIsWhatLiftedThePicture() {
		#expect(worstError(working: Self.linear, destination: Self.sRGB) >= 8)
		#expect(worstError(working: Self.linear, destination: Self.named709) >= 15)
	}

	/// What is actually blocking management from being turned on: not the
	/// footage, the paint.
	///
	/// A card's fill is a hex somebody typed, and Core Image reads a `CIColor`
	/// with no space on it as sRGB — so a managed pass converts it into the film
	/// and an unmanaged one writes it down as it stands. Measured on a rendered
	/// file, the Core Animation pass that draws a caption or a scene writes it
	/// down as it stands too: `#808080` came out at 127 as a scene's shape and
	/// at 127 as a card's fill, and the card went to 116 the moment the pass was
	/// made managed. The numbers here are one higher because they are the pass
	/// on its own; the rendered ones have an HEVC encode after them.
	///
	/// One hex, two colours in one film. So the footage round trip is not what
	/// this waits on — ``RGBA/ciColor`` naming the space it is in is, and the
	/// layer pass agreeing with it.
	@Test func aPaintedHexIsWhatManagementWouldMove() throws {
		let arrivesIn = try #require(Self.arrivesIn)
		#expect(painted(working: NSNull(), destination: nil) == 128)
		#expect(painted(working: arrivesIn, destination: arrivesIn) == 117)
	}
}
