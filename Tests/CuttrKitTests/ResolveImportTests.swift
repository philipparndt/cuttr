import Foundation
import Testing
@testable import CuttrKit

@Suite struct ResolveImportTests {

	// A Resolve EDL: subclips dropped on a timeline and exported as CMX 3600.
	// The audio events are there because Resolve writes them, and they are the
	// same cuts again — importing both would double every clip.
	private let edl = """
	TITLE: Take 01
	FCM: NON-DROP FRAME

	001  AX       V     C        01:00:05:00 01:00:12:10 00:00:00:00 00:00:07:10
	* FROM CLIP NAME: Intro
	001  AX       A     C        01:00:05:00 01:00:12:10 00:00:00:00 00:00:07:10
	002  AX       V     C        01:00:14:00 01:01:03:22 00:00:07:10 00:00:57:07
	* FROM CLIP NAME: Installing the driver
	* SOURCE FILE: take-01.MOV
	"""

	@Test func readsAnEDLAtTheTakesFrameRate() throws {
		let clips = try ResolveImport.read(edl, framesPerSecond: 25)
		#expect(clips.count == 2)
		#expect(clips[0].name == "Intro")
		#expect(abs(clips[0].start - 3605.0) < 0.001)
		#expect(abs(clips[0].end - 3612.4) < 0.001)
		#expect(clips[1].name == "Installing the driver")
		#expect(abs(clips[1].start - 3614.0) < 0.001)
	}

	@Test func dropFrameIsCountedRatherThanIgnored() {
		// 00:01:00;02 is the first frame label after the two that are skipped
		// at the top of the minute, and it is frame 1800.
		let seconds = ResolveImport.parseTimecode("00:01:00;02", fps: 29.97)
		#expect(abs((seconds ?? 0) - 1800 / 29.97) < 0.001)
		// An hour of drop-frame is an hour of wall clock, to within a frame —
		// which is the entire reason drop-frame exists.
		let hour = ResolveImport.parseTimecode("01:00:00;00", fps: 29.97)
		#expect(abs((hour ?? 0) - 3600) < 0.05)
	}

	@Test func nonDropIsNot() {
		#expect(ResolveImport.parseTimecode("01:00:00:00", fps: 25) == 3600)
		#expect(ResolveImport.parseTimecode("00:00:01:12", fps: 24) == 1.5)
	}

	@Test func readsFCPXML() throws {
		let xml = """
		<?xml version="1.0" encoding="UTF-8"?>
		<fcpxml version="1.8">
		  <resources><asset id="r2" name="take-01"/></resources>
		  <library><event><project><sequence><spine>
		    <asset-clip name="Intro" ref="r2" offset="0s" start="3600s" duration="10s"/>
		    <asset-clip name="Demo" ref="r2" offset="10s" start="1001/30000s" duration="1001/300s"/>
		  </spine></sequence></project></event></library>
		</fcpxml>
		"""
		let clips = try ResolveImport.read(xml, framesPerSecond: 25)
		#expect(clips.count == 2)
		#expect(clips[0] == ImportedClip(name: "Intro", start: 3600, end: 3610))
		#expect(clips[1].name == "Demo")
		#expect(abs(clips[1].end - clips[1].start - 1001.0 / 300) < 1e-9)
	}

	@Test func readsFinalCutPro7XML() throws {
		let xml = """
		<?xml version="1.0" encoding="UTF-8"?>
		<xmeml version="4"><sequence><media><video><track>
		  <clipitem id="c1">
		    <name>Intro</name>
		    <rate><timebase>25</timebase></rate>
		    <in>125</in><out>375</out>
		    <file id="f1"><name>take-01.mov</name></file>
		  </clipitem>
		</track></video></media></sequence></xmeml>
		"""
		let clips = try ResolveImport.read(xml, framesPerSecond: 25)
		#expect(clips.count == 1)
		// The clip's own name, not the camera file's — which is the same for
		// every clip in the timeline and would make the import useless.
		#expect(clips[0] == ImportedClip(name: "Intro", start: 5, end: 15))
	}

	@Test func recognisesEachFormat() {
		#expect(ResolveImport.detect(edl) != nil)
		#expect(ResolveImport.detect("<?xml version=\"1.0\"?><fcpxml version=\"1.9\">") != nil)
		#expect(ResolveImport.detect("<?xml version=\"1.0\"?><xmeml version=\"4\">") != nil)
		#expect(ResolveImport.detect("cuttr: 1\nvideo: a.mov\n") == nil)
	}

	@Test func cameraTimecodeIsShiftedOntoTheTakesClock() throws {
		let clips = try ResolveImport.read(edl, framesPerSecond: 25)
		let (moved, shift) = ResolveImport.rebase(clips, against: 600)
		#expect(abs(shift + 3605) < 0.001)
		#expect(abs(moved[0].start) < 0.001)
		#expect(abs(moved[1].start - 9) < 0.001)
	}

	@Test func aSetThatAlreadyFitsIsLeftAlone() throws {
		let clips = try ResolveImport.read(edl, framesPerSecond: 25)
		// The recording is longer than the timecodes, so they are already on
		// its clock and moving them would be the bug.
		let (moved, shift) = ResolveImport.rebase(clips, against: 7200)
		#expect(shift == 0)
		#expect(moved == clips)
	}

	@Test func mergingSlugsAndDropsWhatDoesNotFit() {
		let imported = [
			ImportedClip(name: "Intro — hello", start: 1, end: 5),
			ImportedClip(name: "Intro — hello", start: 6, end: 9),
			ImportedClip(name: "Past the end", start: 500, end: 510),
		]
		let (take, added, skipped) = ResolveImport.merge(imported, into: Take(video: "a.mov"), duration: 100)
		#expect(added == 2)
		#expect(skipped == 1)
		#expect(take.clips.map(\.slug) == ["intro-hello", "intro-hello-2"])
	}

	@Test func aFileWithNothingInItSaysSo() {
		#expect(throws: ImportError.self) {
			try ResolveImport.read("TITLE: empty\nFCM: NON-DROP FRAME\n", framesPerSecond: 25)
		}
		#expect(throws: ImportError.self) {
			try ResolveImport.read("just some text", framesPerSecond: 25)
		}
	}
}
