import CoreGraphics
import Foundation

public extension Scene {

	/// A column of credits: blocks of a role and the names under it, laid out.
	///
	/// **Why this is a part kind and the others were not.** Everything else an
	/// end plate needs was already here — a ground, words, a rule, and keys
	/// that move any of them. A credit roll is text moved in `y`, and in that
	/// sense the existing vocabulary can already *render* one. What it cannot
	/// do is *say* one. A text part is a single line: ``OverlayLayers`` builds
	/// one `CTLine` from it, so thirty names are thirty parts, each with two
	/// keys whose `y` values have to stay a fixed distance apart. Change the
	/// speed and that is sixty numbers; insert a name in the middle and it is
	/// sixty again. The file would hold the *result* of a layout and no longer
	/// the layout, which is the one thing this format exists not to do.
	///
	/// So what is added is the part nobody can hand-place: the arithmetic of a
	/// column. A roll knows that a role is set against its names, that blocks
	/// are separated by a gap, that a title sits over the top, and that lines
	/// are spaced by their type size. What it does *not* know is that it
	/// scrolls — that is two keys on `y`, the same two keys any other part
	/// takes, and the reason ``Credits/Preset/cards`` can hold a roll still and
	/// fade it instead. A roll is a column; moving it is the file's business.
	struct Roll: Sendable, Equatable {

		/// One block: a role, and the names under it.
		public var entries: [Entry]

		/// A line over the top of the column, centred, in ``titleStyle``.
		///
		/// On the roll rather than as an entry with no names, because it is not
		/// one: it is centred where an entry is aligned, it takes its own type
		/// size, and it comes once. An entry with an empty `role` is still a
		/// perfectly good block of names.
		public var title: String?

		/// The style the names are set in. `nil` is the project's fallback,
		/// like every other style reference.
		public var style: String?
		/// The style the roles are set in. `nil` means the same as ``style``,
		/// so a roll that wants one face says one word.
		public var roleStyle: String?
		/// The style the title is set in. `nil` means the same as ``roleStyle``
		/// resolves to, for the same reason.
		public var titleStyle: String?

		/// The height of one line of names, as a fraction of the frame height —
		/// the same unit a style's `size` is in.
		///
		/// Every other line is spaced in proportion to its own type size, so a
		/// title set half again as large takes half again as much room. That is
		/// leading as anybody sets it, and it means a roll whose styles are all
		/// one size is a plain grid of this number.
		public var line: Double

		/// The blank space between two blocks, in lines. Under the title too.
		public var gap: Double

		/// The space between the role column and the name column, as a fraction
		/// of the frame **height** — both axes in the same unit, so a roll laid
		/// out at 16:9 keeps its proportions at 4:3. Only ``Align/columns``
		/// uses it.
		public var column: Double

		/// How the lines sit against each other.
		///
		/// Not the style's `align`, which answers a different question: there
		/// it says which part of a caption sits at the style's `position`, and
		/// a scene's parts are placed by their keys instead. This one is about
		/// the lines of the column against one another, which no style has ever
		/// had a word for.
		public var align: Align

		/// Letter spacing, as a fraction of the type size — the same field a
		/// text part has, meaning the same thing, applied to every line.
		public var tracking: Double

		public init(
			entries: [Entry] = [], title: String? = nil,
			style: String? = nil, roleStyle: String? = nil, titleStyle: String? = nil,
			line: Double = 0.062, gap: Double = 0.6, column: Double = 0.028,
			align: Align = .columns, tracking: Double = 0
		) {
			self.entries = entries
			self.title = title
			self.style = style
			self.roleStyle = roleStyle
			self.titleStyle = titleStyle
			self.line = line
			self.gap = gap
			self.column = column
			self.align = align
			self.tracking = tracking
		}

		/// One block of the roll.
		public struct Entry: Sendable, Equatable {
			/// What they did. Prose, and always somebody's to rewrite — even on
			/// a block whose names were derived.
			public var role: String
			/// Who did it, one per line.
			public var names: [String]
			/// Where the names came from, when they were not typed here.
			///
			/// This is the whole of the re-generation contract, and it is in the
			/// file on purpose. See ``Roll/Source``.
			public var source: Source?

			public init(role: String, names: [String], source: Source? = nil) {
				self.role = role
				self.names = names
				self.source = source
			}
		}

