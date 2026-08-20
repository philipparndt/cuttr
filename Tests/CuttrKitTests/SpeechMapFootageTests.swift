import Foundation
import Testing
@testable import CuttrKit

/// Refinement and handles, on the recording somebody actually complained about.
///
/// Off by default and not part of the suite, for the same reason the other
/// footage suites are: it needs minutes of somebody's video on an external disk
/// that cannot be in this repository. What it is for is the question the unit
/// tests cannot answer. Those prove the arithmetic on envelopes this file made
/// up; this one asks whether the numbers coming out of a real German take, from
/// a recorder eleven seconds out of step with the camera, are the ones somebody
/// would have placed by hand.
///
/// ```
/// CUTTR_FOOTAGE=/Volumes/500G/DorisWalter70/mia-take-1.cuttr \
///     xcrun swift test --filter SpeechMapFootageTests
/// ```
///
/// It prints its measurements. Every number in `docs/silence.md` came out of
/// here, and anybody doubting one can run it again.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CUTTR_FOOTAGE"] != nil))
struct SpeechMapFootageTests {

	private var takeURL: URL {
		URL(fileURLWithPath: ProcessInfo.processInfo.environment["CUTTR_FOOTAGE"]!)
	}

	/// The take, its words, and the envelope of whichever microphone was
	/// nearest — all on the video's clock.
	private func listen() async throws -> (
		take: Take, said: Transcript, wave: Waveform, map: SpeechMap, shift: Double
	) {
		let base = takeURL.deletingLastPathComponent()
		let take = try TakeReader.read(try String(contentsOf: takeURL, encoding: .utf8))
		let words = try #require(take.words, "this take has no transcript, so it is not the one")
		let said = Transcript.read(try String(
			contentsOf: URL(fileURLWithPath: words.path, relativeTo: base), encoding: .utf8))
		let audio = try #require(take.audio, "this take has no separate recorder, so it is not the one")
		let wave = try await WaveformExtractor.extract(
			url: URL(fileURLWithPath: audio.file, relativeTo: base))
		let shift = take.video == nil ? 0 : audio.offset
		return (take, said, wave, SpeechMap.of(wave, shift: shift), shift)
	}

	// MARK: - How far the marks moved

	/// Every line in the take, cut the way pressing Return on it would cut it,
	/// and the distribution of how far each mark had to move to land on the
	/// sound.
	///
	/// A distribution rather than an example, because one example proves
	/// nothing either way: the recogniser is sometimes early, sometimes late,
	/// and the interesting number is how often it is far enough out to hear.
	///
	/// Counted over the marks refinement had something to aim at. A line break
	/// in a transcript is not always a break in the sound — a full stop with
	/// nobody pausing is a new line and one continuous utterance — and a mark
	/// in the middle of a sentence has no moment the sound started to move to.
	/// Averaging those in would report the shape of the transcript rather than
	/// the accuracy of the word times.
	@Test func wordDerivedSpansMoveOntoTheSound() async throws {
		let (_, said, _, map, _) = try await listen()
		var heads: [Double] = []
		var tails: [Double] = []
		var headsAdrift = 0
		var tailsAdrift = 0
		for line in said.lines {
			guard let span = said.span(line) else { continue }
			let room = said.neighbours(of: span.start ... span.end)
			let cut = map.cut(from: span.start, to: span.end,
			                  after: room.before, before: room.after)
			if map.runs.contains(where: { near($0.lowerBound, cut.refined.lowerBound) }) {
				heads.append(cut.startMoved)
				if cut.startMoved != 0 { headsAdrift += 1 }
			}
			if map.runs.contains(where: { near($0.upperBound, cut.refined.upperBound) }) {
				tails.append(cut.endMoved)
				if cut.endMoved != 0 { tailsAdrift += 1 }
			}
		}

		print("\n\(said.lines.count) lines in the take")
		print("  \(heads.count) in marks put on the start of a sound, \(headsAdrift) of them adrift")
		print("  \(tails.count) out marks put on the end of one,      \(tailsAdrift) of them adrift")
		show("in  moved", heads)
		show("out moved", tails)
		show("in  moved, size", heads.map(abs))
		show("out moved, size", tails.map(abs))

		// The refinement is worth doing at all: most of the marks it could aim
		// were not already where the sound is.
		#expect(Double(headsAdrift) / Double(heads.count) > 0.5)
		// And it never reaches further than it said it would.
		#expect(heads.allSatisfy { abs($0) <= SpeechMap.reach + 1e-9 })
		#expect(tails.allSatisfy { abs($0) <= SpeechMap.reach + 1e-9 })
	}

