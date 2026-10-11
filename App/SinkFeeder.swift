import CoreMedia
import CoreVideo
import Foundation
import IOSurface
import OffSightCore
import os
import VideoToolbox

/// Sends approved live frames to the extension's sink, scaled to the active format and tagged
/// with the epoch/generation the approval decision was made for (architecture §5.2).
final class SinkFeeder {
    struct Config: Equatable {
        var sendLive: Bool
        var epoch: UInt64
        var generation: UInt64
        var format: Dimensions
    }

    private let link: ExtensionLink
    private let log = Logger(subsystem: OffSightConstants.logSubsystem, category: "feeder")
    private let lock = NSLock()
    private var config: Config?
    private var transferSession: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?
    private var poolFormat: Dimensions?
    private(set) var framesSent: UInt64 = 0
    private(set) var framesDropped: UInt64 = 0

    init(link: ExtensionLink) {
        self.link = link
        var session: VTPixelTransferSession?
        if VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &session) == noErr,
           let session {
            VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Letterbox)
            transferSession = session
        }
    }

    func update(_ newConfig: Config?) {
        lock.lock(); defer { lock.unlock() }
        config = newConfig
    }

    /// Called on the capture queue for each camera frame.
    func handle(_ cameraFrame: CVPixelBuffer) {
        lock.lock()
        let current = config
        lock.unlock()
        // Gate 1: the app never sends live frames unless the policy says so.
        guard let current, current.sendLive, let transferSession else { return }
        guard let output = makeOutputBuffer(for: current.format) else { return }
        guard VTPixelTransferSessionTransferImage(transferSession, from: cameraFrame, to: output) == noErr else { return }

        guard let surface = CVPixelBufferGetIOSurface(output)?.takeUnretainedValue() else { return }
        let tag = FrameTag(epoch: current.epoch, generation: current.generation).encoded
        IOSurfaceSetValue(surface, OffSightConstants.frameTagSurfaceKey as CFString, tag as CFString)

        guard let sampleBuffer = Self.makeSampleBuffer(output) else { return }
        if link.enqueue(sampleBuffer) {
            framesSent += 1
        } else {
            framesDropped += 1
        }
    }

    private func makeOutputBuffer(for format: Dimensions) -> CVPixelBuffer? {
        if poolFormat != format || pool == nil {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: format.width,
                kCVPixelBufferHeightKey: format.height,
                kCVPixelBufferIOSurfacePropertiesKey: [String: Any]() as CFDictionary,
            ]
            var newPool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &newPool)
            pool = newPool
            poolFormat = format
            log.info("Output pool \(format.description, privacy: .public)")
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        return buffer
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
