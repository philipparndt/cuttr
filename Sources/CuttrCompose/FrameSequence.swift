import CoreGraphics
import Foundation
import ImageIO

/// A folder of frames, put on the picture one per frame.
///
/// The one part kind with no drawing in it. Whatever made the frames — a
/// `component:` this program bakes, a Blender render, a Python script that
/// plotted something — the drawing is over by the time this is asked, and all
/// that is left is to composite the result. That is why this exists rather than
/// a third way of drawing: `docs/remotion.md` is blunt about the cost of a part
/// kind implemented twice, and this is the shape that avoids it.
///
/// It goes further than that, in fact: a scene holding one of these is painted
/// rather than layered, so there is not even a second *compositing* of it. The
/// preview and the export both read frame *n* off the disk through the painter,
/// and there is nothing for two paths to disagree about because there is one.
/// ``OverlayLayers/isLayered(_:in:)`` is where that is decided and why.
///
///     - frames: charts/walks/%04d.png
///       fps:    25
///       keys:
///         - {t: 0, x: 0.5, y: 0.5, width: 0.7, height: 0.5, opacity: 0}
///         - {t: 0.6, opacity: 1, ease: out}
///
/// Everything else about the part is what every part gets: it is positioned,
/// scaled, turned and faded by its keys, and it composites through the person
/// mask, film mode, the tape and the grade in the order the file lists them.
public struct FrameSequence: Sendable, Equatable {

	/// A `printf` pattern relative to the project file: `charts/walks/%04d.png`.
	///
	/// A pattern rather than a folder, because a folder does not say how the
	/// files are named and half the tools that write frame sequences pad
	/// differently. `%d`, `%04d` and `%05d` all read.
	public var pattern: String

	/// The rate the frames were made at, which need not be the rate the
	/// programme comes out at. A sequence baked at 25 on a 50 fps render holds
	/// each frame for two, which is what a sequence baked at 25 *is*.
	public var fps: Double

	public init(pattern: String, fps: Double) {
		self.pattern = pattern
		self.fps = fps
	}

	/// Which frame is showing, `seconds` into the part's own life.
	///
	/// Rounded down, so frame nought is on screen for the whole of the first
	/// 1/fps of a second rather than for half of it.
	public func index(at seconds: Double) -> Int {
		max(0, Int((seconds * fps).rounded(.down)))
	}

	/// Where frame `index` is, relative to the project file.
	public func url(forFrame index: Int, relativeTo base: URL) -> URL {
		URL(fileURLWithPath: Self.expand(pattern, index), relativeTo: base)
	}

	/// The pattern with the number in it.
	///
	/// Hand-written rather than handed to `String(format:)`, which would take a
	/// pattern out of a project file straight to a format string — and a `%s`
	/// somebody typed by accident would then read a pointer.
	static func expand(_ pattern: String, _ index: Int) -> String {
		guard let percent = pattern.firstIndex(of: "%") else { return pattern }
		var digits = ""
		var cursor = pattern.index(after: percent)
		while cursor < pattern.endIndex, pattern[cursor].isNumber {
			digits.append(pattern[cursor])
			cursor = pattern.index(after: cursor)
		}
		// Only `d` is a frame number. Anything else is left alone, which makes
		// a mistyped pattern a file that is not there — reported as a missing
		// frame — rather than something surprising.
		guard cursor < pattern.endIndex, pattern[cursor] == "d" else { return pattern }
		let width = Int(digits) ?? 0
		var number = String(index)
		while number.count < width { number = "0" + number }
		return String(pattern[pattern.startIndex ..< percent]) + number
			+ String(pattern[pattern.index(after: cursor)...])
	}

	/// How many frames are actually there, counted from nought until one is
	/// missing.
	///
	/// Counted rather than declared, because the count is a fact about the
	/// folder and a declared one goes stale. The walk stops at the first gap: a
	/// sequence with a hole in it is a sequence that ends at the hole, which is
	/// visible and therefore fixable, where skipping the gap would silently
	/// shorten the animation.
	///
	/// Counted once and remembered, because the painter asks for this on every
	/// frame it draws and three hundred `stat` calls per drawn frame is a
	/// preview that stutters over a sequence. ``Reel/empty()`` forgets it, which
	/// is what a fresh bake does.
	public func count(relativeTo base: URL) -> Int {
		Reel.shared.count(of: self, relativeTo: base)
	}

