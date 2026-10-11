import CoreMedia
import CoreMediaIO
import Foundation
import OffSightCore
import os

/// Finds OffSight Camera, reads its client snapshot and pushes frames into its sink stream.
final class ExtensionLink {
    /// Called on the main queue whenever the routing-relevant part of the snapshot changes.
    var onSnapshot: ((ClientSnapshot) -> Void)?
    /// Called on the main queue when OffSight Camera disappears (extension restarted, replaced or removed).
    var onDeviceLost: (() -> Void)?

    private(set) var deviceID: CMIOObjectID?
    private(set) var sourceStreamID: CMIOStreamID?
    private(set) var sinkStreamID: CMIOStreamID?
    private(set) var latestSnapshot: ClientSnapshot?
    private(set) var listenerCallbacks = 0
    private(set) var sinkStartStatus: OSStatus?

    private let log = Logger(subsystem: OffSightConstants.logSubsystem, category: "link")
    private let snapshotSelector = fourCharCode(OffSightConstants.snapshotPropertyFourCC)
    private var pollTimer: Timer?
    private var pollCount = 0
    private(set) var sinkStartAttempts = 0
    private var devicesListenerInstalled = false
    private var failedSnapshotReads = 0
    private(set) var rebinds = 0
    private var snapshotListener: (stream: CMIOStreamID, block: CMIOObjectPropertyListenerBlock)?

    private let sinkLock = NSLock()
    private var sinkQueue: CMSimpleQueue?

    var isConnected: Bool { deviceID != nil }

