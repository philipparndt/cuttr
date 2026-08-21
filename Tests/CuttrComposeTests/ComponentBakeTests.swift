import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import CuttrCompose

/// Baking, for real: a hidden `WKWebView`, React out of the bundle, and PNGs on
/// the disk at the end of it.
///
/// **Serialized, and it has to be.** Every test in here builds a web view; run
/// in parallel they contend for the main actor and the content-rule store, and a
/// suite of them that was not serialized once left the test process alive after
/// every test had passed. A `make test` that hangs is as bad as one that fails.
///
/// **Nothing here reaches the network and nothing here needs Node.** That is the
/// entire point of the feature, so it is also the entire point of this suite: if
/// one of these ever needs either, the feature has stopped being what it claims.
@Suite(.serialized) @MainActor struct ComponentBakeTests {

	/// A project with one component in it, written to a fresh folder.
	private func fixture(
		_ source: String, duration: Double = 0.4, props: [String: String] = [:],
		width: Int = 160, height: Int = 90
	) throws -> (project: Project, baseURL: URL, component: Component) {
		let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
			.appendingPathComponent("cuttr-bake-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		try source.write(to: directory.appendingPathComponent("c.js"),
		                 atomically: true, encoding: .utf8)
		let component = Component(file: "c.js", duration: duration, props: props)
		var project = Project(scenes: [
			"s": Scene(parts: [.init(content: .component(component),
			                         keys: [.init(t: 0, x: 0.5, y: 0.5, opacity: 1,
			                                      width: 1, height: 1)])]),
		])
		// Small, because these tests are about what comes out and not about how
		// fast: ten frames of 160×90 is a tenth of a second of baking.
		project.output = Output(width: width, height: height, framesPerSecond: 25)
		return (project, directory, component)
	}

	/// A square that moves with the frame, so which frame a PNG is can be read
	/// off it, and nothing else on the page.
	private let mover = """
		function C() {
			const frame = useCurrentFrame();
			return h('div', {style: {position: 'absolute', left: (frame * 4) + 'px',
			                         top: '10px', width: '20px', height: '20px',
			                         background: '#e8452c'}});
		}
		component(C);
		"""

	private func pixel(_ url: URL, x: Int, y: Int) throws -> (r: Int, g: Int, b: Int, a: Int) {
		let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
		let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
		let rep = NSBitmapImageRep(cgImage: image)
		let colour = try #require(rep.colorAt(x: x, y: y))
		return (Int((colour.redComponent * 255).rounded()),
		        Int((colour.greenComponent * 255).rounded()),
		        Int((colour.blueComponent * 255).rounded()),
		        Int((colour.alphaComponent * 255).rounded()))
	}

	// MARK: - It bakes

