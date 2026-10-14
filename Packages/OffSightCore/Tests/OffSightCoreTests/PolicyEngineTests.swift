import XCTest
@testable import OffSightCore

final class PolicyEngineTests: XCTestCase {
    private let zoom = AppKey("us.zoom.xos")
    private let teams = AppKey("com.microsoft.teams2")
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private var nextClientSequence: UInt64 = 0

    private func client(_ app: AppKey, id: UUID = UUID(), sequence: UInt64? = nil, gap: Double? = nil) -> StreamingClient {
        nextClientSequence += 1
        return StreamingClient(clientID: id, app: app, startSequence: sequence ?? nextClientSequence, restartGap: gap)
    }

    // MARK: Default protection

    func testNoClientsMeansNotLive() {
        let engine = PolicyEngine()
        XCTAssertFalse(engine.outputLive)
        XCTAssertEqual(ProtectionState.current(bypassDetected: false, policy: engine), .idle)
    }

    func testNewClientIsPendingAndPlaceholder() {
        var engine = PolicyEngine()
        engine.clientsChanged([client(zoom)], now: t0)
        XCTAssertEqual(engine.session(for: zoom)?.phase, .pending)
        XCTAssertFalse(engine.outputLive)
        XCTAssertEqual(engine.pendingPrompts.map(\.app), [zoom])
        XCTAssertEqual(ProtectionState.current(bypassDetected: false, policy: engine), .protected)
    }

    func testApproveGoesLive() {
        var engine = PolicyEngine()
        engine.clientsChanged([client(zoom)], now: t0)
        XCTAssertTrue(engine.approve(zoom, now: t0 + 1))
        XCTAssertTrue(engine.outputLive)
        XCTAssertTrue(engine.pendingPrompts.isEmpty)
        XCTAssertEqual(ProtectionState.current(bypassDetected: false, policy: engine), .live)
    }

    func testKeepPlaceholderStaysPlaceholderButCanGoLiveLater() {
        var engine = PolicyEngine()
        engine.clientsChanged([client(zoom)], now: t0)
        XCTAssertTrue(engine.keepPlaceholder(zoom))
        XCTAssertFalse(engine.outputLive)
        XCTAssertTrue(engine.pendingPrompts.isEmpty)
        // UR-13: go live later from the menu in the same session.
        XCTAssertTrue(engine.approve(zoom, now: t0 + 60))
        XCTAssertTrue(engine.outputLive)
    }

    // MARK: Prompt expiry (UR-09a)

    func testPromptExpiresIntoPlaceholder() {
        var engine = PolicyEngine(settings: PolicySettings(promptExpiry: 30, gracePeriod: 15))
        engine.clientsChanged([client(zoom)], now: t0)
        engine.tick(now: t0 + 29)
        XCTAssertEqual(engine.session(for: zoom)?.phase, .pending)
        engine.tick(now: t0 + 30)
        XCTAssertEqual(engine.session(for: zoom)?.phase, .placeholder)
        XCTAssertFalse(engine.outputLive)
    }

    func testSettingsAreClampedToApprovedRanges() {
        let low = PolicySettings(promptExpiry: 1, gracePeriod: 1)
        XCTAssertEqual(low.promptExpiry, 5)
        XCTAssertEqual(low.gracePeriod, 5)
        let high = PolicySettings(promptExpiry: 500, gracePeriod: 5000)
        XCTAssertEqual(high.promptExpiry, 120)
        XCTAssertEqual(high.gracePeriod, 300)
        let defaults = PolicySettings()
        XCTAssertEqual(defaults.promptExpiry, 30)
        XCTAssertEqual(defaults.gracePeriod, 15)
    }

    // MARK: Sessions and grace (UR-11, UR-12)

    func testRestartWithinGraceKeepsApproval() {
        var engine = PolicyEngine(settings: PolicySettings(promptExpiry: 30, gracePeriod: 15))
        let id = UUID()
        engine.clientsChanged([client(zoom, id: id)], now: t0)
        engine.approve(zoom, now: t0 + 1)
        engine.clientsChanged([], now: t0 + 10)
        XCTAssertFalse(engine.outputLive)
        engine.tick(now: t0 + 20)
        engine.clientsChanged([client(zoom, id: id)], now: t0 + 24)
        XCTAssertTrue(engine.outputLive, "restart 14 s after stop is within the 15 s grace period")
    }

