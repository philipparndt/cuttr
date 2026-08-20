import Foundation
import Testing
@testable import CuttrKit

/// The arithmetic behind an automatic pass, on numbers with known answers.
///
/// Deliberately synthetic. Whether mel cepstra separate a child from her
/// grandmother is a question for a real recording and a hand-labelled file —
/// see `docs/speakers.md`. Whether k-means finds two clumps that are plainly
/// two clumps is a question with an answer, and it is the half that can go
/// silently wrong in a way nobody notices until the colours are already on the
/// screen.
@Suite struct SpeakerClusteringTests {

	/// Two clumps a long way apart, interleaved the way an interview is.
	private func twoVoices() -> [[Double]] {
		var out: [[Double]] = []
		for index in 0 ..< 20 {
			let nudge: Double = Double(index) * 0.01
			if index % 2 == 0 {
				out.append([10 + nudge, 10, 10])
			} else {
				out.append([-10, -10 - nudge, -10])
			}
		}
		return out
	}

	@Test func twoClumpsComeBackAsTwoClumps() {
		let grouping = SpeakerClustering.cluster(twoVoices(), into: 2)
		#expect(Set(grouping.labels).count == 2)
		// Alternating, and every even index agrees with every other even one.
		let evens = Set(grouping.labels.enumerated().filter { $0.offset % 2 == 0 }.map(\.element))
		let odds = Set(grouping.labels.enumerated().filter { $0.offset % 2 == 1 }.map(\.element))
		#expect(evens.count == 1)
		#expect(odds.count == 1)
		#expect(evens != odds)
		#expect(grouping.separation > 0.9)
	}

	/// The same points give the same answer every time, in every process.
	///
	/// The usual k-means starts from random centres. Here that would mean the
	/// same take proposed as two speakers this morning and the other way round
	/// this afternoon, and a suggestion that moves is one nobody can check.
	@Test func theAnswerDoesNotMoveBetweenRuns() {
		let once = SpeakerClustering.cluster(twoVoices(), into: 2)
		let again = SpeakerClustering.cluster(twoVoices(), into: 2)
		#expect(once == again)
		// And it does not depend on how the points arrived, only on what they
		// are: the same twenty points in the other order fall into the same two
		// groups. Which group is called 0 is arbitrary and is not the claim —
		// what matters is who is with whom.
		let backwards = SpeakerClustering.cluster(Array(twoVoices().reversed()), into: 2)
		let first = zip(once.labels.reversed(), backwards.labels).filter { $0.0 == once.labels[0] }
		#expect(Set(first.map(\.1)).count == 1)
		#expect(abs(backwards.separation - once.separation) < 1e-9)
	}

	/// The number the whole thing hangs on. One clump is one clump, however
	/// firmly a clustering insists on drawing a line through it — and a line
	/// through a blob is what makes a colour that is wrong a third of the time.
	@Test func oneClumpIsNotTwoSpeakers() {
		// A single ball of points: nothing here is two of anything.
		var seed = 1.0
		let blob = (0 ..< 40).map { _ -> [Double] in
			(0 ..< 3).map { _ in
				seed = (seed * 1_103_515_245 + 12345).truncatingRemainder(dividingBy: 2_147_483_648)
				return seed / 2_147_483_648 - 0.5
			}
		}
		let grouping = SpeakerClustering.cluster(blob, into: 2)
		#expect(grouping.separation < SpeakerProposal.leastSeparation + 0.3)
		#expect(grouping.separation < 0.5)
	}

	/// Without this, one feature in hertz drowns out twelve in tenths and the
	/// distance is entirely about pitch — which is the one thing already known
	/// not to separate these speakers.
	@Test func standardisingStopsOneColumnDrowningTheRest() {
		let lopsided = [[200.0, 1.0], [201.0, -1.0], [400.0, 1.0], [401.0, -1.0]]
		// Raw, the split is by the big column: 200s against 400s.
		let raw = SpeakerClustering.cluster(lopsided, into: 2)
		#expect(raw.labels[0] == raw.labels[1])
		// Standardised, the small column gets its say and the split moves.
		let evened = SpeakerClustering.cluster(SpeakerClustering.standardise(lopsided), into: 2)
		#expect(evened.labels[0] != evened.labels[1])

		// A column that never varies is left alone rather than divided by zero.
		let flat = SpeakerClustering.standardise([[1.0, 5.0], [2.0, 5.0]])
		#expect(flat[0][1] == 0)
		#expect(flat[1][1] == 0)
		#expect(flat.allSatisfy { $0.allSatisfy { $0.isFinite } })
	}

