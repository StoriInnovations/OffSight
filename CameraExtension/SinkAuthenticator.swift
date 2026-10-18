import Darwin
import Foundation
import OffSightCore
import os
import Security

/// Decides whether a process may write frames into the sink stream (threat T3, NFR-04).
/// Preferred: OffSight.app's code signature (bundle ID + team). Where the sandbox forbids that
/// check, the client must run from /Applications/OffSight.app (decision A7).
///
/// Spike S5 found that looking up the running process by pid (`SecCodeCopyGuestWithAttributes`)
/// is refused inside the extension's sandbox, so the signature of the process's executable on
/// disk is checked as a second strategy.
enum SinkAuthenticator {
    struct Result {
        let ok: Bool
        let mode: String
    }

    private static let log = Logger(subsystem: OffSightConstants.logSubsystem, category: "sink-auth")
    /// kPOSIXErrorBase + EPERM: the sandbox refused the check (spike S5).
    private static let sandboxDenied: OSStatus = 100_001
    private static let installedAppPath = "/Applications/OffSight.app"

    static func authenticate(pid: Int32, signingID: String?) -> Result {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let appBundleID = info["OffSightAppBundleID"] as? String, !appBundleID.isEmpty,
              let teamID = info["OffSightTeamID"] as? String, !teamID.isEmpty else {
            log.fault("OffSightAppBundleID / OffSightTeamID missing from Info.plist")
            return Result(ok: false, mode: "misconfigured")
        }
        var requirement: SecRequirement?
        let requirementText = "anchor apple generic and identifier \"\(appBundleID)\" "
            + "and certificate leaf[subject.OU] = \"\(teamID)\""
        guard SecRequirementCreateWithString(requirementText as CFString, SecCSFlags(), &requirement) == errSecSuccess,
              let requirement else {
            return Result(ok: false, mode: "requirement-invalid")
        }
        let sid = signingID ?? "nil"

        // Strategy 1: the running process.
        var code: SecCode?
        let attributes = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
        let guestStatus = SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(), &code)
        if guestStatus == errSecSuccess, let code {
            let validity = SecCodeCheckValidity(code, SecCSFlags(), requirement)
            if validity == errSecSuccess {
                return Result(ok: true, mode: "codesign-process")
            }
            log.error("Sink client pid \(pid) failed the code requirement (status \(validity))")
            return Result(ok: false, mode: "codesign-mismatch(\(validity), signingID=\(sid))")
        }

        // Strategy 2: the executable on disk that this pid is running. An attacker cannot make
        // its own pid report OffSight's executable without actually running OffSight's code.
        var staticStatus: OSStatus = errSecSuccess
        if let bundleURL = appBundleURL(of: pid) {
            var staticCode: SecStaticCode?
            staticStatus = SecStaticCodeCreateWithPath(bundleURL as CFURL, SecCSFlags(), &staticCode)
            if staticStatus == errSecSuccess, let staticCode {
                staticStatus = SecStaticCodeCheckValidity(staticCode, SecCSFlags(), requirement)
                if staticStatus == errSecSuccess, signingID == nil || signingID == appBundleID {
                    return Result(ok: true, mode: "codesign-path(guest=\(guestStatus))")
                }
            }
            if staticStatus != Self.sandboxDenied {
                log.error("Sink client pid \(pid) failed the on-disk check (status \(staticStatus), signingID \(sid, privacy: .public))")
                return Result(ok: false, mode: "codesign-path-mismatch(\(staticStatus), signingID=\(sid))")
            }
        } else {
            staticStatus = -1
        }

        // Spike S5: inside the camera extension's sandbox both checks fail with 100001
        // (kPOSIXErrorBase + EPERM: operation not permitted).
        log.error("Code-signing checks unavailable (guest \(guestStatus), path \(staticStatus), signingID \(sid, privacy: .public))")
        // Decision A7 (architecture §18): with code-signing checks unavailable in the sandbox,
        // accept the client running OffSight's executable from /Applications/OffSight.app (where
        // both the App Store and Homebrew builds install). Accepted risk: someone with admin rights
        // who replaces that app could inject frames; nobody can read the camera through the sink.
        if let bundleURL = appBundleURL(of: pid), bundleURL.path == Self.installedAppPath {
            return Result(ok: true, mode: "path(guest=\(guestStatus),codesign=\(staticStatus))")
        }
        return Result(ok: false, mode: "codesign-unavailable(guest=\(guestStatus),path=\(staticStatus),signingID=\(sid))")
    }

    /// The outermost .app bundle containing the executable of `pid`.
    private static func appBundleURL(of pid: Int32) -> URL? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        var url = URL(fileURLWithPath: "/")
        for component in URL(fileURLWithPath: String(cString: buffer)).pathComponents.dropFirst() {
            url.appendPathComponent(component)
            if component.hasSuffix(".app") { return url }
        }
        return nil
    }
}
