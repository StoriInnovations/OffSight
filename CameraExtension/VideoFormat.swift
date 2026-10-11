import CoreGraphics
import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation
import ImageIO
import OffSightCore
import os

/// One output format plus its fallback placeholder (UR-25, UR-28).
///
/// Normally OffSight.app sends the placeholder through the sink, the path Photo Booth and Teams
/// display. This copy is the fallback for when the app sends nothing (not running, crashed). It is
/// rendered once and copied into a fresh pool buffer per frame, like frames from the sink.
final class VideoFormat {
    let dimensions: Dimensions
    let streamFormat: CMIOExtensionStreamFormat
    /// The description advertised to clients. Every frame sent is stamped with exactly this one:
    /// stricter clients (Photo Booth, Teams) drop frames whose description differs from it.
    let formatDescription: CMFormatDescription
    private let master: CVPixelBuffer
    private let pool: CVPixelBufferPool
    private static let log = Logger(subsystem: OffSightConstants.logSubsystem, category: "placeholder")

    init?(dimensions: Dimensions) {
        var description: CMFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCVPixelFormatType_32BGRA,
                                       width: Int32(dimensions.width), height: Int32(dimensions.height),
                                       extensions: nil, formatDescriptionOut: &description)
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, [kCVPixelBufferPoolMinimumBufferCountKey: 4] as CFDictionary,
                                PlaceholderRendering.bufferAttributes(dimensions) as CFDictionary, &pool)
        let artwork = PlaceholderLayout.artwork(for: dimensions)
        let image = Self.loadArtwork(artwork.resourceName)
        if image == nil {
            Self.log.fault("Placeholder artwork \(artwork.resourceName, privacy: .public) missing; using plain slate")
        }
        guard let description, let pool,
              let master = PlaceholderRendering.render(image, dimensions: dimensions) else { return nil }
        Self.log.notice("Fallback placeholder \(dimensions.description, privacy: .public): \(PlaceholderRendering.brightSamples(master)) of 4096 samples bright")

        let duration = CMTime(value: 1, timescale: OffSightConstants.frameRate)
        self.dimensions = dimensions
        self.formatDescription = description
        self.streamFormat = CMIOExtensionStreamFormat(formatDescription: description, maxFrameDuration: duration,
                                                      minFrameDuration: duration, validFrameDurations: nil)
        self.master = master
        self.pool = pool
    }

    /// Called on the extension's output timer, under the device lock.
    func makePlaceholderSampleBuffer() -> CMSampleBuffer? {
        var output: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &output) == kCVReturnSuccess,
              let output, PlaceholderRendering.copyPixels(from: master, to: output) else { return nil }
        return makeSampleBuffer(wrapping: output)
    }

    /// Wraps a frame (fallback placeholder or a frame from the sink) for sending, stamped with this
    /// format's advertised description and the current host time.
    func makeSampleBuffer(wrapping pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: OffSightConstants.frameRate),
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                                                        dataReady: true, makeDataReadyCallback: nil, refcon: nil,
                                                        formatDescription: formatDescription,
                                                        sampleTiming: &timing, sampleBufferOut: &sampleBuffer)
        return status == noErr ? sampleBuffer : nil
    }

    /// The brand PNGs are plain resources read with ImageIO: AppKit must not be used in a camera
    /// extension (it runs without a window-server session).
    private static func loadArtwork(_ name: String) -> CGImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
