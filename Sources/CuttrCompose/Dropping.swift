import CoreGraphics
import Foundation

/// A caption that falls in and lands: the shape of the fall, the judder that
/// follows it, and the dust it knocks up.
///
/// **Everything here is arithmetic on the moment.** No physics stepped from the
/// frame before, no state carried between renders — the same argument
/// ``EffectRenderer`` makes at more length. Any frame can be asked for in any
/// order, which is what a scrubbing preview does, and the same second comes out
/// the same on every machine.
///
/// Both render paths ask this, so the fall, the judder and every puff of dust
/// are in the same place in each of them. That is the same reason ``SpinnerLook``
/// exists: two implementations of one movement is one movement that eventually
/// disagrees with itself.
public enum Dropping {

	/// The fraction of the arrival at which it hits.
	///
	/// Not the whole of it, because a caption that arrives on the last frame of
	/// its own arrival has nothing left to land with. The rest is the judder,
	/// and the dust — which is most of what makes it read as heavy.
	public static let lands = 0.55

	/// How far above home the caption is, in points, at a fraction of its
	/// arrival.
	///
	/// - `fell` is the distance it comes from — far enough to be off the top.
	/// - `judder` is how far it rattles after hitting, which is a much smaller
	///   number: scaled to the fall it would read as a second, shorter fall
	///   rather than as an impact.
	public static func lift(at fraction: Double, fell: Double, judder: Double) -> Double {
		let fraction = max(0, min(1, fraction))
		if fraction <= lands {
			// Gravity, near enough: distance goes with the square of the time,
			// so it leaves slowly and arrives fast. An eased fall — slow at
			// both ends — is a caption being lowered on a wire.
			let falling = fraction / lands
			return fell * (1 - falling * falling)
		}
		// And then it bounces, twice, smaller each time, and stops. Never
		// below home: it has landed on something.
		let after = (fraction - lands) / (1 - lands)
		return judder * exp(-4.2 * after) * abs(sin(.pi * 2.6 * after))
	}

	/// A number to seed a cloud with, from the words that knocked it up.
	///
	/// So that two captions in a row do not throw identical dust, and so that
	/// the same caption throws the same dust in every render. Written out
	/// rather than using `Hasher`, which is seeded per process.
	public static func seed(from text: String) -> Int {
		var hash: UInt64 = 0xcbf2_9ce4_8422_2325
		for byte in text.utf8 {
			hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
		}
		return Int(bitPattern: UInt(hash & 0x7fff_ffff))
	}
}

// MARK: - The dust

/// What a caption knocks up when it lands.
///
/// Soft, low and wide: it bursts sideways along the foot of the words and
/// falls back, rather than rising like smoke. Drawn as a few dozen soft discs
/// — the same disc image in both render paths — because dust has no edges, and
/// anything with an edge in it reads as debris.
public struct Dust: Sendable, Equatable {

	/// How much of it, against the usual. 0 is a landing with no cloud at all.
	public var amount: Double

	public init(amount: Double = 1) {
		self.amount = amount
	}

	/// One puff, where it is now.
	public struct Puff: Sendable, Equatable {
		/// Which of the cloud's puffs this is.
		///
		/// **A puff has to be recognisable from one moment to the next.** The
		/// list is only what is in the air, so it is a different length at
		/// every moment — and one puff reaching the end of its life shifts
		/// every puff after it down a place. A caller drawing the whole list
		/// each frame never notices; one that gives each puff something of its
		/// own to move, as the layer path does, follows one puff and then
		/// suddenly its neighbour, which is a cloud that jumps as it thins.
		public let index: Int
		public let centre: CGPoint
		public let radius: Double
		public let alpha: Double
	}

	/// How many puffs there are. Enough to read as a cloud rather than as a
	/// handful of circles, and few enough to be drawn per frame.
	public var count: Int { max(0, min(220, Int((44 * max(0, amount)).rounded()))) }

	/// How much thicker than usual the cloud is drawn.
	///
	/// **`amount` has to reach the opacity and not only the count**, or asking
	/// for more dust past the point where the count caps out changes nothing at
	/// all — which is what happens to anybody who turns it up because they
	/// cannot see it. The square root so that doubling the number is a visible
	/// step rather than a wall of white, and a ceiling because dust that is
	/// opaque is a wipe.
	var thickness: Double { min(2.4, max(0, amount).squareRoot()) }

