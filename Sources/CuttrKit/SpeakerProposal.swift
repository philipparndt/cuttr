import Foundation

/// Working out who is speaking, and offering it rather than asserting it.
///
/// **The model proposes; the file records what somebody confirmed.** Nothing
/// in here writes a word. It returns an ``Offer`` that the pane draws in
/// brackets, and it stays a guess until somebody keeps it. That is not
/// squeamishness: a colour that is wrong a third of the time is worse than no
/// colour, because after the third wrong one nobody believes the right ones
/// either.
///
/// **Nothing leaves the machine, on any path.** ``Method/timbre`` is a Fourier
/// transform and has nowhere to send anything. ``Method/voiceAnalytics`` goes
/// through the same on-device recogniser ``Transcriber`` is pinned to, and
/// refuses outright rather than falling back to a server. ``Method/embedding``
/// runs a Core ML file that is already on the disk, and if it is not there the
/// method is simply not offered — the fetch is a separate, explicit act by the
/// person using the program.
public enum SpeakerProposal {

	/// How the voices are told apart.
	public enum Method: String, Sendable, CaseIterable {
		/// Mel cepstra off the samples. No model, no permission, no network,
		/// and it works on a take that has never been near a recogniser.
		case timbre
		/// Pitch, jitter, shimmer and voicing, as Apple's own recogniser
		/// measured them. Richer than anything hand-rolled and free of any
		/// foreign model — but it needs the recogniser to run again over the
		/// whole take, which is a minute of somebody's machine.
		case voiceAnalytics = "voice-analytics"
		/// A speaker-embedding network. The only one designed for this job
		/// rather than borrowed for it, and the only one that needs a file this
		/// program does not ship.
		case embedding
		/// Whose mouth is moving, out of the people this take already follows.
		/// Not audio at all — see ``SpeakerDetector``, which was in this
		/// program before any of the rest of this was.
		case mouth

		public var title: String {
			switch self {
			case .timbre: return "Timbre"
			case .voiceAnalytics: return "Voice analytics"
			case .embedding: return "Speaker embedding"
			case .mouth: return "Whose mouth is moving"
			}
		}

		/// Whether it listens or looks. What the caller has to hand it.
		public var watchesThePicture: Bool { self == .mouth }
	}

	/// What a pass came back with.
	public struct Offer: Sendable {
		/// Who says each line, keyed by the line's first word — the same key
		/// ``TakeDocument/suggestedSpeakers`` uses.
		public let byLine: [Int: String]
		/// How separated the clusters were, −1 to 1. See
		/// ``SpeakerClustering/silhouette(_:labels:distance:)``.
		public let separation: Double
		public let method: Method
		/// The lines that were too short or too quiet to measure, and so were
		/// left alone rather than guessed at.
		public let skipped: Int

		public init(byLine: [Int: String], separation: Double, method: Method, skipped: Int) {
			self.byLine = byLine
			self.separation = separation
			self.method = method
			self.skipped = skipped
		}

		public var isEmpty: Bool { byLine.isEmpty }
	}

	/// Below this, the clusters are one clump with a line drawn through it and
	/// the answer is not worth showing.
	///
	/// Measured rather than chosen: on the take this was built against, the
	/// runs that scored above it were the ones worth keeping and the runs below
	/// it were coin tosses dressed up as an answer.
	public static let leastSeparation = 0.12

	/// How many frames to look at per line when the method looks rather than
	/// listens.
	///
	/// Six seconds of a line, at ten frames a second. About the length of a
	/// spoken sentence, so most lines are watched whole — and a line longer
	/// than that is settled by its first six seconds rather than by a thin
	/// scattering across all of it.
	public static let mouthSamples = 60

	/// A line shorter than this is not enough voice to place. Half a second is
	/// about two words, and `Auch.` on its own genuinely cannot be attributed.
	public static let shortestLine = 0.6

	// MARK: - Running a pass

