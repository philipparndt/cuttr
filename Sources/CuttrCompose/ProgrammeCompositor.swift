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
		/// The clips carrying a presentation treatment. Only those: a programme
		/// with none of them looks nothing up and hands its frames back
		/// untouched, exactly as it did before this feature existed.
		var treated: [ResolvedClip] = []
		/// The frame each hold stands on, and the stretch of programme it
		/// stands there for. What is under it in the track is filler.
		var stills: [(range: CMTimeRange, image: CIImage)] = []

		/// The picture a hold is holding at this moment, if one is.
		func still(at time: Double) -> CIImage? {
			let when = CMTime(seconds: time, preferredTimescale: 600)
			return stills.first { $0.range.containsTime(when) }?.image
		}

		/// Where the picture is at this moment of the programme.
		///
		/// The compositor's one question about a treatment, and the clip
		/// answers it — see ``ResolvedClip/picture(atProgramme:)``. Nothing
		/// here works out an eased fraction for itself.
		func picture(at time: Double) -> Presentation.Rectangle {
			for clip in treated where time >= clip.start && time <= clip.end {
				let box = clip.picture(atProgramme: time)
				if !box.isWhole { return box }
			}
			return .whole
		}

		/// Whether anything is being drawn into the frame at this moment.
		///
		/// The *drawn* window rather than the span, because a movement placed
		/// before the first mark puts the overlay on screen early — and a frame
		/// this says nothing is happening on is handed straight back to the
		/// encoder untouched. Asking the span here is how film mode would fail
		/// to grade the frames it was meant to have graded before the clip.
		func busy(at time: Double) -> Bool {
			// A frame whose picture has been moved cannot be handed back as it
			// came, whatever else is or is not on it — and neither can one that
			// is being held, because what is in the track there is filler.
			if !picture(at: time).isWhole || still(at: time) != nil { return true }
			if effects.contains(where: { $0.overlay.timing.drawn(at: time) }) {
				return true
			}
			return overlays.contains { shown in
				guard shown.timing.drawn(at: time) else { return false }
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

	/// Colour management off — ``Renderer/context()`` records what that costs,
	/// what it was thought to cost, and what has to be true before it can go on.
	private let context = Renderer.context()

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
		//
		// `outgoingFill` is checked as well as `outgoing`, and the render that
		// found out why shows it plainly: a shot dissolving out of a card has
		// no outgoing *track*, so this took the shot's own frame and handed it
		// back — the dissolve snapped, from the card to the shot, in one frame.
		if instruction.outgoing == nil, instruction.outgoingFill == nil,
		   instruction.incomingLook == .none,
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
		//
		// A card has no track and is painted instead. Everything after this
		// point — the blend, the film, the overlays — cannot tell the
		// difference, which is the point: a card is the picture underneath.
		// A held frame stands in for whatever the track has here, which is
		// filler put there to keep the timeline unbroken. The grade still
		// applies: a hold is part of the shot it stopped, not a separate one.
		let held = work.still(at: time).map { Grading.apply(instruction.incomingLook, to: $0) }
		let incoming = held
			?? source(instruction.incoming, look: instruction.incomingLook)
			?? instruction.incomingFill?.image(size: size)
		let outgoing = source(instruction.outgoing, look: instruction.outgoingLook)
			?? instruction.outgoingFill?.image(size: size)

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

		// The picture is moved before anything is drawn over it: a scene
		// playing beside a held recording is over the whole frame, and the
		// recording is a rectangle within it.
		image = Frame.picture(image, into: work.picture(at: time), size: size)
		image = Frame.overlays(over: image, at: time, size: size, work: work)

		guard let buffer = request.renderContext.newPixelBuffer() else {
			request.finish(with: RenderError.exportFailed("no buffer to render into"))
			return
		}
		// No colour space, no colour matching: the values that came out of the
		// footage are the values written back.
		//
		// `nil` and not `CGColorSpace(name: .itur_709)`, which is what stood
		// here under this same comment — a contradiction that was harmless only
		// because with the working space null the argument is ignored, and that
		// would have been the bug the day it stopped being ignored. Measured: it
		// is *not* the space these buffers are tagged with, and landing a
		// managed pass in it lifts the picture by up to nineteen levels. When
		// management goes on, the space to name here is the one Core Video
		// builds from the buffer's own attachments.
		context.render(image, to: buffer, bounds: CGRect(origin: .zero, size: size),
		               colorSpace: nil)
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
	/// The colour to paint on either side, for a card — which is a stretch of
	/// programme with no track behind it.
	let outgoingFill: Card.Fill?
	let incomingFill: Card.Fill?
	/// What to draw while they overlap.
	let blend: Transition
	let session: UUID

	init(
		timeRange: CMTimeRange, outgoing: CMPersistentTrackID?, incoming: CMPersistentTrackID?,
		outgoingLook: Look = .none, incomingLook: Look = .none,
		outgoingFill: Card.Fill? = nil, incomingFill: Card.Fill? = nil,
		blend: Transition = .cut, session: UUID
	) {
		self.timeRange = timeRange
		self.outgoing = outgoing
		self.incoming = incoming
		self.outgoingLook = outgoingLook
		self.incomingLook = incomingLook
		self.outgoingFill = outgoingFill
		self.incomingFill = incomingFill
		self.blend = blend
		self.session = session
		// Tweening is about whether there are two pictures here, not two
		// tracks: a shot dissolving into a card is a dissolve.
		self.containsTweening = (outgoing != nil || outgoingFill != nil)
			&& (incoming != nil || incomingFill != nil)
		let tracks = [outgoing, incoming].compactMap { $0 }
		// `nil` means "every track", which is what a card wants: it needs none
		// of them, and an empty list is read as an instruction that has nothing
		// to do rather than as one that needs nothing.
		self.requiredSourceTrackIDs = tracks.isEmpty
			? nil : tracks.map { NSNumber(value: $0) }
	}
}
