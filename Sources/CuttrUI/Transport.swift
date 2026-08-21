@preconcurrency import AVFoundation
import AppKit
import CuttrKit

/// Playback of the take as one thing.
///
/// The video and the separately recorded audio are played by a single
/// `AVPlayer`, over an `AVMutableComposition` that puts the audio at its
/// offset. The obvious alternative — two players, started together and nudged
/// when they drift — was not tried, and should not be: two `AVPlayer`s have two
/// clocks, and the number being tuned here is a millisecond. A tool for
/// measuring an offset cannot have an offset of its own that it does not know
/// about.
///
/// Re-aligning is therefore a rebuild of the composition. That reads no media —
/// the assets and their tracks are held from the first load — so a nudge is a
/// few hundred microseconds of bookkeeping and a seek back to where the
/// playhead was.
@MainActor
public final class Transport {

	/// Which microphone comes out of the speakers.
	public enum Monitor: Int, CaseIterable {
		case external, camera, both

		public var title: String {
			switch self {
			case .external: return "Audio file"
			case .camera: return "Camera"
			case .both: return "Both"
			}
		}

		/// The same three, short enough to sit on the waveform they are about.
		public var short: String {
			switch self {
			case .external: return "rec"
			case .camera: return "cam"
			case .both: return "both"
			}
		}
	}

	public let player = AVPlayer()

	/// Both at once, and it is the alignment tool rather than a convenience.
	///
	/// Two recordings of one room, summed, comb-filter against each other, and
	/// the ear is far better at hearing that hollow flanging disappear than the
	/// eye is at lining up two waveforms. Nudge until it sounds like one
	/// microphone; that is the offset. Doubling as a check that the waveform
	/// match was not a coincidence.
	public var monitor: Monitor = .external { didSet { rebuild() } }

	/// Called on every tick with the current time, for the playhead.
	public var onTick: ((Double) -> Void)?
	/// Called when playback starts or stops.
	public var onRateChange: ((Float) -> Void)?

	// Durations and the transform are loaded once, with the tracks, and kept.
	// They are `await` properties on the asset, and `rebuild()` is called on
	// every millisecond of a nudge — a rebuild that has to await anything is a
	// rebuild that arrives after the next one.
	private var videoAsset: AVURLAsset?
	private var videoTrack: AVAssetTrack?
	private var videoDuration: CMTime = .zero
	private var videoTransform: CGAffineTransform = .identity
	private var cameraAudioTrack: AVAssetTrack?
	private var externalAudioAsset: AVURLAsset?
	private var externalAudioTrack: AVAssetTrack?
	private var externalAudioDuration: CMTime = .zero
	private var offset: Double = 0
	private var duration: Double = 0

	private var timeObserver: Any?
	private var rateObservation: NSKeyValueObservation?
	private var loadTask: Task<Void, Never>?

	public init() {
		// Sixty a second, so the playhead moves with the picture rather than in
		// steps somebody can count. It is one closure and a rectangle's worth of
		// invalidation per tick.
		timeObserver = player.addPeriodicTimeObserver(
			forInterval: CMTime(value: 1, timescale: 60),
			queue: .main
		) { [weak self] time in
			MainActor.assumeIsolated { self?.onTick?(time.seconds) }
		}
		rateObservation = player.observe(\.rate, options: [.new]) { [weak self] player, _ in
			let rate = player.rate
			Task { @MainActor in self?.onRateChange?(rate) }
		}
	}

	deinit {
		if let timeObserver { player.removeTimeObserver(timeObserver) }
	}

