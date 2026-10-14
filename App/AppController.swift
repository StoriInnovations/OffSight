import AppKit
import AVFoundation
import OffSightCore
import os

/// Wires the extension link, policy engine, capture, feeder and UI together.
/// All state changes happen on the main thread.
final class AppController: StatusMenuActions {
    private let log = Logger(subsystem: OffSightConstants.logSubsystem, category: "app")
    private var engine = PolicyEngine()
    private let link = ExtensionLink()
    private let installer = ExtensionInstaller()
    private let capture = CameraCapture()
    private let resolver = ClientIdentityResolver()
    private let bypass = BypassMonitor()
    private lazy var feeder = SinkFeeder(link: link)
    private lazy var prompts = PromptPanelController(captureSession: capture.session)
    private var statusItem: StatusItemController?
    private var tickTimer: Timer?
    private var snapshot: ClientSnapshot?
    private var resolvedApps: [AppKey: ResolvedApp] = [:]
    private var nextFormatRequest = Date.distantPast
    private let shortcuts = GlobalShortcuts()
    /// Recent client and policy changes, for diagnostics (no images, app names only).
    private var timeline: [String] = []
    private var lastPolicySummary = ""
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
    /// True while the Video Effects window is open: OffSight's capture runs so the system can show
    /// and apply effects for OffSight. Live frames still go out only when the policy says so.
    private var effectsWindowOpen = false
    private lazy var effectsWindow: VideoEffectsWindowController = {
        let controller = VideoEffectsWindowController(capture: capture)
        controller.onVisibilityChange = { [weak self] open in
            self?.effectsWindowOpen = open
            self?.apply()
        }
        return controller
    }()
    private let notifier = SessionNotifier()
    private let settingsModel = SettingsModel()
    /// Settings values last applied, to react only to real changes.
    private var appliedPolicySettings = PolicySettings()
    private var appliedCameraID: String?
    private var appliedShortcuts: [GlobalShortcuts.Action: KeyboardShortcut?] = [:]
    private lazy var settingsWindow = HostedWindowController(title: "OffSight Settings") { [settingsModel] in
        SettingsView(model: settingsModel)
    }
    private let onboarding = OnboardingWindowController()
    private lazy var aboutWindow = HostedWindowController(title: "About OffSight") { AboutView() }

