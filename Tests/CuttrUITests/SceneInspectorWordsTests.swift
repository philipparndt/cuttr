import AppKit
import CuttrCompose
import CuttrKit
import Testing
@testable import CuttrUI

/// What the inspector says, and where it says it.
///
/// Two complaints, both of them fair. A key could not state the gradient — so a
/// background moved in opacity and not in the thing it *is* — and the values at
/// the top of the panel read as global settings the keys ought to obey, because
/// nothing on screen said what the two groups were to each other.
@Suite @MainActor struct SceneInspectorWordsTests {

	private func scene() -> Scene {
		Scene(parts: [
			.init(content: .background(Scene.Background(
				from: RGBA(hex: "#0b1220")!, to: RGBA(hex: "#1d3557")!, angle: 90)),
			      keys: [.init(t: 0, opacity: 0),
			             .init(t: 1, opacity: 1, color: RGBA(hex: "#402015")!,
			                   to: RGBA(hex: "#f4a261")!, angle: 350, ease: .out)]),
			.init(content: .text("{{title}}", style: "title", tracking: 0.1),
			      keys: [.init(t: 0, x: 0.5, y: 0.5, opacity: 1),
			             .init(t: 1, opacity: 1, ease: .out)]),
			.init(content: .shape(fill: .white, corner: 0.01),
			      keys: [.init(t: 0, x: 0.5, y: 0.3, width: 0.3, height: 0.004),
			             .init(t: 1, width: 0.6, ease: .out)]),
			.init(content: .bar(Scene.Bar()),
			      keys: [.init(t: 0, x: 0.5, y: 0.5, progress: 0),
			             .init(t: 1, progress: 1, ease: .out)]),
			.init(content: .spinner(Spinner(style: .ring)),
			      keys: [.init(t: 0, x: 0.9, y: 0.5, opacity: 0),
			             .init(t: 1, opacity: 1, ease: .out)]),
			.init(content: .image("logo.png"),
			      keys: [.init(t: 0, x: 0.2, y: 0.8), .init(t: 1, x: 0.3, ease: .out)]),
		])
	}

	private func inspector(part: Int) -> SceneInspector {
		_ = NSApplication.shared
		let panel = SceneInspector()
		panel.reload(scene(), project: Project(output: Output(width: 1920, height: 1080)),
		             part: part, key: 1)
		panel.layoutSubtreeIfNeeded()
		return panel
	}

	/// Every part kind explains its fields, and every heading with words under
	/// it offers the `?` — the same rule the properties panel keeps, because a
	/// second convention for "where the explanations live" is a second thing to
	/// learn.
	@Test func everyPartExplainsItselfBehindTheQuestionMark() {
		for part in 0 ..< scene().parts.count {
			let panel = inspector(part: part)
			let said = panel.explanationsForTesting
			#expect(!said.isEmpty, "nothing is explained for part \(part)")
			#expect(said.allSatisfy { !$0.note.isEmpty && !$0.key.isEmpty })
			#expect(Set(panel.askableSectionsForTesting) == Set(said.map(\.section)),
			        "for part \(part): \(panel.askableSectionsForTesting)")
		}
	}

	/// And none of it is printed under the fields, where it used to be most of a
	/// screenful of grey prose.
	@Test func theExplanationsAreNotPrinted() {
		for part in 0 ..< scene().parts.count {
			let panel = inspector(part: part)
			let notes = Set(panel.explanationsForTesting.map(\.note))
			let printed = panel.rowsForTesting
				.map { $0.trimmingCharacters(in: .whitespaces) }
				.filter(notes.contains)
			#expect(printed.isEmpty, "still printed for part \(part): \(printed)")
		}
	}

	/// Resting on a row says the same thing.
	@Test func everyExplainedRowSaysItOnHover() {
		let panel = inspector(part: 0)
		let notes = Set(panel.explanationsForTesting.map(\.note))
		func tips(in view: NSView) -> [String] {
			view.subviews.flatMap { sub -> [String] in
				(sub.toolTip.map { [$0] } ?? []) + tips(in: sub)
			}
		}
		let shown = Set(tips(in: panel))
		#expect(notes.subtracting(shown).isEmpty,
		        "not offered on hover: \(notes.subtracting(shown))")
	}

	/// The one thing that stays printed, and where: what the two groups are to
	/// each other, directly under the heading of the second one.
	///
	/// It used to be the last row of the panel, under a list of keys, which is
	/// as far from the thing it explains as the form can put it.
	@Test func theRuleSitsUnderTheHeadingItExplains() throws {
		let rows = inspector(part: 0).rowsForTesting
		let heading = try #require(rows.firstIndex { $0.contains("KEYS") },
		                           "no keys heading in \(rows)")
		#expect(rows.count > heading + 1)
		#expect(rows[heading + 1].contains("A key states only what changes"),
		        "under the heading is \(rows[heading + 1])")
		#expect(rows[heading + 1].contains("the part says above"),
		        "it does not say what the values at the top are")
		// And the part's own values are under a heading of their own, above it,
		// so the two groups read as two groups rather than one long list.
		let part = try #require(rows.firstIndex { $0.contains("THE PART") })
		#expect(part < heading)
	}

	/// A background's key offers both stops and the angle, which is the whole of
	/// the capability that was missing.
	@Test func aBackgroundKeyOffersTheWholeGradient() {
		let rows = inspector(part: 0).rowsForTesting
		for name in ["color", "to", "angle"] {
			#expect(rows.contains { $0.hasPrefix(name) },
			        "no \(name) row for a background's key: \(rows)")
		}
		// And the summary beside the key says what it states, in the words the
		// file uses.
		#expect(rows.contains { $0.contains("opacity color to angle") },
		        "the key does not say what it states: \(rows)")
	}

	/// The far stop is not offered where there is no ramp to have one.
	@Test func nothingElseGetsASecondStop() {
		for part in 1 ..< scene().parts.count {
			let rows = inspector(part: part).rowsForTesting
			#expect(!rows.contains { $0.hasPrefix("to ") }, "part \(part) offers a stop")
			#expect(!rows.contains { $0.hasPrefix("angle") }, "part \(part) offers an angle")
		}
	}
}
