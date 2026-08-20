import Foundation

/// Something that happened in a take that nobody said.
///
/// A laugh is not a word and a transcript that leaves it out is a transcript of
/// a different recording. The moment somebody laughs is a moment an editor cuts
/// to, and until now the only way to find it was to listen — which is the thing
/// this program exists to stop having to do.
///
/// **On the video's clock**, like every other time in a take. The classifier is
/// pointed at whichever file has the better microphone, which for a real shoot
/// is the separate recorder, and that file has a clock of its own. The
/// conversion happens once, in ``Transcriber/Source/onVideoClock(_:)-(SoundEvent)``,
/// before a hit ever becomes one of these — the same route a word takes, and
/// deliberately the same arithmetic.
///
/// **The identifier is what goes in the file, not the label.** `laughter` is
/// written down; `[Lachen]` is what a German reader sees. A file whose meaning
/// changes with the system language is a file that cannot be shared, and the
/// take file is the product.
public struct SoundEvent: Sendable, Equatable {

	/// What it is: `laughter`, `applause`, … One of ``SoundEvent/known``, in
	/// principle — a `String` and not an enum in practice, because a later
	/// version of this program will add a kind and an older build must still be
	/// able to read, show and re-write a file that has one.
	public var kind: String
	public var start: Double
	public var end: Double
	/// How sure the classifier was, 0 to 1. Kept because it is the number
	/// somebody argues with when a laugh in the file was not a laugh.
	public var confidence: Double

	public init(kind: String, start: Double, end: Double, confidence: Double = 1) {
		self.kind = kind
		self.start = Swift.min(start, end)
		self.end = Swift.max(start, end)
		self.confidence = Swift.max(0, Swift.min(1, confidence))
	}

	public var duration: Double { end - start }

	public func contains(_ time: Double) -> Bool { time >= start && time < end }

	public func overlaps(_ other: SoundEvent) -> Bool { start < other.end && other.start < end }

	// MARK: - Which of the 303 are worth having

	/// The kinds this program writes down.
	///
	/// Apple's classifier knows 303 sounds, and a transcript with 303 kinds of
	/// annotation in it is not a transcript, it is a log. These seven are the
	/// ones an editor *cuts on*: the moment a room laughs, claps, cheers, cries,
	/// sings, coughs or drops to a whisper is a moment somebody goes looking
	/// for. Nothing here names a fridge hum or a car passing, because knowing
	/// about those changes no cut.
	///
	/// `sneeze` is deliberately absent although the classifier has it and it
	/// sounds like it belongs. Measured on 332 seconds of a real family
	/// interview it fired eight times, every one of them within a second of a
	/// laugh and none of them a sneeze — twice at a confidence above the floor
	/// below, so no threshold saves it. A class that is wrong every time it
	/// fires is worse than a class that is missing, because the wrong one is
	/// believed.
	public static let known = [
		"laughter", "applause", "cheering", "crying", "singing", "cough", "whispering",
	]

	/// What the classifier's own name for a sound becomes here.
	///
	/// The 303 are a taxonomy, and its branches fire together: one laugh in the
	/// measured take produced `laughter`, `giggling`, `belly_laugh`,
	/// `chuckle_chortle` and `snicker` on the same second of audio. Written out
	/// as five events that is five lines in the file for one thing that
	/// happened, and none of the five is a distinction anybody cuts on. So a
	/// family folds to the branch somebody would say out loud, the confidences
	/// merge, and `[laughter]` appears once.
	///
	/// `nil` for the other 290-odd, which are not written down at all.
	public static func kind(forClassifier identifier: String) -> String? {
		switch identifier {
		case "laughter", "giggling", "belly_laugh", "chuckle_chortle", "snicker",
		     "baby_laughter":
			return "laughter"
		case "applause", "clapping":
			return "applause"
		case "cheering":
			return "cheering"
		case "crying_sobbing", "baby_crying":
			return "crying"
		case "singing", "choir_singing":
			return "singing"
		case "cough":
			return "cough"
		case "whispering":
			return "whispering"
		default:
			return nil
		}
	}

