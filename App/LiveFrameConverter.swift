import Accelerate
import CoreVideo
import Foundation
import OffSightCore

/// Copies camera frames into OffSight Camera's BGRA buffers, converting (420v) and scaling on the
/// CPU when a frame isn't already BGRA at the right size. A frame of another shape (the camera
/// changed modes mid-call) is centre-cropped to OffSight Camera's shape, never stretched.
/// Capture queue only.
///
/// Deliberately not VideoToolbox: running camera frames through a `VTPixelTransferSession` made
/// macOS stop applying the video effects chosen for OffSight (Background, Portrait…) to every
/// frame in the process, preview included, until OffSight quit (B2).
final class CPUFrameConverter {
    private var conversion = vImage_YpCbCrToARGB()
    private var conversionReady = false
    private var intermediate = vImage_Buffer()
    private var intermediateSize: (width: Int, height: Int) = (0, 0)

    deinit {
        free(intermediate.data)
    }

    /// Writes `source` (420v or BGRA) into `destination` (BGRA), scaled to its size.
    func convert(_ source: CVPixelBuffer, into destination: CVPixelBuffer) -> Bool {
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        guard var output = Self.buffer(destination) else { return false }
        switch CVPixelBufferGetPixelFormatType(source) {
        case kCVPixelFormatType_32BGRA:
            guard var input = Self.buffer(source) else { return false }
            return Self.copyOrScale(&input, into: &output)
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            guard prepareConversion(), var bgra = intermediateBuffer(for: source),
                  let lumaBase = CVPixelBufferGetBaseAddressOfPlane(source, 0),
                  let chromaBase = CVPixelBufferGetBaseAddressOfPlane(source, 1) else { return false }
            var luma = vImage_Buffer(data: lumaBase,
                                     height: vImagePixelCount(CVPixelBufferGetHeightOfPlane(source, 0)),
                                     width: vImagePixelCount(CVPixelBufferGetWidthOfPlane(source, 0)),
                                     rowBytes: CVPixelBufferGetBytesPerRowOfPlane(source, 0))
            var chroma = vImage_Buffer(data: chromaBase,
                                       height: vImagePixelCount(CVPixelBufferGetHeightOfPlane(source, 1)),
                                       width: vImagePixelCount(CVPixelBufferGetWidthOfPlane(source, 1)),
                                       rowBytes: CVPixelBufferGetBytesPerRowOfPlane(source, 1))
            let toBGRA: [UInt8] = [3, 2, 1, 0] // ARGB channel order → BGRA
            guard vImageConvert_420Yp8_CbCr8ToARGB8888(&luma, &chroma, &bgra, &conversion, toBGRA, 255,
                                                         vImage_Flags(kvImageNoFlags)) == kvImageNoError else { return false }
            return Self.copyOrScale(&bgra, into: &output)
        default:
            return false
        }
    }

    private func prepareConversion() -> Bool {
        guard !conversionReady else { return true }
        // Camera frames: video range, ITU-R 709 (HD).
        var range = vImage_YpCbCrPixelRange(Yp_bias: 16, CbCr_bias: 128, YpRangeMax: 235, CbCrRangeMax: 240,
                                            YpMax: 235, YpMin: 16, CbCrMax: 240, CbCrMin: 16)
        conversionReady = vImageConvert_YpCbCrToARGB_GenerateConversion(
            kvImage_YpCbCrToARGBMatrix_ITU_R_709_2, &range, &conversion,
            kvImage420Yp8_CbCr8, kvImageARGB8888, vImage_Flags(kvImageNoFlags)) == kvImageNoError
        return conversionReady
    }

    private func intermediateBuffer(for source: CVPixelBuffer) -> vImage_Buffer? {
        let width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source)
        if intermediateSize != (width, height) {
            free(intermediate.data)
            intermediate = vImage_Buffer()
            intermediateSize = (0, 0)
            guard vImageBuffer_Init(&intermediate, vImagePixelCount(height), vImagePixelCount(width), 32,
                                    vImage_Flags(kvImageNoFlags)) == kvImageNoError else { return nil }
            intermediateSize = (width, height)
        }
        return intermediate
    }

    private static func buffer(_ pixelBuffer: CVPixelBuffer) -> vImage_Buffer? {
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        return vImage_Buffer(data: base, height: vImagePixelCount(CVPixelBufferGetHeight(pixelBuffer)),
                             width: vImagePixelCount(CVPixelBufferGetWidth(pixelBuffer)),
                             rowBytes: CVPixelBufferGetBytesPerRow(pixelBuffer))
    }

    /// Copies row by row when the sizes match. Otherwise scales the centred part of the input that
    /// has the output's shape, so a frame of a different shape is trimmed, not distorted.
    private static func copyOrScale(_ input: inout vImage_Buffer, into output: inout vImage_Buffer) -> Bool {
        if input.width == output.width, input.height == output.height {
            let rowBytes = Int(input.width) * 4
            for row in 0..<Int(input.height) {
                memcpy(output.data + row * output.rowBytes, input.data + row * input.rowBytes, rowBytes)
            }
            return true
        }
        let crop = Dimensions(width: Int(input.width), height: Int(input.height))
            .aspectFillCrop(to: Dimensions(width: Int(output.width), height: Int(output.height)))
        var region = vImage_Buffer(data: input.data + crop.y * input.rowBytes + crop.x * 4,
                                   height: vImagePixelCount(crop.height), width: vImagePixelCount(crop.width),
                                   rowBytes: input.rowBytes)
        return vImageScale_ARGB8888(&region, &output, nil, vImage_Flags(kvImageNoFlags)) == kvImageNoError
    }
}
