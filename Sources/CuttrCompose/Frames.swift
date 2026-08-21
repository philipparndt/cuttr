import CoreGraphics
import Foundation
import ImageIO

/// A folder of numbered pictures, played over the cut.
///
/// The one overlay kind that draws nothing of its own. Everything else here —
/// a caption, a scene, a bubble, a shower of confetti — is a description of
/// something and a drawing of it; this is the drawing arriving already done,
/// and all the compositor does is put it where the file says.
///
/// **Why that is worth a kind of its own.** Sooner or later somebody wants a
/// picture on the frame that no sane part kind covers: a chart of the year's
/// walks, a map with a route drawn on it, a leaderboard, something out of
/// Blender, something out of a browser. The vocabulary in this format is
/// deliberately small, and the honest answer for those is not to grow it but to
/// take pixels. Once the pixels are on disk it makes no difference at all what
/// made them, which is why this kind knows nothing about any of it — see
/// `docs/remotion.md`, where the argument is written out.
///
/// **A folder, not a printf pattern, and the frames are the ones that are
/// there.** The sequence is every file in the folder whose name carries a
/// number and a picture's extension, sorted by that number; frame *n* of the
/// sequence is the *n*th of those. So there is no such thing as a frame missing
/// from the middle. A render that stopped after six hundred of a thousand is a
/// six-hundred-frame sequence, and ``ends`` already says what a sequence that
/// runs out does.
///
/// The alternative was `chart/%04d.png`, which reads a numbering *claim* out of
/// the file and then has to decide what to do where the folder does not meet it
/// — hold the frame before the hole, or blank it. Both of those are one frame
/// nobody can see; so is the shift this produces instead. The difference is
/// that this one costs no grammar, cannot be written down wrongly, and does not
/// care whether the thing that made the frames counted from nought or from one,
/// or called them `element-0001.png` or `0001.png`. What *is* worth saying out
/// loud is how many frames there are, and `cuttr-render --describe` says it.
public struct Frames: Sendable, Equatable {

	/// The folder, relative to the project file — as `image:` and `file:` are.
	public var folder: String

	/// How fast the sequence runs, in frames a second.
	///
	/// Stated in the file and never guessed. A sequence carries no rate of its
	/// own — a folder of pictures is a folder of pictures — and the two numbers
	/// it might be defaulted to are both wrong: the output's rate is a fact
	/// about the encode, and twenty-five is a fact about nothing. Guessing it
	/// shows as an animation running at some ratio of the speed it was drawn
	/// at, which is exactly the kind of wrongness nobody thinks to look for. So
	/// the reader refuses a sequence that does not say.
	public var framesPerSecond: Double

	/// How tall it is drawn, as a fraction of the frame height. The width
	/// follows the pictures' own shape, so nothing is ever squashed.
	///
	/// One by default, which for a sequence rendered at the output's own size is
	/// exactly over the frame — the common case for something with an alpha
	/// channel, and the case where the answer should need no arithmetic.
	public var size: Double

	/// What happens when the sequence runs out before the overlay does.
	public var ends: Ends

	/// Two answers, and a third that is deliberately not here.
	///
	/// - ``hold`` — the last frame stays on. What a projector does, and the
	///   default: a chart that has finished drawing itself should go on being a
	///   chart.
	/// - ``loop`` — back to the first frame. For the things that are made to go
	///   round: a rotating globe, a texture, an equaliser.
	///
	/// **Why there is no `stretch`.** Fitting the sequence's own length to the
	/// span would re-time somebody else's animation from a fact about the *cut*
	/// — so trimming a shot by two frames would silently change the speed of
	/// every chart on it, and the same project would render different frames
	/// after a re-cut. That is the one thing this format's design does not
	/// allow, so `ends: stretch` is refused by name with that sentence rather
	/// than left out and read as a typo.
	public enum Ends: String, Sendable, CaseIterable {
		case hold, loop
	}

	public init(
		folder: String, framesPerSecond: Double, size: Double = 1, ends: Ends = .hold
	) {
		self.folder = folder
		self.framesPerSecond = framesPerSecond
		self.size = size
		self.ends = ends
	}

