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
		/// Confetti, snow, sparks: the whole frame, for a moment.
		case effect(Effect)
		/// A scene the project defines: parts moved by keyframes, with the
		/// parameters this use of it fills in.
		case scene(String, with: [String: String])
		/// The picture itself, taken to film for a while: bars, a stock, grain.
		case film(Film)
		/// The lens giving up on one colour at a time.
		case aberration(Aberration)
		/// The picture played off a worn tape: tracking, noise, lines.
		case tape(Tape)
		/// Somebody saying something, in a drawn bubble with a tail that
		/// points at them.
		case bubble(Bubble)

		/// Whether this kind *is* the frame rather than something laid over it.
		///
		/// Film mode, the aberration and the tape all take a picture and hand
		/// back another picture, so where they come in the list matters to
		/// everything after them: an aberration written before a film overlay
		/// is a lens on the footage and leaves the bars clean, and the same one
		/// written after it bends the bars too. ``Frame`` draws them in the
		/// order the file lists them, and this is how it knows which ones those
		/// are.
		public var changesTheFrame: Bool {
			switch self {
			case .film, .aberration, .tape: return true
			case .text, .spinner, .effect, .scene, .bubble: return false
			}
		}
	}

	public var kind: Kind

	/// What to call one in a sentence somebody reads.
	public var described: String {
		switch kind {
		case .text(let text, _): return text.isEmpty ? "a caption" : "the caption “\(text)”"
		case .spinner: return "a spinner"
		case .scene(let name, _): return "the scene `\(name)`"
		case .effect(let effect): return "the \(effect.style.rawValue)"
		case .film: return "film mode"
		case .aberration: return "the aberration"
		case .tape: return "the tape"
		case .bubble(let bubble):
			return bubble.text.isEmpty ? "a bubble" : "the bubble \u{201C}\(bubble.text)\u{201D}"
		}
	}

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
		case .bubble(var bubble):
			// The same key a caption uses, meaning the same thing: one bubble
			// on three times, saying something different each time, rather than
			// three bubbles with the same paper, seed and anchor to keep in
			// step by hand.
			if let text = appearance.text { bubble.text = text }
			out.kind = .bubble(bubble)
		case .effect, .scene, .film, .aberration, .tape:
			// None of them says anything of its own at an appearance: an effect
			// is simply on twice, a scene says what its parameters say, and
			// the three that are the frame itself say nothing at all.
			break
		}
		return out
	}

	/// How it arrives and how it leaves.
	public var arrival: Transition
	public var departure: Transition

	/// Where the arrival sits against the overlay's first mark, and where the
	/// departure sits against its last.
	///
	/// Two fields beside the transitions rather than a case inside them, for two
	/// reasons. A sound has an arrival and a departure of the same type and no
	/// span to place them against, so a placement on ``Transition`` would be a
	/// value half its holders could not use. And every `case` of that enum is
	/// pattern-matched in a dozen places for what it *is*; adding a second
	/// associated value to all four to carry something none of them reads would
	/// touch every one of those and say nothing.
	public var arrivalPlacement: Transition.Placement = .after
	public var departurePlacement: Transition.Placement = .before

	/// The overlay's parameters, moving.
	///
	/// Empty for nearly every overlay, and an empty list is exactly what an
	/// overlay was before there were any: nothing is computed, nothing is
	/// rounded, and the file writes what it always wrote. See ``Overlay/Key``
	/// for what a key may state and ``Kind/animatable`` for what it may not.
	public var keys: [Key] = []

	/// What it goes behind.
	///
	/// `people` asks Vision, on this machine, for the shape of whoever is in the
	/// frame and puts the overlay behind them — a caption that goes round the
	/// back of the person talking, confetti that falls between her and the
	/// camera and behind her both. It costs a segmentation pass per frame, so it
	/// is asked for rather than assumed.
	public var behind: Occlusion

	public enum Occlusion: String, Sendable, CaseIterable {
		case nothing
		case people
	}

	/// Where it sits. An anchor overrides the style's position and makes the
	/// overlay follow whatever the anchor follows.
	///
	/// A bubble is the exception, and deliberately: there the anchor is what it
	/// *points at*. The bubble is placed where the anchor was when it came on
	/// and stays there, because words that move under the reader cannot be
	/// read; it is the tail that follows the face. See ``Bubble``.
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
		arrivalPlacement: Transition.Placement = .after,
		departurePlacement: Transition.Placement = .before,
		behind: Occlusion = .nothing,
		anchor: String? = nil,
		offset: CGPoint = .zero,
		keys: [Key] = []
	) {
		self.kind = kind
		self.appearances = appearances
		self.behind = behind
		self.arrival = arrival
		self.departure = departure
		self.arrivalPlacement = arrivalPlacement
		self.departurePlacement = departurePlacement
		self.anchor = anchor
		self.offset = offset
		self.keys = keys
	}

	/// The overlay most projects write: on over one range, saying one thing.
	public init(
		kind: Kind,
		span: Span,
		arrival: Transition = .slide(.left, over: 0.4),
		departure: Transition = .slide(.right, over: 0.4),
		arrivalPlacement: Transition.Placement = .after,
		departurePlacement: Transition.Placement = .before,
		behind: Occlusion = .nothing,
		anchor: String? = nil,
		offset: CGPoint = .zero,
		keys: [Key] = []
	) {
		self.init(kind: kind, appearances: [Appearance(span)], arrival: arrival,
		          departure: departure, arrivalPlacement: arrivalPlacement,
		          departurePlacement: departurePlacement, behind: behind, anchor: anchor,
		          offset: offset, keys: keys)
	}

	/// Several ranges, all saying the same thing.
	public init(
		kind: Kind,
		spans: [Span],
		arrival: Transition = .slide(.left, over: 0.4),
		departure: Transition = .slide(.right, over: 0.4),
		arrivalPlacement: Transition.Placement = .after,
		departurePlacement: Transition.Placement = .before,
		behind: Occlusion = .nothing,
		anchor: String? = nil,
		offset: CGPoint = .zero,
		keys: [Key] = []
	) {
		self.init(kind: kind, appearances: spans.map { Appearance($0) }, arrival: arrival,
		          departure: departure, arrivalPlacement: arrivalPlacement,
		          departurePlacement: departurePlacement, behind: behind, anchor: anchor,
		          offset: offset, keys: keys)
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
		/// A stretch of one clip or section, timed from where that starts.
		///
		/// The form to reach for when a caption belongs to the middle of a
		/// shot rather than to the whole of it. It is still bound to the
		/// material: move the clip up the programme, re-cut the take, put three
		/// more shots in front of it, and the caption is still four seconds
		/// into *that* clip. An absolute time is not — which is the flaw this
		/// case exists to fix.
		case within(Endpoint, from: Double, to: Double)
		/// Times on the programme's own clock. Kept because a file may say it
		/// and because now and then somebody means it; it does not survive
		/// anything moving.
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
	/// `over` is the length of the movement. Where that length *sits* is a
	/// separate question, and its answer is ``Overlay/arrivalPlacement`` and
	/// ``Overlay/departurePlacement``; by default the movement is taken from
	/// inside the span at each end, which is what it has always been.
	///
	/// So two overlays whose spans meet — one ending where the next begins —
	/// cross at the boundary: the first slides out to the right at the same
	/// moment the second slides in from the left, with no gap to arrange and
	/// nothing to keep in step by hand. That is the effect the whole clip-bound
	/// design exists to make automatic, and a placement moves where the crossing
	/// happens rather than whether it does. Both movements placed `across` the
	/// mark is the same crossing centred on it; the second one's arrival placed
	/// `before` puts the two on top of each other in the seconds *leading up*
	/// to the mark, which is a dissolve between two overlays rather than a
	/// hand-off at a line. Neither overlay's span moves, so the file still says
	/// which one belongs where.
	public enum Transition: Sendable, Equatable {
		case cut
		case fade(over: Double)
		case slide(Edge, over: Double)
		/// For an effect: stop letting pieces go, and let what is in the air
		/// leave the frame on its own. A shower of confetti that fades out is a
		/// shower somebody switched off; one that falls out is one that ran out.
		case fall(over: Double)

		public enum Edge: String, Sendable, CaseIterable {
			case left, right, up, down
		}

		/// Where a movement sits relative to the mark it is attached to.
		///
		/// Read against the **mark**, never against the overlay, which is what
		/// makes one set of three words do both ends:
		///
		/// - `before` — the movement has finished by the time the mark arrives.
		///   At the first mark that is an overlay already fully on for the
		///   clip's first frame; at the last it is one already gone.
		/// - `across` — the mark falls in the middle of the movement: half way
		///   on at the first frame, half way off at the last.
		/// - `after` — the movement begins at the mark.
		///
		/// **Why the two defaults are different words.** `over` has always been
		/// taken from *inside* the span: an overlay begins arriving at its first
		/// mark and has finished leaving by its last, so the whole of both
		/// movements happens between the marks somebody wrote and nothing at all
		/// is on screen outside them. Said in these words, that is `after` at
		/// the start and `before` at the end. It looks lopsided written down,
		/// and it is the one arrangement in which the span and the picture agree
		/// about when the overlay exists — which is why it is the default and
		/// why the asymmetry is worth a paragraph rather than a tidy-up.
		///
		/// The word that surprises people is `before`. At the first mark it puts
		/// the overlay on screen *early*; at the last mark it is what already
		/// happens and changes nothing. Same word, same meaning — the mark it is
		/// measured from is the thing that moved.
		public enum Placement: String, Sendable, CaseIterable {
			case before, across, after

			/// How much of the movement falls on the near side of the mark.
			var beforeTheMark: Double {
				switch self {
				case .before: return 1
				case .across: return 0.5
				case .after: return 0
				}
			}

			/// What to call one in the panel, where there is no mark drawn to
			/// point at.
			public var title: String {
				switch self {
				case .before: return "before the mark"
				case .across: return "across the mark"
				case .after: return "after the mark"
				}
			}
		}

		public var duration: Double {
			switch self {
			case .cut: return 0
			case .fade(let over): return over
			case .slide(_, let over): return over
			case .fall(let over): return over
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
		/// Tapered spokes round a circle, fading in turn. The oldest spinner
		/// there is, and the most legible over busy footage: the spokes reach
		/// the edge of the circle, so it reads at a smaller size than dots.
		case bars
		/// One dot travelling round a faint track. Quieter than the others —
		/// for a corner of the frame rather than over somebody's head.
		case orbit
		/// A circle breathing, going nowhere. For "hold on" rather than
		/// "working": nothing about it suggests progress round a loop.
		case pulse
		/// Three dots rising in turn, the way a terminal says it is thinking.
		case bounce
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

	/// The same lower third, centred across the frame. Wanted often enough to
	/// be worth not writing out: the only difference is where it sits and which
	/// part of it sits there.
	public static let lowerThirdCentred = TextStyle(
		position: CGPoint(x: 0.5, y: 0.13), alignment: .centre)

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

	// MARK: - Credits
	//
	// Three faces for an end plate, built in for the same reason the others are:
	// so that a project which wants a plain credit roll writes a `roll:` part
	// and nothing else at all. No plate and no padding behind any of them —
	// unlike a caption, whose plate is what makes it readable over a picture. A
	// roll lines its columns up on the plate's edges, so padding on the lines
	// would show as a gap the file never asked for.

	/// The names in a credit roll.
	public static let credit = TextStyle(
		font: "Helvetica Neue Medium", size: 0.040, color: .white,
		background: RGBA(r: 0, g: 0, b: 0, a: 0), padding: 0, cornerRadius: 0,
		alignment: .left)

	/// The roles beside them: smaller and quieter, because the name is the
	/// thing being said and the role is what it answers.
	public static let creditRole = TextStyle(
		font: "Helvetica Neue", size: 0.040, color: RGBA(r: 0.55, g: 0.60, b: 0.66),
		background: RGBA(r: 0, g: 0, b: 0, a: 0), padding: 0, cornerRadius: 0,
		alignment: .right)

	/// A line over the top of the column.
	public static let creditTitle = TextStyle(
		font: "Helvetica Neue Bold", size: 0.070, color: .white,
		background: RGBA(r: 0, g: 0, b: 0, a: 0), padding: 0, cornerRadius: 0,
		position: CGPoint(x: 0.5, y: 0.5), alignment: .centre)

	/// The names worth offering, in the spelling this program uses.
	///
	/// `builtIn` also answers to the American spellings, because a file that
	/// says `center` should work — but a menu that lists a style twice under
	/// two spellings is a menu that makes somebody wonder what the difference
	/// is. They are read, not offered.
	public static let offered = ["lower-third", "lower-third-centre", "centre", "title", "caption",
	                             "bubble", "credit", "credit-role", "credit-title"]

	/// Available without being written down, and overridable by writing one
	/// down: a project that redefines `lower-third` still gets the others.
	public static let builtIn: [String: TextStyle] = [
		"lower-third": .lowerThird,
		"lower-third-centre": .lowerThirdCentred,
		"lower-third-center": .lowerThirdCentred,
		"centre": .centred,
		"center": .centred,
		"title": .title,
		"caption": .caption,
		// Dark ink on nothing, because what is behind a bubble's words is the
		// bubble. A caption's white would be invisible on paper.
		"bubble": Bubble.textStyle,
		"credit": .credit,
		"credit-role": .creditRole,
		"credit-title": .creditTitle,
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

	/// Part of the way from one colour to another, straight through sRGB.
	///
	/// Not through a perceptual space, and that is deliberate: Core Animation
	/// interpolates `backgroundColor` component-wise in the layer's own space,
	/// and the export goes through Core Animation. A cleverer ramp here would
	/// be a preview that disagrees with the file it renders.
	///
	/// Either end missing means there is nothing to ramp between — the one that
	/// exists is the answer, which is what makes a colour stated at only one
	/// key hold from there on.
	public static func between(_ a: RGBA?, _ b: RGBA?, _ fraction: Double) -> RGBA? {
		guard let a, let b else { return b ?? a }
		func mix(_ x: Double, _ y: Double) -> Double { x + (y - x) * fraction }
		return RGBA(r: mix(a.r, b.r), g: mix(a.g, b.g), b: mix(a.b, b.b), a: mix(a.a, b.a))
	}

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
