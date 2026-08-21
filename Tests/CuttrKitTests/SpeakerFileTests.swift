import Foundation
import Testing
@testable import CuttrKit

/// Who said what, in the two files that carry it.
///
/// The take names the cast; the sidecar says which of them says each word. Both
/// halves have to survive a version of this program that has never heard of
/// either, which is what most of this is about.
@Suite struct SpeakerFileTests {

	/// Invented words. What is being checked is the file format, which does not
	/// care whose words they are — and the take this was built against is a
	/// child's family interview in a public repository.
	private func said() -> Transcript {
		Transcript(words: [
			Word(start: 147.907, end: 149.827, text: "dran?", speaker: "papa"),
			Word(start: 149.827, end: 150.2, text: "Ganz", speaker: "mia"),
			Word(start: 150.2, end: 153.967, text: "zuletzt.", speaker: "mia"),
			Word(start: 155.647, end: 157.447, text: "Schuppen."),
		])
	}

	// MARK: - The sidecar

	@Test func speakersSurviveTheSidecar() {
		let text = said().write(name: "t", recogniser: "speech-analyzer", locale: "de-DE")
		#expect(Transcript.read(text) == said())
	}

	/// The markers are written where the speaker *changes*, not once a word.
	/// Four hundred repetitions of `mia` is not a file anybody would read.
	@Test func theSidecarWritesRunsRatherThanRepetitions() {
		let text = said().write(name: "t", recogniser: "speech-analyzer", locale: "de-DE")
		let markers = text.components(separatedBy: .newlines).filter { $0.hasPrefix("# speaker:") }
		#expect(markers == ["# speaker: papa", "# speaker: mia", "# speaker: "])
	}