	/// Which picture is on screen `elapsed` seconds into the overlay, out of
	/// `count` of them, or `nil` when there is nothing to show.
	///
	/// Timed from the start of the overlay's **span**, not from its first drawn
	/// frame, exactly as a scene's keys and an overlay's own keys are: adding
	/// `at: before` to an `in:` is a one-word edit and must not re-time the
	/// animation. On the frames before the mark the sequence holds its first
	/// picture, which is what `fillMode: .both` does on the layer side.
	///
	/// Both render paths ask this, so a chart is on the same frame of itself in
	/// the preview and in the export.
	public func frame(at elapsed: Double, of count: Int) -> Int? {
		guard count > 0, framesPerSecond > 0 else { return nil }
		let step = Int((max(0, elapsed) * framesPerSecond).rounded(.down))
		switch ends {
		case .hold: return min(step, count - 1)
		case .loop: return step % count
		}
	}

	/// How long the sequence itself lasts. What an editor with nothing else to
	/// go on has to guess a span from, and what ``Ends`` is about the end of.
	public func duration(of count: Int) -> Double {
		framesPerSecond > 0 ? Double(count) / framesPerSecond : 0
	}

	/// What is actually in the folder: how many pictures, how big they are, and
	/// how long they run for.
	///
	/// The answer to "why is my chart not there", which is why `cuttr-render
	/// --describe` prints it and why it is public. A sequence is the one kind of
	/// overlay whose contents are outside the project file, and the format's own
	/// standard for that is the resolver naming a missing take rather than
	/// rendering a black stretch and saying nothing.
	public func found(relativeTo baseURL: URL) -> (count: Int, pixels: CGSize, seconds: Double) {
		let listing = FrameFolder.listing(folder, relativeTo: baseURL)
		return (listing.count, listing.pixels, duration(of: listing.count))
	}
}

/// The pictures in a folder, found once and handed to both render paths.
///
/// **Both paths get the same `CGImage`, and neither of them touches its
/// pixels.** That is the whole point of the frames-on-disk shape: the drawing
/// happened elsewhere, so there is nothing here for two implementations to
/// disagree about — the painter hands the image to Core Image and the layer
/// tree hands the same object to Core Animation, and each of those premultiplies
/// from the image's own `alphaInfo`.
///
/// That last sentence is measured rather than assumed, because getting it wrong
/// is the classic way an overlay with soft edges comes out with a dark fringe
/// round it. A PNG read back through ImageIO reports `alphaInfo == .last`, which
/// is *straight* alpha; pure white at half alpha over black comes out at 128 in
/// both paths, byte for byte. `bothPathsAgreeOnAHalfCoveredPixel` holds that
/// number, so nobody has to premultiply anything by hand — and if a future
/// framework stops doing it, the test says so rather than the render.
///
/// **Nothing is decoded until it is drawn.** The images are made with
/// `kCGImageSourceShouldCache` off, so each one carries the file's compressed
/// bytes and is decoded by whichever framework is about to draw it. A thousand
/// 1920×1080 bitmaps is eight gigabytes; a thousand PNGs of the same is a few
/// hundred megabytes of mapped file, and only the handful in flight is ever a
/// bitmap. It is also what makes the layer path affordable at all, since a
/// keyframe animation over `contents` holds every value it will ever show.
enum FrameFolder {

	/// One folder, as it was found: the pictures in order, and the shape of the
	/// first of them.
	struct Listing {
		var urls: [URL]
		/// The first picture's size in pixels, which is the shape the whole
		/// sequence is drawn at. Read from the file's header rather than by
		/// decoding it.
		var pixels: CGSize
		var count: Int { urls.count }
	}

	private static let lock = NSLock()
	private nonisolated(unsafe) static var listings: [String: Listing] = [:]
	private nonisolated(unsafe) static var images: [String: CGImage] = [:]

	/// The extensions a picture in a sequence may have.
	///
	/// PNG first because it is the only one of them with an alpha channel worth
	/// having, and a sequence laid over a shot is nearly always a sequence with
	/// transparency in it. The rest are here so that a folder of stills off a
	/// camera is a sequence too.
	static let extensions: Set<String> = ["png", "tif", "tiff", "jpg", "jpeg", "heic", "webp"]

