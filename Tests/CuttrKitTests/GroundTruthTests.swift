import Foundation
import Testing
@testable import CuttrKit

/// The labels themselves, and the arithmetic that marks a method against them.
///
/// Runs everywhere, because none of it needs the recording: a label is a time
/// and a name, and the scoring is a permutation and a count.
@Suite struct SpeakerLabelTests {

	static let url = URL(fileURLWithPath: #filePath)
		.deletingLastPathComponent()   // CuttrKitTests
		.deletingLastPathComponent()   // Tests
		.appendingPathComponent("Fixtures/mia-take-1.speakers")

	static func labelled() throws -> SpeakerLabels {
		SpeakerLabels.read(try String(contentsOf: url, encoding: .utf8))
	}

	@Test func theLabelsAreWhatTheyWere() throws {
		let truth = try Self.labelled()
		#expect(truth.count == 68)
		#expect(truth.speakers.sorted() == ["interviewer", "mia"])
		// The number every method has to beat before it is worth switching on.
		#expect(abs(truth.commonest - 0.618) < 0.005)
	}

	/// The one thing the file must not contain. A ground truth for somebody's
	/// family video is a shape, not a transcript, and this is the test that
	/// says so out loud — the words live beside the take and nowhere else.
	@Test func theLabelsCarryNoWords() throws {
		let text = try String(contentsOf: Self.url, encoding: .utf8)
		for line in text.components(separatedBy: .newlines) {
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
			let fields = trimmed.split(separator: " ", omittingEmptySubsequences: true)
			#expect(fields.count == 2, "a label row is a time and a name: \(trimmed)")
			#expect(Timecode.parse(String(fields[0])) != nil)
			#expect(Slug.isValid(String(fields[1])))
		}
	}

	@Test func labelsRoundTrip() throws {
		let truth = try Self.labelled()
		#expect(SpeakerLabels.read(truth.write(name: "t")) == truth)
	}

	/// Matched by time, not by line number, so a change to how lines are
	/// divided cannot shift every label by one.
	@Test func aLabelIsFoundByWhenItWasSaid() {
		let truth = SpeakerLabels(labels: [
			.init(at: 10.0, who: "mia"), .init(at: 12.5, who: "papa"),
		])
		#expect(truth.who(at: 10.0) == "mia")
		#expect(truth.who(at: 10.02) == "mia")
		#expect(truth.who(at: 12.5) == "papa")
		// Beyond a frame and a half, it is a different line and is not guessed.
		#expect(truth.who(at: 10.4) == nil)
		#expect(truth.who(at: 0) == nil)
	}

	// MARK: - Marking

	/// Two lines each, alternating, split on the full stops.
	private func fourLines() -> Transcript {
		Transcript(words: (0 ..< 4).flatMap { line in
			[Word(start: Double(line) * 2, end: Double(line) * 2 + 1, text: "wort"),
			 Word(start: Double(line) * 2 + 1, end: Double(line) * 2 + 1.9, text: "ende\(line).")]
		})
	}

	private let alternating = SpeakerLabels(labels: [
		.init(at: 0, who: "mia"), .init(at: 2, who: "papa"),
		.init(at: 4, who: "mia"), .init(at: 6, who: "papa"),
	])

	/// A cluster has no name of its own, so calling the same two people A and B
	/// rather than B and A is not an error anybody could have avoided.
	@Test func theBestMatchingOfClustersToNamesIsTheScore() {
		let said = fourLines()
		let starts = said.lines.map(\.lowerBound)
		// Perfectly right, under names that match nothing.
		let backwards = [starts[0]: "b", starts[1]: "a", starts[2]: "b", starts[3]: "a"]
		let score = alternating.score(backwards, against: said)
		#expect(score.correct == 4)
		#expect(score.accuracy == 1)
		#expect(score.naming["b"] == "mia")
		#expect(score.wrong.isEmpty)
	}

	/// Declining to answer is not the same as being right, and the two
	/// denominators say so separately.
	@Test func decliningToAnswerIsNotCounted() {
		let said = fourLines()
		let starts = said.lines.map(\.lowerBound)
		let score = alternating.score([starts[0]: "a", starts[1]: "b"], against: said)
		#expect(score.labelled == 4)
		#expect(score.placed == 2)
		#expect(score.correct == 2)
		#expect(score.accuracy == 0.5)
		#expect(score.accuracyWherePlaced == 1)
		// The two it never answered are still wrong, and are named as such.
		#expect(score.wrong.count == 2)
		#expect(score.wrong.allSatisfy { $0.said == nil })
	}

	/// One cluster for the whole take is the constant, and the constant scores
	/// exactly what the commonest label is worth — which is the floor every
	/// other number has to be read against.
	@Test func answeringTheSameThingEveryTimeScoresTheFloor() {
		let said = fourLines()
		let starts = said.lines.map(\.lowerBound)
		let score = alternating.score(
			[starts[0]: "a", starts[1]: "a", starts[2]: "a", starts[3]: "a"], against: said)
		#expect(score.correct == 2)
		#expect(score.accuracy == alternating.commonest)
		#expect(score.wrong.count == 2)
	}

	/// Getting one line wrong costs one line, and the best matching does not
	/// rescue it by relabelling everything.
	@Test func oneWrongLineIsOneWrongLine() {
		let said = fourLines()
		let starts = said.lines.map(\.lowerBound)
		let score = alternating.score(
			[starts[0]: "a", starts[1]: "a", starts[2]: "a", starts[3]: "b"], against: said)
		#expect(score.correct == 3)
		#expect(score.wrong.count == 1)
		#expect(score.wrong.first?.truth == "papa")
	}

	/// A pass taught by lines somebody answered has no permutation to hide
	/// behind, and the two figures say so separately.
	///
	/// Blind, the clusters have no names of their own and calling the same two
	/// people A and B rather than B and A is not an error. Taught, the names are
	/// the ones somebody chose, and calling `mia` `papa` throughout is exactly
	/// as wrong as it sounds — letting it permute would flatter it into a
	/// hundred per cent.
	@Test func aTaughtPassIsMarkedUnderTheNamesItChose() {
		let said = fourLines()
		let starts = said.lines.map(\.lowerBound)
		let swapped = [starts[0]: "papa", starts[1]: "mia",
		               starts[2]: "papa", starts[3]: "mia"]
		let score = alternating.score(swapped, against: said)
		#expect(score.correct == 4)
		#expect(score.agreed == 0)
		#expect(score.agreement == 0)
		// And right in the names it chose scores full marks on both counts.
		let straight = [starts[0]: "mia", starts[1]: "papa",
		                starts[2]: "mia", starts[3]: "papa"]
		let right = alternating.score(straight, against: said)
		#expect(right.agreed == 4)
		#expect(right.agreement == 1)
	}

	/// Labels that belong to a different recording line up with nothing, and
	/// that is answered rather than scored as a rout.
	@Test func labelsForAnotherTakeMatchNothing() {
		let elsewhere = SpeakerLabels(labels: [.init(at: 900, who: "mia")])
		let score = elsewhere.score([0: "a"], against: fourLines())
		#expect(score.labelled == 0)
		#expect(score.accuracy == 0)
	}
}

/// The numbers in `docs/speakers.md`, against the recording they were measured
/// on.
///
/// Off by default and not part of the suite, because it needs footage that is
/// not in this repository and must not be: it is a seven-year-old's family
/// interview. `Tests/Fixtures/mia-take-1.speakers` holds the labels — a time
/// and a name per line — and the words are read from the take itself, wherever
/// the person running this keeps it.
///
/// ```
/// CUTTR_FOOTAGE=/Volumes/500G/DorisWalter70/mia-take-1.cuttr \
///   xcrun swift test --filter SpeakerFootageTests
/// ```
///
/// What it checks is that the labels still describe *that* take: same number of
/// lines, every line labelled. It does not run a method — a pass over five
/// minutes of video is a minute and a half of somebody's machine, and
/// `cuttr-render --speakers <take> --truth <labels>` is the thing to reach for.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CUTTR_FOOTAGE"] != nil))
struct SpeakerFootageTests {