    func testRestartAfterGraceNeedsNewApproval() {
        var engine = PolicyEngine(settings: PolicySettings(promptExpiry: 30, gracePeriod: 15))
        engine.clientsChanged([client(zoom)], now: t0)
        engine.approve(zoom, now: t0 + 1)
        engine.clientsChanged([], now: t0 + 10)
        engine.tick(now: t0 + 26)
        XCTAssertNil(engine.session(for: zoom), "approval discarded after grace")
        engine.clientsChanged([client(zoom)], now: t0 + 3600)
        XCTAssertEqual(engine.session(for: zoom)?.phase, .pending)
        XCTAssertFalse(engine.outputLive)
    }

    func testRestartAfterGraceNeedsNewApprovalEvenWithoutTick() {
        var engine = PolicyEngine(settings: PolicySettings(promptExpiry: 30, gracePeriod: 15))
        engine.clientsChanged([client(zoom)], now: t0)
        engine.approve(zoom, now: t0 + 1)
        engine.clientsChanged([], now: t0 + 10)
        engine.clientsChanged([client(zoom)], now: t0 + 100)
        XCTAssertEqual(engine.session(for: zoom)?.phase, .pending)
    }

    func testPendingPromptDisappearsWhenAppStopsAndPromptsAgainOnRestart() {
        // B1: Photo Booth starts, stops and restarts the camera within a second as its window opens.
        var engine = PolicyEngine()
        engine.clientsChanged([client(zoom)], now: t0)
        engine.clientsChanged([], now: t0 + 0.5)
        XCTAssertTrue(engine.pendingPrompts.isEmpty, "no prompt while the app is not using the camera")
        XCTAssertFalse(engine.outputLive)
        engine.clientsChanged([client(zoom)], now: t0 + 1)
        XCTAssertEqual(engine.session(for: zoom)?.phase, .pending)
        XCTAssertEqual(engine.pendingPrompts.map(\.app), [zoom], "an undecided session asks again")
        XCTAssertEqual(engine.session(for: zoom)?.promptExpiresAt, t0 + 1 + PolicySettings.defaultPromptExpiry,
                       "with a fresh expiry")
        XCTAssertFalse(engine.outputLive)
    }

    func testDeclinedSessionRestartWithinGraceKeepsPlaceholderWithoutPrompt() {
        var engine = PolicyEngine()
        engine.clientsChanged([client(zoom)], now: t0)
        engine.keepPlaceholder(zoom)
        engine.clientsChanged([], now: t0 + 2)
        engine.clientsChanged([client(zoom)], now: t0 + 5)
        XCTAssertEqual(engine.session(for: zoom)?.phase, .placeholder)
        XCTAssertTrue(engine.pendingPrompts.isEmpty)
    }

    func testExpiredPromptRestartWithinGraceKeepsPlaceholder() {
        var engine = PolicyEngine(settings: PolicySettings(promptExpiry: 5, gracePeriod: 15))
        engine.clientsChanged([client(zoom)], now: t0)
        engine.tick(now: t0 + 6)
        XCTAssertEqual(engine.session(for: zoom)?.phase, .placeholder, "expired into the placeholder")
        engine.clientsChanged([], now: t0 + 7)
        engine.clientsChanged([client(zoom)], now: t0 + 8)
        XCTAssertEqual(engine.session(for: zoom)?.phase, .placeholder)
        XCTAssertTrue(engine.pendingPrompts.isEmpty)
    }

    func testUndecidedSessionCannotBeApprovedWhileStopped() {
        var engine = PolicyEngine()
        engine.clientsChanged([client(zoom)], now: t0)
        engine.clientsChanged([], now: t0 + 1)
        XCTAssertFalse(engine.approve(zoom, now: t0 + 2), "no approval for an app that is not using the camera")
        engine.clientsChanged([client(zoom)], now: t0 + 3)
        XCTAssertFalse(engine.outputLive)
    }

    func testRuleR4RestartWithoutVisibleStopAfterLongGapIsNewSession() {
        var engine = PolicyEngine(settings: PolicySettings(promptExpiry: 30, gracePeriod: 15))
        let zoomID = UUID()
        let teamsID = UUID()
        engine.clientsChanged([client(zoom, id: zoomID, sequence: 1), client(teams, id: teamsID, sequence: 2)], now: t0)
        engine.approve(zoom, now: t0)
        engine.approve(teams, now: t0)
        XCTAssertTrue(engine.outputLive)
        // Zoom's stop was not attributable; it starts again an hour later.
        engine.clientsChanged([client(zoom, id: zoomID, sequence: 3, gap: 3600), client(teams, id: teamsID, sequence: 2)],
                              now: t0 + 3600)
        XCTAssertEqual(engine.session(for: zoom)?.phase, .pending)
        XCTAssertFalse(engine.outputLive)
    }

