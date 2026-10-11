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
public struct GateStats: Codable, Equatable, Sendable {
    public var liveFramesForwarded: UInt64 = 0
    public var placeholderFramesSent: UInt64 = 0
    public var rejectedUnauthenticated: UInt64 = 0
    public var rejectedMissingTag: UInt64 = 0
    public var rejectedWrongEpoch: UInt64 = 0
    public var rejectedStaleGeneration: UInt64 = 0
    public var rejectedWrongDimensions: UInt64 = 0

    public init() {}
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

    public init(epoch: UInt64, generation: UInt64, activeFormat: Dimensions, clients: [ClientRecord],
                stats: GateStats = GateStats(), sinkConnected: Bool = false, sinkAuthMode: String = "none") {
        self.epoch = epoch
        self.generation = generation
        self.activeFormat = activeFormat
        self.clients = clients
        self.stats = stats
        self.sinkConnected = sinkConnected
        self.sinkAuthMode = sinkAuthMode
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

/// Tag attached to every live frame the app sends. The extension forwards a live frame only
/// when the tag matches its current epoch and client-set generation (the "generation fence").
public struct FrameTag: Equatable, Sendable {
    public let epoch: UInt64
    public let generation: UInt64

    public init(epoch: UInt64, generation: UInt64) {
        self.epoch = epoch
        self.generation = generation
    }

    public var encoded: String { "live|\(epoch)|\(generation)" }

    public init?(encoded: String) {
        let parts = encoded.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "live",
              let epoch = UInt64(parts[1]), let generation = UInt64(parts[2]) else { return nil }
        self.init(epoch: epoch, generation: generation)
    }
}
