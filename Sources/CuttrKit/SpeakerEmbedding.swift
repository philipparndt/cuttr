import CoreML
import Foundation

/// A speaker-embedding network, if somebody has fetched one.
///
/// **This program does not ship a model and does not download one behind
/// anybody's back.** There is no blob in the repository and nothing here
/// reaches the network: it looks in one folder, and if the file is not there
/// the method is not offered and everything else works exactly as before.
/// Automatic assignment is an offer, never a requirement.
///
/// Fetching one is an explicit act — `Scripts/fetch-speaker-model.sh`, which
/// names the licence before it downloads anything and puts the result in
/// ``folder``. The reason it is separate is that a model has a licence and a
/// licence is a decision somebody makes about their own work, not a decision a
/// build script makes for them.
///
/// **What it wants.** A compiled Core ML model (`.mlmodelc`) taking a mono
/// 16 kHz waveform and giving back one vector per utterance — an x-vector or
/// an ECAPA-TDNN embedding, 192 or 512 wide. Those vectors are compared by
/// angle, never by distance: the length of one says how loud the microphone
/// was.
public enum SpeakerEmbedding {

	public struct Sample: Sendable {
		public let start: Double
		public let end: Double
		/// The embedding, or empty when the span could not be measured.
		public let features: [Double]

		public init(start: Double, end: Double, features: [Double]) {
			self.start = start
			self.end = end
			self.features = features
		}
	}

	public enum Trouble: LocalizedError {
		case noModel(URL)
		case unusable(String)

		public var errorDescription: String? {
			switch self {
			case .noModel(let url):
				return "There is no speaker-embedding model at \(url.path)."
					+ " cuttr does not ship one and will not fetch one by itself:"
					+ " Scripts/fetch-speaker-model.sh names the licence and downloads it."
			case .unusable(let why):
				return "That speaker-embedding model could not be used: \(why)"
			}
		}
	}

	/// Where a fetched model goes. Under Application Support rather than in the
	/// bundle, because the bundle is signed and this is somebody's own file.
	public static var folder: URL {
		let support = FileManager.default.urls(for: .applicationSupportDirectory,
		                                       in: .userDomainMask).first
			?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
		return support.appendingPathComponent("cuttr/models", isDirectory: true)
	}

	public static var modelURL: URL {
		folder.appendingPathComponent("speaker-embedding.mlmodelc")
	}

	/// Whether the method can be offered at all. Checked before the menu item
	/// is drawn, so nobody is offered something that will fail.
	public static var isAvailable: Bool {
		FileManager.default.fileExists(atPath: modelURL.path)
	}

	/// What licence the fetched model came under, as the fetch script wrote it
	/// down beside the model. Shown wherever the model is, because a model
	/// whose terms nobody can find is a model nobody can ship.
	public static var licence: String? {
		try? String(contentsOf: folder.appendingPathComponent("LICENCE.txt"), encoding: .utf8)
	}

	/// One embedding per span.
	public static func measure(
		url: URL, spans: [(start: Double, end: Double)], offset: Double = 0
	) async throws -> [Sample] {
		guard isAvailable else { throw Trouble.noModel(modelURL) }
		let configuration = MLModelConfiguration()
		// The neural engine when there is one, and nowhere else: this is a
		// twenty-megabyte network over sixty spans, and it should not be a
		// reason for the fans to come on.
		configuration.computeUnits = .all
		let model: MLModel
		do { model = try MLModel(contentsOf: modelURL, configuration: configuration) }
		catch { throw Trouble.unusable(error.localizedDescription) }

		guard let input = model.modelDescription.inputDescriptionsByName.keys.sorted().first,
		      let output = model.modelDescription.outputDescriptionsByName.keys.sorted().first
		else { throw Trouble.unusable("it has no input or no output") }

		let samples = try await VoiceTimbre.decode(url: url)
		let rate = VoiceTimbre.rate
		var out: [Sample] = []
		for span in spans {
			let from = Swift.max(0, Int(((span.start - offset) * rate).rounded()))
			let to = Swift.min(samples.count, Int(((span.end - offset) * rate).rounded()))
			guard to - from >= Int(rate * 0.4) else {
				out.append(Sample(start: span.start, end: span.end, features: []))
				continue
			}
			let slice = Array(samples[from ..< to])
			guard let array = try? MLMultiArray(shape: [1, NSNumber(value: slice.count)],
			                                    dataType: .float32) else {
				out.append(Sample(start: span.start, end: span.end, features: []))
				continue
			}
			for (index, value) in slice.enumerated() { array[index] = NSNumber(value: value) }
			guard let features = try? MLDictionaryFeatureProvider(dictionary: [input: array]),
			      let result = try? await model.prediction(from: features),
			      let vector = result.featureValue(for: output)?.multiArrayValue else {
				out.append(Sample(start: span.start, end: span.end, features: []))
				continue
			}
			var embedding = [Double](repeating: 0, count: vector.count)
			for index in 0 ..< vector.count { embedding[index] = vector[index].doubleValue }
			out.append(Sample(start: span.start, end: span.end, features: embedding))
		}
		return out
	}
}
