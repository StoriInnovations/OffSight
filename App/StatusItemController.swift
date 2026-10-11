import AppKit
import OffSightCore

/// Everything the menu needs to render, gathered by AppController.
struct MenuState {
    struct SessionRow {
        let app: AppKey
        let name: String
        let phase: SessionPhase
        let startedAt: Date
    }

    var indicator: ShutterIndicator = .idle
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
    func installExtension()
    func removeExtension()
    func openExtensionApproval()
    func openCameraPrivacySettings()
    func copyDiagnostics()
}

/// Menu bar icon and menu (UR-13, UR-16, UR-20…22, UR-35a). Each state has its own shape.
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private weak var actions: StatusMenuActions?
    private var state = MenuState()

    init(actions: StatusMenuActions) {
        self.actions = actions
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        render()
    }

    func update(_ newState: MenuState) {
        state = newState
        render()
    }

    private func render() {
        guard let button = statusItem.button else { return }
        let (symbol, label) = Self.symbol(for: state.indicator)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        image?.isTemplate = true
        button.image = image
        button.title = image == nil ? "OffSight" : ""
        button.contentTintColor = state.indicator == .live ? .systemRed : nil
        button.toolTip = "OffSight — \(label)"
        button.setAccessibilityLabel("OffSight: \(label)")
    }

    static func symbol(for indicator: ShutterIndicator) -> (String, String) {
        switch indicator {
        case .unprotected: return ("exclamationmark.triangle.fill", "Unprotected — a camera is in use outside OffSight")
        case .paused: return ("pause.circle", "Protection paused")
        case .live: return ("video.fill", "Live")
        case .protected: return ("video.slash.fill", "Protected — placeholder showing")
        case .idle: return ("video.slash", "Idle")
        }
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let (_, label) = Self.symbol(for: state.indicator)
        menu.addItem(disabled("OffSight — \(label)"))

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
            case .live: phase = state.indicator == .live ? "Live" : "Approved (waiting)"
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
        menu.addItem(item("Close all shutters") { $0.closeAllShutters() })
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
        menu.addItem(item("Install / update camera extension") { $0.installExtension() })
        menu.addItem(item("Remove camera extension") { $0.removeExtension() })
        menu.addItem(item("Copy diagnostics") { $0.copyDiagnostics() })
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
