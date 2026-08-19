import CoreImage
import CuttrKit
import Foundation

/// Everything that goes *over* a frame once the picture in it has been decided:
/// the effects, and the overlays that are painted rather than laid on.
///
/// Its own file because two things need it — the compositor, which makes every
/// frame of a render, and anything else that wants to know what a moment of the
/// programme looks like. What it must not become is a second place that decides
/// where things go; it calls the same painters the rest of the program does.
enum Frame {

	static func overlays(
		over picture: CIImage, at time: Double, size: CGSize,
		work: ProgrammeCompositor.Work
	) -> CIImage {
		var image = picture

		// Film mode first, because it is the picture rather than something over
		// it: the bars are the edge of the frame, the grain is in the emulsion,
		// and a caption laid over the top afterwards is a caption on the
		// programme rather than one that has been developed with it.
		for shown in work.overlays where time >= shown.start && time <= shown.end {
			guard case .film(let film) = shown.overlay.kind else { continue }
			image = Filming.applied(film, to: image, intensity: fade(shown, at: time),
			                        size: size, time: time)
		}

		let frame = image

		// Anything that goes behind somebody: painted in, then the person over
		// it.
		for shown in work.overlays
		where shown.overlay.behind == .people && time >= shown.start && time <= shown.end {
			guard let painted = OverlayPainter.image(
				      for: shown, project: work.project, baseURL: work.baseURL,
				      size: size, at: time),
			      let mask = work.people?.mask(for: frame, at: time) else { continue }
			image = painted.composited(over: image)
			image = frame.applyingFilter("CIBlendWithRedMask", parameters: [
				"inputBackgroundImage": image,
				"inputMaskImage": mask,
			])
		}

		for (shown, renderer) in work.effects where time >= shown.start && time <= shown.end {
			var spawningUntil = Double.infinity
			if case .fall(let over) = shown.overlay.departure {
				spawningUntil = max(0, shown.duration - over)
			}
			let opacity = fade(shown, at: time)
			guard opacity > 0.001 else { continue }

			func plate(_ half: EffectRenderer.Half) -> CIImage? {
				guard let drawn = renderer.image(at: time - shown.start,
				                                 spawningUntil: spawningUntil, only: half)
				else { return nil }
				guard opacity < 0.999 else { return drawn }
				return drawn.applyingFilter("CIColorMatrix", parameters: [
					"inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity),
				])
			}

			if shown.overlay.behind == .people, let mask = work.people?.mask(for: frame, at: time) {
				if let back = plate(.back) {
					image = back.composited(over: image)
					image = frame.applyingFilter("CIBlendWithRedMask", parameters: [
						"inputBackgroundImage": image,
						"inputMaskImage": mask,
					])
				}
				if let front = plate(.front) { image = front.composited(over: image) }
				continue
			}

			if let all = plate(.all) { image = all.composited(over: image) }
		}
		return image
	}

	/// How far in or out an overlay is at a moment: one in the middle, nothing
	/// at either edge if it fades.
	///
	/// Only a fade fades. An effect cannot slide — it is the whole frame — so
	/// anything else simply starts, which for confetti means the first pieces
	/// arriving over the top edge. For film mode this number is not an opacity
	/// but how far into the mode the programme is: the bars close, the colour
	/// arrives and the grain comes up together, which is what makes going to
	/// film a move rather than a switch.
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
