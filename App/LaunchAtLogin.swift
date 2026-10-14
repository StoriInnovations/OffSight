import Foundation
import OffSightCore
import os
import ServiceManagement

/// "Launch at login" (UR-38). Offered pre-ticked on the last onboarding step, so it is on by
/// default but only with the user's consent (Mac App Store guideline 2.4.5).
enum LaunchAtLogin {
    private static let log = Logger(subsystem: OffSightConstants.logSubsystem, category: "login")

    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// macOS wants the user to allow it in System Settings › General › Login Items.
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            log.error("Launch at login \(enabled ? "on" : "off") failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