	private func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

	/// Whether a refined cut is actually clipping anything.
	///
	/// The claim under test is the one that matters and the one nothing else
	/// checks: that the in mark is *before* the sound starts and the out mark
	/// is *after* the decay ends. So the envelope is sampled on the far side of
	/// each mark — the 50 ms the clip does not contain — and what is there
	/// should be room, not somebody talking.
	///
	/// The same measurement is taken at the unrefined word times beside it, and
	/// the difference between the two counts is the whole feature.
	@Test func aRefinedCutDoesNotClipTheWordOrItsDecay() async throws {
		let (_, said, wave, map, shift) = try await listen()
		let level = decibels(wave)
		let loud = percentile(level, 0.1) + 15   // SpeechEdges' own threshold

		/// The loudest thing in the window, in decibels, on the video's clock.
		func peak(from: Double, to: Double) -> Float {
			let a = Int(((from - shift) / SpeechEdges.step).rounded())
			let b = Int(((to - shift) / SpeechEdges.step).rounded())
			let range = max(0, a) ..< min(level.count, max(b, a + 1))
			guard !range.isEmpty else { return -120 }
			return level[range].max() ?? -120
		}

		var askedClipped = 0
		var refinedClipped = 0
		var counted = 0
		var worst = 0.0
		for line in said.lines {
			guard let span = said.span(line) else { continue }
			let room = said.neighbours(of: span.start ... span.end)
			let cut = map.cut(from: span.start, to: span.end,
			                  after: room.before, before: room.after)
			// Only the lines whose marks the refinement had an opinion about.
			// A mark left in the middle of a sentence is a hard cut by
			// construction and says nothing about whether this works.
			guard !map.isSpeaking(at: cut.refined.lowerBound),
			      !map.isSpeaking(at: cut.refined.upperBound) else { continue }
			counted += 1

			let outsideAsked = max(peak(from: cut.asked.lowerBound - 0.05, to: cut.asked.lowerBound),
			                       peak(from: cut.asked.upperBound, to: cut.asked.upperBound + 0.05))
			let outsideRefined = max(
				peak(from: cut.refined.lowerBound - 0.05, to: cut.refined.lowerBound),
				peak(from: cut.refined.upperBound, to: cut.refined.upperBound + 0.05))
			if outsideAsked > loud { askedClipped += 1 }
			if outsideRefined > loud {
				refinedClipped += 1
				worst = max(worst, Double(outsideRefined - loud))
			}
		}

		print("\n\(counted) lines whose marks landed in the quiet")
		print(String(format: "  speech left outside the mark at the word times: %d (%.1f%%)",
		             askedClipped, 100 * Double(askedClipped) / Double(counted)))
		print(String(format: "  speech left outside the mark once refined:      %d (%.1f%%)",
		             refinedClipped, 100 * Double(refinedClipped) / Double(counted)))
		if refinedClipped > 0 {
			print(String(format: "  worst of those, over the talking threshold:     %.1f dB", worst))
		}

		// It has to be an improvement, and a large one.
		#expect(refinedClipped < askedClipped)
		#expect(Double(refinedClipped) / Double(counted) < 0.05)
	}

	// MARK: - The air between two clips

