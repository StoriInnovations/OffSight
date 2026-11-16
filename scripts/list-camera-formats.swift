// Lists every camera's formats: size, shape (aspect ratio), frame rates and supported effects.
// Run: swift scripts/list-camera-formats.swift  (used for the B4 aspect-ratio survey)

import AVFoundation

let session = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external],
                                               mediaType: .video, position: .unspecified)
for device in session.devices {
    print(device.localizedName)
    for format in device.formats {
        let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let fps = format.videoSupportedFrameRateRanges
            .map { "\(Int($0.minFrameRate))–\(Int($0.maxFrameRate))" }.joined(separator: ", ")
        var effects: [String] = []
        if format.isPortraitEffectSupported { effects.append("Portrait") }
        if format.isCenterStageSupported { effects.append("Center Stage") }
        if #available(macOS 15.0, *), format.isBackgroundReplacementSupported { effects.append("Background") }
        let shape = String(format: "%.3f", Double(size.width) / Double(size.height))
        print("  \(size.width)x\(size.height)  shape \(shape)  fps \(fps)  \(effects.joined(separator: ", "))")
    }
}
