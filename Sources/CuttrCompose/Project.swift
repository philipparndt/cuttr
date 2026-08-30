import CuttrKit
import Foundation

/// A programme: clips drawn from several takes, in order, with things drawn
/// over them.
///
/// The takes are the raw material and are never modified from here. A project
/// refers to their clips **by slug**, which is the whole reason a slug exists:
/// re-cutting a take — moving a boundary, renaming a clip, adding three more —
/// leaves every reference in every project still pointing at the right thing,
/// because the reference is a name rather than a time.
public struct Project: Sendable, Equatable {

	/// The take files this project draws from, relative to the project file.
	public var takes: [String]

	/// How somebody has arranged those takes.
	///
	/// A folder *refers* to takes; it does not contain them. ``takes`` stays the
	/// flat list of everything the project draws on, because that is what the
	/// resolver, the vocabulary, the exporter and sharing all read, and none of
	/// them has any business learning about an arrangement in a window.
	///
	/// Which means the two can disagree, and ``takes`` is the authority: a
	/// folder naming a take the project does not list is ignored, and a take
	/// named by two folders belongs to the first of them. Neither is an error —
	/// both are what a hand-edited file or a half-finished merge looks like, and
	/// a project has to open.
	public var folders: [Folder] = []

	/// A named gathering of takes. Empty is a perfectly good folder: making one
	/// before there is anything to put in it is the reason to be able to make
	/// one at all.
	public struct Folder: Sendable, Equatable {
		public var name: String
		public var takes: [String]

		public init(name: String, takes: [String] = []) {
			self.name = name
			self.takes = takes
		}
	}

	public var output: Output

	/// The programme, in order.
	public var timeline: [TimelineEntry]

	/// Text and spinners laid over the cut.
	public var overlays: [Overlay]

	/// Music, atmospheres, stings: sound that is not from a take.
	public var sounds: [Sound]

	/// Named colour looks, referenced by a take's `look: {profile: …}`.
	public var profiles: [String: Look]

	/// Scenes this project defines: titles, plates, anything made of parts and
	/// keyframes. Named, so an overlay can use one and fill in its parameters.
	public var scenes: [String: Scene]

	/// Named text looks. The built-in ones are merged under whatever the file
	/// defines, so a project can override `lower-third` without redefining the
	/// two it did not touch.
	public var styles: [String: TextStyle]

	/// What this project records for itself: a URL, a size, and a browser to
	/// show it in. See ``Recording``.
	public var recordings: [Recording] = []

	var unknown: UnknownProjectKeys

	/// The prose the file carried: the block at the top saying what this
	/// programme is, the line above a scene saying what it does. Not part of
	/// the value, and lost on every save until it was carried — see
	/// ``CuttrKit/FileComments``.
	public var comments = FileComments()

	/// The order the file declared its named blocks in, by block: the styles,
	/// the scenes and the profiles as they were written down.
	///
	/// A dictionary has no order, so the writer sorted them, so a file whose
	/// styles were arranged to be read top to bottom came back alphabetical.
	/// Sorting was the right answer to the wrong question — it was there to
	/// stop a dictionary's arbitrary order churning the file, and remembering
	/// the order the file actually had is deterministic in the same way and
	/// keeps somebody's arrangement as well. Anything the file did not declare
	/// is still sorted, after the rest.
	public var declaredOrder: [String: [String]] = [:]

	public init(
		takes: [String] = [],
		output: Output = Output(),
		timeline: [TimelineEntry] = [],
		overlays: [Overlay] = [],
		sounds: [Sound] = [],
		styles: [String: TextStyle] = [:],
		profiles: [String: Look] = [:],
		scenes: [String: Scene] = [:],
		unknownKeys: [String: Any] = [:]
	) {
		self.takes = takes
		self.output = output
		self.timeline = timeline
		self.overlays = overlays
		self.sounds = sounds
		self.styles = styles
		self.profiles = profiles
		self.scenes = scenes
		self.unknown = UnknownProjectKeys(storage: unknownKeys)
	}

