@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// One window, recorded to a file.
///
/// **Why a window and not a rectangle of the screen.**
/// `SCContentFilter(desktopIndependentWindow:)` captures the window itself, so
/// what is in the film is what is in the window: a notification sliding in over
/// it is not, and a window nudged half way through does not walk out of frame.
/// A screen recorder that captures a region has to ask somebody to hold still
/// for two minutes.
///
/// It is also the window's own pixels at the window's own scale, so type stays
/// type instead of becoming a photograph of type.
public final class WindowRecorder: NSObject, @unchecked Sendable {

	public enum Trouble: Error, Equatable {
		case noConsent(Consent)
		case noWindow
		/// The window is there and is not the size that was asked for. Refused
		/// rather than cropped: cropping a screen recording throws away the
		/// resolution that made it readable.
		case wrongSize(got: CGSize, wanted: CGSize)
		case cannotWrite(String)
	}

	private let stream: SCStream
	private let writer: AVAssetWriter
	private let input: AVAssetWriterInput
	private let queue = DispatchQueue(label: "de.rnd7.cuttr.record")
	/// The presentation time of the first frame, so the film starts at nought.
	///
	/// A capture hands out frames stamped on the host clock, which is the time
	/// since the machine booted. Written straight through, the take would begin
	/// at nine hours and somebody would have to subtract.
	private var firstFrame: CMTime?
	private var frames = 0
	private var stopped = false

	public private(set) var url: URL

	/// How much has been recorded, in seconds — for the clock on screen.
	public var elapsed: Double {
		guard let firstFrame, let last = lastFrame else { return 0 }
		return max(0, (last - firstFrame).seconds)
	}

	private var lastFrame: CMTime?

	// MARK: - Making one

	/// Everything that can be refused is refused here, before a file is made:
	/// the permission, the window, and its size.
	public init(window: SCWindow, size: CGSize, to url: URL,
	            framesPerSecond: Double = 30) throws {
		self.url = url

		// The window's own scale, so the recording is the pixels the window
		// drew rather than an enlargement of them.
		let scale = size.width > 0 ? max(1, window.frame.width > 0
			? size.width / window.frame.width : 1) : 1
		_ = scale

		let configuration = SCStreamConfiguration()
		configuration.width = Int(size.width)
		configuration.height = Int(size.height)
		configuration.minimumFrameInterval = CMTime(
			value: 1, timescale: CMTimeScale(max(1, framesPerSecond.rounded())))
		configuration.showsCursor = true
		configuration.pixelFormat = kCVPixelFormatType_32BGRA
		configuration.queueDepth = 6
		configuration.scalesToFit = false

		let filter = SCContentFilter(desktopIndependentWindow: window)
		stream = SCStream(filter: filter, configuration: configuration, delegate: nil)

		try? FileManager.default.removeItem(at: url)
		do {
			writer = try AVAssetWriter(outputURL: url, fileType: .mov)
		} catch {
			throw Trouble.cannotWrite(error.localizedDescription)
		}
		// HEVC for the same reason the renderer prefers it: a screencast is
		// flat colour and sharp edges, which is where h.264 spends its
		// bit-rate badly and shows it as rings around type.
		input = AVAssetWriterInput(mediaType: .video, outputSettings: [
			AVVideoCodecKey: AVVideoCodecType.hevc,
			AVVideoWidthKey: Int(size.width),
			AVVideoHeightKey: Int(size.height),
		])
		input.expectsMediaDataInRealTime = true
		super.init()
		guard writer.canAdd(input) else {
			throw Trouble.cannotWrite("this machine cannot encode \(Int(size.width))×\(Int(size.height))")
		}
		writer.add(input)
		try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
	}

	// MARK: - Running

	public func start() async throws {
		guard writer.startWriting() else {
			throw Trouble.cannotWrite(writer.error?.localizedDescription ?? "the writer refused")
		}
		try await stream.startCapture()
	}

	/// Stops, and hands back a whole file.
	///
	/// The order matters and is the whole of why this is not two lines: the
	/// capture is stopped first so no frame arrives after the writer has been
	/// told there will be no more, and `finishWriting` is waited for, because a
	/// file whose moov atom has not been written yet is a file that does not
	/// open.
	@discardableResult
	public func stop() async -> URL? {
		guard !stopped else { return frames > 0 ? url : nil }
		stopped = true
		try? await stream.stopCapture()
		guard frames > 0 else {
			input.markAsFinished()
			await writer.finishWriting()
			try? FileManager.default.removeItem(at: url)
			return nil
		}
		input.markAsFinished()
		await writer.finishWriting()
		return writer.status == .completed ? url : nil
	}

	/// For the panel: how many frames have arrived, so "recording" can be told
	/// from "recording nothing".
	public var frameCount: Int { frames }
}

// MARK: - The frames

extension WindowRecorder: SCStreamOutput {

	public func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer,
	                   of type: SCStreamOutputType) {
		guard type == .screen, !stopped, buffer.isValid,
		      CMSampleBufferGetNumSamples(buffer) > 0 else { return }
		// A capture sends frames whether or not anything changed, and marks the
		// ones that are not new. Those are dropped: a screencast of a still page
		// should cost what a still page costs.
		guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
			buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
			let raw = attachments.first?[.status] as? Int,
			let status = SCFrameStatus(rawValue: raw), status == .complete else { return }

		let stamp = CMSampleBufferGetPresentationTimeStamp(buffer)
		if firstFrame == nil {
			firstFrame = stamp
			// Nought at the first frame, so the time somebody reads off the
			// window while recording is the time they can cut to afterwards.
			writer.startSession(atSourceTime: .zero)
		}
		guard let firstFrame else { return }
		lastFrame = stamp
		guard input.isReadyForMoreMediaData else { return }

		let at = stamp - firstFrame
		guard let retimed = try? CMSampleBuffer(
			copying: buffer,
			withNewTiming: [CMSampleTimingInfo(
				duration: .invalid, presentationTimeStamp: at, decodeTimeStamp: .invalid)])
		else { return }
		if input.append(retimed) { frames += 1 }
	}
}
