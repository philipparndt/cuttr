import AVFoundation
import CoreImage
import CuttrKit
import Foundation
import Testing
@testable import CuttrCompose

/// Where a movement sits against the mark, measured in pixels.
///
/// Film mode is the one to measure it with: it is the frame itself, and its
/// grade mixes in straight in proportion to how far into the mode the programme
/// is. A black-and-white stock over a red card is therefore one subtraction away
/// from a number — the colour left in the middle of the frame — so "half way
/// through the transition when the clip starts" becomes a claim about a pixel
/// rather than about a model. Which is the point: the frame path and the layer
/// path have to agree about when an overlay is drawn, and the only way to know
/// they do is to look.
@Suite struct OverlayPlacementTests {

	private let pixels = FramePixels()

	/// Film mode over a card, on from two seconds to six, arriving and leaving
	/// however the caller says.
	///
	/// Written as a file and resolved rather than built by hand, so the spelling
	/// under test is the one somebody types. The card's own colour never comes
	/// into it: the picture handed to the frame path below is supplied here, so
	/// there is one flat field and nothing else in the measurement.
	private func work(_ transitions: String) throws -> ProgrammeCompositor.Work {
		let project = try ProjectReader.read("""
			output:
			  size: 320x180
			  fps:  25

			timeline:
			  - card: 00:08.000

			overlays:
			  - film:   noir
			    ratio:  16:9
			    strength: 1
			    grain:  0
			    vignette: 0
			    from:   00:02.000
			    to:     00:06.000
			\(transitions)
			""")
		let resolved = try Resolver.resolve(project, baseURL: URL(fileURLWithPath: "/"))
		// The span is what the file says, whatever the placements are. A
		// placement that quietly widened it would be a file that no longer meant
		// what it said, and this is the assertion that says so.
		#expect(resolved.overlays.count == 1)
		#expect(resolved.overlays.first?.start == 2)
		#expect(resolved.overlays.first?.end == 6)
		return ProgrammeCompositor.Work(
			size: pixels.size, project: project, baseURL: URL(fileURLWithPath: "/"),
			overlays: resolved.overlays, effects: [], people: nil)
	}

	/// A flat red card: nothing but colour to lose.
	private var card: CIImage {
		CIImage(color: CIColor(red: 0.85, green: 0.1, blue: 0.1)).cropped(to: pixels.frame)
	}

	/// How much colour is left in the middle of the frame at a moment.
	private func colour(_ work: ProgrammeCompositor.Work, at time: Double) -> Double {
		let out = Frame.overlays(over: card, at: time, size: pixels.size, work: work)
		let sample = pixels.pixel(out, x: 160, y: 90)
		return sample.r - sample.b
	}

	/// How far into film mode the programme is at a moment, nought to one.
	///
	/// Measured rather than asked for: the colour that is left, against the
	/// colour on a frame the mode is nowhere near and the colour on one it has
	/// settled on. Nought is the card as it was painted and one is black and
	/// white, whatever the stock happens to do in between.
	private func graded(_ work: ProgrammeCompositor.Work, at time: Double) -> Double {
		let plain = colour(work, at: 0)
		let settled = colour(work, at: 4)
		#expect(plain - settled > 0.3, "the stock has to take enough colour out to measure")
		return (plain - colour(work, at: time)) / (plain - settled)
	}

	// MARK: - The first mark

	/// The default, and the one that matters most: nothing has changed.
	///
	/// A file that says nothing about placement gets what this program has always
	/// done — the movement is taken from inside the span, so the clip's first
	/// frame is ungraded and the grade arrives over the second after it.
	@Test func byDefaultTheMovementStartsAtTheMark() throws {
		let work = try work("""
			    in:     {fade: true, over: 1}
			    out:    cut
			""")
		#expect(graded(work, at: 1.5) == 0, "nothing before the clip")
		#expect(graded(work, at: 2) == 0, "the clip's first frame is ungraded")
		#expect(abs(graded(work, at: 2.5) - 0.5) < 0.1, "half a second in")
		#expect(graded(work, at: 3) > 0.95, "a second in, and settled")
	}