	public var unknownKeys: [String: Any] {
		get { unknown.storage }
		set { unknown = UnknownProjectKeys(storage: newValue) }
	}

	public static func == (a: Project, b: Project) -> Bool {
		a.takes == b.takes && a.folders == b.folders && a.output == b.output
			&& a.timeline == b.timeline
			&& a.overlays == b.overlays && a.sounds == b.sounds
			&& a.styles == b.styles && a.profiles == b.profiles
			&& a.scenes == b.scenes && a.recordings == b.recordings
	}

	// MARK: - Arranging the takes

	/// Which folder a take is in, or nothing when it is loose.
	///
	/// The *first* folder that names it. A take in two folders is not a state
	/// this program can produce and is one a text editor can, and the answer
	/// has to be one of them rather than the take appearing twice.
	public func folder(of take: String) -> String? {
		folders.first { $0.takes.contains(take) }?.name
	}

	/// The takes in no folder at all, in project order.
	public var looseTakes: [String] {
		takes.filter { folder(of: $0) == nil }
	}

	/// The takes a folder holds, in project order rather than in the order the
	/// folder happens to list them — the project's order is somebody's
	/// arrangement and the file already keeps it. A path the project does not
	/// list is not one of them.
	public func takes(in folder: String) -> [String] {
		guard let found = folders.first(where: { $0.name == folder }) else { return [] }
		return takes.filter { found.takes.contains($0) && self.folder(of: $0) == folder }
	}

	@discardableResult
	public mutating func addFolder(named name: String) -> String {
		let wanted = name.trimmingCharacters(in: .whitespaces)
		guard !wanted.isEmpty else { return "" }
		guard !folders.contains(where: { $0.name == wanted }) else { return wanted }
		folders.append(Folder(name: wanted))
		return wanted
	}

	public mutating func renameFolder(_ name: String, to wanted: String) {
		let tidied = wanted.trimmingCharacters(in: .whitespaces)
		guard !tidied.isEmpty, !folders.contains(where: { $0.name == tidied }),
		      let at = folders.firstIndex(where: { $0.name == name }) else { return }
		folders[at].name = tidied
	}

	/// Takes the folder away and leaves its takes in the project, loose. An
	/// arrangement is not the material.
	public mutating func removeFolder(_ name: String) {
		folders.removeAll { $0.name == name }
	}

	/// Puts a take in a folder, or — with `nil` — takes it out of the one it is
	/// in. Out of every other folder either way, so a take is in one place.
	public mutating func move(take: String, toFolder folder: String?) {
		for index in folders.indices { folders[index].takes.removeAll { $0 == take } }
		guard let folder, let at = folders.firstIndex(where: { $0.name == folder })
		else { return }
		folders[at].takes.append(take)
	}

	/// A take leaving the project leaves its folder with it.
	public mutating func forgetTakeInFolders(_ take: String) {
		for index in folders.indices { folders[index].takes.removeAll { $0 == take } }
	}

	/// The style a name refers to, falling back through the built-ins.
	public func style(named name: String?) -> TextStyle {
		guard let name else { return TextStyle.lowerThird }
		return styles[name] ?? TextStyle.builtIn[name] ?? TextStyle.lowerThird
	}

	/// A scene by name, with the parameters it is being used with.
	///
	/// The project's own first, then the two this program brings — the same
	/// order ``style(named:)`` uses, and for the same reason: a project that
	/// writes its own `bullets` gets its own `bullets`, and nothing has to be
	/// renamed to escape a built-in.
	///
	/// The parameters are handed in because a built-in is *made* out of them:
	/// `bullets` with three lines is a different scene from `bullets` with
	/// five, where an authored one is the same scene with different words in
	/// it.
	public func scene(named name: String, with parameters: [String: String] = [:]) -> Scene? {
		scenes[name] ?? Scene.builtIn(name, with: parameters)
	}
}

