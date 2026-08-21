import Foundation

/// Finding the loud bits, and proposing what to do about them.
///
/// The complaint this answers is "there are some very loud areas in one take":
/// a door, a hand on the table, the `p` of a child two inches from the
/// microphone. All three are the same shape — a tenth of a second twelve
/// decibels above everything around it — and all three are found by comparing
/// the recording with itself rather than with a target. A take that is quiet
/// throughout has no excursions in it, and a take recorded in a workshop is
/// loud throughout and has none either; what is wanted is the moment that does
/// not belong to its own neighbourhood.
///
/// **A proposal, never an edit.** What comes back is a curve for somebody to
/// look at and keep or throw away, in the house style for anything a machine
/// worked out — the same as a name read off the words or a speaker guessed from
/// a voice. A pass that quietly pulled twenty points into a take would be a
/// pass nobody could trust, and the numbers it proposes are ordinary points
/// afterwards: draggable, deletable, and written in the file in decibels where
/// they can be read and corrected.
public enum PeakTaming {

	/// What counts as a peak worth taming, and what to do to it.
	///
	/// Every one of these is a judgement rather than a fact, which is why they
	/// are here to be changed rather than buried in the arithmetic. The
	/// defaults were measured against real recordings — see
	/// `PeakTamingFootageTests`.
	public struct Settings: Sendable {
		/// How far above its surroundings a moment has to be to count, in
		/// decibels. Twelve is about a door in a room somebody is talking in;
		/// six would catch every consonant in the take.
		public var threshold = 12.0
		/// And how near the top of the recording's own range it has to be, in
		/// decibels below it.
		///
		/// **Both halves are needed, and each without the other is wrong.**
		/// Measured on a five-minute recording of two children in a room: the
		/// local test alone proposed a hundred and forty dips over eight per cent
		/// of the take, which is a compressor and not a repair — every hand on
		/// the table during a quiet passage stands out locally. Adding this one
		/// left eight, over half a per cent of it, which is what somebody means
		/// by "there are some very loud areas". The other way round is wrong too:
		/// the loudest moment of a loud passage belongs there.
		public var nearTheTop = 6.0
		/// How much of the excess is left standing. Nought would flatten the
		/// transient into the speech and sound like a fault; eight leaves it
		/// clearly the loudest thing in the passage by peak and no longer
		/// painful.
		///
		/// Measured, and worth saying plainly: a thump tamed by this much ends
		/// up *quieter* than the speech around it by a gated loudness meter —
		/// five units under, on the recording this was measured against. That is
		/// not the pass over-doing it. A door has no business being as loud as a
		/// voice; what makes it painful is its peak, which is what comes down,
		/// and what would be a fault is ducking the voice.
		public var keep = 8.0
		/// The longest a thing can last and still be an excursion rather than
		/// the recording having got louder. Past this it is not a plop, it is
		/// somebody shouting, and turning that down is a decision about the
		/// performance rather than a repair.
		public var longest = 0.7
		/// How long the level takes to get down and back, in seconds. Short
		/// enough not to duck the words either side, long enough not to click:
		/// a step in the middle of speech is heard as a click, which is a worse
		/// artefact than the peak was.
		public var shoulder = 0.04
		/// The most it will ever propose taking off. A moment thirty decibels
		/// above the room is a fault in the recording, and pulling it all the
		/// way down would leave an audible hole where the sound used to be.
		public var deepest = 18.0
		/// Not worth a point. Four points in the file to take two decibels off
		/// eighty milliseconds is clutter nobody can hear.
		public var least = 3.0

		public init() {}
	}

	/// One loud moment: where it is on the envelope's own clock, and how far
	/// above its surroundings it goes.
	public struct Excursion: Sendable, Equatable {
		public var start: Double
		public var end: Double
		/// Decibels above the level around it, at its worst.
		public var excess: Double

		public init(start: Double, end: Double, excess: Double) {
			self.start = start
			self.end = end
			self.excess = excess
		}

		public var duration: Double { end - start }
	}

	/// The whole of it, for a caller holding a decoded waveform: the excursions
	/// in it, and the curve that tames them.
	///
	/// `shift` is the take's audio offset when the envelope came from the
	/// separate recorder — the envelope is on the recorder's clock and a curve
	/// is on the video's, and this is the one place the two are related.
	public static func propose(
		over waveform: Waveform, shift: Double = 0,
		existing: [LevelPoint] = [], settings: Settings = Settings()
	) -> [LevelPoint] {
		// A hundred buckets a second: fine enough that a plosive is several
		// buckets rather than one, coarse enough that a forty-minute take is a
		// quarter of a million numbers and the pass is instant.
		let envelope = waveform.envelope(ratePerSecond: rate)
		let found = excursions(in: envelope, ratePerSecond: rate, settings: settings)
		return proposal(for: found, over: existing, shift: shift, settings: settings)
	}

	static let rate = 100.0

