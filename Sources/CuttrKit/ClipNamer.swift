import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// What to call a clip, from what is said in it.
///
/// **Nothing leaves the machine.** `FoundationModels` is the model Apple ships
/// on this Mac; there is no network path and no account. The same promise the
/// transcriber makes, for the same reason: somebody's unreleased footage is not
/// something a cutting program may post to a server because it was convenient.
///
/// **A proposal, never a decision.** What comes back here is put in front of
/// somebody in an open text field with the text selected, ready to be typed
/// over. It is never written into a take without a person pressing Return, and
/// it never touches a slug: a slug is what the assembly file points at, so a
/// name arriving from a model changes at most what the clip is *called*.
///
/// **It invents, so this checks.** Asked to label "Alles von A bis Z" the model
/// has answered `Geburtstagssuppe` — a soup nobody mentioned. The instructions
/// below tell it to use only words from the passage, and
/// ``isGrounded(_:in:)`` then checks that it did; a proposal with a word in it
/// that nobody said is thrown away and the first words are used instead. The
/// caller is told which happened and says so, because a name somebody cannot
/// account for is a name they cannot trust.
///
/// **It works without the model.** Not every Mac has Apple Intelligence, some
/// have it switched off, and the one that has it refuses a passage now and then
/// on safety grounds — measured at two refusals in seventeen ordinary German
/// sentences about grandparents, so this is a normal path and not an edge case.
/// Every one of those ends in the same place: ``Transcript/phrase(_:limit:)``,
/// which is what this program did before there was a model at all.
public enum ClipNamer {

	/// Whether there is a model on this Mac to ask.
	public enum Availability: Sendable, Equatable {
		case available
		/// And why not, in words for somebody who might do something about it.
		case unavailable(String)

		public var isAvailable: Bool { self == .available }
	}

	/// A name to put in front of somebody, and where it came from.
	public struct Naming: Sendable, Equatable {
		public let name: String
		public let source: Source

		public enum Source: Sendable, Equatable {
			/// The model on this Mac read the words and proposed this.
			case model
			/// It proposed something that is not in the words. This is the
			/// first words instead; the string is what it said, so that the
			/// person can be told what was rejected on their behalf.
			case invented(String)
			/// There was no model to ask, or it would not answer. The string
			/// says which.
			case firstWords(String)
		}

		public init(name: String, source: Source) {
			self.name = name
			self.source = source
		}
	}

	/// About twenty characters — three or four words of German, which is a clip
	/// name somebody can read down a column of and a slug they can type.
	public static let length = 20

