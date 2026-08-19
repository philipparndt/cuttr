import Foundation
import Testing
@testable import CuttrCompose

/// Scenes: parts moved by keyframes, defined in the project and used with
/// different words each time.
@Suite struct SceneTests {

	private func intro() -> Scene {
		Scene(parts: [
			.init(content: .shape(fill: RGBA(hex: "#101418cc")!, corner: 0.02), keys: [
				.init(t: 0, x: 0.5, y: 0.5, opacity: 1, width: 0, height: 0.34),
				.init(t: 0.5, width: 0.62, ease: .out),
			]),
			.init(content: .text("{{title}}", style: "title"), keys: [
				.init(t: 0.35, x: 0.5, y: 0.56, opacity: 0),
				.init(t: 0.9, y: 0.53, opacity: 1, ease: .out),
			]),
		])
	}

	@Test func aSceneSurvivesTheFile() throws {
		let project = Project(
			timeline: [TimelineEntry(clip: ClipReference("intro"))],
			overlays: [Overlay(kind: .scene("intro", with: ["title": "Folge 3"]),
			                   span: .within(.clip(ClipReference("intro")), from: 0, to: 4))],
			scenes: ["intro": intro()])

		let text = ProjectWriter.write(project)
		#expect(text.contains("scenes:"))
		#expect(text.contains("with:    {title: Folge 3}"))
		let back = try ProjectReader.read(text)
		#expect(back.scenes == project.scenes)
		#expect(back.overlays == project.overlays)
		#expect(ProjectWriter.write(back) == text)
	}

	/// A key says only what changes; the rest is what it was.
	@Test func gapsAreFilledFromTheKeyBefore() {
		let keys = Scene.filled(intro().parts[0].keys)
		#expect(keys.count == 2)
		#expect(keys[1].width == 0.62)
		// Not stated at the second key, so unchanged from the first.
		#expect(keys[1].x == 0.5)
		#expect(keys[1].height == 0.34)
		#expect(keys[1].opacity == 1)
	}

	/// Parameters are what makes a scene a template rather than one title.
	@Test func parametersAreFilledInAndMissingOnesAreVisible() {
		#expect(Scene.fill("{{title}} — {{subtitle}}", with: ["title": "Folge 3"])
			== "Folge 3 — {{subtitle}}")
		#expect(Scene.fill("{{ title }}", with: ["title": "Folge 3"]) == "Folge 3")
	}

	/// The keys are sorted by time, whatever order the file lists them in.
	@Test func keysAreInTimeOrder() {
		let scene = Scene(parts: [.init(content: .text("a", style: nil), keys: [
			.init(t: 2, x: 1), .init(t: 0, x: 0), .init(t: 1, x: 0.5),
		])])
		#expect(Scene.filled(scene.parts[0].keys).map(\.t) == [0, 1, 2])
	}
}