	/// What a reader sees, in their own language where there is one.
	///
	/// The identifier is the fact and this is the presentation of it. Only the
	/// languages this program is actually used in are here; anything else gets
	/// the identifier, which is English and is at least true.
	public var label: String {
		let language = Locale.current.language.languageCode?.identifier ?? "en"
		guard let table = Self.labels[language] else { return kind }
		return table[kind] ?? kind
	}

	private static let labels: [String: [String: String]] = [
		"de": [
			"laughter": "Lachen", "applause": "Applaus", "cheering": "Jubel",
			"crying": "Weinen", "singing": "Gesang", "cough": "Husten",
			"whispering": "Flüstern",
		],
	]

	// MARK: - From windows to events

	/// A window whose confidence is below this is not evidence of anything, and
	/// is not allowed to join an event either.
	public static let joining = 0.3

	/// And an event needs one window at least this sure before it is written
	/// down. Measured: on the take above, 0.6 is the line between the six
	/// laughs a person hears and the shrug the classifier makes at ordinary
	/// speech. It is not a delicate number — 0.55 and 0.65 give the same six —
	/// but it is not a guess either.
	///
	/// It will still be wrong sometimes. That is what the file being text is
	/// for: a laugh that was not a laugh is one block to delete, in an editor,
	/// and it stays deleted.
	public static let floor = 0.6

	/// Windows the classifier missed inside one event. One hop of the analysis
	/// window, so a laugh that dips for half a second stays one laugh.
	public static let bridging = 0.5

	/// Turns overlapping windows into the events they are evidence of.
	///
	/// The classifier is asked for one-second windows at half-second hops, so a
	/// two-second laugh comes back as four or five hits saying the same thing.
	/// Those are not four laughs. Windows of one kind that touch — or are within
	/// ``bridging`` of touching — become one event running from the first's
	/// start to the last's end, as sure as the surest of them.
	///
	/// The times therefore *bracket* the laugh rather than trim it: they are the
	/// audio the classifier was listening to when it was sure. That is the right
	/// way round for the thing they are for, which is making a clip that has the
	/// whole laugh in it.
	///
	/// Finally, two kinds that overlap are one moment of audio heard two ways,
	/// and the surer reading wins. A cough and a laugh do not happen in the same
	/// second; a classifier saying both means it is unsure which.
	public static func merge(
		_ windows: [SoundEvent], joining: Double = SoundEvent.joining,
		floor: Double = SoundEvent.floor, bridging: Double = SoundEvent.bridging
	) -> [SoundEvent] {
		var events: [SoundEvent] = []
		let heard = windows.filter { $0.confidence >= joining }
		for kind in Set(heard.map(\.kind)).sorted() {
			var run: SoundEvent?
			for window in heard.filter({ $0.kind == kind }).sorted(by: { $0.start < $1.start }) {
				guard var open = run else { run = window; continue }
				if window.start <= open.end + bridging {
					open.end = Swift.max(open.end, window.end)
					open.confidence = Swift.max(open.confidence, window.confidence)
					run = open
				} else {
					events.append(open)
					run = window
				}
			}
			if let open = run { events.append(open) }
		}

		// The surest first, so that a weaker reading of the same seconds is the
		// one dropped. Ties break on the earlier event, so the answer does not
		// depend on the order the windows arrived in.
		var kept: [SoundEvent] = []
		for event in events.filter({ $0.confidence >= floor })
			.sorted(by: { ($0.confidence, -$0.start) > ($1.confidence, -$1.start) })
		{
			guard !kept.contains(where: { $0.overlaps(event) }) else { continue }
			kept.append(event)
		}
		return kept.sorted { ($0.start, $0.kind) < ($1.start, $1.kind) }
	}
}
