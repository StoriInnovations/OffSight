import AppKit
import CoreMedia
import CoreVideo
import Foundation
import IOSurface
import OffSightCore
import os
import VideoToolbox

/// Sends frames into the extension's sink (architecture §5.2):
/// - approved live frames, scaled to the active format and tagged with the epoch/generation the
///   approval decision was made for;
/// - otherwise, while any app uses OffSight Camera, the placeholder at 30 fps: the user's own image
///   (UR-26) or the built-in artwork. Photo Booth
///   and Teams display frames arriving this way, but not frames the extension generates itself.
final class SinkFeeder {
    struct Config: Equatable {
        var sendLive: Bool
        var sendPlaceholder: Bool
        var epoch: UInt64
        var generation: UInt64
        var format: Dimensions
    }

    private let link: ExtensionLink
    private let log = Logger(subsystem: OffSightConstants.logSubsystem, category: "feeder")
    private let lock = NSLock()
    private var config: Config?
    private var transferSession: VTPixelTransferSession?
    private var livePool: PoolCache
    private var placeholderPool: PoolCache
    private var placeholderMasters: [Dimensions: CVPixelBuffer] = [:]
    private var placeholderChoice = ""
    /// What the last rendered placeholder contains (diagnostics).
    private(set) var placeholderDescription = "not rendered yet"
    private var placeholderTimer: DispatchSourceTimer?
    /// Used only on the placeholder queue (transfer sessions are not shared across queues).
    private var placeholderTransfer: VTPixelTransferSession?
    private var placeholderFrameCounter: UInt64 = 0
    private let placeholderQueue = DispatchQueue(label: "com.storiinnovations.offsight.placeholder", qos: .userInteractive)
    private(set) var framesSent: UInt64 = 0
    private(set) var framesDropped: UInt64 = 0
    private(set) var placeholderFramesSent: UInt64 = 0

