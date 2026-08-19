import AVFoundation
import Foundation
import Testing
@testable import CuttrKit

/// Searching for a meme, and what a downloaded one becomes.
///
/// Nothing here touches the network, and that is deliberate: a test that calls
/// GIPHY fails on a train, spends somebody's rate limit, and needs a key to
/// run — so it would be turned off, and a test that is turned off is not a
/// test. What is checked is everything either side of the wire, which is where
/// the decisions with right answers are: reading each service's answer, telling
/// four kinds of failure apart, and choosing a name and a take for what came
/// back. The bytes in the middle are AVFoundation's problem and URLSession's.
@Suite struct MemeTests {

	// MARK: - Reading what a provider sends

	/// GIPHY's shape, trimmed to the keys this program reads. Its numbers are
	/// strings — `"width": "480"` — which is the thing about this API most
	/// likely to be got wrong by a decoder written from memory.
	private let giphyAnswer = """
	{
	  "data": [
	    {
	      "type": "gif",
	      "id": "l0HlvtIPzPdt2usKs",
	      "url": "https://giphy.com/gifs/facepalm-l0HlvtIPzPdt2usKs",
	      "title": "Facepalm GIF by Cartoon Hangover",
	      "images": {
	        "original": {
	          "width": "480", "height": "270", "size": "1044162",
	          "url": "https://media.giphy.com/media/l0Hlv/giphy.gif",
	          "mp4": "https://media.giphy.com/media/l0Hlv/giphy.mp4",
	          "mp4_size": "142371"
	        },
	        "fixed_width_small_still": {
	          "width": "100", "height": "56",
	          "url": "https://media.giphy.com/media/l0Hlv/100w_s.gif"
	        },
	        "downsized_small": { "width": "192", "height": "108",
	          "mp4": "https://media.giphy.com/media/l0Hlv/giphy-downsized-small.mp4" }
	      }
	    },
	    {
	      "id": "no-video-here",
	      "url": "https://giphy.com/gifs/no-video-here",
	      "title": "Nothing to download",
	      "images": { "downsized": { "url": "https://media.giphy.com/media/x/giphy.gif" } }
	    }
	  ],
	  "pagination": { "total_count": 250, "count": 2, "offset": 0 },
	  "meta": { "status": 200, "msg": "OK", "response_id": "abc" }
	}
	"""

	private let tenorAnswer = """
	{
	  "results": [
	    {
	      "id": "16989471141876748307",
	      "title": "",
	      "content_description": "Facepalm Really GIF",
	      "itemurl": "https://tenor.com/view/facepalm-really-gif-16989471",
	      "url": "https://tenor.com/bZaMu.gif",
	      "hasaudio": false,
	      "media_formats": {
	        "mp4": {
	          "url": "https://media.tenor.com/abc/facepalm.mp4",
	          "duration": 2.4, "dims": [498, 280], "size": 265081
	        },
	        "tinygif": {
	          "url": "https://media.tenor.com/abc/facepalm-tiny.gif",
	          "duration": 0, "dims": [220, 124], "size": 43210
	        }
	      }
	    }
	  ],
	  "next": ""
	}
	"""

	@Test func readsGiphysAnswer() throws {
		let found = try MemeSearch.parse(Data(giphyAnswer.utf8), from: .giphy)
		// The second result has no mp4 anywhere in it. AVFoundation will not
		// open a GIF as a movie, so a result with no mp4 is not a result.
		#expect(found.count == 1)
		let first = try #require(found.first)
		#expect(first.id == "l0HlvtIPzPdt2usKs")
		#expect(first.title == "Facepalm GIF by Cartoon Hangover")
		#expect(first.video.absoluteString == "https://media.giphy.com/media/l0Hlv/giphy.mp4")
		#expect(first.preview?.absoluteString == "https://media.giphy.com/media/l0Hlv/100w_s.gif")
		#expect(first.page?.absoluteString == "https://giphy.com/gifs/facepalm-l0HlvtIPzPdt2usKs")
		// Strings in the file, numbers here.
		#expect(first.size.width == 480)
		#expect(first.size.height == 270)
	}

	@Test func readsTenorsAnswer() throws {
		let found = try MemeSearch.parse(Data(tenorAnswer.utf8), from: .tenor)
		let first = try #require(found.first)
		#expect(first.id == "16989471141876748307")
		// Tenor's `title` is usually empty and the description is the sentence
		// a person would recognise it by.
		#expect(first.title == "Facepalm Really GIF")
		#expect(first.video.absoluteString == "https://media.tenor.com/abc/facepalm.mp4")
		#expect(first.duration == 2.4)
		#expect(first.size.width == 498)
	}

