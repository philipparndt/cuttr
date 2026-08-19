import CoreGraphics
import CoreImage
import Foundation

/// A stretch of the programme with no footage behind it.
///
/// Every other entry on a timeline is a reference into a take, because that is
/// what an assembly is for. A card is the exception that a programme needs
/// anyway: the four seconds of dark blue before the first shot, the beat of
/// black between two sections. There is nothing to reference, so there is
/// nothing to name — a card is a length and a colour, and that is the whole of
/// it.
///
/// It is still an entry like any other. It takes `as:`, so an overlay hangs on
/// `@intro` and the title is drawn over the card exactly as a caption is drawn
/// over a shot; it takes `transition:`, so the first shot can dissolve out of
/// it; and it nests inside a `group:`. Nothing downstream of the resolver has
/// to know that a card is unusual except the one place that makes the picture.
public struct Card: Sendable, Equatable {

	/// Seconds. Stated rather than derived, because there is no material to
	/// derive it from.
	public var duration: Double
	public var fill: Fill

	/// What the card is made of.
	///
	/// A gradient as well as a colour because it costs one filter and is the
	/// difference between a title card and a dropout: two stops a few levels
	/// apart read as a made thing, where one flat colour reads as the picture
	/// having failed. Vertical only — a two-stop gradient at an angle is a
	/// design tool, and this is a backing.
	public enum Fill: Sendable, Equatable {
		case solid(RGBA)
		case gradient(top: RGBA, bottom: RGBA)
	}

	/// Black, which is what a card is when nobody says otherwise — and the one
	/// fill the file leaves out.
	public static let black = Fill.solid(.black)

	public init(duration: Double = 3, fill: Fill = Card.black) {
		self.duration = duration
		self.fill = fill
	}
}

extension Card.Fill {

	/// The card, as a frame.
	///
	/// No colour space is named anywhere in here, for the same reason the
	/// compositor names none: the values written down are the values wanted,
	/// and handing Core Image a space to convert from moves them. Measured on a
	/// rendered file — `fill: "#101014"` arrives as 16, 16, 20 either side of
	/// the encode, which is exactly what was asked for.
	func image(size: CGSize) -> CIImage {
		let frame = CGRect(origin: .zero, size: size)
		switch self {
		case .solid(let colour):
			return CIImage(color: colour.ciColor).cropped(to: frame)
		case .gradient(let top, let bottom):
			let gradient = CIFilter(name: "CILinearGradient", parameters: [
				"inputPoint0": CIVector(x: 0, y: 0),
				"inputColor0": bottom.ciColor,
				"inputPoint1": CIVector(x: 0, y: size.height),
				"inputColor1": top.ciColor,
			])
			// A filter that will not build is not worth failing a render for:
			// the bottom colour alone is still a card.
			guard let image = gradient?.outputImage else {
				return CIImage(color: bottom.ciColor).cropped(to: frame)
			}
			return image.cropped(to: frame)
		}
	}
}

extension RGBA {
	/// The colour as Core Image wants it, in the space the file wrote it in.
	var ciColor: CIColor {
		CIColor(red: r, green: g, blue: b, alpha: a)
	}
}
