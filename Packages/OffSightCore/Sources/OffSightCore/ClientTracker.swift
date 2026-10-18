import Foundation

/// Bookkeeping of meeting-app clients inside the camera extension.
///
/// CoreMediaIO tells the extension which client is starting a stream, but not which one stopped,
/// so stops are counted and all clients are marked stopped once the count reaches zero
/// (architecture §6.1, rule R4).
public struct ClientTracker: Sendable {
    public private(set) var records: [UUID: ClientRecord] = [:]
    public private(set) var activeStreamCount = 0
    private var startTimes: [UUID: TimeInterval] = [:]
    private var sequence: UInt64 = 0
    private var lastStopAt: TimeInterval?

    public init() {}

    /// A client was authorised to start the source stream.
    public mutating func clientStarting(clientID: UUID, pid: Int32, signingID: String?, now: TimeInterval) {
        sequence += 1
        var gap: Double?
        if let previousStart = startTimes[clientID] {
            if let lastStopAt, lastStopAt >= previousStart {
                gap = now - lastStopAt
            } else {
                gap = now - previousStart
            }
        }
        records[clientID] = ClientRecord(clientID: clientID, pid: pid, signingID: signingID,
                                         streaming: true, startSequence: sequence, restartGap: gap)
        startTimes[clientID] = now
    }

    /// The source stream's startStream callback.
    public mutating func streamStarted() {
        activeStreamCount += 1
    }

    /// The source stream's stopStream callback.
    public mutating func streamStopped(now: TimeInterval) {
        activeStreamCount = max(0, activeStreamCount - 1)
        lastStopAt = now
        if activeStreamCount == 0 {
            for id in records.keys {
                records[id]?.streaming = false
            }
        }
    }

    public mutating func clientDisconnected(clientID: UUID) {
        records.removeValue(forKey: clientID)
        startTimes.removeValue(forKey: clientID)
    }

    public mutating func processExited(pid: Int32) {
        for (id, record) in records where record.pid == pid {
            records.removeValue(forKey: id)
            startTimes.removeValue(forKey: id)
        }
    }

    public var sortedRecords: [ClientRecord] {
        records.values.sorted { $0.startSequence < $1.startSequence }
    }
}
