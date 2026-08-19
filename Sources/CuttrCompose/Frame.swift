import CoreImage
import CuttrKit
import Foundation

/// Everything that happens to a frame once the picture in it has been decided:
/// the effects, the overlays that are painted rather than laid on, and the
/// three kinds that are the frame itself.
///
/// Its own file because two things need it — the compositor, which makes every
/// frame of a render, and anything else that wants to know what a moment of the
/// programme looks like. What it must not become is a second place that decides
/// where things go; it calls the same painters the rest of the program does.
enum Frame {

	/// The overlays, in the order the file lists them.
	///
	/// **Order is authored, not decided here.** It used to be decided by kind —
	/// film first, then anything going behind somebody, then the effects — and
	/// that answers the question only while there is exactly one thing that is
	/// the whole frame. With four of them the question is which of the four,
	/// and no rule about kinds can answer it: an aberration under film mode is
	/// a lens on the footage and the bars stay clean, and the same aberration
	/// over it bends the bars as well. Both are wanted, and the difference
	/// between them is not a property of either kind.
	///
	/// So the list decides. An overlay written earlier in `overlays:` is drawn
	/// earlier, and film mode takes its place in that list like everything
	/// else. "Inside the film" is written before it, "over the film" after it.
	/// That rule needs no new key, it is visible in a diff, and the panel can
	/// move a row up and down.
	///
	/// **What it cannot order.** A caption, a spinner and a scene are not drawn
	/// here at all: they are Core Animation layers, and the export lays them
	/// over the finished picture in a second pass (see ``OverlayLayers``, and
	/// ``Renderer/overlays(of:onto:to:progress:)`` for why it has to be a
	/// second pass). That pass happens after every pixel in this function, so a
	/// caption cannot be put underneath a film overlay by writing it first —
	/// among themselves those three stack in list order, and against anything
	/// here they are always on top. The panel says so on the row rather than
	/// offering an order it cannot keep.
	static func overlays(
		over picture: CIImage, at time: Double, size: CGSize,
		work: ProgrammeCompositor.Work
	) -> CIImage {
		var image = picture

		for shown in work.overlays where time >= shown.start && time <= shown.end {
			let intensity = fade(shown, at: time)

			switch shown.overlay.kind {
			case .film(let film):
				image = Filming.applied(film, to: image, intensity: intensity,
				                        size: size, time: time)

			case .aberration(let aberration):
				image = Aberrating.applied(aberration, to: image, intensity: intensity, size: size)

			case .tape(let tape):
				image = Taping.applied(tape, to: image, intensity: intensity,
				                       size: size, time: time)

			case .effect:
				guard intensity > 0.001, let renderer = renderer(for: shown, in: work) else { continue }
				image = thrown(shown, renderer: renderer, over: image, under: picture,
				               at: time, opacity: intensity, size: size, work: work)

			case .text, .spinner, .scene:
				// Layers, unless they go behind somebody — in which case they
				// are painted here, because the mask that knows where she is
				// lives in the pass that has the pixels.
				guard shown.overlay.behind == .people else { continue }
				guard let painted = OverlayPainter.image(
					      for: shown, project: work.project, baseURL: work.baseURL,
					      size: size, at: time),
				      let mask = work.people?.mask(for: picture, at: time) else { continue }
				image = behind(painted, mask: mask, over: image)
			}
		}
		return image
	}

	/// The renderer built for this appearance of this effect.
	///
	/// Matched by which overlay and which appearance rather than by value: what
	/// is resolved is the overlay *as it is at one appearance*, and two
	/// appearances of one effect are two entries with two clouds in them.
	private static func renderer(
		for shown: ResolvedOverlay, in work: ProgrammeCompositor.Work
	) -> EffectRenderer? {
		work.effects.first {
			$0.overlay.source == shown.source && $0.overlay.appearance == shown.appearance
		}?.renderer
	}

	/// A cloud of pieces over the frame — or half in front of somebody and half
	/// behind her.
	///
	/// `under` is the picture as it arrived, which is what the segmentation is
	/// asked about: Vision is being asked where the person is, and the person
	/// is in the footage rather than in whatever has since been done to it.
	/// What is *re-laid* over the pieces is the frame as it stands here, so an
	/// effect written after a film overlay puts the film-graded person back in
	/// front of the confetti rather than the ungraded one.
	private static func thrown(
		_ shown: ResolvedOverlay, renderer: EffectRenderer, over image: CIImage,
		under picture: CIImage, at time: Double, opacity: Double, size: CGSize,
		work: ProgrammeCompositor.Work
	) -> CIImage {
		var spawningUntil = Double.infinity
		if case .fall(let over) = shown.overlay.departure {
			spawningUntil = max(0, shown.duration - over)
		}

		func plate(_ half: EffectRenderer.Half) -> CIImage? {
			guard let drawn = renderer.image(at: time - shown.start,
			                                 spawningUntil: spawningUntil, only: half)
			else { return nil }
			guard opacity < 0.999 else { return drawn }
			return drawn.applyingFilter("CIColorMatrix", parameters: [
				"inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity),
			])
		}

		if shown.overlay.behind == .people, let mask = work.people?.mask(for: picture, at: time) {
			var out = image
			if let back = plate(.back) { out = behind(back, mask: mask, over: out) }
			if let front = plate(.front) { out = front.composited(over: out) }
			return out
		}
		guard let all = plate(.all) else { return image }
		return all.composited(over: image)
	}

	/// Something painted in, with whoever is in the frame put back in front of
	/// it.
	private static func behind(_ painted: CIImage, mask: CIImage, over image: CIImage) -> CIImage {
		let over = painted.composited(over: image)
		return image.applyingFilter("CIBlendWithRedMask", parameters: [
			"inputBackgroundImage": over,
			"inputMaskImage": mask,
		])
	}

	/// How far in or out an overlay is at a moment: one in the middle, nothing
	/// at either edge if it fades.
	///
	/// Only a fade fades. An effect cannot slide — it is the whole frame — so
	/// anything else simply starts, which for confetti means the first pieces
	/// arriving over the top edge. For film mode, the aberration and the tape
	/// this number is not an opacity but how far into the thing the programme
	/// is: the bars close, the fringes spread, the tracking gives way.
	static func fade(_ shown: ResolvedOverlay, at time: Double) -> Double {
		let span = max(shown.duration, 0.0001)
		let arrive = min(shown.overlay.arrival.duration, span / 2)
		let depart = min(shown.overlay.departure.duration, span / 2)
		var opacity = 1.0
		if case .fade = shown.overlay.arrival, arrive > 0, time < shown.start + arrive {
			opacity = min(opacity, (time - shown.start) / arrive)
		}
		if case .fade = shown.overlay.departure, depart > 0, time > shown.end - depart {
			opacity = min(opacity, (shown.end - time) / depart)
		}
		return max(0, min(1, opacity))
	}
}
