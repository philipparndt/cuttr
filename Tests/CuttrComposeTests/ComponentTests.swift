import Foundation
import Testing
@testable import CuttrCompose

/// A `component:` as the project file has it, and as the cache accounts for it.
///
/// Nothing here starts a browser. What is being tested is the part that decides
/// *whether* to start one, and it is the part with the sharp edge: a cache that
/// says yes when it should say no renders last week's chart, and one that says
/// no when it should say yes bakes for twenty seconds on every render.
@Suite struct ComponentTests {

	private let file = """
		cuttr-project: 1

		output:
		  size: 1920x1080
		  fps:  25

		scenes:
		  s:
		    parts:
		      - component: charts/walks.js
		        duration:  8
		        props:     {accent: "#7fd4ff", unit: km}
		        keys:
		          - {t: 0, x: 0.5, y: 0.5, width: 1, height: 1}
		"""

	private func component(in project: Project) throws -> Component {
		let part = try #require(project.scenes["s"]?.parts.first)
		guard case .component(let component) = part.content else {
			throw ProjectError.badValue(key: "parts", value: "not a component")
		}
		return component
	}

	// MARK: - The file

	@Test func aComponentPartReads() throws {
		let component = try component(in: try ProjectReader.read(file))
		#expect(component.file == "charts/walks.js")
		#expect(component.duration == 8)
		#expect(component.props == ["accent": "#7fd4ff", "unit": "km"])
	}

	/// A number written as a number is the same prop as one written in quotes,
	/// which is what a scene's `with:` already does — and it matters here
	/// because two spellings of one prop would be two bakes.
	@Test func propsAreStringsHoweverTheyAreWritten() throws {
		let project = try ProjectReader.read(
			file.replacingOccurrences(of: ##"{accent: "#7fd4ff", unit: km}"##,
			                          with: "{year: 2025}"))
		#expect(try component(in: project).props == ["year": "2025"])
	}

