import Foundation

/// A clip that came from somewhere else.
public struct ImportedClip: Sendable, Equatable {
	public var name: String
	/// Seconds on the *source* recording's own clock, which is not necessarily
	/// the file's clock — see ``ResolveImport``.
	public var start: Double
	public var end: Double
}

public enum ImportError: LocalizedError {
	case unrecognised
	case noClips
	case malformed(String)

	public var errorDescription: String? {
		switch self {
		case .unrecognised:
			return "This is not an EDL or an XML timeline that cuttr can read."
		case .noClips:
			return "No clips in this file. In Resolve, put the subclips on a timeline and export that."
		case .malformed(let what):
			return "Could not read the file: \(what)"
		}
	}
}

/// Reading subclips out of DaVinci Resolve.
///
/// Resolve keeps subclips in the media pool, and the media pool is not
/// something it exports. What it exports is a *timeline*, so the way across is
/// to drop the subclips onto one and export that — as an EDL, as FCPXML, or as
/// the older Final Cut Pro 7 XML, all three of which Resolve writes and all
/// three of which are handled here. Each timeline event is one subclip, with
/// its source in and out, and usually with the name the subclip was given.
///
/// **The timecode problem, and what is done about it.** An EDL's source
/// timecodes are the *camera's* — a file that starts at 14:32:08:00 has an EDL
/// full of numbers near fourteen hours, while cuttr counts from the first frame
/// of the file. There is nothing in an EDL that says where the file starts, so
/// the numbers alone cannot be placed. ``rebase(_:against:)`` is the answer and
/// it is a heuristic rather than a fact: when every imported clip lands past the
/// end of the recording, the whole set is shifted so that the earliest one
/// starts where the take's clock does. That is right for the ordinary case —
/// one camera file, one timeline — and it is stated here rather than hidden
/// because the case it is wrong for is real: subclips from *two* source files
/// with different start timecodes cannot be told apart this way.
public enum ResolveImport {

	/// What the text turns out to be.
	public enum Format: Sendable {
		case edl, fcpxml, fcp7xml
	}

	public static func detect(_ text: String) -> Format? {
		let head = text.prefix(4096)
		if head.contains("<fcpxml") { return .fcpxml }
		if head.contains("<xmeml") { return .fcp7xml }
		// An EDL begins with TITLE:, and Resolve always writes one. The FCM
		// line is the fallback for a hand-trimmed file.
		if head.contains("TITLE:") || head.contains("FCM:") { return .edl }
		return nil
	}

	/// Reads whichever of the three it is.
	///
	/// `framesPerSecond` is only used by the EDL reader, which has no rate in
	/// it: an EDL is frames-and-timecode all the way down and says nothing
	/// about how long a frame is. The take's own video answers that.
	public static func read(_ text: String, framesPerSecond: Double) throws -> [ImportedClip] {
		guard let format = detect(text) else { throw ImportError.unrecognised }
		let clips: [ImportedClip]
		switch format {
		case .edl: clips = try readEDL(text, framesPerSecond: framesPerSecond)
		case .fcpxml, .fcp7xml: clips = try readXML(text)
		}
		guard !clips.isEmpty else { throw ImportError.noClips }
		return clips
	}

	// MARK: - EDL

