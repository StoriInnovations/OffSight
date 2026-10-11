import Foundation

/// Fail-closed decision logic used by the camera extension for every frame (architecture §5.2).
///
/// A live frame is forwarded only if it came through the authenticated sink, carries a tag for
/// the current epoch and generation, and matches the active format. The app's placeholder frames
/// need the current epoch but not the generation. Whenever no acceptable frame has arrived from
/// the sink within `maxLiveFrameAge`, the extension sends its own placeholder instead.
public struct FrameGate: Sendable {
    public enum Verdict: Equatable, Sendable {
        case forward(FrameTag.Kind)
        /// An authenticated request to advertise this format (never forwarded).
        case formatRequest(Dimensions)
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
    /// Last frame forwarded from the sink (live or the app's placeholder).
    private var lastForwardedAt: TimeInterval?

    public init(epoch: UInt64, activeFormat: Dimensions) {
        self.epoch = epoch
        self.activeFormat = activeFormat
    }

    /// Call on every change to the set of clients. Invalidates all live frames already in flight.
    @discardableResult
    public mutating func advanceGeneration() -> UInt64 {
        generation &+= 1
        lastForwardedAt = nil
        return generation
    }

    public mutating func setActiveFormat(_ format: Dimensions) {
        activeFormat = format
        advanceGeneration()
    }

    /// Decides whether a frame from the sink may be forwarded to meeting apps.
    public mutating func evaluateSinkFrame(tag: String?, sinkAuthenticated: Bool,
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
        if parsed.kind == .formatRequest {
            return .formatRequest(dimensions)
        }
        // The generation fence applies to camera content only; a placeholder may go to anyone.
        guard parsed.kind == .placeholder || parsed.generation == generation else {
            stats.rejectedStaleGeneration += 1
            return .reject(.staleGeneration)
        }
        guard dimensions == activeFormat else {
            stats.rejectedWrongDimensions += 1
            return .reject(.wrongDimensions)
        }
        lastForwardedAt = now
        switch parsed.kind {
        case .live: stats.liveFramesForwarded += 1
        case .placeholder: stats.appPlaceholderFramesForwarded += 1
        case .formatRequest: break
        }
        return .forward(parsed.kind)
    }

    /// Called on every output tick. Returns true when the placeholder must be sent.
    public mutating func needsPlaceholderFrame(now: TimeInterval) -> Bool {
        if let last = lastForwardedAt, now - last < Self.maxLiveFrameAge {
            return false
        }
        stats.placeholderFramesSent += 1
        return true
    }

    public mutating func noteUnauthenticatedSinkAttempt() {
        stats.rejectedUnauthenticated += 1
    }
}
