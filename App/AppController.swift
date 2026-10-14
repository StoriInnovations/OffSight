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
    /// Website of each browser session (UR-34a), per session start; nil while unknown.
    private var browserSites: [AppKey: (sessionStart: Date, host: String?)] = [:]
    private var notRunningSince: Date?
    #if DEBUG
    private var lastPublishedProtection: ProtectionState?
    #endif
    private var restartNoticeShown = false
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
        #if DEBUG
        startTestHook()
        #endif

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
        // NFR-12: the live camera unplugged mid-session. Close every shutter (no silent switch to
        // another camera while live) and pick a camera again for next time.
        NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification,
                                               object: nil, queue: .main) { [weak self] notification in
            guard let self, let device = notification.object as? AVCaptureDevice,
                  device.uniqueID == self.capture.device?.uniqueID else { return }
            let wasLive = self.engine.outputLive
            self.log.notice("Live camera \(device.localizedName, privacy: .public) disconnected; closing all shutters")
            self.note("camera disconnected: \(device.localizedName)")
            self.engine.closeAllShutters()
            self.capture.reselectCamera()
            self.apply()
            if wasLive {
                self.notifier.notice(title: "Camera disconnected",
                                     body: "\(device.localizedName) was unplugged, so every app is back on the placeholder. Go live again from the OffSight menu.")
            }
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

    /// After an update, macOS sometimes keeps the new camera extension stopped until a restart.
    /// Say so once, 20 s after it is first seen installed but not running.
    private func checkExtensionRunning() {
        guard installer.state == .activated, !link.isConnected else {
            notRunningSince = nil
            return
        }
        let since = notRunningSince ?? Date()
        notRunningSince = since
        guard !restartNoticeShown, Date().timeIntervalSince(since) > 20 else { return }
        restartNoticeShown = true
        log.notice("Camera extension installed but not running; suggesting a restart")
        notifier.notice(title: "Restart to finish setting up OffSight Camera",
                        body: "macOS installed the camera extension but hasn't started it. Restart your Mac; meeting apps keep the placeholder until then.")
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
        let policyChanged = policySummary != lastPolicySummary
        if policyChanged {
            lastPolicySummary = policySummary
            note("policy: \(policySummary)")
        }

        lookUpBrowserSites()

        prompts.update(items: pending.map { session in
            let resolved = resolvedApps[session.app]
            return PromptItem(app: session.app, displayName: name(of: session.app),
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
        checkExtensionRunning()
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

        #if DEBUG
        if policyChanged || menu.protectionState != lastPublishedProtection {
            lastPublishedProtection = menu.protectionState
            publishTestState()
        }
        #endif

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
        let base = resolvedApps[app]?.displayName ?? app.id
        return BrowserSite.label(browser: base, host: browserSites[app]?.host)
    }

    /// Best effort (UR-34a): once per browser session, ask the browser for its front tab's site.
    private func lookUpBrowserSites() {
        guard BrowserContext.isAvailable else { return }
        for session in engine.activeSessions where KnownClients.match(signingID: session.app.id)?.isBrowser == true {
            guard browserSites[session.app]?.sessionStart != session.startedAt else { continue }
            let start = session.startedAt
            browserSites[session.app] = (start, nil)
            BrowserContext.frontSite(bundleID: session.app.id) { [weak self] host in
                guard let self, let host, self.browserSites[session.app]?.sessionStart == start else { return }
                self.browserSites[session.app] = (start, host)
                self.note("site for \(session.app.id): \(host)")
                self.apply()
            }
        }
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

#if DEBUG
// MARK: - Test hook (Debug builds only)

/// Lets the on-device test tool (Tools/OffSightTest) drive and observe OffSight through
/// distributed notifications. Compiled only into Debug builds: Release and App Store builds have
/// no way for another process to approve a session (NFR-04).
extension AppController {
    fileprivate func startTestHook() {
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name(TestHook.commandNotification),
                                                            object: nil, queue: .main) { [weak self] notification in
            guard let self, let text = notification.object as? String,
                  let command = TestHook.Command(encoded: text) else { return }
            self.note("test hook: \(text)")
            self.handleTestCommand(command)
        }
        log.notice("Test hook listening (Debug build)")
    }

    private func handleTestCommand(_ command: TestHook.Command) {
        let now = Date()
        func apps(_ selector: String) -> [AppKey] {
            selector == "*" ? engine.activeSessions.map(\.app) : [AppKey(selector)]
        }
        switch command {
        case .state:
            break
        case .approve(let selector):
            for app in apps(selector) { engine.approve(app, now: now) }
        case .keepPlaceholder(let selector):
            for app in apps(selector) { engine.keepPlaceholder(app) }
        case .closeAllShutters:
            engine.closeAllShutters()
        case .pause(let minutes):
            engine.pause(until: now.addingTimeInterval(TimeInterval(minutes * 60)), now: now)
        case .resume:
            engine.resume(now: now)
        case .setPromptExpiry(let seconds):
            UserDefaults.standard.set(seconds, forKey: AppDefaults.promptExpiryKey)
            settingsChanged()
        case .setGracePeriod(let seconds):
            UserDefaults.standard.set(seconds, forKey: AppDefaults.gracePeriodKey)
            settingsChanged()
        }
        apply()
        publishTestState()
    }

    fileprivate func publishTestState() {
        let pending = engine.pendingPrompts
        let state = TestHookState(
            time: Date().timeIntervalSince1970,
            live: engine.outputLive,
            paused: engine.isPaused,
            protectionState: "\(ProtectionState.current(bypassDetected: bypass.bypassDetected, policy: engine))",
            sessions: engine.activeSessions.map {
                .init(app: $0.app.id, name: name(of: $0.app), phase: $0.phase.rawValue, startedAt: $0.startedAt.timeIntervalSince1970)
            },
            prompts: pending.map {
                .init(app: $0.app.id, name: name(of: $0.app),
                      shownAt: (prompts.shownAt(for: $0.app) ?? Date()).timeIntervalSince1970)
            },
            extensionConnected: link.isConnected,
            cameraFormat: link.latestSnapshot?.activeFormat.description,
            promptExpiry: engine.settings.promptExpiry,
            gracePeriod: engine.settings.gracePeriod,
            liveFramesSent: feeder.framesSent,
            placeholderFramesSent: feeder.placeholderFramesSent,
            recentEvents: Array(timeline.suffix(10)))
        DistributedNotificationCenter.default().postNotificationName(Notification.Name(TestHook.stateNotification),
                                                                     object: state.encodedJSON, userInfo: nil,
                                                                     deliverImmediately: true)
    }
}
#endif
