import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)

    // Quit cleanly on SIGTERM (pkill, logout) so the pollers' ssh and python children stop too.
    signal(SIGTERM, SIG_IGN)
    let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    termination.setEventHandler { NSApp.terminate(nil) }
    termination.resume()

    app.run()
}