	/// Who is speaking in each line of `transcript`.
	///
	/// `names` is what the clusters are called. When somebody has already
	/// labelled a few lines by hand, pass their slugs and the clusters take the
	/// name of whoever is already in them — which is the useful way round:
	/// answer two lines, and the pass does the other sixty-six. With nothing to
	/// go on it numbers them, and accepting the offer puts those numbers in the
	/// cast.
	public static func propose(
		for transcript: Transcript,
		audio url: URL,
		offset: Double = 0,
		method: Method = .timbre,
		voices: Int = 2,
		names: [String] = [],
		locale: String = "",
		video: URL? = nil,
		faces: [SpeakerDetector.Candidate] = [],
		samples: Int = mouthSamples
	) async throws -> Offer {
		let lines = transcript.lines
		guard lines.count >= voices * 2, voices >= 2 else {
			return Offer(byLine: [:], separation: 0, method: method, skipped: lines.count)
		}
		let spans: [(start: Double, end: Double)] = lines.compactMap { transcript.span($0) }
		guard spans.count == lines.count else {
			return Offer(byLine: [:], separation: 0, method: method, skipped: lines.count)
		}

		let vectors: [[Double]]
		let usable: [Bool]
		let distance: SpeakerClustering.Distance
		switch method {
		case .timbre:
			let measured = try await VoiceTimbre.measure(url: url, spans: spans, offset: offset)
			vectors = SpeakerClustering.standardise(measured.map(\.features))
			usable = zip(measured, spans).map { sample, span in
				sample.voiced > 0.15 && span.end - span.start >= shortestLine
			}
			distance = .euclidean
		case .voiceAnalytics:
			let measured = try await VoiceAnalytics.measure(
				url: url, spans: spans, offset: offset,
				locale: locale.isEmpty ? .current : Locale(identifier: locale))
			vectors = SpeakerClustering.standardise(measured.map(\.features))
			usable = zip(measured, spans).map { sample, span in
				sample.frames >= 8 && span.end - span.start >= shortestLine
			}
			distance = .euclidean
		case .embedding:
			let measured = try await SpeakerEmbedding.measure(url: url, spans: spans, offset: offset)
			vectors = measured.map(\.features)
			usable = zip(measured, spans).map { sample, span in
				!sample.features.isEmpty && span.end - span.start >= shortestLine
			}
			distance = .cosine
		case .mouth:
			guard let video, !faces.isEmpty else {
				return Offer(byLine: [:], separation: 0, method: method, skipped: lines.count)
			}
			var measured: [[Double]] = []
			var seen: [Int] = []
			for span in spans {
				let scores = try await SpeakerDetector.movement(
					videoURL: video, among: faces, from: span.start, to: span.end,
					samples: samples)
				// One column per tracked person, in the order they were given,
				// so a line is a point in as many dimensions as there are faces
				// and the clustering has something to separate.
				var row = [Double](repeating: 0, count: faces.count)
				var enough = 0
				for (index, face) in faces.enumerated() {
					guard let found = scores.first(where: { $0.name == face.name }) else { continue }
					// On a log scale: a mouth is either moving or it is not, and
					// the interesting difference between 0.004 and 0.02 is the
					// factor of five, not the 0.016. Clustered linearly, one
					// very animated line stretches the range and drags the
					// split point up with it.
					row[index] = Foundation.log(found.movement + 0.001)
					enough = Swift.max(enough, found.seen)
				}
				measured.append(row)
				seen.append(enough)
			}
			vectors = SpeakerClustering.standardise(measured)
			usable = zip(seen, spans).map { seen, span in
				seen >= 4 && span.end - span.start >= shortestLine
			}
			distance = .euclidean
		}

		// Clustered on the lines worth measuring only. A line of silence
		// dragged into the arithmetic pulls a centre towards the room tone.
		let kept = usable.indices.filter { usable[$0] }
		guard kept.count >= voices * 2 else {
			return Offer(byLine: [:], separation: 0, method: method,
			             skipped: lines.count)
		}
		let grouping = SpeakerClustering.cluster(
			kept.map { vectors[$0] }, into: voices, distance: distance)
		guard grouping.separation >= leastSeparation else {
			return Offer(byLine: [:], separation: grouping.separation, method: method,
			             skipped: lines.count)
		}

		let titles = name(clusters: grouping.labels, at: kept, in: lines,
		                  of: transcript, offered: names, voices: voices)
		var byLine: [Int: String] = [:]
		for (position, line) in kept.enumerated() {
			byLine[lines[line].lowerBound] = titles[grouping.labels[position]]
		}
		return Offer(byLine: byLine, separation: grouping.separation, method: method,
		             skipped: lines.count - kept.count)
	}

	/// What to call each cluster.
	///
	/// Whoever is already named in it, by majority — so answering two lines by
	/// hand and then asking teaches the pass both names at once, and the offer
	/// comes back in the words somebody chose rather than as `speaker-1`. A
	/// cluster nobody has touched is numbered, and two clusters never end up
	/// with the same name.
	static func name(
		clusters: [Int], at kept: [Int], in lines: [Range<Int>],
		of transcript: Transcript, offered: [String], voices: Int
	) -> [String] {
		var votes = [[String: Int]](repeating: [:], count: voices)
		for (position, line) in kept.enumerated() {
			guard let slug = transcript.speaker(ofLine: lines[line]) else { continue }
			votes[clusters[position]][slug, default: 0] += 1
		}
		var titles = [String](repeating: "", count: voices)
		var taken = Set<String>()
		for cluster in 0 ..< voices {
			guard let winner = votes[cluster].max(by: { left, right in
				left.value == right.value ? left.key > right.key : left.value < right.value
			})?.key, !taken.contains(winner) else { continue }
			titles[cluster] = winner
			taken.insert(winner)
		}
		// Then whatever was offered, then numbers — and never a name twice.
		var spare = offered.filter { !taken.contains($0) }
		var number = 1
		for cluster in 0 ..< voices where titles[cluster].isEmpty {
			if !spare.isEmpty {
				titles[cluster] = spare.removeFirst()
			} else {
				while taken.contains("speaker-\(number)") { number += 1 }
				titles[cluster] = "speaker-\(number)"
			}
			taken.insert(titles[cluster])
		}
		return titles
	}
}
