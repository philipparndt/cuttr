import AppKit
import AVFoundation
import Foundation
import Testing
@testable import CuttrKit
@testable import CuttrUI

/// A take's level, where it is heard and where it is drawn.
///
/// It was written into the file and honoured by the renderer, and nowhere else:
/// the cutting room's own monitor played the audio at full level and the
/// timeline drew the waveform at full height. So typing a level did nothing you
/// could hear or see, which is indistinguishable from a field that does not
/// work.
@MainActor @Suite struct MonitorGainTests {

	/// Decibels are what the file says; a mix and a waveform both want the
	/// ratio. One conversion, so they cannot disagree.
	@Test func decibelsBecomeAnAmplitude() {
		#expect(Levelling.amplitude(0) == 1)
		#expect(abs(Levelling.amplitude(6) - 1.9953) < 0.001)
		#expect(abs(Levelling.amplitude(-6) - 0.5012) < 0.001)
		#expect(abs(Levelling.amplitude(20) - 10) < 1e-9)
		#expect(abs(Levelling.amplitude(-20) - 0.1) < 1e-9)
	}

	/// Ten decibels is a little over three times the amplitude, which is what
	/// the waveform has to grow by — and it clips against the lane rather than
	/// drawing over its neighbour.
	@Test func tenDecibelsIsThreeTimesTheHeight() {
		#expect(abs(Levelling.amplitude(10) - 3.1623) < 0.001)
	}

	/// The monitor takes the take's level, and putting it back to nought takes
	/// the mix off again rather than leaving a mix that multiplies by one.
	@Test func theMonitorTakesTheLevelAndGivesItBack() async throws {
		let transport = Transport()
		#expect(transport.gain == 0)
		transport.gain = -6
		#expect(transport.gain == -6)
		transport.gain = 0
		#expect(transport.gain == 0)
	}

	/// The window hands the take's level to the monitor whenever it refreshes,
	/// which is the same place it hands over the look.
	@Test func theWindowHandsTheLevelToTheMonitor() {
		_ = NSApplication.shared
		var take = Take(video: "a.mov", clips: [Clip(slug: "one", start: 0, end: 1)])
		take.gain = -4
		let controller = MainWindowController(document: TakeDocument(take: take))
		defer { controller.window?.close() }
		let window = controller.windowForTesting
		window.setContentSize(NSSize(width: 1400, height: 900))
		window.layoutIfNeeded()
		#expect(controller.transportForTesting.gain == -4)

		controller.takeDocument.setTakeGain(3)
		#expect(controller.transportForTesting.gain == 3)
	}
}
