import AVFoundation
import CoreImage
import CuttrKit
import Foundation

/// The one place a frame of the programme is made.
///
/// It exists because of dissolves. Everything else this program draws — the
/// grade, the fit, the effects, the overlays that go behind somebody — needs
/// one source frame and can be done with a Core Image filter composition. A
/// dissolve needs *two*: the shot going out and the shot coming in, at the same
/// moment, which that composition cannot hand over. A compositor can.
///
/// So the work moved here rather than being split between two mechanisms.
/// AVFoundation asks for a frame, this fetches whichever tracks the instruction
/// names, grades each with its own clip's look, blends them, and lays the rest
/// over the top. The preview plays the same composition, so what is scrubbed
/// and what is written are made by the same code — which is the point of the
/// whole file.
final class ProgrammeCompositor: NSObject, AVVideoCompositing {

	/// Everything a render needs that cannot be put in an instruction.
	///
	/// AVFoundation makes the compositor itself, from a class, so there is
	/// nowhere to hand it anything: the instructions carry an id and the work is
	/// looked up here. Kept behind a lock because a compositor is asked for
	/// frames from several threads.
	struct Work {
		let size: CGSize
		let project: Project
		let baseURL: URL
		let overlays: [ResolvedOverlay]
		let effects: [(overlay: ResolvedOverlay, renderer: EffectRenderer)]
		let people: PersonMask?

		/// Whether anything is being drawn into the frame at this moment.
		func busy(at time: Double) -> Bool {
			if effects.contains(where: { time >= $0.overlay.start && time <= $0.overlay.end }) {
				return true
			}
			return overlays.contains { shown in
				guard time >= shown.start, time <= shown.end else { return false }
				if shown.overlay.behind == .people { return true }
				// Film mode, the aberration and the tape change the frame
				// itself, so a frame any of them is on is a frame that cannot
				// be handed back as it came.
				return shown.overlay.kind.changesTheFrame
			}
		}
	}

	private static let lock = NSLock()
	private nonisolated(unsafe) static var sessions: [UUID: Work] = [:]

	static func register(_ work: Work) -> UUID {
		let id = UUID()
		lock.lock()
		sessions[id] = work
		lock.unlock()
		return id
	}

	static func forget(_ id: UUID) {
		lock.lock()
		sessions.removeValue(forKey: id)
		lock.unlock()
	}

	private static func work(_ id: UUID) -> Work? {
		lock.lock()
		defer { lock.unlock() }
		return sessions[id]
	}

	// MARK: - AVVideoCompositing

	/// Colour management off, for the reason the renderer records: converting
	/// Rec. 709 video into Core Image's linear space and back does not come
	/// home, and the picture arrives seven or eight levels lifted.
	private let context = CIContext(options: [.workingColorSpace: NSNull()])

	let sourcePixelBufferAttributes: [String: any Sendable]? = [
		kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA],
	]
	let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
		kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA],
	]

	func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

	func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
		guard let instruction = request.videoCompositionInstruction as? ProgrammeInstruction,
		      let work = Self.work(instruction.session) else {
			request.finish(with: RenderError.noVideo)
			return
		}

		let time = request.compositionTime.seconds
		let size = work.size

		// Nothing to do to this frame? Then hand it back as it came.
		//
		// Not an optimisation — or not only one. Every trip through Core Image
		// and back out to the encoder costs a colour conversion, and the frames
		// of a programme that is only being cut should be the frames that were
		// shot. This is what keeps a cut exact and pays the conversion only
		// where something is actually being drawn.
		if instruction.outgoing == nil, instruction.incomingLook == .none,
		   !work.busy(at: time), let track = instruction.incoming,
		   let buffer = request.sourceFrame(byTrackID: track),
		   CVPixelBufferGetWidth(buffer) == Int(size.width),
		   CVPixelBufferGetHeight(buffer) == Int(size.height) {
			request.finish(withComposedVideoFrame: buffer)
			return
		}

		func source(_ track: CMPersistentTrackID?, look: Look) -> CIImage? {
			guard let track, let buffer = request.sourceFrame(byTrackID: track) else { return nil }
			// Taken as it is: with no colour space named, Core Image reads the
			// buffer's own tag and converts, and the frame arrives forty levels
			// dark. The values in the footage are the values wanted.
			var image = Grading.apply(look, to: CIImage(cvPixelBuffer: buffer))
			image = image.transformed(by: Grading.fit(image.extent, into: size))
			return image
		}

		// The two shots, each graded as its own clip asks — a dissolve between a
		// warm shot and a cold one has to be warm at one end and cold at the
		// other, which means grading before blending rather than after.
		let incoming = source(instruction.incoming, look: instruction.incomingLook)
		let outgoing = source(instruction.outgoing, look: instruction.outgoingLook)

		var image: CIImage
		switch (outgoing, incoming) {
		case (let going?, let coming?):
			let span = max(instruction.timeRange.duration.seconds, 0.0001)
			let progress = min(1, max(0, (time - instruction.timeRange.start.seconds) / span))
			image = Transitions.blend(instruction.blend, going: going, coming: coming,
			                          progress: progress, size: size)
		case (nil, let coming?):
			image = coming
		case (let going?, nil):
			image = going
		default:
			request.finish(with: RenderError.noVideo)
			return
		}

		image = Frame.overlays(over: image, at: time, size: size, work: work)

		guard let buffer = request.renderContext.newPixelBuffer() else {
			request.finish(with: RenderError.exportFailed("no buffer to render into"))
			return
		}
		// No colour space, no colour matching: the values that came out of the
		// footage are the values written back. Handing this a space converts
		// them, and the picture arrives forty levels dark.
		context.render(image, to: buffer, bounds: CGRect(origin: .zero, size: size),
		               colorSpace: CGColorSpace(name: CGColorSpace.itur_709))
		request.finish(withComposedVideoFrame: buffer)
	}

	func cancelAllPendingVideoCompositionRequests() {}
}

/// What to do for one stretch of the programme: which track the picture comes
/// from, and — while a dissolve is running — which one it is going to.
final class ProgrammeInstruction: NSObject, AVVideoCompositionInstructionProtocol {

	let timeRange: CMTimeRange
	let enablePostProcessing = false
	let containsTweening: Bool
	let requiredSourceTrackIDs: [NSValue]?
	let passthroughTrackID = kCMPersistentTrackID_Invalid

	/// The shot going out, if two shots overlap here.
	let outgoing: CMPersistentTrackID?
	let incoming: CMPersistentTrackID?
	let outgoingLook: Look
	let incomingLook: Look
	/// What to draw while they overlap.
	let blend: Transition
	let session: UUID

	init(
		timeRange: CMTimeRange, outgoing: CMPersistentTrackID?, incoming: CMPersistentTrackID?,
		outgoingLook: Look = .none, incomingLook: Look = .none,
		blend: Transition = .cut, session: UUID
	) {
		self.timeRange = timeRange
		self.outgoing = outgoing
		self.incoming = incoming
		self.outgoingLook = outgoingLook
		self.incomingLook = incomingLook
		self.blend = blend
		self.session = session
		self.containsTweening = outgoing != nil && incoming != nil
		self.requiredSourceTrackIDs = [outgoing, incoming].compactMap { $0 }.map { NSNumber(value: $0) }
	}
}
