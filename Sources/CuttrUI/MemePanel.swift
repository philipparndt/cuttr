import AppKit
import CuttrKit

/// Find a meme, and put it in the project.
///
/// A sheet over the project window, like every other dialog here. What it does
/// is deliberately narrow: search a service, show what came back, download the
/// one somebody picked. From the moment it lands there is nothing special about
/// it — it is a take with one clip in it, in the library with everything else,
/// dragged onto the programme the same way — and that is the whole design, so
/// this panel has no business knowing about the timeline.
///
/// Nothing here blocks the main thread. The search and the download are `async`
/// and the window stays live throughout, which matters more than usual: a
/// provider that has gone quiet takes fifteen seconds to say so.
@MainActor
public final class MemePanel: NSViewController {

	/// What to do with the one that was chosen. Returns the reference a project
	/// would write for it. Handed in rather than done here, because writing a
	/// take into a project is the project window's business.
	public typealias Download = (MemeResult) async throws -> String

	private let download: Download
	private let onAdded: (String) -> Void

	private var provider: MemeProvider
	private var results: [MemeResult] = []
	private var working = false

	private let providerButton = NSPopUpButton()
	private let searchField = NSSearchField()
	private let grid = MemeGrid()
	private let messageLabel = NSTextField(labelWithString: "")
	private let attributionLabel = NSTextField(labelWithString: "")
	private let addButton = NSButton()
	private let settingsButton = NSButton()
	private let spinner = NSProgressIndicator()
	private var searchTask: Task<Void, Never>?
	private var hosted: NSWindow?

	public init(download: @escaping Download, onAdded: @escaping (String) -> Void) {
		self.download = download
		self.onAdded = onAdded
		self.provider = MemeKeys.firstUsable()
		super.init(nibName: nil, bundle: nil)
	}

	@available(*, unavailable) required init?(coder: NSCoder) { nil }

	public static func present(over view: NSView, download: @escaping Download,
	                           onAdded: @escaping (String) -> Void) {
		guard let window = view.window else { return }
		let panel = MemePanel(download: download, onAdded: onAdded)
		window.beginSheet(panel.sheet()) { _ in }
	}

	private func sheet() -> NSWindow {
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
		                      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
		window.contentViewController = self
		window.title = "Find a meme"
		window.isReleasedWhenClosed = false
		window.minSize = NSSize(width: 520, height: 380)
		hosted = window
		return window
	}

	// MARK: - Building it

