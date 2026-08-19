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

	var unknown: UnknownProjectKeys

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
		a.takes == b.takes && a.output == b.output && a.timeline == b.timeline
			&& a.overlays == b.overlays && a.sounds == b.sounds
			&& a.styles == b.styles && a.profiles == b.profiles
			&& a.scenes == b.scenes
	}

	/// The style a name refers to, falling back through the built-ins.
	public func style(named name: String?) -> TextStyle {
		guard let name else { return TextStyle.lowerThird }
		return styles[name] ?? TextStyle.builtIn[name] ?? TextStyle.lowerThird
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

	public static func == (a: TimelineEntry, b: TimelineEntry) -> Bool {
		a.source == b.source && a.transition == b.transition && a.label == b.label
			&& a.trim == b.trim
	}

	public init(
		source: Source, transition: Transition = .cut,
		label: String? = nil, trim: (head: Double, tail: Double) = (0, 0)
	) {
		self.source = source
		self.transition = transition
		self.label = label
		self.trim = trim
	}

	public init(
		clip: ClipReference, transition: Transition = .cut,
		label: String? = nil, trim: (head: Double, tail: Double) = (0, 0)
	) {
		self.init(source: .clip(clip), transition: transition, label: label, trim: trim)
	}

	public init(list: [ClipReference], transition: Transition = .cut) {
		self.init(source: .list(list), transition: transition)
	}

	/// A query written as text, which is how it arrives from the file and how
	/// it is written back — keeping the source means a hand-written query comes
	/// out the way it went in rather than re-printed from the parse tree.
	public init(query: String, transition: Transition = .cut) throws {
		self.init(source: .query(try QueryParser.parse(query), source: query), transition: transition)
	}

	/// A card, which takes a name for its placement like any other entry — and
	/// wants one more than most, because `@intro` is how the title finds it.
	public init(card: Card, transition: Transition = .cut, label: String? = nil) {
		self.init(source: .card(card), transition: transition, label: label)
	}

	public init(group: String, entries: [TimelineEntry], transition: Transition = .cut) {
		self.init(source: .group(group, entries), transition: transition)
	}

	/// An entry written the way it is written in the file.
	///
	/// `intro` is a clip, `#b-roll and not #reject` is a query, `@introduction`
	/// is a section. One rule, used by the reader and by the panel, so that what
	/// somebody types in a field and what they type in the file mean the same
	/// thing — which is most of what the panel is for.
	public init(text: String, transition: Transition = .cut) throws {
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		if trimmed.hasPrefix("@") {
			self.init(group: Slug.make(from: String(trimmed.dropFirst())), entries: [], transition: transition)
		} else if trimmed.contains("#") || trimmed.contains("*") || trimmed.contains(" ") {
			try self.init(query: trimmed, transition: transition)
		} else {
			self.init(clip: ClipReference(trimmed), transition: transition)
		}
	}

	/// The single clip this names, for the cases that only make sense for one.
	public var clip: ClipReference? {
		if case .clip(let reference) = source { return reference }
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

	public var description: String { take.map { "\($0)/\(slug)" } ?? slug }
}
