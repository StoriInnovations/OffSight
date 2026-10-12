import AppKit
import OffSightCore
import QuartzCore

/// Everything the menu needs to render, gathered by AppController.
struct MenuState {
    struct SessionRow {
        let app: AppKey
        let name: String
        let phase: SessionPhase
        let startedAt: Date
    }

    var protectionState: ProtectionState = .idle
    var sessions: [SessionRow] = []
    var blockingNames: [String] = []
    var camerasBypassed: [String] = []
    var bypassSuspects: [String] = []
    var pausedUntil: Date?
    var extensionStatus = ""
    var extensionNeedsApproval = false
    var cameraAccessDenied = false
}

protocol StatusMenuActions: AnyObject {
    func goLive(_ app: AppKey)
    func closeShutter(_ app: AppKey)
    func closeAllShutters()
    func pause(minutes: Int)
    func resumeProtection()
    func openExtensionApproval()
    func openCameraPrivacySettings()
    func openSettings()
    func openHelp()
    func openAbout()
}

/// Menu bar icon and menu (UR-13, UR-16, UR-20…22, UR-35a). Uses the brand glyphs from the asset
/// catalog; each state is distinguishable by shape alone.
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private weak var actions: StatusMenuActions?
    private var state = MenuState()
    private var displayedState: ProtectionState?
    private var displayedColoured: Bool?
    private var colourObservation: NSKeyValueObservation?

    init(actions: StatusMenuActions) {
        self.actions = actions
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        colourObservation = UserDefaults.standard.observe(\.useColouredStatusIcon, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.renderIcon() }
        }
        renderIcon()
    }

    func update(_ newState: MenuState) {
        state = newState
        renderIcon()
    }

    private var effectiveState: ProtectionState { state.protectionState }

    /// Updates the icon only when the state or colour mode changes, on the main thread.
    private func renderIcon() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let button = statusItem.button else { return }
        let protectionState = effectiveState
        let coloured = UserDefaults.standard.useColouredStatusIcon
        guard protectionState != displayedState || coloured != displayedColoured else { return }
        let isFirstRender = displayedState == nil
        displayedState = protectionState
        displayedColoured = coloured

        guard let image = Self.image(for: protectionState, coloured: coloured) else {
            button.image = nil
            button.title = "OffSight"
            return
        }
        if !isFirstRender, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            // The only animation allowed: a single 150 ms crossfade between states.
            button.wantsLayer = true
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.15
            button.layer?.add(fade, forKey: "stateCrossfade")
        }
        button.title = ""
        button.image = image
        button.toolTip = protectionState.accessibilityDescription
        button.setAccessibilityLabel(protectionState.accessibilityDescription)
    }

    static func image(for protectionState: ProtectionState, coloured: Bool) -> NSImage? {
        let name = coloured ? protectionState.menuBarColorAssetName : protectionState.menuBarAssetName
        // Copy: NSImage(named:) returns a shared instance.
        guard let image = NSImage(named: name)?.copy() as? NSImage else { return nil }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = !coloured
        image.accessibilityDescription = protectionState.accessibilityDescription
        return image
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(disabled(effectiveState.accessibilityDescription))

        if !state.camerasBypassed.isEmpty {
            menu.addItem(.separator())
            for camera in state.camerasBypassed {
                menu.addItem(disabled("⚠︎ \(camera) is being used directly by another app — not protected"))
            }
            if !state.bypassSuspects.isEmpty {
                menu.addItem(disabled("Possibly: \(state.bypassSuspects.joined(separator: ", "))"))
            }
            menu.addItem(disabled("Fix: choose “OffSight Camera” as the camera in that app."))
        }

        if state.cameraAccessDenied {
            menu.addItem(.separator())
            menu.addItem(disabled("OffSight needs camera access for preview and live video"))
            menu.addItem(item("Open Camera privacy settings…") { $0.openCameraPrivacySettings() })
        }

        menu.addItem(.separator())
        if state.sessions.isEmpty {
            menu.addItem(disabled("No app is using OffSight Camera"))
        }
        for row in state.sessions {
            let minutes = Int(Date().timeIntervalSince(row.startedAt)) / 60
            let seconds = Int(Date().timeIntervalSince(row.startedAt)) % 60
            let phase: String
            switch row.phase {
            case .live: phase = state.protectionState == .live ? "Live" : "Approved (waiting)"
            case .pending: phase = "Waiting for approval"
            case .placeholder: phase = "Placeholder"
            }
            menu.addItem(disabled("\(row.name) — \(phase) · \(String(format: "%d:%02d", minutes, seconds))"))
            if row.phase == .live {
                menu.addItem(item("    Close shutter for \(row.name)") { $0.closeShutter(row.app) })
            } else {
                menu.addItem(item("    Go live for \(row.name) (this session)") { $0.goLive(row.app) })
            }
        }
        if !state.blockingNames.isEmpty, state.sessions.contains(where: { $0.phase == .live }) {
            menu.addItem(disabled("Live video is held back until \(state.blockingNames.joined(separator: ", ")) is approved"))
        }

        menu.addItem(.separator())
        let panic = AppDefaults.shortcut(forKey: AppDefaults.panicShortcutKey).map { "  \($0.displayString)" } ?? ""
        menu.addItem(item("Close all shutters\(panic)") { $0.closeAllShutters() })
        if let until = state.pausedUntil {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            menu.addItem(disabled("Protection paused until \(formatter.string(from: until))"))
            menu.addItem(item("Resume protection now") { $0.resumeProtection() })
        } else {
            let pauseItem = NSMenuItem(title: "Pause protection", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            submenu.addItem(item("For 15 minutes") { $0.pause(minutes: 15) })
            submenu.addItem(item("For 1 hour") { $0.pause(minutes: 60) })
            pauseItem.submenu = submenu
            menu.addItem(pauseItem)
        }

        menu.addItem(.separator())
        menu.addItem(disabled("Camera extension: \(state.extensionStatus)"))
        if state.extensionNeedsApproval {
            menu.addItem(item("Approve OffSight Camera in System Settings…") { $0.openExtensionApproval() })
        }
        menu.addItem(.separator())
        menu.addItem(item("Settings…") { $0.openSettings() })
        menu.addItem(item("OffSight Help") { $0.openHelp() })
        menu.addItem(item("About OffSight") { $0.openAbout() })
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit OffSight (meeting apps keep the placeholder)",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }


    private func disabled(_ title: String) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menuItem.isEnabled = false
        return menuItem
    }

    private func item(_ title: String, _ handler: @escaping (StatusMenuActions) -> Void) -> NSMenuItem {
        let menuItem = ClosureMenuItem(title: title) { [weak self] in
            guard let actions = self?.actions else { return }
            handler(actions)
        }
        return menuItem
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { handler() }
}