struct UnknownProjectKeys: @unchecked Sendable {
	var storage: [String: Any]
}

/// What comes out the other end.
public struct Output: Sendable, Equatable {
	public var width: Int
	public var height: Int
	public var framesPerSecond: Double
	/// Where the render goes, relative to the project file. The `-o` flag beats
	/// it; this is what makes `cuttr-render project.cuttrproj` work with no
	/// arguments at all.
	public var file: String?

	/// What the programme should sound like.
	public var audio: AudioTarget?

	/// The clip everything else is graded to match. A slug, resolved like any
	/// other reference.
	public var matchReference: String?

	public init(
		width: Int = 1920, height: Int = 1080, framesPerSecond: Double = 25,
		file: String? = nil, audio: AudioTarget? = nil, matchReference: String? = nil
	) {
		self.width = width
		self.height = height
		self.framesPerSecond = framesPerSecond
		self.file = file
		self.audio = audio
		self.matchReference = matchReference
	}

	public var size: CGSize { CGSize(width: width, height: height) }
}

/// The picture moved aside, held, and something said while it is held.
///
/// **What it is for.** A screen recording explains what somebody did and not
/// why. An explainer stops, moves the recording aside, puts the point on screen
/// beside it, and carries on from where it stopped — and that last clause is the
/// hard one, because it means the programme gets longer.
public struct Presentation: Sendable, Equatable {

	/// When it happens, **on the take's clock** — the same clock the clip's own
	/// marks are on.
	///
	/// Not the programme's, and that is not a detail. A hold *changes* programme
	/// times, so a treatment written in them would need the layout to know where
	/// it is while the layout needed it to know how long the clip runs. The
	/// take's clock is known before anything is laid out, and it is the clock
	/// everything else in a take is on.
	public var at: Double

	/// Where the picture goes: `[x, y, width, height]` in fractions of the
	/// frame, as everything else in this file that places something is.
	///
	/// One rectangle rather than a zoom and a side. Those are the same
	/// information in two numbers that can disagree — "forty per cent on the
	/// left" has to say what "on the left" means at forty per cent — and the
	/// picture keeps its shape inside it either way.
	public var into: Rectangle

	/// How long the picture stands still, in seconds. The programme gets this
	/// much longer; nothing of the recording is skipped.
	public var hold: Double

	/// How long the travel takes at each end, in seconds. Eased, because a
	/// picture that arrives at a stop linearly reads as a cut to a still.
	public var ramp: Double

	/// The scene that plays while it is held, and what to fill it with.
	public var scene: String
	public var parameters: [String: String]

	/// Whether the scene's snippets are all there at once or arrive across the
	/// hold. Its own key rather than one more entry in `with:` because it is
	/// the one parameter every built-in scene answers to, and a control in the
	/// panel needs somewhere to be.
	public var reveal: Reveal

	public enum Reveal: String, Sendable, CaseIterable {
		case together
		case oneByOne = "one-by-one"
	}

	public init(at: Double, into: Rectangle, hold: Double, ramp: Double = 0.6,
	            scene: String, parameters: [String: String] = [:],
	            reveal: Reveal = .together) {
		self.at = at
		self.into = into
		self.hold = max(0, hold)
		self.ramp = max(0, ramp)
		self.scene = scene
		self.parameters = parameters
		self.reveal = reveal
	}

	/// How long the whole gesture lasts: out, held, back.
	public var span: Double { ramp + hold + ramp }

	/// Where the picture is, `time` seconds into that gesture.
	///
	/// Eased at both ends with a smoothstep. A linear travel to a stop reads as
	/// a cut to a still — the picture arrives at full speed and simply ceases —
	/// and this is the one thing in the feature that has to look deliberate.
	public func frame(at time: Double) -> Rectangle {
		guard ramp > 0 else { return time < 0 || time > span ? .whole : into }
		if time <= 0 || time >= span { return .whole }
		if time < ramp { return Rectangle.between(.whole, into, Self.eased(time / ramp)) }
		if time <= ramp + hold { return into }
		return Rectangle.between(into, .whole, Self.eased((time - ramp - hold) / ramp))
	}