		/// Where an entry's names came from.
		///
		/// **Why this is in the file.** ``CuttrKit/TakeDocument/manualSlugs``
		/// is the precedent for the opposite decision, and the difference is
		/// what the marker has to survive. There, "somebody typed this slug" is
		/// a fact about one editing session: the question it answers — should
		/// renaming the clip rewrite the slug? — is only ever asked while that
		/// rename is being typed, and by the time the file is closed it is
		/// settled.
		///
		/// Here the question is asked *later, in another process*: three takes
		/// are added next week and the roll is asked to catch up. Something has
		/// to know then which lines this program wrote and which lines a person
		/// wrote, and nothing that lives in a session can know it. The marker is
		/// therefore in the file, because it is a fact about the project.
		///
		/// **Why the derived block carries it and not the typed one.** The other
		/// way round — `manual: true` on the lines somebody typed — makes the
		/// dangerous case the default: a person who adds a line in a text editor
		/// and does not know the key exists loses it the next time the command
		/// runs. This way what somebody typed needs no permission to stay, and
		/// the only line that can be overwritten is the one that says out loud
		/// where it came from.
		///
		/// **What it licenses.** Only the `names`. The `role` above them is
		/// prose and stays whatever it says, so renaming `Featuring` to `Mit
		/// dabei` survives every re-generation. And because the cast is derived
		/// in a fixed order, re-generating an unchanged project rewrites nothing
		/// at all — the same discipline ``ProjectWriter`` keeps.
		public enum Source: String, Sendable, CaseIterable {
			/// The speakers of the takes this film actually uses.
			case cast
		}

		public enum Align: String, Sendable, CaseIterable {
			/// Roles right-aligned against a rule down the middle, names
			/// left-aligned after it. What a broadcast roll is.
			case columns
			/// Everything centred: role over its names.
			case centre
			/// Everything ranged left from one edge.
			case left
		}

		/// Whether anything here was derived, which is what decides whether
		/// there is anything for a re-generation to do.
		public var derives: Bool { entries.contains { $0.source != nil } }
	}
}

public extension Scene.Roll {

	/// How a line is to be measured. Injected so that the arithmetic can be
	/// tested without a font: the layout is a great deal of adding up, and the
	/// one part of it that needs CoreText is the width of a string.
	///
	/// The frame size is not a parameter because it is not the caller's to
	/// choose: ``laidOut(in:project:measure:)`` was given one, and a measurement
	/// taken at a different size would place the words somewhere they are not.
	typealias Measuring = @Sendable (_ text: String, _ style: TextStyle, _ tracking: Double) -> CGSize

	/// The roll, laid out: every line with its own offset from the middle of
	/// the column.
	///
	/// Offsets rather than absolute positions, because where the column *is* is
	/// the part's `x` and `y` like any other part's. Both render paths and the
	/// editor's hit-testing ask this one function, so a name is in the same
	/// place in the preview, in the export, and under the mouse.
	struct Layout: Sendable, Equatable {
		public struct Line: Sendable, Equatable {
			public var text: String
			public var style: TextStyle
			public var tracking: Double
			/// The middle of this line, from the middle of the column, in
			/// pixels, y upwards.
			public var offset: CGPoint
			public var size: CGSize

			public init(
				text: String, style: TextStyle, tracking: Double,
				offset: CGPoint, size: CGSize
			) {
				self.text = text
				self.style = style
				self.tracking = tracking
				self.offset = offset
				self.size = size
			}
		}

		public var lines: [Line]
		/// The whole column, in pixels.
		public var size: CGSize

		public init(lines: [Line] = [], size: CGSize = .zero) {
			self.lines = lines
			self.size = size
		}
	}

	/// Which column a line belongs to, while it is being placed.
	private enum Side {
		/// Ranged right against the rule down the middle.
		case role
		/// Ranged left from it.
		case name
		/// The title, which belongs to the column rather than to either side.
		case whole
	}

