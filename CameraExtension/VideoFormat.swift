import CoreGraphics
import CoreMedia
import CoreMediaIO
import CoreText
import CoreVideo
import Foundation
import OffSightCore

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

/// Draws the built-in "Camera off" placeholder. It lives in the extension so a correct
/// placeholder exists even if OffSight.app has never run or has crashed (UR-04).
enum PlaceholderRenderer {
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
        draw(in: context, width: CGFloat(dimensions.width), height: CGFloat(dimensions.height))
        return buffer
    }

    private static func draw(in context: CGContext, width: CGFloat, height: CGFloat) {
        // Background
        context.setFillColor(CGColor(srgbRed: 0.11, green: 0.13, blue: 0.17, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let unit = height / 720
        let iconColor = CGColor(srgbRed: 0.85, green: 0.87, blue: 0.90, alpha: 1)

        // Camera icon with a slash, centred a little above the middle.
        let bodySize = CGSize(width: 150 * unit, height: 100 * unit)
        let lensWidth = 55 * unit
        let totalWidth = bodySize.width + 12 * unit + lensWidth
        let originX = (width - totalWidth) / 2
        let originY = height / 2 + 30 * unit
        let body = CGRect(x: originX, y: originY, width: bodySize.width, height: bodySize.height)
        context.setFillColor(iconColor)
        context.addPath(CGPath(roundedRect: body, cornerWidth: 18 * unit, cornerHeight: 18 * unit, transform: nil))
        context.fillPath()
        let lensX = body.maxX + 12 * unit
        context.move(to: CGPoint(x: lensX, y: body.midY))
        context.addLine(to: CGPoint(x: lensX + lensWidth, y: body.maxY - 8 * unit))
        context.addLine(to: CGPoint(x: lensX + lensWidth, y: body.minY + 8 * unit))
        context.closePath()
        context.fillPath()

        // Slash: background-coloured gap, then the light stroke.
        let slashStart = CGPoint(x: originX - 10 * unit, y: originY - 25 * unit)
        let slashEnd = CGPoint(x: originX + totalWidth + 10 * unit, y: originY + bodySize.height + 25 * unit)
        context.setLineCap(.round)
        context.setStrokeColor(CGColor(srgbRed: 0.11, green: 0.13, blue: 0.17, alpha: 1))
        context.setLineWidth(26 * unit)
        context.move(to: slashStart)
        context.addLine(to: slashEnd)
        context.strokePath()
        context.setStrokeColor(iconColor)
        context.setLineWidth(12 * unit)
        context.move(to: slashStart)
        context.addLine(to: slashEnd)
        context.strokePath()

        drawCenteredText("Camera off", in: context, width: width, baselineY: height / 2 - 60 * unit,
                         size: 56 * unit, color: CGColor(srgbRed: 0.95, green: 0.96, blue: 0.97, alpha: 1), bold: true)
        drawCenteredText("Protected by OffSight", in: context, width: width, baselineY: height / 2 - 115 * unit,
                         size: 28 * unit, color: CGColor(srgbRed: 0.62, green: 0.66, blue: 0.72, alpha: 1), bold: false)
    }

    private static func drawCenteredText(_ text: String, in context: CGContext, width: CGFloat, baselineY: CGFloat,
                                         size: CGFloat, color: CGColor, bold: Bool) {
        let baseFont = CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): baseFont,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        context.textPosition = CGPoint(x: (width - bounds.width) / 2 - bounds.minX, y: baselineY)
        CTLineDraw(line, context)
    }
}