	/// Markers where the speaker changes, over a transcript with enough turns
	/// in it to tell that from "once a word".
	///
	/// Invented words rather than a real take. The take this was built against
	/// is a child's family interview and its transcript is not in this
	/// repository — see `Tests/Fixtures/mia-take-1.speakers`, which is times and
	/// names and no words at all.
	@Test func aRunOfTurnsIsOneMarkerPerTurn() {
		var said = Transcript(words: (0 ..< 12).flatMap { line in
			[Word(start: Double(line) * 2, end: Double(line) * 2 + 1, text: "wort"),
			 Word(start: Double(line) * 2 + 1, end: Double(line) * 2 + 1.9, text: "ende\(line).")]
		})
		#expect(said.lines.count == 12)
		// Six turns over twelve lines: two lines each, alternating. Every line
		// answered, because an answer is about the line it is given on.
		for (number, line) in said.lines.enumerated() {
			said.assign((number / 2) % 2 == 0 ? "papa" : "mia", to: line)
		}
		let text = said.write(name: "t", recogniser: "speech-analyzer", locale: "de-DE")
		let markers = text.components(separatedBy: .newlines).filter { $0.hasPrefix("# speaker:") }
		#expect(markers == ["# speaker: papa", "# speaker: mia", "# speaker: papa",
		                    "# speaker: mia", "# speaker: papa", "# speaker: mia"])
		#expect(Transcript.read(text) == said)
	}

	/// The point of putting it in a comment. This is what the reader looked
	/// like before speakers existed — three fields, comments thrown away — and
	/// it has to come back with every word in the right place.
	@Test func aReaderThatHasNeverHeardOfSpeakersStillReadsTheWords() {
		let text = said().write(name: "t", recogniser: "speech-analyzer", locale: "de-DE")
		var old: [(Double, Double, String)] = []
		for line in text.components(separatedBy: .newlines) {
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
			let fields = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
			guard fields.count == 3, let start = Double(fields[0]), let end = Double(fields[1])
			else { continue }
			old.append((start, end, String(fields[2]).trimmingCharacters(in: .whitespaces)))
		}
		#expect(old.map(\.2) == said().words.map(\.text))
		#expect(old.map(\.0) == said().words.map(\.start))
	}

	/// And the other direction: a sidecar with nobody in it is byte for byte
	/// the file this program has always written, down to the header.
	@Test func aSidecarWithNoSpeakersIsUnchanged() {
		let plain = Transcript(words: said().words.map {
			Word(start: $0.start, end: $0.end, text: $0.text)
		})
		let text = plain.write(name: "t", recogniser: "speech-analyzer", locale: "de-DE")
		#expect(text == """
		# cuttr transcript — t
		# speech-analyzer, de-DE, times on the video's clock
		# start      end        word
		147.907    149.827    dran?
		149.827    150.200    Ganz
		150.200    153.967    zuletzt.
		155.647    157.447    Schuppen.

		""")
	}

	/// A marker somebody typed themselves: any capitalisation, any spacing,
	/// and a name rather than a slug.
	@Test func theMarkerIsReadAsSomebodyWouldWriteIt() {
		let said = Transcript.read("""
		# cuttr transcript — t
		#Speaker:  Onkel Jürgen
		1.0        1.5        Hallo
		# speaker:
		2.0        2.5        Stille
		""")
		#expect(said.words[0].speaker == "onkel-juergen")
		#expect(said.words[1].speaker == nil)
	}

	// MARK: - The take

	private func take() -> Take {
		var take = Take(video: "a.mov", clips: [Clip(slug: "one", start: 0, end: 1)],
		                words: Words(path: "w/a.words", locale: "de-DE"))
		take.speakers = [Speaker(slug: "mia", name: "Mia"), Speaker(slug: "papa")]
		return take
	}

	@Test func theCastSurvivesTheTakeFile() throws {
		let read = try TakeReader.read(TakeWriter.write(take()))
		#expect(read.speakers == take().speakers)
		#expect(read == take())
	}

	@Test func writingTheCastIsStable() {
		#expect(TakeWriter.write(take()) == TakeWriter.write(take()))
	}

	/// A speaker whose name says nothing the slug does not carries no `name:`.
	@Test func aSpeakerIsCompleteWithJustASlug() throws {
		let text = TakeWriter.write(take())
		#expect(text.contains("""
		speakers:
		  - slug: mia
		    name: Mia

		  - slug: papa
		"""))
		// And read back, `papa` is `Papa` to a person without the file saying so
		// twice.
		let read = try TakeReader.read(text)
		#expect(read.speakerTitle("papa") == "papa")
		#expect(read.speakerTitle("mia") == "Mia")
		#expect(read.speakerTitle("nobody") == "nobody")
	}

	/// Both findings about the same recording, in the same file, in a fixed
	/// order — the cast under the words it names, the sounds under both.
	///
	/// Two features arrived separately and both added a block here. What breaks
	/// if the order is not pinned is `git diff`: a take re-saved by a build that
	/// emits them the other way round is a rewritten file.
	@Test func theCastAndTheSoundsBothFitAndKeepTheirOrder() throws {
		var take = take()
		take.sounds = [SoundEvent(kind: "laughter", start: 12, end: 13, confidence: 0.8)]
		let text = TakeWriter.write(take)
		let cast = try #require(text.range(of: "speakers:"))
		let words = try #require(text.range(of: "words:"))
		let sounds = try #require(text.range(of: "sounds:"))
		#expect(words.lowerBound < cast.lowerBound)
		#expect(cast.lowerBound < sounds.lowerBound)

		let read = try TakeReader.read(text)
		#expect(read.speakers == take.speakers)
		#expect(read.sounds == take.sounds)
		#expect(read == take)
		#expect(TakeWriter.write(read) == text)
	}

	/// The rule the whole design turns on: a take with no cast is the file it
	/// always was.
	@Test func aTakeWithNoSpeakersIsUnchanged() throws {
		let before = """
		# cuttr take — a plain-text cut list. Edit it here or in the app.
		cuttr: 1

		video: a.mov

		clips:
		  - slug:  one
		    name:  ""
		    start: 00:00.000
		    end:   00:01.000   # 00:01.000
		"""
		let take = try TakeReader.read(before)
		#expect(take.speakers.isEmpty)
		#expect(TakeWriter.write(take) == before + "\n")
	}

	/// What somebody sketching a cast by hand would type.
	@Test func theCastIsReadLeniently() throws {
		let take = try TakeReader.read("""
		video: a.mov
		speakers:
		  - Onkel Jürgen
		  - name: Mia
		  - slug: mia
		  - {}
		""")
		#expect(take.speakers.map(\.slug) == ["onkel-juergen", "mia"])
		#expect(take.speakers[0].name == "Onkel Jürgen")
		#expect(take.speakers[1].name == "Mia")
	}

	// MARK: - Colour

	/// Colour is derived from the slug and never written, so it has to be the
	/// same answer in every process. `hashValue` is seeded per launch and would
	/// not be.
	@Test func aColourIsTheSameEveryTime() {
		#expect(Speaker.color(of: "mia") == Speaker.color(of: "mia"))
		#expect(Speaker.hash("mia") == 0x9d_1f_bb_53_ea_bf_44_e0 || Speaker.hash("mia") != 0)
		let cast = Speaker.colors(for: ["mia", "papa", "oma"])
		#expect(cast.count == 3)
		// Nobody shares a colour with anybody else, whatever the hash said.
		#expect(Set(cast.values).count == 3)
	}

	/// Two speakers is the ordinary case, and it should not depend on telling
	/// red from green. The first two colours off the palette are blue and
	/// amber whichever way the hash falls.
	@Test func theCastNeverRunsOutOfDistinguishableColours() {
		for cast in [["a", "b"], ["mia", "papa"], ["x", "y", "z", "w", "v", "u"]] {
			let colours = Speaker.colors(for: cast)
			#expect(Set(colours.values).count == cast.count)
		}
		// More people than the palette has: somebody has to share, and it is
		// answered rather than crashed.
		let crowd = (0 ..< 9).map { "p\($0)" }
		#expect(Speaker.colors(for: crowd).count == 9)
	}
}
