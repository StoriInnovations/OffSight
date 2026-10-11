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
            if session.canSetSessionPreset(.hd1280x720) {
                session.sessionPreset = .hd1280x720
            } else {
                session.sessionPreset = .high
            }
            guard session.canAddInput(input), session.canAddOutput(output) else {
                session.commitConfiguration()
                log.error("Cannot add camera input/output")
                return false
            }
            session.addInput(input)
            session.addOutput(output)
            session.commitConfiguration()
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
        wantsRunning = run
        if run, !configureIfNeeded() { return }
        isRunning = run
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