	public static var availability: Availability {
		#if canImport(FoundationModels)
		if #available(macOS 26, *) {
			switch SystemLanguageModel.default.availability {
			case .available:
				return .available
			case .unavailable(.deviceNotEligible):
				return .unavailable("this Mac does not have Apple Intelligence")
			case .unavailable(.appleIntelligenceNotEnabled):
				return .unavailable("Apple Intelligence is switched off in System Settings")
			case .unavailable(.modelNotReady):
				return .unavailable("the language model is still being fetched")
			case .unavailable:
				return .unavailable("this Mac's language model is not available")
			}
		}
		return .unavailable("macOS 26 or later has the language model this needs")
		#else
		return .unavailable("this build has no language model")
		#endif
	}

	/// What the model is told it is for.
	///
	/// Written as constraints rather than as an example, because an example is
	/// a thing to copy and the failure being guarded against is copying: given
	/// one sample label about a grandmother it will produce labels about
	/// grandmothers. The one rule that matters is the first — every word of the
	/// answer has to be a word somebody said — and it is checked afterwards
	/// rather than trusted.
	static let instructions = """
		You label clips in a video editor. You are given a passage of speech \
		transcribed from a recording. Answer with a label for it and nothing else.

		Rules:
		- Use only words that appear in the passage. Do not add a subject, an \
		object or a detail the passage does not contain.
		- Write it in the same language the passage is in.
		- At most about twenty characters, two or three words.
		- No quotation marks, no full stop, no explanation.
		"""

	/// A name for a clip whose words are `said`, falling back to `firstWords`.
	///
	/// Never throws and never returns nothing: every way this can fail is a way
	/// of ending up with the first words, which is a usable name.
	public static func propose(for said: String, orFirstWords firstWords: String) async -> Naming {
		let said = said.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !said.isEmpty else {
			return Naming(name: firstWords, source: .firstWords("nothing is said here"))
		}
		guard case .available = availability else {
			guard case .unavailable(let why) = availability else {
				return Naming(name: firstWords, source: .firstWords("no model"))
			}
			return Naming(name: firstWords, source: .firstWords(why))
		}

		#if canImport(FoundationModels)
		if #available(macOS 26, *) {
			do {
				let session = LanguageModelSession(instructions: instructions)
				// Greedy rather than sampled: naming the same sentence twice
				// should give the same name twice. A clip name that changes
				// because a die was rolled is a name nobody can check.
				let answer = try await session.respond(
					to: "Passage:\n\(said)",
					options: GenerationOptions(samplingMode: .greedy,
					                           maximumResponseTokens: 24))
				let proposed = tidy(answer.content)
				guard !proposed.isEmpty else {
					return Naming(name: firstWords, source: .firstWords("it had nothing to say"))
				}
				guard isGrounded(proposed, in: said) else {
					return Naming(name: firstWords, source: .invented(proposed))
				}
				return Naming(name: proposed, source: .model)
			} catch {
				// A refusal is the common one and reads as a crash if it is not
				// said out loud: the model declines a passage now and then for
				// reasons it does not explain, and the person pressing the key
				// has done nothing wrong.
				return Naming(name: firstWords,
				              source: .firstWords("the model would not name this one"))
			}
		}
		#endif
		return Naming(name: firstWords, source: .firstWords("no model on this Mac"))
	}

	// MARK: - Checking that it did not make it up

	/// Whether every word of `proposal` is accounted for by something in `said`.
	///
	/// Folded through ``Slug/make(from:)`` first, because that is already this
	/// program's one answer to "are these the same word": case, accents and
	/// punctuation away, `Größe` and `grosse` the same thing.
	///
	/// A word counts as accounted for when it shares a run of four letters with
	/// something somebody said. Loose on purpose, and the looseness is
	/// measured: German compounds at both ends and inflects, so `Radfahren` for
	/// `Fahrradfahren` and `Salate` for `Kartoffelsalat` are the model reading
	/// rather than inventing, and `Hackfleischsoße` for a recogniser's
	/// `Hackfleischsoce` is it quietly fixing a mishearing, which is better
	/// than the transcript and would be a shame to throw away.
	///
	/// **Only words of more than three letters are checked**, and that is the
	/// rule that makes the rest of it work. `der`, `die`, `das`, `an` carry no
	/// claim about the recording, and a model that writes `Die Fahrradtour`
	/// where nobody said `die` has invented nothing. It also stops the check
	/// from passing everything: `a` and `er` are inside almost every German
	/// word, so a test that let them count called `Geburtstagssuppe` grounded
	/// in `Alles von A bis Z`.
	///
	/// What is left is the failure worth catching — a content word out of
	/// nowhere, `Suppe` in a passage about the alphabet, `Alter` in a passage
	/// about hair — because those are the names that would be believed.
	public static func isGrounded(_ proposal: String, in said: String) -> Bool {
		let spoken = words(of: said)
		guard !spoken.isEmpty else { return false }
		let proposed = words(of: proposal)
		guard !proposed.isEmpty else { return false }
		let content = proposed.filter { $0.count > 3 }
		// A label made entirely of little words says nothing, but it has not
		// made anything up either — so it passes only if every one of them was
		// actually said.
		guard !content.isEmpty else { return proposed.allSatisfy(spoken.contains) }
		return content.allSatisfy { word in spoken.contains { shares($0, word) } }
	}

	/// Whether two words have four letters in a row in common.
	private static func shares(_ heard: String, _ word: String, run: Int = 4) -> Bool {
		let letters = Array(heard)
		guard letters.count >= run, word.count >= run else { return false }
		for start in 0 ... (letters.count - run)
		where word.contains(String(letters[start ..< start + run])) { return true }
		return false
	}

	private static func words(of text: String) -> [String] {
		Slug.make(from: text).split(separator: "-").map(String.init).filter { !$0.isEmpty }
	}

	/// The answer, as a clip name.
	///
	/// One line, no quotes, no full stop — a model asked for a label still
	/// wraps one in quotation marks about one time in ten, and `"Fahrradfahren"`
	/// slugs to `fahrradfahren` either way but reads as a mistake in the table.
	static func tidy(_ answer: String) -> String {
		let line = answer.split(separator: "\n", omittingEmptySubsequences: true).first ?? ""
		return line.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'“”„«»*.:;!?—–-"))
	}
}
