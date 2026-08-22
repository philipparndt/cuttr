import AppKit

/// A document, as the content of a window rather than the owner of one.
///
/// **One window, and the document in it changes.** That is the model, and the
/// three editors in this program — the cutting window, the composing window,
/// the scene window — are the three things that can be in it. None of them
/// makes an `NSWindow` any more; each builds a view and hands it over, and a
/// ``DocumentPlace`` puts one of them on screen at a time.
///
/// What this replaces looked the same and was not. Every document had a window
/// of its own, all at one frame, and switching ordered one in and the rest out.
/// From the inside that is "the contents changed"; from the outside it is
/// several windows — the Window menu listed them all, Mission Control showed a
/// row of them, and the one being revealed came up with a flicker as macOS
/// faded a window in rather than redrawing a view. The user said so twice: "it
/// still seems to open a new window instead of just switching the contents".
///
/// The subclass keeps its whole view tree between turns on screen, which is
/// what makes a switch cheap and, more to the point, *lossless*: scroll
/// positions, split-view dividers, which rail item is lit, the selection, the
/// zoom of a timeline are all facts about views that are still there. The two
/// things a view tree does not carry are the keyboard focus — the window's, not
/// the view's — and anything written into the shared bar, so those are
/// remembered here and put back by ``appear(in:)``.
@MainActor
public class DocumentEditor: NSWindowController {

	/// The view this document *is*. Set by the subclass while it builds.
	var contentRoot = NSView()

	/// What the window will not go below while this document is in it.
	var minimumSize = NSSize(width: 900, height: 600)

	/// How big a window opens when this document is the first thing in it.
	var openingSize = NSSize(width: 1280, height: 800)

	/// Where the keyboard goes the first time this document appears.
	var initialResponder: NSView?

	/// Where the keyboard was when it last left, which is where it goes back
	/// to. A window's first responder is the window's, so swapping the content
	/// view drops it — and a take whose timeline had the keyboard has to come
	/// back with the timeline holding it, or the first `space` does nothing.
	private weak var lastResponder: NSView?

	/// The place holding this document, whether or not it is the one showing.
	private(set) weak var place: DocumentPlace?

	/// The window, and only while this document is the one on screen.
	///
	/// Overridden rather than inherited, over storage of our own. Two things
	/// come from that. `NSWindowController`'s own getter loads a nib when it has
	/// no window, and these have no nib — so every `window?.firstResponder` on a
	/// document that is off screen would go looking for one. And `nil` while
	/// hidden is exactly what the key monitors want: each editor installs a
	/// local monitor that answers only `event.window === self.window`, so with
	/// three documents open in one window precisely one of them hears a key.
	public override var window: NSWindow? {
		get { host }
		set { host = newValue }
	}

	private weak var host: NSWindow?

	/// The bar across the top of the window. The place owns it — it is one bar
	/// that says which document you are in, not one per document — so it is
	/// `nil` for a document that is not on screen, and writing to it then is
	/// meant to be a no-op rather than a message that overwrites what somebody
	/// is looking at.
	var bar: DocumentBar? { place?.showing === self ? place?.bar : nil }

	init() { super.init(window: nil) }

	@available(*, unavailable) required init?(coder: NSCoder) { nil }

	// MARK: - What the place asks

	/// The window's title while this document is in it, for the Window menu and
	/// for ⌘-clicking the proxy icon.
	var documentTitle: String { "" }
	/// The file, for the same two things.
	var documentFile: URL? { nil }
	/// Whether the title bar should say there is something unsaved.
	var documentIsEdited: Bool { false }
	/// The undo manager the responder chain gets while this is on screen.
	var documentUndoManager: UndoManager? { nil }

	/// Furnishes the shared bar: the name, the clock, and whatever controls
	/// this document puts in it. Called with a bar that has just been cleared.
	func furnish(_ bar: DocumentBar) {}

	/// On screen. Everything the view tree does not carry is put back by now.
	func documentAppeared() {}
	/// Off screen, still open. Stop anything that makes noise or draws.
	func documentHidden() {}
	/// Gone. Cancel the tasks, drop the monitors.
	func documentClosed() {}

	/// Whether it can be closed, or whether somebody has to be asked first.
	func mayClose() -> Bool { true }

