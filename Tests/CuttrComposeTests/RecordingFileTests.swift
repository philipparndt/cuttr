import CuttrKit
import Foundation
import Testing
@testable import CuttrCompose

/// A screencast, as it is written down.
///
/// The file is the product, so this suite is about the file: that a recording
/// survives being read and written unchanged, that a project with none writes
/// nothing new, and that a recording somebody made once can be made again by
/// reading rather than by remembering.
@Suite struct RecordingFileTests {

	@Test func aRecordingIsRead() throws {
		let project = try ProjectReader.read("""
		recordings:
		  - as:      install-demo
		    url:     https://example.com/download
		    size:    1600x900
		    browser: chromium
		    chrome:  none
		timeline: [one]
		""")
		let made = try #require(project.recordings.first)
		#expect(made.name == "install-demo")
		#expect(made.url == "https://example.com/download")
		#expect(made.width == 1600)
		#expect(made.height == 900)
		#expect(made.browser == .chromium)
		#expect(made.chrome == Recording.Chrome.none)
	}

	/// What a recording is without anything said about it: 1280×720, whichever
	/// browser is installed, and the address bar in the film.
	@Test func aPlainRecordingHasTheCommonAnswers() throws {
		let project = try ProjectReader.read("""
		recordings:
		  - as:  install-demo
		    url: https://example.com/download
		timeline: [one]
		""")
		let made = try #require(project.recordings.first)
		#expect(made.width == 1280)
		#expect(made.height == 720)
		#expect(made.browser == nil, "a browser was chosen that nobody named")
		#expect(made.chrome == .bar, "the address bar is the default")
	}

	/// And writing it back puts none of those defaults in: three lines is what a
	/// plain recording costs.
	@Test func thePlainOneStaysThreeLines() throws {
		let project = try ProjectReader.read("""
		recordings:
		  - as:  install-demo
		    url: https://example.com/download
		timeline: [one]
		""")
		let written = ProjectWriter.write(project)
		#expect(written.contains("""
		recordings:
		  - as:      install-demo
		    url:     https://example.com/download

		"""))
		#expect(!written.contains("size:    1280x720"))
		#expect(!written.contains("chrome:"))
		#expect(!written.contains("browser:"))
	}

	@Test func aRecordingRoundTrips() throws {
		let project = try ProjectReader.read("""
		recordings:
		  - as:      install-demo
		    url:     https://example.com/download
		    size:    1600x900
		    browser: chrome
		    chrome:  none

		  - as:      the-settings
		    url:     https://example.com/settings
		timeline: [one]
		""")
		let written = ProjectWriter.write(project)
		let back = try ProjectReader.read(written)
		#expect(back == project)
		#expect(ProjectWriter.write(back) == written)
		#expect(written.contains("    browser: chrome\n"))
		#expect(written.contains("    chrome:  none\n"))
	}

	/// The rule every block here follows: a project that has none of this writes
	/// exactly what it wrote before, so the feature costs nothing to a file that
	/// does not use it.
	@Test func aProjectThatRecordsNothingWritesNoBlock() throws {
		let project = try ProjectReader.read("timeline: [one]\n")
		#expect(!ProjectWriter.write(project).contains("recordings"))
	}

	/// A recording with nowhere to go would open a browser on nothing, so it is
	/// skipped whole rather than half-read.
	@Test func aRecordingWithNoUrlIsNotOne() throws {
		let project = try ProjectReader.read("""
		recordings:
		  - as: install-demo
		  - url: https://example.com
		  - as:  good
		    url: https://example.com/ok
		timeline: [one]
		""")
		#expect(project.recordings.count == 1)
		#expect(project.recordings.first?.name == "good")
	}

	/// A size that is not a size is a mistake in the file and is said so,
	/// because the alternative is a recording that comes out at a size nobody
	/// chose.
	@Test func aSizeThatIsNotOneIsRefused() {
		#expect(throws: (any Error).self) {
			try ProjectReader.read("""
			recordings:
			  - as:   demo
			    url:  https://example.com
			    size: enormous
			timeline: [one]
			""")
		}
	}

	/// A file written by a later version survives being opened and saved by
	/// this one, which is the promise the rest of the format makes and has to
	/// be made per entry because a recording is written in a list.
	@Test func aKeyFromALaterVersionSurvives() throws {
		let project = try ProjectReader.read("""
		recordings:
		  - as:      install-demo
		    url:     https://example.com
		    throttle: slow-3g
		timeline: [one]
		""")
		#expect(project.recordings.first?.unknownKeys["throttle"] as? String == "slow-3g")
		let written = ProjectWriter.write(project)
		#expect(written.contains("throttle: slow-3g"))
		// And it is still there the second time round.
		let back = try ProjectReader.read(written)
		#expect(back.recordings.first?.unknownKeys["throttle"] as? String == "slow-3g")
		#expect(ProjectWriter.write(back) == written)
	}

	/// The name is a slug, because it is also the take's name and a take is
	/// referred to by one.
	@Test func theNameIsASlug() throws {
		let project = try ProjectReader.read("""
		recordings:
		  - as:  The Install Demo
		    url: https://example.com
		timeline: [one]
		""")
		#expect(project.recordings.first?.name == "the-install-demo")
	}
}
