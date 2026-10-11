import XCTest
@testable import OffSightCore

/// Property-based check of the core guarantee over random event sequences:
/// output is live only if paused or every active app has an active, approved session.
final class PolicyInvariantTests: XCTestCase {
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    func testOutputLiveImpliesEveryActiveAppApprovedOrPaused() {
        let apps = [AppKey("a"), AppKey("b"), AppKey("c")]
        let clientIDs = Dictionary(uniqueKeysWithValues: apps.map { ($0, UUID()) })

        for seed in UInt64(1)...200 {
            var rng = SeededGenerator(state: seed)
            var engine = PolicyEngine(settings: PolicySettings(promptExpiry: 10, gracePeriod: 5))
            var now = Date(timeIntervalSinceReferenceDate: 0)
            var sequence: UInt64 = 0
            var streaming: [AppKey: UInt64] = [:]

            for _ in 0..<300 {
                now = now.addingTimeInterval(Double.random(in: 0...4, using: &rng))
                let app = apps.randomElement(using: &rng)!
                switch Int.random(in: 0..<10, using: &rng) {
                case 0, 1:
                    sequence += 1
                    streaming[app] = sequence
                    engine.clientsChanged(clients(streaming, clientIDs, gap: Double.random(in: 0...60, using: &rng)), now: now)
                case 2:
                    streaming[app] = nil
                    engine.clientsChanged(clients(streaming, clientIDs, gap: nil), now: now)
                case 3: engine.approve(app, now: now)
                case 4: engine.keepPlaceholder(app)
                case 5: engine.closeShutter(app, now: now)
                case 6: if Int.random(in: 0..<10, using: &rng) == 0 { engine.closeAllShutters() }
                case 7: if Int.random(in: 0..<20, using: &rng) == 0 { engine.pause(until: now.addingTimeInterval(30), now: now) }
                case 8: if Int.random(in: 0..<30, using: &rng) == 0 { engine.systemWillSleep() }
                default: engine.tick(now: now)
                }

                if engine.outputLive {
                    let ok = engine.isPaused || engine.activeApps.allSatisfy { key in
                        guard let s = engine.session(for: key) else { return false }
                        return s.isActive && s.phase == .live
                    }
                    XCTAssertTrue(ok, "seed \(seed): live output without approval")
                }
                XCTAssertTrue(engine.activeApps == Set(streaming.keys), "seed \(seed): active apps out of sync")
                for session in engine.pendingPrompts {
                    XCTAssertTrue(session.isActive, "seed \(seed): prompt for an app that is not using the camera")
                }
            }
        }
    }

    private func clients(_ streaming: [AppKey: UInt64], _ ids: [AppKey: UUID], gap: Double?) -> [StreamingClient] {
        streaming.map { StreamingClient(clientID: ids[$0.key]!, app: $0.key, startSequence: $0.value, restartGap: gap) }
    }
}
