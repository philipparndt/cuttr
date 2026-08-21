import Foundation

/// Bringing the clips of one recording level with each other.
///
/// Loudness is measured per recording, and for a take somebody speaks through
/// at one level that is the right grain — one pass serves every programme that
/// uses it. Within one recording it is not: two children at the same microphone
/// are ten decibels apart, and a single figure for the whole take brings all of
/// it to a target while leaving them exactly as far apart as they were.
///
/// So this is the other half of it, and it belongs where the clips were cut,
/// because that is the one place they can be heard against each other.
public enum Levelling {

	/// A level in decibels, as the amplitude a mix multiplies by.
	///
	/// Decibels are what a person reads and what the file says; a mix and a
	/// waveform both want the ratio. Said once because it was written out at
	/// every place that needed it, and a formula copied is a formula that ends
	/// up different somewhere.
	public static func amplitude(_ decibels: Double) -> Double {
		decibels == 0 ? 1 : pow(10, decibels / 20)
	}

	/// How far a trim is allowed to go.
	///
	/// A trim is a correction, not a rescue. Past about twelve decibels what
	/// comes up is the room rather than the voice, and a clip that needs more
	/// than that needs re-recording or leaving alone — quietly amplifying it to
	/// match a conversation would make the take sound worse while claiming to
	/// have levelled it.
	public static let limit = 12.0

	/// The trims that bring these clips level with one another, given what each
	/// one measured, in LUFS.
	///
	/// **Matched to the median, not to the loudest and not to a target.** The
	/// median is the level most of the take already is, so most clips barely
	/// move and the ones that were out come to meet them. Matching to the
	/// loudest turns every other clip up and brings the room up with it;
	/// matching to a fixed number is the *project's* job — `output.audio.target`
	/// already does it for the whole programme — and doing it here as well
	/// would be two things pulling at the same knob.
	///
	/// A clip that measured nothing — silence, or nobody speaking in it — keeps
	/// the trim it had. There is no level to match, and amplifying silence to
	/// meet a conversation is the one outcome nobody wants.
	///
	/// Rounded to a tenth of a decibel, which is finer than anybody can hear
	/// and is what the take file writes: a value the file cannot hold exactly
	/// would come back different on the next read and leave the document
	/// looking edited when nothing had changed.
	public static func match(
		_ measured: [Double?], existing: [Double]? = nil, limit: Double = Levelling.limit
	) -> [Double] {
		let heard = measured.compactMap { $0 }.sorted()
		let held = existing ?? [Double](repeating: 0, count: measured.count)
		guard !heard.isEmpty else { return held }
		let middle = heard.count.isMultiple(of: 2)
			? (heard[heard.count / 2 - 1] + heard[heard.count / 2]) / 2
			: heard[heard.count / 2]

		return measured.indices.map { index in
			guard let loudness = measured[index] else {
				return index < held.count ? held[index] : 0
			}
			let wanted = middle - loudness
			return (min(max(wanted, -limit), limit) * 10).rounded() / 10
		}
	}
}
