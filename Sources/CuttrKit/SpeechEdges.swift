import Foundation

/// Where the talking starts and stops in a recording.
///
/// What somebody is aiming at when they trim a clip against a waveform. The
/// first attempt at this asked the *transcript* — the head of the first word
/// after a silence, the tail of the last word before one — and it was wrong on
/// screen: a recogniser's word times are a claim about which sounds were which
/// word, not about the exact instant the sound began, and they arrive rounded
/// to a twentieth of a second besides. Marks landed in the silence before a
/// burst, and the plain end of a sentence had no mark at all.
///
/// So this reads the *envelope the timeline is drawing*. What you see is what
/// you snap to, which is the only version of this feature that can be right:
/// the operator is aiming at a shape on the screen, and the shape is this
/// array.
public enum SpeechEdges {

	/// Ten milliseconds a step. Finer than anybody can point at with a mouse
	/// and coarse enough that five minutes is thirty thousand numbers.
	static let step = 0.01

	/// A quarter of a second of quiet before the talking counts as having
	/// stopped. Below that, the gaps *inside* a sentence start earning marks —
	/// German is full of stops in the middle of a word — and a mark between two
	/// syllables is a mark nobody was aiming at.
	static let restingFor = 0.25

	/// And a sixth of a second of sound before it counts as having started, so
	/// a chair creaking is not an edge.
	static let soundingFor = 0.15

	/// How far above the room's own noise a sound has to be to be somebody
	/// talking, and how far it has to fall again to have stopped. Two
	/// thresholds rather than one: with a single one, a voice hovering at the
	/// line produces a burst of marks a frame apart.
	static let loudBy = 15.0
	static let quietBy = 8.0

	/// The moments the sound starts and stops, in the recording's own time,
	/// shifted onto the clock the caller is asking about.
	///
	/// `shift` is what the timeline draws this waveform with: for a separate
	/// recorder that is the take's `audio.offset`, and for the camera's own
	/// track it is nothing at all. The one clock rule is the whole reason this
	/// takes it as an argument rather than knowing about takes.
	public static func edges(in waveform: Waveform, shift: Double = 0) -> [Double] {
		let level = decibels(waveform)
		guard level.count > 2 else { return [] }
		// The tenth percentile is the room: in five minutes of anybody talking,
		// most of the time nobody is.
		let floor = percentile(level, 0.1)
		let loud = floor + Float(loudBy)
		let quiet = floor + Float(quietBy)
		// A recording with no quiet in it — music, a tone, a room full of
		// machinery — has no edges to find, and inventing some would put marks
		// at whatever the arithmetic happened to produce. The *top* of the
		// file rather than some percentile of it: a take with one sentence in
		// five minutes is mostly room, and its ninetieth percentile is still
		// room, which is exactly the take that needs its two marks.
		guard percentile(level, 0.999) > loud else { return [] }

		let gap = Int((restingFor / step).rounded())
		let least = Int((soundingFor / step).rounded())
		var found: [Double] = []
		var index = 0
		while index < level.count {
			guard level[index] > loud else { index += 1; continue }
			// One run of talking: from here until it has been quiet long enough
			// to say it has stopped.
			var last = index
			var ahead = index
			while ahead < level.count {
				if level[ahead] > loud { last = ahead }
				else if ahead - last > gap { break }
				ahead += 1
			}
			if last - index >= least {
				// The attack and the release: back to where the sound left the
				// room's level, and forward to where it returns. Somebody
				// trimming wants the start of the breath, not the middle of it.
				var head = index
				while head > 0, level[head - 1] > quiet { head -= 1 }
				var tail = last
				while tail + 1 < level.count, level[tail + 1] > quiet { tail += 1 }
				found.append(Double(head) * step + shift)
				found.append(Double(tail + 1) * step + shift)
			}
			index = ahead
		}
		return found
	}

	/// The drawn envelope, in decibels.
	private static func decibels(_ waveform: Waveform) -> [Float] {
		waveform.envelope(ratePerSecond: 1 / step).map {
			20 * log10f(max($0, 1e-6))
		}
	}

	private static func percentile(_ values: [Float], _ fraction: Double) -> Float {
		guard !values.isEmpty else { return 0 }
		let sorted = values.sorted()
		let at = Int((Double(sorted.count - 1) * fraction).rounded())
		return sorted[at]
	}
}