	/// Smoothstep. Slow away, quick across, slow into the stop.
	static func eased(_ t: Double) -> Double {
		let t = min(1, max(0, t))
		return t * t * (3 - 2 * t)
	}

	/// A box in the frame, in fractions of it.
	public struct Rectangle: Sendable, Equatable {
		public var x: Double
		public var y: Double
		public var width: Double
		public var height: Double

		public init(x: Double, y: Double, width: Double, height: Double) {
			self.x = x
			self.y = y
			self.width = max(0, width)
			self.height = max(0, height)
		}

		/// The whole frame, which is where the picture is when nothing is
		/// happening to it.
		public static let whole = Rectangle(x: 0, y: 0, width: 1, height: 1)

		public var isWhole: Bool { self == .whole }

		/// The larger band of frame this box leaves empty, left or right.
		///
		/// What a built-in scene lays itself out in. Left and right only: a
		/// picture pushed to one side is what this feature is for, and a band
		/// above or below a full-width picture is not somewhere three sentences
		/// go.
		public var free: (x: Double, width: Double) {
			let toTheLeft = max(0, x)
			let toTheRight = max(0, 1 - (x + width))
			return toTheLeft > toTheRight ? (0, toTheLeft) : (x + width, toTheRight)
		}

		/// Part of the way from one box to another.
		public static func between(_ a: Rectangle, _ b: Rectangle, _ t: Double) -> Rectangle {
			func mix(_ x: Double, _ y: Double) -> Double { x + (y - x) * t }
			return Rectangle(x: mix(a.x, b.x), y: mix(a.y, b.y),
			                 width: mix(a.width, b.width), height: mix(a.height, b.height))
		}

		/// The largest box of the given aspect that fits inside this one,
		/// centred in it.
		///
		/// Fit rather than fill, so a rectangle of the wrong shape letterboxes
		/// instead of stretching the picture. Somebody sketching a box in a
		/// panel will draw the wrong aspect nearly every time, and a distorted
		/// screen recording is worse than a margin.
		public func fitting(aspect: Double) -> Rectangle {
			guard aspect > 0, width > 0, height > 0 else { return self }
			// Both sides are fractions of a frame that is not itself square, so
			// the aspect handed in is already expressed in those fractions.
			let mine = width / height
			if mine > aspect {
				let narrowed = height * aspect
				return Rectangle(x: x + (width - narrowed) / 2, y: y,
				                 width: narrowed, height: height)
			}
			let shortened = width / aspect
			return Rectangle(x: x, y: y + (height - shortened) / 2,
			                 width: width, height: shortened)
		}
	}
}

/// A screencast this project makes for itself: a page, at a size, in a browser
/// that is cuttr's rather than anybody's.
///
/// **Why it is written down.** Every other recording cuttr has ever seen came
/// from somewhere else and arrived as a fact. A screencast is the one kind that
/// can be *made again* — the page has changed, the copy is wrong, the window
/// was the wrong size — and making it again should be reading a file rather
/// than remembering what somebody did six weeks ago.
public struct Recording: Sendable, Equatable {

	/// What it is called. The take is called this too: one name, and the
	/// material tree already knows how to show it.
	public var name: String

	/// The page to record, when this records a page.
	///
	/// A recording records one thing, and which one is said by which key is
	/// there rather than by a `kind:` naming what the other keys already say.
	/// A recording with both is refused by name when the file is read.
	public var url: String

	/// The terminal to record, when this records a terminal.
	public var terminal: Terminal?

	/// Where the shell starts, so the prompt does not open on wherever
	/// somebody happened to be.
	public var directory: String?

	/// What to run when it opens, in the order written — so a screencast can
	/// begin with the state it is about rather than with somebody typing their
	/// way to it.
	public var run: [String] = []