	static func readEDL(_ text: String, framesPerSecond: Double) throws -> [ImportedClip] {
		guard framesPerSecond > 0 else { throw ImportError.malformed("no frame rate to read an EDL with") }
		var clips: [ImportedClip] = []
		// A CMX 3600 comment describes the event *above* it, and Resolve writes
		// one set of comments per event — including for the audio event that
		// repeats the video one. So a name is attached to the clip that has just
		// been read, and only if that clip has not been named already: the
		// second `FROM CLIP NAME` belongs to the audio event, which was skipped,
		// and letting it fall through would name the next clip after this one.
		var named = Set<Int>()          // by `FROM CLIP NAME`, which wins
		var weaklyNamed = Set<Int>()    // by `SOURCE FILE`, which only fills a gap

		for rawLine in text.components(separatedBy: .newlines) {
			let line = rawLine.trimmingCharacters(in: .whitespaces)
			if line.isEmpty { continue }

			// Resolve writes both `* FROM CLIP NAME:` and `*FROM CLIP NAME:`.
			if line.hasPrefix("*") {
				guard let index = clips.indices.last else { continue }
				let body = line.dropFirst().trimmingCharacters(in: .whitespaces)
				if body.hasPrefix("FROM CLIP NAME:"), !named.contains(index) {
					clips[index].name = String(body.dropFirst("FROM CLIP NAME:".count))
						.trimmingCharacters(in: .whitespaces)
					named.insert(index)
				} else if body.hasPrefix("SOURCE FILE:"),
				          !named.contains(index), !weaklyNamed.contains(index) {
					// The camera file rather than the subclip: the same for
					// every event, so it is a last resort and never an override.
					clips[index].name = String(body.dropFirst("SOURCE FILE:".count))
						.trimmingCharacters(in: .whitespaces)
					weaklyNamed.insert(index)
				}
				continue
			}

			// An event line starts with its number.
			guard let first = line.first, first.isNumber else { continue }
			let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
			// event, reel, channel, transition, [dur], and four timecodes.
			guard fields.count >= 8 else { continue }
			let channel = fields[2].uppercased()
			// Audio-only events repeat the video ones in a Resolve EDL. Keeping
			// both would double every clip.
			guard channel.hasPrefix("V") || channel.hasPrefix("B") || channel == "AA/V" else { continue }
			let timecodes = fields.suffix(4)
			guard let sourceIn = parseTimecode(timecodes[timecodes.startIndex], fps: framesPerSecond),
			      let sourceOut = parseTimecode(timecodes[timecodes.startIndex + 1], fps: framesPerSecond),
			      sourceOut > sourceIn
			else { continue }
			// An EDL's out point is exclusive, which is also how a clip's `end`
			// is defined here, so no frame is added or taken away.
			clips.append(ImportedClip(name: "event \(fields[0])", start: sourceIn, end: sourceOut))
		}
		return clips
	}

	/// `HH:MM:SS:FF`, or `HH:MM:SS;FF` for drop-frame.
	///
	/// Drop-frame is not a different frame rate — it is 29.97 fps counted with
	/// labels skipped so the clock keeps up with the wall. Two frame numbers are
	/// dropped at the start of every minute except every tenth, and ignoring
	/// that puts an hour-long timeline out by three and a half seconds.
	static func parseTimecode(_ text: String, fps: Double) -> Double? {
		let dropFrame = text.contains(";") || text.contains(",")
		let parts = text.split(whereSeparator: { $0 == ":" || $0 == ";" || $0 == "," })
		guard parts.count == 4,
		      let h = Int(parts[0]), let m = Int(parts[1]),
		      let s = Int(parts[2]), let f = Int(parts[3])
		else { return nil }

		let nominal = (fps * 100).rounded() / 100
		if dropFrame {
			// The rate a drop-frame count is written against: 30 labels a
			// second for 29.97 frames, 60 for 59.94.
			let labelled = (nominal / 29.97).rounded() * 30
			let dropPerMinute = 2 * Int((labelled / 30).rounded())
			let totalMinutes = h * 60 + m
			let dropped = dropPerMinute * (totalMinutes - totalMinutes / 10)
			let frames = Int(labelled) * (h * 3600 + m * 60 + s) + f - dropped
			return Double(frames) / nominal
		}
		return Double(h * 3600 + m * 60 + s) + Double(f) / nominal
	}

	// MARK: - XML

	static func readXML(_ text: String) throws -> [ImportedClip] {
		guard let data = text.data(using: .utf8) else { throw ImportError.malformed("not UTF-8") }
		let parser = XMLParser(data: data)
		let delegate = XMLReader()
		parser.delegate = delegate
		guard parser.parse() else {
			throw ImportError.malformed(parser.parserError?.localizedDescription ?? "bad XML")
		}
		return delegate.clips
	}

	/// One delegate for both XML dialects, because they are the same document
	/// twice: a list of clip items, each with a name and a pair of source
	/// points. What differs is the spelling and the unit — FCPXML writes
	/// rational seconds in attributes, FCP7 writes frame counts in elements —
	/// and neither is worth a second parser.
	private final class XMLReader: NSObject, XMLParserDelegate {
		var clips: [ImportedClip] = []

		// FCP7 state: a clipitem is assembled from its children.
		private var element = ""
		private var text = ""
		private var name: String?
		private var inPoint: Double?
		private var outPoint: Double?
		private var timebase: Double = 25
		private var inClipItem = false
		/// FCP7 nests a `<file>` with its own `<name>` inside the clip item;
		/// the clip's own name comes first and must not be overwritten by it.
		private var depthInsideClipItem = 0