	/// Two clips made from adjacent sentences: how much air is at the join.
	///
	/// The complaint in one number — but not the number it looks like. The gap
	/// *between* two clips is the wrong thing to measure, and measuring it was
	/// this test's first mistake: with handles the air is inside the clips, so
	/// two clips that share a short pause fairly meet exactly and the gap
	/// between them is zero. What somebody hears when the two are butted
	/// together is the silence the first one carries after its last word plus
	/// the silence the second carries before its first, and that is what is
	/// counted here.
	///
	/// Measured against the recording rather than against the refined marks:
	/// where the recogniser is out by more than refinement can reach, a mark it
	/// left alone is not where the sound is, and taking it for the sound would
	/// flatter this feature by pretending the words were tight to begin with.
	@Test func twoAdjacentSentencesAreNotGluedTogether() async throws {
		let (_, said, _, map, _) = try await listen()
		let lines = said.lines

		/// The silence a clip carries after its last sound, and before its
		/// first. Nothing at all when the mark is in the middle of a word,
		/// which is the case that sounds clipped.
		func trailingAir(_ end: Double) -> Double {
			guard !map.isSpeaking(at: end) else { return 0 }
			guard let sound = map.runs.last(where: { $0.upperBound <= end }) else { return 0 }
			return end - sound.upperBound
		}
		func leadingAir(_ start: Double) -> Double {
			guard !map.isSpeaking(at: start) else { return 0 }
			guard let sound = map.runs.first(where: { $0.lowerBound >= start }) else { return 0 }
			return sound.lowerBound - start
		}

		var before: [Double] = []
		var after: [Double] = []
		var noAirToBeHad = 0
		var overlaps = 0
		var wordsShared = 0
		for index in 0 ..< max(0, lines.count - 1) {
			guard let first = said.span(lines[index]),
			      let second = said.span(lines[index + 1]) else { continue }
			let firstRoom = said.neighbours(of: first.start ... first.end)
			let secondRoom = said.neighbours(of: second.start ... second.end)
			let a = map.cut(from: first.start, to: first.end,
			                after: firstRoom.before, before: firstRoom.after)
			let b = map.cut(from: second.start, to: second.end,
			                after: secondRoom.before, before: secondRoom.after)
			before.append(trailingAir(a.asked.upperBound) + leadingAir(b.asked.lowerBound))
			after.append(trailingAir(a.span.upperBound) + leadingAir(b.span.lowerBound))
			// One continuous utterance with a full stop written into the middle
			// of it: there is no pause here to share, and taking one would mean
			// taking somebody's voice.
			if after.last! < 0.04,
			   map.isSpeaking(at: a.span.upperBound) || map.isSpeaking(at: b.span.lowerBound) {
				noAirToBeHad += 1
			}
			if b.span.lowerBound < a.span.upperBound {
				overlaps += 1
				// Whatever they share had better be silence: the guarantee that
				// holds whichever half of a pause the marks fell into.
				let shared = b.span.lowerBound ... a.span.upperBound
				if map.runs.contains(where: {
					$0.lowerBound < shared.upperBound && $0.upperBound > shared.lowerBound
				}) { wordsShared += 1 }
			}
		}

		print("\n\(before.count) adjacent pairs of lines")
		show("air at the join, words", before)
		show("air at the join, cut  ", after)
		let airless = after.filter { $0 < 0.04 }.count
		print(String(format: "  joins with under 40 ms of air: %d at the word times, %d once cut",
		             before.filter { $0 < 0.04 }.count, airless))
		print("  of those \(airless), with somebody still talking at the join: \(noAirToBeHad)")
		print("  pairs whose spans overlap: \(overlaps), of which sharing any speech: \(wordsShared)")

		// The point of the exercise. Fewer joins with no air in them — and
		// every one that is left is a join where somebody is still talking, so
		// there was never any air there to give it.
		#expect(airless < before.filter { $0 < 0.04 }.count)
		#expect(noAirToBeHad == airless)
		// And more air at the ordinary join, which is the complaint itself.
		#expect(median(after) > median(before))
		// And the guarantee that holds unconditionally.
		#expect(wordsShared == 0)
	}

