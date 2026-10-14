import AppKit
import AVFoundation
import Foundation
import OffSightCore

/// The result of one scenario.
struct Outcome {
    enum Status: String { case pass = "PASS", fail = "FAIL", skip = "SKIP" }
    var status: Status
    var detail: String
    var metrics: [(String, String)] = []

    static func pass(_ detail: String, _ metrics: [(String, String)] = []) -> Outcome { Outcome(status: .pass, detail: detail, metrics: metrics) }
    static func fail(_ detail: String, _ metrics: [(String, String)] = []) -> Outcome { Outcome(status: .fail, detail: detail, metrics: metrics) }
    static func skip(_ detail: String) -> Outcome { Outcome(status: .skip, detail: detail) }
}

struct Scenario {
    let id: String
    let title: String
    let requirements: String
    let run: (TestContext) -> Outcome
}

/// Shared state for a run: the app link, the settings to restore, and helpers.
final class TestContext {
    let app = AppLink()
    let options: Options
    private var savedSettings: (expiry: Double, grace: Double)?

    struct Options {
        var grace: Double = 5          // shortest allowed, so scenarios run quickly
        var settle: TimeInterval = 1.0 // pause after starting a client
    }

    init(options: Options) {
        self.options = options
    }

    /// Fast settings for the run; restored by `finish()`.
    func prepare() {
        if let state = app.state() {
            savedSettings = (state.promptExpiry, state.gracePeriod)
            app.run(.setGracePeriod(seconds: options.grace))
            app.run(.setPromptExpiry(seconds: 30))
        }
    }

    func finish() {
        app.run(.closeAllShutters)
        app.run(.resume)
        if let saved = savedSettings {
            app.run(.setPromptExpiry(seconds: saved.expiry))
            app.run(.setGracePeriod(seconds: saved.grace))
        }
    }

    /// Waits until no app is using OffSight Camera and any earlier session's grace period is over,
    /// so the next client starts a fresh session.
    func waitForIdle() -> Bool {
        guard Wait.until(15, { Probe.streamingClients().isEmpty }) != nil else { return false }
        Wait.sleep((app.latest?.gracePeriod ?? options.grace) + 0.8)
        return app.waitFor(3) { $0.sessions.isEmpty } != nil
    }

    func newClient() -> CameraClient? { CameraClient(device: CameraClient.offSightCamera) }
}

enum Scenarios {
    static let all: [Scenario] = [
        environment, placeholderByDefault, promptLatency, approveGoesLive, closeAllTiming, steadyFrames, promptUI,
        restartWhilePending, restartWithinGraceKeepsApproval, sessionEndAsksAgain, keepThenGoLive,
        promptExpiry, pause, bypassDetection, failClosed, photoBooth, quickTime,
    ]

    // MARK: Environment

