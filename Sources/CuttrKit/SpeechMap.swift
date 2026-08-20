import Foundation

/// Where the talking is in a recording, and therefore where the silence is.
///
/// ``SpeechEdges`` answers "at what moments does the sound start and stop"; a
/// list of moments is what a timeline snaps to, and it is the wrong shape for
/// every other question. Between two of those moments there is either somebody
/// talking or there is not, and almost everything worth asking is about the
/// *stretches*: how long is this pause, is that mark sitting in one, how much
/// air can this clip have before it takes some of the next one's.
///
/// So this pairs the edges up. It adds no measurement of its own — the same
/// envelope, the same thresholds, the same 50 ms over a five-minute take — and
/// the timeline draws ``edges`` back out again, so what ⌥ snaps to and what a
/// clip is refined against are one array and cannot drift apart.
///
/// **One clock.** Built with the shift the lane is drawn with, so every number
/// in it is on the video's clock like every other time in a take. Nothing here
/// stores an audio-relative time, and ``bounds`` is where the recording begins
/// and ends *on that clock* — negative at the head when the recorder rolled
/// first.
///
/// `docs/silence.md` is the report: what was measured on a real take, why the
/// handle is a quarter of a second, and why none of this is written to a file.
public struct SpeechMap: Sendable, Equatable {

	/// The runs of talking, in order and not overlapping.
	public let runs: [ClosedRange<Double>]

	/// Where the recording begins and ends. The head and the tail of the file
	/// are quiet stretches like any other, and a clip at the very start of a
	/// take should be able to take air out of the lead-in.
	public let bounds: ClosedRange<Double>

	public init(runs: [ClosedRange<Double>], bounds: ClosedRange<Double>) {
		self.runs = runs.sorted { $0.lowerBound < $1.lowerBound }
		self.bounds = bounds
	}

	/// Reads the envelope the timeline is drawing.
	///
	/// `shift` is what that lane is drawn with: the take's `audio.offset` for a
	/// separate recorder, nothing at all for the camera's own track.
	public static func of(_ waveform: Waveform, shift: Double = 0) -> SpeechMap {
		let edges = SpeechEdges.edges(in: waveform, shift: shift)
		var runs: [ClosedRange<Double>] = []
		runs.reserveCapacity(edges.count / 2)
		var index = 0
		while index + 1 < edges.count {
			runs.append(edges[index] ... edges[index + 1])
			index += 2
		}
		return SpeechMap(runs: runs, bounds: shift ... (shift + waveform.duration))
	}

	/// The moments, back in the shape the timeline snaps to.
	public var edges: [Double] { runs.flatMap { [$0.lowerBound, $0.upperBound] } }

	public var isEmpty: Bool { runs.isEmpty }

	// MARK: - The defaults

	/// A quarter of a second of air at each end of a clip, when there is a
	/// quarter of a second to be had.
	///
	/// Stated here rather than chosen inside the function that applies it,
	/// because it is the one number in this file that is a matter of taste and
	/// somebody will want to argue with it. Two things pin it down. Below about
	/// a tenth of a second the air is not audible as air — the cut still sounds
	/// clipped — and above about a third it starts to sound like a mistake, a
	/// clip that begins by waiting. And ``SpeechEdges/restingFor`` is a quarter
	/// of a second, which is the shortest gap this program will call a stop at
	/// all: at this handle the shortest real gap gives each of its two
	/// neighbours half of itself, and every longer gap gives both of them the
	/// whole amount.
	public static let handle = 0.25

	/// How far a mark may move when it is refined: a fifth of a second.
	///
	/// A recogniser's word times arrive rounded to a twentieth of a second and
	/// are loose by rather more than the rounding, so this has to be several
	/// times the quantum to be worth doing. It is also strictly less than
	/// ``SpeechEdges/restingFor``, and that is not a coincidence: two runs are
	/// at least that far apart, so a mark inside one run can never reach the
	/// start of the next one. Between the runs, the transcript is what stops it
	/// — see ``cut(from:to:after:before:handle:reach:)``.
	public static let reach = 0.2

	// MARK: - Reading the silence

	/// The stretch of quiet a moment sits in.
	///
	/// Empty — `time ... time` — while somebody is talking, which is the honest
	/// answer and also the one that makes the arithmetic below need no special
	/// case for it: a clip cut out of the middle of a sentence gets no air
	/// because there is none.
	///
	/// A mark exactly on an edge counts as being in the quiet, not in the
	/// speech. That is the case that matters: a refined mark lands exactly on
	/// an edge, and being in the quiet is the whole reason there is air to give
	/// it.
	public func quiet(at time: Double) -> ClosedRange<Double> {
		if isSpeaking(at: time) { return time ... time }
		let from = runs.last { $0.upperBound <= time }?.upperBound ?? Swift.min(bounds.lowerBound, time)
		let to = runs.first { $0.lowerBound >= time }?.lowerBound ?? Swift.max(bounds.upperBound, time)
		return Swift.min(from, time) ... Swift.max(to, time)
	}