	/// The sequence in a folder, listed once per folder per run.
	///
	/// Cached because the preview asks for a frame every time the playhead
	/// moves and a render asks once per frame of the programme, and neither
	/// wants a directory scan for it. The cost of that is a folder re-rendered
	/// while the app is open: the file names are remembered and the pictures
	/// behind them are not, so a re-render of the *same* frames shows through
	/// and one that produces a different number of them does not. That is the
	/// staleness `docs/remotion.md` says a component part would have to warn
	/// about, met here at its cheapest — a sequence is material, and reopening
	/// the project is how material is re-read.
	static func listing(_ folder: String, relativeTo baseURL: URL) -> Listing {
		let url = URL(fileURLWithPath: folder, relativeTo: baseURL)
		let key = url.standardizedFileURL.path
		lock.lock()
		if let found = listings[key] {
			lock.unlock()
			return found
		}
		lock.unlock()

		let names = (try? FileManager.default.contentsOfDirectory(atPath: key)) ?? []
		let numbered = names
			.filter { extensions.contains(($0 as NSString).pathExtension.lowercased()) }
			.compactMap { name -> (number: Int, name: String)? in
				number(in: name).map { ($0, name) }
			}
			// By the number in the name, and by the name where two share one —
			// so the order is settled rather than merely consistent, and a
			// folder holding `0001.png` beside `0001.tif` does not shuffle
			// between runs.
			.sorted { $0.number == $1.number ? $0.name < $1.name : $0.number < $1.number }
		let urls = numbered.map { url.appendingPathComponent($0.name) }
		let built = Listing(urls: urls, pixels: urls.first.map(pixels(of:)) ?? .zero)
		lock.lock()
		listings[key] = built
		lock.unlock()
		return built
	}

	/// The last run of digits in a name, which is where every renderer that
	/// writes a sequence puts the frame number: `element-0042.png`, `0042.png`,
	/// `render_v2_0042.png`. The *last* run, so the `2` in `v2` is not mistaken
	/// for it.
	static func number(in name: String) -> Int? {
		let stem = (name as NSString).deletingPathExtension
		var digits = ""
		for character in stem.reversed() {
			if character.isNumber {
				digits.append(character)
			} else if !digits.isEmpty {
				break
			}
		}
		return digits.isEmpty ? nil : Int(String(digits.reversed()))
	}

	/// One picture of the sequence, lazily decoded, remembered by path.
	static func image(_ index: Int, in listing: Listing) -> CGImage? {
		guard listing.urls.indices.contains(index) else { return nil }
		let url = listing.urls[index]
		let key = url.path
		lock.lock()
		if let found = images[key] {
			lock.unlock()
			return found
		}
		lock.unlock()
		guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
		      let made = CGImageSourceCreateImageAtIndex(
			      source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
		else { return nil }
		lock.lock()
		images[key] = made
		lock.unlock()
		return made
	}

	/// The box a sequence is drawn in: as tall as `size` says, as wide as the
	/// pictures are shaped.
	///
	/// Both paths ask this, so the chart in the preview is the chart in the
	/// export down to the pixel. A folder with nothing in it has no shape, so it
	/// gets the frame's — there is nothing to draw in it either way.
	static func box(_ frames: Frames, pixels: CGSize, frame: CGSize) -> CGSize {
		let height = max(1, frames.size * frame.height)
		guard pixels.width > 0, pixels.height > 0 else {
			return CGSize(width: max(1, frames.size * frame.width), height: height)
		}
		return CGSize(width: height * (pixels.width / pixels.height), height: height)
	}

	/// A picture's size without decoding it. The header of a PNG is a few dozen
	/// bytes and the picture is a few hundred kilobytes.
	private static func pixels(of url: URL) -> CGSize {
		guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
		      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
			      as? [CFString: Any],
		      let width = properties[kCGImagePropertyPixelWidth] as? Int,
		      let height = properties[kCGImagePropertyPixelHeight] as? Int
		else { return .zero }
		return CGSize(width: width, height: height)
	}

	/// Everything remembered about every folder, forgotten. For the tests,
	/// which write a sequence, read it, write a different one to the same place
	/// and read that.
	static func forgetEverything() {
		lock.lock()
		listings.removeAll()
		images.removeAll()
		lock.unlock()
	}
}
