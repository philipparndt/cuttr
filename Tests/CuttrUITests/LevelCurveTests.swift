import AppKit
import AVFoundation
import Foundation
import Testing
@testable import CuttrKit
@testable import CuttrUI

/// Drawing a gain curve on the timeline, and hearing it.
///
/// The same lesson `MonitorGainTests` records, one grain finer: a level that is
/// written into the file and honoured by the renderer and nowhere else is a
/// control nobody can use. A dip that takes the plosive off and a dip that takes
/// the word off are the same four numbers, so the curve has to be visible over
/// the waveform and audible in the cutting room or it cannot be judged at all.
@MainActor @Suite(.serialized) struct LevelCurveTests {

	/// A probe's answer, without a file: twenty seconds at 25 frames.
	private func info(seconds: Double = 20) -> MediaInfo {
		MediaInfo(url: URL(fileURLWithPath: "/a.mov"), duration: seconds,
		          grid: FrameGrid(framesPerSecond: 25), hasVideo: true, hasAudio: true,
		          naturalSize: CGSize(width: 1920, height: 1080))
	}

	/// An envelope, without a file. See
	/// ``TakeDocument/setMediaForTesting(video:audio:videoWave:audioWave:)``: the
	/// lanes exist only where something has decoded, and a test that waited for a
	/// real decode would be a test about `AVAssetReader`.
	private func envelope(seconds: Double = 20) -> Waveform {
		let buckets = Int(seconds * 100)
		let level = Float(Levelling.amplitude(-20))
		return Waveform(bucketsPerSecond: 100, duration: seconds, sampleRate: 48000,
		                mins: [Float](repeating: -level, count: buckets),
		                maxs: [Float](repeating: level, count: buckets))
	}

	private func take(levels: [LevelPoint] = []) -> Take {
		Take(video: "a.mov", clips: [Clip(slug: "one", name: "One", start: 0, end: 5)],
		     levels: levels)
	}

	/// A window, laid out, with a waveform in it — everything the timeline needs
	/// to have a lane to point at.
	private func window(_ take: Take) -> MainWindowController {
		_ = NSApplication.shared
		let controller = MainWindowController(document: TakeDocument(take: take))
		let window = controller.windowForTesting
		window.setContentSize(NSSize(width: 1400, height: 900))
		window.layoutIfNeeded()
		controller.takeDocument.setMediaForTesting(video: info(), videoWave: envelope())
		controller.timelineForTesting.zoomToFit()
		// Drawn once, because the lane, the curve and the waveform through it are
		// only exercised by a real pass over `draw(_:)`.
		controller.timelineForTesting.display()
		return controller
	}

	private func key(_ code: UInt16, _ characters: String = "") -> NSEvent {
		NSEvent.keyEvent(
			with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
			windowNumber: 0, context: nil, characters: characters,
			charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
	}

	// MARK: - Heard

	/// The window hands the curve to the monitor, in the same breath as the
	/// take's flat level.
	@Test func theWindowHandsTheCurveToTheMonitor() {
		let dip = [LevelPoint(at: 1, gain: 0), LevelPoint(at: 1.1, gain: -12)]
		let controller = window(take(levels: dip))
		defer { controller.window?.close() }
		#expect(controller.transportForTesting.levels == dip)

		controller.takeDocument.setLevels([])
		#expect(controller.transportForTesting.levels.isEmpty)
	}

	/// And the monitor gives the mix back when there is nothing left to say,
	/// rather than leaving one that multiplies by one.
	@Test func theMonitorTakesTheCurveAndGivesItBack() {
		let transport = Transport()
		#expect(transport.levels.isEmpty)
		transport.levels = [LevelPoint(at: 1, gain: -6)]
		#expect(transport.levels.count == 1)
		transport.levels = []
		#expect(transport.levels.isEmpty)
	}

	// MARK: - Drawn on

	/// A press on the curve makes a point, and the drag that follows places it.
	///
	/// Driven with real mouse events through a real window, because the
	/// arithmetic that turns a point on screen into a level in decibels is
	/// exactly the part that goes wrong — and it needs the lane's rectangle.
	@Test func pressingOnTheCurveMakesAPointAndDraggingPlacesIt() throws {
		let controller = window(take())
		defer { controller.window?.close() }
		let timeline = controller.timelineForTesting
		let window = try #require(timeline.window)

		func event(_ type: NSEvent.EventType, _ at: NSPoint) throws -> NSEvent {
			try #require(NSEvent.mouseEvent(
				with: type, location: at, modifierFlags: [], timestamp: 0,
				windowNumber: window.windowNumber, context: nil,
				eventNumber: 0, clickCount: 1, pressure: 1))
		}

		// On the nought line, four seconds in. There is no curve yet, which is
		// why the line is drawn at all: it is what a first click lands on.
		let lane = try #require(timeline.curveRectForTesting)
		let start = NSPoint(x: timeline.x(for: 4), y: timeline.yForLevelForTesting(0, in: lane))
		timeline.mouseDown(with: try event(.leftMouseDown, timeline.convert(start, to: nil)))
		#expect(controller.takeDocument.take.levels.count == 1)
		#expect(abs((controller.takeDocument.take.levels.first?.at ?? 0) - 4) < 0.05)
		#expect(abs(controller.takeDocument.take.levels.first?.gain ?? 1) < 0.2)

