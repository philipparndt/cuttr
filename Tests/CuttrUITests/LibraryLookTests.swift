import AppKit
import Testing
@testable import CuttrCompose
@testable import CuttrUI

/// Space over the library: a look at the material before it is placed.
///
/// The library lists what the takes hold, and until now the only way to see any
/// of it was to put it on the programme and look at that. What makes this
/// different from the programme tree's look is the thing being played: a clip
/// here may never have been placed, so there is no stretch of assembly to play
/// and what plays is the take's own media, on the take's own clock.
///
/// Nothing here dispatches a key event into a view. The press is handed over the
/// way the table hands it over — `table.onKey`, which is the wiring — and what
/// is then asserted is whether a look opened, because an unclaimed key event
/// walks up to `NSResponder` and beeps on the machine running the tests.
@MainActor @Suite struct LibraryLookTests {

	/// A take with one clip in it, its media on disk where the take says.
	///
	/// The files are empty, which is enough for every question here: whether the
	/// media is *there* is what the library has to decide, and what is inside it
	/// is the player's business.
	private func library(offset: Double = 0.5, mediaOnDisk: Bool = true) throws
		-> (LibraryView, NSWindow, URL) {
		let folder = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("cuttr-library-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		let video = folder.appendingPathComponent("shoot.mov")
		let audio = folder.appendingPathComponent("recorder.wav")
		if mediaOnDisk {
			try Data().write(to: video)
			try Data().write(to: audio)
		}

		var vocabulary = ComposeDocument.Vocabulary()
		vocabulary.takeNames = ["take-01"]
		vocabulary.tags = ["b-roll"]
		vocabulary.items = [
			ComposeDocument.Vocabulary.Item(
				take: "take-01", slug: "intro", name: "", tags: ["b-roll"],
				start: 3, length: 2, reference: "intro"),
		]
		vocabulary.media = ["take-01": ComposeDocument.Vocabulary.Media(
			video: video, audio: audio, offset: offset)]

		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 820),
		                      styleMask: [.titled], backing: .buffered, defer: true)
		let library = LibraryView(frame: NSRect(x: 0, y: 0, width: 320, height: 820))
		window.contentView?.addSubview(library)
		library.reload(vocabulary)
		return (library, window, folder)
	}

	private func key(_ code: UInt16) -> NSEvent {
		NSEvent.keyEvent(
			with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
			windowNumber: 0, context: nil, characters: code == 49 ? " " : "\r",
			charactersIgnoringModifiers: code == 49 ? " " : "\r",
			isARepeat: false, keyCode: code)!
	}

	/// A clip is its own stretch of the take, which is where it starts and how
	/// long it runs — not a time on the programme, because it may not be on the
	/// programme at all.
	@Test func aClipIsItsStretchOfTheTake() throws {
		let (library, _, folder) = try library()
		defer { try? FileManager.default.removeItem(at: folder) }
		library.reveal("intro")
		#expect(library.lookSpan() == QuickLook.Span(start: 3, end: 5))
	}

	/// Space opens a look. Asked of the table's own closure and answered by
	/// whether there is a panel up, not by whether a handler ran.
	@Test func spaceOverAClipIsALook() throws {
		let (library, _, folder) = try library()
		defer { try? FileManager.default.removeItem(at: folder) }
		library.reveal("intro")
		#expect(library.keyForTesting(key(49)))
		#expect(library.isLooking)

		// And the same key again puts it away, which is how one key covers both.
		#expect(library.keyForTesting(key(49)))
		#expect(!library.isLooking)
	}

	/// What it plays is the take's media at the take's offset.
	///
	/// One clock, the video's. A positive offset means the recorder was started
	/// after the camera, and the composition that puts the two together is
	/// ``Transport``'s — so this asserts the three numbers were handed over,
	/// which is the whole of what this list has to get right.
	@Test func itPlaysTheTakesOwnMediaAtItsOffset() throws {
		let (library, _, folder) = try library(offset: 0.75)
		defer { try? FileManager.default.removeItem(at: folder) }
		library.reveal("intro")
		#expect(library.keyForTesting(key(49)))
		let panel = try #require(library.lookPanelForTesting)
		let media = try #require(panel.mediaForTesting)
		#expect(media.video?.lastPathComponent == "shoot.mov")
		#expect(media.audio?.lastPathComponent == "recorder.wav")
		#expect(media.offset == 0.75)
		library.closeLook()
	}

	/// A take whose media has been moved somewhere else still opens a look, and
	/// the look says so. A key that quietly does nothing is indistinguishable
	/// from a key nobody wired up.
	@Test func aTakeWhoseMediaHasMovedStillSaysSomething() throws {
		let (library, _, folder) = try library(mediaOnDisk: false)
		defer { try? FileManager.default.removeItem(at: folder) }
		library.reveal("intro")
		#expect(library.keyForTesting(key(49)))
		#expect(library.isLooking)
		let panel = try #require(library.lookPanelForTesting)
		#expect(panel.mediaForTesting == nil, "loaded media that is not there")
		library.closeLook()
	}

	/// Escape puts it away, and only while one is open — the list keeps whatever
	/// escape meant to it otherwise.
	@Test func escapeIsTheWayOut() throws {
		let (library, _, folder) = try library()
		defer { try? FileManager.default.removeItem(at: folder) }
		library.reveal("intro")
		#expect(!library.keyForTesting(key(53)), "escape claimed with nothing open")
		#expect(library.keyForTesting(key(49)))
		#expect(library.keyForTesting(key(53)))
		#expect(!library.isLooking)
	}

	/// A tag is a name with no stretch of anything behind it, so the key is
	/// declined rather than answered with an empty panel. The same goes for a
	/// heading, an anchor and a scene.
	@Test func spaceOnANameThatIsNotAClipIsDeclined() throws {
		let (library, _, folder) = try library()
		defer { try? FileManager.default.removeItem(at: folder) }
		library.reveal("#b-roll")
		#expect(library.lookSpan() == nil)
		#expect(!library.keyForTesting(key(49)))
		#expect(!library.isLooking)
	}

	/// Space used to be a second way to put a clip on the programme. It is not
	/// any more — and `return`, which is the first way, still is.
	@Test func spaceLooksWhereItUsedToInsert() throws {
		let (library, _, folder) = try library()
		defer { try? FileManager.default.removeItem(at: folder) }
		var placed: [String] = []
		library.onInsert = { placed.append($0) }
		library.reveal("intro")

		#expect(library.keyForTesting(key(49)))
		#expect(placed.isEmpty, "space put something on the programme")
		library.closeLook()

		#expect(library.keyForTesting(key(36)))
		#expect(placed == ["intro"])
	}

	/// The trap this feature fell into everywhere else: the window's own key
	/// monitor sees every press first and answers space with the transport, so a
	/// list that answers space for itself is never asked — unless the list has
	/// the keyboard, which is the one condition the monitor hands the key on for.
	///
	/// So: the table takes first responder, it *is* an `NSTableView` — which is
	/// what the monitor tests — and it hands its presses to this list.
	@Test func theListHasTheKeyboardAndHandsThePressOver() throws {
		let (library, window, folder) = try library()
		defer { try? FileManager.default.removeItem(at: folder) }
		let table = library.tableForTesting
		#expect(table.onKey != nil, "the list is not being asked about its keys")
		#expect(window.makeFirstResponder(table))
		#expect(window.firstResponder is NSTableView,
		        "the window's monitor would eat the key")
	}

	/// The panel lands beside the row it is about and inside the window, the same
	/// as the programme tree's does.
	@Test func theLookLandsBesideTheClip() throws {
		let (library, window, folder) = try library()
		defer { try? FileManager.default.removeItem(at: folder) }
		library.reveal("intro")
		library.showLook()
		let frame = try #require(library.lookFrameForTesting)
		let column = window.convertToScreen(library.convert(library.bounds, to: nil))
		#expect(frame.minX >= column.maxX)
		#expect(window.frame.contains(frame))
		library.closeLook()
		#expect(!library.isLooking)
	}

	/// A reload puts it away: the rows are about to move under it, and the take
	/// it was playing may not be one of this project's any more.
	@Test func aReloadPutsTheLookAway() throws {
		let (library, _, folder) = try library()
		defer { try? FileManager.default.removeItem(at: folder) }
		library.reveal("intro")
		library.showLook()
		#expect(library.isLooking)
		library.reload(ComposeDocument.Vocabulary())
		#expect(!library.isLooking)
	}
}
