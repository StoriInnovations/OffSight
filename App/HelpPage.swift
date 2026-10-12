import AppKit
import OffSightCore
import os

/// OffSight Help: the bundled single-page guide (Contents/Resources/Help/index.html), opened in
/// the default browser. A browser rather than an in-app web view keeps the app free of WebKit and
/// of any network entitlement, which a sandboxed web view would need.
enum Help {
    private static let log = Logger(subsystem: OffSightConstants.logSubsystem, category: "help")

    static var page: URL? {
        Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Help")
    }

    static func open() {
        guard let page else {
            log.error("Help page missing from the app bundle")
            return
        }
        NSWorkspace.shared.open(page)
    }
}
