import Testing
@testable import CuttrKit

@Suite struct SlugTests {

	@Test func lowercasesAndHyphenates() {
		#expect(Slug.make(from: "Installing the driver") == "installing-the-driver")
		#expect(Slug.make(from: "Intro — hello, and welcome!") == "intro-hello-and-welcome")
	}

	@Test func foldsGermanRatherThanDroppingIt() {
		#expect(Slug.make(from: "Präzision") == "praezision")
		#expect(Slug.make(from: "Größe") == "groesse")
		#expect(Slug.make(from: "Öffnen") == "oeffnen")
	}

	@Test func foldsOtherDiacriticsToTheirBase() {
		#expect(Slug.make(from: "Café") == "cafe")
	}

	@Test func neverStartsOrEndsWithAHyphen() {
		#expect(Slug.make(from: "  —  take two  — ") == "take-two")
		#expect(Slug.make(from: "!!!") == "")
	}

	@Test func validityIsAFixedPointOfMaking() {
		#expect(Slug.isValid("demo-install"))
		#expect(!Slug.isValid("Demo Install"))
		#expect(!Slug.isValid(""))
		#expect(!Slug.isValid("trailing-"))
	}

	@Test func uniquingNumbersFromTwo() {
		#expect(Slug.unique("intro", taken: []) == "intro")
		#expect(Slug.unique("intro", taken: ["intro"]) == "intro-2")
		#expect(Slug.unique("intro", taken: ["intro", "intro-2"]) == "intro-3")
	}

	@Test func placeholdersAreNumberedFromOne() {
		// `clip`, `clip-2` is what `unique` would give and it reads as though
		// the first one were special. A list somebody is about to work through
		// should start at one.
		var taken = Set<String>()
		for expected in ["clip-1", "clip-2", "clip-3"] {
			let slug = Slug.numbered(taken: taken)
			#expect(slug == expected)
			taken.insert(slug)
		}
	}

	@Test func aDeletedNumberIsHandedOutAgain() {
		// Otherwise a session of marking and undoing walks up to `clip-40`
		// with four clips on the timeline.
		#expect(Slug.numbered(taken: ["clip-1", "clip-3"]) == "clip-2")
	}

	@Test func anUnnameableClipStillGetsASlug() {
		// A clip made by pressing `s` has no name yet, and it still has to be
		// referenceable the moment it exists.
		#expect(Slug.unique(Slug.make(from: ""), taken: []) == "clip")
	}
}
