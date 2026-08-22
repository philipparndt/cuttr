import AppKit
import CuttrCompose
import CuttrKit

/// One row of the material tree, drawn rather than assembled.
///
/// Four things have to fit in a narrow column — what kind it is, what it is
/// called, what it is called in the file, and its tags — and stacked text
/// fields would spend most of the width on the gaps between them. This is the
/// library's row, which had the same problem and solved it the same way, with
/// the take and meme rows added.
///
/// The one exception is a take being renamed. That needs a real field, because
/// what it needs is a text editor; it is put over the row for as long as the
/// rename lasts and taken away again.
@MainActor
final class MaterialRow: NSTableCellView {

	var row: Material.Row = .root(.takes) {
		didSet { needsDisplay = true }
	}

	var isRenaming = false {
		didSet { renamingChanged() }
	}

	/// Whether this row is the selected one, and whether its list has the
	/// keyboard.
	///
	/// The row draws its own words, so it has to know: `faintText` is a heading
	/// against the panel and is barely there against the lifted ground a
	/// selected row sits on, and unreadable against the lit one. Everything
	/// here brightens by the same step, so the row keeps its shape and only its
	/// contrast changes.
	var isChosen = false { didSet { needsDisplay = true } }
	var isLit = false { didSet { needsDisplay = true } }

	/// A selected row is read against a ground two steps lighter than the
	/// panel, and a lit one against a ground lighter still. Grey-on-grey at
	/// that point is not dim, it is gone — so both of the quieter inks step up
	/// with the ground rather than only one of them.
	private var dim: NSColor {
		guard isChosen else { return Theme.dimText }
		return isLit ? Theme.text : Theme.dimText
	}

	private var faint: NSColor {
		guard isChosen else { return Theme.faintText }
		return isLit ? Theme.text : Theme.dimText
	}

	var onRenamed: ((String) -> Void)?

	private var field: NSTextField?

	/// A cell view is resized by the table as the column changes, and a
	/// layer-backed one keeps whatever it drew at its old width until something
	/// marks it dirty.
	override func setFrameSize(_ newSize: NSSize) {
		super.setFrameSize(newSize)
		needsDisplay = true
	}

	override func draw(_ dirtyRect: NSRect) {
		guard !isRenaming else { return }
		let bounds = self.bounds
		switch row {
		case .root(let root):
			heading(root.title, kind: root.kind, in: bounds)

		case .take(let name, _, let clips, let problem):
			mark(.take)
			primary(name, x: 26, y: bounds.height - 16)
			// The count the takes table had as a column, and what went wrong
			// instead when something did: a moved take is the commonest fault
			// in a project and this is where it should be said.
			if let problem {
				_ = secondary(problem, x: 26, y: bounds.height - 28, colour: Theme.playhead)
			} else {
				_ = secondary("\(clips) clip\(clips == 1 ? "" : "s")", x: 26,
				              y: bounds.height - 28, colour: dim)
			}

		case .folder(let name, let held):
			mark(.section)
			primary(name, x: 26, y: bounds.height - 16)
			// An empty folder says so rather than saying "0 takes", which reads
			// as a count that failed rather than as a folder waiting to be
			// filled — and waiting to be filled is what it is for.
			_ = secondary(held == 0 ? "empty" : "\(held) take\(held == 1 ? "" : "s")",
			              x: 26, y: bounds.height - 28, colour: dim)

		case .memes(let count):
			mark(.take)
			primary("memes", x: 26, y: bounds.height - 16)
			_ = secondary("\(count) borrowed", x: 26, y: bounds.height - 28,
			              colour: dim)

		case .clip(let item):
			// The lane it was cut on, as a stripe against the words rather than
			// against the edge of the row: it is the *clip* that was cut on
			// that lane, and the clip is its name.
			mark(.clip)
			Theme.clipStripe(item.color).setFill()
			NSRect(x: 19, y: 3, width: 3, height: bounds.height - 6).fill()
			primary(item.reference, x: 26, y: bounds.height - 16)
			var offset = secondary(
				item.length > 0 ? Timecode.string(item.length) : "", x: 26,
				y: bounds.height - 28, colour: dim)
			offset += 16
			for tag in item.tags.prefix(3) {
				offset += chip(tag, at: offset, y: bounds.height - 29) + 4
				if offset > bounds.width - 30 { break }
			}

		case .scene(let name):
			mark(.scene)
			primary(name, x: 26, y: bounds.height - 16)
			_ = secondary("double-click to edit", x: 26, y: bounds.height - 28,
			              colour: dim)

		case .anchor(let name, let take):
			mark(.anchor)
			primary(name, x: 26, y: bounds.height - 16)
			_ = secondary(take, x: 26, y: bounds.height - 28, colour: dim)

		case .tag(let name, let count):
			mark(.tag)
			primary("#\(name)", x: 26, y: bounds.height - 16)
			_ = secondary("\(count) clip\(count == 1 ? "" : "s")", x: 26,
			              y: bounds.height - 28, colour: dim)
		}
	}