	/// How much quiet there is immediately before a moment, and after it.
	public func quiet(before time: Double) -> Double { time - quiet(at: time).lowerBound }
	public func quiet(after time: Double) -> Double { quiet(at: time).upperBound - time }

	/// Every stretch of quiet in the recording, in order, the lead-in and the
	/// run-out included.
	///
	/// What `cuttr-render --silence` prints, and the thing an agent reading a
	/// take has never been able to see: a transcript says which words were said
	/// and this says where the room was empty, which is where a cut can go
	/// without anybody hearing it.
	public var quiet: [ClosedRange<Double>] {
		guard !runs.isEmpty else { return [bounds] }
		var out: [ClosedRange<Double>] = []
		var at = bounds.lowerBound
		for run in runs {
			if run.lowerBound > at { out.append(at ... run.lowerBound) }
			at = Swift.max(at, run.upperBound)
		}
		if bounds.upperBound > at { out.append(at ... bounds.upperBound) }
		return out
	}

	/// Whether somebody is talking at that moment — so, whether a mark there is
	/// cutting through a word.
	public func isSpeaking(at time: Double) -> Bool {
		runs.contains { $0.lowerBound < time && time < $0.upperBound }
	}

	/// How far into a run a mark is, measured from whichever end of it is
	/// nearer. Nothing at all when the mark is in the quiet.
	///
	/// The number behind "this clip is clipping a word": a mark 340 ms inside a
	/// run is 340 ms of somebody's sentence that will not be in the programme.
	public func depthIntoSpeech(at time: Double) -> Double {
		guard let run = runs.first(where: { $0.lowerBound < time && time < $0.upperBound })
		else { return 0 }
		return Swift.min(time - run.lowerBound, run.upperBound - time)
	}

	// MARK: - Making a cut out of a span

	/// What a span read off the words turns into, and every number behind it.
	///
	/// Kept whole rather than reduced to two times, because the reason is the
	/// interesting part: a mark that did not move because there was no edge to
	/// move to and a mark that did not move because it was already right look
	/// identical in the answer and are not the same thing at all.
	public struct Cut: Sendable, Equatable {
		/// What was asked for.
		public var asked: ClosedRange<Double>
		/// Where the marks went once they were put on the sound.
		public var refined: ClosedRange<Double>
		/// And where they went once they had taken their air. The clip.
		public var span: ClosedRange<Double>

		/// How far each mark moved when it was refined. Signed, in seconds:
		/// negative is earlier.
		public var startMoved: Double { refined.lowerBound - asked.lowerBound }
		public var endMoved: Double { refined.upperBound - asked.upperBound }

		/// How much air each end was given.
		public var startHandle: Double { refined.lowerBound - span.lowerBound }
		public var endHandle: Double { span.upperBound - refined.upperBound }

		/// And how much there was to be had — the stretch of quiet each refined
		/// mark was sitting in, on its own side of the mark. Zero means
		/// somebody was talking there.
		public var quietBefore: Double
		public var quietAfter: Double

		public var duration: Double { span.upperBound - span.lowerBound }

		public init(asked: ClosedRange<Double>, refined: ClosedRange<Double>,
		            span: ClosedRange<Double>, quietBefore: Double, quietAfter: Double) {
			self.asked = asked
			self.refined = refined
			self.span = span
			self.quietBefore = quietBefore
			self.quietAfter = quietAfter
		}

		/// The cut nothing was known about: what this program did before, and
		/// what it still does while the audio is being decoded.
		public static func unchanged(_ span: ClosedRange<Double>) -> Cut {
			Cut(asked: span, refined: span, span: span, quietBefore: 0, quietAfter: 0)
		}
	}

