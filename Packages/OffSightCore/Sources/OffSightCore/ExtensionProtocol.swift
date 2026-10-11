import Foundation

/// One meeting-app connection to OffSight Camera, as seen by the extension.
public struct ClientRecord: Codable, Hashable, Sendable {
    public var clientID: UUID
    public var pid: Int32
    public var signingID: String?
    public var streaming: Bool
    /// Increases every time any client starts streaming; lets the app notice restarts.
    public var startSequence: UInt64
    /// Seconds between the last observed stream stop and this (re)start, or nil on first start.
    public var restartGap: Double?

    public init(clientID: UUID, pid: Int32, signingID: String?, streaming: Bool,
                startSequence: UInt64, restartGap: Double? = nil) {
        self.clientID = clientID
        self.pid = pid
        self.signingID = signingID
        self.streaming = streaming
        self.startSequence = startSequence
        self.restartGap = restartGap
    }
}

/// Counters the extension keeps about what it sent; published for diagnostics only.
/// Decoding tolerates missing fields, so app and extension builds of different ages interoperate.
public struct GateStats: Codable, Equatable, Sendable {
    public var liveFramesForwarded: UInt64 = 0
    /// Placeholder frames rendered by OffSight.app and forwarded from the sink.
    public var appPlaceholderFramesForwarded: UInt64 = 0
    /// Placeholder frames the extension generated itself (fallback when the app sends none).
    public var placeholderFramesSent: UInt64 = 0
    public var rejectedUnauthenticated: UInt64 = 0
    public var rejectedMissingTag: UInt64 = 0
    public var rejectedWrongEpoch: UInt64 = 0
    public var rejectedStaleGeneration: UInt64 = 0
    public var rejectedWrongDimensions: UInt64 = 0

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        liveFramesForwarded = try c.decodeIfPresent(UInt64.self, forKey: .liveFramesForwarded) ?? 0
        appPlaceholderFramesForwarded = try c.decodeIfPresent(UInt64.self, forKey: .appPlaceholderFramesForwarded) ?? 0
        placeholderFramesSent = try c.decodeIfPresent(UInt64.self, forKey: .placeholderFramesSent) ?? 0
        rejectedUnauthenticated = try c.decodeIfPresent(UInt64.self, forKey: .rejectedUnauthenticated) ?? 0
        rejectedMissingTag = try c.decodeIfPresent(UInt64.self, forKey: .rejectedMissingTag) ?? 0
        rejectedWrongEpoch = try c.decodeIfPresent(UInt64.self, forKey: .rejectedWrongEpoch) ?? 0
        rejectedStaleGeneration = try c.decodeIfPresent(UInt64.self, forKey: .rejectedStaleGeneration) ?? 0
        rejectedWrongDimensions = try c.decodeIfPresent(UInt64.self, forKey: .rejectedWrongDimensions) ?? 0
    }
}

/// How the extension's sink (frames from OffSight.app) is being consumed; diagnostics only.
public struct SinkStats: Codable, Equatable, Sendable {
    public var consumeLoopsStarted: UInt64 = 0
    public var consumeCallbacks: UInt64 = 0
    public var buffersReceived: UInt64 = 0
    public var buffersWithoutImage: UInt64 = 0
    public var consumeErrors: UInt64 = 0
    public var lastError: String?

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        consumeLoopsStarted = try c.decodeIfPresent(UInt64.self, forKey: .consumeLoopsStarted) ?? 0
        consumeCallbacks = try c.decodeIfPresent(UInt64.self, forKey: .consumeCallbacks) ?? 0
        buffersReceived = try c.decodeIfPresent(UInt64.self, forKey: .buffersReceived) ?? 0
        buffersWithoutImage = try c.decodeIfPresent(UInt64.self, forKey: .buffersWithoutImage) ?? 0
        consumeErrors = try c.decodeIfPresent(UInt64.self, forKey: .consumeErrors) ?? 0
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
    }
}