	@Test func anEmptyAnswerIsNoResultsRatherThanAFailure() throws {
		#expect(try MemeSearch.parse(Data(#"{"data": [], "meta": {"status": 200}}"#.utf8),
		                             from: .giphy).isEmpty)
		#expect(try MemeSearch.parse(Data(#"{"results": []}"#.utf8), from: .tenor).isEmpty)
	}

	@Test func somethingThatIsNotJsonIsSaidToBeUnreadable() {
		#expect(throws: MemeError.unreadable(.giphy)) {
			try MemeSearch.parse(Data("<html>502 Bad Gateway</html>".utf8), from: .giphy)
		}
	}

	// MARK: - The four ways it goes wrong

	@Test func aRefusalIsToldApartFromAnOutage() {
		// The two services disagree about which code a bad key is: GIPHY says
		// 401 or 403, Tenor is a Google API and says 400 INVALID_ARGUMENT.
		// Reporting Tenor's as a bad request would send somebody looking at
		// their search term.
		let giphy = MemeSearch.failure(.giphy, status: 403, body: Data())
		#expect(giphy == .keyRejected(.giphy, nil))

		let tenorBody = Data("""
		{"error": {"code": 400, "status": "INVALID_ARGUMENT",
		 "message": "API key not valid. Please pass a valid API key."}}
		""".utf8)
		let tenor = MemeSearch.failure(.tenor, status: 400, body: tenorBody)
		#expect(tenor == .keyRejected(.tenor, "API key not valid. Please pass a valid API key."))

		#expect(MemeSearch.failure(.giphy, status: 429, body: Data()) == .tooManyRequests(.giphy))
		if case .providerDown = MemeSearch.failure(.giphy, status: 503, body: Data()) {} else {
			Issue.record("a 503 is the provider being down")
		}
	}

	@Test func noNetworkSaysSoRatherThanBlamingTheProvider() async {
		// The machine being off the network is not GIPHY being down, and
		// telling somebody to check a service that is perfectly well is the
		// wrong half hour to send them on.
		let unplugged: MemeSearch.Fetch = { _ in throw URLError(.notConnectedToInternet) }
		await #expect(throws: MemeError.offline) {
			try await MemeSearch.search("facepalm", provider: .giphy, key: "not-a-real-key",
			                            fetch: unplugged)
		}
	}

	@Test func noKeyIsItsOwnAnswer() async {
		await #expect(throws: MemeError.noKey(.giphy)) {
			try await MemeSearch.search("facepalm", provider: .giphy, key: "",
			                            fetch: { _ in Issue.record("must not ask"); return (Data(), URLResponse()) })
		}
		// And the message has to say where to put one and where to get one,
		// because "no API key" on its own is a dead end.
		let said = MemeError.noKey(.giphy).errorDescription ?? ""
		#expect(said.contains("config.yaml"))
		#expect(said.contains("GIPHY_API_KEY"))
		#expect(said.contains("https://developers.giphy.com/dashboard/"))
	}

	@Test func theKeyComesFromTheEnvironmentFirstAndTheFileSecond() throws {
		var settings = Settings()
		settings.setKey("from-the-file", for: "giphy")
		#expect(MemeKeys.key(for: .giphy, environment: [:], settings: settings) == "from-the-file")
		#expect(MemeKeys.key(for: .giphy, environment: ["GIPHY_API_KEY": "from-the-shell"],
		                     settings: settings) == "from-the-shell")
		#expect(MemeKeys.key(for: .tenor, environment: [:], settings: settings) == nil)
		// And the panel opens on a service that will actually answer.
		#expect(MemeKeys.firstUsable(environment: [:], settings: settings) == .giphy)
	}

	@Test func theKeyIsNotInTheUrlThisProgramShows() {
		// A search URL carries the key in a query parameter, so it is never
		// somewhere that gets logged or shown. This only checks the shape.
		let url = MemeSearch.url(for: .giphy, query: "facepalm", key: "SECRET")
		#expect(url?.host == "api.giphy.com")
		#expect(url?.query?.contains("q=facepalm") == true)
		let tenor = MemeSearch.url(for: .tenor, query: "face palm", key: "SECRET")
		#expect(tenor?.host == "tenor.googleapis.com")
		#expect(tenor?.query?.contains("face%20palm") == true)
	}

	// MARK: - What a download becomes

	private func result(title: String, id: String = "abc123") -> MemeResult {
		MemeResult(provider: .giphy, id: id, title: title,
		           page: URL(string: "https://giphy.com/gifs/\(id)"),
		           video: URL(string: "https://media.giphy.com/media/\(id)/giphy.mp4")!)
	}

	@Test func aNameBecomesAFileNameAndAReference() {
		// GIPHY titles are written for a search engine. The part somebody would
		// type is the front of it, and the whole title is kept in the take.
		#expect(MemeDownload.slug(for: result(title: "Facepalm GIF by Cartoon Hangover")) == "facepalm")
		#expect(MemeDownload.slug(for: result(title: "Oh No Reaction Sticker")) == "oh-no-reaction")
		// Nothing usable to go on: the service's own id is the one thing there
		// always is.
		#expect(MemeDownload.slug(for: result(title: "")) == "giphy-abc123")
		// Two facepalms in one project are two files.
		#expect(MemeDownload.slug(for: result(title: "Facepalm GIF"), taken: ["facepalm"])
			== "facepalm-2")
		// Long enough to be unwieldy is cut at a word.
		let long = MemeDownload.slug(for: result(
			title: "When you realise the render has been going for three hours and it is wrong"))
		#expect(long.count <= 32)
		#expect(!long.hasSuffix("-"))
	}

	@Test func aDownloadedMemeIsATakeWithOneClipAndItsProvenance() throws {
		let meme = result(title: "Facepalm GIF by Cartoon Hangover")
		let take = MemeDownload.take(for: meme, video: "../memes/facepalm.mp4",
		                             duration: 2.48, slug: "facepalm")
		#expect(take.video == "../memes/facepalm.mp4")
		#expect(take.clips.count == 1)
		#expect(take.clips[0].slug == "facepalm")
		#expect(take.clips[0].start == 0)
		#expect(take.clips[0].end == 2.48)

		// And it survives being written and read back, which is what makes it
		// a project somebody can publish rather than a folder of orphans.
		let back = try TakeReader.read(TakeWriter.write(take))
		#expect(back == take)
		#expect(back.source?.provider == "giphy")
		#expect(back.source?.id == "abc123")
		#expect(back.source?.page == "https://giphy.com/gifs/abc123")
		#expect(back.source?.attribution == "Powered By GIPHY")
		#expect(back.source?.isMeme == true)
	}

	@Test func aTakeThatWasRecordedIsNotAMeme() {
		// What the library sorts on. A `source:` naming something that is not a
		// meme service — a stock library, somebody's own archive — is carried
		// through the file but does not land in the memes section.
		#expect(TakeSource(provider: "shot-on-the-roof", id: "1").isMeme == false)
		#expect(TakeSource(provider: "tenor", id: "1").isMeme == true)
	}

	@Test func theTakeSaysWhereTheMediaIsRelativeToItself() {
		// Every path in a project is relative to the file that holds it, which
		// is what makes the whole folder copyable to another disk.
		let project = URL(fileURLWithPath: "/Users/somebody/Films/Ep-3")
		#expect(MemeDownload.relativePath(
			from: project.appendingPathComponent("takes/facepalm.cuttr"),
			to: project.appendingPathComponent("memes/facepalm.mp4")) == "../memes/facepalm.mp4")
		// A project that keeps its takes beside itself, which is also allowed.
		#expect(MemeDownload.relativePath(
			from: project.appendingPathComponent("facepalm.cuttr"),
			to: project.appendingPathComponent("memes/facepalm.mp4")) == "memes/facepalm.mp4")
	}

	@Test func downloadingWritesTheMediaAndTheTakeWhereTheyBelong() async throws {
		// The bytes come from a closure rather than from GIPHY, so the shape of
		// what lands on the disk is checked without a network: a real mp4 in
		// `memes/`, a take beside the project's other takes pointing at it with
		// `../`, and one clip as long as the file.
		let root = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("cuttr-meme-\(UUID().uuidString)", isDirectory: true)
		defer { try? FileManager.default.removeItem(at: root) }
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

		let sample = try makeMovie(in: root)
		let bytes = try Data(contentsOf: sample)
		let downloaded = try await MemeDownload.fetch(
			result(title: "Facepalm GIF by Cartoon Hangover"),
			project: root, takes: root.appendingPathComponent("takes", isDirectory: true),
			fetch: { _ in bytes })

		#expect(downloaded.slug == "facepalm")
		#expect(downloaded.video.deletingLastPathComponent().lastPathComponent == "memes")
		#expect(FileManager.default.fileExists(atPath: downloaded.video.path))

		let take = try TakeReader.read(try String(contentsOf: downloaded.take, encoding: .utf8))
		#expect(take.video?.hasPrefix("../memes/facepalm") == true)
		#expect(take.source?.isMeme == true)
		#expect(take.clips.count == 1)
		#expect(abs(take.clips[0].end - 1.0) < 0.1)
	}

	/// A second of green, written with AVFoundation so the test needs no
	/// fixture on disk and no ffmpeg on the machine.
	private func makeMovie(in folder: URL) throws -> URL {
		let url = folder.appendingPathComponent("sample.mp4")
		let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
		let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
			AVVideoCodecKey: AVVideoCodecType.h264,
			AVVideoWidthKey: 160, AVVideoHeightKey: 90,
		])
		let adaptor = AVAssetWriterInputPixelBufferAdaptor(
			assetWriterInput: input, sourcePixelBufferAttributes: nil)
		writer.add(input)
		writer.startWriting()
		writer.startSession(atSourceTime: .zero)
		var pool: CVPixelBuffer?
		for frame in 0..<25 {
			CVPixelBufferCreate(nil, 160, 90, kCVPixelFormatType_32BGRA, nil, &pool)
			guard let buffer = pool else { break }
			CVPixelBufferLockBaseAddress(buffer, [])
			memset(CVPixelBufferGetBaseAddress(buffer), 120,
			       CVPixelBufferGetBytesPerRow(buffer) * 90)
			CVPixelBufferUnlockBaseAddress(buffer, [])
			while !input.isReadyForMoreMediaData { usleep(1000) }
			adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 25))
		}
		input.markAsFinished()
		let done = DispatchSemaphore(value: 0)
		writer.finishWriting { done.signal() }
		done.wait()
		return url
	}
}