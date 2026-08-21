import Foundation
import Testing
@testable import CuttrKit

/// Bringing the clips of one recording level with each other.
///
/// The take's own loudness is one figure for the whole recording, which is the
/// right grain for a take somebody speaks through at one level and useless for
/// one where two children take turns: matching the take to a target moves all
/// of it and leaves them as far apart as they were.
@Suite struct LevellingTests {

	/// Matched to the middle of what was heard, so most clips barely move and
	/// the ones that were out come to meet them.
	@Test func theQuietOneComesUpAndTheLoudOneComesDown() {
		// Three clips at -30, -24 and -18 LUFS. The middle is -24.
		let gains = Levelling.match([-30, -24, -18])
		#expect(gains == [6, 0, -6])
	}

	/// An even number of clips has no middle line, so it is the mean of the two
	/// either side of the gap — the same rule a median always has.
	@Test func anEvenNumberOfClipsSplitsTheDifference() {
		#expect(Levelling.match([-30, -26, -24, -20]) == [5, 1, -1, -5])
	}

	/// Matching to the loudest would turn every other clip up and bring the
	/// room up with it. The middle moves half as much in each direction.
	@Test func theLoudestDoesNotSetTheLevel() {
		let gains = Levelling.match([-30, -29, -28, -6])
		// The middle of those four is -28.5, so the three quiet ones barely
		// move — where matching to the loudest would have turned all three up
		// by more than twenty decibels and brought the room with them.
		#expect(gains[0] == 1.5)
		#expect(gains[1] == 0.5)
		#expect(gains[2] == -0.5)
		// And the shout wants -22.5, which is past the limit, so it comes down
		// as far as a trim is allowed to and no further. It is still the loudest
		// thing in the take afterwards, which is honest: it was a shout.
		#expect(gains[3] == -Levelling.limit)
	}

	/// A trim is a correction, not a rescue: past the limit what comes up is
	/// the room rather than the voice.
	@Test func aTrimIsBounded() {
		let gains = Levelling.match([-60, -20, -18], limit: 12)
		#expect(gains[0] == 12)
		#expect(Levelling.match([-60, -20, -18], limit: 6)[0] == 6)
	}

	/// A clip with nothing to measure keeps the trim it had. There is no level
	/// to match, and amplifying silence to meet a conversation is the one
	/// outcome nobody wants.
	@Test func silenceIsLeftWhereItWas() {
		let gains = Levelling.match([-30, nil, -18], existing: [0, 4, 0])
		#expect(gains[0] == 6)
		#expect(gains[1] == 4)
		#expect(gains[2] == -6)
	}

	/// Nothing measurable at all is nothing to say, and every trim stands.
	@Test func aSilentTakeIsLeftAlone() {
		#expect(Levelling.match([nil, nil], existing: [2, -3]) == [2, -3])
		#expect(Levelling.match([]) == [])
	}

	/// Rounded to a tenth of a decibel, which is what the take file writes: a
	/// value the file cannot hold exactly would come back different on the next
	/// read and leave the document looking edited when nothing had changed.
	@Test func trimsAreRoundedToWhatTheFileCanHold() {
		let gains = Levelling.match([-23.04, -20.61, -19.97])
		#expect(gains.allSatisfy { ($0 * 10).rounded() / 10 == $0 })
	}

	/// Matching a set that already agrees changes nothing, so pressing it twice
	/// is pressing it once.
	@Test func matchingWhatAlreadyAgreesChangesNothing() {
		#expect(Levelling.match([-23, -23, -23]) == [0, 0, 0])
	}
}
