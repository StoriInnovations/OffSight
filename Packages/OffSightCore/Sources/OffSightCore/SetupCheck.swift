import Foundation

/// What AppController knows about OffSight's setup, gathered for `SetupCheck`.
public struct SetupFacts: Equatable, Sendable {
    public enum CameraAccess: Equatable, Sendable {
        case allowed, notAsked, denied
    }

    /// Which camera extension build macOS runs, against the one this app carries.
    public var extensionStatus: ExtensionVersionStatus
    /// An install request is in flight, or macOS hasn't answered the first one yet.
    public var installing = false
    /// macOS answered the install request with "completes after a restart".
    public var installCompletesAfterRestart = false
    /// macOS told the install request it waits for the user to allow the extension.
    public var awaitingApproval = false
    /// The install failed because this app isn't in the Applications folder.
    public var installFailedOutsideApplications = false
    /// Where this app runs from. Live video works only from `OffSightConstants.installedAppPath`.
    public var appPath = ""
    /// Every camera extension build macOS lists, including old ones waiting to be removed; nil
    /// until macOS has answered.
    public var installed: [InstalledExtension]?
    /// How many cameras named OffSight Camera macOS lists.
    public var offSightCameras = 0
    public var cameraAccess: CameraAccess = .allowed
    /// Other copies of OffSight.app on this Mac.
    public var otherCopies: [String] = []
    /// The extension's sink authentication result while it refuses this app's live video; nil
    /// when it accepted it or hasn't been asked.
    public var sinkRefused: String?

    public init(extensionStatus: ExtensionVersionStatus) {
        self.extensionStatus = extensionStatus
    }
}

/// One setup step that is missing, with what the user can do about it. Required steps reopen the
/// setup guide; recommended ones are only listed in it.
public struct SetupIssue: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable {
        case moveToApplications, allowExtension, restart, installExtension, liveVideoRefused, cameraAccess, otherCopies
    }

    public enum Action: Equatable, Sendable {
        case openExtensionSettings, installAgain, requestCameraAccess, openCameraPrivacy
        case showInFinder(path: String)

        public var label: String {
            switch self {
            case .openExtensionSettings: return "Open System Settings"
            case .installAgain: return "Install Again"
            case .requestCameraAccess: return "Allow Camera Access"
            case .openCameraPrivacy: return "Open Camera Privacy Settings"
            case .showInFinder(let path): return "Show \((path as NSString).abbreviatingWithTildeInPath) in Finder"
            }
        }
    }

    public let kind: Kind
    public let required: Bool
    public let title: String
    public let detail: String
    public let actions: [Action]

    public var id: String { kind.rawValue }
    /// Shown on the guide's camera extension step; the rest belong to camera access.
    public var concernsCameraExtension: Bool { kind != .cameraAccess }
}

/// Works out which setup steps are missing (UR-37), so the setup guide can reopen on exactly
/// those after the first run: OffSight not at /Applications/OffSight.app, the camera extension
/// not installed, not allowed, not started, replaced but still waiting for a restart, or refusing
/// OffSight's live video, and camera access.
public enum SetupCheck {
    public static let restartHow = "Save your work, then choose Apple menu › Restart."

