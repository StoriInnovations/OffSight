import Foundation
import OffSightCore
import os
import ServiceManagement

/// "Launch at login" (UR-38). Offered pre-ticked on the last onboarding step, so it is on by
/// default but only with the user's consent (Mac App Store guideline 2.4.5).
///
/// Implemented as a launch agent bundled in the app (Contents/Library/LaunchAgents) rather than
/// a plain login item: launchd starts OffSight at login and also restarts it if it ever quits
/// unexpectedly (NFR-11). Quitting from the menu exits cleanly, so it stays quit.
enum LaunchAtLogin {
    private static let log = Logger(subsystem: OffSightConstants.logSubsystem, category: "login")
    private static let agent = SMAppService.agent(plistName: "com.storiinnovations.offsight.agent.plist")

    static var isEnabled: Bool { agent.status == .enabled }

    /// macOS wants the user to allow it in System Settings › General › Login Items.
    static var needsApproval: Bool { agent.status == .requiresApproval }

    /// Builds before the launch agent registered OffSight as a plain login item; move them over.
    static func migrateFromLoginItem() {
        guard SMAppService.mainApp.status == .enabled else { return }
        try? SMAppService.mainApp.unregister()
        setEnabled(true)
        log.notice("Launch at login moved from the login item to the launch agent")
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try agent.register()
            } else {
                try agent.unregister()
            }
        } catch {
            log.error("Launch at login \(enabled ? "on" : "off") failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
