import CoreImage
import CuttrKit
import Foundation
import Testing
@testable import CuttrCompose

/// Two effects, in the two orders, and the difference between them.
///
/// This is the test the whole arrangement exists for. "Within the film mode"
/// and "above the film mode" are the same two overlays written the other way
/// round, and if the drawing order did not follow the list there would be no
/// way to ask for one rather than the other.
@Suite struct StackingTests {

	private let pixels = FramePixels()

	private func work(_ overlays: [Overlay]) -> ProgrammeCompositor.Work {
		ProgrammeCompositor.Work(
			size: pixels.size, project: Project(overlays: overlays),
			baseURL: URL(fileURLWithPath: "/"),
			overlays: overlays.enumerated().map { index, overlay in
				ResolvedOverlay(overlay: overlay, origin: .project(index), appearance: 0,
				                start: 0, end: 10, path: nil)
			},
			effects: [], people: nil)
	}

	private func drawn(_ overlays: [Overlay], over picture: CIImage) -> CIImage {
		Frame.overlays(over: picture, at: 5, size: pixels.size, work: work(overlays))
	}

	/// A film overlay and an aberration, both ways round.
	///
	/// The bars are what tells them apart. Written after the aberration they
	/// are laid on last and are clean black; written before it they are part of
	/// the picture the lens is looking at, so the edge of the bar comes apart
	/// into its colours like any other edge.
	@Test func theOrderInTheListIsTheOrderTheyAreDrawn() {
		let span = Overlay.Span.times(from: 0, to: 10)
		let film = Overlay(
			kind: .film(Film(ratio: Film.Ratio(2.39, 1), tint: .none,
			                 strength: 0, grain: 0, vignette: 0)),
			span: span, arrival: .cut, departure: .cut)
		let lens = Overlay(kind: .aberration(Aberration(kind: .radial, amount: 6)),
		                   span: span, arrival: .cut, departure: .cut)
		let picture = pixels.flat(1)

		let inside = drawn([lens, film], over: picture)     // the lens, then the film
		let above = drawn([film, lens], over: picture)      // the film, then the lens

		// Where the bar ends and the picture begins, near enough.
		let boundary = Int(Film(ratio: Film.Ratio(2.39, 1)).bars(in: pixels.size).vertical
			* Double(pixels.size.height))
		#expect(boundary > 10)

		func fringed(_ image: CIImage) -> Bool {
			(0..<20).contains { step in
				let sample = pixels.pixel(image, x: 160, y: boundary - 10 + step)
				return abs(sample.r - sample.b) > 0.1
			}
		}
		#expect(!fringed(inside), "the lens ran before the bars, so they should be clean")
		#expect(fringed(above), "the lens ran after the bars and should have taken them apart")

		// Inside the bar, in the order that puts the bars last, it is black —
		// nothing has been laid over it and nothing pulled out of it.
		let inBar = pixels.pixel(inside, x: 160, y: 4)
		#expect(inBar.r < 0.02 && inBar.g < 0.02 && inBar.b < 0.02, "\(inBar)")

		// And the two frames are not the same frame, which is the plain
		// statement of the whole thing.
		#expect(pixels.bytes(inside) != pixels.bytes(above))
	}

	/// The same, with the tape: written over the film it marks the bars,
	/// written under it cannot.
	///
	/// A dropout is a white streak laid on the picture. Under the film overlay
	/// the bars are laid on afterwards and cover every one of them, so the bars
	/// stay perfectly black however many fields go by; over it the streaks land
	/// on the bars, which is what "the VHS is on top of the film" looks like.
	@Test func theTapeIsOverOrUnderTheFilmDependingOnWhereItIsWritten() {
		let span = Overlay.Span.times(from: 0, to: 10)
		let film = Overlay(
			kind: .film(Film(ratio: Film.Ratio(2.39, 1), tint: .none,
			                 strength: 0, grain: 0, vignette: 0)),
			span: span, arrival: .cut, departure: .cut)
		var chewed = Tape(.chewed)
		chewed.jitter = 0; chewed.band = 0; chewed.chroma = 0; chewed.scanlines = 0
		chewed.dropouts = 1
		let tape = Overlay(kind: .tape(chewed), span: span, arrival: .cut, departure: .cut)
		let picture = pixels.flat(0.5)
		let bar = Int(Film(ratio: Film.Ratio(2.39, 1)).bars(in: pixels.size).vertical
			* Double(pixels.size.height)) - 2
		#expect(bar > 8, "there should be a bar to measure: \(bar)")

		/// How many fields out of forty put something bright in the bars.
		func marked(_ order: [Overlay]) -> Int {
			var fields = 0
			for field in 0..<40 {
				let time = Double(field) / 30 + 0.001
				let frame = pixels.map(Frame.overlays(
					over: picture, at: time, size: pixels.size, work: work(order)))
				let lit = (0..<bar).contains { row in
					(0..<Int(pixels.size.width)).contains { frame[$0, row].g > 0.2 }
				}
				if lit { fields += 1 }
			}
			return fields
		}

		#expect(marked([tape, film]) == 0, "the bars were laid on last and should be clean")
		#expect(marked([film, tape]) > 3, "the tape was laid on last and should have marked them")
	}

	/// Every kind that is the frame has to be known to the two places that ask
	/// "is there anything to do here" — or a programme with one on it takes the
	/// path that does nothing at all, and the effect never appears.
	@Test func everyFrameKindIsKnownToTheTestsThatSkipWork() {
		let span = Overlay.Span.times(from: 0, to: 10)
		let kinds: [Overlay.Kind] = [
			.film(Film()), .aberration(Aberration()), .tape(Tape()),
		]
		for kind in kinds {
			let overlay = Overlay(kind: kind, span: span, arrival: .cut, departure: .cut)
			#expect(kind.changesTheFrame, "\(kind) does not say it is the frame")
			#expect(!OverlayLayers.isLayered(overlay), "\(kind) would be drawn twice")
			#expect(work([overlay]).busy(at: 5), "\(kind) would be skipped by the exact path")
			#expect(!work([overlay]).busy(at: 20), "and it is not on outside its own span")
		}
		// A caption is the other way round on both counts.
		let caption = Overlay(kind: .text("hello", style: nil), span: span)
		#expect(!caption.kind.changesTheFrame)
		#expect(OverlayLayers.isLayered(caption))
	}
}
