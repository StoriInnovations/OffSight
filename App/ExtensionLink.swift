import CoreMedia
import CoreMediaIO
import Foundation
import OffSightCore
import os

/// Finds OffSight Camera, reads its client snapshot and pushes frames into its sink stream.
final class ExtensionLink {
    /// Called on the main queue whenever the routing-relevant part of the snapshot changes.
    var onSnapshot: ((ClientSnapshot) -> Void)?

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
            } else {
                self.readSnapshot()
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

    func refreshDevice() {
        let found = CMIO.devices().first { device in
            CMIO.deviceUID(of: device) == OffSightConstants.deviceUUID.uuidString
                || CMIO.name(of: device) == OffSightConstants.deviceName
        }
        guard found != deviceID else { return }

        stopSink()
        deviceID = found
        sourceStreamID = nil
        sinkStreamID = nil
        guard let found else {
            log.info("OffSight Camera not present")
            return
        }

        for stream in CMIO.streams(of: found) {
            switch CMIO.name(of: stream) {
            case OffSightConstants.sourceStreamName?: sourceStreamID = stream
            case OffSightConstants.sinkStreamName?: sinkStreamID = stream
            default: break
            }
        }
        log.info("OffSight Camera found: device \(found), source \(self.sourceStreamID ?? 0), sink \(self.sinkStreamID ?? 0)")

        if let sourceStreamID {
            var address = CMIO.address(snapshotSelector)
            CMIOObjectAddPropertyListenerBlock(sourceStreamID, &address, DispatchQueue.main) { [weak self] _, _ in
                self?.listenerCallbacks += 1
                self?.readSnapshot()
            }
        }
        startSink()
        readSnapshot()
    }

    // MARK: Snapshot

    @discardableResult
    func readSnapshot() -> ClientSnapshot? {
        guard let sourceStreamID,
              let json = CMIO.string(of: sourceStreamID, selector: snapshotSelector),
              let snapshot = ClientSnapshot.decode(json: json) else { return nil }
        let previous = latestSnapshot
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
