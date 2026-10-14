import Foundation

/// Identifies the app an approval belongs to: the resolved host app's bundle ID
/// (a browser's helpers all map to the browser, UR-34).
public struct AppKey: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public let id: String

    public init(_ id: String) {
        self.id = id
    }

    public static func < (lhs: AppKey, rhs: AppKey) -> Bool { lhs.id < rhs.id }
    public var description: String { id }
}

public enum SessionPhase: String, Codable, Sendable {
    /// Waiting for the user's decision; the app gets the placeholder.
    case pending
    /// Approved for this session; the app may get live video.
    case live
    /// Denied, expired or shutter closed; the app gets the placeholder.
    case placeholder
}

public struct Session: Equatable, Sendable {
    public let app: AppKey
    public fileprivate(set) var phase: SessionPhase
    public fileprivate(set) var startedAt: Date
    public fileprivate(set) var promptExpiresAt: Date?
    /// Set while the app has stopped using the camera and the grace period is running.
    public fileprivate(set) var endedAt: Date?

    public var isActive: Bool { endedAt == nil }
}

public struct PolicySettings: Equatable, Codable, Sendable {
    public static let promptExpiryRange: ClosedRange<TimeInterval> = 5...120
    public static let gracePeriodRange: ClosedRange<TimeInterval> = 5...300
    public static let defaultPromptExpiry: TimeInterval = 30
    public static let defaultGracePeriod: TimeInterval = 15

    public private(set) var promptExpiry: TimeInterval
    public private(set) var gracePeriod: TimeInterval

    public init(promptExpiry: TimeInterval = PolicySettings.defaultPromptExpiry,
                gracePeriod: TimeInterval = PolicySettings.defaultGracePeriod) {
        self.promptExpiry = min(max(promptExpiry, Self.promptExpiryRange.lowerBound), Self.promptExpiryRange.upperBound)
        self.gracePeriod = min(max(gracePeriod, Self.gracePeriodRange.lowerBound), Self.gracePeriodRange.upperBound)
    }
}

/// A client currently streaming from OffSight Camera, already resolved to its app.
public struct StreamingClient: Hashable, Sendable {
    public let clientID: UUID
    public let app: AppKey
    public let startSequence: UInt64
    public let restartGap: Double?

    public init(clientID: UUID, app: AppKey, startSequence: UInt64, restartGap: Double? = nil) {
        self.clientID = clientID
        self.app = app
        self.startSequence = startSequence
        self.restartGap = restartGap
    }
}

/// Per-app session state machine and the live/placeholder decision (architecture §6).
///
/// Approvals exist only in memory, inside `Session.phase == .live`, and are discarded when the
/// session ends (UR-11). Nothing here is ever persisted.
public struct PolicyEngine: Sendable {
    public private(set) var settings: PolicySettings
    public private(set) var sessions: [AppKey: Session] = [:]
    public private(set) var pausedUntil: Date?
    public private(set) var activeApps: Set<AppKey> = []
    private var lastStartSequence: [UUID: UInt64] = [:]

    public init(settings: PolicySettings = PolicySettings()) {
        self.settings = settings
    }

    // MARK: Derived state

    public var isPaused: Bool { pausedUntil != nil }

    /// Live video may flow only while every app using OffSight Camera is approved (D-1),
    /// or while protection is paused (UR-41).
    public var outputLive: Bool {
        guard !activeApps.isEmpty else { return false }
        if isPaused { return true }
        return activeApps.allSatisfy { app in
            guard let session = sessions[app] else { return false }
            return session.isActive && session.phase == .live
        }
    }

    public var activeSessions: [Session] {
        activeApps.sorted().compactMap { sessions[$0] }
    }

    /// Sessions that need an approval prompt. Prompts are suppressed while paused.
    public var pendingPrompts: [Session] {
        guard !isPaused else { return [] }
        return activeSessions.filter { $0.phase == .pending }
    }

    /// Active apps that are not approved, i.e. the reason approved apps are on placeholder.
    public var blockingApps: [AppKey] {
        activeSessions.filter { $0.phase != .live }.map(\.app)
    }

    public func session(for app: AppKey) -> Session? {
        sessions[app]
    }

    // MARK: Inputs

    public mutating func updateSettings(_ newSettings: PolicySettings) {
        settings = newSettings
    }

    /// Feed the full set of currently streaming clients after every snapshot from the extension.
    public mutating func clientsChanged(_ clients: [StreamingClient], now: Date) {
        let newActive = Set(clients.map(\.app))

        var restarted: [AppKey: Double] = [:]
        var seen: [UUID: UInt64] = [:]
        for client in clients {
            if let previous = lastStartSequence[client.clientID], client.startSequence > previous {
                let gap = client.restartGap ?? .infinity
                restarted[client.app] = max(restarted[client.app] ?? 0, gap)
            }
            seen[client.clientID] = client.startSequence
        }
        lastStartSequence = seen

        for app in activeApps.subtracting(newActive) {
            endSession(app, now: now)
        }
        for app in newActive.subtracting(activeApps) {
            startOrResumeSession(app, now: now)
        }
        // Rule R4: an app that was already active restarted without a visible stop. Treat it as a
        // new session unless the restart happened within the grace period.
        for (app, gap) in restarted where activeApps.contains(app) && newActive.contains(app) {
            if gap > settings.gracePeriod {
                startNewSession(app, now: now)
            }
        }

        activeApps = newActive
        ensureSessionsForActiveApps(now: now)
    }

