import CuttrUI
import Foundation

// A thin shell. Everything the app does lives in CuttrUI, which is a library so
// that it can be tested — a test target cannot reach inside an executable.
//
// `assumeIsolated` because this *is* the main thread and there is no run loop
// yet to hop onto: top-level code in a language-mode-5 target is not isolated,
// and everything below `run()` is.
MainActor.assumeIsolated { CuttrApp.run() }
