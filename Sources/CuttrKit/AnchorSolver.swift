@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import Vision

/// Follows a marked point through a clip.
///
/// Two methods, and the first is the one that works on heads. Clicking near an
/// eye does not start a generic tracker on a patch of pixels — it asks Vision
/// for the faces in that frame, takes the one whose eye is nearest the click,
/// and then follows *that landmark* frame by frame. A landmark is re-detected
/// every time rather than propagated, so it does not drift, it survives the head
/// turning, and it comes back after the person walks behind something. A patch
/// tracker does none of those and is the fallback for things that are not faces.
///
/// Sampled at 10 Hz rather than per frame. A head does not move at 25 Hz worth
/// of detail, Vision costs tens of milliseconds a frame, and the interpolation
/// between samples is invisible; per frame it would be three times the work and
/// three times the sidecar for a curve of the same shape.
public enum AnchorError: LocalizedError {
	case noVideoTrack(URL)

	public var errorDescription: String? {
		switch self {
		case .noVideoTrack(let url):
			return "\(url.lastPathComponent) has no video to track anything in."
		}
	}
}

public enum AnchorSolver {

	public static let sampleRate: Double = 10

	public struct Progress: Sendable {
		public let solved: Int
		public let total: Int
		public var fraction: Double { total > 0 ? Double(solved) / Double(total) : 0 }
	}

	/// Follows a marked point outward until the face is lost.
	///
	/// This is what marking does, and it is why an anchor is not tied to a
	/// subclip. What the tracker can follow is a *shot* — from wherever the
	/// point was marked, forward until the person turns away or the camera
	/// cuts, and backward the same. Where the subclip boundaries fall is a
	/// separate decision made later, and one that changes; the shot does not.
	///
	/// Stops after `lossTolerance` consecutive samples with nothing found, so a
	/// blink or a half-second of a turned head does not end it but leaving the
	/// frame does. Bounded by `limit` seconds each way so that marking a face
	/// in a five-minute recording is not a five-minute wait.
	public static func solveShot(
		videoURL: URL,
		method: Anchor.Method,
		markedAt: Double,
		point: CGPoint,
		within bounds: ClosedRange<Double>,
		limit: Double = 90,
		lossTolerance: Int = 15,
		onProgress: @Sendable (Progress) -> Void = { _ in }
	) async throws -> AnchorPath {
		let step = 1 / sampleRate
		let earliest = max(bounds.lowerBound, markedAt - limit)
		let latest = min(bounds.upperBound, markedAt + limit)

		let asset = AVURLAsset(url: videoURL)
		guard try await asset.loadTracks(withMediaType: .video).first != nil else {
			throw AnchorError.noVideoTrack(videoURL)
		}
		let generator = imageGenerator(asset)

		guard let wanted = try? await landmark(nearest: point, in: generator, at: markedAt) else {
			// Nothing to lock on to where they clicked. One sample at the marked
			// point, so the anchor exists and can be re-solved or nudged rather
			// than silently doing nothing.
			return AnchorPath(samples: [(markedAt, point)])
		}

		/// Walks in one direction until the face is lost for long enough.
		func walk(_ direction: Double, stopAt: Double) async -> [(time: Double, point: CGPoint)] {
			var found: [(time: Double, point: CGPoint)] = []
			var last = point
			var misses = 0
			var time = markedAt + direction * step
			let total = max(abs(stopAt - markedAt) / step, 1)
			while direction > 0 ? time <= stopAt : time >= stopAt {
				if Task.isCancelled { return found }
				if let position = try? await landmarkPosition(wanted, in: generator, at: time, near: last) {
					misses = 0
					last = position
					found.append((time, position))
				} else {
					misses += 1
					if misses >= lossTolerance { break }
					// Held rather than dropped: a blink is not the end of a
					// shot, and a hole in the middle of a path is a slide
					// across it at render time.
					found.append((time, last))
				}
				onProgress(Progress(solved: found.count, total: Int(total)))
				time += direction * step
			}
			// The tail of held samples after the last real one is not tracking,
			// it is the tracker having lost the face. Trimmed, so the range says
			// what was actually followed.
			while misses > 0, !found.isEmpty {
				found.removeLast()
				misses -= 1
			}
			return found
		}

		let forward = await walk(1, stopAt: latest)
		let backward = await walk(-1, stopAt: earliest)
		return AnchorPath(samples: backward.reversed() + [(markedAt, point)] + forward)
	}

	private static func imageGenerator(_ asset: AVURLAsset) -> AVAssetImageGenerator {
		let generator = AVAssetImageGenerator(asset: asset)
		generator.appliesPreferredTrackTransform = true
		// Exact frames: a generator allowed to round to the nearest keyframe
		// would return the same picture for several samples and the path would
		// come out as a staircase.
		generator.requestedTimeToleranceBefore = .zero
		generator.requestedTimeToleranceAfter = .zero
		// Downscaled for Vision. Face landmarks do not get better above about
		// 720 across and the request costs roughly the pixel count.
		generator.maximumSize = CGSize(width: 1280, height: 1280)
		return generator
	}

