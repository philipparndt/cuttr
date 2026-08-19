import CoreGraphics
import Foundation

/// Something drawn over the cut.
///
/// One type with a `kind` rather than a protocol with two conformers, because
/// what an overlay *is* — when it appears, how it arrives, how it leaves, where
/// it sits — is the same question for a caption and for a spinner, and only the
/// last line differs. A protocol would put the shared nine tenths in a default
/// implementation nobody can read.
public struct Overlay: Sendable, Equatable {

	public enum Kind: Sendable, Equatable {
		/// A caption. The text is the thing; the style says how it looks.
		case text(String, style: String?)
		/// A spinner, which is the same shape however it is drawn.
		case spinner(Spinner)
	}

	public var kind: Kind

	/// Each time it is on screen, and what it says while it is.
	///
	/// A list, because one overlay is often wanted in three places — a spinner
	/// that comes back every time the same thing is happening, a title that
	/// returns for the reprise. Written as a list only when there is more than
	/// one of them, so the ordinary overlay stays the four lines it always was.
	public var appearances: [Appearance]

	/// One time it is on, with what it says then.
	///
	/// The words belong to the appearance rather than to the overlay because
	/// that is what a spinner over a long take is for: "Thinking" the first
	/// time, "Still thinking" the second. Saying it twice as two overlays with
	/// the same anchor, size, colour, arrival and departure is four lines of
	/// duplication that then have to be kept in step by hand.
	public struct Appearance: Sendable, Equatable {
		public var span: Span
		/// What a caption says here, when that differs from the overlay's own.
		public var text: String?
		/// What a spinner says here, likewise.
		public var words: [SpinnerWord]?

		public init(_ span: Span, text: String? = nil, words: [SpinnerWord]? = nil) {
			self.span = span
			self.text = text
			self.words = words
		}

		public var says: Bool { text != nil || words != nil }
	}

	/// The ranges alone, which is what most of this program cares about.
	public var spans: [Span] { appearances.map(\.span) }

	/// The first range, which for most overlays is the only one.
	public var span: Span {
		get { appearances.first?.span ?? .times(from: 0, to: 0) }
		set {
			if appearances.isEmpty { appearances = [Appearance(newValue)] }
			else { appearances[0].span = newValue }
		}
	}

	/// The overlay as it is at one of its appearances: what it says there,
	/// rather than what it says by default.
	public func shown(at appearance: Appearance) -> Overlay {
		var out = self
		switch kind {
		case .text(let text, let style):
			out.kind = .text(appearance.text ?? text, style: style)
		case .spinner(var spinner):
			if let words = appearance.words { spinner.words = words }
			out.kind = .spinner(spinner)
		}
		return out
	}

	/// How it arrives and how it leaves.
	public var arrival: Transition
	public var departure: Transition

	/// Where it sits. An anchor overrides the style's position and makes the
	/// overlay follow whatever the anchor follows.
	public var anchor: String?
	/// Offset from the anchor, in fractions of the frame **height** — both axes
	/// in the same unit, so a spinner stays the same distance above a head on a
	/// 16:9 render and a 4:3 one.
	public var offset: CGPoint

	public init(
		kind: Kind,
		appearances: [Appearance],
		arrival: Transition = .slide(.left, over: 0.4),
		departure: Transition = .slide(.right, over: 0.4),
		anchor: String? = nil,
		offset: CGPoint = .zero
	) {
		self.kind = kind
		self.appearances = appearances
		self.arrival = arrival
		self.departure = departure
		self.anchor = anchor
		self.offset = offset
	}

	/// The overlay most projects write: on over one range, saying one thing.
	public init(
		kind: Kind,
		span: Span,
		arrival: Transition = .slide(.left, over: 0.4),
		departure: Transition = .slide(.right, over: 0.4),
		anchor: String? = nil,
		offset: CGPoint = .zero
	) {
		self.init(kind: kind, appearances: [Appearance(span)], arrival: arrival,
		          departure: departure, anchor: anchor, offset: offset)
	}

	/// Several ranges, all saying the same thing.
	public init(
		kind: Kind,
		spans: [Span],
		arrival: Transition = .slide(.left, over: 0.4),
		departure: Transition = .slide(.right, over: 0.4),
		anchor: String? = nil,
		offset: CGPoint = .zero
	) {
		self.init(kind: kind, appearances: spans.map { Appearance($0) }, arrival: arrival,
		          departure: departure, anchor: anchor, offset: offset)
	}

