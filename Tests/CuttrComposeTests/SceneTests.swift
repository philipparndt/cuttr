import CuttrKit
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

	/// The stage and both render paths ask one function where a part is.
	@Test func aPartIsWhereTheKeysSayItIs() {
		let keys = Scene.filled([
			Scene.Key(t: 0, x: 0.2, opacity: 0, ease: .linear),
			Scene.Key(t: 1, x: 0.8, opacity: 1, ease: .linear),
		])
		let middle = Scene.state(of: keys, at: 0.5)
		#expect(middle?.x == 0.5)
		#expect(middle?.opacity == 0.5)
		// Held at both ends, which is what `fillMode: .both` does.
		#expect(Scene.state(of: keys, at: -3)?.x == 0.2)
		#expect(Scene.state(of: keys, at: 99)?.x == 0.8)
	}
}

/// What an intro screen needs that a lower third never did: a ground to stand
/// on, a colour that moves, and letters set apart.
@Suite struct SceneTitleCardTests {

	private func card() -> Scene {
		Scene(parts: [
			.init(content: .background(Scene.Background(
				from: RGBA(hex: "#0b1220")!, to: RGBA(hex: "#1d3557")!, angle: 90)), keys: [
					.init(t: 0, opacity: 0),
					.init(t: 0.4, opacity: 1, ease: .out),
				]),
			.init(content: .text("{{title}}", style: "title", tracking: 0.14), keys: [
				.init(t: 0.3, x: 0.5, y: 0.5, opacity: 0, color: RGBA.white),
				.init(t: 1.2, opacity: 1, color: RGBA(hex: "#f4a261")!, ease: .out),
			]),
		])
	}

	@Test func aTitleCardSurvivesTheFile() throws {
		let project = Project(scenes: ["intro": card()])
		let text = ProjectWriter.write(project)
		#expect(text.contains("background: {from: \"#0b1220\", to: \"#1d3557\", angle: 90}"))
		#expect(text.contains("tracking: 0.14"))
		#expect(text.contains("color: \"#f4a261\""))
		let back = try ProjectReader.read(text)
		#expect(back.scenes == project.scenes)
		// And written again it is the same bytes, which is the whole rule.
		#expect(ProjectWriter.write(back) == text)
	}

	/// A flat background stays the one word somebody wrote.
	@Test func aFlatBackgroundIsOneWord() throws {
		let project = Project(scenes: ["plate": Scene(parts: [
			.init(content: .background(Scene.Background(from: RGBA(hex: "#101418")!)),
			      keys: [.init(t: 0, opacity: 1)]),
		])])
		let text = ProjectWriter.write(project)
		#expect(text.contains("- background: \"#101418\""))
		#expect(try ProjectReader.read(text).scenes == project.scenes)
	}

	/// A file from before any of this still reads, and still writes back the
	/// way it came in.
	@Test func anOlderSceneIsUnchanged() throws {
		let text = """
		# cuttr project — the assembly. Clips are referenced by slug.
		cuttr-project: 1

		output:
		  size: 1920x1080
		  fps:  25

		timeline:
		  - clip: intro

		scenes:
		  rule:
		    parts:
		      - shape: "#ffffff"
		        keys:
		          - {t: 0, x: 0.5, y: 0.2, width: 0, height: 0.004}
		          - {t: 0.6, width: 0.5, ease: out}

		"""
		let project = try ProjectReader.read(text)
		#expect(project.scenes["rule"]?.parts.count == 1)
		#expect(project.scenes["rule"]?.parts[0].keys.allSatisfy { $0.color == nil } == true)
		#expect(ProjectWriter.write(project) == text)
	}

