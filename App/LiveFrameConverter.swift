import Accelerate
import CoreVideo
import Foundation

/// How live camera frames become OffSight Camera's BGRA format (B2 experiment).
///
/// macOS kept the Background effect on OffSight's preview until the first live frame went out;
/// from then on, until OffSight restarted, every frame (preview included) came back without it.
/// The live path was the only place that ran camera frames through a VideoToolbox pixel transfer
/// (YUV to BGRA plus scaling), so the alternatives avoid it.
enum LiveConversion: String, CaseIterable, Identifiable {
    /// VideoToolbox pixel transfer (the original path).
    case videoToolbox
    /// Accelerate (vImage) on the CPU: YUV to BGRA, then scale.
    case cpu
    /// The capture output delivers BGRA at OffSight Camera's size; OffSight only copies it.
    case captureOutput

    var id: String { rawValue }

    var label: String {
        switch self {
        case .videoToolbox: return "VideoToolbox (original)"
        case .cpu: return "CPU (Accelerate)"
        case .captureOutput: return "Camera output at full size"
        }
    }
}

/// Converts and scales camera frames on the CPU. Capture queue only.
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

    /// Copies row by row when the sizes match, otherwise scales (both are the same shape).
    private static func copyOrScale(_ input: inout vImage_Buffer, into output: inout vImage_Buffer) -> Bool {
        if input.width == output.width, input.height == output.height {
            let rowBytes = Int(input.width) * 4
            for row in 0..<Int(input.height) {
                memcpy(output.data + row * output.rowBytes, input.data + row * input.rowBytes, rowBytes)
            }
            return true
        }
        return vImageScale_ARGB8888(&input, &output, nil, vImage_Flags(kvImageNoFlags)) == kvImageNoError
    }
}