	/// How long it draws for is the one thing a component may not decide for
	/// itself: it is how many frames get baked.
	@Test func aComponentWithNoDurationIsRefused() {
		#expect(throws: (any Error).self) {
			try ProjectReader.read(
				self.file.replacingOccurrences(of: "        duration:  8\n", with: ""))
		}
	}

	@Test func aComponentPartIsWrittenBackAsItWasWritten() throws {
		let out = ProjectWriter.write(try ProjectReader.read(file))
		#expect(out.contains("      - component: charts/walks.js\n"))
		#expect(out.contains("        duration:  8\n"))
		#expect(out.contains(##"        props:     {accent: "#7fd4ff", unit: km}"## + "\n"))
		#expect(ProjectWriter.write(try ProjectReader.read(out)) == out)
	}

	/// Absent when unused: a component that takes nothing is the two lines it
	/// was written as, not two lines and an empty flow mapping.
	@Test func aComponentWithNoPropsWritesNoPropsLine() throws {
		let bare = file.replacingOccurrences(
			of: ##"        props:     {accent: "#7fd4ff", unit: km}"## + "\n", with: "")
		let out = ProjectWriter.write(try ProjectReader.read(bare))
		#expect(!out.contains("props:"))
		#expect(ProjectWriter.write(try ProjectReader.read(out)) == out)
	}

	// MARK: - Where the frames go

	/// Named after the component and not after its fingerprint, and separators
	/// become dashes so that two files with the same name in different folders
	/// are two bakes.
	@Test func theFramesGoBesideTheProjectUnderTheComponentsName() {
		#expect(Component(file: "charts/walks.js", duration: 1).folder
			== ".cuttr/components/charts-walks")
		#expect(Component(file: "walks.js", duration: 1).folder
			== ".cuttr/components/walks")
		#expect(Component(file: "titles/walks.js", duration: 1).folder
			!= Component(file: "charts/walks.js", duration: 1).folder)
	}

	/// A `component:` and a `frames:` are the same part by the time anything
	/// looks at pixels. That is the line that keeps this from being a third way
	/// of drawing, so it is worth an assertion of its own.
	@Test func aComponentIsAFrameSequenceByTheTimeItIsDrawn() {
		let component = Component(file: "charts/walks.js", duration: 8)
		let content = Scene.Part.Content.component(component)
		let sequence = content.sequence(at: 25)
		#expect(sequence?.pattern == ".cuttr/components/charts-walks/%05d.png")
		#expect(sequence?.fps == 25)
		#expect(component.frames(at: 25) == 200)
		#expect(component.frames(at: 50) == 400)
	}

	// MARK: - The bake record

	private func bake(_ change: (inout Component.Bake) -> Void = { _ in }) -> Component.Bake {
		var bake = Component.Bake(
			runtime: "abc123", source: "charts/walks.js", digest: "deadbeef",
			width: 1920, height: 1080, fps: 25, frames: 200,
			props: ["accent": "#7fd4ff", "unit": "km"])
		change(&bake)
		return bake
	}

	@Test func aBakeRecordGoesRoundTheHouses() throws {
		let written = bake().written
		let read = try #require(Component.Bake(written))
		#expect(read == bake())
		// And writing it again gives the same file, which is what makes a
		// re-bake of an unchanged component a folder with no diff in it.
		#expect(read.written == written)
	}

	@Test func aBakeRecordNobodyCanAccountForIsNoCacheAtAll() {
		#expect(Component.Bake("") == nil)
		#expect(Component.Bake("hello") == nil)
		// Every field is needed. A record missing the size is a record that
		// cannot say whether the frames are the right size.
		let holed = bake().written.split(separator: "\n")
			.filter { !$0.hasPrefix("size:") }.joined(separator: "\n")
		#expect(Component.Bake(holed) == nil)
	}

	/// The reason, not just the verdict. "The size changed" is what somebody
	/// needs; a hash that differs tells them nothing they can act on.
	@Test func aStaleBakeSaysWhyItIsStale() {
		#expect(bake().differs(from: bake()) == nil)
		#expect(bake().differs(from: bake { $0.digest = "01234567" })
			== "the file has been edited")
		#expect(bake().differs(from: bake { $0.runtime = "other" })
			== "cuttr's component runtime has changed")
		#expect(bake().differs(from: bake { $0.width = 1280; $0.height = 720 })
			== "the output is 1280×720 now, not 1920×1080")
		#expect(bake().differs(from: bake { $0.fps = 50 })
			== "the output is 50 fps now, not 25")
		#expect(bake().differs(from: bake { $0.frames = 250 })
			== "it is on for 250 frames now, not 200")
		#expect(bake().differs(from: bake { $0.props["unit"] = "mi" })
			== "its props have changed")
	}

	// MARK: - What the preview is told

	private func project(_ text: String) throws -> (Project, URL) {
		let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
			.appendingPathComponent("cuttr-component-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(
			at: directory.appendingPathComponent("charts"), withIntermediateDirectories: true)
		try "component(function () { return null; });\n".write(
			to: directory.appendingPathComponent("charts/walks.js"),
			atomically: true, encoding: .utf8)
		return (try ProjectReader.read(text), directory)
	}

	/// Nothing bakes while somebody is typing, so the preview has to say what it
	/// is showing. A component that has never been baked says so.
	@Test func anUnbakedComponentIsSaidOutLoud() throws {
		let (project, directory) = try project(file)
		let said = ComponentBaker.staleness(project, from: directory)
		#expect(said.count == 1)
		#expect(said[0].contains("charts/walks.js"))
		#expect(said[0].contains("never been baked"))
		try? FileManager.default.removeItem(at: directory)
	}

	/// A bake that is there but out of date says which way it is out of date,
	/// and says what is on screen is the last one — never silently draws it.
	@Test func aStaleBakeIsSaidOutLoudWithItsReason() throws {
		let (project, directory) = try project(file)
		let component = try component(in: project)
		let folder = directory.appendingPathComponent(component.folder)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		// A record for the same component at the wrong size.
		let stale = Component.Bake(
			runtime: "whatever", source: component.file, digest: "0", width: 1280,
			height: 720, fps: 25, frames: 200, props: component.props)
		try stale.written.write(to: folder.appendingPathComponent("bake"),
		                        atomically: true, encoding: .utf8)
		let said = ComponentBaker.staleness(project, from: directory)
		#expect(said.count == 1)
		#expect(said[0].contains("runtime has changed"))
		#expect(said[0].contains("the last bake"))
		try? FileManager.default.removeItem(at: directory)
	}

	@Test func aComponentThatIsNotThereIsSaidOutLoud() throws {
		let (project, directory) = try project(file)
		try FileManager.default.removeItem(
			at: directory.appendingPathComponent("charts/walks.js"))
		let said = ComponentBaker.staleness(project, from: directory)
		#expect(said.count == 1)
		#expect(said[0].contains("is not there"))
		try? FileManager.default.removeItem(at: directory)
	}

	/// Two overlays on one scene are one bake. Baking it twice would be the same
	/// pixels for twice the wait.
	@Test func oneComponentUsedTwiceIsOneBake() throws {
		var project = try ProjectReader.read(file)
		project.scenes["t"] = project.scenes["s"]
		#expect(ComponentBaker.components(in: project).count == 1)
	}
}