	/// The palette to record in.
	///
	/// The same argument as the browser's fresh profile, and the terminals say
	/// it themselves: a capture should not depend on whoever's settings the
	/// machine happens to have. A screencast made on a laptop set to a light
	/// theme and one made on a desktop set to a dark one are two different
	/// films of the same thing.
	///
	/// Whatever the terminal calls its themes; nothing here has a list, because
	/// the list belongs to whichever terminal is installed and would be wrong
	/// the week after it was written down.
	public var theme: String?

	/// The size of the **recording** — the window as captured, chrome and all,
	/// which is what lands in the take and has to fit the output's frame.
	///
	/// Not the page's size, which is this minus whatever the browser's chrome
	/// costs. One number, and no ambiguity about which of two things it names:
	/// a recording that needs the page at an exact size is a different number
	/// and can be a different key, and guessing which was meant is how a
	/// feature grows a setting nobody can explain.
	public var width: Int
	public var height: Int

	/// Which browser to drive, or nothing for whichever is installed.
	public var browser: Browser?

	/// Whether the browser's own chrome is in the film.
	public var chrome: Chrome

	/// Compared on what it *says*. Two recordings that differ only in a key
	/// neither of them understands are the same recording as far as this
	/// program is concerned, and making that a difference would mean a file
	/// from a later version reading as edited the moment it was opened.
	public static func == (a: Recording, b: Recording) -> Bool {
		a.name == b.name && a.url == b.url && a.width == b.width
			&& a.height == b.height && a.browser == b.browser && a.chrome == b.chrome
			&& a.terminal == b.terminal && a.directory == b.directory && a.run == b.run
			&& a.theme == b.theme
	}

	/// Whether this records a terminal rather than a page.
	public var recordsATerminal: Bool { terminal != nil }

	/// The terminals cuttr drives.
	///
	/// Three, named. Not iTerm, Warp, Alacritty or Kitty: each drives
	/// differently, and adding one without a reason to choose it is how a list
	/// like this becomes a list of things nobody has tried.
	public enum Terminal: String, Sendable, CaseIterable {
		/// The one every Mac has, and the one a viewer is most likely to
		/// recognise. It costs a second permission — see `CuttrRecord`.
		case terminal
		case ghostty
		case abydos

		public var application: String {
			switch self {
			case .terminal: return "/System/Applications/Utilities/Terminal.app"
			case .ghostty: return "/Applications/Ghostty.app"
			case .abydos: return "/Applications/Abydos.app"
			}
		}

		public var described: String {
			switch self {
			case .terminal: return "Terminal"
			case .ghostty: return "Ghostty"
			case .abydos: return "Abydos"
			}
		}
	}

	public enum Browser: String, Sendable, CaseIterable {
		case chrome, chromium, edge

		/// Where each one lives, in the order they are looked for.
		public var application: String {
			switch self {
			case .chrome: return "/Applications/Google Chrome.app"
			case .chromium: return "/Applications/Chromium.app"
			case .edge: return "/Applications/Microsoft Edge.app"
			}
		}

		public var described: String {
			switch self {
			case .chrome: return "Google Chrome"
			case .chromium: return "Chromium"
			case .edge: return "Microsoft Edge"
			}
		}
	}

	/// What is above the page.
	public enum Chrome: String, Sendable, CaseIterable {
		/// Back, forward, reload and the address bar. The default, because a
		/// screencast that does not say where it is has to say it in words
		/// instead — "go to the downloads page" is a sentence about an address
		/// bar.
		case bar
		/// Nothing: the whole frame is the page, for the films that are about
		/// what is on the page rather than about the browser.
		case none
	}

	/// Anything this version has never heard of, kept so that a file written by
	/// a later one survives being opened and saved by this one — the same
	/// promise the rest of the format makes, and it has to be made per entry
	/// because a recording is written in a list.
	var unknown = UnknownProjectKeys(storage: [:])

