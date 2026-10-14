import Carbon.HIToolbox
import Foundation
import OffSightCore

/// User defaults owned by the app (UR-39). Grouped as in the Settings window:
/// General, Camera, Approvals, Shortcuts. There is deliberately no exemption or "always allow"
/// setting (UR-40).
enum AppDefaults {
    // General
    static let useColouredStatusIconKey = "useColouredStatusIcon"
    static let notificationsEnabledKey = "notificationsEnabled"
    /// Set when the first-run guide has been completed (UR-37).
    static let onboardingCompletedKey = "onboardingCompleted"

    // Camera
    /// `AVCaptureDevice.uniqueID` of the live camera; empty means automatic (built-in first).
    static let liveCameraIDKey = "liveCameraUniqueID"

    // Approvals
    static let promptExpiryKey = "promptExpirySeconds"
    static let gracePeriodKey = "gracePeriodSeconds"

    // Shortcuts
    static let panicShortcutKey = "panicShortcut"
    static let goLiveShortcutKey = "goLiveShortcut"

    static func register() {
        UserDefaults.standard.register(defaults: [
            useColouredStatusIconKey: false,
            notificationsEnabledKey: true,
            liveCameraIDKey: "",
            promptExpiryKey: PolicySettings.defaultPromptExpiry,
            gracePeriodKey: PolicySettings.defaultGracePeriod,
            panicShortcutKey: KeyboardShortcut.defaultPanic.storageString,
        ])
    }

    /// Prompt expiry and grace period, clamped to their safe ranges by `PolicySettings`.
    static var policySettings: PolicySettings {
        let defaults = UserDefaults.standard
        return PolicySettings(promptExpiry: defaults.double(forKey: promptExpiryKey),
                              gracePeriod: defaults.double(forKey: gracePeriodKey))
    }

    static var notificationsEnabled: Bool {
        UserDefaults.standard.bool(forKey: notificationsEnabledKey)
    }

    static var liveCameraID: String? {
        let id = UserDefaults.standard.string(forKey: liveCameraIDKey) ?? ""
        return id.isEmpty ? nil : id
    }

    static func shortcut(forKey key: String) -> KeyboardShortcut? {
        UserDefaults.standard.string(forKey: key).flatMap(KeyboardShortcut.init(storageString:))
    }
}

extension UserDefaults {
    /// KVO-observable mirror of the "useColouredStatusIcon" default (the property name must match the key).
    @objc dynamic var useColouredStatusIcon: Bool {
        bool(forKey: AppDefaults.useColouredStatusIconKey)
    }
}

/// A global keyboard shortcut: a virtual key code plus Carbon modifier flags.
struct KeyboardShortcut: Equatable {
    let keyCode: UInt32
    /// Carbon modifiers (`cmdKey`, `optionKey`, `controlKey`, `shiftKey`).
    let modifiers: UInt32
    /// The key's character as typed, for display.
    let key: String

    /// ⌃⌥⌘O: close all shutters (UR-17).
    static let defaultPanic = KeyboardShortcut(keyCode: UInt32(kVK_ANSI_O),
                                               modifiers: UInt32(controlKey | optionKey | cmdKey), key: "O")

    var displayString: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + key
    }

    /// "keyCode:modifiers:key"; empty means no shortcut.
    var storageString: String { "\(keyCode):\(modifiers):\(key)" }

    init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    init?(storageString: String) {
        let parts = storageString.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let keyCode = UInt32(parts[0]), let modifiers = UInt32(parts[1]),
              !parts[2].isEmpty else { return nil }
        self.init(keyCode: keyCode, modifiers: modifiers, key: String(parts[2]))
    }
}