	/// A colour stated at one key and again at another ramps between them; one
	/// stated only once holds from there.
	@Test func colourMovesBetweenTheKeysThatStateIt() {
		let keys = Scene.filled(card().parts[1].keys)
		let middle = Scene.state(of: keys, at: 0.75)!
		let white = RGBA.white, warm = RGBA(hex: "#f4a261")!
		// Half way in eased time, so not the arithmetic middle — but between.
		#expect(middle.color!.g < white.g && middle.color!.g > warm.g)
		#expect(Scene.state(of: keys, at: 0)?.color == white)
		#expect(Scene.state(of: keys, at: 5)?.color == warm)

		// A part with no colour anywhere keeps none, so it is drawn in the
		// colour it was declared with rather than in an invented default.
		let plain = Scene.filled([Scene.Key(t: 0, x: 0), Scene.Key(t: 1, x: 1)])
		#expect(Scene.state(of: plain, at: 0.5)?.color == nil)
	}

	/// The ramp reaches the whole frame, whichever way it runs.
	@Test func aGradientReachesBothEdges() {
		let size = CGSize(width: 1920, height: 1080)
		let up = Scene.Background(from: .black, to: .white, angle: 90).ends(in: size)
		#expect(abs(up.start.y) < 0.001)
		#expect(abs(up.end.y - 1080) < 0.001)
		#expect(abs(up.start.x - 960) < 0.001)
		let across = Scene.Background(from: .black, to: .white, angle: 0).ends(in: size)
		#expect(abs(across.start.x) < 0.001)
		#expect(abs(across.end.x - 1920) < 0.001)
	}

	/// Letters set apart make a wider line — which is the whole of what
	/// tracking does, and the only part of it worth asserting.
	@Test func trackingWidensTheLine() {
		let size = CGSize(width: 640, height: 360)
		let plain = OverlayLayers.textLayer("CUTTR", style: .title, size: size)
		let spaced = OverlayLayers.textLayer("CUTTR", style: .title, size: size, tracking: 0.3)
		#expect(spaced.1.width > plain.1.width)
		#expect(abs(spaced.1.height - plain.1.height) < 0.001)
	}
}

/// Dragging a bar on the timeline writes back the way the range was written.
///
/// The point being that a drag must not quietly convert somebody's
/// re-cut-proof caption into one that is not.
@Suite struct SpanMovingTests {

	private func resolved() -> ResolvedProject {
		let clips = ["first", "second"].enumerated().map { index, slug -> ResolvedClip in
			ResolvedClip(
				reference: ClipReference(slug), takeName: "take",
				clip: Clip(slug: slug, start: 0, end: 10), videoURL: nil, audioURL: nil,
				audioOffset: 0, start: Double(index) * 10)
		}
		return ResolvedProject(
			project: Project(), baseURL: URL(fileURLWithPath: "."), clips: clips,
			overlays: [], groups: [], anchors: [])
	}

	@Test func programmeTimesStayProgrammeTimes() {
		let moved = Overlay.Span.times(from: 1, to: 3).moved(start: 5, end: 8, in: resolved())
		#expect(moved == .times(from: 5, to: 8))
	}

	@Test func aStretchOfAClipKeepsItsOffsetIntoThatClip() {
		let span = Overlay.Span.within(.clip(ClipReference("second")), from: 1, to: 3)
		// The second clip starts at ten, so 12 → 15 is "two to five seconds in".
		#expect(span.moved(start: 12, end: 15, in: resolved())
			== .within(.clip(ClipReference("second")), from: 2, to: 5))
	}

	@Test func aClipBoundRangeSnapsToWhicheverClipItNowCovers() {
		let span = Overlay.Span.clips(from: ClipReference("first"), to: ClipReference("first"))
		let moved = span.moved(start: 11, end: 18, in: resolved())
		#expect(moved == .marks(from: .clip(ClipReference("second")),
		                        to: .clip(ClipReference("second"))))
	}
}

/// Styles are read under more names than they are offered under.
@Suite struct StyleNameTests {

	@Test func bothSpellingsAreRead() {
		#expect(TextStyle.builtIn["lower-third-centre"] == TextStyle.builtIn["lower-third-center"])
		#expect(TextStyle.builtIn["centre"] == TextStyle.builtIn["center"])
	}

