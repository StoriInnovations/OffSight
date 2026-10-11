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
    private lazy var settingsWindow = HostedWindowController(title: "OffSight Settings") { SettingsView() }
    private lazy var aboutWindow = HostedWindowController(title: "About OffSight") { AboutView() }

    func start() {
        AppDefaults.register()
        statusItem = StatusItemController(actions: self)

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
        engine.clientsChanged(clients, now: Date())
        log.info("Snapshot gen \(snapshot.generation): \(clients.count) streaming client(s), live=\(self.engine.outputLive)")
        apply()
    }

    /// Pushes the current decision to the capture, feeder and UI.
    private func apply() {
        let live = engine.outputLive
        let pending = engine.pendingPrompts
        let cameraAuthorized = CameraCapture.authorizationStatus == .authorized

        capture.setRunning(cameraAuthorized && (live || !pending.isEmpty))
        if let snapshot {
            // The tag carries the generation this decision was made for; if the client set has
            // changed since, the extension rejects these frames until we catch up (§5.2).
            // While any app uses OffSight Camera and nobody is live, the app sends the placeholder.
            let anyClientStreaming = snapshot.clients.contains(where: \.streaming)
            feeder.update(SinkFeeder.Config(sendLive: live, sendPlaceholder: anyClientStreaming && !live,
                                            epoch: snapshot.epoch, generation: snapshot.generation,
                                            format: snapshot.activeFormat))
            requestNativeFormatIfNeeded()
        } else {
            feeder.update(nil)
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
    }

    /// OffSight Camera should advertise the live camera's native size. If it doesn't yet, ask the
    /// extension (it applies the change once no app is using the camera). Throttled to every 5 s.
    private func requestNativeFormatIfNeeded() {
        guard let native = capture.nativeFormat, let latest = link.latestSnapshot, latest.sinkConnected,
              latest.activeFormat != native, latest.pendingFormat != native,
              Date() >= nextFormatRequest else { return }
        nextFormatRequest = Date().addingTimeInterval(5)
        feeder.requestFormat(native, epoch: latest.epoch)
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

    func installExtension() { installer.activate() }
    func removeExtension() { installer.deactivate() }
    func openExtensionApproval() { installer.openApprovalSettings() }

    func openCameraPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }

    func openSettings() { settingsWindow.show() }
    func openAbout() { aboutWindow.show() }

    #if DEBUG
    func forceProtectionState(_ state: ProtectionState?) {
        statusItem?.force(state)
    }

    func setPlaceholderStyle(_ style: SinkFeeder.PlaceholderStyle) {
        feeder.placeholderStyle = style
        log.notice("Placeholder test pattern: \(style.rawValue, privacy: .public)")
    }

    var placeholderStyle: SinkFeeder.PlaceholderStyle { feeder.placeholderStyle }
    #endif

    func copyDiagnostics() {
        let report = Diagnostics.report(
            snapshot: link.latestSnapshot,
            link: link,
            installer: installer,
            resolved: Array(resolvedApps.values),
            engine: engine,
            captureDevice: capture.deviceName,
            nativeFormat: capture.nativeFormat,
            feeder: feeder,
            bypass: bypass)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }
}
