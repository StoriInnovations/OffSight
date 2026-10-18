import Foundation
import OffSightCore

/// Talks to a Debug build of OffSight.app through its test hook (distributed notifications).
/// Release and App Store builds have no hook, so `state()` returns nil there.
final class AppLink {
    private(set) var latest: TestHookState?
    private var observer: NSObjectProtocol?

    init() {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(TestHook.stateNotification), object: nil, queue: .main) { [weak self] note in
            guard let json = note.object as? String, let state = TestHookState.decode(json) else { return }
            if state.time >= (self?.latest?.time ?? 0) { self?.latest = state }
        }
    }

    func send(_ command: TestHook.Command) {
        DistributedNotificationCenter.default().postNotificationName(Notification.Name(TestHook.commandNotification),
                                                                     object: command.encoded, userInfo: nil,
                                                                     deliverImmediately: true)
    }

    /// Asks for a fresh state; nil if the app doesn't answer within `timeout`.
    func state(timeout: TimeInterval = 2) -> TestHookState? {
        let before = latest?.time ?? 0
        send(.state)
        guard Wait.until(timeout, { (self.latest?.time ?? 0) > before }) != nil else { return nil }
        return latest
    }

    /// Sends `command` and returns the state that follows it.
    @discardableResult
    func run(_ command: TestHook.Command, timeout: TimeInterval = 2) -> TestHookState? {
        let before = latest?.time ?? 0
        send(command)
        guard Wait.until(timeout, { (self.latest?.time ?? 0) > before }) != nil else { return nil }
        return latest
    }

    /// Waits until a state satisfies `condition`, asking for fresh states every 0.25 s.
    func waitFor(_ timeout: TimeInterval, _ condition: @escaping (TestHookState) -> Bool) -> TestHookState? {
        var lastAsk = Date.distantPast
        var match: TestHookState?
        _ = Wait.until(timeout) {
            if let state = self.latest, condition(state) {
                match = state
                return true
            }
            if Date().timeIntervalSince(lastAsk) > 0.25 {
                lastAsk = Date()
                self.send(.state)
            }
            return false
        }
        return match
    }
}

enum Wait {
    /// Spins the run loop (so notifications and capture callbacks arrive) until `condition` holds.
    /// Returns the seconds it took, or nil on timeout.
    @discardableResult
    static func until(_ timeout: TimeInterval, poll: TimeInterval = 0.01, _ condition: () -> Bool) -> TimeInterval? {
        let start = Date()
        while true {
            if condition() { return Date().timeIntervalSince(start) }
            if Date().timeIntervalSince(start) > timeout { return nil }
            RunLoop.current.run(until: Date().addingTimeInterval(poll))
        }
    }

    static func sleep(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