    func testRuleR4QuickRestartKeepsApproval() {
        var engine = PolicyEngine(settings: PolicySettings(promptExpiry: 30, gracePeriod: 15))
        let zoomID = UUID()
        engine.clientsChanged([client(zoom, id: zoomID, sequence: 1)], now: t0)
        engine.approve(zoom, now: t0)
        engine.clientsChanged([client(zoom, id: zoomID, sequence: 2, gap: 0.2)], now: t0 + 600)
        XCTAssertTrue(engine.outputLive)
    }

    // MARK: Several apps (D-1, UR-10)

    func testApprovingOneAppNeverExposesAnother() {
        var engine = PolicyEngine()
        engine.clientsChanged([client(zoom)], now: t0)
        engine.approve(zoom, now: t0)
        XCTAssertTrue(engine.outputLive)
        engine.clientsChanged([client(zoom, sequence: 1), client(teams)], now: t0 + 5)
        XCTAssertFalse(engine.outputLive, "Teams is not approved, so nobody gets live video")
        XCTAssertEqual(engine.blockingApps, [teams])
        XCTAssertEqual(engine.pendingPrompts.map(\.app), [teams])
        engine.approve(teams, now: t0 + 6)
        XCTAssertTrue(engine.outputLive)
    }

    // MARK: Shutter controls

    func testCloseShutterAndPanic() {
        var engine = PolicyEngine()
        engine.clientsChanged([client(zoom)], now: t0)
        engine.approve(zoom, now: t0)
        engine.closeShutter(zoom, now: t0 + 1)
        XCTAssertFalse(engine.outputLive)
        engine.approve(zoom, now: t0 + 2)
        XCTAssertTrue(engine.outputLive)
        engine.closeAllShutters()
        XCTAssertFalse(engine.outputLive)
        XCTAssertTrue(engine.pendingPrompts.isEmpty)
    }

    // MARK: Pause (UR-41, R6)

    func testPauseMakesLiveWithoutPromptsThenRequiresApproval() {
        var engine = PolicyEngine(settings: PolicySettings(promptExpiry: 30, gracePeriod: 15))
        engine.pause(until: t0 + 3600, now: t0)
        engine.clientsChanged([client(zoom)], now: t0 + 1)
        XCTAssertTrue(engine.outputLive)
        XCTAssertTrue(engine.pendingPrompts.isEmpty)
        // Live outranks Paused: a feed is actually going out.
        XCTAssertEqual(ProtectionState.current(bypassDetected: false, policy: engine), .live)
        engine.tick(now: t0 + 3600)
        XCTAssertFalse(engine.isPaused)
        XCTAssertFalse(engine.outputLive)
        XCTAssertEqual(engine.pendingPrompts.map(\.app), [zoom])
    }

    func testPauseEndMakesEndedSessionsPlaceholder() {
        var engine = PolicyEngine(settings: PolicySettings(promptExpiry: 30, gracePeriod: 300))
        engine.pause(until: t0 + 100, now: t0)
        engine.clientsChanged([client(zoom)], now: t0 + 1)
        engine.approve(zoom, now: t0 + 2)
        engine.clientsChanged([], now: t0 + 50)
        engine.tick(now: t0 + 100)
        engine.clientsChanged([client(zoom)], now: t0 + 110)
        XCTAssertFalse(engine.outputLive, "approval given during a pause must not survive it")
    }

    func testPanicCancelsPause() {
        var engine = PolicyEngine()
        engine.pause(until: t0 + 3600, now: t0)
        engine.clientsChanged([client(zoom)], now: t0 + 1)
        engine.closeAllShutters()
        XCTAssertFalse(engine.isPaused)
        XCTAssertFalse(engine.outputLive)
    }

    // MARK: Sleep (R5)