	/// What a span taken from the words should actually be cut as.
	///
	/// Two steps, and they answer two different complaints.
	///
	/// **Refinement.** A word time is the recogniser's claim about which sound
	/// was which word. It is not a claim about the instant the sound began, and
	/// it arrives rounded to a twentieth of a second besides, so a clip made
	/// from a word selection starts a little before or after the talking does.
	/// The in mark goes to the nearest moment the sound *starts* and the out
	/// mark to the nearest moment it *stops* — starts for one end and stops for
	/// the other, never both, so a mark cannot be pulled onto the wrong kind of
	/// edge. Within ``reach``, and no further.
	///
	/// **It can never take in a word nobody selected.** `after` is where the
	/// previous word ended and `before` is where the next one starts, and the
	/// marks are clamped to them. Between two words with no silence between
	/// them those clamps are the selection's own edges and refinement does
	/// nothing, which is right — there is no moment the sound started to move
	/// to.
	///
	/// **Handles.** A clip trimmed hard against the words has no air in it, and
	/// a row of them assembled later is glued end to end. So each mark backs
	/// off into the silence it is sitting in, by up to `handle` — *and never
	/// past the middle of that silence*.
	///
	/// The midpoint is the whole rule, and it is what makes this safe. A pause
	/// belongs half to the sentence in front of it and half to the one behind,
	/// so two clips cut from either side of one pause both stop at the same
	/// line: they meet exactly and never overlap, without either of them
	/// knowing that the other exists. That last part is what matters. A clip
	/// has to be a function of the take and the recording alone, or making the
	/// second clip would have to go back and re-trim the first, and a file
	/// somebody is reading as text would move under them.
	///
	/// **What that guarantee is worth, exactly.** It holds whenever each mark
	/// is in its own half of the pause they share — which is where a word time
	/// is, and where a refined mark sits precisely, on the boundary of its own
	/// run. It cannot be made to hold for arbitrary marks by any rule of this
	/// shape, and the proof is one line: two marks a millisecond apart in the
	/// middle of a long pause would need the earlier one to take no air at all,
	/// and it has no way of knowing the other is there. What *is* unconditional
	/// is the part worth having — a mark only ever moves within the pause it
	/// was already in, so anything two clips end up sharing is silence. No word
	/// is ever in two clips.
	///
	/// Where there is no silence — somebody talking straight through, a clip
	/// cut out of the middle of a sentence — the stretch of quiet is empty, the
	/// midpoint is the mark itself, and the handle is nothing. The clip is a
	/// hard cut against the words, exactly as before. Nothing is borrowed from
	/// a neighbour's speech to make up the difference, because there is nothing
	/// there to borrow that is not somebody's voice.
	public func cut(
		from start: Double, to end: Double,
		after previousWordEnd: Double? = nil,
		before nextWordStart: Double? = nil,
		handle: Double = SpeechMap.handle,
		reach: Double = SpeechMap.reach
	) -> Cut {
		let asked = Swift.min(start, end) ... Swift.max(start, end)
		guard !runs.isEmpty, handle >= 0, reach >= 0 else { return .unchanged(asked) }

		// Refining the head against the starts of runs, and the tail against
		// their ends. Bounded by the selection itself as well as by the
		// neighbours, so a mark cannot cross the one at the other end of it.
		let headFloor = Swift.max(asked.lowerBound - reach, previousWordEnd ?? -.infinity)
		let headCeiling = Swift.min(asked.lowerBound + reach, asked.upperBound)
		let head = nearest(to: asked.lowerBound, among: runs.map(\.lowerBound),
		                   between: headFloor, and: headCeiling) ?? asked.lowerBound

		let tailFloor = Swift.max(asked.upperBound - reach, head)
		let tailCeiling = Swift.min(asked.upperBound + reach, nextWordStart ?? .infinity)
		let tail = nearest(to: asked.upperBound, among: runs.map(\.upperBound),
		                   between: tailFloor, and: tailCeiling) ?? asked.upperBound

		let refined = head ... Swift.max(tail, head)

		let airBefore = quiet(at: refined.lowerBound)
		let airAfter = quiet(at: refined.upperBound)
		// Never past the middle, and never the wrong way: a mark already beyond
		// the midpoint — sitting deep in a pause the recogniser was loose about
		// — stays where it is rather than being dragged back to the line.
		let openTo = Swift.max(refined.lowerBound - handle,
		                       Swift.min(refined.lowerBound, middle(of: airBefore)))
		let closeTo = Swift.min(refined.upperBound + handle,
		                        Swift.max(refined.upperBound, middle(of: airAfter)))

		return Cut(asked: asked, refined: refined,
		           span: openTo ... Swift.max(closeTo, openTo),
		           quietBefore: refined.lowerBound - airBefore.lowerBound,
		           quietAfter: airAfter.upperBound - refined.upperBound)
	}

	private func middle(of range: ClosedRange<Double>) -> Double {
		(range.lowerBound + range.upperBound) / 2
	}

	/// The value in `candidates` closest to `target`, ignoring any outside the
	/// window. A take has a few hundred edges and a walk over them is nothing
	/// next to the decode that produced them.
	private func nearest(to target: Double, among candidates: [Double],
	                     between floor: Double, and ceiling: Double) -> Double? {
		guard floor <= ceiling else { return nil }
		var best: Double?
		for candidate in candidates where candidate >= floor && candidate <= ceiling {
			if best == nil || abs(candidate - target) < abs(best! - target) { best = candidate }
		}
		return best
	}
}