    func start() {
        installDevicesListener()
        refreshDevice()
        // Fallback poll: spike S2 checks whether property notifications alone are reliable.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.pollCount += 1
            if self.deviceID == nil {
                self.refreshDevice()
            } else if self.readSnapshot() == nil {
                // The extension restarts or is replaced on every update, possibly keeping the same
                // device ID; after 2 s of unreadable snapshots, reconnect from scratch.
                self.failedSnapshotReads += 1
                if self.failedSnapshotReads >= 8 {
                    self.failedSnapshotReads = 0
                    self.refreshDevice(force: true)
                }
            } else {
                self.failedSnapshotReads = 0
                self.retrySinkIfNeeded()
            }
        }
    }

    // MARK: Device discovery

    private func installDevicesListener() {
        guard !devicesListenerInstalled else { return }
        var address = CMIO.address(UInt32(kCMIOHardwarePropertyDevices))
        let status = CMIOObjectAddPropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &address, DispatchQueue.main) { [weak self] _, _ in
            self?.refreshDevice()
        }
        devicesListenerInstalled = status == noErr
    }

    /// Binds to OffSight Camera's current device and streams. Rebinds whenever any of their IDs
    /// change, or when `force` is set (the extension can restart with the same device ID).
    func refreshDevice(force: Bool = false) {
        let found = CMIO.devices().first { device in
            CMIO.deviceUID(of: device) == OffSightConstants.deviceUUID.uuidString
                || CMIO.name(of: device) == OffSightConstants.deviceName
        }
        var source: CMIOStreamID?
        var sink: CMIOStreamID?
        if let found {
            for stream in CMIO.streams(of: found) {
                switch CMIO.name(of: stream) {
                case OffSightConstants.sourceStreamName?: source = stream
                case OffSightConstants.sinkStreamName?: sink = stream
                default: break
                }
            }
        }
        guard force || found != deviceID || source != sourceStreamID || sink != sinkStreamID else { return }

        let wasConnected = deviceID != nil
        stopSink()
        removeSnapshotListener()
        deviceID = found
        sourceStreamID = source
        sinkStreamID = sink
        latestSnapshot = nil
        sinkStartStatus = nil
        guard let found else {
            log.info("OffSight Camera not present")
            if wasConnected { onDeviceLost?() }
            return
        }
        rebinds += 1
        log.info("OffSight Camera bound: device \(found), source \(source ?? 0), sink \(sink ?? 0) (bind #\(self.rebinds))")

        if let source {
            var address = CMIO.address(snapshotSelector)
            let block: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.listenerCallbacks += 1
                self?.readSnapshot()
            }
            if CMIOObjectAddPropertyListenerBlock(source, &address, DispatchQueue.main, block) == noErr {
                snapshotListener = (source, block)
            }
        }
        startSink()
        readSnapshot()
    }

    private func removeSnapshotListener() {
        guard let listener = snapshotListener else { return }
        var address = CMIO.address(snapshotSelector)
        CMIOObjectRemovePropertyListenerBlock(listener.stream, &address, DispatchQueue.main, listener.block)
        snapshotListener = nil
    }

    // MARK: Snapshot

    @discardableResult
    func readSnapshot() -> ClientSnapshot? {
        guard let sourceStreamID,
              let json = CMIO.string(of: sourceStreamID, selector: snapshotSelector),
              let snapshot = ClientSnapshot.decode(json: json) else { return nil }
        let previous = latestSnapshot
        if let previous, previous.epoch != snapshot.epoch {
            // A new extension instance: rebind the sink and listener to it, then re-read.
            log.info("Extension restarted (epoch \(previous.epoch) -> \(snapshot.epoch)); rebinding")
            DispatchQueue.main.async { self.refreshDevice(force: true) }
            return snapshot
        }
        latestSnapshot = snapshot
        if previous == nil || !(previous!.hasSameRouting(as: snapshot)) {
            onSnapshot?(snapshot)
        }
        return snapshot
    }

    // MARK: Sink

    /// Every 5 s, restart the sink if it failed to start or the extension does not see it connected.
    private func retrySinkIfNeeded() {
        guard pollCount % 20 == 0 else { return }
        let failed = sinkStartStatus.map { $0 != noErr } ?? true
        let notConnected = latestSnapshot.map { !$0.sinkConnected } ?? false
        guard failed || notConnected else { return }
        log.info("Retrying sink start (status \(self.sinkStartStatus ?? 0), connected \(!notConnected))")
        stopSink()
        startSink()
    }

    private func startSink() {
        guard let deviceID, let sinkStreamID else { return }
        sinkStartAttempts += 1
        var queue: Unmanaged<CMSimpleQueue>?
        let copyStatus = CMIOStreamCopyBufferQueue(sinkStreamID, { _, _, _ in }, nil, &queue)
        guard copyStatus == noErr, let queue else {
            log.error("CMIOStreamCopyBufferQueue failed: \(copyStatus)")
            sinkStartStatus = copyStatus
            return
        }
        sinkLock.lock()
        sinkQueue = queue.takeRetainedValue()
        sinkLock.unlock()
        let startStatus = CMIODeviceStartStream(deviceID, sinkStreamID)
        sinkStartStatus = startStatus
        if startStatus != noErr {
            log.error("CMIODeviceStartStream(sink) failed: \(startStatus)")
        }
    }

    func stopSink() {
        if let deviceID, let sinkStreamID {
            CMIODeviceStopStream(deviceID, sinkStreamID)
        }
        sinkLock.lock()
        sinkQueue = nil
        sinkLock.unlock()
    }

    /// Thread-safe; called from the capture queue. Drops the frame if the queue is full.
    @discardableResult
    func enqueue(_ sampleBuffer: CMSampleBuffer) -> Bool {
        sinkLock.lock(); defer { sinkLock.unlock() }
        guard let sinkQueue else { return false }
        guard CMSimpleQueueGetCount(sinkQueue) < CMSimpleQueueGetCapacity(sinkQueue) else { return false }
        let pointer = Unmanaged.passRetained(sampleBuffer).toOpaque()
        if CMSimpleQueueEnqueue(sinkQueue, element: pointer) != noErr {
            Unmanaged<CMSampleBuffer>.fromOpaque(pointer).release()
            return false
        }
        return true
    }
}