    func start() {
        AppDefaults.register()
        statusItem = StatusItemController(actions: self)
        wireSettings()
        wireOnboarding()

        capture.onFrame = { [weak self] frame in self?.feeder.handle(frame) }
        prompts.model.onApprove = { [weak self] app in self?.goLive(app) }
        prompts.model.onKeepPlaceholder = { [weak self] app in
            self?.engine.keepPlaceholder(app)
            self?.apply()
        }

        installer.onChange = { [weak self] in self?.apply() }
        link.onSnapshot = { [weak self] snapshot in self?.handle(snapshot) }
        link.onDeviceLost = { [weak self] in
            guard let self else { return }
            // No OffSight Camera means no clients: drop them so nothing waits on a stale snapshot.
            self.snapshot = nil
            self.engine.clientsChanged([], now: Date())
            self.apply()
        }
        bypass.onChange = { [weak self] in self?.apply() }
        bypass.ownCaptureRunning = { [weak self] in self?.capture.isRunningOrStopping ?? false }

        if CameraCapture.authorizationStatus == .notDetermined {
            capture.requestAccess { [weak self] _ in self?.apply() }
        }
        installer.activate()
        installer.refreshInstalledProperties()
        link.start()
        bypass.start()

        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.engine.tick(now: Date())
            self.apply()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            self?.log.info("System sleeping: ending all sessions")
            self?.engine.systemWillSleep()
            self?.apply()
        }
        apply()
    }

    // MARK: Onboarding

    private func wireOnboarding() {
        onboarding.model.installExtension = { [weak self] in self?.installer.activate() }
        onboarding.model.openExtensionApproval = { [weak self] in self?.openExtensionApproval() }
        onboarding.model.finished = { [weak self] launchAtLogin in
            // UR-38 with consent: the choice made on the last step (pre-ticked).
            LaunchAtLogin.setEnabled(launchAtLogin)
            UserDefaults.standard.set(true, forKey: AppDefaults.onboardingCompletedKey)
            self?.settingsModel.refresh()
            self?.onboarding.close()
        }
        if !UserDefaults.standard.bool(forKey: AppDefaults.onboardingCompletedKey) {
            DispatchQueue.main.async { [weak self] in self?.onboarding.show() }
        }
    }

    func showOnboarding() { onboarding.show() }

    // MARK: Settings

    private func wireSettings() {
        settingsModel.openVideoEffects = { [weak self] in self?.openVideoEffects() }
        settingsModel.installExtension = { [weak self] in self?.installer.activate() }
        settingsModel.removeExtension = { [weak self] in self?.installer.deactivate() }
        settingsModel.openExtensionApproval = { [weak self] in self?.openExtensionApproval() }
        settingsModel.openCameraPrivacySettings = { [weak self] in self?.openCameraPrivacySettings() }
        settingsModel.copyDiagnostics = { [weak self] in self?.copyDiagnostics() }
        settingsModel.showOnboarding = { [weak self] in self?.showOnboarding() }

        shortcuts.onAction = { [weak self] action in
            guard let self else { return }
            switch action {
            case .closeAllShutters:
                self.log.info("Close-all-shutters shortcut")
                self.closeAllShutters()
            case .goLiveForPrompted:
                // Only when exactly one app is asking, so the shortcut can't approve the wrong one (UR-10, UR-15).
                let pending = self.engine.pendingPrompts
                guard pending.count == 1, let app = pending.first?.app else {
                    self.log.info("Go-live shortcut ignored: \(pending.count) app(s) asking")
                    return
                }
                self.goLive(app)
            }
        }

        appliedCameraID = AppDefaults.liveCameraID
        settingsChanged()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil,
                                               queue: .main) { [weak self] _ in self?.settingsChanged() }
    }

    /// Applies settings that changed (UserDefaults posts this for every write, so compare first).
    private func settingsChanged() {
        let policy = AppDefaults.policySettings
        if policy != appliedPolicySettings {
            appliedPolicySettings = policy
            engine.updateSettings(policy)
            log.info("Prompt expiry \(policy.promptExpiry) s, grace period \(policy.gracePeriod) s")
        }

        let cameraID = AppDefaults.liveCameraID
        if cameraID != appliedCameraID {
            appliedCameraID = cameraID
            capture.reselectCamera()
            apply()
        }

        var problems: [String] = []
        for (action, key) in [(GlobalShortcuts.Action.closeAllShutters, AppDefaults.panicShortcutKey),
                              (.goLiveForPrompted, AppDefaults.goLiveShortcutKey)] {
            let shortcut = AppDefaults.shortcut(forKey: key)
            guard appliedShortcuts[action] != .some(shortcut) else { continue }
            appliedShortcuts[action] = .some(shortcut)
            if !shortcuts.set(shortcut, for: action), let shortcut {
                problems.append("\(shortcut.displayString) is already used by another app. Choose a different shortcut.")
            }
        }
        if !problems.isEmpty || settingsModel.shortcutProblem != nil {
            settingsModel.shortcutProblem = problems.isEmpty ? nil : problems.joined(separator: "\n")
        }
    }

    private func note(_ text: String) {
        timeline.append("\(Self.timeFormatter.string(from: Date())) \(text)")
        if timeline.count > 40 { timeline.removeFirst(timeline.count - 40) }
    }

    // MARK: Snapshot → policy

    private func handle(_ snapshot: ClientSnapshot) {
        self.snapshot = snapshot
        var clients: [StreamingClient] = []
        for record in snapshot.clients where record.streaming {
            let resolved = resolver.resolve(pid: record.pid, signingID: record.signingID)
            resolvedApps[resolved.key] = resolved
            clients.append(StreamingClient(clientID: record.clientID, app: resolved.key,
                                           startSequence: record.startSequence, restartGap: record.restartGap))
        }
        let records = snapshot.clients.map { record -> String in
            let gap = record.restartGap.map { String(format: " gap %.1fs", $0) } ?? ""
            return "pid \(record.pid) seq \(record.startSequence) \(record.streaming ? "streaming" : "stopped")\(gap)"
        }
        note("snapshot gen \(snapshot.generation): \(records.isEmpty ? "no clients" : records.joined(separator: "; "))")
        engine.clientsChanged(clients, now: Date())
        log.info("Snapshot gen \(snapshot.generation): \(clients.count) streaming client(s), live=\(self.engine.outputLive)")
        apply()
    }

    /// Pushes the current decision to the capture, feeder and UI.
    private func apply() {
        let live = engine.outputLive
        let pending = engine.pendingPrompts
        let cameraAuthorized = CameraCapture.authorizationStatus == .authorized

        capture.setRunning(cameraAuthorized && (live || !pending.isEmpty || effectsWindowOpen))
        if let snapshot {
            // The tag carries the generation this decision was made for; if the client set has
            // changed since, the extension rejects these frames until we catch up (§5.2).
            // While any app uses OffSight Camera and nobody is live, the app sends the placeholder.
            let anyClientStreaming = snapshot.clients.contains(where: \.streaming)
            feeder.update(SinkFeeder.Config(sendLive: live, sendPlaceholder: anyClientStreaming && !live,
                                            epoch: snapshot.epoch, generation: snapshot.generation,
                                            format: snapshot.activeFormat))
            requestCameraFormatIfNeeded()
        } else {
            feeder.update(nil)
        }

        let policySummary = engine.activeSessions.map { "\(name(of: $0.app)) \($0.phase.rawValue)" }.joined(separator: ", ")
            + " | prompts \(pending.count), live \(live)"
        if policySummary != lastPolicySummary {
            lastPolicySummary = policySummary
            note("policy: \(policySummary)")
        }

        prompts.update(items: pending.map { session in
            let resolved = resolvedApps[session.app]
            return PromptItem(app: session.app, displayName: resolved?.displayName ?? session.app.id,
                              icon: resolved?.bundleURL.map { NSWorkspace.shared.icon(forFile: $0.path) },
                              expiresAt: session.promptExpiresAt, shownAt: Date())
        })

        var menu = MenuState()
        menu.protectionState = ProtectionState.current(bypassDetected: bypass.bypassDetected, policy: engine)
        menu.sessions = engine.activeSessions.map { session in
            MenuState.SessionRow(app: session.app, name: name(of: session.app), phase: session.phase,
                                 startedAt: session.startedAt)
        }
        menu.blockingNames = engine.blockingApps.map(name(of:))
        menu.camerasBypassed = bypass.camerasInUse
        menu.bypassSuspects = bypass.bypassDetected ? bypassSuspects() : []
        menu.pausedUntil = engine.pausedUntil
        if link.isConnected {
            menu.extensionStatus = "Connected"
        } else if installer.state == .activated {
            // Installed and enabled but no device: a replaced camera extension can stay stopped
            // until the next restart.
            menu.extensionStatus = "Installed but not running — restart the Mac if this persists"
        } else {
            menu.extensionStatus = installer.state.label
        }
        menu.extensionNeedsApproval = installer.state == .needsUserApproval
        menu.cameraAccessDenied = CameraCapture.authorizationStatus == .denied
        statusItem?.update(menu)
        if settingsModel.extensionStatus != menu.extensionStatus {
            settingsModel.extensionStatus = menu.extensionStatus
        }
        let model = onboarding.model
        if model.extensionStatus != menu.extensionStatus { model.extensionStatus = menu.extensionStatus }
        if model.extensionConnected != link.isConnected { model.extensionConnected = link.isConnected }
        if model.extensionNeedsApproval != menu.extensionNeedsApproval { model.extensionNeedsApproval = menu.extensionNeedsApproval }

        let liveApps = live ? Set(engine.activeSessions.filter { $0.phase == .live }.map(\.app)) : []
        notifier.update(live: liveApps, active: Set(engine.activeSessions.map(\.app)), name: name(of:))
    }

    /// OffSight Camera should advertise the live camera's native size, scaled up where needed so
    /// macOS video effects can't blank the placeholder (`effectsFreeFormat`). If it doesn't yet, ask
    /// the extension (it applies the change once no app is using the camera). Throttled to every 5 s.
    private func requestCameraFormatIfNeeded() {
        guard let native = capture.nativeFormat, let latest = link.latestSnapshot, latest.sinkConnected,
              Date() >= nextFormatRequest else { return }
        let wanted = OffSightConstants.effectsFreeFormat(for: native)
        guard latest.activeFormat != wanted, latest.pendingFormat != wanted else { return }
        nextFormatRequest = Date().addingTimeInterval(5)
        feeder.requestFormat(wanted, epoch: latest.epoch)
    }

    private func name(of app: AppKey) -> String {
        resolvedApps[app]?.displayName ?? app.id
    }

    /// Known meeting apps that are running but not connected to OffSight Camera (C6: best effort).
    private func bypassSuspects() -> [String] {
        let connected = Set(engine.activeApps.map(\.id))
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard let bundleID = app.bundleIdentifier, KnownClients.hostBundleIDs.contains(bundleID),
                  !connected.contains(bundleID) else { return nil }
            return app.localizedName
        }.sorted()
    }

    // MARK: StatusMenuActions

    func goLive(_ app: AppKey) {
        engine.approve(app, now: Date())
        log.info("User approved \(app.id, privacy: .public) for this session")
        apply()
    }

    func closeShutter(_ app: AppKey) {
        engine.closeShutter(app, now: Date())
        apply()
    }

    func closeAllShutters() {
        engine.closeAllShutters()
        apply()
    }

    func pause(minutes: Int) {
        let now = Date()
        engine.pause(until: now.addingTimeInterval(TimeInterval(minutes * 60)), now: now)
        apply()
    }

    func resumeProtection() {
        engine.resume(now: Date())
        apply()
    }

    func openExtensionApproval() { installer.openApprovalSettings() }

    func openCameraPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Effects chosen for OffSight apply to its own capture of the physical camera, so they reach
    /// meeting apps with the live video and never touch the placeholder.
    func openVideoEffects() {
        effectsWindow.show()
    }

    func openSettings() { settingsWindow.show() }
    func openAbout() { aboutWindow.show() }
    func openHelp() { Help.open() }


    func copyDiagnostics() {
        let report = Diagnostics.report(
            snapshot: link.latestSnapshot,
            link: link,
            installer: installer,
            resolved: Array(resolvedApps.values),
            engine: engine,
            captureDevice: capture.deviceName,
            nativeFormat: capture.nativeFormat,
            captureMode: capture.activeModeDescription,
            timeline: timeline,
            feeder: feeder,
            bypass: bypass)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }
}