	public var unknownKeys: [String: Any] {
		get { unknown.storage }
		set { unknown = UnknownProjectKeys(storage: newValue) }
	}

	public var size: CGSize { CGSize(width: width, height: height) }

	public init(name: String, url: String = "", width: Int = 1280, height: Int = 720,
	            browser: Browser? = nil, chrome: Chrome = .bar,
	            terminal: Terminal? = nil, directory: String? = nil, run: [String] = [],
	            theme: String? = nil) {
		self.name = name
		self.url = url
		self.terminal = terminal
		self.directory = directory
		self.run = run
		self.theme = theme
		self.width = max(1, width)
		self.height = max(1, height)
		self.browser = browser
		self.chrome = chrome
	}
}

/// How loud the finished programme should be.
///
/// Defaults are the streaming convention rather than the broadcast one: −16 LUFS
/// with a decibel of headroom is what a video on the web is expected to be, and
/// −23 is what a television station wants. Neither is a fact; both are stated so
/// that a project which says nothing still comes out level.
public struct AudioTarget: Sendable, Equatable {
	public var target: Double
	public var ceiling: Double

	public init(target: Double = -16, ceiling: Double = -1) {
		self.target = target
		self.ceiling = ceiling
	}
}

/// One entry on the programme's timeline.
///
/// An entry is not always one clip. `tag:` puts *every* clip carrying a label
/// there, in the order the clips themselves declare — so an assembly can say
/// "and then all the b-roll" and stay correct when a thirteenth b-roll shot is
/// cut next week. That is the difference between a project file that survives a
/// re-cut and one that has to be maintained alongside the takes.
public struct TimelineEntry: Sendable, Equatable {

	public enum Source: Sendable, Equatable {
		/// `take-01/intro`, or `intro` when no other take has that slug.
		case clip(ClipReference)
		/// Several clips, in the order written.
		case list([ClipReference])
		/// Every clip a query selects, sorted by each clip's own `order`.
		case query(ClipQuery, source: String)
		/// Time on the programme with no take behind it: a length and a fill.
		///
		/// The one entry that is not a reference. An intro screen is a stretch
		/// of programme that exists to be drawn on, and making somebody shoot
		/// four seconds of a blank wall to have somewhere to put a title is not
		/// an assembly language.
		case card(Card)
		/// A named section of the programme.
		///
		/// Groups exist so that an overlay can be hung on a *section* rather
		/// than on the clip that happens to open it — `from: @introduction`
		/// stays right when a shot is added to the introduction, where
		/// `from: intro to: demo` does not. They nest, because a section of a
		/// section is a thing programmes have.
		indirect case group(String, [TimelineEntry])

		public var description: String {
			switch self {
			case .clip(let reference): return reference.description
			case .list(let references): return references.map(\.description).joined(separator: ", ")
			case .query(_, let source): return source
			case .card(let card): return "card \(Timecode.string(card.duration))"
			case .group(let name, _): return "@\(name)"
			}
		}
	}

	public var source: Source
	/// How this entry arrives from the one before it: a cut unless it says
	/// otherwise, and an overlap of some kind when it does.
	public var transition: Transition

	/// A name for *this placement* of the clip.
	///
	/// A clip used twice is two places on the programme, and `from: intro`
	/// cannot tell them apart — which is what makes using one twice awkward.
	/// `as: opening` names the placement, and an overlay hangs on `@opening`
	/// exactly as it would on a section. It behaves like a section of one clip,
	/// because that is what it is.
	public var label: String?

	/// Seconds off the head and the tail of the clip, for this placement only.
	///
	/// The take is not touched: trimming here says "use a bit less of it here",
	/// which is what somebody wants when the same shot is used twice at
	/// different lengths. A clip trimmed to nothing is dropped rather than
	/// rendered as a frame of nothing.
	public var trim: (head: Double, tail: Double)

