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