	public override func loadView() {
		let root = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 560))
		root.wantsLayer = true
		root.layer?.backgroundColor = Theme.card.cgColor

		for service in MemeProvider.allCases {
			providerButton.addItem(withTitle: service.displayName)
		}
		providerButton.selectItem(at: MemeProvider.allCases.firstIndex(of: provider) ?? 0)
		providerButton.target = self
		providerButton.action = #selector(providerChanged)
		providerButton.font = Theme.body

		searchField.placeholderString = "facepalm, shrug, mind blown…"
		searchField.font = Theme.body
		searchField.target = self
		searchField.action = #selector(searchNow)
		// Typed-into rather than typed-at: the whole search is one request and
		// a request per keystroke would spend a rate limit in a sentence.
		searchField.sendsWholeSearchString = true

		spinner.style = .spinning
		spinner.controlSize = .small
		spinner.isDisplayedWhenStopped = false

		let top = NSStackView(views: [providerButton, searchField, spinner])
		top.orientation = .horizontal
		top.spacing = 8
		top.alignment = .centerY

		grid.onSelect = { [weak self] _ in self?.updateButtons() }
		grid.onChoose = { [weak self] _ in self?.add() }
		// The grid is placed by constraints, not by its own frame — without
		// this the width constraint below is fighting the autoresizing mask and
		// loses: the grid stayed the width it was born with, so it worked out
		// that it had room for one column and the scroll view had nothing to
		// scroll.
		grid.translatesAutoresizingMaskIntoConstraints = false
		let scroll = TableScroll.wrap(grid, horizontal: false)
		scroll.drawsBackground = true
		scroll.backgroundColor = Theme.background
		scroll.borderType = .noBorder

		messageLabel.font = Theme.body
		messageLabel.textColor = Theme.dimText
		messageLabel.lineBreakMode = .byWordWrapping
		messageLabel.maximumNumberOfLines = 3

		// The mark the service's terms require, wherever its results are shown.
		attributionLabel.font = Theme.monoSmall
		attributionLabel.textColor = Theme.faintText

		configure(settingsButton, "Settings…", #selector(openSettings))
		configure(addButton, "Add to Project", #selector(add))
		addButton.keyEquivalent = "\r"
		addButton.isEnabled = false
		let cancel = NSButton(title: "Cancel", target: self, action: #selector(close))
		cancel.bezelStyle = .rounded
		cancel.keyEquivalent = "\u{1b}"

		for view in [top, scroll, messageLabel, attributionLabel, settingsButton,
		             addButton, cancel] as [NSView] {
			view.translatesAutoresizingMaskIntoConstraints = false
			root.addSubview(view)
		}
		NSLayoutConstraint.activate([
			top.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
			top.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
			top.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),

			scroll.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 10),
			scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
			scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
			scroll.bottomAnchor.constraint(equalTo: messageLabel.topAnchor, constant: -8),

			messageLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
			messageLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
			messageLabel.bottomAnchor.constraint(equalTo: attributionLabel.topAnchor, constant: -6),

			attributionLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
			attributionLabel.bottomAnchor.constraint(equalTo: addButton.topAnchor, constant: -8),

			settingsButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
			settingsButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),

			addButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
			addButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
			cancel.trailingAnchor.constraint(equalTo: addButton.leadingAnchor, constant: -8),
			cancel.bottomAnchor.constraint(equalTo: addButton.bottomAnchor),

			// The grid is as wide as the pane and as tall as its contents,
			// which is what makes it scroll vertically and never sideways.
			grid.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
		])
		// The size the sheet opens at, said in constraints as well as in the
		// window's frame.
		//
		// A window whose `contentViewController` is set takes its size from the
		// view's own fitting size, and a view laid out entirely with edge
		// constraints has none worth having: the meme panel came up as a column
		// one search field wide, with the grid and the buttons squeezed into a
		// sliver. The preferred size is what it wants, the minimums are what it
		// will not go below, and both are needed.
		preferredContentSize = NSSize(width: 720, height: 560)
		let wide = root.widthAnchor.constraint(equalToConstant: 720)
		let tall = root.heightAnchor.constraint(equalToConstant: 560)
		for wish in [wide, tall] {
			wish.priority = NSLayoutConstraint.Priority(250)
			wish.isActive = true
		}
		NSLayoutConstraint.activate([
			root.widthAnchor.constraint(greaterThanOrEqualToConstant: 520),
			root.heightAnchor.constraint(greaterThanOrEqualToConstant: 380),
		])
		view = root
		show(attribution: provider)
		sayHowToStart()
	}

	private func configure(_ button: NSButton, _ title: String, _ action: Selector) {
		button.title = title
		button.bezelStyle = .rounded
		button.target = self
		button.action = action
	}

	public override func viewDidAppear() {
		super.viewDidAppear()
		view.window?.makeFirstResponder(searchField)
	}

	public override func viewWillDisappear() {
		super.viewWillDisappear()
		searchTask?.cancel()
	}

	// MARK: - Searching

	@objc private func providerChanged() {
		provider = MemeProvider.allCases[max(0, providerButton.indexOfSelectedItem)]
		show(attribution: provider)
		results = []
		grid.show([])
		if searchField.stringValue.isEmpty { sayHowToStart() } else { searchNow() }
	}

	/// What the panel says before anybody has typed anything — which is either
	/// how to start, or that there is no key and where to put one.
	private func sayHowToStart() {
		if MemeKeys.key(for: provider) == nil {
			say(MemeError.noKey(provider), asProblem: true)
		} else {
			say("Search \(provider.displayName). What arrives is a take with one clip in it, "
				+ "in the library under memes.")
		}
	}

	@objc func searchNow() {
		let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !query.isEmpty else { sayHowToStart(); return }
		guard let key = MemeKeys.key(for: provider) else {
			say(MemeError.noKey(provider), asProblem: true)
			return
		}
		searchTask?.cancel()
		working = true
		spinner.startAnimation(nil)
		say("searching \(provider.displayName)…")
		let provider = self.provider
		searchTask = Task { [weak self] in
			do {
				let found = try await MemeSearch.search(query, provider: provider, key: key)
				guard !Task.isCancelled, let self else { return }
				self.finished(found, query: query)
			} catch {
				guard !Task.isCancelled, let self else { return }
				self.working = false
				self.spinner.stopAnimation(nil)
				self.say(error, asProblem: true)
			}
		}
	}

	private func finished(_ found: [MemeResult], query: String) {
		working = false
		spinner.stopAnimation(nil)
		results = found
		grid.show(found)
		updateButtons()
		if found.isEmpty {
			say("\(provider.displayName) has nothing for \(query.debugDescription).")
		} else {
			// Said once, here, because it is the first thing somebody notices
			// after adding one: a meme from a GIF search has no sound. Both
			// services serve them as silent mp4s — they are GIFs underneath.
			say("\(found.count) from \(provider.displayName). "
				+ "Double-click one, or choose it and press Add. These are GIFs: no sound.")
			view.window?.makeFirstResponder(grid)
		}
	}

	// MARK: - Taking one

	@objc func add() {
		guard !working, let chosen = grid.chosen else { return }
		working = true
		updateButtons()
		spinner.startAnimation(nil)
		say("downloading \(chosen.title.isEmpty ? chosen.id : chosen.title)…")
		Task { [weak self] in
			guard let self else { return }
			do {
				let reference = try await self.download(chosen)
				self.onAdded(reference)
				self.close()
			} catch {
				self.working = false
				self.spinner.stopAnimation(nil)
				self.updateButtons()
				self.say(error, asProblem: true)
			}
		}
	}

	@objc private func openSettings() {
		SettingsSheet.present(over: view) { [weak self] in
			// A key that has just been pasted in should work without the panel
			// being reopened, so whatever was said about not having one is
			// said again — or not.
			guard let self else { return }
			if self.results.isEmpty { self.sayHowToStart() }
			if !self.searchField.stringValue.isEmpty, MemeKeys.key(for: self.provider) != nil {
				self.searchNow()
			}
		}
	}

	private func updateButtons() {
		addButton.isEnabled = !working && grid.chosen != nil
	}

	private func say(_ message: String, asProblem: Bool = false) {
		messageLabel.stringValue = message
		messageLabel.textColor = asProblem ? Theme.base(.rose) : Theme.dimText
	}

	private func say(_ error: Error, asProblem: Bool) {
		say(error.localizedDescription, asProblem: asProblem)
	}

	private func show(attribution provider: MemeProvider) {
		attributionLabel.stringValue = provider.attribution
	}

	@objc private func close() {
		searchTask?.cancel()
		guard let window = view.window else { return }
		window.sheetParent?.endSheet(window)
		hosted = nil
	}

	// MARK: - For the tests

	var shown: [MemeResult] { results }
	var message: String { messageLabel.stringValue }
	var attribution: String { attributionLabel.stringValue }
	func present(_ found: [MemeResult]) { finished(found, query: "test") }
	/// For the tests: what the grid has picked, and where a tile is.
	var chosenForTesting: MemeResult? { grid.chosen }
	func tileFrameForTesting(_ index: Int) -> NSRect { grid.tileFrame(index) }
	func choose(_ index: Int) { grid.select(index); updateButtons() }
	var canAdd: Bool { addButton.isEnabled }
}

