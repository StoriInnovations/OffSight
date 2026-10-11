import CoreGraphics
import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation
import ImageIO
import OffSightCore
import os

/// One output format plus its pre-rendered placeholder frames (UR-25, UR-28).
///
/// The placeholder is rendered once per format and cached, as a small ring of identical buffers
/// sent in turn: some clients keep the previous frame's buffer and may ignore a frame that reuses it.
final class VideoFormat {
    private static let ringSize = 3

    let dimensions: Dimensions
    let streamFormat: CMIOExtensionStreamFormat
    /// The description advertised to clients. Every frame sent is stamped with exactly this one:
    /// stricter clients (Photo Booth, Teams) drop frames whose description differs from it.
    let formatDescription: CMFormatDescription
    private let placeholders: [CVPixelBuffer]
    private var nextPlaceholder = 0

    init?(dimensions: Dimensions) {
        var description: CMFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCVPixelFormatType_32BGRA,
                                       width: Int32(dimensions.width), height: Int32(dimensions.height),
                                       extensions: nil, formatDescriptionOut: &description)
        let placeholders = (0..<Self.ringSize).compactMap { _ in PlaceholderRenderer.render(dimensions) }
        guard let description, placeholders.count == Self.ringSize else { return nil }

        let duration = CMTime(value: 1, timescale: OffSightConstants.frameRate)
        self.dimensions = dimensions
        self.formatDescription = description
        self.streamFormat = CMIOExtensionStreamFormat(formatDescription: description, maxFrameDuration: duration,
                                                      minFrameDuration: duration, validFrameDurations: nil)
        self.placeholders = placeholders
    }

    /// Called on the extension's output timer, under the device lock.
    func makePlaceholderSampleBuffer() -> CMSampleBuffer? {
        let buffer = placeholders[nextPlaceholder]
        nextPlaceholder = (nextPlaceholder + 1) % placeholders.count
        return makeSampleBuffer(wrapping: buffer)
    }

    /// Wraps a frame (placeholder or a live frame from the sink) for sending, stamped with this
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
}

/// Produces the "Camera off" frame from the brand artwork bundled with this extension
/// (16:9 1920×1080 and 4:3 1440×1080 PNGs from the handoff). AppKit must not be used in a camera
/// extension (it runs without a window-server session), so the PNGs are plain resources read with
/// ImageIO rather than an asset catalog. It lives in the
/// extension so a correct placeholder exists even if OffSight.app has never run or has crashed
/// (UR-04). Each format is rendered once and cached by `VideoFormat`. The frame is never mirrored.
enum PlaceholderRenderer {
    private static let log = Logger(subsystem: OffSightConstants.logSubsystem, category: "placeholder")

    static func render(_ dimensions: Dimensions) -> CVPixelBuffer? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: dimensions.width,
            kCVPixelBufferHeightKey: dimensions.height,
            kCVPixelBufferIOSurfacePropertiesKey: [String: Any]() as CFDictionary,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, dimensions.width, dimensions.height, kCVPixelFormatType_32BGRA,
                                  attributes as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer),
                                      width: dimensions.width, height: dimensions.height, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }

        // Brand slate underneath, so nothing but the placeholder can ever show through.
        context.setFillColor(CGColor(srgbRed: 0x1C / 255.0, green: 0x21 / 255.0, blue: 0x29 / 255.0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: dimensions.width, height: dimensions.height))

        let artwork = PlaceholderLayout.artwork(for: dimensions)
        guard let image = artworkImage(artwork.resourceName) else {
            log.fault("Placeholder artwork \(artwork.resourceName, privacy: .public) missing; sending plain slate frame")
            return buffer
        }
        context.interpolationQuality = .high
        let rect = PlaceholderLayout.aspectFillRect(source: CGSize(width: image.width, height: image.height),
                                                    target: dimensions)
        context.draw(image, in: rect)
        context.flush()
        log.info("Placeholder \(dimensions.description, privacy: .public) from \(artwork.resourceName, privacy: .public): \(brightSamples(buffer, dimensions)) of 4096 samples bright (mark and text)")
        return buffer
    }

    /// Counts bright pixels on a 64×64 grid of the rendered frame, to confirm in the log that the
    /// artwork (light mark and text on dark slate) actually landed in the buffer.
    private static func brightSamples(_ buffer: CVPixelBuffer, _ dimensions: Dimensions) -> Int {
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return -1 }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        var bright = 0
        for gy in 0..<64 {
            for gx in 0..<64 {
                let x = (gx * dimensions.width) / 64
                let y = (gy * dimensions.height) / 64
                let offset = y * bytesPerRow + x * 4 // BGRA
                let luma = (Int(pixels[offset + 2]) * 3 + Int(pixels[offset + 1]) * 6 + Int(pixels[offset])) / 10
                if luma > 110 { bright += 1 }
            }
        }
        return bright
    }

    private static func artworkImage(_ name: String) -> CGImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
