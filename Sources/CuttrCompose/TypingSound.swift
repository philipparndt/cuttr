import Foundation

/// The sound a typed line makes: one short click per character.
///
/// **Synthesised rather than played from a file**, because the alternative is
/// asking somebody to find a click and put it beside the project, and then the
/// project does not survive being copied without it. A click is a transient —
/// a burst of noise and a short knock under it — which is about twenty lines of
/// arithmetic and no asset at all.
///
/// **One file per line, not one per character.** The clicks are mixed into a
/// single buffer at their own offsets and handed over as one sound, so a line
/// of forty characters is one thing on one lane rather than forty overlapping
/// placements the lane allocator has to find room for. It also means the
/// timing is sample-accurate: the moments come from the same
/// ``Scene/Typing/moments(of:keys:)`` that decides when the letters appear, so
/// what is heard is what is seen and not a rounding of it.
public enum TypingSound {

	static let rate = 48000.0

	/// One key, as samples.
	///
	/// A mechanical key is two sounds at once: the click of the switch, and the
	/// knock of the key bottoming out under it. Either one alone is wrong — the
	/// click on its own is a spark, and the knock on its own is a drum.
	///
	/// **Low and dull on purpose.** The switch noise is filtered before it is
	/// used, so what is left is the body of the click rather than its edge: a
	/// bright transient forty times in four seconds is a rattle over the top of
	/// whatever else is playing, and this has to sit under a line of type
	/// without becoming the thing being listened to.
	///
	/// **Every key is the same key.** No pitch or loudness varied between them:
	/// the rhythm is where a typed line gets its life — see
	/// ``Scene/Typing/steady`` — and a timbre that also wanders reads as a
	/// fault in the recording rather than as a person typing.
	static func key(into samples: inout [Double], at offset: Int, level: Double) {
		let length = Int(0.055 * rate)
		var noise = Seeded(1)
		// One pole, which is all a click needs: it takes the top off the noise
		// and leaves the wood of it.
		var filtered = 0.0
		for step in 0..<length {
			let index = offset + step
			let at = Double(step) / rate
			filtered += 0.18 * (noise.value(-1...1) - filtered)
			guard index >= 0, index < samples.count else { continue }
			let click = filtered * exp(-at / 0.0055)
			let knock = sin(2 * .pi * 138 * at) * exp(-at / 0.028)
				+ 0.42 * sin(2 * .pi * 92 * at) * exp(-at / 0.036)
			samples[index] += (1.5 * click + 0.5 * knock) * level
		}
	}

	/// A whole line's clicks, as a file, or `nil` if it cannot be written.
	///
	/// Named for what is in it, so the same line at the same moments is
	/// written once and found again on the next render rather than being
	/// synthesised over and over.
	public static func file(
		clicking moments: [Double], level: Double, into folder: URL
	) -> URL? {
		let moments = moments.filter { $0.isFinite && $0 >= 0 }.sorted()
		guard !moments.isEmpty, level > 0 else { return nil }

		var name: UInt64 = 0xcbf2_9ce4_8422_2325
		func stir(_ value: Double) {
			var bits = value.bitPattern
			for _ in 0..<8 {
				name = (name ^ (bits & 0xff)) &* 0x0000_0100_0000_01b3
				bits >>= 8
			}
		}
		moments.forEach(stir)
		stir(level)
		let url = folder.appendingPathComponent("typing-\(String(name, radix: 16)).wav")
		if FileManager.default.fileExists(atPath: url.path) { return url }

		// A tail on the end so the last click is not cut off by the file
		// running out under it.
		let seconds = (moments.last ?? 0) + 0.25
		var samples = [Double](repeating: 0, count: max(1, Int(seconds * rate)))
		for moment in moments {
			key(into: &samples, at: Int(moment * rate), level: 1)
		}

		// Room for two clicks landing together without the sum clipping, which
		// a fast line does.
		let peak = samples.map(abs).max() ?? 1
		let scale = peak > 0 ? min(1, 0.7 / peak) * level : 0
		guard let data = wav(samples.map { $0 * scale }) else { return nil }
		try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		guard (try? data.write(to: url)) != nil else { return nil }
		return url
	}

	/// Sixteen-bit mono PCM, with the header written out.
	///
	/// Hand-written for the same reason the take file's emitter is: it is
	/// forty-four bytes of a format that has not changed since 1991, and the
	/// alternative pulls in an encoder whose output has to be trusted to be
	/// the same on every machine.
	static func wav(_ samples: [Double]) -> Data? {
		guard !samples.isEmpty else { return nil }
		var out = Data()
		func put(_ text: String) { out.append(contentsOf: Array(text.utf8)) }
		func put32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) } }
		func put16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) } }

		let bytes = UInt32(samples.count * 2)
		put("RIFF"); put32(36 + bytes); put("WAVE")
		put("fmt "); put32(16)
		put16(1)                       // PCM
		put16(1)                       // mono
		put32(UInt32(rate))
		put32(UInt32(rate) * 2)        // bytes a second
		put16(2)                       // bytes a frame
		put16(16)                      // bits a sample
		put("data"); put32(bytes)
		for sample in samples {
			let clamped = max(-1, min(1, sample))
			put16(UInt16(bitPattern: Int16(clamped * 32767)))
		}
		return out
	}

	/// Where the written files go: beside the rest of this program's working
	/// files rather than in the project, because they are worth nothing once
	/// the render is over and regenerating one costs milliseconds.
	public static var folder: URL {
		FileManager.default.temporaryDirectory.appendingPathComponent("cuttr-typing",
		                                                              isDirectory: true)
	}
}