	@Test func aComponentBakesToAFolderOfFrames() async throws {
		let (project, baseURL, component) = try fixture(mover)
		let report = try await ComponentBaker.bake(project, from: baseURL)
		#expect(report.baked.count == 1)
		#expect(report.baked.first?.frames == 10)

		let folder = baseURL.appendingPathComponent(component.folder)
		let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
		// Ten frames, numbered from nought, and the record of what made them.
		#expect(files == ["00000.png", "00001.png", "00002.png", "00003.png", "00004.png",
		                  "00005.png", "00006.png", "00007.png", "00008.png", "00009.png",
		                  "bake"])
		try? FileManager.default.removeItem(at: baseURL)
	}

	/// The square is where the frame number says it is, which is the only proof
	/// that the frame number is what drove the render.
	@Test func theFrameNumberIsWhatDrivesIt() async throws {
		let (project, baseURL, component) = try fixture(mover)
		_ = try await ComponentBaker.bake(project, from: baseURL)
		let folder = baseURL.appendingPathComponent(component.folder)
		// The div is 20 wide at `left: frame * 4`, `top: 10`. `colorAt` counts
		// rows from the top, the same way CSS does, so a row inside it is 20.
		for frame in [0, 5, 9] {
			let url = folder.appendingPathComponent(String(format: "%05d.png", frame))
			let inside = try pixel(url, x: frame * 4 + 10, y: 20)
			#expect(inside == (232, 69, 44, 255), "frame \(frame) is not drawn where it should be")
		}
		try? FileManager.default.removeItem(at: baseURL)
	}

	/// Transparent where nothing was drawn, so the frames go over the picture
	/// rather than over white — and unassociated alpha, so a soft edge does not
	/// darken when it is composited.
	@Test func whatWasNotDrawnIsTransparent() async throws {
		let (project, baseURL, component) = try fixture("""
			function C() {
				return h('div', {style: {position: 'absolute', left: '40px', top: '20px',
				                         width: '40px', height: '40px', borderRadius: '20px',
				                         background: '#e8452c'}});
			}
			component(C);
			""")
		_ = try await ComponentBaker.bake(project, from: baseURL)
		let url = baseURL.appendingPathComponent(component.folder)
			.appendingPathComponent("00000.png")
		#expect(try pixel(url, x: 2, y: 2).a == 0, "the corner is not transparent")
		#expect(try pixel(url, x: 60, y: 50).a == 255, "the circle is not opaque")

		// The soft edge of the circle: partly transparent, and still the ink's
		// own colour. A premultiplied value written as an unassociated one would
		// be darker here, which is the dark fringe nobody notices until it is
		// over footage. Round the whole circle, so every angle of edge is looked
		// at rather than one flat run of it.
		var soft: [(Int, Int, Int, Int)] = []
		for x in 38 ... 82 {
			for y in 18 ... 62 {
				let p = try pixel(url, x: x, y: y)
				// Well away from either end, where unpremultiplying a value
				// stored in eight bits amplifies its own rounding: at an alpha
				// of a twentieth, one count of the stored colour is twenty
				// counts of the recovered one, and that arithmetic is the PNG
				// format's rather than anything this program did.
				if p.a > 40, p.a < 215 { soft.append((p.r, p.g, p.b, p.a)) }
			}
		}
		#expect(soft.count > 20, "the circle has no soft edge to measure")
		for (r, g, b, a) in soft {
			#expect(abs(r - 232) <= 6 && abs(g - 69) <= 6 && abs(b - 44) <= 6,
			        "a partly transparent pixel is not the ink's colour: \(r),\(g),\(b) at a=\(a)")
		}
		try? FileManager.default.removeItem(at: baseURL)
	}

	/// Twice through, byte for byte. The frame number is the only input, so this
	/// is what "the same project renders the same frames" means in practice.
	@Test func bakingTwiceGivesTheSameBytes() async throws {
		let (project, baseURL, component) = try fixture(mover)
		_ = try await ComponentBaker.bake(project, from: baseURL)
		let folder = baseURL.appendingPathComponent(component.folder)
		let first = try (0 ..< 10).map {
			try Data(contentsOf: folder.appendingPathComponent(String(format: "%05d.png", $0)))
		}
		_ = try await ComponentBaker.bake(project, from: baseURL, force: true)
		let again = try (0 ..< 10).map {
			try Data(contentsOf: folder.appendingPathComponent(String(format: "%05d.png", $0)))
		}
		#expect(first == again)
		try? FileManager.default.removeItem(at: baseURL)
	}

	// MARK: - The cache

	@Test func anUnchangedComponentIsNotBakedAgain() async throws {
		let (project, baseURL, _) = try fixture(mover)
		#expect(try await ComponentBaker.bake(project, from: baseURL).baked.count == 1)
		let second = try await ComponentBaker.bake(project, from: baseURL)
		#expect(second.baked.isEmpty)
		#expect(second.reused == ["c.js"])
		try? FileManager.default.removeItem(at: baseURL)
	}

	@Test func editingTheComponentBakesItAgain() async throws {
		let (project, baseURL, _) = try fixture(mover)
		_ = try await ComponentBaker.bake(project, from: baseURL)
		try (mover + "\n// a comment, which is still an edit\n").write(
			to: baseURL.appendingPathComponent("c.js"), atomically: true, encoding: .utf8)
		#expect(try await ComponentBaker.bake(project, from: baseURL).baked.count == 1)
		try? FileManager.default.removeItem(at: baseURL)
	}

	/// A bake that got shorter must not leave the tail of the last one behind:
	/// those frames would go on being drawn, which is the cache lying.
	@Test func aShorterBakeLeavesNoFramesBehind() async throws {
		let (project, baseURL, component) = try fixture(mover, duration: 0.4)
		_ = try await ComponentBaker.bake(project, from: baseURL)
		var shorter = project
		shorter.scenes["s"]?.parts[0].content =
			.component(Component(file: component.file, duration: 0.2))
		_ = try await ComponentBaker.bake(shorter, from: baseURL)
		let files = try FileManager.default.contentsOfDirectory(
			atPath: baseURL.appendingPathComponent(component.folder).path)
		#expect(files.filter { $0.hasSuffix(".png") }.count == 5)
		try? FileManager.default.removeItem(at: baseURL)
	}

	// MARK: - When it is broken

	private func trouble(_ source: String, duration: Double = 0.08) async -> String {
		do {
			let (project, baseURL, _) = try fixture(source, duration: duration)
			defer { try? FileManager.default.removeItem(at: baseURL) }
			_ = try await ComponentBaker.bake(project, from: baseURL)
			return "it baked, which it should not have"
		} catch {
			return error.localizedDescription
		}
	}

	/// A JavaScript error reaches somebody as that error, on the line they wrote
	/// it on — not as a black rectangle and not as a silent hole.
	@Test func aMistakeInTheComponentIsReportedWithItsLine() async {
		let said = await trouble("""
			function C() {
				const frame = useCurrentFrame();
				const bad = frame.nope.deeper;
				return h('div', null, bad);
			}
			component(C);
			""")
		#expect(said.hasPrefix("c.js:3: "), "the line is wrong: \(said)")
		#expect(said.contains("frame.nope"))
	}

	/// And a syntax error, which happens before any frame is drawn at all.
	@Test func aSyntaxErrorIsReportedWithItsLine() async {
		let said = await trouble("function C() {\n\tconst x = ;\n}\ncomponent(C);")
		#expect(said.hasPrefix("c.js:2: "), "the line is wrong: \(said)")
	}

	/// A file that never says which function it is has nothing to draw, and is
	/// told so in words that say what to do about it.
	@Test func aFileThatNeverRegistersAnythingSaysSo() async {
		let said = await trouble("function C() { return null; }")
		#expect(said.contains("never called component"))
		#expect(said.contains("component(YourFunction)"))
	}

	// MARK: - Determinism, enforced rather than asked for

	@Test func randomnessWithoutASeedIsRefused() async {
		let said = await trouble("""
			function C() { return h('div', null, String(Math.random())); }
			component(C);
			""")
		#expect(said.contains("Math.random()"))
		#expect(said.contains("random(seed)"))
	}

	@Test func fetchingAnythingIsRefused() async {
		let said = await trouble("""
			function C() { fetch('https://example.com/data.json'); return null; }
			component(C);
			""")
		#expect(said.contains("fetch is not available"))
	}

	@Test func anAnimationLoopIsRefused() async {
		let said = await trouble("""
			function C() { requestAnimationFrame(function () {}); return null; }
			component(C);
			""")
		#expect(said.contains("requestAnimationFrame"))
	}

	/// The clock reads the epoch, so a component that prints a date comes out
	/// obviously wrong rather than differently on every render.
	@Test func theClockIsFrozenRatherThanRunning() async throws {
		let (project, baseURL, component) = try fixture("""
			function C() {
				// White if the clock reads 1970, black if it is running.
				const year = new Date().getFullYear();
				return h('div', {style: {position: 'absolute', left: 0, top: 0,
				                         width: '160px', height: '90px',
				                         background: year === 1970 ? '#ffffff' : '#000000'}});
			}
			component(C);
			""", duration: 0.08)
		_ = try await ComponentBaker.bake(project, from: baseURL)
		let url = baseURL.appendingPathComponent(component.folder)
			.appendingPathComponent("00000.png")
		#expect(try pixel(url, x: 80, y: 45).r == 255, "the clock is not frozen")
		try? FileManager.default.removeItem(at: baseURL)
	}

	/// `random(seed)` gives the same number for the same seed and different
	/// numbers for different ones — which is the whole bargain the effects make
	/// with their own seeds.
	@Test func aSeededRandomIsTheSameEveryTime() async throws {
		let (project, baseURL, component) = try fixture("""
			function C() {
				const a = random('mia');
				const b = random('mia');
				const c = random('nia');
				const same = a === b && a !== c && a >= 0 && a < 1;
				return h('div', {style: {position: 'absolute', left: 0, top: 0,
				                         width: '160px', height: '90px',
				                         background: same ? '#ffffff' : '#000000'}});
			}
			component(C);
			""", duration: 0.08)
		_ = try await ComponentBaker.bake(project, from: baseURL)
		let url = baseURL.appendingPathComponent(component.folder)
			.appendingPathComponent("00000.png")
		#expect(try pixel(url, x: 80, y: 45).r == 255)
		try? FileManager.default.removeItem(at: baseURL)
	}

	// MARK: - Fonts

	/// A family this machine has not got is refused by name. A browser would
	/// substitute something and say nothing, and the render would be wrong in a
	/// way nobody was told about.
	@Test func aFontThatIsNotOnTheMachineIsRefusedByName() async {
		let said = await trouble("""
			function C() {
				return h('div', {style: {font: '20px "Nonexistent Sans Deluxe"',
				                         color: '#fff'}}, 'hello');
			}
			component(C);
			""")
		#expect(said.contains("Nonexistent Sans Deluxe"))
		#expect(said.contains("has not got"))
	}

	/// And one it has is not. Helvetica Neue is on every macOS this builds for,
	/// and a check that refused it would refuse everything.
	@Test func aFontThatIsOnTheMachineIsFine() async throws {
		let (project, baseURL, _) = try fixture("""
			function C() {
				return h('div', {style: {font: '20px "Helvetica Neue"', color: '#fff'}},
				         'hello');
			}
			component(C);
			""", duration: 0.08)
		#expect(try await ComponentBaker.bake(project, from: baseURL).baked.count == 1)
		try? FileManager.default.removeItem(at: baseURL)
	}

	// MARK: - The subset

	/// `<Sequence>`, `interpolate` and `spring` are the three things somebody
	/// arriving from Remotion reaches for first, so they get one render each.
	@Test func theRemotionShapedSubsetWorks() async throws {
		let (project, baseURL, component) = try fixture("""
			function Inner() {
				// Nought here is frame ten outside, so at outside frame twelve
				// this is two.
				return h('div', {style: {position: 'absolute', left: 0, top: 0,
				                         width: '160px', height: '90px',
				                         background: useCurrentFrame() === 2
					                         ? '#ffffff' : '#000000'}});
			}
			function C() {
				const frame = useCurrentFrame();
				// Both of these must land on a number, or the div below is not
				// white and the test says so.
				const eased = interpolate(frame, [0, 20], [0, 1],
				                          {extrapolateRight: 'clamp', easing: Easing.out(Easing.cubic)});
				const bounced = spring({frame: frame, fps: useVideoConfig().fps});
				const sane = eased >= 0 && eased <= 1 && bounced >= 0 && bounced < 1.4;
				return h('div', null,
				         h(Sequence, {from: 10}, h(Inner)),
				         h('div', {style: {position: 'absolute', left: 0, top: '80px',
				                           width: '160px', height: '10px',
				                           background: sane ? '#00ff00' : '#ff0000'}}));
			}
			component(C);
			""", duration: 0.52)
		_ = try await ComponentBaker.bake(project, from: baseURL)
		let folder = baseURL.appendingPathComponent(component.folder)

		// Frame twelve: the sequence is on and its own clock reads two.
		#expect(try pixel(folder.appendingPathComponent("00012.png"), x: 80, y: 45).r == 255)
		// Frame nine: it has not started, so nothing of it is drawn.
		#expect(try pixel(folder.appendingPathComponent("00009.png"), x: 80, y: 45).a == 0)
		// And the numbers stayed numbers on every frame.
		for frame in [0, 6, 12] {
			let url = folder.appendingPathComponent(String(format: "%05d.png", frame))
			let strip = try pixel(url, x: 80, y: 85)
			#expect(strip.g == 255 && strip.r == 0,
			        "interpolate or spring went out of range at frame \(frame)")
		}
		try? FileManager.default.removeItem(at: baseURL)
	}

	/// What the project file passes in comes out on the frame.
	@Test func propsReachTheComponent() async throws {
		let (project, baseURL, component) = try fixture("""
			function C() {
				const {shade} = useProps();
				return h('div', {style: {position: 'absolute', left: 0, top: 0,
				                         width: '160px', height: '90px',
				                         background: shade}});
			}
			component(C);
			""", duration: 0.08, props: ["shade": "#3366cc"])
		_ = try await ComponentBaker.bake(project, from: baseURL)
		let url = baseURL.appendingPathComponent(component.folder)
			.appendingPathComponent("00000.png")
		#expect(try pixel(url, x: 80, y: 45) == (51, 102, 204, 255))
		try? FileManager.default.removeItem(at: baseURL)
	}

	// MARK: - Exporting it

	/// A component and its bake both travel. The frames depend on the WebKit
	/// that drew them, so a folder exported without them would render something
	/// else on the machine it was opened on — which is what exporting exists to
	/// prevent.
	@Test func exportingAProjectBringsTheComponentAndItsFrames() async throws {
		let (project, baseURL, component) = try fixture(mover)
		_ = try await ComponentBaker.bake(project, from: baseURL)
		let target = baseURL.appendingPathComponent("exported", isDirectory: true)
		try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
		let report = try ProjectExporter.export(project, named: "p", from: baseURL, to: target)
		#expect(report.components == ["c.js"])
		#expect(FileManager.default.fileExists(atPath:
			target.appendingPathComponent("c.js").path))
		#expect(FileManager.default.fileExists(atPath:
			target.appendingPathComponent(component.folder + "/00005.png").path))
		// And the exported folder needs no bake to render: the record came too,
		// so nothing about it is stale.
		let exported = try ProjectReader.read(
			String(contentsOf: target.appendingPathComponent("p.cuttrproj"), encoding: .utf8))
		#expect(ComponentBaker.staleness(exported, from: target).isEmpty)
		try? FileManager.default.removeItem(at: baseURL)
	}
}