	/// Where an overlay lives on the programme's clock.
	///
	/// Bound to **clips** by default, and that is the point. A caption that
	/// belongs to a section of the programme should still belong to it after
	/// somebody re-cuts a take and every time in the file moves — so it says
	/// "from `intro` to `demo-install`", and the times are worked out at render.
	/// Explicit times are there for the cases that are genuinely about time.
	public enum Span: Sendable, Equatable {
		/// From the start of one mark to the end of another, inclusive. The
		/// same mark twice is a single clip or a single group.
		case marks(from: Endpoint, to: Endpoint)
		case times(from: Double, to: Double)

		/// A clip by slug, or a section by name.
		public enum Endpoint: Sendable, Equatable {
			case clip(ClipReference)
			case group(String)

			/// `@name` is a group, anything else is a clip. The same shape as
			/// `#tag` in a query, and for the same reason: a slug can contain
			/// neither character, so there is nothing to disambiguate.
			public init(_ text: String) {
				if text.hasPrefix("@") { self = .group(String(text.dropFirst())) }
				else { self = .clip(ClipReference(text)) }
			}

			public var description: String {
				switch self {
				case .clip(let reference): return reference.description
				case .group(let name): return "@\(name)"
				}
			}
		}

		/// The old two-clip spelling, kept because it is what most spans are.
		public static func clips(from: ClipReference, to: ClipReference) -> Span {
			.marks(from: .clip(from), to: .clip(to))
		}
	}

	/// How an overlay enters or leaves.
	///
	/// `over` is the length of the movement, taken from *inside* the span at
	/// each end. So two overlays whose spans meet — one ending where the next
	/// begins — cross at the boundary: the first slides out to the right at the
	/// same moment the second slides in from the left, with no gap to arrange
	/// and nothing to keep in step by hand. That is the effect the whole
	/// clip-bound design exists to make automatic.
	public enum Transition: Sendable, Equatable {
		case cut
		case fade(over: Double)
		case slide(Edge, over: Double)

		public enum Edge: String, Sendable, CaseIterable {
			case left, right, up, down
		}

		public var duration: Double {
			switch self {
			case .cut: return 0
			case .fade(let over): return over
			case .slide(_, let over): return over
			}
		}
	}
}

/// One thing a spinner says, and for how long.
public struct SpinnerWord: Sendable, Equatable {
	public var text: String
	/// Seconds. `nil` shares the overlay's span evenly with the other words
	/// that also left it out, which is what makes the common case one line each
	/// and no arithmetic.
	public var duration: Double?

	public init(_ text: String, duration: Double? = nil) {
		self.text = text
		self.duration = duration
	}
}

/// A progress spinner, of the kind that goes over somebody's head.
public struct Spinner: Sendable, Equatable {
	public enum Style: String, Sendable, CaseIterable {
		/// Dots around a circle, fading in turn — the system's own idiom.
		case dots
		/// A gap-toothed ring going round.
		case ring
		/// A single arc sweeping.
		case arc
	}

	public var style: Style
	/// Diameter, in fractions of the frame height.
	public var size: Double
	/// Turns a second.
	public var speed: Double
	public var color: RGBA

	/// What it says, in turn, beside the spinner.
	///
	/// The thing a terminal spinner does that a video overlay usually does not:
	/// the glyph turning says "still going", and the words changing say what it
	/// is going now. Empty for a spinner that only turns.
	///
	/// The sequence repeats for as long as the overlay is on screen, so three
	/// words over a thirty-second clip is three words cycling rather than three
	/// words and then silence.
	public var words: [SpinnerWord]

	/// The style the words are drawn in. Defaults to ``TextStyle/caption``,
	/// which has no plate behind it — a spinner over somebody's head should not
	/// arrive with a black box.
	public var wordStyle: String?

	public init(
		style: Style = .dots, size: Double = 0.09, speed: Double = 1,
		color: RGBA = .white, words: [SpinnerWord] = [], wordStyle: String? = nil
	) {
		self.style = style
		self.size = size
		self.speed = speed
		self.color = color
		self.words = words
		self.wordStyle = wordStyle
	}