    static let environment = Scenario(id: "environment", title: "OffSight is installed, running and reachable",
                                      requirements: "setup") { ctx in
        var metrics: [(String, String)] = []
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.storiinnovations.offsight").first != nil else {
            return .fail("OffSight is not running. Open /Applications/OffSight.app.")
        }
        guard let snapshot = Probe.snapshot() else {
            return .fail("OffSight Camera not found or not running (camera extension not approved, or restart needed).")
        }
        metrics.append(("camera format", snapshot.activeFormat.description))
        metrics.append(("sink connected", "\(snapshot.sinkConnected)"))
        guard snapshot.activeFormat.width >= 1920, snapshot.activeFormat.height >= 1440 else {
            return .fail("OffSight Camera is \(snapshot.activeFormat); it should be at least 1920x1440 (effects-free).", metrics)
        }
        guard snapshot.sinkConnected else { return .fail("OffSight.app is not connected to the camera extension.", metrics) }
        guard CameraClient.offSightCamera != nil else { return .fail("AVFoundation does not list OffSight Camera.", metrics) }
        guard let state = ctx.app.state() else {
            return .fail("No answer from the test hook. Use a Debug build (scripts/dev-install.sh); Release and App Store builds have no hook.", metrics)
        }
        metrics.append(("prompt expiry", "\(Int(state.promptExpiry)) s"))
        metrics.append(("grace period", "\(Int(state.gracePeriod)) s"))
        return .pass("Ready", metrics)
    }

    // MARK: Approval flow

    static let placeholderByDefault = Scenario(id: "placeholder-default", title: "A new app gets the placeholder, never live video",
                                               requirements: "UR-01, UR-02, UR-03, UR-05") { ctx in
        guard ctx.waitForIdle() else { return .skip("Another app is using OffSight Camera; close it and rerun.") }
        guard let client = ctx.newClient() else { return .fail("Could not open OffSight Camera") }
        let before = Probe.counters()
        client.start()
        defer { client.stop() }
        guard Wait.until(5, { client.frameCount >= 15 }) != nil else { return .fail("No frames from OffSight Camera within 5 s") }
        Wait.sleep(2)
        guard let before, let after = Probe.counters() else { return .fail("Camera counters unavailable") }
        let live = Probe.delta(after.live, before.live), placeholders = Probe.delta(after.placeholders, before.placeholders)
        let metrics = [("live frames", "\(live)"), ("placeholder frames", "\(placeholders)"),
                       ("client fps", String(format: "%.1f", client.fps(window: 2)))]
        if live > 0 { return .fail("Live frames reached an unapproved app", metrics) }
        if placeholders == 0 { return .fail("No placeholder frames were sent", metrics) }
        return .pass("Only placeholder frames", metrics)
    }

    static let promptLatency = Scenario(id: "prompt-latency", title: "The prompt appears within 500 ms",
                                        requirements: "UR-06, NFR-09") { ctx in
        guard ctx.waitForIdle() else { return .skip("Another app is using OffSight Camera") }
        guard let client = ctx.newClient() else { return .fail("Could not open OffSight Camera") }
        client.start()
        let started = Date().timeIntervalSince1970
        defer { client.stop() }
        guard let state = ctx.app.waitFor(5, { !$0.prompts.isEmpty }), let prompt = state.prompts.first else {
            return .fail("No prompt within 5 s")
        }
        let latency = max(0, prompt.shownAt - started)
        let metrics = [("latency", String(format: "%.0f ms", latency * 1000)), ("app", prompt.name)]
        return latency <= 0.5 ? .pass("Prompt shown", metrics) : .fail("Prompt took longer than 500 ms", metrics)
    }

    static let approveGoesLive = Scenario(id: "approve-live", title: "Go live sends live video without interrupting the stream",
                                          requirements: "UR-07, UR-13, NFR-07") { ctx in
        guard ctx.waitForIdle() else { return .skip("Another app is using OffSight Camera") }
        guard let client = ctx.newClient() else { return .fail("Could not open OffSight Camera") }
        client.start()
        defer { client.stop() }
        guard ctx.app.waitFor(5, { !$0.prompts.isEmpty }) != nil, let before = Probe.counters() else { return .fail("No prompt") }
        let sentAt = ProcessInfo.processInfo.systemUptime
        ctx.app.send(.approve(app: "*"))
        guard let elapsed = Wait.until(2, { (Probe.counters()?.live ?? 0) > before.live }) else {
            return .fail("No live frames within 2 s of approval")
        }
        Wait.sleep(1.5)
        let gap = client.maxGap(since: sentAt)
        let metrics = [("first live frame after", String(format: "%.0f ms", elapsed * 1000)),
                       ("longest frame gap", String(format: "%.0f ms", gap * 1000))]
        if gap > 0.5 { return .fail("The stream stalled while switching to live", metrics) }
        return .pass("Live", metrics)
    }

    static let closeAllTiming = Scenario(id: "close-all", title: "Close all shutters takes effect within 250 ms",
                                         requirements: "UR-16, UR-17, UR-19") { ctx in
        guard ctx.waitForIdle() else { return .skip("Another app is using OffSight Camera") }
        guard let client = ctx.newClient() else { return .fail("Could not open OffSight Camera") }
        client.start()
        defer { client.stop() }
        guard ctx.app.waitFor(5, { !$0.prompts.isEmpty }) != nil else { return .fail("No prompt") }
        ctx.app.send(.approve(app: "*"))
        guard let start = Probe.counters(), Wait.until(2, { (Probe.counters()?.live ?? 0) > start.live }) != nil else {
            return .fail("Could not go live first")
        }
        Wait.sleep(1)
        let sentAt = ProcessInfo.processInfo.systemUptime
        ctx.app.send(.closeAllShutters)
        // The last live frame goes out when the shutter has closed: wait until live stops for 150 ms.
        var lastLive = Probe.counters()?.live ?? 0
        var lastChange = ProcessInfo.processInfo.systemUptime
        _ = Wait.until(2) {
            let live = Probe.counters()?.live ?? lastLive
            let now = ProcessInfo.processInfo.systemUptime
            if live != lastLive { lastLive = live; lastChange = now }
            return now - lastChange > 0.15
        }
        let latency = max(0, lastChange - sentAt)
        let placeholderBefore = Probe.counters()?.placeholders ?? 0
        Wait.sleep(0.5)
        let placeholdersFlow = (Probe.counters()?.placeholders ?? 0) > placeholderBefore
        let gap = client.maxGap(since: sentAt)
        let metrics = [("shutter closed after", String(format: "%.0f ms", latency * 1000)),
                       ("longest frame gap", String(format: "%.0f ms", gap * 1000))]
        if !placeholdersFlow { return .fail("No placeholder frames after closing", metrics) }
        if gap > 0.5 { return .fail("The stream stalled (the meeting could drop)", metrics) }
        return latency <= 0.25 ? .pass("Closed", metrics) : .fail("Took longer than 250 ms", metrics)
    }

    static let steadyFrames = Scenario(id: "steady-frames", title: "Steady frame rate and one size, placeholder and live",
                                       requirements: "UR-05, UR-28") { ctx in
        guard ctx.waitForIdle() else { return .skip("Another app is using OffSight Camera") }
        guard let client = ctx.newClient(), let format = Probe.snapshot()?.activeFormat else { return .fail("Could not open OffSight Camera") }
        client.start()
        defer { client.stop() }
        Wait.sleep(3)
        let placeholderFPS = client.fps(window: 2)
        ctx.app.send(.approve(app: "*"))
        Wait.sleep(3)
        let liveFPS = client.fps(window: 2)
        let sizes = client.frameSizes
        let metrics = [("placeholder fps", String(format: "%.1f", placeholderFPS)), ("live fps", String(format: "%.1f", liveFPS)),
                       ("frame sizes", sizes.sorted().joined(separator: ", ")), ("advertised", format.description)]
        if sizes != [format.description] { return .fail("Frame size changed or differs from the advertised format", metrics) }
        if placeholderFPS < 25 || liveFPS < 25 { return .fail("Below 25 fps", metrics) }
        return .pass("Steady", metrics)
    }

    // MARK: Sessions

    static let restartWhilePending = Scenario(id: "restart-pending", title: "An unanswered app that restarts its camera is asked again",
                                              requirements: "R2, bug B1 (Photo Booth)") { ctx in
        guard ctx.waitForIdle() else { return .skip("Another app is using OffSight Camera") }
        guard let client = ctx.newClient() else { return .fail("Could not open OffSight Camera") }
        client.start()
        guard ctx.app.waitFor(5, { !$0.prompts.isEmpty }) != nil else { client.stop(); return .fail("No first prompt") }
        client.stop()
        Wait.sleep(0.5)
        client.start()
        defer { client.stop() }
        guard let state = ctx.app.waitFor(3, { !$0.prompts.isEmpty && !$0.live }) else {
            return .fail("No prompt after the restart: the app would silently stay on the placeholder")
        }
        return .pass("Asked again", [("prompts", "\(state.prompts.count)")])
    }

    static let restartWithinGraceKeepsApproval = Scenario(id: "grace-keeps-live", title: "A quick camera restart keeps the approval",
                                                          requirements: "UR-12") { ctx in
        guard ctx.waitForIdle() else { return .skip("Another app is using OffSight Camera") }
        guard let client = ctx.newClient() else { return .fail("Could not open OffSight Camera") }
        client.start()
        guard ctx.app.waitFor(5, { !$0.prompts.isEmpty }) != nil else { client.stop(); return .fail("No prompt") }
        ctx.app.send(.approve(app: "*"))
        guard ctx.app.waitFor(3, { $0.live }) != nil else { client.stop(); return .fail("Did not go live") }
        client.stop()
        Wait.sleep(1)
        client.start()
        defer { client.stop() }
        guard ctx.app.waitFor(3, { $0.live && $0.prompts.isEmpty }) != nil else {
            return .fail("Approval was lost on a restart within the grace period")
        }
        return .pass("Still live, no new prompt")
    }

    static let sessionEndAsksAgain = Scenario(id: "session-end", title: "After the session ends, the next one asks again",
                                              requirements: "UR-11, UR-40") { ctx in
        guard ctx.waitForIdle() else { return .skip("Another app is using OffSight Camera") }
        guard let client = ctx.newClient() else { return .fail("Could not open OffSight Camera") }
        client.start()
        guard ctx.app.waitFor(5, { !$0.prompts.isEmpty }) != nil else { client.stop(); return .fail("No prompt") }
        ctx.app.send(.approve(app: "*"))
        guard ctx.app.waitFor(3, { $0.live }) != nil else { client.stop(); return .fail("Did not go live") }
        client.stop()
        Wait.sleep((ctx.app.latest?.gracePeriod ?? 5) + 1.5)
        client.start()
        defer { client.stop() }
        guard ctx.app.waitFor(3, { !$0.prompts.isEmpty && !$0.live }) != nil else {
            return .fail("The next session was not asked again")
        }
        let before = Probe.counters()
        Wait.sleep(1)
        if let before, let after = Probe.counters(), after.live > before.live {
            return .fail("Live frames went out before approval")
        }
        return .pass("Asked again; placeholder until approved")
    }

    static let keepThenGoLive = Scenario(id: "keep-then-live", title: "Keep placeholder, then go live later from the menu",
                                         requirements: "UR-09, UR-13") { ctx in
        guard ctx.waitForIdle() else { return .skip("Another app is using OffSight Camera") }
        guard let client = ctx.newClient() else { return .fail("Could not open OffSight Camera") }
        client.start()
        defer { client.stop() }
        guard ctx.app.waitFor(5, { !$0.prompts.isEmpty }) != nil else { return .fail("No prompt") }
        ctx.app.send(.keepPlaceholder(app: "*"))
        guard ctx.app.waitFor(2, { $0.prompts.isEmpty && !$0.live && $0.sessions.first?.phase == "placeholder" }) != nil else {
            return .fail("Keep placeholder did not hold")
        }
        let before = Probe.counters()
        Wait.sleep(1)
        if let before, let after = Probe.counters(), after.live > before.live { return .fail("Live frames after Keep placeholder") }
        ctx.app.send(.approve(app: "*"))
        guard ctx.app.waitFor(3, { $0.live }) != nil else { return .fail("Could not go live later") }
        return .pass("Placeholder kept, then live on request")
    }

    static let promptExpiry = Scenario(id: "prompt-expiry", title: "An unanswered prompt expires into the placeholder",
                                       requirements: "UR-09, UR-09a") { ctx in
        guard ctx.waitForIdle() else { return .skip("Another app is using OffSight Camera") }
        ctx.app.run(.setPromptExpiry(seconds: 5))
        defer { ctx.app.run(.setPromptExpiry(seconds: 30)) }
        guard let client = ctx.newClient() else { return .fail("Could not open OffSight Camera") }
        client.start()
        defer { client.stop() }
        guard ctx.app.waitFor(5, { !$0.prompts.isEmpty }) != nil else { return .fail("No prompt") }
        guard ctx.app.waitFor(8, { $0.prompts.isEmpty }) != nil else {
            return .fail("The prompt did not expire")
        }
        guard let state = ctx.app.state(), !state.live, state.sessions.first?.phase == "placeholder" else {
            return .fail("Did not expire into the placeholder")
        }
        return .pass("Expired into the placeholder")
    }

    static let pause = Scenario(id: "pause", title: "Pause gives live video without prompts; resuming asks again",
                                requirements: "UR-41") { ctx in
        guard ctx.waitForIdle() else { return .skip("Another app is using OffSight Camera") }
        ctx.app.run(.pause(minutes: 1))
        defer { ctx.app.run(.resume) }
        guard let client = ctx.newClient() else { return .fail("Could not open OffSight Camera") }
        client.start()
        defer { client.stop() }
        guard ctx.app.waitFor(3, { $0.paused && $0.live && $0.prompts.isEmpty }) != nil else {
            return .fail("Paused protection did not give live video without a prompt")
        }
        ctx.app.run(.resume)
        guard ctx.app.waitFor(3, { !$0.paused && !$0.live && !$0.prompts.isEmpty }) != nil else {
            return .fail("Resuming did not go back to the placeholder and ask")
        }
        return .pass("Paused, then protected again")
    }

    // MARK: Awareness and robustness

    static let bypassDetection = Scenario(id: "bypass", title: "An app using the real camera directly shows as unprotected",
                                          requirements: "UR-35, UR-35a") { ctx in
        guard ctx.waitForIdle() else { return .skip("Another app is using OffSight Camera") }
        guard let client = CameraClient(device: CameraClient.physicalCamera) else { return .skip("No built-in camera") }
        client.start()
        guard ctx.app.waitFor(5, { $0.protectionState == "unprotected" }) != nil else {
            client.stop()
            return .fail("Bypass not detected within 5 s")
        }
        client.stop()
        guard ctx.app.waitFor(8, { $0.protectionState != "unprotected" }) != nil else {
            return .fail("Still unprotected after the real camera stopped")
        }
        return .pass("Detected and cleared")
    }

    static let failClosed = Scenario(id: "fail-closed", title: "If OffSight quits unexpectedly, apps get the placeholder",
                                     requirements: "UR-04, NFR-11") { ctx in
        guard ctx.waitForIdle() else { return .skip("Another app is using OffSight Camera") }
        guard let client = ctx.newClient() else { return .fail("Could not open OffSight Camera") }
        client.start()
        defer { client.stop() }
        guard ctx.app.waitFor(5, { !$0.prompts.isEmpty }) != nil else { return .fail("No prompt") }
        ctx.app.send(.approve(app: "*"))
        guard ctx.app.waitFor(3, { $0.live }) != nil else { return .fail("Did not go live") }
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.storiinnovations.offsight").first else {
            return .fail("OffSight not running")
        }
        let killedAt = ProcessInfo.processInfo.systemUptime
        kill(running.processIdentifier, SIGKILL)
        var metrics: [(String, String)] = []
        // Live frames must stop and the extension's own placeholder take over.
        guard let base = Probe.counters() else { return .fail("Camera counters unavailable") }
        guard let fallbackAfter = Wait.until(2, { (Probe.counters()?.fallback ?? 0) > base.fallback }) else {
            return .fail("The extension did not fall back to its placeholder")
        }
        let liveBefore = Probe.counters()?.live ?? 0
        Wait.sleep(1)
        if (Probe.counters()?.live ?? 0) > liveBefore { return .fail("Live frames continued after OffSight died") }
        metrics.append(("fallback placeholder after", String(format: "%.0f ms", fallbackAfter * 1000)))
        metrics.append(("longest frame gap", String(format: "%.0f ms", client.maxGap(since: killedAt) * 1000)))
        // NFR-11: with launch at login on, launchd restarts OffSight.
        let relaunched = Wait.until(20, {
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.storiinnovations.offsight").contains { !$0.isTerminated }
        })
        if let relaunched {
            metrics.append(("relaunched after", String(format: "%.1f s", relaunched)))
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.storiinnovations.offsight") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            metrics.append(("relaunched", "manually (launch at login is off, so no automatic restart)"))
        }
        guard ctx.app.waitFor(20, { $0.extensionConnected }) != nil else { return .fail("OffSight did not come back", metrics) }
        if let state = ctx.app.state(), state.live { return .fail("Came back live without a new approval", metrics) }
        ctx.prepare()
        return .pass("Failed closed and recovered", metrics)
    }

    // MARK: Real apps

    static let photoBooth = Scenario(id: "photo-booth", title: "Photo Booth: prompt on launch, live on approval, placeholder on close",
                                     requirements: "UR-01, UR-06, bug B1") { ctx in
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.PhotoBooth") else {
            return .skip("Photo Booth not installed")
        }
        guard ctx.waitForIdle() else { return .skip("Another app is using OffSight Camera") }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        var app: NSRunningApplication?
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { running, _ in app = running }
        defer { app?.terminate() }
        guard ctx.app.waitFor(12, { $0.sessions.contains { $0.app == "com.apple.PhotoBooth" } }) != nil else {
            return .skip("Photo Booth didn't use OffSight Camera. In Photo Booth choose Camera › OffSight Camera once, then rerun.")
        }
        guard ctx.app.waitFor(3, { $0.prompts.contains { $0.app == "com.apple.PhotoBooth" } }) != nil else {
            return .fail("No prompt for Photo Booth on launch (bug B1)")
        }
        guard let before = Probe.counters() else { return .fail("Camera counters unavailable") }
        ctx.app.send(.approve(app: "com.apple.PhotoBooth"))
        guard Wait.until(3, { (Probe.counters()?.live ?? 0) > before.live }) != nil else { return .fail("No live frames for Photo Booth") }
        ctx.app.send(.closeAllShutters)
        guard ctx.app.waitFor(2, { !$0.live }) != nil else { return .fail("Did not close") }
        app?.terminate()
        guard ctx.app.waitFor(10, { !$0.sessions.contains { $0.app == "com.apple.PhotoBooth" } }) != nil else {
            return .fail("Photo Booth's session did not end after quitting")
        }
        return .pass("Prompted, live, closed and ended")
    }

    static let quickTime = Scenario(id: "quicktime", title: "QuickTime Player: new recording with OffSight Camera",
                                    requirements: "UR-01, UR-06") { ctx in
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.QuickTimePlayerX") != nil else {
            return .skip("QuickTime Player not installed")
        }
        guard ctx.waitForIdle() else { return .skip("Another app is using OffSight Camera") }
        let open = """
        tell application "QuickTime Player"
            activate
            set doc to new movie recording
            set cams to (video recording devices whose name is "OffSight Camera")
            if (count of cams) > 0 then set current camera of doc to item 1 of cams
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: open)?.executeAndReturnError(&error)
        defer {
            NSAppleScript(source: "tell application \"QuickTime Player\" to close every document saving no")?.executeAndReturnError(nil)
        }
        if let error {
            return .skip("Could not script QuickTime Player (\(error[NSAppleScript.errorMessage] ?? "error")). Allow Terminal to control QuickTime Player in System Settings › Privacy & Security › Automation.")
        }
        guard ctx.app.waitFor(10, { $0.prompts.contains { $0.app == "com.apple.QuickTimePlayerX" } }) != nil else {
            return .fail("No prompt for QuickTime Player")
        }
        guard let before = Probe.counters() else { return .fail("Camera counters unavailable") }
        ctx.app.send(.approve(app: "com.apple.QuickTimePlayerX"))
        guard Wait.until(3, { (Probe.counters()?.live ?? 0) > before.live }) != nil else { return .fail("No live frames for QuickTime") }
        ctx.app.send(.closeAllShutters)
        return .pass("Prompted and live on approval")
    }
}
