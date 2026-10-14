import Foundation

/// Where to choose OffSight Camera in each supported meeting app (UR-36). Used by onboarding;
/// the help page carries the same paths.
public struct MeetingAppGuide: Equatable, Sendable {
    public let bundleID: String
    public let name: String
    /// Menu path or place in the app where the camera is chosen.
    public let whereToChoose: String
    public let isBrowser: Bool

    public init(bundleID: String, name: String, whereToChoose: String, isBrowser: Bool = false) {
        self.bundleID = bundleID
        self.name = name
        self.whereToChoose = whereToChoose
        self.isBrowser = isBrowser
    }

    private static let meetInBrowser = "Google Meet: before joining, the camera menu under your preview; in a call, ⋮ More options › Settings › Video › Camera. Allow the browser in System Settings › Privacy & Security › Camera."

    public static let all: [MeetingAppGuide] = [
        MeetingAppGuide(bundleID: "us.zoom.xos", name: "Zoom", whereToChoose: "zoom.us › Settings › Video › Camera"),
        MeetingAppGuide(bundleID: "com.microsoft.teams2", name: "Microsoft Teams",
                        whereToChoose: "··· (Settings and more) › Settings › Devices › Camera"),
        MeetingAppGuide(bundleID: "Cisco-Systems.Spark", name: "Webex", whereToChoose: "Webex › Settings › Video › Camera"),
        MeetingAppGuide(bundleID: "com.tinyspeck.slackmacgap", name: "Slack",
                        whereToChoose: "Slack › Settings › Audio & video › Camera"),
        MeetingAppGuide(bundleID: "com.apple.FaceTime", name: "FaceTime", whereToChoose: "Video menu › OffSight Camera"),
        MeetingAppGuide(bundleID: "com.apple.PhotoBooth", name: "Photo Booth",
                        whereToChoose: "Camera menu › OffSight Camera (a quick way to check OffSight works)"),
        MeetingAppGuide(bundleID: "com.google.Chrome", name: "Google Chrome", whereToChoose: meetInBrowser, isBrowser: true),
        MeetingAppGuide(bundleID: "com.apple.Safari", name: "Safari", whereToChoose: meetInBrowser, isBrowser: true),
        MeetingAppGuide(bundleID: "com.microsoft.edgemac", name: "Microsoft Edge", whereToChoose: meetInBrowser, isBrowser: true),
        MeetingAppGuide(bundleID: "company.thebrowser.Browser", name: "Arc", whereToChoose: meetInBrowser, isBrowser: true),
        MeetingAppGuide(bundleID: "org.mozilla.firefox", name: "Firefox", whereToChoose: meetInBrowser, isBrowser: true),
    ]

    /// The guides for apps that are installed, in display order.
    public static func installed(isInstalled: (String) -> Bool) -> [MeetingAppGuide] {
        all.filter { isInstalled($0.bundleID) }
    }
}
