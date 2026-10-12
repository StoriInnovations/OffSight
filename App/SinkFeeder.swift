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
    /// Debug test patterns for diagnosing apps that do not display the placeholder.
    enum PlaceholderStyle: String, CaseIterable {
        case brand = "Placeholder (as chosen in Settings)"
        case brandWithMovingBar = "Placeholder + moving bar"
        case brightGrey = "Bright grey (static)"
        /// The artwork with faint film grain: still dark, no longer flat.
        case fineGrain = "Placeholder + fine grain (dark, textured)"
        /// The artwork with its levels lifted: bright, still flat.
        case brightened = "Placeholder, brightened (light, flat)"
    }

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
    private var placeholderMasters: [String: CVPixelBuffer] = [:]
    private var placeholderRevision = -1
    /// What the last rendered placeholder contains (diagnostics).
    private(set) var placeholderDescription = "not rendered yet"
    private var placeholderTimer: DispatchSourceTimer?
    /// Used only on the placeholder queue (transfer sessions are not shared across queues).
    private var placeholderTransfer: VTPixelTransferSession?
    private var placeholderFrameCounter: UInt64 = 0
    private var style: PlaceholderStyle = .brand

    var placeholderStyle: PlaceholderStyle {
        get { lock.lock(); defer { lock.unlock() }; return style }
        set { lock.lock(); style = newValue; lock.unlock() }
    }
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
    /// removed), and each frame differs from the last by one invisible pixel: Photo Booth and Teams
    /// show nothing for a stream of byte-identical frames, as if the camera had stalled.
    private func sendPlaceholderFrame() {
        lock.lock()
        let current = config
        lock.unlock()
        let style = placeholderStyle
        guard let current, current.sendPlaceholder, !current.sendLive else { return }
        guard let master = placeholderMaster(for: current.format, style: style),
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
        if style == .brandWithMovingBar {
            Self.drawMovingBar(output, frame: placeholderFrameCounter)
        }
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

    /// A bright vertical bar sweeping across the frame (debug test pattern).
    private static func drawMovingBar(_ buffer: CVPixelBuffer, frame: UInt64) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let barWidth = max(8, width / 40)
        let x0 = Int((frame * 12) % UInt64(max(1, width - barWidth)))
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            memset(pixels + y * bytesPerRow + x0 * 4, 0xFF, barWidth * 4)
        }
    }

    /// Placeholder queue only. Rendered once per format, test pattern and placeholder choice.
    private func placeholderMaster(for format: Dimensions, style: PlaceholderStyle) -> CVPixelBuffer? {
        let revision = PlaceholderImageStore.revision
        if revision != placeholderRevision {
            // The user picked another image: drop renderings of the old one.
            placeholderMasters.removeAll()
            placeholderRevision = revision
        }
        let variant: String
        switch style {
        case .brightGrey: variant = "grey"
        case .fineGrain: variant = "grain"
        case .brightened: variant = "bright"
        case .brand, .brandWithMovingBar: variant = "image"
        }
        let key = "\(format.description)|\(variant)"
        if let cached = placeholderMasters[key] { return cached }
        let image: CGImage?
        let source: String
        if style == .brightGrey {
            image = Self.solidImage(grey: 0.5)
            source = "solid grey"
        } else if style != .fineGrain, style != .brightened, let custom = PlaceholderImageStore.loadImage() {
            // (The grain and brightened test patterns always start from the built-in artwork.)
            image = custom
            source = "custom image \(custom.width)x\(custom.height)"
        } else {
            let artwork = PlaceholderLayout.artwork(for: format)
            image = Self.cgImage(named: artwork.assetName)
            source = image == nil ? "MISSING \(artwork.assetName)" : artwork.assetName
        }
        guard let master = PlaceholderRendering.render(image, dimensions: format) else { return nil }
        switch style {
        case .fineGrain: Self.adjustPixels(master) { value, noise in value + Int(noise % 13) - 6 }
        case .brightened: Self.adjustPixels(master) { value, _ in 128 + value / 2 }
        default: break
        }
        placeholderMasters[key] = master
        let bright = PlaceholderRendering.brightSamples(master)
        placeholderDescription = "\(format.description) from \(source) (\(variant)), \(bright) of 4096 samples bright"
        log.notice("Placeholder \(self.placeholderDescription, privacy: .public)")
        return master
    }

    /// Applies `transform(value, noise)` to the colour channels of every pixel (debug test patterns).
    private static func adjustPixels(_ buffer: CVPixelBuffer, _ transform: (Int, UInt32) -> Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        var seed: UInt32 = 0x9E37_79B9
        for y in 0..<height {
            let row = pixels + y * bytesPerRow
            for x in 0..<width {
                seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5 // xorshift
                for channel in 0..<3 { // BGRA: leave alpha alone
                    let value = transform(Int(row[x * 4 + channel]), seed >> (channel * 8))
                    row[x * 4 + channel] = UInt8(clamping: value)
                }
            }
        }
    }

    private static func solidImage(grey: CGFloat) -> CGImage? {
        guard let context = CGContext(data: nil, width: 16, height: 9, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: grey, green: grey, blue: grey, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 9))
        return context.makeImage()
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