	/// The loud moments in an amplitude envelope.
	///
	/// Measured against a *local* level rather than against the take's own
	/// average, because a recording drifts: a child walks away from the
	/// microphone and comes back, and a single figure for the whole take would
	/// call the loud half an excursion and miss the plop in the quiet half.
	///
	/// The level around a moment is "what the loud parts of these eleven seconds
	/// reach": the ninetieth centile within each second, and then the median of
	/// those. Both choices are measurements rather than taste. The centile
	/// first, because a moment has to be compared with the *speech* around it
	/// and not with the pauses — against the median of the raw envelope,
	/// ordinary consonants are fifteen decibels up and everything is an
	/// excursion. The median second, because a second with a door in it must not
	/// raise the level the door is measured against.
	public static func excursions(
		in envelope: [Float], ratePerSecond: Double, settings: Settings = Settings()
	) -> [Excursion] {
		guard ratePerSecond > 0, envelope.count > 1 else { return [] }
		// Decibels, floored well below anything a microphone hears, so that
		// digital silence is a number rather than an infinity.
		let levels = envelope.map { 20 * log10(Double(max($0, 1e-6))) }
		let perSecond = Int(ratePerSecond.rounded())
		guard perSecond >= 1 else { return [] }

		var seconds: [Double] = []
		var index = 0
		while index < levels.count {
			let end = min(index + perSecond, levels.count)
			seconds.append(centile(of: Array(levels[index..<end]), 0.9))
			index = end
		}
		let reach = 5
		let reference = seconds.indices.map { second in
			centile(of: Array(seconds[max(0, second - reach)...min(seconds.count - 1, second + reach)]), 0.5)
		}
		// The top of the take's own range, as the 99.9th centile rather than as
		// the single loudest bucket: one absurd moment — a hand over the
		// microphone — must not put everything else out of reach of the test
		// below and leave a take with nothing proposed for it.
		let top = centile(of: levels, 0.999) - settings.nearTheTop

		/// Runs of buckets that are far enough above where they are, with the
		/// loudest bucket in each.
		var runs: [(from: Int, to: Int, excess: Double, peak: Double)] = []
		var open: Int?
		var worst = 0.0
		var loudest = -Double.infinity
		for bucket in levels.indices {
			let around = reference[min(bucket / perSecond, reference.count - 1)]
			let excess = levels[bucket] - around
			if excess > settings.threshold {
				if open == nil { open = bucket; worst = excess; loudest = levels[bucket] }
				worst = max(worst, excess)
				loudest = max(loudest, levels[bucket])
			} else if let start = open {
				runs.append((start, bucket, worst, loudest))
				open = nil
			}
		}
		if let start = open { runs.append((start, levels.count, worst, loudest)) }

		// Two knocks a bucket apart are one knock. Merged before the length is
		// judged, so a slam that flickers below the threshold in the middle is
		// not read as two short ones.
		let together = max(1, Int((0.15 * ratePerSecond).rounded()))
		var merged: [(from: Int, to: Int, excess: Double, peak: Double)] = []
		for run in runs {
			if let last = merged.last, run.from - last.to <= together {
				merged[merged.count - 1] = (last.from, run.to,
				                            max(last.excess, run.excess),
				                            max(last.peak, run.peak))
			} else {
				merged.append(run)
			}
		}

		return merged.compactMap { run in
			let start = Double(run.from) / ratePerSecond
			let end = Double(run.to) / ratePerSecond
			guard end - start <= settings.longest, run.peak >= top else { return nil }
			return Excursion(start: start, end: end, excess: run.excess)
		}
	}

	/// The curve that tames these: whatever was there already, with a dip over
	/// each excursion.
	///
	/// Four points to a dip — down, along, along, up — so the level is back
	/// where it was on both sides and nothing outside the shoulders is touched.
	/// The shoulders sit at whatever the existing curve says there, which is
	/// what makes this compose with a curve somebody has already drawn instead
	/// of flattening it.
	///
	/// Rounded to a tenth of a decibel and to the millisecond, because that is
	/// what the take file holds: a value the file cannot write exactly would
	/// come back a hair different on the next read and leave a document looking
	/// edited when nothing had changed.
	public static func proposal(
		for excursions: [Excursion], over existing: [LevelPoint],
		shift: Double = 0, settings: Settings = Settings()
	) -> [LevelPoint] {
		var added: [LevelPoint] = []
		for excursion in excursions {
			let cut = -min(max(excursion.excess - settings.keep, 0), settings.deepest)
			guard abs(cut) >= settings.least else { continue }
			let from = max(0, excursion.start + shift - settings.shoulder)
			let start = max(0, excursion.start + shift)
			let end = excursion.end + shift
			let to = end + settings.shoulder
			// An excursion somebody has already dealt with is left alone. The
			// envelope still shows the plop after it has been tamed — the
			// waveform is the file, not the mix — so a second pass over the
			// same take would otherwise propose the same dip a second time and
			// take twenty-four decibels off it.
			guard !existing.contains(where: { $0.at >= from && $0.at <= to }) else { continue }
			let base = { (time: Double) in GainCurve.gain(at: time, in: existing) }
			added += [
				LevelPoint(at: from, gain: base(from)),
				LevelPoint(at: start, gain: base(start) + cut),
				LevelPoint(at: end, gain: base(end) + cut),
				LevelPoint(at: to, gain: base(to)),
			]
		}
		guard !added.isEmpty else { return existing }
		// Only what is new is rounded. A point somebody typed themselves is
		// theirs, and re-writing −3.25 as −3.3 on the way past would be this
		// pass editing something it was not asked about.
		return GainCurve.tidied(existing + added.map {
			LevelPoint(at: Double(Timecode.milliseconds($0.at)) / 1000,
			           gain: ($0.gain * 10).rounded() / 10)
		})
	}

	/// The value a fraction of the way up a sorted copy. Nearest-rank rather
	/// than interpolated: these are levels in decibels off an envelope, and
	/// inventing a value between two buckets would be precision the measurement
	/// does not have.
	private static func centile(of values: [Double], _ fraction: Double) -> Double {
		guard !values.isEmpty else { return 0 }
		let sorted = values.sorted()
		let index = Int((Double(sorted.count - 1) * fraction).rounded())
		return sorted[min(sorted.count - 1, max(0, index))]
	}
}