    /// "Go live for this session" (prompt or menu).
    @discardableResult
    public mutating func approve(_ app: AppKey, now: Date) -> Bool {
        guard var session = sessions[app], session.isActive, session.phase != .live else { return false }
        session.phase = .live
        session.promptExpiresAt = nil
        sessions[app] = session
        return true
    }

    /// "Keep placeholder" or dismissing the prompt.
    @discardableResult
    public mutating func keepPlaceholder(_ app: AppKey) -> Bool {
        guard var session = sessions[app], session.phase == .pending else { return false }
        session.phase = .placeholder
        session.promptExpiresAt = nil
        sessions[app] = session
        return true
    }

    /// Close the shutter for one app (UR-16). Ends any pause first.
    public mutating func closeShutter(_ app: AppKey, now: Date) {
        if isPaused {
            endPause(now: now)
        }
        guard var session = sessions[app] else { return }
        session.phase = .placeholder
        session.promptExpiresAt = nil
        sessions[app] = session
    }

    /// Panic: every app back to placeholder, pause cancelled, no new prompts (UR-16, UR-17).
    public mutating func closeAllShutters() {
        pausedUntil = nil
        for app in sessions.keys {
            sessions[app]?.phase = .placeholder
            sessions[app]?.promptExpiresAt = nil
        }
    }

    /// Timed pause (UR-41): everything live, no prompts, until `until`.
    public mutating func pause(until: Date, now: Date) {
        guard until > now else { return }
        pausedUntil = until
    }

    /// End a pause early. Every active session must be approved again (rule R6).
    public mutating func resume(now: Date) {
        guard isPaused else { return }
        endPause(now: now)
    }

    /// Advance timers: prompt expiry, grace period, pause end. Call a few times per second.
    public mutating func tick(now: Date) {
        if let until = pausedUntil, now >= until {
            endPause(now: now)
        }
        for (app, session) in sessions {
            if let endedAt = session.endedAt {
                if now.timeIntervalSince(endedAt) > settings.gracePeriod {
                    sessions[app] = nil
                }
            } else if session.phase == .pending, let expiresAt = session.promptExpiresAt, now >= expiresAt {
                // UR-09a: an unanswered prompt expires into the placeholder, never into live.
                sessions[app]?.phase = .placeholder
                sessions[app]?.promptExpiresAt = nil
            }
        }
        ensureSessionsForActiveApps(now: now)
    }

    /// Rule R5: sleep ends every session. Apps still using the camera after wake are prompted again.
    public mutating func systemWillSleep() {
        sessions.removeAll()
        pausedUntil = nil
    }

    // MARK: Private

    private mutating func startNewSession(_ app: AppKey, now: Date) {
        sessions[app] = Session(app: app, phase: .pending, startedAt: now,
                                promptExpiresAt: isPaused ? nil : now.addingTimeInterval(settings.promptExpiry),
                                endedAt: nil)
    }

    private mutating func startOrResumeSession(_ app: AppKey, now: Date) {
        if var session = sessions[app], let endedAt = session.endedAt,
           now.timeIntervalSince(endedAt) <= settings.gracePeriod {
            // UR-12: restart within the grace period keeps the earlier decision. A session that
            // ended before the user decided has no decision to keep, so it asks again (rule R2).
            session.endedAt = nil
            if session.phase == .pending {
                session.promptExpiresAt = isPaused ? nil : now.addingTimeInterval(settings.promptExpiry)
            }
            sessions[app] = session
        } else {
            startNewSession(app, now: now)
        }
    }

    private mutating func endSession(_ app: AppKey, now: Date) {
        guard var session = sessions[app] else { return }
        // An unanswered session stays undecided (pending) but its prompt goes away while the app
        // is not using the camera; it prompts again if the app restarts within the grace period.
        session.promptExpiresAt = nil
        session.endedAt = now
        sessions[app] = session
    }

    private mutating func endPause(now: Date) {
        pausedUntil = nil
        for (app, session) in sessions {
            if session.isActive {
                sessions[app]?.phase = .pending
                sessions[app]?.promptExpiresAt = now.addingTimeInterval(settings.promptExpiry)
            } else {
                sessions[app]?.phase = .placeholder
                sessions[app]?.promptExpiresAt = nil
            }
        }
    }

    private mutating func ensureSessionsForActiveApps(now: Date) {
        for app in activeApps where sessions[app] == nil {
            startNewSession(app, now: now)
        }
    }
}

/// What the menu bar icon shows (UR-20, UR-35a). When several conditions hold, the brand spec's
/// priority applies: unprotected > live > paused > protected > idle.
public enum ProtectionState: String, CaseIterable, Sendable {
    /// No app is using OffSight Camera.
    case idle
    /// At least one app is connected and receiving the placeholder.
    case protected
    /// A real camera feed is going out (approved, or protection paused with an app connected).
    case live
    /// An app is reading a physical camera directly, bypassing OffSight.
    case unprotected
    /// The user paused protection.
    case paused

    public static func current(bypassDetected: Bool, policy: PolicyEngine) -> ProtectionState {
        if bypassDetected { return .unprotected }
        if policy.outputLive { return .live }
        if policy.isPaused { return .paused }
        if !policy.activeApps.isEmpty { return .protected }
        return .idle
    }
}
