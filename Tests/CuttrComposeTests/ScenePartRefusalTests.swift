import Foundation
import Testing
@testable import CuttrCompose

/// A part the reader cannot understand is refused, not dropped.
///
/// This is the bug that made a card render black. `background:` written as a
/// list of two colours rather than as `{from:, to:}` was skipped in silence,
/// the scene rendered without its ground, and on a black card that is a black
/// frame with nothing anywhere saying why. Measured on the rendered file:
/// thirty-eight of forty pixels at `#000000`, the other two the title.
@Suite struct ScenePartRefusalTests {

	private func project(_ part: String) throws -> Project {
		try ProjectReader.read("""
		cuttr-project: 1

		timeline:
		  - clip: intro

		scenes:
		  opening:
		    parts:
		\(part)
		""")
	}

	private func refuses(_ part: String, saying fragment: String) {
		do {
			_ = try project(part)
			Issue.record("read a part it should have refused: \(part)")
		} catch let error as ProjectError {
			let said = error.errorDescription ?? ""
			#expect(said.contains(fragment), "said \(said)")
		} catch {
			Issue.record("wrong error: \(error)")
		}
	}

	@Test func aGradientWrittenAsAListIsRefusedByName() {
		refuses("""
		      - background: ["#203050", "#050510"]
		        keys:
		          - {t: 0}
		""", saying: "background: [#203050, #050510]")
	}

	@Test func aPartThatNamesNoKindSaysWhatItDidName() {
		refuses("""
		      - colour: "#203050"
		        keys:
		          - {t: 0}
		""", saying: "colour, keys")
	}

	@Test func aColourThatIsNotAColourIsRefused() {
		refuses("""
		      - shape: bright-red
		        keys:
		          - {t: 0}
		""", saying: "shape: bright-red")
	}

	/// A part with no keys is never anywhere, so it can never be drawn.
	@Test func aPartWithNoKeysIsRefused() {
		refuses("""
		      - text: "hello"
		""", saying: "keys: none")
	}

	/// …and the forms that were always right still read.
	@Test func theFormsThatWorkStillWork() throws {
		let project = try project("""
		      - background: {from: "#203050", to: "#050510"}
		        keys:
		          - {t: 0}
		      - background: "#101418"
		        keys:
		          - {t: 0}
		      - shape: "#ffffff"
		        keys:
		          - {t: 0, width: 0.4}
		      - image: logo.png
		        keys:
		          - {t: 0}
		      - text: "{{title}}"
		        keys:
		          - {t: 0}
		""")
		#expect(project.scenes["opening"]?.parts.count == 5)
	}
}