	/// Points the transport at the take's media. Asynchronous once, then every
	/// alignment change is ``setOffset(_:)`` and costs nothing.
	public func load(video: URL?, audio: URL?, offset: Double, completion: (() -> Void)? = nil) {
		loadTask?.cancel()
		self.offset = offset
		videoAsset = nil; videoTrack = nil; cameraAudioTrack = nil
		externalAudioAsset = nil; externalAudioTrack = nil
		videoDuration = .zero; externalAudioDuration = .zero; videoTransform = .identity
		player.replaceCurrentItem(with: nil)

		loadTask = Task { [weak self] in
			var loadedVideo: (AVURLAsset, AVAssetTrack?, AVAssetTrack?, CMTime, CGAffineTransform)?
			var loadedAudio: (AVURLAsset, AVAssetTrack, CMTime)?
			if let video {
				let asset = AVURLAsset(url: video)
				let v = try? await asset.loadTracks(withMediaType: .video).first
				let a = try? await asset.loadTracks(withMediaType: .audio).first
				let duration = (try? await asset.load(.duration)) ?? .zero
				let transform = (try? await v?.load(.preferredTransform)) ?? .identity
				loadedVideo = (asset, v, a, duration, transform)
			}
			if let audio {
				let asset = AVURLAsset(url: audio)
				if let track = try? await asset.loadTracks(withMediaType: .audio).first {
					loadedAudio = (asset, track, (try? await asset.load(.duration)) ?? .zero)
				}
			}
			guard !Task.isCancelled, let self else { return }
			if let loadedVideo {
				self.videoAsset = loadedVideo.0
				self.videoTrack = loadedVideo.1
				self.cameraAudioTrack = loadedVideo.2
				self.videoDuration = loadedVideo.3
				self.videoTransform = loadedVideo.4
			}
			if let loadedAudio {
				self.externalAudioAsset = loadedAudio.0
				self.externalAudioTrack = loadedAudio.1
				self.externalAudioDuration = loadedAudio.2
			}
			// No separate recording means nothing to choose between, and a
			// monitor set to a file that is not there is silence somebody has
			// to diagnose.
			if loadedAudio == nil { self.monitorWithoutRebuild(.camera) }
			else if self.monitor == .camera && loadedVideo?.2 == nil { self.monitorWithoutRebuild(.external) }
			self.rebuild(preservingTime: false)
			completion?()
		}
	}

	private func monitorWithoutRebuild(_ value: Monitor) {
		// The setter rebuilds, and this runs inside the load that is about to.
		if monitor != value { monitor = value }
	}

	/// Plays a composition somebody else assembled.
	///
	/// The composing window's way in. It has already built exactly what the
	/// renderer will encode and does not want this class's cutting-room
	/// machinery — but it does want the part that works: one player, one view,
	/// one set of seek and tick rules. Having a second `AVPlayer` set up by hand
	/// over there was a second playback path to get wrong, and it was wrong.
	public func present(
		_ composition: AVComposition, videoComposition: AVVideoComposition?,
		audioMix: AVAudioMix? = nil, duration: Double
	) {
		loadTask?.cancel()
		self.duration = duration
		let resumeAt = min(currentTime, duration)
		let wasPlaying = isPlaying
		let item = AVPlayerItem(asset: composition)
		item.videoComposition = videoComposition
		item.audioMix = audioMix
		player.replaceCurrentItem(with: item)
		if resumeAt > 0 { seek(to: resumeAt) }
		if wasPlaying { player.play() }
	}

	/// What is on the player now, for a second view that wants to show the same
	/// thing — a look at one clip, beside the list it was chosen from.
	///
	/// Read off the player rather than kept beside it. The composition is built
	/// again whenever the alignment moves, and a copy held here would be the old
	/// one the first time somebody nudged the offset — which is exactly the
	/// second source of truth ``present(_:videoComposition:audioMix:duration:)``
	/// exists to avoid.
	public var playing: (composition: AVComposition, videoComposition: AVVideoComposition?,
	                     audioMix: AVAudioMix?, duration: Double)? {
		guard let item = player.currentItem,
		      let composition = item.asset as? AVComposition else { return nil }
		return (composition, item.videoComposition, item.audioMix, duration)
	}

	/// The grade the picture is shown through.
	///
	/// The cutting window's whole reason for having one: a look is decided by
	/// looking, and a slider whose effect only appears after a render is a
	/// slider nobody can use. The same arithmetic the renderer applies, from
	/// the same place, so what is dragged here is what will be encoded.
	public var look: Look = .none {
		didSet { if look != oldValue { showLook() } }
	}