    public static func issues(for facts: SetupFacts) -> [SetupIssue] {
        var issues: [SetupIssue] = []
        if let issue = extensionIssue(facts) { issues.append(issue) }
        switch facts.cameraAccess {
        case .allowed:
            break
        case .notAsked:
            issues.append(SetupIssue(kind: .cameraAccess, required: true, title: "Allow camera access",
                                     detail: "OffSight uses the camera only for the private preview in its prompt and for live video you approve.",
                                     actions: [.requestCameraAccess]))
        case .denied:
            issues.append(SetupIssue(kind: .cameraAccess, required: true, title: "Turn on camera access",
                                     detail: "Camera access for OffSight is off, so you can't go live. Turn on OffSight in System Settings › Privacy & Security › Camera, then reopen OffSight if macOS asks.",
                                     actions: [.openCameraPrivacy]))
        }
        if !facts.otherCopies.isEmpty {
            let places = facts.otherCopies.map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: ", ")
            issues.append(SetupIssue(kind: .otherCopies, required: false, title: "Remove other copies of OffSight",
                                     detail: "Also on this Mac: \(places). Opening another copy installs its own build of OffSight Camera, and the Mac then needs a restart. Move the copies you don't use to the Trash.",
                                     actions: facts.otherCopies.prefix(3).map { SetupIssue.Action.showInFinder(path: $0) }))
        }
        return issues
    }

    /// Builds macOS lists, counting old ones that wait for a restart to be removed.
    private static func buildCount(_ facts: SetupFacts) -> Int { facts.installed?.count ?? 0 }

    private static func restart(_ facts: SetupFacts, required: Bool, _ why: String) -> SetupIssue {
        let builds = buildCount(facts)
        let several = builds > 1 ? " macOS has \(builds) builds of OffSight Camera installed; the restart removes the old ones." : ""
        return SetupIssue(kind: .restart, required: required, title: required ? "Restart your Mac" : "Restart your Mac when convenient",
                          detail: "\(why)\(several) \(restartHow)", actions: [])
    }

    private static func extensionIssue(_ facts: SetupFacts) -> SetupIssue? {
        if facts.installFailedOutsideApplications {
            return SetupIssue(kind: .moveToApplications, required: true, title: "Move OffSight to Applications",
                              detail: "macOS installs OffSight Camera only from an app in the Applications folder. Quit OffSight, move it to Applications, then open it from there.",
                              actions: facts.appPath.isEmpty ? [] : [.showInFinder(path: facts.appPath)])
        }
        if !facts.appPath.isEmpty, facts.appPath != OffSightConstants.installedAppPath {
            // OffSight Camera accepts live video only from there (decision A7), so going live
            // would silently keep the placeholder.
            return SetupIssue(kind: .moveToApplications, required: true, title: "Move OffSight to Applications",
                              detail: "This OffSight runs from \(facts.appPath). OffSight Camera accepts live video only from \(OffSightConstants.installedAppPath), so meeting apps keep the placeholder even after you go live. Quit OffSight. If another copy is at \(OffSightConstants.installedAppPath), move that one to the Trash. Then put this copy there, named OffSight.app (or install it again from the App Store or TestFlight), and open it from there.",
                              actions: [.showInFinder(path: facts.appPath)])
        }
        if facts.awaitingApproval || facts.extensionStatus == .awaitingApproval {
            return SetupIssue(kind: .allowExtension, required: true, title: "Allow OffSight Camera",
                              detail: "macOS waits for you to allow the camera OffSight adds. On macOS 15 or later: System Settings › General › Login Items & Extensions › Camera Extensions, then turn on OffSight. On macOS 13 or 14: System Settings › Privacy & Security, then Allow.",
                              actions: [.openExtensionSettings])
        }
        if facts.offSightCameras > 1 {
            return restart(facts, required: true,
                           "macOS lists \(facts.offSightCameras) cameras named OffSight Camera because an older build is still loaded, and meeting apps may pick the wrong one.")
        }
        switch facts.extensionStatus {
        case .current:
            if let refused = facts.sinkRefused {
                return SetupIssue(kind: .liveVideoRefused, required: true, title: "Live video can't reach OffSight Camera",
                                  detail: "OffSight Camera refused this app's video (\(refused)), so meeting apps keep the placeholder even after you go live. Quit any other copy of OffSight, then restart the Mac. If it keeps happening, send Copy Diagnostics from Settings › Advanced.",
                                  actions: [])
            }
            guard buildCount(facts) > 1 else { return nil }
            return SetupIssue(kind: .restart, required: false, title: "Restart your Mac when convenient",
                              detail: "macOS keeps \(buildCount(facts) - 1) older build(s) of OffSight Camera until the next restart. OffSight works meanwhile. \(restartHow)",
                              actions: [])
        case .different(let running):
            let what = running.map { "build \($0.build)" } ?? "an older build"
            return restart(facts, required: true, "macOS is still running \(what) of OffSight Camera, not the one this app carries.")
        case .installedNotStarted:
            return restart(facts, required: true, "OffSight Camera is installed and allowed, but macOS hasn't started it.")
        case .disabled:
            return SetupIssue(kind: .allowExtension, required: true, title: "Turn on OffSight Camera",
                              detail: "OffSight Camera is installed but turned off. Turn on OffSight in System Settings › General › Login Items & Extensions › Camera Extensions.",
                              actions: [.openExtensionSettings, .installAgain])
        case .awaitingApproval:
            return nil // handled above
        case .notInstalled(_, let error):
            if facts.installCompletesAfterRestart {
                return restart(facts, required: true, "macOS finishes installing OffSight Camera when the Mac restarts.")
            }
            if let error {
                return SetupIssue(kind: .installExtension, required: true, title: "Install OffSight Camera",
                                  detail: "Installing the camera OffSight adds failed: \(error)",
                                  actions: [.installAgain])
            }
            guard !facts.installing else { return nil }
            return SetupIssue(kind: .installExtension, required: true, title: "Install OffSight Camera",
                              detail: "macOS doesn't have this app's OffSight Camera installed.",
                              actions: [.installAgain])
        case .notRunning:
            // Nothing known yet unless the install said it needs a restart.
            return facts.installCompletesAfterRestart
                ? restart(facts, required: true, "macOS finishes installing OffSight Camera when the Mac restarts.")
                : nil
        }
    }
}
