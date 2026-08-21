import AppKit
import CuttrKit

/// The palette and the metrics, in one place.
///
/// Fixed and dark rather than following the system appearance. A waveform is
/// judged by eye — is that a breath or the start of the word — and the same
/// grey has to mean the same amplitude in every session. A light mode would
/// need a second set of contrasts tuned against a white ground, and nobody
/// grades audio on white.
public enum Theme {
	/// Three grounds, and the rule is **the further in, the lighter**.
	///
	/// `background` is the chrome: the bar across the top and the rail down the
	/// side, which together are one L of furniture saying where you are and what
	/// you are doing. `panel` is everything that L frames. `card` is a surface
	/// somebody reads or types into inside that — the properties form, the
	/// project file — and it is lighter again.
	///
	/// Stated because it was arrived at twice by being wrong. The bar was
	/// `panel`, which is what the content it sits above is, so there was no edge
	/// between them at all; moving the bar to `background` then put it at the
	/// same value as the code editor, which was also `background`, and moved the
	/// missing edge one page over. Three regions cannot be told apart by two
	/// colours, and which of them is which is not a matter of taste — it is how
	/// far in they are.
	public static let background = NSColor(calibratedWhite: 0.10, alpha: 1)
	public static let panel = NSColor(calibratedWhite: 0.14, alpha: 1)
	public static let rule = NSColor(calibratedWhite: 0.24, alpha: 1)
	public static let text = NSColor(calibratedWhite: 0.88, alpha: 1)
	public static let dimText = NSColor(calibratedWhite: 0.55, alpha: 1)

	/// `[laughter]` in the transcript: something that was heard and not said.
	///
	/// Its own hue rather than a weight of the text's, because it is not a
	/// quieter kind of word — it is a different claim about the recording, and
	/// a reader skimming for the laugh should find it without reading.
	///
	/// A fixed assignment, not a palette slot: it means this and nothing else,
	/// anywhere in the program.
	public static let heardNotSaid = NSColor(calibratedRed: 0.45, green: 0.78, blue: 0.58, alpha: 1)

	/// The camera's own audio, and the separate recorder's. Two hues, because
	/// the whole alignment task is telling one from the other at a glance.
	public static let cameraWave = NSColor(calibratedRed: 0.42, green: 0.62, blue: 0.85, alpha: 1)
	public static let externalWave = NSColor(calibratedRed: 0.95, green: 0.72, blue: 0.32, alpha: 1)

	/// The palette: six hues that can be told apart, and **nothing more**.
	///
	/// This is the rule the whole scheme rests on, and it is written here because
	/// it was arrived at twice from two directions.
	///
	/// `base(_:)` is a set of *labels*. It does not mean six things. Whoever
	/// hands one out says what it means, and there are two who do: somebody
	/// cutting a take assigns them to lanes — "these four are the alternates" —
	/// and the transcript assigns them to whoever is speaking. In both cases the
	/// person chose, the choice is arbitrary, and the hue is never the only
	/// marker: a clip carries its slug and a line of speech begins with the
	/// speaker's name in a fixed-width column.
	///
	/// ``color(_:)`` is the one place the *program* fixes an assignment, and
	/// there the rule is tighter: within that set a hue means exactly one kind
	/// of thing, everywhere it appears — in the library, on the programme, on a
	/// badge, in the properties, in the project file. That is how somebody
	/// learns what `#` and `@` mean without being told. A second meaning for one
	/// of those hues spends the only signal that carries information.
	///
	/// And selection is not a hue at all — see ``accent``. It is a state a thing
	/// is in rather than a kind of thing, so it is said in value.
	///
	/// The hues are chosen to stay apart from each other *and* from the two
	/// waveform hues, because a clip bar sits directly above a camera lane drawn
	/// in blue and a recorder lane drawn in amber. The clip blue is darker and
	/// the clip amber redder than the waveforms they sit over, which is what
	/// keeps a coloured region from reading as part of the audio underneath it.
	public static func base(_ color: ClipColor) -> NSColor {
		switch color {
		case .green:  return NSColor(calibratedRed: 0.36, green: 0.82, blue: 0.60, alpha: 1)
		case .blue:   return NSColor(calibratedRed: 0.36, green: 0.58, blue: 0.95, alpha: 1)
		case .amber:  return NSColor(calibratedRed: 0.95, green: 0.62, blue: 0.25, alpha: 1)
		case .violet: return NSColor(calibratedRed: 0.68, green: 0.52, blue: 0.95, alpha: 1)
		case .rose:   return NSColor(calibratedRed: 0.95, green: 0.42, blue: 0.55, alpha: 1)
		case .teal:   return NSColor(calibratedRed: 0.30, green: 0.78, blue: 0.80, alpha: 1)
		}
	}