	/// The roll, laid out in a frame of this size.
	///
	/// Vertical spacing needs no measurement at all — it is the line height,
	/// the type sizes and the gaps — which is why ``height(in:project:)`` can
	/// be exact without a font, and why the generator can write a scroll that
	/// carries the whole column past the frame.
	func laidOut(
		in size: CGSize, project: Project, with parameters: [String: String] = [:],
		measure: Measuring? = nil
	) -> Layout {
		let measure = measure ?? { text, style, tracking in
			OverlayLayers.measured(text, style: style, size: size, tracking: tracking)
		}
		// Filled in here rather than where the words are drawn, because the
		// column is measured from them: a roll saying `{{year}}` laid out on the
		// placeholder and drawn on the answer would line up on neither.
		func said(_ text: String) -> String { Scene.fill(text, with: parameters) }
		let names = project.style(named: style)
		let roles = roleStyle.map { project.style(named: $0) } ?? names
		let titles = titleStyle.map { project.style(named: $0) } ?? roles
		let lineHeight = line * size.height
		// Proportional to the type size, so a bigger line takes more room. A
		// style with no size at all would divide by nothing, so it does not.
		let base = names.size > 0 ? names.size : 1
		func advance(_ style: TextStyle) -> Double { lineHeight * (style.size / base) }

		/// Where a line is on the way down: what it says, in what, how tall its
		/// row is, and which side of the rule it is on.
		var placed: [(text: String, style: TextStyle, side: Side, top: Double, height: Double)] = []
		var cursor = 0.0

		if let title, !title.isEmpty {
			let height = advance(titles)
			placed.append((said(title), titles, .whole, cursor, height))
			cursor += height + gap * lineHeight
		}

		for (index, entry) in entries.enumerated() {
			if index > 0 { cursor += gap * lineHeight }
			switch align {
			case .columns:
				// The role sits on the first of the block's rows, beside the
				// first name, which is what makes it read as one block rather
				// than as a heading.
				let rows = max(entry.names.count, entry.role.isEmpty ? 0 : 1)
				for row in 0 ..< rows {
					let underName = row < entry.names.count ? advance(names) : 0
					let underRole = row == 0 && !entry.role.isEmpty ? advance(roles) : 0
					let height = max(underName, underRole)
					if row == 0, !entry.role.isEmpty {
						placed.append((said(entry.role), roles, .role, cursor, height))
					}
					if row < entry.names.count {
						placed.append((said(entry.names[row]), names, .name, cursor, height))
					}
					cursor += height
				}
			case .centre, .left:
				if !entry.role.isEmpty {
					let height = advance(roles)
					placed.append((said(entry.role), roles, .whole, cursor, height))
					cursor += height
				}
				for name in entry.names {
					let height = advance(names)
					placed.append((said(name), names, .whole, cursor, height))
					cursor += height
				}
			}
		}
		guard !placed.isEmpty else { return Layout() }
		let tall = cursor

		// Across. The rule between the columns is at nought while the two sides
		// are placed against it; where that lands the column as a whole is
		// worked out afterwards, from the box the lines came to.
		let widths = placed.map { measure($0.text, $0.style, tracking) }
		let divider = column * size.height / 2
		var centres = [Double](repeating: 0, count: placed.count)
		for (index, entry) in placed.enumerated() {
			switch (align, entry.side) {
			case (.columns, .role): centres[index] = -divider - widths[index].width / 2
			case (.columns, .name): centres[index] = divider + widths[index].width / 2
			case (.left, _): centres[index] = widths[index].width / 2
			default: break   // the title, and everything in a centred roll
			}
		}
		// The title is centred on the column the entries made, not on the rule:
		// a roll whose names are longer than its roles has its middle to the
		// right of the rule, and a title centred on the rule would sit visibly
		// off it. Left-ranged, it starts at the same edge as everything else,
		// which is nought by construction.
		if align == .columns {
			let sides = placed.indices.filter { placed[$0].side != .whole }
			if !sides.isEmpty {
				let low = sides.map { centres[$0] - widths[$0].width / 2 }.min() ?? 0
				let high = sides.map { centres[$0] + widths[$0].width / 2 }.max() ?? 0
				let middle = (low + high) / 2
				for index in placed.indices where placed[index].side == .whole {
					centres[index] = middle
				}
			}
		}
		let low = placed.indices.map { centres[$0] - widths[$0].width / 2 }.min() ?? 0
		let high = placed.indices.map { centres[$0] + widths[$0].width / 2 }.max() ?? 0
		let middle = (low + high) / 2

		let lines = placed.indices.map { index in
			Layout.Line(
				text: placed[index].text, style: placed[index].style, tracking: tracking,
				offset: CGPoint(
					x: centres[index] - middle,
					// Measured down from the top while it was laid out, and the
					// frame counts up, so the top of the column is +half.
					y: tall / 2 - (placed[index].top + placed[index].height / 2)),
				size: widths[index])
		}
		return Layout(lines: lines, size: CGSize(width: high - low, height: tall))
	}

	/// How tall the column is, in fractions of the frame height.
	///
	/// What a scroll is written against: a roll whose column is 2.4 frames tall
	/// starts at `y: -1.2` and ends at `y: 2.4` to carry every line from below
	/// the frame to above it. No measurement needed, because nothing about the
	/// height of a column depends on how wide its words are.
	func height(in size: CGSize, project: Project) -> Double {
		guard size.height > 0 else { return 0 }
		let laid = laidOut(in: size, project: project, measure: { _, _, _ in .zero })
		return laid.size.height / size.height
	}

	/// The names as they are now, with every derived block brought up to date.
	///
	/// Blocks that say nothing about where they came from are left exactly as
	/// they are, in place — which is the whole point of the marker. A block
	/// whose role somebody rewrote keeps the rewrite; only the names under it
	/// are replaced.
	func regenerated(cast: [String]) -> Scene.Roll {
		var out = self
		for index in out.entries.indices where out.entries[index].source == .cast {
			out.entries[index].names = cast
		}
		return out
	}
}
