import CoreMediaIO
import CoreMedia
import CoreVideo
import Foundation
import IOKit.audio
import IOSurface
import OffSightCore
import os

/// The "OffSight Camera" device. Owns the frame gate, the client tracker and both streams.
///
/// Everything that touches the gate or decides what goes to meeting apps runs under `lock`, so a
/// client change (generation advance) and a frame send can never interleave (architecture §5.2).
final class DeviceSource: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!
    private var sourceStream: SourceStreamSource!
    private var sinkStream: SinkStreamSource!

    private let log = Logger(subsystem: OffSightConstants.logSubsystem, category: "device")
    private let lock = NSLock()
    private let formats: [VideoFormat]
    private var gate: FrameGate
    private var tracker = ClientTracker()
    private var activeFormatIndex = 0
    private var sourceStreaming = false
    private var timer: DispatchSourceTimer?
    private let timerQueue = DispatchQueue(label: "com.storiinnovations.offsight.extension.timer", qos: .userInteractive)
    private let sinkQueue = DispatchQueue(label: "com.storiinnovations.offsight.extension.sink", qos: .userInteractive)
    private var exitWatchers: [Int32: DispatchSourceProcess] = [:]

    private var sinkClient: CMIOExtensionClient?
    private var sinkAuthenticated = false
    private var sinkAuthMode = "none"
    private var sinkConsuming = false

    init(localizedName: String) {
        formats = OffSightConstants.formats.compactMap { VideoFormat(dimensions: $0) }
        gate = FrameGate(epoch: UInt64.random(in: 1...UInt64.max), activeFormat: formats[0].dimensions)
        super.init()

        device = CMIOExtensionDevice(localizedName: localizedName, deviceID: OffSightConstants.deviceUUID,
                                     legacyDeviceID: nil, source: self)
        let streamFormats = formats.map(\.streamFormat)
        sourceStream = SourceStreamSource(localizedName: OffSightConstants.sourceStreamName,
                                          streamID: OffSightConstants.sourceStreamUUID,
                                          streamFormats: streamFormats, device: self)
        sinkStream = SinkStreamSource(localizedName: OffSightConstants.sinkStreamName,
                                      streamID: OffSightConstants.sinkStreamUUID,
                                      streamFormats: streamFormats, device: self)
        do {
            try device.addStream(sourceStream.stream)
            try device.addStream(sinkStream.stream)
        } catch {
            log.fault("Failed to add streams: \(error.localizedDescription, privacy: .public)")
        }
        log.info("OffSight Camera ready, epoch \(self.gate.epoch)")
    }

    // MARK: CMIOExtensionDeviceSource

    var availableProperties: Set<CMIOExtensionProperty> {
        [.deviceTransportType, .deviceModel]
    }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let deviceProperties = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) {
            deviceProperties.transportType = kIOAudioDeviceTransportTypeVirtual
        }
        if properties.contains(.deviceModel) {
            deviceProperties.model = OffSightConstants.deviceModel
        }
        return deviceProperties
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    // MARK: Format

    var currentFormatIndex: Int {
        lock.lock(); defer { lock.unlock() }
        return activeFormatIndex
    }

    func setActiveFormatIndex(_ index: Int) {
        guard formats.indices.contains(index) else { return }
        lock.lock()
        let changed = index != activeFormatIndex
        activeFormatIndex = index
        if changed {
            gate.setActiveFormat(formats[index].dimensions)
        }
        lock.unlock()
        if changed {
            log.info("Active format -> \(self.formats[index].dimensions.description, privacy: .public)")
            publishSnapshot()
        }
    }

    // MARK: Meeting-app clients (source stream)

    func sourceClientStarting(_ client: CMIOExtensionClient) {
        lock.lock()
        tracker.clientStarting(clientID: client.clientID, pid: client.pid, signingID: client.signingID, now: Self.hostSeconds())
        gate.advanceGeneration()
        lock.unlock()
        log.info("Source start requested by pid=\(client.pid) signingID=\(client.signingID ?? "nil", privacy: .public)")
        watchForExit(pid: client.pid)
        publishSnapshot()
    }

    func startSourceStreaming() {
        lock.lock()
        tracker.streamStarted()
        sourceStreaming = true
        lock.unlock()
        startTimerIfNeeded()
    }

    func stopSourceStreaming() {
        lock.lock()
        tracker.streamStopped(now: Self.hostSeconds())
        gate.advanceGeneration()
        sourceStreaming = tracker.activeStreamCount > 0
        let stillStreaming = sourceStreaming
        lock.unlock()
        if !stillStreaming {
            stopTimer()
        }
        publishSnapshot()
    }

    func clientDisconnected(_ client: CMIOExtensionClient) {
        lock.lock()
        let wasTracked = tracker.records[client.clientID] != nil
        tracker.clientDisconnected(clientID: client.clientID)
        if wasTracked {
            gate.advanceGeneration()
        }
        if sinkClient?.clientID == client.clientID {
            sinkClient = nil
            sinkAuthenticated = false
            sinkConsuming = false
        }
        lock.unlock()
        if wasTracked {
            publishSnapshot()
        }
    }

    private func watchForExit(pid: Int32) {
        lock.lock(); defer { lock.unlock() }
        guard exitWatchers[pid] == nil else { return }
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: timerQueue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.tracker.processExited(pid: pid)
            self.gate.advanceGeneration()
            self.exitWatchers[pid]?.cancel()
            self.exitWatchers[pid] = nil
            self.lock.unlock()
            self.log.info("Client process \(pid) exited")
            self.publishSnapshot()
        }
        exitWatchers[pid] = source
        source.resume()
    }

    // MARK: Snapshot property

    func snapshotJSON() -> String {
        lock.lock(); defer { lock.unlock() }
        return ClientSnapshot(epoch: gate.epoch, generation: gate.generation,
                              activeFormat: formats[activeFormatIndex].dimensions,
                              clients: tracker.sortedRecords, stats: gate.stats,
                              sinkConnected: sinkClient != nil, sinkAuthMode: sinkAuthMode).encodedJSON()
    }

    private func publishSnapshot() {
        let state = CMIOExtensionPropertyState(value: snapshotJSON() as NSString)
        sourceStream.stream.notifyPropertiesChanged([SourceStreamSource.snapshotProperty: state])
    }

    // MARK: Output timer (placeholder + steady frame rate)

    private func startTimerIfNeeded() {
        lock.lock(); defer { lock.unlock() }
        guard timer == nil else { return }
        let newTimer = DispatchSource.makeTimerSource(flags: .strict, queue: timerQueue)
        newTimer.schedule(deadline: .now(), repeating: 1.0 / Double(OffSightConstants.frameRate), leeway: .milliseconds(2))
        newTimer.setEventHandler { [weak self] in self?.timerFired() }
        timer = newTimer
        newTimer.resume()
    }

    private func stopTimer() {
        lock.lock(); defer { lock.unlock() }
        timer?.cancel()
        timer = nil
    }

    private func timerFired() {
        lock.lock(); defer { lock.unlock() }
        guard sourceStreaming else { return }
        let now = Self.hostSeconds()
        guard gate.needsPlaceholderFrame(now: now) else { return }
        guard let sampleBuffer = formats[activeFormatIndex].makePlaceholderSampleBuffer() else { return }
        sourceStream.stream.send(sampleBuffer, discontinuity: [], hostTimeInNanoseconds: Self.hostNanoseconds())
    }

    // MARK: Sink (frames from OffSight.app)

    func authorizeSinkClient(_ client: CMIOExtensionClient) -> Bool {
        let result = SinkAuthenticator.authenticate(pid: client.pid, signingID: client.signingID)
        lock.lock()
        sinkAuthMode = result.mode
        if result.ok {
            sinkClient = client
            sinkAuthenticated = true
        } else {
            gate.noteUnauthenticatedSinkAttempt()
        }
        lock.unlock()
        if result.ok {
            log.info("Sink client accepted (pid=\(client.pid), mode=\(result.mode, privacy: .public))")
        } else {
            log.error("Sink client REJECTED (pid=\(client.pid), signingID=\(client.signingID ?? "nil", privacy: .public), mode=\(result.mode, privacy: .public))")
        }
        publishSnapshot()
        return result.ok
    }

    func startSink() {
        lock.lock()
        guard let client = sinkClient, sinkAuthenticated, !sinkConsuming else {
            lock.unlock()
            return
        }
        sinkConsuming = true
        lock.unlock()
        consumeNextSinkBuffer(from: client)
    }

    func stopSink() {
        lock.lock()
        sinkConsuming = false
        lock.unlock()
    }

    private func consumeNextSinkBuffer(from client: CMIOExtensionClient) {
        sinkStream.stream.consumeSampleBuffer(from: client) { [weak self] sampleBuffer, sequenceNumber, _, _, _ in
            guard let self else { return }
            if let sampleBuffer {
                self.handleSinkBuffer(sampleBuffer)
                let output = CMIOExtensionScheduledOutput(sequenceNumber: sequenceNumber,
                                                          hostTimeInNanoseconds: Self.hostNanoseconds())
                self.sinkStream.stream.notifyScheduledOutputChanged(output)
            }
            self.lock.lock()
            let keepGoing = self.sinkConsuming && self.sinkClient?.clientID == client.clientID
            self.lock.unlock()
            guard keepGoing else { return }
            if sampleBuffer != nil {
                self.sinkQueue.async { self.consumeNextSinkBuffer(from: client) }
            } else {
                self.sinkQueue.asyncAfter(deadline: .now() + .milliseconds(5)) { self.consumeNextSinkBuffer(from: client) }
            }
        }
    }

    private func handleSinkBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let dimensions = Dimensions(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        let tag = Self.readTag(from: pixelBuffer)

        lock.lock(); defer { lock.unlock() }
        let verdict = gate.evaluateLiveFrame(tag: tag, sinkAuthenticated: sinkAuthenticated,
                                             dimensions: dimensions, now: Self.hostSeconds())
        guard verdict == .forward, sourceStreaming else { return }
        sourceStream.stream.send(sampleBuffer, discontinuity: [], hostTimeInNanoseconds: Self.hostNanoseconds())
    }

    private static func readTag(from pixelBuffer: CVPixelBuffer) -> String? {
        guard let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else { return nil }
        guard let value = IOSurfaceCopyValue(surface, OffSightConstants.frameTagSurfaceKey as CFString) else { return nil }
        return value as? String
    }

    // MARK: Clock

    static func hostSeconds() -> TimeInterval {
        CMClockGetTime(CMClockGetHostTimeClock()).seconds
    }

    static func hostNanoseconds() -> UInt64 {
        UInt64(max(0, hostSeconds()) * Double(NSEC_PER_SEC))
    }
}
