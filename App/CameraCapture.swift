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
        return largest(candidates, aspect: 16.0 / 9.0)
            ?? largest(candidates, aspect: 4.0 / 3.0)
            ?? largest(candidates)
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
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
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
            session.commitConfiguration()
            // Capture in the camera's native mode (see nativeFormat). On macOS this is done by
            // setting the device's active format directly; there is no input-priority preset.
            if let mode = Self.nativeMode(of: device) {
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
