import Foundation
import Testing
@testable import CuttrKit

/// A take is a file somebody writes in, and saving it has to keep what they
/// wrote. See ``FileComments`` for where the prose is held and how it is
/// addressed.
@Suite struct TakeCommentTests {

	/// A take as somebody would annotate one: a block at the top, a note above
	/// a clip, a word at the end of a line.
	private let annotated = """
	# take 01 — the driver install, shot twice.
	#
	# The first pass is unusable: the phone rang. Kept anyway, because the
	# second one has the better explanation in the middle of it and the two
	# will be cut together.
	cuttr: 1

	video: media/take-01.mov

	clips:
	  # The good one. Starts on the word, not on the breath before it.
	  - slug:  intro
	    name:  Intro
	    start: 00:01.500
	    end:   00:12.300

	  # The phone rings at about nine seconds — cut before it.
	  - slug:  demo-install
	    name:  Installing the driver
	    start: 00:14.020   # trimmed by hand
	    end:   00:63.880
	"""

	private func commentLines(_ text: String) -> [String] {
		text.components(separatedBy: "\n")
			.map { $0.trimmingCharacters(in: .whitespaces) }
			.filter { $0.hasPrefix("#") }
	}

	@Test func savingAnAnnotatedTakeKeepsWhatWasWrittenInIt() throws {
		let written = TakeWriter.write(try TakeReader.read(annotated))
		#expect(commentLines(annotated).count == 7)
		// Every one of them, in the same order, and nothing added: the clip
		// length comments the emitter writes itself are its own and are not
		// counted as prose.
		#expect(commentLines(written).filter { !$0.hasPrefix("# 00:") }
			== commentLines(annotated))

		let lines = written.components(separatedBy: "\n")
		func line(after comment: String) -> String {
			guard let index = lines.firstIndex(where: { $0.contains(comment) }) else { return "" }
			return lines[(index + 1)...].first {
				!$0.trimmingCharacters(in: .whitespaces).hasPrefix("#")
			} ?? ""
		}
		#expect(line(after: "The good one").contains("slug:  intro"))
		#expect(line(after: "The phone rings").contains("slug:  demo-install"))
		// The one at the end of a line stayed on that line.
		#expect(lines.contains { $0.contains("start: 00:14.020") && $0.contains("# trimmed by hand") })
	}

	@Test func writingAnAnnotatedTakeTwiceIsStable() throws {
		// The house rule, with prose in the file: the second save is the same
		// bytes as the first, and the take's own comments are not doubled.
		let once = TakeWriter.write(try TakeReader.read(annotated))
		let twice = TakeWriter.write(try TakeReader.read(once))
		#expect(once == twice)
		#expect(!twice.contains("# 00:10.800   # 00:10.800"))
	}

	@Test func theEmittersOwnCommentsAreNotDoubledOrLost() throws {
		// A take with everything the emitter comments on itself: the offset's
		// direction, the measured numbers, the clip lengths, and the block that
		// says where clips go when there are none.
		var take = Take(video: "a.mov", audio: AudioTrack(file: "b.wav", offset: 1.25))
		take.measured = Measured(loudness: -18.2, peak: -1.4)
		let empty = TakeWriter.write(take)
		#expect(empty.contains("# audio + offset = video clock"))
		#expect(TakeWriter.write(try TakeReader.read(empty)) == empty)

		take.clips = [Clip(slug: "intro", name: "Intro", start: 1.5, end: 12.3)]
		let full = TakeWriter.write(take)
		#expect(full.contains("   # 00:10.800"))
		#expect(TakeWriter.write(try TakeReader.read(full)) == full)
	}

	@Test func aNoteOnADeletedClipDoesNotMoveToAnother() throws {
		var take = try TakeReader.read(annotated)
		take.clips.removeFirst()
		let written = TakeWriter.write(take)
		#expect(!written.contains("The good one"))
		// And the surviving note is still on the clip it was about, rather than
		// having been shuffled up into the gap the other one left.
		let lines = written.components(separatedBy: "\n")
		let index = lines.firstIndex { $0.contains("The phone rings") } ?? 0
		#expect(lines[index + 1].contains("slug:  demo-install"))
	}

	@Test func aNoteStaysWithItsClipWhenTheClipsAreReordered() throws {
		var take = try TakeReader.read(annotated)
		take.clips.reverse()
		let lines = TakeWriter.write(take).components(separatedBy: "\n")
		guard let good = lines.firstIndex(where: { $0.contains("The good one") }),
		      let rings = lines.firstIndex(where: { $0.contains("The phone rings") })
		else { Issue.record("both notes should be written"); return }
		// A clip is addressed by its slug, not by its place in the list, so the
		// notes swapped over with the clips instead of staying put and becoming
		// wrong.
		#expect(rings < good)
		#expect(lines[good + 1].contains("slug:  intro"))
		#expect(lines[rings + 1].contains("slug:  demo-install"))
	}

	@Test func renamingAClipKeepsTheNoteAboveIt() throws {
		// The slug is the reference, so the address holds: renaming the clip is
		// exactly the case where a note must not be dropped.
		var take = try TakeReader.read(annotated)
		take.clips[0].name = "The opening, second attempt"
		let written = TakeWriter.write(take)
		#expect(written.contains("The good one"))
	}

	@Test func aTakeWithNoCommentsIsWrittenExactlyAsBefore() throws {
		// Nothing to put back, so nothing is touched: the file a take with no
		// prose in it produces is the file it always produced.
		let take = Take(video: "a.mov",
		                clips: [Clip(slug: "intro", name: "Intro", start: 0, end: 2)])
		#expect(take.comments.isEmpty)
		let written = TakeWriter.write(take)
		#expect(TakeWriter.write(try TakeReader.read(written)) == written)
		#expect(commentLines(written).count == 1)
	}
}

