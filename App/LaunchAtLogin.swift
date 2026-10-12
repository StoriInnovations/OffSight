import Foundation
import OffSightCore
import os
import ServiceManagement

/// "Launch at login" (UR-38), on by default: turned on once on first run, then left to the user.
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

    /// First run: on by default (UR-38). Later runs respect whatever the user chose.
    static func applyDefaultOnFirstRun() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: AppDefaults.launchAtLoginInitialisedKey) else { return }
        defaults.set(true, forKey: AppDefaults.launchAtLoginInitialisedKey)
        setEnabled(true)
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