	/// …and each is offered once, in one spelling.
	@Test func eachIsOfferedOnce() {
		#expect(Set(TextStyle.offered).count == TextStyle.offered.count)
		for name in TextStyle.offered {
			#expect(TextStyle.builtIn[name] != nil, "\(name) is offered but not defined")
			#expect(!name.contains("center"), "\(name) is offered in the other spelling")
		}
	}
}

/// An overlay that starts at zero is the one that goes wrong.
///
/// Core Animation reads a `beginTime` of nought as "now" — in an export that
/// is whenever the encoder reached it, in a paused preview tree it is whenever
/// the tree was attached. Either way the caption on the first clip appeared
/// wherever the playhead happened to be, and every overlay with a later start
/// behaved perfectly, which is what made it hard to see.
@Suite struct BeginTimeTests {

	@Test func zeroIsNeverZero() {
		for host in [OverlayLayers.Host.preview, .export] {
			#expect(host.beginTime(0) > 0, "\(host) starts an overlay at now")
			// And anything with a real start is left exactly as it is.
			#expect(host.beginTime(12.5) == 12.5)
		}
	}
}

/// A dissolve is an overlap: the incoming clip starts before the outgoing one
/// ends, and the programme is that much shorter.
@Suite struct TransitionTests {

	private func resolve(_ transition: Double) throws -> [ResolvedClip] {
		// Resolved by hand: what matters here is the arithmetic on the clock,
		// and the resolver needs media it cannot have in a test.
		var clips: [ResolvedClip] = []
		var cursor = 0.0
		for (index, slug) in ["a", "b"].enumerated() {
			var overlap = 0.0
			if index > 0, transition > 0, let last = clips.last {
				overlap = min(transition, last.duration / 2, 10 / 2)
				cursor -= overlap
			}
			clips.append(ResolvedClip(
				reference: ClipReference(slug), takeName: "take",
				clip: Clip(slug: slug, start: 0, end: 10), videoURL: nil, audioURL: nil,
				audioOffset: 0, start: cursor, transition: overlap))
			cursor += 10
		}
		return clips
	}

	@Test func aCutLeavesTheClockAlone() throws {
		let clips = try resolve(0)
		#expect(clips.map(\.start) == [0, 10])
		#expect(clips.map(\.transition) == [0, 0])
	}

	@Test func aDissolveShortensTheProgramme() throws {
		let clips = try resolve(1.5)
		#expect(clips[1].start == 8.5)
		#expect(clips[1].transition == 1.5)
	}

	/// Never longer than half of either shot, or a three-second dissolve
	/// between two-second clips would run past both.
	@Test func aDissolveIsNeverLongerThanTheShotsItJoins() throws {
		let clips = try resolve(30)
		#expect(clips[1].transition == 5)
		#expect(clips[1].start == 5)
	}
}

/// Using one clip twice, at different lengths, in different places.
@Suite struct PlacementTests {

	@Test func aPlacementCanBeNamedAndTrimmed() throws {
		let project = Project(
			timeline: [
				TimelineEntry(clip: ClipReference("intro")),
				TimelineEntry(clip: ClipReference("intro"), label: "reprise",
				              trim: (head: 1.5, tail: 0.5)),
			],
			overlays: [Overlay(kind: .text("again", style: nil),
			                   span: .marks(from: .group("reprise"), to: .group("reprise")))])

		let text = ProjectWriter.write(project)
		#expect(text.contains("as:"))
		#expect(text.contains("trim:"))
		let back = try ProjectReader.read(text)
		#expect(back.timeline == project.timeline)
		#expect(back.timeline[1].label == "reprise")
		#expect(back.timeline[1].trim.head == 1.5)
		#expect(back.timeline[1].trim.tail == 0.5)
		#expect(ProjectWriter.write(back) == text)
	}

	/// A clip with nothing said about it is still written in the short form.
	@Test func theOrdinaryEntryIsUnchanged() {
		let text = ProjectWriter.write(Project(timeline: [TimelineEntry(clip: ClipReference("intro"))]))
		#expect(text.contains("  - clip: intro\n"))
		#expect(!text.contains("as:"))
		#expect(!text.contains("trim:"))
	}
}