	/// The bar's outline, its ground, its stripe, and the wash over the lanes.
	///
	/// **The colour is a stripe on the block, not the block.** Six saturated hues
	/// filled solid, in a band sitting directly on two waveform lanes that are
	/// themselves blue and amber, made the loudest thing on a cutting screen a
	/// decision somebody once made about filing. The block is the panel's own
	/// grey, lifted when it is selected; the colour is a bar down its leading
	/// edge, in line with the tick at the head of the lane, so a row of them
	/// reads as one lane rather than as forty coloured rectangles.
	///
	/// The wash across the waveform keeps the colour and stays faint on purpose:
	/// several of them overlap, and each has to stay readable through the others
	/// — two stacked regions at 0.30 would be a solid block.
	public static func clipStroke(_ color: ClipColor) -> NSColor { base(color) }
	public static func clipStripe(_ color: ClipColor) -> NSColor {
		base(color).withAlphaComponent(0.95)
	}
	public static func clipBlock(_ selected: Bool) -> NSColor {
		selected ? cardHigh : card
	}
	public static func clipWash(_ color: ClipColor, selected: Bool) -> NSColor {
		base(color).withAlphaComponent(selected ? 0.20 : 0.10)
	}

	// MARK: - Who is speaking

	/// A speaker's name at the head of their line. The palette's own hue, full
	/// strength, because it is three or four characters and has to be found at
	/// a glance down the left edge of a page of text.
	///
	/// Out of ``base(_:)`` — the palette — for the reason written there: a
	/// speaker is somebody's own filing of a take, exactly as a clip's lane is,
	/// and the hue is a label rather than a meaning. Which is also why it is
	/// safe for one hue to be a lane in one window and a voice in another: in
	/// neither is it the only marker.
	public static func speakerLabel(_ color: ClipColor) -> NSColor { base(color) }

	/// The words themselves, in the speaker's hue but lifted towards the
	/// panel's ordinary text colour.
	///
	/// A page of full-strength amber on a dark grey is a page nobody reads for
	/// five minutes. Two thirds of the way to ``text`` keeps the hue plainly
	/// there while the contrast stays close to what the rest of the pane has —
	/// and the hue is never carrying the identity on its own anyway, because
	/// the name is written at the head of every line.
	public static func speakerText(_ color: ClipColor) -> NSColor {
		guard let hue = base(color).usingColorSpace(.deviceRGB) else { return text }
		let lift = 0.62
		return NSColor(
			deviceRed: hue.redComponent + (0.88 - hue.redComponent) * lift,
			green: hue.greenComponent + (0.88 - hue.greenComponent) * lift,
			blue: hue.blueComponent + (0.88 - hue.blueComponent) * lift,
			alpha: 1)
	}

	/// A name a model proposed and nobody has confirmed.
	///
	/// Dim, and the words it is about are left in the ordinary text colour. A
	/// colour that is wrong a third of the time is worse than no colour,
	/// because somebody stops believing the ones that are right — so a guess
	/// gets a name in brackets and does not get to paint the page.
	public static func suggestedLabel(_ color: ClipColor) -> NSColor {
		base(color).withAlphaComponent(0.55)
	}

	/// The uncommitted in/out span, before it becomes a clip.
	///
	/// The accent, not amber. It was the fifth thing amber meant on one screen —
	/// the separate recording's waveform, a clip filed on the amber lane, a
	/// `#tag`, film mode, and this — and amber in the cutting window has one job:
	/// it is the recorder. A span somebody has just marked and not yet committed
	/// is not a *kind* of thing at all, it is the thing being done, and that is
	/// what the accent is for.
	public static let pendingFill = accent.withAlphaComponent(0.16)
	public static let pendingStroke = accent.withAlphaComponent(0.85)

	public static let playhead = NSColor(calibratedRed: 0.95, green: 0.30, blue: 0.35, alpha: 1)

	/// A surface somebody reads or types into: the paper, one step in from the
	/// panel — and a rule that separates without drawing a line anybody notices.
	public static let card = NSColor(calibratedWhite: 0.17, alpha: 1)
	public static let cardHigh = NSColor(calibratedWhite: 0.21, alpha: 1)
	public static let faintText = NSColor(calibratedWhite: 0.40, alpha: 1)

	/// Selection, and the thing being done. Almost without hue, on purpose.
	///
	/// It was `#4D8FF2` — within a few degrees of the camera waveform's
	/// `#6B9ED9`. Two blues on one screen doing two entirely different jobs: one
	/// saying "this is the camera's audio", the other saying "this is the row you
	/// clicked". Measured side by side they are indistinguishable at a glance,
	/// which is the definition of a colour that is not carrying information.
	///
	/// The rule this settles is that **hue says what kind of thing something
	/// is**, program-wide — and there was no hue left to move the accent to.
	/// Green is a clip, amber is the separate recording, teal is a list, violet
	/// is a section, rose is a spinner, blue is a scene and the camera. Selection
	/// is not a kind of thing; it is a state one is in. So it is said in *value*
	/// — a light, barely-cool steel that nothing in this program is drawn in —
	/// and the hues are left to mean what they mean.
	public static let accent = NSColor(calibratedRed: 0.80, green: 0.84, blue: 0.90, alpha: 1)

	/// What a selected row sits on: the panel, lifted. Never a bar of colour.
	public static let selected = NSColor(calibratedWhite: 0.26, alpha: 1)