		// Pulled down, live all the way: the take follows the pointer, because
		// the picture and the monitor are what somebody is judging the dip by.
		for level in [-6.0, -12.0] {
			let to = NSPoint(x: start.x, y: timeline.yForLevelForTesting(level, in: lane))
			timeline.mouseDragged(with: try event(.leftMouseDragged, timeline.convert(to, to: nil)))
			#expect(abs((controller.takeDocument.take.levels.first?.gain ?? 0) - level) < 0.2)
		}
		let last = NSPoint(x: start.x, y: timeline.yForLevelForTesting(-12, in: lane))
		timeline.mouseUp(with: try event(.leftMouseUp, timeline.convert(last, to: nil)))
		let point = try #require(controller.takeDocument.take.levels.first)
		#expect(abs(point.gain + 12) < 0.2, "the point landed at \(point.gain) dB")
		#expect(controller.takeDocument.take.levels.count == 1)
		// And the point stayed where it was put, rather than following the
		// pointer's time as well as its level.
		#expect(abs(point.at - 4) < 0.05)

		// ⌘Z puts back the take as it was found rather than the last pixel of
		// the drag. One press here, because nothing has spun the run loop
		// between the press and the drag and `UndoManager` groups by event.
		controller.takeDocument.undoManager.undo()
		#expect(controller.takeDocument.take.levels.isEmpty)
	}

	/// A click in the middle of the lane still scrubs. The curve claims four
	/// points either side of the line it draws and not the lane.
	@Test func aClickAwayFromTheCurveStillScrubs() throws {
		let controller = window(take())
		defer { controller.window?.close() }
		let timeline = controller.timelineForTesting
		let window = try #require(timeline.window)
		let lane = try #require(timeline.curveRectForTesting)
		var scrubbed: Double?
		let scrub = timeline.onScrub
		timeline.onScrub = { time in scrubbed = time; scrub?(time) }

		let point = NSPoint(x: timeline.x(for: 4), y: lane.midY + 20)
		let event = try #require(NSEvent.mouseEvent(
			with: .leftMouseDown, location: timeline.convert(point, to: nil),
			modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
			context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
		timeline.mouseDown(with: event)
		#expect(controller.takeDocument.take.levels.isEmpty)
		#expect(abs((scrubbed ?? 0) - 4) < 0.05)
	}

	/// ⌫ takes the selected point away — **through the window**, because the
	/// window's key monitor sees every press before any view does, so a lane
	/// that answered this for itself would never be asked.
	@Test func backspaceRemovesTheSelectedPoint() {
		let dip = [LevelPoint(at: 1, gain: 0), LevelPoint(at: 1.1, gain: -12)]
		let controller = window(take(levels: dip))
		defer { controller.window?.close() }
		controller.timelineForTesting.selectedLevel = 1

		#expect(controller.handleKeyForTesting(key(51)))
		#expect(controller.takeDocument.take.levels == [dip[0]])
		#expect(controller.timelineForTesting.selectedLevel == nil)

		// With no point in hand it is the clips' key again, and the clip is
		// still there because nothing was selected either.
		#expect(controller.handleKeyForTesting(key(51)))
		#expect(controller.takeDocument.take.clips.count == 1)
	}

	// MARK: - Offered

	/// The peaks are proposed, not applied: nothing about the take changes until
	/// ⏎, and ⎋ throws the offer away.
	@Test func tamingThePeaksIsAnOfferUntilReturn() throws {
		var loud = take()
		let controller = window(loud)
		defer { controller.window?.close() }
		// A recording with a door in it, at eight seconds.
		var envelope = [Float](repeating: Float(Levelling.amplitude(-24)), count: 2000)
		for bucket in 800..<812 { envelope[bucket] = Float(Levelling.amplitude(-4)) }
		controller.takeDocument.setMediaForTesting(
			video: info(),
			videoWave: Waveform(bucketsPerSecond: 100, duration: 20, sampleRate: 48000,
			                    mins: envelope.map { -$0 }, maxs: envelope))
		loud = controller.takeDocument.take

		controller.tamePeaksAction()
		#expect(controller.takeDocument.take.levels.isEmpty)
		controller.timelineForTesting.display()
		let offered = try #require(controller.timelineForTesting.proposedLevels)
		#expect(offered.count == 4)
		#expect(abs((offered.min { $0.gain < $1.gain }?.at ?? 0) - 8) < 0.06)

		// ⎋ drops it, and the take is untouched.
		#expect(controller.handleKeyForTesting(key(53)))
		#expect(controller.timelineForTesting.proposedLevels == nil)
		#expect(controller.takeDocument.take.levels.isEmpty)

		// ⏎ keeps it, as one undo step.
		controller.tamePeaksAction()
		#expect(controller.handleKeyForTesting(key(36)))
		#expect(controller.timelineForTesting.proposedLevels == nil)
		#expect(controller.takeDocument.take.levels.count == 4)
		controller.takeDocument.undoManager.undo()
		#expect(controller.takeDocument.take.levels.isEmpty)
	}

	/// A take with nothing sticking out of it is told so rather than being given
	/// four points that do nothing.
	@Test func aSteadyTakeIsOfferedNothing() {
		let controller = window(take())
		defer { controller.window?.close() }
		controller.tamePeaksAction()
		#expect(controller.timelineForTesting.proposedLevels == nil)
		#expect(controller.takeDocument.take.levels.isEmpty)
	}
}