    init(link: ExtensionLink) {
        self.link = link
        livePool = PoolCache()
        placeholderPool = PoolCache()
        var session: VTPixelTransferSession?
        if VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &session) == noErr,
           let session {
            VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Letterbox)
            transferSession = session
        }
        var placeholderSession: VTPixelTransferSession?
        if VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &placeholderSession) == noErr {
            placeholderTransfer = placeholderSession
        }
    }

    /// Main thread.
    func update(_ newConfig: Config?) {
        lock.lock()
        config = newConfig
        lock.unlock()
        let wantPlaceholder = newConfig?.sendPlaceholder == true
        if wantPlaceholder, placeholderTimer == nil {
            let timer = DispatchSource.makeTimerSource(flags: .strict, queue: placeholderQueue)
            timer.schedule(deadline: .now(), repeating: 1.0 / Double(OffSightConstants.frameRate), leeway: .milliseconds(2))
            timer.setEventHandler { [weak self] in self?.sendPlaceholderFrame() }
            placeholderTimer = timer
            timer.resume()
        } else if !wantPlaceholder, let timer = placeholderTimer {
            timer.cancel()
            placeholderTimer = nil
        }
    }

    // MARK: Live

    /// Called on the capture queue for each camera frame.
    func handle(_ cameraFrame: CVPixelBuffer) {
        lock.lock()
        let current = config
        lock.unlock()
        // Gate 1: the app never sends live frames unless the policy says so.
        guard let current, current.sendLive, let transferSession else { return }
        guard let output = livePool.buffer(for: current.format) else { return }
        guard VTPixelTransferSessionTransferImage(transferSession, from: cameraFrame, to: output) == noErr else { return }
        // Plain BGRA like the extension's advertised format: drop colour attachments copied from
        // the camera frame so the extension can stamp the frame with its own format description.
        CVBufferRemoveAllAttachments(output)
        send(output, tag: FrameTag(kind: .live, epoch: current.epoch, generation: current.generation)) { sent in
            if sent { self.framesSent += 1 } else { self.framesDropped += 1 }
        }
    }

    // MARK: Placeholder

    /// Placeholder queue, 30 fps while needed. Never touches camera frames.
    ///
    /// Produced exactly like a live frame (hardware transfer into a fresh pool buffer, attachments
    /// removed), and each frame differs from the last by one invisible pixel, so no consumer can
    /// mistake the stream for a stalled camera. (Photo Booth and Teams once showed grey here; the
    /// cause was macOS video effects, avoided by OffSight Camera's size, see `effectsFreeFormat`.)
    private func sendPlaceholderFrame() {
        lock.lock()
        let current = config
        lock.unlock()
        guard let current, current.sendPlaceholder, !current.sendLive else { return }
        guard let master = placeholderMaster(for: current.format),
              let output = placeholderPool.buffer(for: current.format) else { return }
        if let placeholderTransfer,
           VTPixelTransferSessionTransferImage(placeholderTransfer, from: master, to: output) == noErr {
            // Same path as live frames.
        } else if !PlaceholderRendering.copyPixels(from: master, to: output) {
            return
        }
        CVBufferRemoveAllAttachments(output)
        placeholderFrameCounter &+= 1
        Self.nudgeCornerPixel(output, frame: placeholderFrameCounter)
        send(output, tag: FrameTag(kind: .placeholder, epoch: current.epoch, generation: current.generation)) { sent in
            if sent { self.placeholderFramesSent += 1 }
        }
    }

    /// Alternates the blue value of the bottom-right pixel by one step: imperceptible, but every
    /// frame is different.
    private static func nudgeCornerPixel(_ buffer: CVPixelBuffer, frame: UInt64) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let offset = (CVPixelBufferGetHeight(buffer) - 1) * CVPixelBufferGetBytesPerRow(buffer)
            + (CVPixelBufferGetWidth(buffer) - 1) * 4 // BGRA: blue first
        let pixel = base.assumingMemoryBound(to: UInt8.self) + offset
        pixel.pointee = (pixel.pointee & 0xFE) | UInt8(frame & 1)
    }

    /// Placeholder queue only. Rendered once per format and placeholder choice.
    private func placeholderMaster(for format: Dimensions) -> CVPixelBuffer? {
        let choice = PlaceholderImageStore.cacheKey
        if choice != placeholderChoice {
            // The user changed the placeholder: drop renderings of the old one.
            placeholderMasters.removeAll()
            placeholderChoice = choice
        }
        if let cached = placeholderMasters[format] { return cached }
        let image: CGImage?
        let source: String
        if let content = PlaceholderImageStore.content(for: format) {
            image = content.image
            source = content.source
        } else {
            let artwork = PlaceholderLayout.artwork(for: format)
            image = Self.cgImage(named: artwork.assetName)
            source = image == nil ? "MISSING \(artwork.assetName)" : artwork.assetName
        }
        guard let master = PlaceholderRendering.render(image, dimensions: format) else { return nil }
        placeholderMasters[format] = master
        let bright = PlaceholderRendering.brightSamples(master)
        placeholderDescription = "\(format.description) from \(source), \(bright) of 4096 samples bright"
        log.notice("Placeholder \(self.placeholderDescription, privacy: .public)")
        return master
    }

    /// The full-resolution bitmap of an imageset in the app's asset catalog.
    private static func cgImage(named name: String) -> CGImage? {
        guard let image = NSImage(named: name) else { return nil }
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    // MARK: Format

    /// Asks the extension to advertise `format` (the live camera's native size). The request is a
    /// plain slate frame of that size tagged as a format request; it is never shown to anyone.
    func requestFormat(_ format: Dimensions, epoch: UInt64) {
        placeholderQueue.async { [self] in
            guard let frame = PlaceholderRendering.render(nil, dimensions: format) else { return }
            send(frame, tag: FrameTag(kind: .formatRequest, epoch: epoch, generation: 0)) { _ in }
            log.info("Requested camera format \(format.description, privacy: .public)")
        }
    }

    // MARK: Sending

    private func send(_ pixelBuffer: CVPixelBuffer, tag: FrameTag, completion: (Bool) -> Void) {
        guard let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else { return }
        IOSurfaceSetValue(surface, OffSightConstants.frameTagSurfaceKey as CFString, tag.encoded as CFString)
        guard let sampleBuffer = Self.makeSampleBuffer(pixelBuffer) else { return }
        completion(link.enqueue(sampleBuffer))
    }

    private static func makeSampleBuffer(_ pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        var description: CMFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                                                           formatDescriptionOut: &description) == noErr,
              let description else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: OffSightConstants.frameRate),
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                                                       formatDescription: description, sampleTiming: &timing,
                                                       sampleBufferOut: &sampleBuffer) == noErr else { return nil }
        return sampleBuffer
    }
}

/// A pixel buffer pool for one format at a time, recreated when the format changes.
private final class PoolCache {
    private var pool: CVPixelBufferPool?
    private var format: Dimensions?
    private let lock = NSLock()

    func buffer(for wanted: Dimensions) -> CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }
        if format != wanted || pool == nil {
            var newPool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil,
                                    PlaceholderRendering.bufferAttributes(wanted) as CFDictionary, &newPool)
            pool = newPool
            format = wanted
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        return buffer
    }
}
