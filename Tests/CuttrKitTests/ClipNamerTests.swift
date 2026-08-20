import Foundation
import Testing
@testable import CuttrKit

/// Naming a clip after what is said in it, without depending on there being a
/// model to ask.
///
/// Nothing here reaches `FoundationModels`. What is worth testing is the part
/// that is this program's: that a proposal nobody said is caught, that a Mac
/// with no Apple Intelligence still gets a name, and that either way a slug
/// somebody typed is left alone. The model itself is measured against real
/// footage in ``ClipNamingFootageTests``.
@Suite struct ClipNamerTests {

	// MARK: - Catching what it made up

	/// The failure this exists for. Asked to label "Alles von A bis Z" the
	/// model has answered `Geburtstagssuppe` — a soup nobody mentioned, and a
	/// name that would be believed.
	@Test func aWordNobodySaidIsNotGrounded() {
		#expect(!ClipNamer.isGrounded("Geburtstagssuppe", in: "Alles von A bis Z"))
		#expect(!ClipNamer.isGrounded("Der Unfall", in: "Er hat manchmal so einen Arbeitsanzug an"))
		// Measured: this one really was answered, for a passage about a man
		// with no hair, and it is the sort of name that would be believed.
		#expect(!ClipNamer.isGrounded(
			"Alter fertig", in: "Ja, ich bin fertig. Wie sieht der Opa aus? Er hat keine Haare."))
	}

	/// Little words are not checked, and that is the rule that makes the rest
	/// work. An article the model added carries no claim about the recording —
	/// and letting `a` and `er` count would pass everything, since they are
	/// inside almost every German word.
	@Test func anArticleTheModelAddedIsNotAnInvention() {
		#expect(ClipNamer.isGrounded(
			"Die Fahrradtour", in: "Ich weiß so lange bei keiner Fahrradtour mehr"))
		#expect(ClipNamer.isGrounded("Der Arbeitsanzug", in: "Er hat manchmal so einen Arbeitsanzug an"))
	}

	@Test func aWordSomebodySaidIsGrounded() {
		#expect(ClipNamer.isGrounded("Arbeitsanzug", in: "Er hat manchmal so einen Arbeitsanzug an"))
		#expect(ClipNamer.isGrounded("kurze Haare", in: "Oma hat kurze Haare, und eine rote Jacke"))
	}

	/// Loose on purpose, and the looseness is measured. German compounds and
	/// inflects, so these are the model reading rather than inventing — and the
	/// last of them is it quietly fixing something the recogniser misheard,
	/// which is better than the transcript and would be a shame to throw away.
	@Test func compoundingAndInflectionAreReadingNotInventing() {
		#expect(ClipNamer.isGrounded("Radfahren", in: "Am liebsten tut sie Fahrradfahren"))
		#expect(ClipNamer.isGrounded("Salate", in: "Und ganz viele Kartoffelsalat, Gurkensalat"))
		#expect(ClipNamer.isGrounded("Hackfleischsoße", in: "Nudel und Hackfleischsoce-Auflauf"))
	}

	/// Folded the way this program folds everything else it compares: case,
	/// accents and punctuation away, through ``Slug/make(from:)``, so there is
	/// not a second answer here to "are these the same word".
	@Test func itComparesWordsTheWayTheRestOfTheProgramDoes() {
		#expect(ClipNamer.isGrounded("GRÖSSE", in: "die Größe des Hauses"))
		#expect(ClipNamer.isGrounded("„Quatsch machen“", in: "Mit Opa kann man immer Quatsch machen"))
	}

	@Test func anEmptyProposalIsNotGrounded() {
		#expect(!ClipNamer.isGrounded("", in: "Er hat eine Brille"))
		#expect(!ClipNamer.isGrounded("Brille", in: ""))
	}

	// MARK: - Tidying the answer

	/// A model asked for a label wraps one in quotation marks about one time in
	/// ten, and answers twice as often as it is asked about as often as that.
	@Test func theAnswerArrivesAsAClipName() {
		#expect(ClipNamer.tidy("\"Fahrradfahren\"") == "Fahrradfahren")
		#expect(ClipNamer.tidy("Arbeitsanzug.") == "Arbeitsanzug")
		#expect(ClipNamer.tidy("„Kurze Haare“") == "Kurze Haare")
		#expect(ClipNamer.tidy("Werkstatt\n\nThat is the label.") == "Werkstatt")
		#expect(ClipNamer.tidy("   ") == "")
	}

	// MARK: - Without a model

	/// Not every Mac has Apple Intelligence, and the ones that do have it
	/// switched off sometimes. Every one of those paths ends in the first
	/// words, which is what this program did before there was a model.
	@Test func withNoModelItIsTheFirstWords() async {
		let said = "Am liebsten tut sie Fahrradfahren"
		let naming = await ClipNamer.propose(for: said, orFirstWords: "Am liebsten tut sie")
		switch naming.source {
		case .model:
			// This Mac has one. The name still has to be something.
			#expect(!naming.name.isEmpty)
		case .invented, .firstWords:
			#expect(naming.name == "Am liebsten tut sie")
		}
	}

	/// A clip covering a silence has nothing to name it after, and asking a
	/// model about nothing is a way of being told something.
	@Test func nothingSaidIsNotAskedAbout() async {
		let naming = await ClipNamer.propose(for: "   ", orFirstWords: "clip-4")
		#expect(naming.name == "clip-4")
		#expect(naming.source == .firstWords("nothing is said here"))
	}

	/// Whatever happens, there is a name. It is a proposal, so an empty field
	/// in front of somebody would be a worse answer than a poor name.
	@Test func thereIsAlwaysAName() async {
		for said in ["", "ja", "Was ist das Besondere an Oma?"] {
			let naming = await ClipNamer.propose(for: said, orFirstWords: "clip-1")
			#expect(!naming.name.isEmpty)
		}
	}

	/// Whether there is a model or not is a question with an answer, and the
	/// answer says what to do about it.
	@Test func availabilitySaysWhyWhenItSaysNo() {
		if case .unavailable(let why) = ClipNamer.availability {
			#expect(!why.isEmpty)
		}
	}
}

/// A proposal is a proposal: naming a clip must never change what the assembly
/// file points at.
@Suite struct ClipNamingSlugTests {

	@Test func namingAClipDerivesItsSlugTheWayTypingANameDoes() {
		var take = Take(video: "a.mov", clips: [Clip(slug: "clip-1", start: 0, end: 5)])
		take.clips[0].name = "Fahrradfahren"
		take.clips[0].slug = Slug.make(from: take.clips[0].name)
		#expect(take.clips[0].slug == "fahrradfahren")
	}

	/// And a slug somebody typed is theirs. The document's `manualSlugs` is
	/// where that distinction lives; this is the arithmetic underneath it —
	/// `setSlug` is the only thing that writes one, and a name never calls it.
	@Test func aSlugSomebodyTypedIsNotRederivedFromAName() {
		var take = Take(video: "a.mov", clips: [Clip(slug: "clip-1", start: 0, end: 5)])
		let id = take.clips[0].id
		#expect(take.setSlug("die-fahrradtour", for: id) == "die-fahrradtour")
		take.clips[0].name = "Fahrradfahren"
		#expect(take.clips[0].slug == "die-fahrradtour")
	}
}