	/// Finished when the clip starts, which means it started before it.
	@Test func placedBeforeTheMarkItIsFinishedWhenTheClipStarts() throws {
		let work = try work("""
			    in:     {fade: true, over: 1, at: before}
			    out:    cut
			""")
		#expect(graded(work, at: 2) > 0.95, "the clip's first frame is already fully graded")
		// And some frames before it are partly graded, which is the whole of
		// what "before the mark" buys.
		#expect(abs(graded(work, at: 1.5) - 0.5) < 0.1, "half way, half a second early")
		#expect(graded(work, at: 1.25) > 0.1, "a quarter in")
		#expect(graded(work, at: 0.9) == 0, "and nothing at all before the movement begins")
	}

	/// Half through when the clip starts.
	@Test func placedAcrossTheMarkItIsHalfThroughWhenTheClipStarts() throws {
		let work = try work("""
			    in:     {fade: true, over: 1, at: across}
			    out:    cut
			""")
		#expect(abs(graded(work, at: 2) - 0.5) < 0.1,
		        "at the clip's first frame it measures about half of what it settles at")
		#expect(graded(work, at: 1.75) > 0.1, "and it had started before the clip")
		#expect(graded(work, at: 1.4) == 0)
		#expect(graded(work, at: 2.5) > 0.95, "settled half a second in")
	}

	// MARK: - The last mark

	/// The default at the other end: it has finished leaving by the last frame.
	@Test func byDefaultTheMovementFinishesAtTheMark() throws {
		let work = try work("""
			    in:     cut
			    out:    {fade: true, over: 1}
			""")
		#expect(abs(graded(work, at: 5.5) - 0.5) < 0.1, "half way out")
		#expect(graded(work, at: 6) == 0, "gone by the last frame")
		#expect(graded(work, at: 6.5) == 0, "and nothing after the clip")
	}

	@Test func placedAcrossTheMarkItIsHalfThroughWhenTheClipEnds() throws {
		let work = try work("""
			    in:     cut
			    out:    {fade: true, over: 1, at: across}
			""")
		#expect(abs(graded(work, at: 6) - 0.5) < 0.1,
		        "at the clip's last frame it measures about half")
		#expect(graded(work, at: 6.25) > 0.1, "still going after the clip")
		#expect(graded(work, at: 6.6) == 0)
	}

	@Test func placedAfterTheMarkItOnlyStartsLeavingAtTheEnd() throws {
		let work = try work("""
			    in:     cut
			    out:    {fade: true, over: 1, at: after}
			""")
		#expect(graded(work, at: 6) > 0.95, "the clip's last frame is still fully graded")
		#expect(abs(graded(work, at: 6.5) - 0.5) < 0.1, "half way out, half a second late")
		#expect(graded(work, at: 7) == 0, "and gone a second after the clip")
	}

	// MARK: - A cut

	/// A cut has no length, so there is nothing to place — and asking for a
	/// placement on one changes nothing rather than changing something odd.
	@Test func aCutIsUnaffectedByAnyOfThis() throws {
		for placement in ["before", "across", "after"] {
			let work = try work("""
				    in:     {fade: false, at: \(placement)}
				    out:    {fade: false, at: \(placement)}
				""")
			#expect(graded(work, at: 1.96) == 0, "\(placement): nothing before the mark")
			#expect(graded(work, at: 2) > 0.95,
			        "\(placement): the whole grade on the first frame")
			#expect(graded(work, at: 5.96) > 0.95,
			        "\(placement): and still all of it on the last")
			#expect(graded(work, at: 6.04) == 0, "\(placement): gone after it")
		}
	}

	// MARK: - What the numbers say

	/// Two overlays that meet, and what a placement does to the crossing.
	///
	/// This is the case the transitions were designed around, so it is worth
	/// saying plainly what changes. By default the two movements butt up against
	/// the shared mark from opposite sides and each is half done a fifth of a
	/// second either side of it. Place the second one's arrival `before` the mark
	/// and the two movements sit on top of each other in the seconds leading up
	/// to it: they overlap on purpose, both half done at the same instant, which
	/// is a dissolve from one overlay to the other rather than a hand-off at a
	/// line. Neither span moved, so the file still says which belongs where.
	@Test func twoOverlaysThatMeetCrossWhereThePlacementPutsThem() {
		func timing(
			from: Double, to: Double,
			arrivalAt: Overlay.Transition.Placement = .after,
			departureAt: Overlay.Transition.Placement = .before
		) -> OverlayTiming {
			OverlayTiming(span: from, to: to,
			              arrival: .fade(over: 0.4), arrivalAt: arrivalAt,
			              departure: .fade(over: 0.4), departureAt: departureAt)
		}

		func half(_ value: Double) -> Bool { abs(value - 0.5) < 0.001 }

		let first = timing(from: 0, to: 4)
		let second = timing(from: 4, to: 8)
		// Butted: the first is still going out where the second has not started.
		#expect(half(first.envelope(at: 3.8)))
		#expect(second.envelope(at: 3.8) == 0)
		#expect(first.envelope(at: 4.2) == 0)
		#expect(half(second.envelope(at: 4.2)))

		// Placed before the mark, the second overlay's arrival lies exactly on
		// top of the first one's departure.
		let early = timing(from: 4, to: 8, arrivalAt: .before)
		#expect(abs(early.drawnFrom - 3.6) < 0.001)
		#expect(half(first.envelope(at: 3.8)))
		#expect(half(early.envelope(at: 3.8)))
		#expect(early.envelope(at: 4) == 1, "and it is fully on for the mark")
		// The span is untouched by all of it.
		#expect(early.start == 4 && early.end == 8)
	}

	/// A movement longer than the overlay can afford.
	///
	/// The old rule was "no longer than half the span", which is what stops the
	/// arrival and the departure of a short overlay crossing in the middle of it.
	/// It still holds for the part that lands inside the span, and a movement
	/// placed wholly outside is not clamped at all — it is not competing for
	/// anything.
	@Test func onlyThePartInsideTheSpanIsClamped() {
		func window(_ at: Overlay.Transition.Placement) -> OverlayTiming {
			OverlayTiming(span: 0, to: 1, arrival: .fade(over: 4), arrivalAt: at,
			              departure: .cut, departureAt: .before)
		}
		// Inside: half a second of a four-second fade, exactly as before.
		#expect(window(.after).arriveTo == 0.5)
		#expect(window(.after).drawnFrom == 0)
		// Across: half of it inside, so the inside half is still half the span.
		#expect(window(.across).arriveFrom == -0.5)
		#expect(window(.across).arriveTo == 0.5)
		// Before: none of it inside, so the file gets the four seconds it asked
		// for and the overlay is on screen for all of them.
		#expect(window(.before).arriveFrom == -4)
		#expect(window(.before).arriveTo == 0)
		#expect(window(.before).drawnFrom == -4)
	}

	/// Keys move with the span, not with the drawing.
	///
	/// `t` is seconds from the start of the appearance and the appearance is what
	/// the file says: `from:` and `to:`. If a key moved with the drawn window
	/// instead, adding `at: before` to an `in:` would shift every key in the
	/// overlay by the length of the fade — a one-word edit that silently
	/// re-times the whole animation. So the pre-roll holds the first key's value,
	/// which is what a track does for any `t` below its first key, and the key at
	/// `t: 0` still lands on the mark.
	@Test func aPlacementMovesNoKey() throws {
		let project = try ProjectReader.read("""
			timeline:
			  - card: 00:08.000
			overlays:
			  - aberration: radial
			    amount: 0.2
			    from:   00:02.000
			    to:     00:06.000
			    in:     {fade: true, over: 1, at: before}
			    keys:
			      - {t: 0}
			      - {t: 2, amount: 1.2}
			""")
		guard let overlay = project.overlays.first else {
			Issue.record("the overlay did not come back")
			return
		}
		func amount(_ t: Double) -> Double {
			guard case .aberration(let aberration) = overlay.kind(at: t) else { return -1 }
			return aberration.amount
		}
		// At the mark, which is `t: 0`, the overlay's own value — unmoved by the
		// placement in front of it.
		#expect(abs(amount(0) - 0.2) < 0.001)
		// Over the second before the mark, `t` is negative and the track holds.
		#expect(abs(amount(-0.5) - 0.2) < 0.001)
		// And the key two seconds in is still two seconds in.
		#expect(abs(amount(2) - 1.2) < 0.001)
	}

	// MARK: - Through the encoder

	/// The same claim, in a file that has been written and read back.
	///
	/// ``Frame`` is asked for a frame directly above, which is the honest way to
	/// measure the grade but leaves out the gate in front of it: the compositor
	/// asks ``ProgrammeCompositor/Work/busy(at:)`` whether anything is happening
	/// at all and hands the source frame straight back when nothing is. That gate
	/// used to ask the span. A film overlay whose arrival is placed before its
	/// first mark would then have been graded by the frame path and thrown away
	/// by the gate — an export that came out right in the preview and wrong in
	/// the file, which is the class of bug this whole area keeps producing.
	@Test func aGradePlacedBeforeTheMarkSurvivesTheEncoder() async throws {
		let directory = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("cuttr-placement-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		let project = try ProjectReader.read("""
			output:
			  size: 320x180
			  fps:  25
			  file: placement.mov

			timeline:
			  - card: 00:03.000
			    fill: "#d92020"

			overlays:
			  - film:   noir
			    ratio:  16:9
			    strength: 1
			    grain:  0
			    vignette: 0
			    from:   00:01.000
			    to:     00:02.000
			    in:     {fade: true, over: 0.4, at: before}
			    out:    cut
			""")
		let url = directory.appendingPathComponent("placement.mov")
		try await Renderer.export(try Resolver.resolve(project, baseURL: directory), to: url)

		let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
		generator.requestedTimeToleranceBefore = .zero
		generator.requestedTimeToleranceAfter = .zero
		func colour(at seconds: Double) async throws -> Double {
			let image = try await generator.image(
				at: CMTime(seconds: seconds, preferredTimescale: 600)).image
			var bytes = [UInt8](repeating: 0, count: 4)
			let context = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8,
			                        bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
			                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
			// One pixel out of the middle of the frame.
			context.draw(image, in: CGRect(x: -160, y: -90,
			                               width: image.width, height: image.height))
			return (Double(bytes[0]) - Double(bytes[2])) / 255
		}

		let plain = try await colour(at: 0.4)
		#expect(plain > 0.3, "the card should be red before anything happens to it: \(plain)")
		// The movement runs from 0.6 to the mark at 1.0.
		let early = try await colour(at: 0.8)
		#expect(early < plain * 0.75, "half way through, half a second early: \(early)")
		#expect(early > plain * 0.15, "and only half way")
		let atTheMark = try await colour(at: 1)
		#expect(atTheMark < plain * 0.2, "black and white for the clip's first frame: \(atTheMark)")
		let after = try await colour(at: 2.4)
		#expect(abs(after - plain) < 0.05, "and the card is itself again after the span")
	}

	/// An effect that runs out, placed after the mark.
	///
	/// `fall` means "stop letting pieces go", so where the movement sits decides
	/// when the tap is turned off — and placed after the mark the shower is fed
	/// right up to the end of the span and empties itself in the seconds beyond
	/// it, which is a thing no spelling could ask for before.
	@Test func aFallPlacedAfterTheMarkEmptiesBeyondTheSpan() {
		let inside = OverlayTiming(span: 0, to: 4, arrival: .cut, arrivalAt: .after,
		                           departure: .fall(over: 1), departureAt: .before)
		#expect(inside.drawnUntil == 4, "by default nothing is drawn past the span")
		#expect(inside.spawningUntil == 3, "and the tap goes off a second before the end")

		let beyond = OverlayTiming(span: 0, to: 4, arrival: .cut, arrivalAt: .after,
		                           departure: .fall(over: 1), departureAt: .after)
		#expect(beyond.drawnUntil == 5, "the cloud is drawn while it empties")
		#expect(beyond.spawningUntil == 4, "fed to the last frame of the span")
	}
}

/// `at:`, in the file.
///
/// The project file is the product, so what these ask is not that the value
/// survives but that the bytes do — and, first of all, that a project which
/// says nothing about placement comes out exactly as it went in.
@Suite struct OverlayPlacementFileTests {

	private func project(
		_ arrival: Overlay.Transition, at arrivalAt: Overlay.Transition.Placement,
		_ departure: Overlay.Transition, at departureAt: Overlay.Transition.Placement
	) -> Project {
		Project(
			timeline: [TimelineEntry(clip: ClipReference("intro"))],
			overlays: [Overlay(
				kind: .text("hello", style: nil),
				span: .clips(from: ClipReference("intro"), to: ClipReference("intro")),
				arrival: arrival, departure: departure,
				arrivalPlacement: arrivalAt, departurePlacement: departureAt)])
	}

	/// The line an overlay with nothing to say about placement writes, which is
	/// the line it wrote before there was anything to say.
	@Test func aProjectThatPlacesNothingWritesWhatItAlwaysWrote() {
		let text = ProjectWriter.write(project(.slide(.left, over: 0.4), at: .after,
		                                       .slide(.right, over: 0.4), at: .before))
		#expect(text.contains("  in:     {slide: left, over: 0.4}\n"))
		#expect(text.contains("  out:    {slide: right, over: 0.4}\n"))
		#expect(!text.contains("at:"), "there was nothing to place, so nothing is written")
	}

	@Test func everyPlacementSurvivesTheFileByteForByte() throws {
		let kinds: [Overlay.Transition] = [
			.fade(over: 0.4), .slide(.up, over: 0.6), .fall(over: 1.5),
		]
		for placement in Overlay.Transition.Placement.allCases {
			for kind in kinds {
				let one = project(kind, at: placement, kind, at: placement)
				let text = ProjectWriter.write(one)
				let back = try ProjectReader.read(text)
				#expect(back.overlays == one.overlays,
				        "\(kind) at \(placement) did not come back")
				#expect(ProjectWriter.write(back) == text,
				        "\(kind) at \(placement) was rewritten by a round trip")
				// Written only where it is not the default — and because the
				// default is a different word at the two ends, the same
				// placement on both is written once at one end and twice when
				// it is the word neither end defaults to.
				let written = text.components(separatedBy: ", at: \(placement.rawValue)}").count - 1
				#expect(written == (placement == .across ? 2 : 1),
				        "\(kind) at \(placement) wrote it \(written) times:\n\(text)")
			}
		}
	}

	/// `{fade: true, over: 0.4, at: before}` is the shape, and the three keys
	/// answer three questions: how, how long, and where.
	@Test func theSpellingReadsAsThreeKeys() throws {
		let read = try ProjectReader.read("""
			timeline:
			  - clip: intro
			overlays:
			  - text:   hello
			    from:   intro
			    in:     {fade: true, over: 0.4, at: before}
			    out:    {slide: right, over: 0.5, at: across}
			""")
		#expect(read.overlays.first?.arrival == .fade(over: 0.4))
		#expect(read.overlays.first?.arrivalPlacement == .before)
		#expect(read.overlays.first?.departure == .slide(.right, over: 0.5))
		#expect(read.overlays.first?.departurePlacement == .across)
	}

	/// A cut has no length, so a placement on one is read and dropped rather
	/// than kept as a value nothing could ever act on — and the file it writes
	/// back is the file a cut has always written.
	@Test func aCutKeepsNoPlacement() throws {
		let read = try ProjectReader.read("""
			timeline:
			  - clip: intro
			overlays:
			  - text:   hello
			    from:   intro
			    in:     {fade: false, at: before}
			    out:    {at: after}
			""")
		#expect(read.overlays.first?.arrival == .cut)
		#expect(read.overlays.first?.arrivalPlacement == .after)
		#expect(read.overlays.first?.departure == .cut)
		#expect(read.overlays.first?.departurePlacement == .before)
		let text = ProjectWriter.write(read)
		#expect(text.contains("  in:     cut\n"))
		#expect(text.contains("  out:    cut\n"))
	}

	/// A word nobody has heard of is refused by name. An `at:` that silently did
	/// nothing would look exactly like an `at:` that worked.
	@Test func aPlacementNobodyRecognisesIsRefused() {
		#expect(throws: (any Error).self) {
			try ProjectReader.read("""
				timeline:
				  - clip: intro
				overlays:
				  - text:   hello
				    from:   intro
				    in:     {fade: true, over: 0.4, at: middle}
				""")
		}
	}

	/// A bubble takes it too, and it is one of the kinds somebody will want it
	/// on: words that have to be read need to be up and still before the frame
	/// they are read on, not arriving over it.
	@Test func aBubbleTakesAPlacement() throws {
		let read = try ProjectReader.read("""
			timeline:
			  - clip: intro
			overlays:
			  - bubble: still thinks glitter is a colour
			    from:   intro
			    in:     {fade: true, over: 0.3, at: before}
			""")
		#expect(read.overlays.first?.arrivalPlacement == .before)
		// And its own default departure — a fade, because a bubble that slid out
		// would swing its tail across the frame on the way — is untouched.
		#expect(read.overlays.first?.departure == .fade(over: 0.2))
		#expect(read.overlays.first?.departurePlacement == .before)
		let text = ProjectWriter.write(read)
		#expect(ProjectWriter.write(try ProjectReader.read(text)) == text)
	}
}
