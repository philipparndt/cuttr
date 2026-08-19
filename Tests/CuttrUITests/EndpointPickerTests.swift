import AppKit
import CuttrCompose
import CuttrKit
import Testing
@testable import CuttrUI

/// What an overlay can hang on, and how it is shown.
///
/// The list a combo box offered was both ambiguous and short: `clip-4` with no
/// take on it, and no `as:` placements at all.
@Suite @MainActor struct EndpointPickerTests {

	private func vocabulary() -> ComposeDocument.Vocabulary {
		var found = ComposeDocument.Vocabulary()
		found.groups = ["questions"]
		found.labels = ["question1"]
		found.takeNames = ["mia-take-1", "mia-take-2"]
		found.items = [
			.init(take: "mia-take-1", slug: "clip-4", name: "The answer", tags: [],
			      length: 4, reference: "mia-take-1/clip-4"),
			.init(take: "mia-take-2", slug: "clip-4", name: "Again", tags: [],
			      length: 5, reference: "mia-take-2/clip-4"),
			.init(take: "mia-take-1", slug: "intro", name: "Intro", tags: [],
			      length: 3, reference: "intro"),
		]
		return found
	}

	@Test func everyKindOfNameIsOffered() {
		let catalogue = EndpointCatalogue(vocabulary())
		#expect(catalogue.entries.contains { $0.kind == .section && $0.reference == "@questions" })
		#expect(catalogue.entries.contains { $0.kind == .placement && $0.reference == "@question1" })
		#expect(catalogue.entries.filter { $0.kind == .clip }.count == 3)
	}

	/// The file writes the short form; the panel shows the long one.
	@Test func aBareSlugIsShownWithItsTake() {
		let catalogue = EndpointCatalogue(vocabulary())
		#expect(catalogue.path(for: .clip(ClipReference("intro"))) == "mia-take-1/intro")
		#expect(catalogue.path(for: .clip(ClipReference("mia-take-2/clip-4"))) == "mia-take-2/clip-4")
		#expect(catalogue.path(for: .group("question1")) == "@question1")
		// A slug that is not there is shown as the file has it, not invented.
		#expect(catalogue.path(for: .clip(ClipReference("gone"))) == "gone")
		#expect(catalogue.knows(.clip(ClipReference("gone"))) == false)
		#expect(catalogue.knows(.group("question1")))
	}

	@Test func searchingMatchesWordByWord() {
		let catalogue = EndpointCatalogue(vocabulary())
		#expect(catalogue.matching("mia 4").count == 2)
		#expect(catalogue.matching("take-1/clip").map(\.path) == ["mia-take-1/clip-4"])
		#expect(catalogue.matching("answer").map(\.path) == ["mia-take-1/clip-4"])
		#expect(catalogue.matching("").count == catalogue.entries.count)
	}

	/// The dialog opens on what the overlay already hangs on, headings and all.
	@Test func itOpensOnWhatIsSetAndGroupsByTake() {
		_ = NSApplication.shared
		var chosen: String?
		let picker = EndpointPicker(catalogue: EndpointCatalogue(vocabulary()),
		                            current: "mia-take-2/clip-4") { chosen = $0 }
		picker.loadView()
		#expect(picker.chosen?.reference == "mia-take-2/clip-4")
		#expect(picker.chosen?.path == "mia-take-2/clip-4")

		// A placement named with `as:` is reachable, which it was not before.
		picker.searchField.stringValue = "question1"
		picker.rebuild()
		#expect(picker.chosen?.reference == "@question1")
		picker.confirm()
		#expect(chosen == "@question1")
	}
}
