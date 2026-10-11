import Foundation
import OffSightCore
import os
import Security

/// Decides whether a process may write frames into the sink stream (threat T3, NFR-04):
/// it must be signed with OffSight.app's bundle ID by the project's Apple team.
enum SinkAuthenticator {
    struct Result {
        let ok: Bool
        let mode: String
    }

    private static let log = Logger(subsystem: OffSightConstants.logSubsystem, category: "sink-auth")

    static func authenticate(pid: Int32, signingID: String?) -> Result {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let appBundleID = info["OffSightAppBundleID"] as? String, !appBundleID.isEmpty,
              let teamID = info["OffSightTeamID"] as? String, !teamID.isEmpty else {
            log.fault("OffSightAppBundleID / OffSightTeamID missing from Info.plist")
            return Result(ok: false, mode: "misconfigured")
        }
        let requirementText = "anchor apple generic and identifier \"\(appBundleID)\" "
            + "and certificate leaf[subject.OU] = \"\(teamID)\""

        var code: SecCode?
        let attributes = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
        let guestStatus = SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(), &code)

        var requirement: SecRequirement?
        let requirementStatus = SecRequirementCreateWithString(requirementText as CFString, SecCSFlags(), &requirement)

        if guestStatus == errSecSuccess, requirementStatus == errSecSuccess, let code, let requirement {
            let validity = SecCodeCheckValidity(code, SecCSFlags(), requirement)
            if validity == errSecSuccess {
                return Result(ok: true, mode: "codesign")
            }
            log.error("Sink client pid \(pid) failed the code requirement (status \(validity))")
            return Result(ok: false, mode: "codesign-mismatch(\(validity))")
        }

        log.error("Code-signing check unavailable (guest \(guestStatus), requirement \(requirementStatus))")
        #if DEBUG
        // Development builds only: fall back to the signing ID so the spike can continue while
        // spike S5 investigates. Release builds always fail closed.
        if signingID == appBundleID {
            return Result(ok: true, mode: "signingID-fallback(debug,guest=\(guestStatus))")
        }
        #endif
        return Result(ok: false, mode: "codesign-unavailable(guest=\(guestStatus))")
    }
}