	/// What is drawn over *this placement*.
	///
	/// An overlay written here and given no range of its own covers exactly
	/// what this entry lays down — which is the case a name cannot express.
	/// `from: intro` finds every use of `intro`, so a clip used twice could
	/// only be told apart by giving each placement an `as:` label and hanging
	/// the caption on that; two names invented to say something the structure
	/// already knew. Written inside the entry, the caption belongs to the entry
	/// and to nothing else.
	///
	/// One that *does* write a range means what it says, exactly as it would in
	/// the top-level list — being written here is then only a statement about
	/// where it is filed.
	public var overlays: [Overlay]

	/// Sound laid under *this placement*, on the same terms as the overlays
	/// above: written here and given no range, it plays for exactly as long as
	/// this entry is on. A sting on one shot rather than on every use of it.
	public var sounds: [Sound]

	/// The presentation treatments on *this* use of the recording.
	///
	/// Written inside the entry, beside the overlays and the sounds, and for the
	/// same reason they are: a hold is a fact about this placement. The same
	/// clip put on the programme twice should not stop in both.
	public var presentations: [Presentation] = []

	/// Whether this entry puts a picture on the programme that could be moved
	/// aside and held.
	///
	/// A card is already still, and a section is a list of placements rather
	/// than one of them — a treatment on either would have nothing to hold.
	public var carriesPictures: Bool {
		switch source {
		case .clip, .list, .query: return true
		case .card, .group: return false
		}
	}

	public static func == (a: TimelineEntry, b: TimelineEntry) -> Bool {
		a.source == b.source && a.transition == b.transition && a.label == b.label
			&& a.trim == b.trim && a.overlays == b.overlays && a.sounds == b.sounds
			&& a.presentations == b.presentations
	}

	public init(
		source: Source, transition: Transition = .cut,
		label: String? = nil, trim: (head: Double, tail: Double) = (0, 0),
		overlays: [Overlay] = [], sounds: [Sound] = []
	) {
		self.source = source
		self.transition = transition
		self.label = label
		self.trim = trim
		self.overlays = overlays
		self.sounds = sounds
	}

	public init(
		clip: ClipReference, transition: Transition = .cut,
		label: String? = nil, trim: (head: Double, tail: Double) = (0, 0),
		overlays: [Overlay] = [], sounds: [Sound] = []
	) {
		self.init(source: .clip(clip), transition: transition, label: label, trim: trim,
		          overlays: overlays, sounds: sounds)
	}

	public init(list: [ClipReference], transition: Transition = .cut,
	            overlays: [Overlay] = [], sounds: [Sound] = []) {
		self.init(source: .list(list), transition: transition, overlays: overlays, sounds: sounds)
	}

	/// A query written as text, which is how it arrives from the file and how
	/// it is written back — keeping the source means a hand-written query comes
	/// out the way it went in rather than re-printed from the parse tree.
	public init(query: String, transition: Transition = .cut,
	            overlays: [Overlay] = [], sounds: [Sound] = []) throws {
		self.init(source: .query(try QueryParser.parse(query), source: query),
		          transition: transition, overlays: overlays, sounds: sounds)
	}

	/// A card, which takes a name for its placement like any other entry — and
	/// wants one more than most, because `@intro` is how the title finds it.
	public init(card: Card, transition: Transition = .cut, label: String? = nil,
	            overlays: [Overlay] = [], sounds: [Sound] = []) {
		self.init(source: .card(card), transition: transition, label: label,
		          overlays: overlays, sounds: sounds)
	}

	public init(group: String, entries: [TimelineEntry], transition: Transition = .cut,
	            overlays: [Overlay] = [], sounds: [Sound] = []) {
		self.init(source: .group(group, entries), transition: transition,
		          overlays: overlays, sounds: sounds)
	}

