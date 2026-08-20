import Foundation

/// A sound laid under the programme: music, an atmosphere, a sting.
///
/// Not a take. A take is a recording somebody cut into clips, and everything
/// about it — slugs, tags, an alignment offset, a measured loudness — is about
/// material that was shot. A music bed is a file with a level and a place on
/// the clock, and giving it a take file to live in would mean cutting a clip
/// out of it and pretending the clip was a shot.
///
/// When it plays is said in exactly the grammar an overlay uses, because it is
/// the same question: `from: @intro`, `from: intro to: demo`, `within:` a clip,
/// or plain times. That is deliberate — a second grammar for "when does this
/// happen" would be a second thing to learn and a second thing to get wrong,
/// and the whole point of binding to marks is that re-cutting a take moves the
/// music with it.
public struct Sound: Sendable, Equatable {

	/// The file, relative to the project — the same rule every path in a
	/// project follows, so a project and its music travel as one folder.
	public var file: String

	/// When it plays.
	///
	/// `nil` only for a sound written inside a timeline entry, where it means
	/// "for exactly as long as that entry is on" — the case a name cannot
	/// express, because `from: intro` finds every use of `intro`. A sound in
	/// the top-level list has no placement to take its length from, so it says
	/// when it plays or it is not read.
	public var span: Overlay.Span?

	/// Decibels, applied to the file as it is. Nought leaves it alone.
	public var gain: Double

	/// How it starts and how it stops. Only a fade means anything to a sound —
	/// it cannot slide in from the left — so anything else is a hard start.
	public var arrival: Overlay.Transition
	public var departure: Overlay.Transition

	/// How far the programme's own sound is pulled under this one, in decibels.
	/// Nought for not at all, which is what a sting under a cut wants and what
	/// music over somebody talking does not.
	public var ducks: Double

	public init(
		file: String,
		span: Overlay.Span?,
		gain: Double = 0,
		arrival: Overlay.Transition = .cut,
		departure: Overlay.Transition = .cut,
		ducks: Double = 0
	) {
		self.file = file
		self.span = span
		self.gain = gain
		self.arrival = arrival
		self.departure = departure
		self.ducks = ducks
	}

	/// How long it takes to arrive and to go, as the mix needs it: a fade's
	/// length, and nothing for anything else.
	public var fadeIn: Double {
		if case .fade(let over) = arrival { return max(0, over) }
		return 0
	}

	public var fadeOut: Double {
		if case .fade(let over) = departure { return max(0, over) }
		return 0
	}
}
