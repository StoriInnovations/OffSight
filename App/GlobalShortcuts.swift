import AppKit
import Carbon.HIToolbox
import OffSightCore
import os

/// System-wide shortcuts (UR-17 panic button, UR-18 go live for the prompted app).
///
/// Uses Carbon's RegisterEventHotKey, which works inside the App Sandbox and needs no
/// Accessibility permission: the system delivers only the registered key combination to us.
final class GlobalShortcuts {
    enum Action: UInt32 {
        case closeAllShutters = 1
        case goLiveForPrompted = 2
    }

    var onAction: ((Action) -> Void)?

    private var hotKeys: [Action: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    private let log = Logger(subsystem: OffSightConstants.logSubsystem, category: "shortcuts")
    private static let signature: OSType = 0x4F_53_4B_59 // "OSKY"

    init() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr, let action = Action(rawValue: hotKeyID.id) else { return status }
            let shortcuts = Unmanaged<GlobalShortcuts>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { shortcuts.onAction?(action) }
            return noErr
        }, 1, &eventType, context, &handler)
    }

    deinit {
        for ref in hotKeys.values { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }

    /// Registers `shortcut` for `action`, replacing any earlier one; nil removes it.
    /// Returns false if macOS refused it (usually because another app already uses it).
    @discardableResult
    func set(_ shortcut: KeyboardShortcut?, for action: Action) -> Bool {
        if let existing = hotKeys.removeValue(forKey: action) {
            UnregisterEventHotKey(existing)
        }
        guard let shortcut else { return true }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers,
                                         EventHotKeyID(signature: Self.signature, id: action.rawValue),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            log.error("Could not register \(shortcut.displayString, privacy: .public) (\(status))")
            return false
        }
        hotKeys[action] = ref
        return true
    }
}