/// What the extension does with the stream meeting apps read; diagnostics only.
public struct SourceStats: Codable, Equatable, Sendable {
    /// True between CoreMediaIO's startStream and the matching stopStream.
    public var streaming = false
    public var startCalls: UInt64 = 0
    public var stopCalls: UInt64 = 0
    /// Frames actually handed to CoreMediaIO, by origin.
    public var sentLive: UInt64 = 0
    public var sentAppPlaceholder: UInt64 = 0
    public var sentFallback: UInt64 = 0
    /// Frames from the sink that passed the gate while no app had the stream started.
    public var droppedNotStreaming: UInt64 = 0

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        streaming = try c.decodeIfPresent(Bool.self, forKey: .streaming) ?? false
        startCalls = try c.decodeIfPresent(UInt64.self, forKey: .startCalls) ?? 0
        stopCalls = try c.decodeIfPresent(UInt64.self, forKey: .stopCalls) ?? 0
        sentLive = try c.decodeIfPresent(UInt64.self, forKey: .sentLive) ?? 0
        sentAppPlaceholder = try c.decodeIfPresent(UInt64.self, forKey: .sentAppPlaceholder) ?? 0
        sentFallback = try c.decodeIfPresent(UInt64.self, forKey: .sentFallback) ?? 0
        droppedNotStreaming = try c.decodeIfPresent(UInt64.self, forKey: .droppedNotStreaming) ?? 0
    }
}

/// State the extension publishes through its read-only custom property.
public struct ClientSnapshot: Codable, Equatable, Sendable {
    public var epoch: UInt64
    public var generation: UInt64
    public var activeFormat: Dimensions
    public var clients: [ClientRecord]
    public var stats: GateStats
    public var sinkConnected: Bool
    public var sinkAuthMode: String
    /// Optional so app and extension builds of different ages still understand each other.
    public var sink: SinkStats?
    /// A camera format the app asked for, applied once no app is using OffSight Camera.
    public var pendingFormat: Dimensions?
    public var source: SourceStats?

    public init(epoch: UInt64, generation: UInt64, activeFormat: Dimensions, clients: [ClientRecord],
                stats: GateStats = GateStats(), sinkConnected: Bool = false, sinkAuthMode: String = "none",
                sink: SinkStats? = nil, pendingFormat: Dimensions? = nil, source: SourceStats? = nil) {
        self.epoch = epoch
        self.generation = generation
        self.activeFormat = activeFormat
        self.clients = clients
        self.stats = stats
        self.sinkConnected = sinkConnected
        self.sinkAuthMode = sinkAuthMode
        self.sink = sink
        self.pendingFormat = pendingFormat
        self.source = source
    }

    /// True when the parts that drive approval decisions are identical (stats are ignored).
    public func hasSameRouting(as other: ClientSnapshot) -> Bool {
        epoch == other.epoch && generation == other.generation
            && activeFormat == other.activeFormat && clients == other.clients
    }

    public func encodedJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    public static func decode(json: String) -> ClientSnapshot? {
        try? JSONDecoder().decode(ClientSnapshot.self, from: Data(json.utf8))
    }
}

/// Tag attached to every frame the app sends into the sink. Live frames are forwarded only when
/// the tag matches the extension's current epoch and client-set generation (the "generation
/// fence"). Placeholder frames carry no camera content, so they only need the current epoch.
public struct FrameTag: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case live
        case placeholder = "ph"
        /// Not shown to anyone: announces the live camera's native size (the frame's dimensions).
        case formatRequest = "fmt"
    }

    public let kind: Kind
    public let epoch: UInt64
    public let generation: UInt64

    public init(kind: Kind = .live, epoch: UInt64, generation: UInt64) {
        self.kind = kind
        self.epoch = epoch
        self.generation = generation
    }

    public var encoded: String { "\(kind.rawValue)|\(epoch)|\(generation)" }

    public init?(encoded: String) {
        let parts = encoded.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 3, let kind = Kind(rawValue: String(parts[0])),
              let epoch = UInt64(parts[1]), let generation = UInt64(parts[2]) else { return nil }
        self.init(kind: kind, epoch: epoch, generation: generation)
    }
}
