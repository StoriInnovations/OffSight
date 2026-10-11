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

    /// Native size of the camera used as the live source: its largest mode that supports 30 fps.
    /// OffSight Camera advertises exactly this size, so live frames pass through unscaled.
    private(set) lazy var nativeFormat: Dimensions? = selectDevice().flatMap { Self.nativeMode(of: $0) }.map { $0.dimensions }

    private static func nativeMode(of device: AVCaptureDevice) -> (format: AVCaptureDevice.Format, dimensions: Dimensions)? {
        device.formats
            .filter { format in
                format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 29.9 && $0.minFrameRate <= 30.1 }
            }
            .map { format -> (format: AVCaptureDevice.Format, dimensions: Dimensions) in
                let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                return (format: format, dimensions: Dimensions(width: Int(size.width), height: Int(size.height)))
            }
            .filter { OffSightConstants.isAcceptableFormat($0.dimensions) }
            .max { $0.dimensions.width * $0.dimensions.height < $1.dimensions.width * $1.dimensions.height }
    }

    /// Built-in camera first (initial scope), then any other physical camera.
    private func selectDevice() -> AVCaptureDevice? {
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
