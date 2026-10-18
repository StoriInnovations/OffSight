import Foundation
import OffSightCore
import os

/// Best-effort website for a browser meeting (UR-34a), read from the browser's front tab with
/// Apple Events. Homebrew build only: the App Store build shows the browser name alone, because
/// the Apple Events exception it needs is unlikely to pass App Review (architecture A3).
/// macOS asks the user once per browser before OffSight may read it; if they decline, or the
/// browser has no scripting support (Firefox), OffSight shows the browser name, as before.
enum BrowserContext {
    #if APPSTORE
    static let isAvailable = false
    #else
    static let isAvailable = true
    #endif

    private static let queue = DispatchQueue(label: "com.storiinnovations.offsight.browser-context")
    private static let log = Logger(subsystem: OffSightConstants.logSubsystem, category: "browser")

    /// Looks up the front tab's site for `bundleID` and calls `completion` on the main queue.
    static func frontSite(bundleID: String, completion: @escaping (String?) -> Void) {
        guard isAvailable, let source = script(for: bundleID) else {
            completion(nil)
            return
        }
        queue.async {
            var error: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
            if let error {
                log.info("No site from \(bundleID, privacy: .public): \(error[NSAppleScript.errorNumber] as? Int ?? 0)")
            }
            let host = result?.stringValue.flatMap(BrowserSite.host(fromURL:))
            DispatchQueue.main.async { completion(host) }
        }
    }

    private static func script(for bundleID: String) -> String? {
        switch bundleID {
        case "com.apple.Safari":
            return "tell application id \"com.apple.Safari\" to if (count of windows) > 0 then get URL of current tab of front window"
        case "com.google.Chrome", "com.microsoft.edgemac", "company.thebrowser.Browser", "com.brave.Browser":
            return "tell application id \"\(bundleID)\" to if (count of windows) > 0 then get URL of active tab of front window"
        default:
            return nil // Firefox and others have no tab scripting
        }
    }
}