	// MARK: - The case with nothing to give

	/// Somebody talking straight through, which is the case that decides
	/// whether any of this can be trusted.
	///
	/// A run of words taken out of the middle of the longest unbroken stretch
	/// of talking in the take. There is no silence at either end of it, so
	/// there is no air to be had — and the right answer is to give none rather
	/// than to take a quarter of a second of somebody's sentence.
	@Test func talkingStraightThroughGetsNoHandles() async throws {
		let (_, said, _, map, _) = try await listen()
		let longest = try #require(map.runs.max { ($0.upperBound - $0.lowerBound)
			< ($1.upperBound - $1.lowerBound) })
		let inside = said.indices(in: longest)
		// Well inside it, so both marks are surrounded by talking.
		guard inside.count >= 6 else {
			Issue.record("the longest run has only \(inside.count) words in it")
			return
		}
		let picked = (inside.lowerBound + 2) ..< (inside.upperBound - 2)
		let span = try #require(said.span(picked))
		let room = said.neighbours(of: span.start ... span.end)
		let cut = map.cut(from: span.start, to: span.end,
		                  after: room.before, before: room.after)

		print(String(format: "\nlongest unbroken run: %@ to %@ (%.3f s), %d words",
		             Timecode.string(longest.lowerBound), Timecode.string(longest.upperBound),
		             longest.upperBound - longest.lowerBound, inside.count))
		print("  " + said.phrase(picked, limit: 12))
		print(String(format: "  asked   %@ \u{2192} %@",
		             Timecode.string(cut.asked.lowerBound), Timecode.string(cut.asked.upperBound)))
		print(String(format: "  refined %@ \u{2192} %@   in %+.3f s, out %+.3f s",
		             Timecode.string(cut.refined.lowerBound), Timecode.string(cut.refined.upperBound),
		             cut.startMoved, cut.endMoved))
		print(String(format: "  cut     %@ \u{2192} %@   air %.3f s and %.3f s",
		             Timecode.string(cut.span.lowerBound), Timecode.string(cut.span.upperBound),
		             cut.startHandle, cut.endHandle))

		#expect(map.isSpeaking(at: cut.refined.lowerBound))
		#expect(map.isSpeaking(at: cut.refined.upperBound))
		#expect(cut.startHandle == 0)
		#expect(cut.endHandle == 0)
		#expect(cut.quietBefore == 0)
		#expect(cut.quietAfter == 0)
		// Nothing was invented, so the clip is what the words said it was.
		#expect(cut.span == cut.asked)
	}

	// MARK: - Saying what was found

	private func show(_ name: String, _ values: [Double]) {
		guard !values.isEmpty else { return }
		let sorted = values.sorted()
		func at(_ fraction: Double) -> Double {
			sorted[Int((Double(sorted.count - 1) * fraction).rounded())]
		}
		print(String(format: "  %@  min %+.3f  p10 %+.3f  median %+.3f  p90 %+.3f  max %+.3f  mean %+.3f",
		             name.padding(toLength: 22, withPad: " ", startingAt: 0),
		             sorted.first!, at(0.1), at(0.5), at(0.9), sorted.last!,
		             values.reduce(0, +) / Double(values.count)))
	}

	private func median(_ values: [Double]) -> Double {
		let sorted = values.sorted()
		return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
	}

	private func decibels(_ wave: Waveform) -> [Float] {
		wave.envelope(ratePerSecond: 1 / SpeechEdges.step).map { 20 * log10f(max($0, 1e-6)) }
	}

	private func percentile(_ values: [Float], _ fraction: Double) -> Float {
		let sorted = values.sorted()
		return sorted[Int((Double(sorted.count - 1) * fraction).rounded())]
	}
}
