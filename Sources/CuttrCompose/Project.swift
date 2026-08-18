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
		styles: [String: TextStyle] = [:],
		unknownKeys: [String: Any] = [:]
	) {
		self.takes = takes
		self.output = output
		self.timeline = timeline
		self.overlays = overlays
		self.styles = styles
		self.unknown = UnknownProjectKeys(storage: unknownKeys)
	}

	public var unknownKeys: [String: Any] {
		get { unknown.storage }
		set { unknown = UnknownProjectKeys(storage: newValue) }
	}

	public static func == (a: Project, b: Project) -> Bool {
		a.takes == b.takes && a.output == b.output && a.timeline == b.timeline
			&& a.overlays == b.overlays && a.styles == b.styles
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

	public init(width: Int = 1920, height: Int = 1080, framesPerSecond: Double = 25, file: String? = nil) {
		self.width = width
		self.height = height
		self.framesPerSecond = framesPerSecond
		self.file = file
	}

	public var size: CGSize { CGSize(width: width, height: height) }
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
			case .group(let name, _): return "@\(name)"
			}
		}
	}

	public var source: Source
	/// Seconds to cross-fade into this entry from the one before, 0 for a cut.
	public var transition: Double

	public init(source: Source, transition: Double = 0) {
		self.source = source
		self.transition = transition
	}

	public init(clip: ClipReference, transition: Double = 0) {
		self.init(source: .clip(clip), transition: transition)
	}

	public init(list: [ClipReference], transition: Double = 0) {
		self.init(source: .list(list), transition: transition)
	}

	/// A query written as text, which is how it arrives from the file and how
	/// it is written back — keeping the source means a hand-written query comes
	/// out the way it went in rather than re-printed from the parse tree.
	public init(query: String, transition: Double = 0) throws {
		self.init(source: .query(try QueryParser.parse(query), source: query), transition: transition)
	}

	public init(group: String, entries: [TimelineEntry], transition: Double = 0) {
		self.init(source: .group(group, entries), transition: transition)
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