    func testSleepEndsAllSessions() {
        var engine = PolicyEngine()
        engine.clientsChanged([client(zoom)], now: t0)
        engine.approve(zoom, now: t0)
        engine.systemWillSleep()
        XCTAssertFalse(engine.outputLive)
        engine.tick(now: t0 + 600)
        XCTAssertEqual(engine.session(for: zoom)?.phase, .pending)
        XCTAssertFalse(engine.outputLive)
    }

    // MARK: Indicator priority (UR-35a)

    func testPausedWithoutClientsShowsPaused() {
        var engine = PolicyEngine()
        engine.pause(until: t0 + 3600, now: t0)
        XCTAssertEqual(ProtectionState.current(bypassDetected: false, policy: engine), .paused)
        engine.clientsChanged([client(zoom)], now: t0 + 1)
        XCTAssertEqual(ProtectionState.current(bypassDetected: false, policy: engine), .live)
        XCTAssertEqual(ProtectionState.current(bypassDetected: true, policy: engine), .unprotected)
    }

    func testBypassTakesPriority() {
        var engine = PolicyEngine()
        engine.clientsChanged([client(zoom)], now: t0)
        engine.approve(zoom, now: t0)
        XCTAssertEqual(ProtectionState.current(bypassDetected: true, policy: engine), .unprotected)
    }

    // MARK: More session rules

    func testUndecidedSessionDroppedAfterGraceAsksAgainAsNewSession() {
        var engine = PolicyEngine(settings: PolicySettings(promptExpiry: 30, gracePeriod: 5))
        engine.clientsChanged([client(zoom)], now: t0)
        engine.clientsChanged([], now: t0 + 1)
        engine.tick(now: t0 + 7)
        XCTAssertNil(engine.session(for: zoom), "undecided session discarded after grace")
        engine.clientsChanged([client(zoom)], now: t0 + 20)
        XCTAssertEqual(engine.session(for: zoom)?.phase, .pending)
        XCTAssertEqual(engine.session(for: zoom)?.startedAt, t0 + 20, "a new session")
    }

    func testUndecidedRestartWhilePausedIsLiveWithoutPrompt() {
        var engine = PolicyEngine()
        engine.clientsChanged([client(zoom)], now: t0)
        engine.pause(until: t0 + 600, now: t0 + 1)
        engine.clientsChanged([], now: t0 + 2)
        engine.clientsChanged([client(zoom)], now: t0 + 3)
        XCTAssertTrue(engine.outputLive, "paused: live without asking")
        XCTAssertTrue(engine.pendingPrompts.isEmpty)
        XCTAssertNil(engine.session(for: zoom)?.promptExpiresAt)
        engine.resume(now: t0 + 4)
        XCTAssertFalse(engine.outputLive)
        XCTAssertEqual(engine.pendingPrompts.map(\.app), [zoom], "resuming asks again")
    }

    func testSeveralAppsGetTheirOwnPrompts() {
        // UR-15
        var engine = PolicyEngine()
        engine.clientsChanged([client(zoom), client(teams)], now: t0)
        XCTAssertEqual(Set(engine.pendingPrompts.map(\.app)), [zoom, teams])
        engine.approve(zoom, now: t0 + 1)
        XCTAssertEqual(engine.pendingPrompts.map(\.app), [teams], "approving one leaves the other asking")
        XCTAssertFalse(engine.outputLive, "D-1: nothing live while another app is unapproved")
    }

    func testCloseAllWhilePendingRemovesPromptsAndStaysPlaceholder() {
        var engine = PolicyEngine()
        engine.clientsChanged([client(zoom), client(teams)], now: t0)
        engine.closeAllShutters()
        XCTAssertTrue(engine.pendingPrompts.isEmpty)
        XCTAssertFalse(engine.outputLive)
        XCTAssertEqual(engine.session(for: zoom)?.phase, .placeholder)
        XCTAssertTrue(engine.approve(zoom, now: t0 + 1), "can still go live later from the menu (UR-13)")
    }

    func testNewPromptExpiryAppliesToTheNextPrompt() {
        var engine = PolicyEngine(settings: PolicySettings(promptExpiry: 30, gracePeriod: 15))
        engine.updateSettings(PolicySettings(promptExpiry: 5, gracePeriod: 15))
        engine.clientsChanged([client(zoom)], now: t0)
        XCTAssertEqual(engine.session(for: zoom)?.promptExpiresAt, t0 + 5)
        engine.tick(now: t0 + 6)
        XCTAssertEqual(engine.session(for: zoom)?.phase, .placeholder)
    }
}