	/// The cloud, `since` seconds after the caption hit.
	///
	/// `foot` is the line the words landed on, in the frame's own coordinates
	/// with the origin at the bottom left: the dust comes off the bottom edge
	/// of the plate and spreads along it, so a long caption throws a long cloud
	/// and a short one throws a small one without being told to.
	public func puffs(_ since: Double, foot: CGRect, frame: CGSize, seed: Int) -> [Puff] {
		guard amount > 0, since >= 0, count > 0 else { return [] }
		var random = Seeded(seed)
		var out: [Puff] = []
		out.reserveCapacity(count)

		// Gravity in the same units as everything else here: fractions of the
		// frame's height, so a cloud looks the same at any output size.
		let gravity = Double(frame.height) * 0.32

		for index in 0..<count {
			// Where along the foot of the words it comes from, and therefore
			// which way it goes: dust thrown at the left end goes left.
			let along: Double = random.value(0...1)
			let side: Double = along < 0.5 ? -1 : 1
			// Hardest at the ends, where the air has somewhere to go. In the
			// middle it mostly puffs upward.
			let outward: Double = abs(along - 0.5) * 2
			let width = Double(foot.width)
			let tall = Double(frame.height)
			// Off a band at the *foot of the words themselves*, not under them.
			// Born below the plate the cloud reads as something happening
			// separately a little lower down; born along the bottom edge it
			// reads as having been knocked off the thing that landed, which is
			// the whole point of it. A band rather than a line because every
			// puff starting on one row is a row of circles.
			let lifted: Double = random.value(0.0...0.30) * Double(foot.height)
			let start = CGPoint(x: foot.minX + along * foot.width, y: foot.minY + lifted)

			// Wide and low. Nearly all of the movement is sideways: what says
			// "heavy" is a cloud driven out along the ground, and one that goes
			// up instead reads as smoke and hides the words behind it.
			let sideways: Double = side * random.value(0.15...0.75) * width * (0.30 + 0.7 * outward)
			let upward: Double = random.value(0.10...0.45) * tall * (0.26 - 0.10 * outward)
			let delay: Double = random.value(0...0.12)
			let life: Double = random.value(0.45...0.95)
			let born: Double = random.value(0.024...0.058) * tall

			let age: Double = since - delay
			guard age > 0, age < life else { continue }

			// It slows as it spreads — air, not a vacuum — which is why the
			// sideways term is the age eased out rather than the age itself.
			// Dust that travels in a straight line is a firework.
			let through: Double = age / life
			let left: Double = 1 - through
			let spread: Double = 1 - left * left
			let x: Double = Double(start.x) + sideways * spread * life
			let y: Double = Double(start.y) + upward * age - 0.5 * gravity * age * age

			// Growing and thinning at once, which is the whole of what a cloud
			// does. The two together are why it disappears rather than being
			// switched off.
			let radius: Double = born * (1 + 3.2 * through)
			let alpha: Double = 0.72 * thickness * min(1, age / 0.05) * left * sqrt(left)
			out.append(Puff(index: index, centre: CGPoint(x: x, y: y),
			                radius: radius, alpha: alpha))
		}
		return out
	}

	/// The whole of the cloud's life, so a caller knows when to stop asking.
	public static let settles = 1.1
}

// MARK: - What a puff is drawn with

public enum DustDisc {

	/// A soft disc: white, opaque in the middle, nothing at the edge.
	///
	/// One picture, made once, drawn many times — and the *same* picture in
	/// both render paths, which is what stops the painter's dust and the
	/// export's dust being two different clouds. The painter draws it into a
	/// context; the layer path hands it to a layer as its `contents`.
	///
	/// Squared falloff rather than linear: a linear ramp has a visible rim
	/// where it reaches nothing, and forty rims is a pile of circles.
	public static let image: CGImage? = make(96)

	private static func make(_ pixels: Int) -> CGImage? {
		// White with the ramp in its alpha, premultiplied, rather than an
		// alpha-only mask: an alpha-only image cannot simply be drawn into a
		// colour context, and this one has to go through `CGContext.draw` in
		// the painter and `CALayer.contents` in the export without either of
		// them knowing it is a special case.
		guard let context = CGContext(
			data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
			space: CGColorSpace(name: CGColorSpace.sRGB)!,
			bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
		else { return nil }
		guard let data = context.data else { return nil }

		let bytes = data.bindMemory(to: UInt8.self, capacity: pixels * context.bytesPerRow)
		let middle = Double(pixels - 1) / 2
		for y in 0..<pixels {
			for x in 0..<pixels {
				let dx = (Double(x) - middle) / middle
				let dy = (Double(y) - middle) / middle
				let distance = min(1, (dx * dx + dy * dy).squareRoot())
				let falloff = (1 - distance) * (1 - distance)
				let value = UInt8(max(0, min(255, (falloff * 255).rounded())))
				let at = y * context.bytesPerRow + x * 4
				// Premultiplied, so the colour channels carry the alpha too.
				bytes[at] = value
				bytes[at + 1] = value
				bytes[at + 2] = value
				bytes[at + 3] = value
			}
		}
		return context.makeImage()
	}
}