	/// Solves an anchor over an explicit time range.
	///
	/// `from`/`to` are on the take's clock. The returned path is too, so the
	/// sidecar stays meaningful when the clip is trimmed or used twice.
	public static func solve(
		videoURL: URL,
		method: Anchor.Method,
		markedAt: Double,
		point: CGPoint,
		from: Double,
		to: Double,
		onProgress: @Sendable (Progress) -> Void = { _ in }
	) async throws -> AnchorPath {
		let asset = AVURLAsset(url: videoURL)
		guard try await asset.loadTracks(withMediaType: .video).first != nil else {
			throw AnchorError.noVideoTrack(videoURL)
		}
		let generator = imageGenerator(asset)

		let step = 1 / sampleRate
		var times: [Double] = []
		var t = from
		while t <= to { times.append(t); t += step }
		if times.last != to { times.append(to) }

		// Which eye, decided once, at the frame the operator was looking at.
		var wanted: Landmark? = method == .faceLandmark
			? try? await landmark(nearest: point, in: generator, at: markedAt)
			: nil

		var samples: [(time: Double, point: CGPoint)] = []
		var last = point
		for (index, time) in times.enumerated() {
			if Task.isCancelled { throw CancellationError() }
			var found: CGPoint?
			if method == .faceLandmark, let wanted {
				found = try? await landmarkPosition(wanted, in: generator, at: time, near: last)
			}
			if found == nil {
				// No face this frame — somebody turned away, or it is not a face
				// at all. Holding the last position is the honest answer and is
				// what the interpolation will smooth over; guessing a new one is
				// how a spinner ends up on a lamp.
				found = last
				if method == .faceLandmark, wanted == nil {
					wanted = try? await landmark(nearest: last, in: generator, at: time)
				}
			}
			last = found ?? last
			samples.append((time, last))
			onProgress(Progress(solved: index + 1, total: times.count))
		}
		return AnchorPath(samples: samples)
	}

	/// What Vision can see at one moment, for answering "is there a face here
	/// for the tracker to lock on to?" before spending a minute finding out.
	public struct FaceReport: Sendable {
		public let boundingBox: CGRect
		public let leftEye: CGPoint?
		public let rightEye: CGPoint?
		public let nose: CGPoint?
	}

	public static func faces(videoURL: URL, at time: Double) async throws -> [FaceReport] {
		let asset = AVURLAsset(url: videoURL)
		guard try await asset.loadTracks(withMediaType: .video).first != nil else {
			throw AnchorError.noVideoTrack(videoURL)
		}
		let generator = AVAssetImageGenerator(asset: asset)
		generator.appliesPreferredTrackTransform = true
		generator.requestedTimeToleranceBefore = .zero
		generator.requestedTimeToleranceAfter = .zero
		generator.maximumSize = CGSize(width: 1280, height: 1280)
		guard let observations = try await detect(generator, at: time) else { return [] }
		return observations.map { face in
			FaceReport(
				boundingBox: face.boundingBox,
				leftEye: position(of: .leftEye, in: face),
				rightEye: position(of: .rightEye, in: face),
				nose: position(of: .nose, in: face))
		}
	}

	/// Which face, and which of its landmarks, the click meant.
	private struct Landmark: Sendable {
		enum Which: Sendable { case leftEye, rightEye, nose, centre }
		let which: Which
	}

	private static func landmark(
		nearest point: CGPoint, in generator: AVAssetImageGenerator, at time: Double
	) async throws -> Landmark? {
		guard let faces = try await detect(generator, at: time), !faces.isEmpty else { return nil }
		var best: (Landmark, Double)?
		for face in faces {
			for which in [Landmark.Which.leftEye, .rightEye, .nose, .centre] {
				guard let candidate = position(of: which, in: face) else { continue }
				let distance = hypot(candidate.x - point.x, candidate.y - point.y)
				if best == nil || distance < best!.1 { best = (Landmark(which: which), distance) }
			}
		}
		// A click that is nowhere near any face is not a request to track the
		// far side of the frame.
		guard let best, best.1 < 0.2 else { return nil }
		return best.0
	}

	private static func landmarkPosition(
		_ wanted: Landmark, in generator: AVAssetImageGenerator, at time: Double, near previous: CGPoint
	) async throws -> CGPoint? {
		guard let faces = try await detect(generator, at: time) else { return nil }
		// The nearest face to where it was, which is what keeps the right person
		// when there are two in shot.
		var best: (CGPoint, Double)?
		for face in faces {
			guard let candidate = position(of: wanted.which, in: face) else { continue }
			let distance = hypot(candidate.x - previous.x, candidate.y - previous.y)
			if best == nil || distance < best!.1 { best = (candidate, distance) }
		}
		// A jump of more than a fifth of the frame between two samples a tenth
		// of a second apart is a different face, not the same one moving.
		guard let best, best.1 < 0.2 else { return nil }
		return best.0
	}

	private static func detect(
		_ generator: AVAssetImageGenerator, at time: Double
	) async throws -> [VNFaceObservation]? {
		let cmTime = CMTime(seconds: time, preferredTimescale: 600)
		guard let image = try? await generator.image(at: cmTime).image else { return nil }
		let request = VNDetectFaceLandmarksRequest()
		// Vision's coordinates are already normalised with the origin at the
		// bottom left, which is what the rest of this program uses, so nothing
		// is flipped anywhere in here.
		let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
		try handler.perform([request])
		return request.results
	}

	private static func position(of which: Landmark.Which, in face: VNFaceObservation) -> CGPoint? {
		let box = face.boundingBox
		func inFrame(_ region: VNFaceLandmarkRegion2D?) -> CGPoint? {
			guard let region, region.pointCount > 0 else { return nil }
			// Landmarks are normalised inside the face's own box, so they have
			// to be put back into the frame before they mean anything.
			let points = region.normalizedPoints
			let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + CGFloat($1.x), y: $0.y + CGFloat($1.y)) }
			let middle = CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
			return CGPoint(x: box.minX + middle.x * box.width, y: box.minY + middle.y * box.height)
		}
		switch which {
		case .leftEye: return inFrame(face.landmarks?.leftEye)
		case .rightEye: return inFrame(face.landmarks?.rightEye)
		case .nose: return inFrame(face.landmarks?.nose)
		case .centre: return CGPoint(x: box.midX, y: box.midY)
		}
	}
}
