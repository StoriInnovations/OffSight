import Foundation

/// A meeting app (or browser) that OffSight can name reliably from a client's code-signing ID.
public struct KnownClient: Equatable, Sendable {
    public let hostBundleID: String
    public let displayName: String
    public let isBrowser: Bool

    public init(hostBundleID: String, displayName: String, isBrowser: Bool = false) {
        self.hostBundleID = hostBundleID
        self.displayName = displayName
        self.isBrowser = isBrowser
    }
}

/// Maps signing IDs of meeting apps and their helper processes to the host app (architecture §4.2).
/// Unknown clients are still protected; they are just labelled by their raw signing ID (rule R7).
public enum KnownClients {
    /// Signing-ID prefixes. A rule matches the ID itself or any ID that continues with ".".
    static let rules: [(prefix: String, client: KnownClient)] = [
        ("us.zoom", KnownClient(hostBundleID: "us.zoom.xos", displayName: "Zoom")),
        ("com.microsoft.teams2", KnownClient(hostBundleID: "com.microsoft.teams2", displayName: "Microsoft Teams")),
        ("com.microsoft.teams", KnownClient(hostBundleID: "com.microsoft.teams", displayName: "Microsoft Teams (classic)")),
        ("Cisco-Systems.Spark", KnownClient(hostBundleID: "Cisco-Systems.Spark", displayName: "Webex")),
        ("com.cisco.webexmeetingsapp", KnownClient(hostBundleID: "com.cisco.webexmeetingsapp", displayName: "Webex Meetings")),
        ("com.webex.meetingmanager", KnownClient(hostBundleID: "com.cisco.webexmeetingsapp", displayName: "Webex Meetings")),
        ("com.tinyspeck.slackmacgap", KnownClient(hostBundleID: "com.tinyspeck.slackmacgap", displayName: "Slack")),
        ("com.apple.FaceTime", KnownClient(hostBundleID: "com.apple.FaceTime", displayName: "FaceTime")),
        ("com.apple.avconferenced", KnownClient(hostBundleID: "com.apple.FaceTime", displayName: "FaceTime")),
        ("com.google.Chrome", KnownClient(hostBundleID: "com.google.Chrome", displayName: "Google Chrome", isBrowser: true)),
        ("com.microsoft.edgemac", KnownClient(hostBundleID: "com.microsoft.edgemac", displayName: "Microsoft Edge", isBrowser: true)),
        ("company.thebrowser.Browser", KnownClient(hostBundleID: "company.thebrowser.Browser", displayName: "Arc", isBrowser: true)),
        ("org.mozilla.firefox", KnownClient(hostBundleID: "org.mozilla.firefox", displayName: "Firefox", isBrowser: true)),
        ("org.mozilla.plugincontainer", KnownClient(hostBundleID: "org.mozilla.firefox", displayName: "Firefox", isBrowser: true)),
        ("com.apple.Safari", KnownClient(hostBundleID: "com.apple.Safari", displayName: "Safari", isBrowser: true)),
        // WebKit's GPU process captures the camera for Safari; attribution is a heuristic (spike S2).
        ("com.apple.WebKit.GPU", KnownClient(hostBundleID: "com.apple.Safari", displayName: "Safari", isBrowser: true)),
    ]

    public static func match(signingID: String) -> KnownClient? {
        rules.first { rule in
            signingID == rule.prefix || signingID.hasPrefix(rule.prefix + ".")
        }?.client
    }

    /// Host bundle IDs of all known meeting apps and browsers (used for bypass hints).
    public static var hostBundleIDs: Set<String> {
        Set(rules.map(\.client.hostBundleID))
    }

    public static func displayName(forHostBundleID bundleID: String) -> String? {
        rules.first { $0.client.hostBundleID == bundleID }?.client.displayName
    }
}
