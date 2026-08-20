import Foundation

/// Who said what, according to somebody who listened.
///
/// The counterpart of a ``SpeakerProposal/Offer``: one is what a model thinks,
/// this is what a person wrote down, and the whole point of having both is
/// ``score(_:against:)``. A method whose accuracy nobody has measured is a
/// method nobody should switch on.
///
/// **A time and a name, and no words.** This is what a ground truth is allowed
/// to be when the take it describes is somebody's family video: the shape of a
/// conversation — who spoke, and when they started — is not its content. The
/// words stay beside the take, on the machine that recorded it, and the tests
/// that need them are gated on that machine's footage being present.
///
/// Matched by *time* rather than by line number, so that a change to how lines
/// are divided — and there has already been one — does not silently shift every
/// label by one and turn a good method into a bad one.
public struct SpeakerLabels: Sendable, Equatable {

	public struct Label: Sendable, Equatable {
		/// When the line starts, on the video's clock.
		public let at: Double
		public let who: String

		public init(at: Double, who: String) {
			self.at = at
			self.who = who
		}
	}

	public var labels: [Label]

	public init(labels: [Label] = []) {
		self.labels = labels.sorted { $0.at < $1.at }
	}

	public var isEmpty: Bool { labels.isEmpty }
	public var count: Int { labels.count }

	/// Everybody named, in the order they are first heard.
	public var speakers: [String] {
		var seen = Set<String>()
		return labels.map(\.who).filter { seen.insert($0).inserted }
	}

	/// Two columns: a time and a name. Comments and blank lines are skipped,
	/// which is what lets the file explain itself at the top.
	public static func read(_ text: String) -> SpeakerLabels {
		var labels: [Label] = []
		for line in text.components(separatedBy: .newlines) {
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
			let fields = trimmed.split(separator: " ", maxSplits: 1,
			                           omittingEmptySubsequences: true)
			guard fields.count == 2, let at = Timecode.parse(String(fields[0])) else { continue }
			let who = Slug.make(from: String(fields[1]))
			guard !who.isEmpty else { continue }
			labels.append(Label(at: at, who: who))
		}
		return SpeakerLabels(labels: labels)
	}

	public func write(name: String) -> String {
		var out = "# cuttr speaker labels — \(name)\n"
		out += "# at           who\n"
		for label in labels {
			out += Timecode.string(label.at).padding(toLength: 12, withPad: " ", startingAt: 0)
			out += " \(label.who)\n"
		}
		return out
	}

	/// Who is speaking at a line that starts here.
	///
	/// Fifty milliseconds is a frame and a half, which is far tighter than any
	/// two lines of speech are together and far looser than the rounding in a
	/// timecode written to the millisecond.
	public func who(at time: Double, within tolerance: Double = 0.05) -> String? {
		var best: (String, Double)?
		for label in labels {
			let apart = abs(label.at - time)
			guard apart <= tolerance else { continue }
			if best == nil || apart < best!.1 { best = (label.who, apart) }
		}
		return best?.0
	}

	// MARK: - Marking a method

	/// How a pass did.
	public struct Score: Sendable {
		public let correct: Int
		/// Lines the method answered *and* the labels have an answer for.
		public let placed: Int
		/// Lines the labels have an answer for at all — the denominator that
		/// matters, because declining to answer is not the same as being right.
		public let labelled: Int
		/// Which cluster name stands for which label, under the best matching.
		public let naming: [String: String]
		/// Where it went wrong: when, what it said, and what was true.
		public let wrong: [(at: Double, said: String?, truth: String)]

		/// Of every line somebody labelled, whether the method answered or not.
		public var accuracy: Double {
			labelled > 0 ? Double(correct) / Double(labelled) : 0
		}

		/// Of the lines it was willing to answer.
		public var accuracyWherePlaced: Double {
			placed > 0 ? Double(correct) / Double(placed) : 0
		}
	}

	/// What an offer scores against these labels.
	///
	/// **Scored the way diarisation is always scored**: the clusters have no
	/// names of their own, so every way of matching them to the labels is tried
	/// and the best one is the score. Anything else would mark a method wrong
	/// for having called the same two people A and B rather than B and A, which
	/// is not an error anybody could have avoided.
	///
	/// ``commonest`` is worth reading beside it: a method below that is not
	/// slightly worse than good, it is worthless, because a constant is cheaper
	/// and never wrong in a surprising way.
	public func score(_ byLine: [Int: String], against transcript: Transcript) -> Score {
		var said: [(at: Double, given: String?, truth: String)] = []
		for line in transcript.lines {
			guard let span = transcript.span(line), let truth = who(at: span.start) else { continue }
			said.append((span.start, byLine[line.lowerBound], truth))
		}
		let names = Set(said.compactMap(\.given)).sorted()
		let truths = speakers.sorted()
		var best = (0, [String: String]())
		for arrangement in Self.arrangements(truths) where arrangement.count >= names.count {
			var naming: [String: String] = [:]
			for (index, name) in names.enumerated() { naming[name] = arrangement[index] }
			let correct = said.reduce(0) { total, line in
				guard let given = line.given else { return total }
				return total + (naming[given] == line.truth ? 1 : 0)
			}
			if correct > best.0 { best = (correct, naming) }
		}
		let wrong = said
			.filter { line in line.given.flatMap { best.1[$0] } != line.truth }
			.map { (at: $0.at, said: $0.given.flatMap { best.1[$0] }, truth: $0.truth) }
		return Score(correct: best.0, placed: said.filter { $0.given != nil }.count,
		             labelled: said.count, naming: best.1, wrong: wrong)
	}

	/// What a method that always answered the same thing would score. The floor
	/// every other number is read against.
	public var commonest: Double {
		guard !labels.isEmpty else { return 0 }
		var counts: [String: Int] = [:]
		for label in labels { counts[label.who, default: 0] += 1 }
		return Double(counts.values.max() ?? 0) / Double(labels.count)
	}

	/// Every ordering. Two or three speakers, so this is two or six.
	static func arrangements(_ items: [String]) -> [[String]] {
		guard items.count > 1 else { return [items] }
		var out: [[String]] = []
		for (index, item) in items.enumerated() {
			var rest = items
			rest.remove(at: index)
			for tail in arrangements(rest) { out.append([item] + tail) }
		}
		return out
	}
}