	private var takeURL: URL {
		URL(fileURLWithPath: ProcessInfo.processInfo.environment["CUTTR_FOOTAGE"]!)
	}

	private func words() throws -> Transcript {
		let take = try TakeReader.read(try String(contentsOf: takeURL, encoding: .utf8))
		let path = try #require(take.words?.path, "that take has no words beside it")
		let sidecar = URL(fileURLWithPath: path, relativeTo: takeURL.deletingLastPathComponent())
		return Transcript.read(try String(contentsOf: sidecar, encoding: .utf8))
	}

	@Test func theLabelsStillDescribeTheTake() throws {
		let said = try words()
		let truth = try SpeakerLabelTests.labelled()
		let lines = said.lines
		print("\(said.count) words, \(lines.count) lines, \(truth.count) labels")
		#expect(lines.count == truth.count)
		// Every line has somebody on it. A ground truth with holes in it is not
		// one, and a hole here means the line splitting has moved under the
		// labels since they were written.
		let missing = lines.compactMap { line -> Double? in
			guard let span = said.span(line) else { return nil }
			return truth.who(at: span.start) == nil ? span.start : nil
		}
		#expect(missing.isEmpty, "no label at \(missing.map(Timecode.string))")
	}

	/// The claim that made sentence-splitting necessary, checked against the
	/// real take rather than against a sentence quoted from it.
	///
	/// Two people taking turns do not pause. So somewhere in this interview
	/// there is a line boundary that the *clock alone* could never have found:
	/// less than ``Transcript/beat`` of silence across it, and a different
	/// speaker on each side. If that is not true of this recording then the
	/// feature was built for nothing, and the honest way to say so is to look.
	@Test func turnsChangeWithNoSilenceBetweenThem() throws {
		let said = try words()
		let truth = try SpeakerLabelTests.labelled()
		let lines = said.lines
		var silent = 0
		for (number, line) in lines.enumerated() where number + 1 < lines.count {
			let next = lines[number + 1]
			guard said.silence(after: line.upperBound - 1) == .sentence,
			      let here = said.span(line).flatMap({ truth.who(at: $0.start) }),
			      let there = said.span(next).flatMap({ truth.who(at: $0.start) }),
			      here != there
			else { continue }
			silent += 1
		}
		print("\(silent) turns change with no silence between them")
		#expect(silent > 0)
	}
}