	func placeDidResize() {}
	func placeDidExitFullScreen() {}

	// MARK: - Coming and going

	/// `nil` when a place lets go of it, so a document in no place says so.
	func adopted(by place: DocumentPlace?) { self.place = place }

	func appear(in window: NSWindow) {
		self.window = window
		window.windowController = self
		window.minSize = minimumSize
		// A window handed a document with a larger minimum than the one it was
		// showing has to grow to it, or AppKit resizes it for us and the frame
		// somebody arranged is gone.
		if window.frame.width < minimumSize.width || window.frame.height < minimumSize.height {
			var frame = window.frame
			frame.size.width = max(frame.width, minimumSize.width)
			frame.size.height = max(frame.height, minimumSize.height)
			window.setFrame(frame, display: false)
		}
		window.title = documentTitle
		window.representedURL = documentFile
		window.isDocumentEdited = documentIsEdited
		if let bar = place?.bar {
			bar.reset()
			furnish(bar)
		}
		place?.host(contentRoot)
		// Said to the window as well as done, because AppKit picks a first
		// responder of its own when a window becomes key and it picks the first
		// text field it can find. On the project page that is the output's frame
		// width, so a window would come up with a cursor blinking in the size of
		// the film — and the properties panel refuses to rebuild while one of its
		// fields is being edited, so opening a file into that window showed
		// nothing.
		window.initialFirstResponder = initialResponder
		window.makeFirstResponder(lastResponder ?? initialResponder)
		documentAppeared()
	}

	func disappear() {
		if let window, let responder = window.firstResponder as? NSView,
		   responder.isDescendant(of: contentRoot) {
			lastResponder = responder
		}
		if window?.windowController === self { window?.windowController = nil }
		documentHidden()
		window = nil
	}

	/// For the tests: a window with this document in it.
	///
	/// A document does not make a window any more, and most of what the layout
	/// tests measure needs one — a view outside a window has no backing scale,
	/// no traffic lights to clear and no `layoutIfNeeded`. This is the one line
	/// that puts it in a place.
	var windowForTesting: NSWindow {
		if let window { return window }
		return DocumentPlace.forTesting(self).window
	}

	/// Says the title again, from the subclass, when the document's name or its
	/// edited state has changed under it.
	func titleChanged() {
		guard let window else { return }
		window.title = documentTitle
		window.representedURL = documentFile
		window.isDocumentEdited = documentIsEdited
	}
}

/// One window, and the documents that take turns in it.
///
/// A place is a window with a bar across the top and a document underneath.
/// Switching swaps the view under the bar and re-furnishes the bar; the window
/// itself is never touched, so its frame, its screen, its full-screen state and
/// its position in the Window menu are the same afterwards because they are the
/// same window's.
///
/// There can be more than one place, and that is deliberate rather than a
/// leftover. Comparing two takes side by side is a real thing to want, and a
/// model where the only gesture swaps in place cannot do it — so ⌥⌘N moves the
/// document on screen into a place of its own, and ⌥-double-clicking a take in a
/// project opens it into one.
@MainActor
final class DocumentPlace: NSObject, NSWindowDelegate {

	let window: NSWindow

	/// The one bar, at the top, for every document that comes through here.
	///
	/// Which document you are in, where the playhead is, and what just
	/// happened. It belongs to the window because that is what somebody reads
	/// it as: a title bar whose contents change, not a title bar that is
	/// replaced. Building one per document would have worked and would have
	/// been wrong in one visible way — the capsule measures its own inset from
	/// the traffic lights when it moves into a window, so a fresh bar every
	/// switch is a fresh measurement every switch.
	let bar = DocumentBar()

	private(set) var documents: [DocumentEditor] = []
	private(set) weak var showing: DocumentEditor?

	/// Told when this place has closed, and when a document has gone from it.
	var onClose: ((DocumentPlace) -> Void)?
	var onCloseDocument: ((DocumentEditor) -> Void)?

	private let body = NSView()
	private var barHeight: NSLayoutConstraint!

