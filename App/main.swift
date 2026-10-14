import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = AppController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One OffSight at a time. A second copy (for example started by the launch agent while the
        // user already opened OffSight) hands over to the running one and exits cleanly, which
        // the agent's KeepAlive treats as a normal quit.
        let me = ProcessInfo.processInfo.processIdentifier
        if let bundleID = Bundle.main.bundleIdentifier,
           let other = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
               .first(where: { $0.processIdentifier != me && !$0.isTerminated }) {
            other.activate()
            exit(0)
        }
        LaunchAtLogin.migrateFromLoginItem()
        controller.start()
    }
}

// SIGTERM (logout, `pkill`, launchctl) is a normal quit: exit cleanly so the launch agent's
// KeepAlive does not treat it as a crash and start OffSight again.
signal(SIGTERM, SIG_IGN)
let terminationSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
terminationSource.setEventHandler { NSApplication.shared.terminate(nil) }
terminationSource.resume()

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
