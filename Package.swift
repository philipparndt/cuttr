// swift-tools-version: 6.0
import PackageDescription

// cuttr cuts video as text.
//
// Everything that reads media uses what ships with macOS — AVFoundation to
// decode, Accelerate to correlate two waveforms — so the part of this program
// that touches a recording has no dependencies at all and will still build
// years from now.
//
// There is one dependency, and it is deliberately kept to *reading*. The clip
// list is YAML, and a hand-written parser for it would be wrong in a way that
// only shows up on somebody's real file: YAML has block scalars, quoting rules
// and escapes, and a note field is exactly where a colon or a `#` turns up.
// Yams is libyaml, which is the reference implementation, built from source.
//
// Writing is ours (`TakeWriter`). An emitter chooses the layout, and the layout
// is the whole point of an as-text tool: one clip per block, fixed key order,
// aligned columns, so that `git diff` over a re-save shows the edit somebody
// made and not a reflow of the file. No general emitter will do that, so this
// one does not use one.
let package = Package(
	name: "cuttr",
	platforms: [.macOS(.v14)],
	products: [
		.executable(name: "cuttr", targets: ["cuttr"]),
		// The window layer, so an Xcode app target can be built from the same
		// sources without a second copy of the dependency graph.
		.library(name: "CuttrUI", targets: ["CuttrUI"]),
		.library(name: "CuttrKit", targets: ["CuttrKit"]),
		.library(name: "CuttrCompose", targets: ["CuttrCompose"]),
		.library(name: "CuttrRecord", targets: ["CuttrRecord"]),
		// The renderer without a window: rendering a project is minutes of
		// encoding, and the machine doing it does not need a screen.
		.executable(name: "cuttr-render", targets: ["cuttr-render"]),
	],
	dependencies: [
		.package(url: "https://github.com/jpsim/Yams", from: "5.1.0"),
	],
	targets: [
		// The model: takes, clips, timecode, waveforms, alignment. Kept free of
		// view code so all of it can be tested without a window — the parser and
		// the aligner are where the decisions with right answers live.
		.target(
			name: "CuttrKit",
			dependencies: [.product(name: "Yams", package: "Yams")],
			swiftSettings: [.swiftLanguageMode(.v5)]
		),
		// The assembly: a project referencing clips by slug across takes, the
		// overlays laid over them, and the renderer that turns the two into a
		// file.
		//
		// Kept apart from CuttrKit rather than folded into it, because they
		// answer to different things. CuttrKit is about one recording and is
		// what the cutting window uses; this is about a programme made of
		// several, and nothing in the cutting window should have to link a
		// video encoder to draw a waveform.
		//
		// `Runtime/` is React and the component runtime, as resources. They are
		// in the bundle because the whole point of `component:` is that there is
		// nothing to install and nothing to fetch: two files from React under
		// MIT and one of ours, 155 kB in total, recorded in
		// `Sources/CuttrCompose/Runtime/LICENCES.md`. A `package.json` here
		// would be the dependency `docs/remotion.md` decided not to take.
		.target(
			name: "CuttrCompose",
			dependencies: ["CuttrKit", .product(name: "Yams", package: "Yams")],
			resources: [.copy("Runtime")],
			swiftSettings: [.swiftLanguageMode(.v5)]
		),
		// Making a recording rather than reading one: a browser cuttr drives and
		// a window it captures.
		//
		// Its own target because it is the one part of the program that starts
		// somebody else's process and asks the system for permission. Nothing
		// in the cutting window should have to link ScreenCaptureKit to draw a
		// waveform, and nothing here should be reachable from the renderer.
		.target(
			name: "CuttrRecord",
			dependencies: ["CuttrKit", "CuttrCompose"],
			swiftSettings: [.swiftLanguageMode(.v5)]
		),
		.testTarget(
			name: "CuttrRecordTests",
			dependencies: ["CuttrRecord"],
			swiftSettings: [.swiftLanguageMode(.v5)]
		),
		.executableTarget(
			name: "cuttr-render",
			dependencies: ["CuttrCompose"],
			swiftSettings: [.swiftLanguageMode(.v5)]
		),
		.testTarget(
			name: "CuttrComposeTests",
			dependencies: ["CuttrCompose"],
			swiftSettings: [.swiftLanguageMode(.v5)]
		),
		// AppKit shell: window, player, timeline, clip list.
		//
		// A library rather than the executable itself, so an Xcode application
		// target can be built from these same sources without declaring the
		// dependency graph a second time.
		.target(
			name: "CuttrUI",
			dependencies: ["CuttrKit", "CuttrCompose", "CuttrRecord"],
			swiftSettings: [.swiftLanguageMode(.v5)]
		),
		// Four lines: make an application, give it the delegate, run it.
		.executableTarget(
			name: "cuttr",
			dependencies: ["CuttrUI"],
			swiftSettings: [.swiftLanguageMode(.v5)]
		),
		// The panels, built and reloaded without a window.
		//
		// Two crashes on launch came from AppKit refusing something a view did
		// while it was being assembled — a constraint across two hierarchies, a
		// grid row that could not be removed. None of that needs a person at the
		// keyboard to find, and none of it was found without one.
		.testTarget(
			name: "CuttrUITests",
			dependencies: ["CuttrUI"],
			swiftSettings: [.swiftLanguageMode(.v5)]
		),
		.testTarget(
			name: "CuttrKitTests",
			dependencies: ["CuttrKit"],
			swiftSettings: [.swiftLanguageMode(.v5)]
		),
	]
)
