import AppKit
import CoreGraphics
import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation
import OffSightCore
import os

/// One output format plus its pre-rendered built-in placeholder (UR-25, UR-28).
struct VideoFormat {
    let dimensions: Dimensions
    let streamFormat: CMIOExtensionStreamFormat
    private let placeholder: CVPixelBuffer
    private let placeholderDescription: CMFormatDescription

    init?(dimensions: Dimensions) {
        var description: CMFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCVPixelFormatType_32BGRA,
                                       width: Int32(dimensions.width), height: Int32(dimensions.height),
                                       extensions: nil, formatDescriptionOut: &description)
        guard let description, let placeholder = PlaceholderRenderer.render(dimensions) else { return nil }

        var bufferDescription: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: placeholder,
                                                     formatDescriptionOut: &bufferDescription)
        guard let bufferDescription else { return nil }

        let duration = CMTime(value: 1, timescale: OffSightConstants.frameRate)
        self.dimensions = dimensions
        self.streamFormat = CMIOExtensionStreamFormat(formatDescription: description, maxFrameDuration: duration,
                                                      minFrameDuration: duration, validFrameDurations: nil)
        self.placeholder = placeholder
        self.placeholderDescription = bufferDescription
    }

    func makePlaceholderSampleBuffer() -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: OffSightConstants.frameRate),
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: placeholder,
                                                        dataReady: true, makeDataReadyCallback: nil, refcon: nil,
                                                        formatDescription: placeholderDescription,
                                                        sampleTiming: &timing, sampleBufferOut: &sampleBuffer)
        return status == noErr ? sampleBuffer : nil
    }
}

/// Produces the "Camera off" frame from the brand artwork in this extension's asset catalog
/// (`PlaceholderCameraOff` 1920×1080, `PlaceholderCameraOff4x3` 1440×1080). It lives in the
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
        guard let image = artworkImage(artwork.assetName) else {
            log.fault("Placeholder artwork \(artwork.assetName, privacy: .public) missing; sending plain slate frame")
            return buffer
        }
        context.interpolationQuality = .high
        let rect = PlaceholderLayout.aspectFillRect(source: CGSize(width: image.width, height: image.height),
                                                    target: dimensions)
        context.draw(image, in: rect)
        log.info("Placeholder \(dimensions.description, privacy: .public) from \(artwork.assetName, privacy: .public)")
        return buffer
    }

    private static func artworkImage(_ name: String) -> CGImage? {
        guard let image = NSImage(named: name) else { return nil }
        var rect = CGRect(origin: .zero, size: image.size)
        // Prefer the full-resolution bitmap rather than a point-sized rendering.
        if let bitmap = image.representations.compactMap({ $0 as? NSBitmapImageRep }).max(by: { $0.pixelsWide < $1.pixelsWide }),
           let cgImage = bitmap.cgImage {
            return cgImage
        }
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}