		func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
		            qualifiedName: String?, attributes: [String: String] = [:]) {
			element = name
			text = ""

			switch name {
			case "asset-clip", "clip", "ref-clip", "sync-clip", "mc-clip":
				// FCPXML: everything is in the attributes.
				guard let duration = attributes["duration"].flatMap(Self.seconds) else { return }
				let start = attributes["start"].flatMap(Self.seconds) ?? 0
				let title = attributes["name"] ?? "clip \(clips.count + 1)"
				guard duration > 0 else { return }
				clips.append(ImportedClip(name: title, start: start, end: start + duration))
			case "clipitem":
				inClipItem = true
				depthInsideClipItem = 0
				self.name = nil
				inPoint = nil
				outPoint = nil
			default:
				if inClipItem { depthInsideClipItem += 1 }
			}
		}

		// Depth is counted for every element inside a clip item and checked
		// before it is decremented, so `<name>` directly inside the item is
		// depth 1 and the `<name>` inside its `<file>` is depth 2. Without
		// that, a clip called "Intro" ends up named after the camera file it
		// came from, which is the same for every clip in the timeline.

		func parser(_ parser: XMLParser, foundCharacters string: String) {
			text += string
		}

		func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
			let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
			text = ""

			switch name {
			case "timebase":
				if let rate = Double(value), rate > 0 { timebase = rate }
			case "name" where inClipItem && depthInsideClipItem == 1:
				if self.name == nil { self.name = value }
				depthInsideClipItem -= 1
			case "in" where inClipItem:
				inPoint = Double(value)
				depthInsideClipItem -= 1
			case "out" where inClipItem:
				outPoint = Double(value)
				depthInsideClipItem -= 1
			case "clipitem":
				defer { inClipItem = false }
				// -1 is FCP7's "not set", which is what a clip that uses the
				// whole file writes.
				guard let inPoint, let outPoint, outPoint > inPoint, inPoint >= 0 else { return }
				clips.append(ImportedClip(
					name: self.name ?? "clip \(clips.count + 1)",
					start: inPoint / timebase,
					end: outPoint / timebase))
			default:
				if inClipItem, depthInsideClipItem > 0 { depthInsideClipItem -= 1 }
			}
			_ = element
		}

		/// FCPXML times: `3600s`, `1001/30000s`, `0s`.
		static func seconds(_ text: String) -> Double? {
			var s = text
			if s.hasSuffix("s") { s.removeLast() }
			if let slash = s.firstIndex(of: "/") {
				guard let numerator = Double(s[s.startIndex ..< slash]),
				      let denominator = Double(s[s.index(after: slash)...]), denominator != 0
				else { return nil }
				return numerator / denominator
			}
			return Double(s)
		}
	}

	// MARK: - Placing them on the take's clock

	/// Shifts imported clips onto the take's clock when they are plainly not on
	/// it already.
	///
	/// Only when *every* clip lands past the end of the recording, which is what
	/// a camera start timecode looks like and what nothing else does. A set that
	/// already fits is left exactly as it is — a heuristic that fires on correct
	/// input is worse than no heuristic.
	///
	/// Returns the clips and the shift that was applied, so the caller can say
	/// what it did rather than move somebody's cut marks silently.
	public static func rebase(_ clips: [ImportedClip], against duration: Double) -> (clips: [ImportedClip], shift: Double) {
		guard duration > 0, let earliest = clips.map(\.start).min() else { return (clips, 0) }
		guard clips.allSatisfy({ $0.start >= duration }) else { return (clips, 0) }
		let shift = -earliest
		return (clips.map { ImportedClip(name: $0.name, start: $0.start + shift, end: $0.end + shift) }, shift)
	}

	/// Adds imported clips to a take, slugged and uniqued.
	///
	/// Clips that fall outside the recording are dropped rather than clamped: a
	/// mark at a time the recording does not have is not a mark, and silently
	/// moving it to the end would put a clip somewhere nobody chose.
	public static func merge(_ imported: [ImportedClip], into take: Take, duration: Double) -> (take: Take, added: Int, skipped: Int) {
		var next = take
		var added = 0
		var skipped = 0
		for clip in imported {
			guard clip.end > 0, duration <= 0 || clip.start < duration else { skipped += 1; continue }
			next.add(Clip(
				slug: Slug.make(from: clip.name),
				name: clip.name,
				start: max(0, clip.start),
				end: duration > 0 ? min(clip.end, duration) : clip.end))
			added += 1
		}
		return (next, added, skipped)
	}
}
