import AVFoundation
import CoreVideo
import Foundation
import OffSightCore
import os

/// Owns the physical camera. It runs only while a prompt preview is visible or output is live,
/// so the camera's green light matches what OffSight is doing (architecture §2).
final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    /// Called on the capture queue for every frame.
    var onFrame: ((CVPixelBuffer) -> Void)?

    let session = AVCaptureSession()
    private(set) var deviceName: String?
    /// The physical camera in use, once configured.
    private(set) var device: AVCaptureDevice?
    private(set) var isConfigured = false
    private(set) var isRunning = false
    private var lastStopRequestedAt: Date?

    /// True while capturing and for a few seconds after, while the camera is shutting down.
    var isRunningOrStopping: Bool {
        isRunning || (lastStopRequestedAt.map { Date().timeIntervalSince($0) < 3 } ?? false)
    }

    private let log = Logger(subsystem: OffSightConstants.logSubsystem, category: "capture")
    private let frameQueue = DispatchQueue(label: "com.storiinnovations.offsight.capture.frames", qos: .userInteractive)
    private let controlQueue = DispatchQueue(label: "com.storiinnovations.offsight.capture.control")
    private var wantsRunning = false

    static var authorizationStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    func requestAccess(completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    /// Native size of the camera used as the live source, captured at 30 fps: its largest 16:9 mode,
    /// else its largest 4:3 mode, else its largest mode of any shape. (A MacBook Pro camera's largest
    /// mode is a square Center Stage mode, which meeting apps should not get.) OffSight Camera
    /// advertises exactly this size, so live frames pass through unscaled.
    private(set) var nativeFormat: Dimensions?

    override init() {
        super.init()
        nativeFormat = selectDevice().flatMap { Self.nativeMode(of: $0) }.map { $0.dimensions }
    }

    private static func nativeMode(of device: AVCaptureDevice) -> (format: AVCaptureDevice.Format, dimensions: Dimensions)? {
        let candidates = device.formats
            .filter { format in
                format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 29.9 && $0.minFrameRate <= 30.1 }
            }
            .map { format -> (format: AVCaptureDevice.Format, dimensions: Dimensions) in
                let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                return (format: format, dimensions: Dimensions(width: Int(size.width), height: Int(size.height)))
            }
            .filter { OffSightConstants.isAcceptableFormat($0.dimensions) }

        typealias Mode = (format: AVCaptureDevice.Format, dimensions: Dimensions)
        func largest(_ modes: [Mode], aspect: Double? = nil) -> Mode? {
            var best: Mode?
            for mode in modes {
                let width = mode.dimensions.width, height = mode.dimensions.height
                if let aspect, abs(Double(width) / Double(height) - aspect) >= 0.01 { continue }
                if best == nil || width * height > best!.dimensions.width * best!.dimensions.height {
                    best = mode
                }
            }
            return best
        }
        // macOS video effects (Background, Portrait, Studio Light) run only on camera modes that
        // support them, so prefer those: they reach the live video via OffSight's capture.
        let withEffects = candidates.filter { Self.supportsEffects($0.format) }
        for pool in [withEffects, candidates] {
            if let mode = largest(pool, aspect: 16.0 / 9.0) ?? largest(pool, aspect: 4.0 / 3.0) ?? largest(pool) {
                return mode
            }
        }
        return nil
    }

    /// The standard session preset that captures at exactly `size`, if there is one.
    private static func preset(for size: Dimensions) -> AVCaptureSession.Preset? {
        switch (size.width, size.height) {
        case (3840, 2160): return .hd4K3840x2160
        case (1920, 1080): return .hd1920x1080
        case (1280, 720): return .hd1280x720
        case (960, 540): return .qHD960x540
        case (640, 480): return .vga640x480
        default: return nil
        }
    }

    /// True when the mode supports the main system video effects: Background replacement where the
    /// system has it (macOS 15+), otherwise Portrait.
    private static func supportsEffects(_ format: AVCaptureDevice.Format) -> Bool {
        if #available(macOS 15.0, *) {
            return format.isBackgroundReplacementSupported
        }
        return format.isPortraitEffectSupported
    }

    /// Which effects the active camera mode supports, for the Video Effects window and diagnostics.
    var activeModeDescription: String? {
        guard let device else { return nil }
        let format = device.activeFormat
        let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        var supported: [String] = []
        if format.isPortraitEffectSupported { supported.append("Portrait") }
        if format.isStudioLightSupported { supported.append("Studio Light") }
        if format.isCenterStageSupported { supported.append("Center Stage") }
        if #available(macOS 15.0, *), format.isBackgroundReplacementSupported { supported.append("Background") }
        let effects = supported.isEmpty ? "no video effects" : supported.joined(separator: ", ")
        return "\(size.width)x\(size.height): \(effects)"
    }

    /// Physical cameras the user can choose as the live source (UR-31).
    static func availableCameras() -> [(id: String, name: String)] {
        BypassMonitor.physicalCameras().map { (id: $0.uniqueID, name: $0.localizedName) }
    }

    /// The camera chosen in Settings if it is connected; otherwise the built-in camera first,
    /// then any other physical camera.
    private func selectDevice() -> AVCaptureDevice? {
        if let id = AppDefaults.liveCameraID, let chosen = AVCaptureDevice(uniqueID: id) {
            return chosen
        }
        if let builtIn = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified) {
            return builtIn
        }
        return BypassMonitor.physicalCameras().first
    }

    @discardableResult
    func configureIfNeeded() -> Bool {
        guard !isConfigured else { return true }
        guard Self.authorizationStatus == .authorized else { return false }
        guard let device = selectDevice() else {
            log.error("No physical camera found")
            return false
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            let output = AVCaptureVideoDataOutput()
            // The camera's own YUV format, not BGRA: the system video effects chosen for OffSight
            // reached the preview but not frames converted to BGRA on delivery. SinkFeeder converts
            // to OffSight Camera's BGRA format with its pixel transfer (which also scales).
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: frameQueue)

            session.beginConfiguration()
            guard session.canAddInput(input), session.canAddOutput(output) else {
                session.commitConfiguration()
                log.error("Cannot add camera input/output")
                return false
            }
            session.addInput(input)
            session.addOutput(output)
            // Capture in the camera's native mode (see nativeFormat). Prefer the matching standard
            // session preset and let macOS configure the camera, as Photo Booth and FaceTime do:
            // the system video effects chosen for OffSight (Background, Portrait…) were reported
            // active yet left frames unchanged while OffSight set the device's format itself.
            let mode = Self.nativeMode(of: device)
            var usedPreset = false
            if let mode, let preset = Self.preset(for: mode.dimensions), session.canSetSessionPreset(preset) {
                session.sessionPreset = preset
                usedPreset = true
                log.info("Capturing with preset \(preset.rawValue, privacy: .public) for \(mode.dimensions.description, privacy: .public)")
            }
            session.commitConfiguration()
            // No matching preset: set the device's active format directly.
            if let mode, !usedPreset {
                do {
                    try device.lockForConfiguration()
                    device.activeFormat = mode.format
                    let thirtyFPS = CMTime(value: 1, timescale: OffSightConstants.frameRate)
                    device.activeVideoMinFrameDuration = thirtyFPS
                    device.activeVideoMaxFrameDuration = thirtyFPS
                    device.unlockForConfiguration()
                    log.info("Capturing at native \(mode.dimensions.description, privacy: .public), 30 fps")
                } catch {
                    log.error("Could not select the native camera mode: \(error.localizedDescription, privacy: .public)")
                }
            }
            deviceName = device.localizedName
            self.device = device
            isConfigured = true
            log.info("Capture configured with \(device.localizedName, privacy: .public)")
            return true
        } catch {
            log.error("Camera input failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Drops the current camera so the next use picks up the camera chosen in Settings.
    /// Main thread; any live video stops until the next `setRunning(true)`.
    func reselectCamera() {
        controlQueue.sync { [session] in
            if session.isRunning { session.stopRunning() }
            session.beginConfiguration()
            session.inputs.forEach(session.removeInput)
            session.outputs.forEach(session.removeOutput)
            session.commitConfiguration()
        }
        if isRunning { lastStopRequestedAt = Date() }
        wantsRunning = false
        isRunning = false
        isConfigured = false
        deviceName = nil
        device = nil
        nativeFormat = selectDevice().flatMap { Self.nativeMode(of: $0) }.map { $0.dimensions }
        log.info("Live camera reselected: \(self.selectDevice()?.localizedName ?? "none", privacy: .public)")
    }

    func setRunning(_ run: Bool) {
        guard run != wantsRunning else { return }
        // Not recorded as wanted until configured, so a later call retries (e.g. after camera access is granted).
        if run, !configureIfNeeded() { return }
        wantsRunning = run
        isRunning = run
        if !run { lastStopRequestedAt = Date() }
        controlQueue.async { [session] in
            if run {
                if !session.isRunning { session.startRunning() }
            } else {
                if session.isRunning { session.stopRunning() }
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(pixelBuffer)
    }
}