	/// An embedding's length says how loud the microphone was, not who was
	/// talking, so it is compared by angle.
	@Test func cosineIgnoresHowLoudItWas() {
		let quiet = [1.0, 2.0, 3.0]
		let loud = [10.0, 20.0, 30.0]
		#expect(SpeakerClustering.measure(quiet, loud, .cosine) < 1e-9)
		#expect(SpeakerClustering.measure(quiet, loud, .euclidean) > 20)
		// And two vectors with nothing in common are a right angle apart.
		#expect(abs(SpeakerClustering.measure([1, 0], [0, 1], .cosine) - 1) < 1e-9)
		// A vector of nothing is answered rather than dividing by zero.
		#expect(SpeakerClustering.measure([0, 0], [1, 1], .cosine) == 1)
	}

	/// Fewer points than clusters, one point, none at all: answered, not
	/// crashed. A take can be three lines long.
	@Test func tooLittleToClusterIsAnswered() {
		#expect(SpeakerClustering.cluster([], into: 2).labels.isEmpty)
		#expect(SpeakerClustering.cluster([[1, 2]], into: 2).labels == [0])
		#expect(SpeakerClustering.cluster([[1, 2], [3, 4]], into: 3).labels == [0, 0])
		#expect(SpeakerClustering.cluster([[1, 2], [3, 4]], into: 1).labels == [0, 0])
		#expect(SpeakerClustering.silhouette([[1.0]], labels: [0]) == 0)
	}

	/// Three voices, because an interview is not always two.
	@Test func threeClumpsComeBackAsThree() {
		var points: [[Double]] = []
		for clump in 0 ..< 3 {
			for step in 0 ..< 8 {
				points.append([Double(clump) * 30 + Double(step) * 0.1,
				               Double(clump) * -30 - Double(step) * 0.1])
			}
		}
		let grouping = SpeakerClustering.cluster(points, into: 3)
		#expect(Set(grouping.labels).count == 3)
		#expect(Set(grouping.labels[0 ..< 8]).count == 1)
		#expect(Set(grouping.labels[8 ..< 16]).count == 1)
		#expect(Set(grouping.labels[16 ..< 24]).count == 1)
		#expect(grouping.separation > 0.9)
	}

	// MARK: - Naming the clusters

	/// Answer two lines by hand, and the pass does the other sixty-six in the
	/// words somebody chose rather than as `speaker-1`.
	@Test func aClusterTakesTheNameOfWhoeverIsAlreadyInIt() {
		var said = Transcript(words: (0 ..< 4).flatMap { line in
			[Word(start: Double(line) * 2, end: Double(line) * 2 + 1, text: "wort"),
			 Word(start: Double(line) * 2 + 1, end: Double(line) * 2 + 1.9, text: "ende\(line).")]
		})
		let lines = said.lines
		#expect(lines.count == 4)
		said.assign("papa", from: lines[0].lowerBound)
		said.assign("mia", from: lines[1].lowerBound)
		said.assign("papa", from: lines[2].lowerBound)

		// Clusters 0 and 1, with lines 0 and 2 in the first and 1 and 3 in the
		// second — which is what the audio would have said too.
		let titles = SpeakerProposal.name(
			clusters: [0, 1, 0, 1], at: [0, 1, 2, 3], in: lines,
			of: said, offered: [], voices: 2)
		#expect(titles == ["papa", "mia"])
	}

	/// With nothing to go on, they are numbered — and never numbered into a
	/// name that is already taken.
	@Test func anUntouchedTakeGetsNumberedSpeakers() {
		let said = Transcript(words: [
			Word(start: 0, end: 1, text: "eins."),
			Word(start: 1, end: 2, text: "zwei.", speaker: "speaker-1"),
		])
		let lines = said.lines
		let titles = SpeakerProposal.name(
			clusters: [0, 1], at: [0, 1], in: lines, of: said, offered: [], voices: 2)
		// The second cluster is already called `speaker-1`, so the first does
		// not get that name as well.
		#expect(titles.count == 2)
		#expect(Set(titles).count == 2)
		#expect(titles.contains("speaker-1"))
	}
}