/// The results, as tiles.
///
/// Hand-drawn, like the library's rows and the programme's strip: a tile is a
/// picture with a line of text under it, and a view hierarchy per result would
/// be two hundred views to say that.
///
/// The thumbnails are stills, not the animations. Twenty animated GIFs decoding
/// at once while somebody reads the titles is a lot of machine for very little,
/// and both services offer a still of every item precisely so that a picker does
/// not have to. What the meme actually does can be seen once it is on the
/// programme, which is a second away.
@MainActor
final class MemeGrid: NSView {

	var onSelect: ((MemeResult) -> Void)?
	var onChoose: ((MemeResult) -> Void)?

	private var results: [MemeResult] = []
	private var thumbnails: [String: NSImage] = [:]
	private var selected: Int?
	private var loading: [Task<Void, Never>] = []

	private let tile = NSSize(width: 168, height: 148)
	private let gap: CGFloat = 10
	private let picture: CGFloat = 108

	override var isFlipped: Bool { true }
	override var acceptsFirstResponder: Bool { true }

	var chosen: MemeResult? {
		guard let selected, results.indices.contains(selected) else { return nil }
		return results[selected]
	}

	func show(_ results: [MemeResult]) {
		for task in loading { task.cancel() }
		loading = []
		self.results = results
		thumbnails = [:]
		selected = results.isEmpty ? nil : 0
		invalidateIntrinsicContentSize()
		needsDisplay = true
		fetchThumbnails()
	}

	func select(_ index: Int) {
		guard results.indices.contains(index) else { return }
		selected = index
		needsDisplay = true
		onSelect?(results[index])
	}