	/// Frame `index`, or the last one there is.
	///
	/// Held at the end rather than disappearing, which is the rule keyframes
	/// already follow — a key holds its value for ever after the last one — and
	/// a sequence that vanished a frame early would read as a bug in the cut.
	public func image(at seconds: Double, relativeTo base: URL, frames: Int) -> CGImage? {
		guard frames > 0 else { return nil }
		let wanted = min(index(at: seconds), frames - 1)
		return Reel.shared.image(at: url(forFrame: wanted, relativeTo: base))
	}
}

public extension Scene {

	/// Whether anything in this scene arrives as pixels.
	///
	/// The one question that decides which of the two render passes a scene goes
	/// through, so both the builder and the panel that reports it ask this rather
	/// than working it out. See ``OverlayLayers/isLayered(_:in:)``.
	var hasFrames: Bool {
		// The rate is asked for and thrown away: what is wanted is whether a
		// part *has* a sequence, and every part that has one has it at every
		// rate. One accessor rather than two that could disagree.
		parts.contains { $0.content.sequence(at: 1) != nil }
	}
}

/// The frames, decoded, and the last few kept.
///
/// The preview asks the painter for a frame every time anything is redrawn, and
/// dragging a playhead over a second of a sequence asks for the same handful of
/// files over and over. Decoding a 1080p PNG is about ten milliseconds, which is
/// most of a preview's budget spent on work already done — so the last few are
/// kept and nothing else is.
///
/// Small on purpose, and it is what makes the export affordable. Holding a whole
/// sequence is four gigabytes for twenty seconds at 1080p, which was measured at
/// eight when Core Animation was doing the holding; eight frames is forty
/// megabytes and a renderer walking forward through a sequence never wants more
/// than the one it is on.
final class Reel: @unchecked Sendable {
	static let shared = Reel()

	private let lock = NSLock()
	private var order: [String] = []
	private var images: [String: CGImage] = [:]
	private var counts: [String: Int] = [:]
	private let keep = 8

	/// How many frames a sequence has, counted from nought until one is missing.
	func count(of sequence: FrameSequence, relativeTo base: URL) -> Int {
		let key = sequence.url(forFrame: 0, relativeTo: base).standardizedFileURL.path
		lock.lock()
		if let found = counts[key] {
			lock.unlock()
			return found
		}
		lock.unlock()

		var found = 0
		let manager = FileManager.default
		// A hundred thousand is not a limit anybody reaches; it is there so that
		// a pattern with no `%d` in it — which expands to the same path every
		// time — stops instead of counting for ever.
		while found < 100_000,
		      manager.fileExists(atPath: sequence.url(forFrame: found, relativeTo: base).path) {
			found += 1
			if !sequence.pattern.contains("%") { break }
		}

		lock.lock()
		counts[key] = found
		lock.unlock()
		return found
	}

	func image(at url: URL) -> CGImage? {
		let key = url.standardizedFileURL.path
		lock.lock()
		if let found = images[key] {
			lock.unlock()
			return found
		}
		lock.unlock()

		guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
		      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }

		lock.lock()
		images[key] = image
		order.append(key)
		while order.count > keep { images.removeValue(forKey: order.removeFirst()) }
		lock.unlock()
		return image
	}

	/// Forgets everything, which is what a fresh bake means: the files at those
	/// paths are different files now.
	func empty() {
		lock.lock()
		images = [:]
		order = []
		counts = [:]
		lock.unlock()
	}
}

public extension Scene.Part.Content {

	/// The frames this part is, wherever they came from — `nil` for a part that
	/// is drawn rather than composited.
	///
	/// The single line that keeps `component:` from being a second way of
	/// drawing. A component's frames are on disk under a name derived from the
	/// component, so by the time the painter or the layer builder asks, the two
	/// keys are the same part and there is one implementation of it. The rate is
	/// the output's, because that is what the bake was made at and what its
	/// fingerprint records.
	func sequence(at fps: Double) -> FrameSequence? {
		switch self {
		case .frames(let sequence): return sequence
		case .component(let component): return component.sequence(at: fps)
		case .text, .shape, .bar, .spinner, .roll, .image, .background: return nil
		}
	}
}