	/// How long each word is on screen, given the overlay's span.
	///
	/// Words with a stated duration keep it; the rest share what is left of one
	/// pass. If the stated ones already fill the span there is nothing to
	/// share, and the unstated ones fall back to a second each rather than to
	/// zero — a word nobody can read is not what was meant.
	public func schedule(over span: Double) -> [(word: SpinnerWord, duration: Double)] {
		guard !words.isEmpty else { return [] }
		let stated = words.compactMap(\.duration).reduce(0, +)
		let unstatedCount = words.filter { $0.duration == nil }.count
		let share = unstatedCount > 0 ? max(0.4, (span - stated) / Double(unstatedCount)) : 0
		return words.map { ($0, $0.duration ?? share) }
	}
}

/// How a caption looks.
///
/// Sizes and positions are fractions of the frame rather than points, so a
/// project renders the same at 1080 and at 4K. A caption written for a preview
/// and then rendered at twice the size with half the type is the sort of thing
/// that is only noticed after the export.
public struct TextStyle: Sendable, Equatable {
	public var font: String
	/// Cap height as a fraction of the frame height.
	public var size: Double
	public var color: RGBA
	/// The plate behind the text. Transparent for none.
	public var background: RGBA
	/// Padding inside the plate, in fractions of the frame height.
	public var padding: Double
	public var cornerRadius: Double
	/// Where the text sits, normalised, origin bottom-left. Which part of the
	/// text this positions is decided by ``alignment``.
	public var position: CGPoint
	public var alignment: Alignment

	public enum Alignment: String, Sendable, CaseIterable {
		case left, centre, right
	}

	public init(
		font: String = "Helvetica Neue Medium",
		size: Double = 0.052,
		color: RGBA = .white,
		background: RGBA = RGBA(r: 0, g: 0, b: 0, a: 0.72),
		padding: Double = 0.022,
		cornerRadius: Double = 0.008,
		position: CGPoint = CGPoint(x: 0.07, y: 0.13),
		alignment: Alignment = .left
	) {
		self.font = font
		self.size = size
		self.color = color
		self.background = background
		self.padding = padding
		self.cornerRadius = cornerRadius
		self.position = position
		self.alignment = alignment
	}

	public static let lowerThird = TextStyle()

	public static let centred = TextStyle(
		size: 0.075, position: CGPoint(x: 0.5, y: 0.5), alignment: .centre)

	/// Small, no plate: for the words beside a spinner, which sit over somebody
	/// rather than along the bottom of the frame.
	public static let caption = TextStyle(
		size: 0.038,
		background: RGBA(r: 0, g: 0, b: 0, a: 0),
		padding: 0.008,
		alignment: .left)

	public static let title = TextStyle(
		font: "Helvetica Neue Bold", size: 0.11,
		background: RGBA(r: 0, g: 0, b: 0, a: 0),
		position: CGPoint(x: 0.5, y: 0.52), alignment: .centre)

	/// Available without being written down, and overridable by writing one
	/// down: a project that redefines `lower-third` still gets the other two.
	public static let builtIn: [String: TextStyle] = [
		"lower-third": .lowerThird,
		"centre": .centred,
		"center": .centred,
		"title": .title,
		"caption": .caption,
	]
}

/// A colour, as it is written in the file: `#rrggbb` or `#rrggbbaa`.
public struct RGBA: Sendable, Equatable {
	public var r: Double, g: Double, b: Double, a: Double

	public init(r: Double, g: Double, b: Double, a: Double = 1) {
		self.r = r; self.g = g; self.b = b; self.a = a
	}

	public static let white = RGBA(r: 1, g: 1, b: 1)
	public static let black = RGBA(r: 0, g: 0, b: 0)

	public init?(hex: String) {
		var text = hex.trimmingCharacters(in: .whitespaces)
		if text.hasPrefix("#") { text.removeFirst() }
		guard text.count == 6 || text.count == 8, let value = UInt32(text, radix: 16) else { return nil }
		let hasAlpha = text.count == 8
		let shift = hasAlpha ? 24 : 16
		r = Double((value >> UInt32(shift)) & 0xff) / 255
		g = Double((value >> UInt32(shift - 8)) & 0xff) / 255
		b = Double((value >> UInt32(shift - 16)) & 0xff) / 255
		a = hasAlpha ? Double(value & 0xff) / 255 : 1
	}

	public var hex: String {
		let channels = [r, g, b].map { UInt8(max(0, min(1, $0)) * 255) }
		let base = channels.map { String(format: "%02x", $0) }.joined()
		// The alpha is left off when it is opaque, because `#ffffff` is what
		// somebody would write and `#ffffffff` is what a program would.
		return a >= 1 ? "#\(base)" : "#\(base)" + String(format: "%02x", UInt8(a * 255))
	}
}
