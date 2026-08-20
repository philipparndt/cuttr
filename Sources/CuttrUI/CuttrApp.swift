import AppKit

/// Starts the application.
///
/// An SPM executable has no Info.plist, so the things a bundled app gets for
/// free are set up by hand here. `Scripts/bundle.sh` wraps the binary into a
/// real .app, which is what gives it a Dock icon and a document type.
public enum CuttrApp {
	/// `@MainActor` because everything below it is: the delegate, the window
	/// controllers and every view. `main.swift` calls this before there is a
	/// run loop, which is the one place a synchronous hop is both needed and
	/// safe — this *is* the main thread.
	@MainActor
	public static func run() {
		let app = NSApplication.shared
		// Off for the whole application, not just per window.
		//
		// Every window already says `tabbingMode = .disallowed`, and that is
		// enough to stop one *joining* a group — but macOS restores the window
		// arrangement from the last launch, and a group made before that
		// setting existed comes back with its tab bar. Under a title bar the
		// program draws itself, that bar lands on top of the content.
		//
		// This is the switch that turns the mechanism off rather than
		// declining it one window at a time. Restored groups are broken up in
		// `AppDelegate` as the windows appear, because this alone does not
		// undo an arrangement that is already on disk.
		NSWindow.allowsAutomaticWindowTabbing = false
		let delegate = AppDelegate()
		app.delegate = delegate
		app.setActivationPolicy(.regular)
		// Held by the application for as long as it runs; without this the
		// delegate is released the moment `run()` is entered.
		objc_setAssociatedObject(app, &delegateKey, delegate, .OBJC_ASSOCIATION_RETAIN)
		app.run()
	}
}

private nonisolated(unsafe) var delegateKey = 0