	/// Colour management off, for the reason the renderer records at length: a
	/// trip through Core Image's linear space and back lifts the picture, and
	/// the preview would then disagree with the file it is previewing.
	private let unmanaged = CIContext(options: [.workingColorSpace: NSNull()])

	private func showLook() {
		guard let item = player.currentItem else { return }
		guard !look.isEmpty else {
			// Nothing to do to the frames, so nothing is done to them — the
			// same rule the renderer follows, and the only way the ungraded
			// picture is the footage rather than a copy of it.
			item.videoComposition = nil
			return
		}
		let look = self.look
		let unmanaged = self.unmanaged
		let composition = AVMutableVideoComposition(
			asset: item.asset,
			applyingCIFiltersWithHandler: { request in
				request.finish(with: look.applied(to: request.sourceImage), context: unmanaged)
			})
		item.videoComposition = composition
	}

	/// Moves the audio against the video. Cheap enough to call on every nudge.
	public func setOffset(_ offset: Double) {
		guard offset != self.offset else { return }
		self.offset = offset
		rebuild()
	}

	private func rebuild(preservingTime: Bool = true) {
		let resumeAt = preservingTime ? currentTime : 0
		let wasPlaying = player.rate != 0

		let composition = AVMutableComposition()
		var end = CMTime.zero

		if videoAsset != nil, let videoTrack,
		   let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
			let range = CMTimeRange(start: .zero, duration: videoDuration)
			try? track.insertTimeRange(range, of: videoTrack, at: .zero)
			track.preferredTransform = videoTransform
			end = videoDuration
		}

		if monitor != .external, let cameraAudioTrack,
		   let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
			try? track.insertTimeRange(CMTimeRange(start: .zero, duration: videoDuration), of: cameraAudioTrack, at: .zero)
		}

		if monitor != .camera, externalAudioAsset != nil, let externalAudioTrack,
		   let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
			// The offset in both directions. A positive offset delays the audio
			// into the composition; a negative one means the recorder started
			// after the camera, so the composition begins part-way into it.
			let audioDuration = externalAudioDuration
			let scale: Int32 = 44100
			if offset >= 0 {
				let at = CMTime(seconds: offset, preferredTimescale: scale)
				try? track.insertTimeRange(CMTimeRange(start: .zero, duration: audioDuration), of: externalAudioTrack, at: at)
				end = max(end, at + audioDuration)
			} else {
				let skip = CMTime(seconds: -offset, preferredTimescale: scale)
				if skip < audioDuration {
					let range = CMTimeRange(start: skip, duration: audioDuration - skip)
					try? track.insertTimeRange(range, of: externalAudioTrack, at: .zero)
					end = max(end, range.duration)
				}
			}
		}

		duration = end.seconds
		guard end > .zero else { player.replaceCurrentItem(with: nil); return }

		let item = AVPlayerItem(asset: composition)
		player.replaceCurrentItem(with: item)
		showLook()
		if resumeAt > 0 { seek(to: resumeAt) }
		if wasPlaying { player.play() }
	}

	// MARK: - Position

	public var currentTime: Double {
		let t = player.currentTime().seconds
		return t.isFinite ? t : 0
	}

	public var isPlaying: Bool { player.rate != 0 }

	/// The seek in flight and the one waiting behind it.
	///
	/// A drag across the timeline asks for a seek per mouse-moved event, and a
	/// frame-accurate seek takes longer than the gap between them. Issuing them
	/// all queues a hundred seeks and the picture arrives seconds after the
	/// mouse stops. Keeping only the newest is what makes scrubbing feel
	/// attached to the pointer.
	private var seekInFlight = false
	private var pendingSeek: Double?

	public func seek(to seconds: Double) {
		let clamped = max(0, min(seconds, duration > 0 ? duration : seconds))
		guard player.currentItem != nil else { return }
		guard !seekInFlight else { pendingSeek = clamped; return }
		seekInFlight = true
		// Zero tolerance both ways: a cut mark is placed on the frame somebody
		// is looking at, and a seek that lands on the previous keyframe shows
		// them a different one.
		player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
		            toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
			MainActor.assumeIsolated {
				guard let self else { return }
				self.seekInFlight = false
				if let next = self.pendingSeek {
					self.pendingSeek = nil
					self.seek(to: next)
				}
			}
		}
	}

	public func play() {
		clearRange()
		player.play()
	}

	public func pause() { player.pause() }
	public func togglePlay() { isPlaying ? pause() : play() }

	/// Plays one span and stops at the end of it.
	///
	/// `forwardPlaybackEndTime` rather than watching the clock and pausing when
	/// it goes past: the player stops exactly on the frame asked for, where a
	/// tick-based stop overshoots by however long it was between ticks. On a
	/// four-second clip that difference is the last word of a sentence.
	public func play(from start: Double, to end: Double) {
		guard let item = player.currentItem else { return }
		item.forwardPlaybackEndTime = CMTime(seconds: end, preferredTimescale: 600)
		seek(to: start)
		player.play()
	}

	/// Back to playing until the end of the programme.
	///
	/// The limit lives on the item, so it outlasts the play that set it and has
	/// to be taken off — otherwise the next plain `space` stops at the end of
	/// whichever clip was played last, which looks exactly like a bug in the
	/// player.
	public func clearRange() {
		player.currentItem?.forwardPlaybackEndTime = .invalid
	}

	/// Shuttle. Negative rates need the item to say it can do them, and a
	/// composition of a long-GOP camera file often cannot go backwards at all —
	/// asking anyway is a silent stop, so it falls back to stepping.
	public func setRate(_ rate: Float) {
		guard let item = player.currentItem else { return }
		if rate < 0 && !item.canPlayReverseEffect { player.pause(); return }
		if rate > 1 && !item.canPlayFastForward { player.rate = 1; return }
		player.rate = rate
	}
}