	init(size: NSSize) {
		window = NSWindow(
			contentRect: NSRect(origin: .zero, size: size),
			// `.fullSizeContentView`, so the content runs to the top of the
			// frame and the bar stands in the whole title band — see
			// `DocumentBar.height`.
			styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
			backing: .buffered, defer: false)
		// Not released when closed, which an `NSWindowController` used to say for
		// us: handing a window to one sets this to `false`. A window made by hand
		// and closed sends itself a `release` it does not own under ARC — and
		// this place holds a strong reference to it, so the next touch of that
		// reference is a read of freed memory. ⌘W on the last document in a
		// window segfaulted on exactly this.
		window.isReleasedWhenClosed = false
		window.titlebarAppearsTransparent = true
		window.appearance = NSAppearance(named: .darkAqua)
		window.backgroundColor = Theme.background
		// No tabs, and now there is nothing to tab: a tab bar exists to say
		// which of several windows you are in, and there is one window per place
		// with the capsule saying which document is in it. `.disallowed`
		// declines *automatic* tabbing; the explicit `addTabbedWindow` that
		// used to form a group behind this program's back is gone with the
		// window-per-document model that called it.
		window.tabbingMode = .disallowed
		window.titleVisibility = .hidden
		DocumentBar.growTitleBand(of: window)
		super.init()
		window.delegate = self
		build()
	}

	private func build() {
		let content = NSView()
		content.wantsLayer = true
		content.layer?.backgroundColor = Theme.background.cgColor
		for view in [bar, body] as [NSView] {
			view.translatesAutoresizingMaskIntoConstraints = false
			content.addSubview(view)
		}
		barHeight = bar.heightAnchor.constraint(equalToConstant: DocumentBar.height)
		NSLayoutConstraint.activate([
			bar.topAnchor.constraint(equalTo: content.topAnchor),
			bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
			bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
			barHeight,
			body.topAnchor.constraint(equalTo: bar.bottomAnchor),
			body.leadingAnchor.constraint(equalTo: content.leadingAnchor),
			body.trailingAnchor.constraint(equalTo: content.trailingAnchor),
			body.bottomAnchor.constraint(equalTo: content.bottomAnchor),
		])
		window.contentView = content
	}

	/// Puts a document's view under the bar. Called by the document itself, on
	/// its way on screen.
	func host(_ view: NSView) {
		for old in body.subviews where old !== view { old.removeFromSuperview() }
		guard view.superview !== body else { return }
		view.translatesAutoresizingMaskIntoConstraints = false
		body.addSubview(view)
		NSLayoutConstraint.activate([
			view.topAnchor.constraint(equalTo: body.topAnchor),
			view.leadingAnchor.constraint(equalTo: body.leadingAnchor),
			view.trailingAnchor.constraint(equalTo: body.trailingAnchor),
			view.bottomAnchor.constraint(equalTo: body.bottomAnchor),
		])
	}

	/// The bar away and the document to the top of the frame, for the composing
	/// window's full-screen preview.
	///
	/// The height goes with it. Hidden but still 52 points tall left a black
	/// band across the top of a picture that had asked for the whole screen —
	/// which was the old behaviour, and was invisible only because every window
	/// had a bar of its own to leave a gap under.
	func setBarHidden(_ hidden: Bool) {
		bar.isHidden = hidden
		barHeight.constant = hidden ? 0 : DocumentBar.height
	}

	/// The documents in this place, and the one showing, in the order they
	/// arrived.
	func holds(_ document: DocumentEditor) -> Bool {
		documents.contains { $0 === document }
	}

	func adopt(_ document: DocumentEditor) {
		if !holds(document) { documents.append(document) }
		document.adopted(by: self)
		show(document)
	}

	func show(_ document: DocumentEditor) {
		guard holds(document) else { return }
		guard showing !== document else {
			window.makeKeyAndOrderFront(nil)
			return
		}
		showing?.disappear()
		showing = document
		document.appear(in: window)
		window.makeKeyAndOrderFront(nil)
	}

	/// The next document that should be on screen once `going` is off it — the
	/// one before it in the list, or the one after.
	private func next(after going: DocumentEditor) -> DocumentEditor? {
		guard let index = documents.firstIndex(where: { $0 === going }) else {
			return documents.first
		}
		let rest = Array(documents[..<index].reversed()) + Array(documents[(index + 1)...])
		return rest.first
	}