	/// One hue per kind of thing a project names, used everywhere that kind
	/// appears — in the library, on the programme, on its badge, in the
	/// properties. Colour is how somebody learns what `#` and `@` mean without
	/// being told.
	public enum Kind {
		case clip, query, list, section, card, sound, text, spinner, effect, scene,
		     film, aberration, tape, bubble, frames,
		     anchor, tag, take
	}

	public static func color(_ kind: Kind) -> NSColor {
		switch kind {
		case .clip, .take: return base(.green)
		case .query, .tag: return base(.amber)
		case .list: return base(.teal)
		case .section: return base(.violet)
		case .text: return NSColor(calibratedWhite: 0.85, alpha: 1)
		case .spinner: return base(.rose)
		case .effect: return base(.violet)
		case .film: return base(.amber)
		case .aberration: return base(.rose)
		case .tape: return base(.teal)
		// Paper, near enough: a bubble is the one overlay that is a drawn thing
		// on the picture rather than a treatment of it.
		case .bubble: return base(.amber)
		// The same blue a scene gets, because from the row's point of view they
		// are the same thing: a picture laid over the cut. What differs is where
		// the picture was drawn, and the symbol says that.
		case .frames, .scene: return base(.blue)
		case .anchor: return base(.teal)
		// A card is the absence of footage, and neutral grey is what that
		// looks like beside six hues that all mean "something was shot".
		case .card: return NSColor(calibratedWhite: 0.62, alpha: 1)
		// The recorder's own amber, because a sound laid under the programme is
		// the same kind of thing as the lane it would have been recorded on.
		case .sound: return externalWave
		}
	}

	/// The picture that goes with the hue.
	///
	/// A symbol and a colour together are what makes a list of forty names
	/// scannable: the eye finds the scissors before it reads the slug. Drawn
	/// from the system set so they are the symbols somebody already knows from
	/// everything else on the machine.
	public static func symbol(_ kind: Kind, size: CGFloat = 12,
	                          colour: NSColor? = nil) -> NSImage? {
		let name: String
		switch kind {
		// A span with a mark at each end, which is what a clip is: two marks on
		// a take's clock. Scissors were the act of cutting rather than the
		// thing cut, and the thing cut is what a list of them holds.
		case .clip: name = "timeline.selection"
		case .take: name = "film"
		case .tag, .query: name = "tag"
		case .list: name = "list.bullet"
		case .section: name = "folder"
		case .text: name = "textformat"
		case .spinner: name = "circle.dotted"
		case .effect: name = "sparkles"
		case .film: name = "camera.filters"
		case .aberration: name = "circle.hexagongrid"
		case .tape: name = "recordingtape"
		case .bubble: name = "bubble.left"
		case .scene: name = "rectangle.stack"
		// Sprocket holes: a folder of numbered pictures, which is what a strip
		// of film is.
		case .frames: name = "film.stack"
		case .anchor: name = "scope"
		case .card: name = "rectangle.fill"
		case .sound: name = "waveform"
		}
		guard let image = NSImage(systemSymbolName: name, accessibilityDescription: name) else {
			return nil
		}
		let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
			.applying(NSImage.SymbolConfiguration(paletteColors: [colour ?? color(kind)]))
		return image.withSymbolConfiguration(configuration)
	}

	/// Where a picture of this size sits inside a slot: its own shape, its own
	/// size, in the middle of the room it is given.
	///
	/// Every symbol in this program was being drawn into a rectangle somebody
	/// picked by eye — 17 by 16, 13 by 12 — and a symbol is not those
	/// proportions. A folder came out wider than it is, and a chevron came out
	/// squashed.
	///
	/// Never enlarged, either, and that is the second half of the same
	/// mistake. `chevron.right` is tall and narrow where `chevron.down` is wide
	/// and short, so filling one slot with each made the closed one half again
	/// the size of the open one — two states of one control at two different
	/// sizes. A symbol already has a size: it was asked for at a point size,
	/// and that is the size it should be. The slot only says where.
	public static func fit(_ size: NSSize, in slot: NSRect) -> NSRect {
		guard size.width > 0, size.height > 0 else { return slot }
		let scale = min(1, min(slot.width / size.width, slot.height / size.height))
		let fitted = NSSize(width: size.width * scale, height: size.height * scale)
		return NSRect(x: slot.midX - fitted.width / 2, y: slot.midY - fitted.height / 2,
		              width: fitted.width, height: fitted.height)
	}

	/// Draws a picture in the middle of a slot, its own shape.
	public static func draw(_ image: NSImage, in slot: NSRect) {
		image.draw(in: fit(image.size, in: slot))
	}

	public static let mono = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
	public static let monoSmall = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
	/// A true fixed-width face, for text that is the *material* rather than the
	/// interface: what somebody said, laid out so it reads as a document and
	/// not as another label in a panel.
	public static let transcript = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
	public static let label = NSFont.systemFont(ofSize: 11, weight: .medium)
	public static let heading = NSFont.systemFont(ofSize: 10, weight: .semibold)
	public static let body = NSFont.systemFont(ofSize: 12, weight: .regular)
	public static let bodyStrong = NSFont.systemFont(ofSize: 12, weight: .medium)
}