	/// Every still, at once and off the main thread. They are a few kilobytes
	/// each and there are two dozen of them; a queue with a width would be more
	/// code than the thing it manages.
	private func fetchThumbnails() {
		for result in results {
			guard let url = result.preview else { continue }
			let id = result.id
			loading.append(Task { [weak self] in
				guard let (data, _) = try? await URLSession.shared.data(from: url),
				      let image = NSImage(data: data), !Task.isCancelled else { return }
				guard let self else { return }
				self.thumbnails[id] = image
				self.needsDisplay = true
			})
		}
	}

	// MARK: - Where things go

	private var columns: Int { max(1, Int((bounds.width - gap) / (tile.width + gap))) }

	/// For the tests: where a tile is, without reaching into the layout.
	func tileFrame(_ index: Int) -> NSRect { frame(of: index) }

	private func frame(of index: Int) -> NSRect {
		let column = index % columns, row = index / columns
		return NSRect(x: gap + CGFloat(column) * (tile.width + gap),
		              y: gap + CGFloat(row) * (tile.height + gap),
		              width: tile.width, height: tile.height)
	}

	override var intrinsicContentSize: NSSize {
		let rows = (results.count + columns - 1) / columns
		return NSSize(width: NSView.noIntrinsicMetric,
		              height: max(1, CGFloat(rows) * (tile.height + gap) + gap))
	}

	override func setFrameSize(_ newSize: NSSize) {
		super.setFrameSize(newSize)
		// The number of columns follows the width, so the height does too.
		invalidateIntrinsicContentSize()
		needsDisplay = true
	}

	// MARK: - Drawing

	override func draw(_ dirtyRect: NSRect) {
		Theme.background.setFill()
		bounds.fill()
		guard !results.isEmpty else { return }

		for (index, result) in results.enumerated() {
			let box = frame(of: index)
			guard box.intersects(dirtyRect) else { continue }
			let chosen = index == selected

			(chosen ? Theme.cardHigh : Theme.card).setFill()
			let path = NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5)
			path.fill()
			if chosen {
				Theme.accent.setStroke()
				path.lineWidth = 2
				path.stroke()
			}

			let slot = NSRect(x: box.minX + 6, y: box.minY + 6,
			                  width: box.width - 12, height: picture)
			NSColor.black.withAlphaComponent(0.35).setFill()
			NSBezierPath(roundedRect: slot, xRadius: 3, yRadius: 3).fill()
			if let image = thumbnails[result.id] {
				NSGraphicsContext.saveGraphicsState()
				NSBezierPath(roundedRect: slot, xRadius: 3, yRadius: 3).addClip()
				image.draw(in: Theme.fit(image.size, in: slot))
				NSGraphicsContext.restoreGraphicsState()
			}

			let name = result.title.isEmpty ? result.id : result.title
			(name as NSString).draw(
				in: NSRect(x: box.minX + 7, y: slot.maxY + 5,
				           width: box.width - 14, height: 26),
				withAttributes: [.font: Theme.monoSmall, .foregroundColor: Theme.text])
			if result.size.width > 0 {
				let size = "\(Int(result.size.width))×\(Int(result.size.height))"
				(size as NSString).draw(
					at: NSPoint(x: box.minX + 7, y: box.maxY - 15),
					withAttributes: [.font: Theme.monoSmall, .foregroundColor: Theme.faintText])
			}
		}
	}

	// MARK: - Picking one

	override func mouseDown(with event: NSEvent) {
		let point = convert(event.locationInWindow, from: nil)
		guard let index = results.indices.first(where: { frame(of: $0).contains(point) }) else {
			return
		}
		window?.makeFirstResponder(self)
		select(index)
		if event.clickCount >= 2 { onChoose?(results[index]) }
	}

	override func keyDown(with event: NSEvent) {
		guard !results.isEmpty else { return super.keyDown(with: event) }
		let current = selected ?? 0
		switch event.keyCode {
		case 123: move(to: current - 1)          // left
		case 124: move(to: current + 1)          // right
		case 126: move(to: current - columns)    // up
		case 125: move(to: current + columns)    // down
		case 36: if let chosen { onChoose?(chosen) }   // return
		default: super.keyDown(with: event)
		}
	}

	private func move(to index: Int) {
		guard results.indices.contains(index) else { return }
		select(index)
		scrollToVisible(frame(of: index).insetBy(dx: 0, dy: -gap))
	}
}