	// MARK: - The parts

	private func heading(_ title: String, kind: Theme.Kind?, in bounds: NSRect) {
		var x: CGFloat = 4
		if let kind, let image = Theme.symbol(kind, size: 10, colour: faint) {
			Theme.draw(image, in: NSRect(x: x, y: bounds.height - 17, width: 13, height: 14))
			x += 17
		}
		(title.uppercased() as NSString).draw(
			at: NSPoint(x: x, y: bounds.height - 15),
			withAttributes: [.font: Theme.heading, .foregroundColor: faint])
		Theme.rule.setFill()
		NSRect(x: 4, y: 3, width: bounds.width - 8, height: 1).fill()
	}

	private func mark(_ kind: Theme.Kind) {
		guard let image = Theme.symbol(kind) else { return }
		Theme.draw(image, in: NSRect(x: 2, y: bounds.height / 2 - 8, width: 16, height: 16))
	}

	private func primary(_ text: String, x: CGFloat, y: CGFloat) {
		(text as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [
			.font: Theme.bodyStrong, .foregroundColor: Theme.text,
		])
	}

	@discardableResult
	private func secondary(_ text: String, x: CGFloat, y: CGFloat,
	                       colour: NSColor) -> CGFloat {
		guard !text.isEmpty else { return x }
		let attributes: [NSAttributedString.Key: Any] = [
			.font: Theme.monoSmall, .foregroundColor: colour,
		]
		(text as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attributes)
		return x + (text as NSString).size(withAttributes: attributes).width
	}

	@discardableResult
	private func chip(_ text: String, at x: CGFloat, y: CGFloat) -> CGFloat {
		let attributes: [NSAttributedString.Key: Any] = [
			.font: Theme.monoSmall, .foregroundColor: Theme.color(.tag),
		]
		let size = (text as NSString).size(withAttributes: attributes)
		let box = NSRect(x: x, y: y, width: size.width + 8, height: 13)
		Theme.color(.tag).withAlphaComponent(0.16).setFill()
		NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3).fill()
		(text as NSString).draw(at: NSPoint(x: x + 4, y: y + 1), withAttributes: attributes)
		return box.width
	}

	// MARK: - Renaming

	/// A real field, only while the rename lasts.
	///
	/// Everything else here is drawn, because a row of stacked fields spends
	/// its width on gaps — but a rename needs a text editor and there is no
	/// drawing one of those.
	private func renamingChanged() {
		guard isRenaming else {
			field?.removeFromSuperview()
			field = nil
			needsDisplay = true
			return
		}
		guard field == nil, case .take(let name, _, _, _) = row else { return }
		let made = NSTextField(string: name)
		made.font = Theme.bodyStrong
		made.isBordered = false
		made.drawsBackground = true
		made.backgroundColor = Theme.card
		made.target = self
		made.action = #selector(committed)
		made.translatesAutoresizingMaskIntoConstraints = false
		addSubview(made)
		NSLayoutConstraint.activate([
			made.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 26),
			made.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
			made.centerYAnchor.constraint(equalTo: centerYAnchor),
		])
		field = made
		window?.makeFirstResponder(made)
	}

	@objc private func committed() {
		guard let field else { return }
		onRenamed?(field.stringValue)
	}
}
