import Foundation

/// Fail-closed decision logic used by the camera extension for every frame (architecture §5.2).
///
/// A live frame is forwarded only if it came through the authenticated sink, carries a tag for
/// the current epoch and generation, and matches the active format. Whenever no acceptable live
/// frame has arrived within `maxLiveFrameAge`, the placeholder is sent instead.
public struct FrameGate: Sendable {
    public enum Verdict: Equatable, Sendable {
        case forward
        case reject(RejectReason)
    }

    public enum RejectReason: String, Sendable {
        case unauthenticatedSink
        case missingTag
        case wrongEpoch
        case staleGeneration
        case wrongDimensions
    }

    public static let maxLiveFrameAge: TimeInterval = 0.1

    public let epoch: UInt64
    public private(set) var generation: UInt64 = 1
    public private(set) var activeFormat: Dimensions
    public private(set) var stats = GateStats()
    private var lastLiveFrameAt: TimeInterval?

    public init(epoch: UInt64, activeFormat: Dimensions) {
        self.epoch = epoch
        self.activeFormat = activeFormat
    }

    /// Call on every change to the set of clients. Invalidates all live frames already in flight.
    @discardableResult
    public mutating func advanceGeneration() -> UInt64 {
        generation &+= 1
        lastLiveFrameAt = nil
        return generation
    }

    public mutating func setActiveFormat(_ format: Dimensions) {
        activeFormat = format
        advanceGeneration()
    }

    public mutating func evaluateLiveFrame(tag: String?, sinkAuthenticated: Bool,
                                           dimensions: Dimensions, now: TimeInterval) -> Verdict {
        guard sinkAuthenticated else {
            stats.rejectedUnauthenticated += 1
            return .reject(.unauthenticatedSink)
        }
        guard let tag, let parsed = FrameTag(encoded: tag) else {
            stats.rejectedMissingTag += 1
            return .reject(.missingTag)
        }
        guard parsed.epoch == epoch else {
            stats.rejectedWrongEpoch += 1
            return .reject(.wrongEpoch)
        }
        guard parsed.generation == generation else {
            stats.rejectedStaleGeneration += 1
            return .reject(.staleGeneration)
        }
        guard dimensions == activeFormat else {
            stats.rejectedWrongDimensions += 1
            return .reject(.wrongDimensions)
        }
        lastLiveFrameAt = now
        stats.liveFramesForwarded += 1
        return .forward
    }

    /// Called on every output tick. Returns true when the placeholder must be sent.
    public mutating func needsPlaceholderFrame(now: TimeInterval) -> Bool {
        if let last = lastLiveFrameAt, now - last < Self.maxLiveFrameAge {
            return false
        }
        stats.placeholderFramesSent += 1
        return true
    }

    public mutating func noteUnauthenticatedSinkAttempt() {
        stats.rejectedUnauthenticated += 1
    }
}
