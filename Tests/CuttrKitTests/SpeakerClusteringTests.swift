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
		said.assign("papa", to: lines[0])
		said.assign("mia", to: lines[1])
		said.assign("papa", to: lines[2])

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

	// MARK: - Placing lines against voices somebody has named

	/// Twelve lines of two voices, interleaved the way an interview is, with
	/// one line of each answered by hand.
	///
	/// The point of the numbers is that they are plainly two clumps and that the
	/// answered line of each is an ordinary member of its own. Whether real mel
	/// cepstra look like this is a question for real footage; whether the
	/// arithmetic puts a point with the voice it sits on top of is a question
	/// with an answer.
	private func twoNamedVoices() -> (points: [[Double]], named: [Int: String]) {
		var points: [[Double]] = []
		for index in 0 ..< 12 {
			let nudge = Double(index) * 0.05
			points.append(index % 2 == 0 ? [4 + nudge, 4, 4] : [-4, -4 - nudge, -4])
		}
		return (points, [0: "papa", 1: "mia"])
	}

	@Test func everyLineGoesWithTheVoiceItSitsOn() {
		let (points, named) = twoNamedVoices()
		let placing = SpeakerClustering.place(points, as: named)
		#expect(placing.names == ["mia", "papa"])
		#expect(placing.chosen.count == points.count)
		for index in points.indices {
			#expect(placing.names[placing.chosen[index]] == (index % 2 == 0 ? "papa" : "mia"))
		}
		#expect(placing.separation > 0.9)
	}

	/// One name is not two, and there is nothing to place lines against.
	///
	/// The caller is meant to cluster blind instead. Answering the question with
	/// "everybody is mia" would be worse than saying nothing, because it looks
	/// like an answer.
	@Test func oneNameIsNotEnoughToPlaceAnything() {
		let (points, _) = twoNamedVoices()
		let placing = SpeakerClustering.place(points, as: [0: "papa", 2: "papa"])
		#expect(placing.chosen.isEmpty)
		#expect(placing.separation == 0)
		#expect(SpeakerClustering.place(points, as: [:]).chosen.isEmpty)
	}

	/// A line somebody answered comes back as what they said, even when the
	/// arithmetic would have put it elsewhere.
	///
	/// Contradicting the person being helped is the one failure that makes a
	/// feature untrustworthy rather than merely wrong.
	@Test func anAnsweredLineIsNotSecondGuessed() {
		var (points, named) = twoNamedVoices()
		// The line answered `papa` is sitting in the middle of mia's crowd.
		points[0] = [-4, -4, -4]
		named = [0: "papa", 3: "mia"]
		let placing = SpeakerClustering.place(points, as: named)
		#expect(placing.names[placing.chosen[0]] == "papa")
		#expect(placing.margin[0] == .infinity)
	}

	/// A line in the middle is offered with less confidence than one on top of
	/// a voice. What "propose only where the margin is clear" would be read off.
	@Test func theMarginSaysHowSureItIs() {
		var (points, named) = twoNamedVoices()
		points.append([0, 0, 0])
		let placing = SpeakerClustering.place(points, as: named)
		let halfway = placing.margin[points.count - 1]
		let obvious = placing.margin[4]
		#expect(halfway >= 0)
		#expect(obvious > halfway * 4)
	}

	/// One answered line has no spread of its own, and a variance of zero says
	/// every other line in the take is impossible. It has to borrow one.
	@Test func aSingleAnsweredLineStillGivesUsableNumbers() {
		let voice = SpeakerClustering.Voice.fit([[1, 2, 3]], width: 3)
		#expect(voice.variance == [0, 0, 0])
		let world = SpeakerClustering.Voice.fit([[-1, -1, -1], [1, 1, 1]], width: 3)
		let tempered = voice.tempered(towards: world, prior: 0.2, shrink: 0.5)
		#expect(tempered.variance.allSatisfy { $0 > 0 })
		#expect(tempered.likelihood(of: [0, 0, 0]).isFinite)
		// And the mean is pulled towards the take's own, but only a little: one
		// answered line is believed, if not quite outright.
		#expect(tempered.mean[0] < 1)
		#expect(tempered.mean[0] > 0.8)
	}

	/// The same answered lines give the same answer in every process.
	///
	/// Swift seeds its hashing per launch, so anything that sums a voice's
	/// points in the order a dictionary holds them drifts between runs, and a
	/// line near a boundary changes its mind overnight. Checked by asking with
	/// the names in a different order, which is what a `Dictionary` would hand
	/// over differently.
	@Test func theTaughtAnswerDoesNotMoveBetweenRuns() {
		let (points, _) = twoNamedVoices()
		let once = SpeakerClustering.place(points, as: [0: "papa", 1: "mia", 2: "papa"])
		let again = SpeakerClustering.place(points, as: [2: "papa", 1: "mia", 0: "papa"])
		#expect(once == again)
	}

	/// The unanswered lines are evidence too.
	///
	/// One round of self-training: the lines that were sure of themselves join
	/// their voice and everything is asked again, so a voice whose one answered
	/// line was atypical is corrected by its crowd. Here the line answered
	/// `papa` is well off to one side of where he actually sits and the one
	/// answered `mia` is squarely in her crowd, which puts the boundary between
	/// them too far towards him. The line at 6.5 is plainly one of his — it sits
	/// nearer his eight lines than her nine — and taught by the two answers
	/// alone it goes to her.
	@Test func theUnansweredLinesPullTheVoicesOntoTheirCrowds() {
		var points: [[Double]] = [[0, 0, 0], [12, 12, 12]]
		let named = [0: "papa", 1: "mia"]
		for index in 0 ..< 8 { points.append([4 + Double(index) * 0.05, 4, 4]) }
		for index in 0 ..< 8 { points.append([12 + Double(index) * 0.05, 12, 12]) }
		points.append([6.5, 6.5, 6.5])
		let last = points.count - 1

		let once = SpeakerClustering.place(points, as: named, rounds: 0)
		#expect(once.names[once.chosen[last]] == "mia")
		let again = SpeakerClustering.place(points, as: named, rounds: 1)
		#expect(again.names[again.chosen[last]] == "papa")
		// And it is surer of itself for having looked, rather than merely
		// different.
		#expect(again.margin[last] > once.margin[last])
	}
}