private extension AVPlayerItem {
	/// `canPlayReverse` is the property; the name here is to keep the call site
	/// reading as a question about the effect rather than about the API.
	var canPlayReverseEffect: Bool { canPlayReverse }
}

/// A view whose layer holds the player's.
///
/// Layer-**backed**, not layer-hosting. The difference is one line and it is
/// not cosmetic: assigning `layer` yourself makes a view layer-hosting, which
/// tells AppKit that the layer's geometry is your problem — so it stops sizing
/// and positioning it, and the layer keeps whatever frame it was born with
/// while the view moves around it. In a split view that goes unnoticed because
/// the split view clips everything anyway. Given a plain sibling to sit next
/// to, the unmanaged layer covered it: the composing window's whole toolbar
/// was underneath a player layer that AppKit had never been asked to place.
public final class PlayerView: NSView {
	public let playerLayer = AVPlayerLayer()

	public init(player: AVPlayer) {
		super.init(frame: .zero)
		playerLayer.player = player
		playerLayer.videoGravity = .resizeAspect
		wantsLayer = true
	}

	@available(*, unavailable) required init?(coder: NSCoder) { nil }

	/// Right-click, with the point in this view's coordinates.
	public var contextMenu: ((NSPoint) -> NSMenu?)?

	public override func menu(for event: NSEvent) -> NSMenu? {
		contextMenu?(convert(event.locationInWindow, from: nil))
	}

	/// The player's layer is attached when AppKit makes the backing layer, not
	/// in `layout()`.
	///
	/// `layout()` looked like the right place — it is where `layer` is
	/// guaranteed to exist — and it cost an afternoon. Inside a split view it is
	/// called promptly, because the split view sets its arranged subviews'
	/// frames; as a plain constrained child of a plain view it was not called
	/// before the first display, so the picture was attached to nothing and the
	/// preview showed the window's own grey. Same view, same player, same
	/// composition, different parent.
	///
	/// `makeBackingLayer` has no such dependency: AppKit asks for the layer, and
	/// what it gets already has the picture in it.
	public override func makeBackingLayer() -> CALayer {
		let backing = CALayer()
		backing.backgroundColor = NSColor.black.cgColor
		backing.addSublayer(playerLayer)
		return backing
	}

	public override func layout() {
		super.layout()
		// No implicit animation: the layer would ease into its new frame on
		// every window resize, which reads as the picture lagging the window.
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		playerLayer.frame = bounds
		CATransaction.commit()
	}
}