/// The addressing itself, which is the part that decides whether a comment
/// comes back on the right key.
@Suite struct FileCommentTests {

	private func addresses(_ text: String) -> [String] {
		FileScan.addresses(of: text.components(separatedBy: "\n")).map { $0 ?? "" }
	}

	@Test func aKeyIsAddressedByItsPath() {
		#expect(addresses("""
		output:
		  size: 1920x1080
		  fps:  25
		""") == ["output", "output/size", "output/fps"])
	}

	@Test func anItemIsAddressedByWhatItSaysRatherThanWhereItIs() {
		let found = addresses("""
		timeline:
		  - clip:  intro
		    trim:  [0, 1]
		  - clip:  outro
		""")
		#expect(found == [
			"timeline",
			"timeline/clip: intro/clip",
			"timeline/clip: intro/trim",
			"timeline/clip: outro/clip",
		])
	}

	@Test func twoItemsThatReadTheSameAreStillTwoAddresses() {
		// The one case where an address falls back to counting: two blocks of
		// `names:` in a credit roll are told apart by nothing else.
		let found = addresses("""
		roll:
		  - names: [a]
		  - names: [b]
		""")
		#expect(found == ["roll", "roll/names: [a]/names", "roll/names: [b]/names"])

		let same = addresses("""
		roll:
		  - names:
		  - names:
		""")
		#expect(same == ["roll", "roll/names:/names", "roll/names:#2/names"])
	}

	@Test func aHashInsideAValueIsNotAComment() {
		// A colour is not prose. Reading one as a comment would cut the value
		// off the line and lose it.
		let scan = FileScan("""
		styles:
		  title:
		    color:    "#4bd5ee"
		    palette:  ["#000000", "#ffffff"]   # the two ends
		""")
		#expect(scan.comments.trailing["styles/title/color"] == nil)
		#expect(scan.comments.trailing["styles/title/palette"] == "   # the two ends")
	}

	@Test func aBlockAtTheTopBelongsToTheFileAndOneAtTheBottomToNothing() {
		let scan = FileScan("""
		# what this is
		cuttr: 1

		video: a.mov

		# an afterthought
		""")
		#expect(scan.comments.header == ["# what this is"])
		#expect(scan.comments.footer == ["", "# an afterthought"])
		#expect(scan.comments.above.isEmpty)
	}

	@Test func theOrderTheBlocksWereWrittenInIsRead() {
		let scan = FileScan("""
		styles:
		  zebra:
		    size: 0.04
		  antelope:
		    size: 0.05
		""")
		#expect(scan.order["styles"] == ["zebra", "antelope"])
	}
}
