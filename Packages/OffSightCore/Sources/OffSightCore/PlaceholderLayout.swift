import CoreGraphics
import Foundation

/// How the brand "Camera off" artwork is fitted to each output format (brand README, placeholder).
public enum PlaceholderLayout {
    public enum Artwork: Equatable, Sendable {
        /// `PlaceholderCameraOff`, 1920×1080.
        case wide16x9
        /// `PlaceholderCameraOff4x3`, 1440×1080.
        case standard4x3

        /// Imageset name in the app's asset catalog.
        public var assetName: String {
            switch self {
            case .wide16x9: return "PlaceholderCameraOff"
            case .standard4x3: return "PlaceholderCameraOff4x3"
            }
        }

        /// Plain PNG resource (without extension) bundled in the camera extension, which reads it
        /// with ImageIO because AppKit cannot be used there.
        public var resourceName: String {
            switch self {
            case .wide16x9: return "placeholder-camera-off-16x9"
            case .standard4x3: return "placeholder-camera-off-4x3"
            }
        }
    }

    /// 4:3 formats use the 4:3 artwork; everything else uses the 16:9 frame.
    public static func artwork(for format: Dimensions) -> Artwork {
        guard format.height > 0 else { return .wide16x9 }
        let aspect = Double(format.width) / Double(format.height)
        return abs(aspect - 4.0 / 3.0) < 0.01 ? .standard4x3 : .wide16x9
    }

    /// Rectangle to draw an image of `source` size into so it fills `target` exactly,
    /// keeping its aspect ratio and centred (aspect-fill: overflow is cropped, never stretched).
    public static func aspectFillRect(source: CGSize, target: Dimensions) -> CGRect {
        let targetWidth = CGFloat(target.width)
        let targetHeight = CGFloat(target.height)
        guard source.width > 0, source.height > 0 else {
            return CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight)
        }
        let scale = max(targetWidth / source.width, targetHeight / source.height)
        let width = source.width * scale
        let height = source.height * scale
        return CGRect(x: (targetWidth - width) / 2, y: (targetHeight - height) / 2, width: width, height: height)
    }
}

import CoreVideo

/// Renders the "Camera off" frame into BGRA pixel buffers. Shared by OffSight.app (which sends the
/// placeholder through the sink) and the camera extension (fallback when the app sends nothing).
public enum PlaceholderRendering {
    /// Pixel buffer attributes matching the frames the app sends through the sink.
    public static func bufferAttributes(_ dimensions: Dimensions) -> [CFString: Any] {
        [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: dimensions.width,
            kCVPixelBufferHeightKey: dimensions.height,
            kCVPixelBufferIOSurfacePropertiesKey: [String: Any]() as CFDictionary,
        ]
    }

    /// Brand slate, filled underneath so nothing else can ever show through.
    public static let slate = CGColor(srgbRed: 0x1C / 255.0, green: 0x21 / 255.0, blue: 0x29 / 255.0, alpha: 1)

    /// Draws `image` aspect-filled and centred (never stretched or mirrored) over the slate.
    /// A nil image yields a plain slate frame.
    public static func render(_ image: CGImage?, dimensions: Dimensions) -> CVPixelBuffer? {
        var attributes = bufferAttributes(dimensions)
        attributes[kCVPixelBufferCGBitmapContextCompatibilityKey] = true
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
        context.setFillColor(slate)
        context.fill(CGRect(x: 0, y: 0, width: dimensions.width, height: dimensions.height))
        if let image {
            context.interpolationQuality = .high
            context.draw(image, in: PlaceholderLayout.aspectFillRect(
                source: CGSize(width: image.width, height: image.height), target: dimensions))
        }
        context.flush()
        return buffer
    }

    /// Row-by-row copy (row strides can differ between buffers).
    @discardableResult
    public static func copyPixels(from source: CVPixelBuffer, to destination: CVPixelBuffer) -> Bool {
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        guard let from = CVPixelBufferGetBaseAddress(source), let to = CVPixelBufferGetBaseAddress(destination) else {
            return false
        }
        let fromStride = CVPixelBufferGetBytesPerRow(source)
        let toStride = CVPixelBufferGetBytesPerRow(destination)
        let rowBytes = min(fromStride, toStride, CVPixelBufferGetWidth(source) * 4)
        let rows = min(CVPixelBufferGetHeight(source), CVPixelBufferGetHeight(destination))
        for row in 0..<rows {
            memcpy(to + row * toStride, from + row * fromStride, rowBytes)
        }
        return true
    }

    /// Bright pixels on a 64×64 grid: confirms the light mark and text actually landed in a frame.
    public static func brightSamples(_ buffer: CVPixelBuffer) -> Int {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return -1 }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        var bright = 0
        for gy in 0..<64 {
            for gx in 0..<64 {
                let offset = (gy * height / 64) * bytesPerRow + (gx * width / 64) * 4 // BGRA
                let luma = (Int(pixels[offset + 2]) * 3 + Int(pixels[offset + 1]) * 6 + Int(pixels[offset])) / 10
                if luma > 110 { bright += 1 }
            }
        }
        return bright
    }
}