	/// An entry written the way it is written in the file.
	///
	/// `intro` is a clip, `#b-roll and not #reject` is a query, `@introduction`
	/// is a section. One rule, used by the reader and by the panel, so that what
	/// somebody types in a field and what they type in the file mean the same
	/// thing — which is most of what the panel is for.
	///
	/// A clip is recognised by *being* one rather than a query by looking like
	/// one — see ``ClipReference/init(reference:)``. The rule used to be that
	/// anything with a space in it was a query, which quietly broke every take
	/// whose name has a space: dragging one clip out of `Mia 1` wrote
	/// `query: Mia 1/that-clip`, the query language split it at the space, and
	/// it came to mean "the clip `mia`, and the clip `that-clip` in a take
	/// called `1`" — nothing, in every project. The file was then saved that
	/// way, so the mistake outlived the drag.
	public init(text: String, transition: Transition = .cut) throws {
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		if trimmed.hasPrefix("@") {
			self.init(group: Slug.make(from: String(trimmed.dropFirst())), entries: [], transition: transition)
		} else if let reference = ClipReference(reference: trimmed) {
			self.init(clip: reference, transition: transition)
		} else if trimmed.isEmpty {
			// Nothing at all is a clip with no name, which is what it was
			// before this and says so plainly: `No clip called ``.` The query
			// parser would refuse it, which is true but less use.
			self.init(clip: ClipReference(trimmed), transition: transition)
		} else {
			try self.init(query: trimmed, transition: transition)
		}
	}

	/// The single clip this names, for the cases that only make sense for one.
	public var clip: ClipReference? {
		if case .clip(let reference) = source { return reference }
		return nil
	}
}

/// Where something laid over the programme is written down.
///
/// An index into `overlays:` was enough while that was the only place an
/// overlay could be. Now that a timeline entry carries its own — and its own
/// sounds — the panel, the strip and the effect renderers all need to say
/// *which* one they mean, and "the third one" no longer picks out a single
/// thing. A path and an index does.
///
/// One type for overlays and for sounds, because it is one idea: which of two
/// lists is being addressed is never in doubt at the place that asks, and two
/// enums of the same shape are two things to keep in step.
public enum Origin: Sendable, Equatable, Hashable {
	/// The nth of the project's own top-level list.
	case project(Int)
	/// The nth one written inside the timeline entry at this path.
	case entry(path: [Int], index: Int)

	/// The top-level index, for the places that are only ever about that list —
	/// the overlay and sound tables, which list it and nothing else.
	public var projectIndex: Int? {
		if case .project(let index) = self { return index }
		return nil
	}
}

/// A reference to a clip in a take.
///
/// The take part is optional because most slugs are unique across a project and
/// writing `take-01/` in front of every one of them is noise. It becomes
/// required the moment two takes disagree, and ``Resolver`` says so by name
/// rather than picking one.
public struct ClipReference: Sendable, Equatable, CustomStringConvertible {
	public var take: String?
	public var slug: String

	public init(take: String? = nil, slug: String) {
		self.take = take
		self.slug = slug
	}

	public init(_ text: String) {
		let parts = text.split(separator: "/", maxSplits: 1)
		if parts.count == 2 {
			self.take = String(parts[0])
			self.slug = String(parts[1])
		} else {
			self.take = nil
			self.slug = text
		}
	}

	/// The reference this text is, or nothing when it is not one.
	///
	/// This is the rule that tells a reference from a query, and it is stated
	/// from the reference's side on purpose. A reference is a slug, optionally
	/// with a take in front of it: the slug is an identifier and has to look
	/// like one, while the take is a file name and may say anything at all,
	/// spaces included. So `Mia 1/that-clip` is a reference and `#b-roll`,
	/// `Mia 1/*` and `intro or outro` are not — none of them ends in a slug.
	///
	/// Asking what a query looks like instead is what went wrong before:
	/// every mark the query language uses can also appear in somebody's take
	/// name, and a heuristic over those turned a perfectly good reference into
	/// a query that could never match. There is nothing a slug can be mistaken
	/// for.
	public init?(reference text: String) {
		self.init(text)
		guard Slug.isValid(slug), take != "" else { return nil }
	}

	public var description: String { take.map { "\($0)/\(slug)" } ?? slug }
}