	/// Takes a document out of this place — for good, or because it is moving to
	/// another one.
	func release(_ document: DocumentEditor, closing: Bool) {
		guard holds(document) else { return }
		let following = next(after: document)
		documents.removeAll { $0 === document }
		if showing === document {
			document.disappear()
			showing = nil
			if let following { show(following) }
		}
		if closing {
			document.documentClosed()
			onCloseDocument?(document)
		}
		document.adopted(by: nil)
		// A place with nothing in it is not a place. The window goes, and the
		// application drops it in `windowWillClose`.
		if documents.isEmpty { window.close() }
	}

	// MARK: - The window's delegate

	/// The showing document's undo manager, so ⌘Z in a field reaches the take
	/// or the scene rather than nothing.
	func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
		showing?.documentUndoManager
	}

	/// Every document in the place gets asked, not only the one on screen: a
	/// window holding three takes with unsaved cuts must not close two of them
	/// silently because only the third was visible.
	func windowShouldClose(_ sender: NSWindow) -> Bool {
		for document in documents where !document.mayClose() { return false }
		return true
	}

	func windowWillClose(_ notification: Notification) {
		showing?.disappear()
		showing = nil
		let going = documents
		documents = []
		for document in going {
			document.documentClosed()
			document.adopted(by: nil)
			onCloseDocument?(document)
		}
		onClose?(self)
	}

	func windowDidResize(_ notification: Notification) { showing?.placeDidResize() }

	/// **The toolbar goes away with the titlebar in full screen, not on its own.**
	///
	/// The toolbar holds no items. It exists for one reason — see
	/// ``DocumentBar/growTitleBand(of:)`` — which is that macOS gives a
	/// `.unified` toolbar a 52-point band and centres the traffic lights in it.
	/// Windowed, it is a transparent strip and the bar shows through.
	///
	/// In full screen a toolbar does *not* hide with the titlebar unless it is
	/// asked to: the menu bar and titlebar slide away and the toolbar stays,
	/// drawn across the top of a content view that now runs to the top of the
	/// screen — over the project capsule and the clock, which is the whole of
	/// what the bar had to say.
	///
	/// Hiding it outright was the first fix and it cost the thing the toolbar is
	/// *for*: with no toolbar there is no band, so when the titlebar does slide
	/// down the traffic lights are no longer centred in anything.
	/// `.autoHideToolbar` is the door that does both — the toolbar stays, so the
	/// band and the buttons in the middle of it are intact every time the
	/// titlebar is on screen, and it goes away *with* the titlebar the rest of
	/// the time, which is when the bar underneath needs to be seen.
	///
	/// Abydos never meets this, and the reason is worth writing down: its
	/// toolbar has real items in it — the capsule, the pills, the run control —
	/// so what is drawn in the band *is* its content. cuttr's bar is a view in
	/// the content view instead, which is what keeps it on screen in full
	/// screen at all, and is why the empty toolbar over it is a problem there
	/// and not here.
	func window(_ window: NSWindow,
	            willUseFullScreenPresentationOptions proposed: NSApplication.PresentationOptions)
		-> NSApplication.PresentationOptions {
		proposed.union(.autoHideToolbar)
	}

	/// The traffic lights go into the sliding titlebar on the way in and come
	/// back on the way out, so the room kept for them is measured again at both
	/// ends.
	func windowDidEnterFullScreen(_ notification: Notification) {
		bar.remeasure()
	}

	func windowDidExitFullScreen(_ notification: Notification) {
		bar.remeasure()
		showing?.placeDidExitFullScreen()
	}

	/// For the tests: a place holding one document, without the application
	/// having opened it.
	///
	/// Held on to, because nothing else does. In the program a place is owned by
	/// the application delegate; a test that makes one has no delegate, and a
	/// window's delegate is a weak reference — so without this the place is
	/// deallocated the moment the line returns and the window is left answering
	/// nothing.
	static func forTesting(_ document: DocumentEditor,
	                       size: NSSize? = nil) -> DocumentPlace {
		let place = DocumentPlace(size: size ?? document.openingSize)
		place.adopt(document)
		place.window.layoutIfNeeded()
		held.append(place)
		return place
	}

	private static var held: [DocumentPlace] = []
}
