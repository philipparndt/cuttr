import Foundation

/// When one appearance of an overlay is on screen, and how far in or out it is
/// at a moment.
///
/// **This is the one place that answers both questions.** There are four paths
/// that have to agree about them — the layer tree the export builds, the same
/// tree built for the preview, the frame path that draws film mode, the tape,
/// the aberration and the effects, and the painter that draws a caption going
/// behind somebody — and until now they agreed by having the same four lines of
/// arithmetic copied into each of them. Four copies were survivable while there
/// was only one question to get right. There are two now:
///
/// - **When is it drawn?** ``drawnFrom`` to ``drawnUntil``.
/// - **When is it fully on?** ``arriveTo`` to ``departFrom``.
///
/// They were the same pair of numbers for every project ever written, because a
/// movement was always taken from inside the span. A movement placed before the
/// first mark makes them different: the overlay is on screen before its span
/// begins. A copy of the arithmetic that knew about the fade and not about the
/// drawn window would fade an overlay up from nothing across frames on which it
/// was not drawn at all — a caption that pops on at full strength, which is the
/// exact class of bug the brackets in ``OverlayLayers`` were added to kill.
///
/// **The span is not the drawn window, and never grows.** ``start`` and ``end``
/// are what the file says: what the timeline draws, what a `keys:` entry's `t`
/// is measured from, what a spinner's words are shared over. Widening those to
/// take in the pre-roll would make `from: intro to: demo` mean something other
/// than it says, and would move every key in the overlay the moment somebody
/// touched `in:`. So the span stays where it is written and the drawing reaches
/// outside it.
struct OverlayTiming {

	/// The span, as the file says it.
	let start: Double
	let end: Double

	/// The arrival, on the programme's clock: from the first moment anything is
	/// drawn to the moment it is fully on.
	let arriveFrom: Double
	let arriveTo: Double
	/// The departure: from the moment it starts leaving to the last moment
	/// anything is drawn.
	let departFrom: Double
	let departTo: Double

	let arrival: Overlay.Transition
	let departure: Overlay.Transition

	init(
		span start: Double, to end: Double,
		arrival: Overlay.Transition, arrivalAt: Overlay.Transition.Placement,
		departure: Overlay.Transition, departureAt: Overlay.Transition.Placement
	) {
		self.start = start
		self.end = end
		self.arrival = arrival
		self.departure = departure
		let span = max(end - start, 0.0001)
		// How much of each movement lands inside the span, which is the only
		// part that has to be paid for out of it.
		let arrive = Self.length(arrival.duration,
		                         inside: 1 - arrivalAt.beforeTheMark, span: span)
		let depart = Self.length(departure.duration,
		                         inside: departureAt.beforeTheMark, span: span)
		arriveFrom = start - arrive * arrivalAt.beforeTheMark
		arriveTo = arriveFrom + arrive
		departTo = end + depart * (1 - departureAt.beforeTheMark)
		departFrom = departTo - depart
	}

	/// How long a movement may actually be.
	///
	/// The rule the copies all had was "no longer than half the span", which is
	/// what keeps the arrival and the departure of a short overlay from crossing
	/// in the middle of it. Placement makes that rule too strong: a movement
	/// placed before the first mark takes none of the span and so has nothing to
	/// collide with. The rule is therefore about the part that *lands inside* —
	/// that part may not take more than half the span — and where all of it
	/// lands inside, which is every file written before this existed, it comes
	/// out at the number it always was.
	private static func length(_ asked: Double, inside: Double, span: Double) -> Double {
		let asked = max(0, asked)
		guard inside > 0 else { return asked }
		return min(asked, span / 2 / inside)
	}

	/// The first and last moment anything of this overlay is on the screen.
	///
	/// The span widened by whatever part of a movement was placed outside it —
	/// and exactly the span where nothing is placed outside, which is what keeps
	/// the default path the path it was.
	var drawnFrom: Double { min(start, arriveFrom) }
	var drawnUntil: Double { max(end, departTo) }
	var drawnSpan: Double { max(drawnUntil - drawnFrom, 0.0001) }

	func drawn(at time: Double) -> Bool { time >= drawnFrom && time <= drawnUntil }

	/// Where a moment sits in the drawn window, nought to one — which is what a
	/// keyframe animation hung over that window wants for its `keyTimes`.
	func fraction(at time: Double) -> Double {
		min(1, max(0, (time - drawnFrom) / drawnSpan))
	}

	/// How far through the arrival: nought before it starts, one once it is
	/// fully on.
	///
	/// A movement of no length — a cut — is nought before its instant and one
	/// from that instant on, which is what a cut is.
	func arriving(at time: Double) -> Double {
		guard arriveTo > arriveFrom else { return time >= arriveTo ? 1 : 0 }
		return min(1, max(0, (time - arriveFrom) / (arriveTo - arriveFrom)))
	}

	/// How far through the departure: nought while it is still fully on, one
	/// when it has gone.
	func departing(at time: Double) -> Double {
		guard departTo > departFrom else { return time >= departTo ? 1 : 0 }
		return min(1, max(0, (time - departFrom) / (departTo - departFrom)))
	}

	/// Only a fade fades. A slide is shown at full strength and moved, a cut
	/// simply appears, and a fall is a cloud that has stopped being fed.
	var arrivesByFading: Bool {
		if case .fade = arrival { return true }
		return false
	}

	var departsByFading: Bool {
		if case .fade = departure { return true }
		return false
	}

	/// The envelope: one in the middle, and a ramp at whichever end fades.
	///
	/// For film mode, the aberration and the tape this is not an opacity but how
	/// far into the thing the programme is — the bars close, the fringes spread,
	/// the tracking gives way — which is why it is one number and not a colour.
	func envelope(at time: Double) -> Double {
		var value = 1.0
		if arrivesByFading { value = min(value, arriving(at: time)) }
		if departsByFading { value = min(value, 1 - departing(at: time)) }
		return max(0, min(1, value))
	}

	/// When an effect stops letting pieces go, measured from ``drawnFrom``.
	///
	/// `nil` for a departure that is not a fall, which is every other kind:
	/// those take the cloud away rather than letting it run out.
	///
	/// Measured from the first drawn frame because that is the clock the cloud
	/// is simulated on — ``Frame`` says why a simulation cannot start at the mark
	/// when the drawing starts before it. And measured with the length the file
	/// asked for rather than the clamped one: a fall has no opacity envelope for
	/// the clamp to protect, and clamping it would change what
	/// `out: {fall: true, over: 5}` on a two-second effect has always meant,
	/// which is "let nothing go, and show me the shower running out".
	var spawningUntil: Double? {
		guard case .fall(let over) = departure else { return nil }
		return max(0, (departTo - over) - drawnFrom)
	}
}

extension ResolvedOverlay {

	/// When this appearance is drawn, when it is fully on, and how far in or out
	/// it is at a moment.
	var timing: OverlayTiming {
		OverlayTiming(span: start, to: end,
		              arrival: overlay.arrival, arrivalAt: overlay.arrivalPlacement,
		              departure: overlay.departure, departureAt: overlay.departurePlacement)
	}
}
