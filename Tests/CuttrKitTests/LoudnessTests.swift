import Foundation
import Testing
@testable import CuttrKit

/// The meter, against signals whose loudness is arithmetic rather than opinion.
@Suite struct LoudnessTests {

	/// A mono WAV of a 1 kHz sine at a given amplitude.
	private func sine(amplitude: Double, seconds: Double, rate: Double = 48000,
	                  gapEvery: Double? = nil) throws -> URL {
		let url = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("cuttr-loud-\(UUID().uuidString).wav")
		let count = Int(seconds * rate)
		var samples = [Float](repeating: 0, count: count)
		for i in 0 ..< count {
			let t = Double(i) / rate
			// Silence for half of every `gapEvery` seconds, to exercise the
			// relative gate: the pauses must not drag the answer down.
			if let gapEvery, t.truncatingRemainder(dividingBy: gapEvery) > gapEvery / 2 { continue }
			samples[i] = Float(amplitude * sin(2 * .pi * 1000 * t))
		}
		try WAV.write(samples, rate: rate, to: url)
		return url
	}

	enum WAV {
		static func write(_ samples: [Float], rate: Double, to url: URL) throws {
			var data = Data()
			func append<T>(_ value: T) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
			let bytes = UInt32(samples.count * 4)
			data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + bytes))
			data.append(contentsOf: Array("WAVEfmt ".utf8))
			append(UInt32(16)); append(UInt16(3))            // IEEE float
			append(UInt16(1)); append(UInt32(rate))
			append(UInt32(rate) * 4); append(UInt16(4)); append(UInt16(32))
			data.append(contentsOf: Array("data".utf8)); append(bytes)
			for s in samples { append(s) }
			try data.write(to: url)
		}
	}

	@Test func aSineReadsItsOwnLevel() async throws {
		// A 1 kHz sine at −23 dBFS RMS should read −23 LUFS: the K filter's
		// +0.69 dB at 1 kHz is exactly what the spec's −0.691 offset cancels,
		// which is the calibration the whole scale rests on.
		let rms = pow(10.0, -23.0 / 20.0)
		let url = try sine(amplitude: rms * 2.0.squareRoot(), seconds: 5)
		defer { try? FileManager.default.removeItem(at: url) }
		let measured = try await LoudnessMeter.measure(url: url)
		let integrated = try #require(measured.integrated)
		#expect(abs(integrated - (-23)) < 0.4, "read \(integrated)")
	}

	@Test func sixMoreDecibelsIsSixMoreUnits() async throws {
		let quiet = try sine(amplitude: 0.05, seconds: 4)
		let loud = try sine(amplitude: 0.1, seconds: 4)
		defer {
			try? FileManager.default.removeItem(at: quiet)
			try? FileManager.default.removeItem(at: loud)
		}
		let a = try #require(try await LoudnessMeter.measure(url: quiet).integrated)
		let b = try #require(try await LoudnessMeter.measure(url: loud).integrated)
		#expect(abs((b - a) - 6.0206) < 0.1, "\(a) then \(b)")
	}

	@Test func pausesDoNotDragItDown() async throws {
		// The relative gate is the reason a take full of pauses measures the
		// same as one without. Without it the second of these reads several
		// units quieter and every clip with pauses comes out too loud.
		//
		// Two seconds on, two off. Gaps shorter than about a second genuinely
		// *do* read quieter and that is not a fault: the window is 400 ms, so
		// every transition produces half-full blocks that sit only ~3 dB down,
		// which is well inside the 10 LU gate and counts. A 0.5 s alternation
		// measures about 2 LU low, correctly.
		let solid = try sine(amplitude: 0.1, seconds: 12)
		let gappy = try sine(amplitude: 0.1, seconds: 12, gapEvery: 4.0)
		defer {
			try? FileManager.default.removeItem(at: solid)
			try? FileManager.default.removeItem(at: gappy)
		}
		let a = try #require(try await LoudnessMeter.measure(url: solid).integrated)
		let b = try #require(try await LoudnessMeter.measure(url: gappy).integrated)
		#expect(abs(a - b) < 1.0, "\(a) then \(b)")
	}

	@Test func silenceHasNoLoudness() async throws {
		let url = try sine(amplitude: 0, seconds: 3)
		defer { try? FileManager.default.removeItem(at: url) }
		let measured = try await LoudnessMeter.measure(url: url)
		// Not zero, not −70: nothing. Amplifying silence to the target is the
		// one thing that must not happen.
		#expect(measured.integrated == nil)
	}

	@Test func theCeilingWinsWhenItBinds() {
		let hot = Loudness(integrated: -30, peak: -0.5)
		// Wants +14 to reach −16, but only −0.5 of headroom to a −1 ceiling.
		#expect(hot.gain(toward: -16) == 14)
		#expect(abs(hot.gain(toward: -16, ceiling: -1) - (-0.5)) < 1e-9)
	}

	@Test func gatingIsWhatMakesTheMeanMeanSomething() {
		// Ninety per cent silence and a tenth at a real level: the answer is the
		// level of the real part, not a tenth of it.
		let loud = [Double](repeating: 0.01, count: 10)
		let silent = [Double](repeating: 1e-12, count: 90)
		let gated = try! #require(LoudnessMeter.integrate(loud + silent))
		let alone = try! #require(LoudnessMeter.integrate(loud))
		#expect(abs(gated - alone) < 0.01)
	}
}
