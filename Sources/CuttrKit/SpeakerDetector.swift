@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import Vision

/// Who is talking.
///
/// **An anchor is a person.** A tracked face already has a name and a path
/// through the recording, so naming somebody is renaming their anchor to `mia`,
/// and there is no second list of people to keep in step with the first.
///
/// The method is mouth movement, not sound. Telling voices apart from audio is
/// speaker diarisation, which needs a model, training data and a good deal of
/// hope; telling *which face in shot is moving its mouth* needs the landmarks
/// Vision already returns for the tracking. It is wrong in the cases you would
/// expect — somebody chewing, somebody off-camera — and right in the case that
/// matters, which is two people in a two-shot taking turns.
public enum SpeakerDetector {

	public struct Candidate: Sendable {
		public let name: String
		public let path: AnchorPath

		public init(name: String, path: AnchorPath) {
			self.name = name
			self.path = path
		}
	}

	public struct Finding: Sendable {
		public let name: String
		/// How much their mouth moved, in face heights per sample. Reported so
		/// a caller can say "probably" rather than "definitely".
		public let movement: Double
		/// How far ahead of the next candidate. 1 means a tie.
		public let margin: Double
	}

	/// Samples at this rate. Speech opens and closes a mouth several times a
	/// second; ten samples a second catches that without decoding every frame.
	private static let sampleRate: Double = 10
	private static let maximumSamples = 80

	/// A mouth that moves less than this is a face, not a speaker.
	private static let stillness = 0.006
	/// And it has to beat the runner-up by this much to be worth naming.
	private static let decisiveness = 1.25

	/// Who, of these people, is talking between `from` and `to`.
	///
	/// `nil` when nobody is moving enough, or when two candidates are too close
	/// to call. Declining to answer is the point: a clip named after the wrong
	/// person is worse than one called `clip-4`, because the wrong name is
	/// believed.
	public static func speaking(
		videoURL: URL, among candidates: [Candidate], from: Double, to: Double
	) async throws -> Finding? {
		guard candidates.count >= 1, to > from else { return nil }
		let asset = AVURLAsset(url: videoURL)
		guard try await asset.loadTracks(withMediaType: .video).first != nil else {
			throw AnchorError.noVideoTrack(videoURL)
		}
		let generator = AVAssetImageGenerator(asset: asset)
		generator.appliesPreferredTrackTransform = true
		generator.requestedTimeToleranceBefore = .zero
		generator.requestedTimeToleranceAfter = .zero
		generator.maximumSize = CGSize(width: 1280, height: 1280)

		let count = min(Int((to - from) * sampleRate), maximumSamples)
		guard count >= 4 else { return nil }

		// One series of mouth openings per candidate.
		var openings = [[Double]](repeating: [], count: candidates.count)
		for index in 0 ..< count {
			if Task.isCancelled { return nil }
			let time = from + (to - from) * Double(index) / Double(count - 1)
			guard let image = try? await generator.image(
				at: CMTime(seconds: time, preferredTimescale: 600)).image else { continue }
			let request = VNDetectFaceLandmarksRequest()
			try? VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
			guard let faces = request.results, !faces.isEmpty else { continue }

			for (candidate, person) in candidates.enumerated() {
				guard let expected = person.path.point(at: time),
				      person.path.covers(time),
				      let face = nearest(faces, to: expected),
				      let opening = mouthOpening(face)
				else { continue }
				openings[candidate].append(opening)
			}
		}

		// Movement, not openness: a wide smile held for a second is a big mouth
		// that is not saying anything. What speech looks like is the *change*
		// from one sample to the next.
		var scores: [(name: String, movement: Double)] = []
		for (index, series) in openings.enumerated() where series.count >= 4 {
			var total = 0.0
			for step in 1 ..< series.count { total += abs(series[step] - series[step - 1]) }
			scores.append((candidates[index].name, total / Double(series.count - 1)))
		}
		scores.sort { $0.movement > $1.movement }

		guard let best = scores.first, best.movement > stillness else { return nil }
		let runnerUp = scores.count > 1 ? scores[1].movement : 0
		let margin = runnerUp > 0 ? best.movement / runnerUp : .infinity
		guard margin >= decisiveness else { return nil }
		return Finding(name: best.name, movement: best.movement, margin: margin)
	}

	/// The face whose eyes are nearest where this person is expected to be.
	private static func nearest(_ faces: [VNFaceObservation], to point: CGPoint) -> VNFaceObservation? {
		var best: (VNFaceObservation, Double)?
		for face in faces {
			let box = face.boundingBox
			let centre = CGPoint(x: box.midX, y: box.midY)
			// Generous: the anchor is on an eye and this is the middle of the
			// head, so half a face-height apart is still the same person.
			let distance = hypot(centre.x - point.x, centre.y - point.y)
			if distance < max(box.height, 0.05), best == nil || distance < best!.1 {
				best = (face, distance)
			}
		}
		return best?.0
	}

	/// How open the mouth is, in face heights.
	private static func mouthOpening(_ face: VNFaceObservation) -> Double? {
		guard let lips = face.landmarks?.innerLips, lips.pointCount > 2 else { return nil }
		let ys = lips.normalizedPoints.map { Double($0.y) }
		guard let low = ys.min(), let high = ys.max() else { return nil }
		// Already in the face box's own space, so it is scale-free: somebody
		// further from the camera does not read as quieter.
		return high - low
	}
}
